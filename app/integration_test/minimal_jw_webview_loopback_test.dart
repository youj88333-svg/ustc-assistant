import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/app/minimal_app_state.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector_factory.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/accounts/application/first_login_commit_service.dart';
import 'package:ustc_assistant_app/features/import/application/import_service.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/settings/presentation/settings_page.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_source_bundle_builder.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/native/native_jw_gateway.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_udf_store.dart';
import 'package:ustc_assistant_app/features/sync/runtime/jw_job_arbiter.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

import '../test/support/minimal_jw_webview_fixture_server.dart';

String _canonicalPath(String path) =>
    p.normalize(path).replaceAll('/', p.separator).toLowerCase();

bool _isStrictDescendant(String candidate, String ancestor) {
  final normalizedCandidate = _canonicalPath(candidate);
  final normalizedAncestor = _canonicalPath(ancestor);
  if (normalizedCandidate == normalizedAncestor) return false;
  final prefix = normalizedAncestor.endsWith(p.separator)
      ? normalizedAncestor
      : '$normalizedAncestor${p.separator}';
  return normalizedCandidate.startsWith(prefix);
}

Future<String> _canonicalExistingDirectory(Directory directory) async {
  if (!await directory.exists()) {
    throw StateError('required build directory is missing');
  }
  return _canonicalPath(await directory.resolveSymbolicLinks());
}

Future<void> _deleteContainedUdf({
  required String appBuildPath,
  required String udfRootPath,
  required String udfPath,
  required String expectedUdfRootPath,
  required String expectedUdfPath,
}) async {
  final appBuild = Directory(appBuildPath);
  final udfRoot = Directory(udfRootPath);
  final udf = Directory(udfPath);
  if (!await appBuild.exists() ||
      !await udfRoot.exists() ||
      !await udf.exists()) {
    return;
  }

  // Re-resolve every boundary immediately before recursive deletion. A
  // junction/reparse-point swap must fail closed rather than broaden the
  // deletion target beyond this test's unique child.
  final resolvedAppBuild = await _canonicalExistingDirectory(appBuild);
  final resolvedUdfRoot = await _canonicalExistingDirectory(udfRoot);
  final resolvedUdf = await _canonicalExistingDirectory(udf);
  if (resolvedAppBuild != _canonicalPath(appBuildPath) ||
      resolvedUdfRoot != _canonicalPath(expectedUdfRootPath) ||
      resolvedUdf != _canonicalPath(expectedUdfPath) ||
      _canonicalPath(udfRootPath) != _canonicalPath(expectedUdfRootPath) ||
      _canonicalPath(udfPath) != _canonicalPath(expectedUdfPath) ||
      !_isStrictDescendant(resolvedUdfRoot, resolvedAppBuild) ||
      !_isStrictDescendant(resolvedUdf, resolvedUdfRoot) ||
      !_isStrictDescendant(resolvedUdf, resolvedAppBuild)) {
    throw StateError('loopback UDF containment changed before cleanup');
  }
  await udf.delete(recursive: true);
}

Future<void> _deleteContainedTestRoot({
  required String appBuildPath,
  required String rootPath,
  required String expectedRootPath,
}) async {
  final appBuild = Directory(appBuildPath);
  final root = Directory(rootPath);
  if (!await appBuild.exists() || !await root.exists()) return;

  final resolvedAppBuild = await _canonicalExistingDirectory(appBuild);
  final resolvedRoot = await _canonicalExistingDirectory(root);
  final normalizedAppBuild = _canonicalPath(appBuildPath);
  final normalizedRoot = _canonicalPath(rootPath);
  if (resolvedAppBuild != normalizedAppBuild ||
      resolvedRoot != _canonicalPath(expectedRootPath) ||
      normalizedRoot != _canonicalPath(expectedRootPath) ||
      !_isStrictDescendant(resolvedRoot, resolvedAppBuild) ||
      _canonicalPath(Directory(resolvedRoot).parent.path) != resolvedAppBuild) {
    throw StateError('loopback runtime containment changed before cleanup');
  }
  await root.delete(recursive: true);
  if (await root.exists()) {
    throw StateError('loopback runtime cleanup remained');
  }
}

