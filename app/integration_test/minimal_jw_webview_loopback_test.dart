import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_app/features/sync/native/jw_source_bundle_builder.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';

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
        isJwRuntimePolicyAllowedForBuild(
          fixture.policy,
          debugMode: false,
        ),
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
}
