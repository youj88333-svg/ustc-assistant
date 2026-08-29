import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter_windows_secure/webview_flutter_windows.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_source_bundle_builder.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';

import '../test/support/minimal_jw_webview_fixture_server.dart';

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

    final udfRoot = Directory('build/minimal_jw_loopback').absolute;
    JwWebviewController? controller;
    String? resolvedUdf;
    var udfPathValidated = false;
    final diagnostics = <String>[];
    final host = JwWebViewSurfaceHost();
    try {
      await udfRoot.create(recursive: true);
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
      final requestedUdf = Directory(p.join(udfRoot.path, 'run-$suffix'));
      await requestedUdf.create(recursive: true);
      final resolvedRoot = p
          .normalize(await udfRoot.resolveSymbolicLinks())
          .toLowerCase();
      resolvedUdf = p
          .normalize(await requestedUdf.resolveSymbolicLinks())
          .toLowerCase();
      final rootPrefix = p.join(resolvedRoot, '').toLowerCase();
      if (!resolvedUdf.startsWith(rootPrefix) || resolvedUdf == resolvedRoot) {
        throw StateError('loopback UDF escaped its exact build root');
      }
      udfPathValidated = true;

      controller = await createProductionJwWebviewController(
        userDataPath: resolvedUdf,
        debugLoopbackPort: fixture.port,
        policy: fixture.policy,
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
      expect(fixture.requestShapes, contains('GET /course/get-data'));
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

      final detach = host.detachAndAwaitUnmount(controller);
      await tester.pump();
      await detach;
      await controller.stop();
      await controller.dispose();
      await WebviewController.awaitEnvironmentReleased();
      controller = null;
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    } catch (error, stack) {
      // Both values are privacy-safe: requestShapes omit query/body values,
      // and diagnostics are the adapter's closed stage vocabulary.
      debugPrint('loopback request shapes: ${fixture.requestShapes}');
      debugPrint('loopback diagnostics: $diagnostics');
      Error.throwWithStackTrace(error, stack);
    } finally {
      if (controller != null) {
        try {
          final detach = host.detachAndAwaitUnmount(controller);
          await tester.pump();
          await detach;
        } on Object {
          // Best-effort detach in the failure cleanup path.
        }
        try {
          await controller.stop();
        } on Object {
          // Best-effort stop before release.
        }
        try {
          await controller.dispose();
        } on Object {
          // Best-effort release; the original test error remains primary.
        }
        try {
          await WebviewController.awaitEnvironmentReleased();
        } on Object {
          // Best-effort environment release before the UDF cleanup.
        }
      }
      await fixture.close();
      if (udfPathValidated && resolvedUdf != null) {
        final udf = Directory(resolvedUdf);
        if (await udf.exists()) await udf.delete(recursive: true);
      }
    }
  });
}