Future<int> _ownedWebViewProcessCount(String rootPath) async {
  if (!Platform.isWindows) return 0;
  // The command returns only a count. It deliberately does not print process
  // command lines, paths, or any other host details.
  const script = r'''
$root = $env:MINIMAL_JW_LOOPBACK_ROOT
if ([string]::IsNullOrWhiteSpace($root)) { throw 'root missing' }
$root = [System.IO.Path]::GetFullPath($root).TrimEnd('\').ToLowerInvariant()
$matches = @(
  Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction Stop |
    Where-Object {
      $commandLine = $_.CommandLine
      $commandLine -and $commandLine.ToLowerInvariant().Contains($root)
    }
)
$matches.Count
''';
  final result = await Process.run(
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    <String>['-NoProfile', '-NonInteractive', '-Command', script],
    environment: <String, String>{'MINIMAL_JW_LOOPBACK_ROOT': rootPath},
  );
  if (result.exitCode != 0) {
    throw StateError('owned WebView process inspection failed');
  }
  final count = int.tryParse(result.stdout.toString().trim());
  if (count == null || count < 0) {
    throw StateError('owned WebView process count was not numeric');
  }
  return count;
}

Future<int> _waitForOwnedWebViewProcessExit(String rootPath) async {
  var count = await _ownedWebViewProcessCount(rootPath);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (count != 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    count = await _ownedWebViewProcessCount(rootPath);
  }
  return count;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: 'loopback lifecycle stage timed out');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real WebView2 survives mounted collection and ordered teardown', (
    tester,
  ) async {
    final courseDatum = await File(
      'test/fixtures/jw/course-datum.json',
    ).readAsString();
    final examHtml = await File(
      'test/fixtures/jw/exam-page.html',
    ).readAsString();
    final fixture = await MinimalJwWebViewFixtureServer.start(
      courseDatum: courseDatum,
      examHtml: examHtml,
    );

    final appBuild = Directory('build').absolute;
    JwWebviewController? controller;
    String? canonicalAppBuild;
    String? canonicalUdfRoot;
    String? udfRootPath;
    String? resolvedUdf;
    String? requestedUdfPath;
    var udfPathValidated = false;
    var controllerCreated = false;
    var controllerReleased = false;
    final diagnostics = <String>[];
    final host = JwWebViewSurfaceHost();
    Object? primaryError;
    StackTrace? primaryStackTrace;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    void rememberCleanupError(Object error, StackTrace stackTrace) {
      cleanupError ??= error;
      cleanupStackTrace ??= stackTrace;
    }

    try {
      // Canonicalize the existing app/build boundary before creating any
      // child. This rejects a pre-existing junction/reparse-point root that
      // resolves outside the build tree.
      canonicalAppBuild = await _canonicalExistingDirectory(appBuild);
      final udfRoot = Directory(
        p.join(canonicalAppBuild, 'minimal_jw_loopback'),
      );
      udfRootPath = _canonicalPath(udfRoot.path);
      await udfRoot.create(recursive: true);
      canonicalUdfRoot = await _canonicalExistingDirectory(udfRoot);
      if (canonicalUdfRoot != udfRootPath ||
          !_isStrictDescendant(canonicalUdfRoot, canonicalAppBuild)) {
        throw StateError('loopback UDF root escaped app/build');
      }
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
      final requestedUdf = Directory(p.join(canonicalUdfRoot, 'run-$suffix'));
      requestedUdfPath = _canonicalPath(requestedUdf.path);
      await requestedUdf.create(recursive: true);
      resolvedUdf = p
          .normalize(await requestedUdf.resolveSymbolicLinks())
          .toLowerCase();
      if (resolvedUdf != requestedUdfPath ||
          !_isStrictDescendant(resolvedUdf, canonicalUdfRoot) ||
          !_isStrictDescendant(resolvedUdf, canonicalAppBuild)) {
        throw StateError('loopback UDF escaped or was redirected');
      }
      udfPathValidated = true;

      controller = await createProductionJwWebviewController(
        userDataPath: resolvedUdf,
        debugLoopbackPort: fixture.port,
        policy: fixture.policy,
      );
      controllerCreated = true;
      expect(
        isJwRuntimePolicyAllowedForBuild(
          productionJwWebRuntimePolicy,
          debugMode: false,
          debugLoopbackPort: fixture.port,
        ),
        isFalse,
      );
      expect(
        isJwRuntimePolicyAllowedForBuild(
          productionJwWebRuntimePolicy,
          debugMode: false,
        ),
        isTrue,
      );
      expect(
        isJwRuntimePolicyAllowedForBuild(fixture.policy, debugMode: false),
        isFalse,
      );
      expect(
        isJwRuntimePolicyAllowedForBuild(
          fixture.policy,
          debugMode: true,
          debugLoopbackPort: fixture.port,
        ),
        isTrue,
      );
      expect(
        fixture.policy.portalLoginTarget.readySelector,
        isNot(productionJwWebRuntimePolicy.portalLoginTarget.readySelector),
      );
      await tester.pumpWidget(
        MaterialApp(home: SizedBox(height: 360, child: host.widget)),
      );
      await host.attach(controller);
      await tester.pump();

      final attachedController = controller;
      final adapter = JwWebViewAdapter(
        controllerFactory: () async => attachedController,
        runtimePolicy: fixture.policy,
        safeDiagnostic: diagnostics.add,
      );
      await adapter.gotoRoot();
      await adapter.gotoCasEntry();
      await adapter.fillLogin(
        const LoginCredentials(
          username: 'PB00000000',
          password: 'loopback-only',
        ),
      );
      await adapter.waitForAuthenticatedHome(const Duration(seconds: 5));
      await adapter.gotoCourseTable();
      final dataId = await adapter.resolveCourseDataId(
        const Duration(seconds: 5),
      );
      final datum = await adapter.fetchCourseDatum(
        semesterId: 461,
        dataId: dataId,
        referer: fixture.policy.courseEntryUrl,
      );
      await adapter.gotoExamArrange();
      final examHtmlResult = await adapter.fetchExamHtml(
        const Duration(seconds: 5),
      );
      final bundle = buildJwSourceBundle(
        courseDatum: datum,
        examHtml: examHtmlResult,
        accountId: 'loopback-account',
        semester: const JwSemester(
          semesterId: 461,
          semesterKey: '2026fall',
          displayName: '2026 秋季学期',
        ),
      );
      expect(bundle['schemaVersion'], '1.0');
      expect(dataId, 'loopback-data');
      expect(fixture.validHomeSubmitRequestCount, 1);
      expect(fixture.invalidHomeSubmitRequestCount, 0);
      expect(
        fixture.requestDetails,
        contains(
          'POST /portal/home application/x-www-form-urlencoded '
          'body:form:password,username',
        ),
      );
      expect(
        fixture.bootstrapCourseGetDataRequestCount,
        greaterThanOrEqualTo(1),
      );
      expect(fixture.invalidCourseGetDataRequestCount, 0);
      expect(fixture.validCourseGetDataXhrRequestCount, 1);
      expect(
        fixture.courseGetDataBootstrapRequestShapes,
        contains('GET /course/get-data'),
      );
      expect(
        fixture.courseGetDataXhrRequestShapes,
        contains('GET /course/get-data XMLHttpRequest'),
      );
      expect(fixture.courseGetDataCarriedCredentials, isTrue);
      expect(fixture.validCourseDatumRequestCount, 1);
      expect(fixture.invalidCourseDatumRequestCount, 0);
      expect(
        fixture.requestShapes,
        contains('POST /course/datum application/json XMLHttpRequest'),
      );
      expect(
        fixture.requestDetails,
        contains(
          'POST /course/datum application/json XMLHttpRequest '
          'body:object:lessonIds',
        ),
      );
      expect(fixture.courseDatumCarriedCredentials, isTrue);

      final detach = host.detachAndAwaitUnmount(controller);
      await tester.pump();
      await detach;
      await controller.stop();
      await controller.dispose();
      // ProductionJwWebviewController.dispose owns the environment-release
      // barrier; the integration test intentionally performs no extra wait.
      controllerReleased = true;
      controller = null;
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    } catch (error, stack) {
      // Both values are privacy-safe: requestShapes omit query/body values,
      // and diagnostics are the adapter's closed stage vocabulary.
      debugPrint('loopback request shapes: ${fixture.requestShapes}');
      debugPrint('loopback diagnostics: $diagnostics');
      primaryError = error;
      primaryStackTrace = stack;
    } finally {
      final activeController = controller;
      if (activeController != null) {
        try {
          final detach = host.detachAndAwaitUnmount(activeController);
          await tester.pump();
          await detach;
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
        try {
          await activeController.stop();
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
        try {
          await activeController.dispose();
          controllerReleased = true;
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
        if (controllerReleased) controller = null;
      }
      try {
        await fixture.close();
      } on Object catch (error, stack) {
        rememberCleanupError(error, stack);
      }
      if (udfPathValidated &&
          controllerCreated &&
          controllerReleased &&
          canonicalAppBuild != null &&
          canonicalUdfRoot != null &&
          udfRootPath != null &&
          resolvedUdf != null &&
          requestedUdfPath != null) {
        try {
          await _deleteContainedUdf(
            appBuildPath: canonicalAppBuild,
            udfRootPath: udfRootPath,
            udfPath: requestedUdfPath,
            expectedUdfRootPath: canonicalUdfRoot,
            expectedUdfPath: resolvedUdf,
          );
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
      }
    }

    final error = primaryError;
    if (error != null) {
      Error.throwWithStackTrace(error, primaryStackTrace ?? StackTrace.current);
    }
    final errorDuringCleanup = cleanupError;
    if (errorDuringCleanup != null) {
      Error.throwWithStackTrace(
        errorDuringCleanup,
        cleanupStackTrace ?? StackTrace.current,
      );
    }
  });

  testWidgets(
    'app-owned runtime completes loopback first login and recoverable reset',
    (tester) async {
      final courseDatum = await File(
        'test/fixtures/jw/course-datum.json',
      ).readAsString();
      final examHtml = await File(
        'test/fixtures/jw/exam-page.html',
      ).readAsString();
      final fixture = await MinimalJwWebViewFixtureServer.start(
        courseDatum: courseDatum,
        examHtml: examHtml,
      );

      final database = AppDatabase(NativeDatabase.memory());
      final appKey = GlobalKey<UstcAssistantAppState>();
      final appBuild = Directory('build').absolute;
      String? canonicalAppBuild;
      String? runtimeRootPath;
      var runtimeRootCreated = false;
      var runtimeLoadCount = 0;
      var controllerFactoryCalls = 0;
      var udfDeleteCalls = 0;
      var releaseFailureBudget = 3;
      var appMounted = false;
      var appShutdownComplete = false;
      final diagnostics = <String>[];
      final runtimes = <MinimalJwRuntime>[];
      final snapshots = <SourceJobSnapshot>[];
      StreamSubscription<SourceJobSnapshot>? snapshotsSubscription;
      Object? primaryError;
      StackTrace? primaryStackTrace;
      Object? cleanupError;
      StackTrace? cleanupStackTrace;
      final phaseHistory = <MinimalAppPhase>[];

      void recordPhase() {
        final currentApp = appKey.currentState;
        if (currentApp != null) phaseHistory.add(currentApp.appState.phase);
      }

      void rememberCleanupError(Object error, StackTrace stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      }

      try {
        canonicalAppBuild = await _canonicalExistingDirectory(appBuild);
        final suffix =
            '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
        final requestedRoot = Directory(
          p.join(canonicalAppBuild, 'minimal_jw_runtime_loopback-$suffix'),
        );
        runtimeRootPath = _canonicalPath(requestedRoot.path);
        await requestedRoot.create(recursive: true);
        runtimeRootCreated = true;
        final resolvedRoot = await _canonicalExistingDirectory(requestedRoot);
        if (resolvedRoot != runtimeRootPath ||
            !_isStrictDescendant(resolvedRoot, canonicalAppBuild) ||
            _canonicalPath(Directory(resolvedRoot).parent.path) !=
                canonicalAppBuild) {
          throw StateError('loopback runtime root escaped app/build');
        }

        final udfStore = WindowsJwUdfStore(
          privateRoot: Directory(resolvedRoot),
          releaseAttempts: 3,
          releaseRetryDelay: Duration.zero,
          releaseDelay: (_) async {},
          deleteDirectory: (directory) async {
            udfDeleteCalls++;
            if (releaseFailureBudget > 0) {
              releaseFailureBudget--;
              throw FileSystemException(
                'injected release failure',
                directory.path,
                OSError('sharing violation', 32),
              );
            }
            await directory.delete(recursive: true);
          },
        );

        Future<MinimalJwRuntime> loadRuntime() async {
          runtimeLoadCount++;
          final app = appKey.currentState;
          if (app == null) {
            throw StateError('app runtime composition is not mounted');
          }
          final accounts = AccountService(
            database: database,
            protector: defaultCredentialProtector(),
          );
          final schemaText = await rootBundle.loadString(
            'assets/schemas/source-bundle-1.0.draft7.schema.json',
          );
          final importer = ImportService(
            database: database,
            decoder: SourceBundleDecoder(
              jsonDecode(schemaText) as Map<String, dynamic>,
            ),
            reminderReconciler: app.reminderReconciler,
          );
          final firstLoginCommit = FirstLoginCommitService(
            accounts: accounts,
            persistPrepared: importer.persistPrepared,
            reminderReconciler: app.reminderReconciler,
          );
          final sessionAdmin = WindowsJwBrowserSessionAdmin(
            udfStore: udfStore,
            safeDiagnostic: diagnostics.add,
            pageFactory: (controller) => JwWebViewAdapter(
              controllerFactory: () async => controller,
              runtimePolicy: fixture.policy,
              safeDiagnostic: diagnostics.add,
              initialController: controller,
            ),
            productionControllerFactory:
                ({
                  required String? userDataPath,
                  required void Function(String) safeDiagnostic,
                }) {
                  controllerFactoryCalls++;
                  if (userDataPath == null || userDataPath.isEmpty) {
                    throw StateError('loopback UDF path was not bound');
                  }
                  return createProductionJwWebviewController(
                    userDataPath: userDataPath,
                    debugLoopbackPort: fixture.port,
                    policy: fixture.policy,
                    safeDiagnostic: safeDiagnostic,
                  );
                },
          );
          final native = NativeJwGateway(
            sessionAdmin: sessionAdmin,
            safeDiagnostic: diagnostics.add,
          );
          final arbiter = JwJobArbiter();
          late final SourceJobGatewayAdapter gateway;
          Future<BridgeGateway> selectNative() async => native;
          final coordinator = SyncCoordinator(
            database: database,
            accounts: accounts,
            bridgeFactory: selectNative,
            importBundle: importer.importBytes,
            prepareBundle: importer.prepare,
            firstLoginCommitService: firstLoginCommit,
            gatewayQuiesce: () => gateway.quiesce(),
            gatewayResume: () => gateway.resume(),
          );
          gateway = SourceJobGatewayAdapter(
            coordinator: coordinator,
            arbiter: arbiter,
            bridgeFactory: selectNative,
            ownsBrowserSessions: true,
            safeDiagnostic: diagnostics.add,
          );
          final runtime = MinimalJwRuntime(
            gateway: gateway,
            browserSessions: sessionAdmin,
            syncCoordinator: coordinator,
            udfStore: udfStore,
          );
          runtimes.add(runtime);
          return runtime;
        }

        await tester.pumpWidget(
          UstcAssistantApp(
            key: appKey,
            database: database,
            runtimeLoader: loadRuntime,
          ),
        );
        appMounted = true;
        await tester.pumpAndSettle();

        final app = appKey.currentState!;
        phaseHistory.add(app.appState.phase);
        app.appState.addListener(recordPhase);
        app.router.go('/sync');
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('first-login-username'))
              .evaluate()
              .isNotEmpty,
        );
        final firstRuntime = await app.runtimeOwner.current;
        expect(runtimeLoadCount, 1);
        expect(runtimes, hasLength(1));
        expect(controllerFactoryCalls, 0);

        // The sync route borrows the same runtime; changing routes must not
        // construct a second controller or a second WebView environment.
        app.router.go('/chat');
        await tester.pumpAndSettle();
        app.router.go('/sync');
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('first-login-username'))
              .evaluate()
              .isNotEmpty,
        );
        expect(runtimeLoadCount, 1);
        expect(await app.runtimeOwner.current, same(firstRuntime));
        expect(controllerFactoryCalls, 0);

        snapshotsSubscription = firstRuntime.gateway.states.listen(
          snapshots.add,
        );
        await tester.enterText(
          find.byKey(const Key('first-login-username')),
          'PB00000000',
        );
        await tester.enterText(
          find.byKey(const Key('first-login-password')),
          'loopback-only',
        );
        await tester.tap(find.byKey(const Key('first-login-submit')));
        await tester.pump();
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('continue-interactive-login'))
              .evaluate()
              .isNotEmpty,
        );

        // The first-login collector may have a provisional identity, but no
        // account or source writes are allowed before the user continuation.
        expect(await database.select(database.localAccounts).get(), isEmpty);
        expect(
          await database.select(database.credentialAccounts).get(),
          isEmpty,
        );
        expect(await database.select(database.importBatches).get(), isEmpty);
        expect(await database.select(database.courseSeries).get(), isEmpty);
        expect(await database.select(database.calendarEvents).get(), isEmpty);
        expect(await database.select(database.syncRuns).get(), isEmpty);

        await tester.tap(find.byKey(const Key('continue-interactive-login')));
        await tester.pump();
        await _pumpUntil(
          tester,
          () => app.appState.phase == MinimalAppPhase.configured,
        );

        final succeeded = snapshots
            .where((snapshot) => snapshot.phase == 'succeeded')
            .toList(growable: false);
        expect(succeeded, hasLength(1));
        expect(
          await _ownedWebViewProcessCount(runtimeRootPath),
          greaterThan(0),
          reason: 'the active loopback WebView must carry the unique UDF root',
        );
        final localAccounts = await database
            .select(database.localAccounts)
            .get();
        final credentialAccounts = await database
            .select(database.credentialAccounts)
            .get();
        final importBatches = await database
            .select(database.importBatches)
            .get();
        final sourceRecords = await database
            .select(database.sourceRecords)
            .get();
        final courseSeries = await database.select(database.courseSeries).get();
        final calendarEvents = await database
            .select(database.calendarEvents)
            .get();
        final scheduleRelations = await database
            .select(database.scheduleRelations)
            .get();
        final syncRuns = await database.select(database.syncRuns).get();
        expect(localAccounts, hasLength(1));
        expect(credentialAccounts, hasLength(1));
        expect(importBatches, hasLength(1));
        expect(sourceRecords, isNotEmpty);
        expect(courseSeries, isNotEmpty);
        expect(calendarEvents, isNotEmpty);
        expect(syncRuns, hasLength(1));
        expect(
          calendarEvents.where((event) => event.type == 'exam'),
          isNotEmpty,
        );
        final importedEntityCount =
            courseSeries.length +
            calendarEvents.length +
            scheduleRelations.length;
        expect(importedEntityCount, greaterThan(0));
        expect(succeeded.single.aggregateCount, importedEntityCount);

        expect(fixture.validHomeSubmitRequestCount, 1);
        expect(fixture.invalidHomeSubmitRequestCount, 0);
        expect(
          fixture.requestDetails,
          contains(
            'POST /portal/home application/x-www-form-urlencoded '
            'body:form:password,username',
          ),
        );
        expect(
          fixture.bootstrapCourseGetDataRequestCount,
          greaterThanOrEqualTo(1),
        );
        expect(fixture.invalidCourseGetDataRequestCount, 0);
        expect(fixture.validCourseGetDataXhrRequestCount, 1);
        expect(
          fixture.courseGetDataBootstrapRequestShapes,
          contains('GET /course/get-data'),
        );
        expect(
          fixture.courseGetDataXhrRequestShapes,
          contains('GET /course/get-data XMLHttpRequest'),
        );
        expect(fixture.courseGetDataCarriedCredentials, isTrue);
        expect(fixture.validCourseDatumRequestCount, 1);
        expect(fixture.invalidCourseDatumRequestCount, 0);
        expect(
          fixture.requestShapes,
          contains('POST /course/datum application/json XMLHttpRequest'),
        );
        expect(
          fixture.requestDetails,
          contains(
            'POST /course/datum application/json XMLHttpRequest '
            'body:object:lessonIds',
          ),
        );
        expect(fixture.courseDatumCarriedCredentials, isTrue);
        expect(
          fixture.requestShapes.where((shape) => shape == 'GET /exam/arrange'),
          hasLength(1),
        );

        // Repeat the ordinary-surface -> sync-surface transition only after
        // the first real collection has created the controller. This proves
        // route reuse does not construct another runtime, controller, or
        // environment (and does not launch a second fixture collection).
        app.router.go('/chat');
        await tester.pumpAndSettle();
        app.router.go('/sync');
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('sync-all')).evaluate().isNotEmpty,
        );
        await _pumpUntil(tester, () {
          final surface = find.byKey(
            const Key('jw-webview-surface-visibility'),
            skipOffstage: false,
          );
          final surfaces = surface.evaluate();
          return surfaces.isEmpty ||
              surfaces.every(
                (element) => (element.widget as Offstage).offstage,
              );
        });
        expect(runtimeLoadCount, 1);
        expect(await app.runtimeOwner.current, same(firstRuntime));
        expect(runtimes, hasLength(1));
        expect(controllerFactoryCalls, 1);
        expect(fixture.validHomeSubmitRequestCount, 1);
        expect(fixture.validCourseDatumRequestCount, 1);
        expect(
          fixture.requestShapes.where((shape) => shape == 'GET /exam/arrange'),
          hasLength(1),
        );

        // Leave the reused sync surface before opening Settings. This mirrors a
        // user returning to the ordinary app surface after checking sync and
        // lets all retained sync route elements finish their visibility update.
        app.router.go('/chat');
        await tester.pumpAndSettle();
        expect(app.router.routeInformationProvider.value.uri.path, '/chat');
        final account = localAccounts.single;
        final partitionRef = udfStore.referenceFor(account.id);
        final partitionPath = _canonicalPath(
          udfStore.resolveForTest(partitionRef).path,
        );
        expect(_isStrictDescendant(partitionPath, runtimeRootPath), isTrue);
        expect(await udfStore.listOwnedPartitions(), hasLength(1));

        app.router.go('/settings');
        await _pumpUntil(tester, () => find.text('设置').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () => find.byType(SnackBar, skipOffstage: false).evaluate().isEmpty,
          timeout: const Duration(seconds: 10),
        );
        final settingsScrollable = find.descendant(
          of: find.byType(SettingsPage),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        );
        expect(settingsScrollable, findsOneWidget);
        final resetFinder = find.byKey(const Key('complete-reset'));
        await tester.scrollUntilVisible(
          resetFinder,
          240,
          scrollable: settingsScrollable,
        );
        await tester.pump();
        // The item is a final ListView child and may be built just below the
        // desktop viewport when the finder first appears. Jump the exact
        // SettingsPage ListView to its bounded end rather than relying on a
        // desktop pointer drag whose hit target can be outside the viewport.
        final settingsScrollState = tester.state<ScrollableState>(
          settingsScrollable,
        );
        await Scrollable.ensureVisible(
          tester.element(resetFinder),
          alignment: 0.5,
          duration: Duration.zero,
        );
        settingsScrollState.position.jumpTo(
          settingsScrollState.position.maxScrollExtent,
        );
        await tester.pumpAndSettle();
        expect(resetFinder, findsOneWidget);
        await tester.tap(resetFinder);
        await tester.pumpAndSettle();
        final firstConfirmation = find.text('确认');
        expect(firstConfirmation, findsOneWidget);
        await tester.tap(firstConfirmation);
        await tester.pumpAndSettle();
        final secondConfirmation = find.text('确认');
        expect(secondConfirmation, findsOneWidget);
        await tester.tap(secondConfirmation);
        await tester.pump();
        await _pumpUntil(
          tester,
          () => app.appState.phase == MinimalAppPhase.resetFailed,
        );

        expect(
          app.appState.safeCode,
          MinimalAppStateController.resetFailedCode,
        );
        expect(
          app.router.routeInformationProvider.value.uri.path,
          '/reset-recovery',
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('retry-reset')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('retry-reset')), findsOneWidget);
        expect(runtimeLoadCount, 1);
        expect(runtimes, hasLength(1));
        expect(controllerFactoryCalls, 1);
        expect(udfDeleteCalls, 3);
        expect(await _waitForOwnedWebViewProcessExit(runtimeRootPath), 0);
        expect(await udfStore.listOwnedPartitions(), hasLength(1));
        expect(await database.select(database.localAccounts).get(), isEmpty);
        expect(
          await database.select(database.credentialAccounts).get(),
          isEmpty,
        );
        expect(await database.select(database.importBatches).get(), isEmpty);
        expect(await database.select(database.sourceRecords).get(), isEmpty);
        expect(await database.select(database.courseSeries).get(), isEmpty);
        expect(await database.select(database.calendarEvents).get(), isEmpty);
        expect(
          await database.select(database.scheduleRelations).get(),
          isEmpty,
        );
        expect(await database.select(database.syncRuns).get(), isEmpty);

        // A deep link cannot bypass the fail-closed state or trigger a fresh
        // runtime while the retained UDF still needs a retry.
        app.router.go('/sync');
        await tester.pump();
        expect(
          app.router.routeInformationProvider.value.uri.path,
          '/reset-recovery',
        );
        expect(runtimeLoadCount, 1);

        await tester.tap(find.byKey(const Key('retry-reset')));
        await tester.pump();
        await _pumpUntil(
          tester,
          () =>
              app.router.routeInformationProvider.value.uri.path == '/sync' &&
              !app.appState.hasAccount &&
              runtimeLoadCount == 2 &&
              find
                  .byKey(const Key('first-login-username'))
                  .evaluate()
                  .isNotEmpty,
        );
        expect(phaseHistory, contains(MinimalAppPhase.unconfigured));
        expect(runtimeLoadCount, 2);
        expect(runtimes, hasLength(2));
        expect(await app.runtimeOwner.current, same(runtimes.last));
        expect(controllerFactoryCalls, 1);
        expect(udfDeleteCalls, 4);
        expect(await udfStore.listOwnedPartitions(), isEmpty);
        expect(await _waitForOwnedWebViewProcessExit(runtimeRootPath), 0);
        expect(app.router.routeInformationProvider.value.uri.path, '/sync');
        expect(find.byKey(const Key('first-login-username')), findsOneWidget);

        await app.prepareForExit();
        appShutdownComplete = true;
      } catch (error, stack) {
        // Keep failure output limited to fixture request shapes and closed
        // diagnostic stages; never print account, path, query, or payload.
        debugPrint('loopback request shapes: ${fixture.requestShapes}');
        debugPrint('loopback diagnostics: $diagnostics');
        final currentApp = appKey.currentState;
        debugPrint(
          'loopback lifecycle summary: loads=$runtimeLoadCount '
          'controllers=$controllerFactoryCalls '
          'runtimes=${runtimes.length} '
          'phase=${currentApp?.appState.phase.name} '
          'route=${currentApp?.router.routeInformationProvider.value.uri.path} '
          'usernameField=${find.byKey(const Key("first-login-username")).evaluate().length} '
          'continueField=${find.byKey(const Key("continue-interactive-login")).evaluate().length} '
          'snapshot=${runtimes.isEmpty ? "none" : (runtimes.last.gateway as SourceJobGatewayAdapter).latestSnapshot.toJson()}',
        );
        primaryError = error;
        primaryStackTrace = stack;
      } finally {
        if (appMounted) {
          appKey.currentState?.appState.removeListener(recordPhase);
        }
        try {
          snapshotsSubscription?.cancel();
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
        if (appMounted && !appShutdownComplete) {
          try {
            await appKey.currentState?.prepareForExit();
            appShutdownComplete = true;
          } on Object catch (error, stack) {
            rememberCleanupError(error, stack);
          }
        }
        if (appMounted) {
          try {
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          } on Object catch (error, stack) {
            rememberCleanupError(error, stack);
          }
        }
        try {
          await fixture.close();
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
        if (appShutdownComplete &&
            runtimeRootCreated &&
            runtimeRootPath != null) {
          try {
            final residual = await _ownedWebViewProcessCount(runtimeRootPath);
            if (residual != 0) {
              throw StateError('loopback WebView process remained after exit');
            }
            if ((await WindowsJwUdfStore(
              privateRoot: Directory(runtimeRootPath),
            ).listOwnedPartitions()).isNotEmpty) {
              throw StateError('loopback UDF partition remained after exit');
            }
            await _deleteContainedTestRoot(
              appBuildPath: canonicalAppBuild!,
              rootPath: runtimeRootPath,
              expectedRootPath: runtimeRootPath,
            );
          } on Object catch (error, stack) {
            rememberCleanupError(error, stack);
          }
        }
        try {
          await database.close();
        } on Object catch (error, stack) {
          rememberCleanupError(error, stack);
        }
      }

      final error = primaryError;
      if (error != null) {
        Error.throwWithStackTrace(
          error,
          primaryStackTrace ?? StackTrace.current,
        );
      }
      final errorDuringCleanup = cleanupError;
      if (errorDuringCleanup != null) {
        Error.throwWithStackTrace(
          errorDuringCleanup,
          cleanupStackTrace ?? StackTrace.current,
        );
      }
    },
  );
}
