// This opt-in probe emits a closed evidence record directly to the integration
// test reporter; avoid_print is intentional here.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';

/// This test is intentionally inert during ordinary integration discovery.
/// Run it only after an explicit review with:
/// `--dart-define=RUN_JW_PUBLIC_PORTAL_PROBE=true`.
const bool _runProbe = bool.fromEnvironment(
  'RUN_JW_PUBLIC_PORTAL_PROBE',
  defaultValue: false,
);

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
    throw StateError('probe build boundary is missing');
  }
  return _canonicalPath(await directory.resolveSymbolicLinks());
}

/// Deletes only the unique probe child after the native release barrier has
/// completed. Re-resolving all boundaries immediately before deletion keeps a
/// junction/reparse-point swap fail closed.
Future<void> _deleteContainedProbe({
  required String appBuildPath,
  required String probePath,
  required String expectedProbePath,
}) async {
  final appBuild = Directory(appBuildPath);
  final probe = Directory(probePath);
  if (!await appBuild.exists() || !await probe.exists()) return;

  final resolvedAppBuild = await _canonicalExistingDirectory(appBuild);
  final resolvedProbe = await _canonicalExistingDirectory(probe);
  final normalizedAppBuild = _canonicalPath(appBuildPath);
  final normalizedProbe = _canonicalPath(probePath);
  if (resolvedAppBuild != normalizedAppBuild ||
      resolvedProbe != _canonicalPath(expectedProbePath) ||
      normalizedProbe != _canonicalPath(expectedProbePath) ||
      !_isStrictDescendant(resolvedProbe, resolvedAppBuild) ||
      _canonicalPath(Directory(resolvedProbe).parent.path) !=
          resolvedAppBuild) {
    throw StateError('probe profile containment changed before cleanup');
  }
  await probe.delete(recursive: true);
  if (await probe.exists()) {
    throw StateError('probe profile cleanup remained');
  }
}

String _safeExceptionType(Object error) {
  final type = error.runtimeType.toString();
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(type)
      ? type
      : 'UnknownException';
}

/// Maps only closed, static collection messages to reportable reasons. An
/// unknown message is deliberately omitted; the report retains only the
/// exception type and boundary in that case.
String? _safeCollectionReason(Object error) {
  if (error is! JwCollectionException) return null;
  final message = error.message;
  return switch (message) {
    'navigation policy rejected' => 'navigation_policy_rejected',
    'navigation did not complete' => 'navigation_did_not_complete',
    'target did not become ready in time' => 'target_not_ready_in_time',
    'ready handshake was not accepted' => 'ready_handshake_rejected',
    'ready target changed' => 'ready_target_changed',
    'ready attempt is no longer active' => 'ready_attempt_inactive',
    'DOM ready selector is missing' => 'dom_selector_missing',
    'DOM ready selector timed out' => 'dom_selector_timed_out',
    'document loading timed out' => 'document_loading_timed_out',
    'collections script is not registered' => 'registered_script_unknown',
    'registered script arguments invalid' => 'registered_script_args_invalid',
    'collection script returned invalid data' => 'registered_script_bad_reply',
    'web message stream failed' => 'registered_script_message_stream_failed',
    'collection script timed out' => 'registered_script_timed_out',
    'webview adapter is closed' => 'adapter_closed',
    _ => _safeScriptCollectionReason(message),
  };
}

String? _safeScriptCollectionReason(String? message) {
  const prefix = 'collection script failed: ';
  if (message == null || !message.startsWith(prefix)) return null;
  final reason = message.substring(prefix.length);
  return switch (reason) {
    'page_contract_changed' => 'script_failed_page_contract_changed',
    'missing_selector' => 'script_failed_missing_selector',
    'not_actionable' => 'script_failed_not_actionable',
    'wrong_target' => 'script_failed_wrong_target',
    'missing_semester_runtime' => 'script_failed_missing_semester_runtime',
    'invalid_semester_options' => 'script_failed_invalid_semester_options',
    'missing_course_data_context' => 'script_failed_missing_course_data_context',
    'response_too_large' => 'script_failed_response_too_large',
    'request_failed' => 'script_failed_request_failed',
    'script_failed' => 'script_failed_script_failed',
    _ => null,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'credential-free native JW public portal boundary probe',
    (tester) async {
      if (!_runProbe || !Platform.isWindows) return;

      final elapsed = Stopwatch()..start();
      final trace = <String>[];
      final safeStages = <String>[];
      final host = JwWebViewSurfaceHost();
      final appBuild = Directory('build').absolute;
      JwWebviewController? controller;
      String? canonicalAppBuild;
      String? probePath;
      String? resolvedProbePath;
      var probePathValidated = false;
      var controllerReleased = false;
      var rootFinishedOnPortalLogin = false;
      var preReloadHandshakeMatched = false;
      var portalReady = false;
      var lastSuccessfulBoundary = 'none';
      String? currentBoundary;
      String? failedBoundary;
      Object? primaryError;
      Object? cleanupError;
      var cleanupStatus = 'not_started';

      void recordSafeStage(String stage) {
        // Existing adapter stages are closed vocabulary. Keep a defensive
        // filter here so an unexpected plugin string can never enter output.
        final safe = RegExp(r'^[A-Za-z0-9:._=/\-]{1,180}$');
        safeStages.add(safe.hasMatch(stage) ? stage : 'diagnostic_stage_unknown');
      }

      void record(String label) {
        trace.add('$label elapsed_ms=${elapsed.elapsedMilliseconds}');
      }

      Future<T> runBoundary<T>(
        String name,
        Future<T> Function() operation,
      ) async {
        currentBoundary = name;
        final started = elapsed.elapsedMilliseconds;
        trace.add('boundary:start:$name elapsed_ms=$started');
        try {
          final result = await operation();
          final finished = elapsed.elapsedMilliseconds;
          trace.add(
            'boundary:success:$name elapsed_ms=$finished '
            'duration_ms=${finished - started}',
          );
          lastSuccessfulBoundary = name;
          currentBoundary = null;
          return result;
        } on Object {
          final finished = elapsed.elapsedMilliseconds;
          trace.add(
            'boundary:failure:$name elapsed_ms=$finished '
            'duration_ms=${finished - started}',
          );
          failedBoundary ??= name;
          currentBoundary = null;
          rethrow;
        }
      }

      try {
        await runBoundary<void>('probe_profile_setup', () async {
          canonicalAppBuild = await _canonicalExistingDirectory(appBuild);
          final suffix =
              '${DateTime.now().microsecondsSinceEpoch}-'
              '${Random().nextInt(1 << 32)}';
          final probe = Directory(
            p.join(canonicalAppBuild!, 'jw-public-portal-probe-$suffix'),
          );
          probePath = _canonicalPath(probe.path);
          await probe.create(recursive: true);
          final resolved = await _canonicalExistingDirectory(probe);
          if (resolved != probePath ||
              !_isStrictDescendant(resolved, canonicalAppBuild!) ||
              _canonicalPath(Directory(resolved).parent.path) !=
                  canonicalAppBuild) {
            throw StateError('probe profile escaped app/build');
          }
          resolvedProbePath = resolved;
          probePathValidated = true;
        });

        await runBoundary<void>('controller_create', () async {
          controller = await createProductionJwWebviewController(
            userDataPath: resolvedProbePath,
            safeDiagnostic: recordSafeStage,
          );
        });

        await runBoundary<void>('surface_mount', () async {
          final nativeController = controller;
          if (nativeController == null) {
            throw StateError('probe controller was not created');
          }
          await tester.pumpWidget(
            MaterialApp(
              home: SizedBox(height: 360, child: host.widget),
            ),
          );
          await tester.pump();
          await host.attach(nativeController);
          await tester.pump();
        });

        late final JwWebViewAdapter adapter;
        await runBoundary<void>('adapter_create', () async {
          final nativeController = controller;
          if (nativeController == null) {
            throw StateError('probe controller was not created');
          }
          adapter = JwWebViewAdapter(
            controllerFactory: () async => nativeController,
            initialController: nativeController,
            safeDiagnostic: recordSafeStage,
          );
        });

        await runBoundary<void>('gotoRoot', () async {
          await adapter.gotoRoot();
          // This is intentionally an in-memory boolean only; the URL value is
          // never printed or persisted.
          final current = await adapter.currentUrl;
          rootFinishedOnPortalLogin = portalLoginTarget.urlMatches(current);
        });

        await runBoundary<void>('pre_reload_handshake', () async {
          final nativeController = controller;
          if (nativeController == null) {
            throw StateError('probe controller was not created');
          }
          final result = await executeRegisteredScript(
            nativeController,
            scriptId: 'jw.portal.login.inspect',
            args: const <String, Object?>{},
            registeredScripts: productionJwWebRuntimePolicy.registeredScripts,
            timeout: defaultResponseTimeout,
            safeDiagnostic: recordSafeStage,
          );
          // Only this closed boolean is retained; the handshake result map is
          // never printed or persisted.
          preReloadHandshakeMatched = result['matched'] == true;
        });

        await runBoundary<void>('gotoCasEntry', adapter.gotoCasEntry);
        portalReady = true;
        record('portal_target_ready');
      } on Object catch (error) {
        primaryError = error;
        failedBoundary ??= currentBoundary ?? 'probe';
      } finally {
        cleanupStatus = 'cleanup_started';
        final nativeController = controller;
        var detachSucceeded = nativeController == null;
        var stopSucceeded = nativeController == null;
        var unmounted = false;

        if (nativeController != null) {
          try {
            final detach = host.detachAndAwaitUnmount(nativeController);
            await tester.pump();
            await detach;
            detachSucceeded = true;
          } on Object catch (error) {
            cleanupError ??= error;
          }
          try {
            await nativeController.stop();
            stopSucceeded = true;
          } on Object catch (error) {
            cleanupError ??= error;
          }
          try {
            // ProductionJwWebviewController.dispose includes the native
            // environment-release barrier; success is the only proof used to
            // authorize deletion of this test's profile child.
            await nativeController.dispose();
            controllerReleased = true;
          } on Object catch (error) {
            cleanupError ??= error;
          }
        }

        try {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          unmounted = true;
        } on Object catch (error) {
          cleanupError ??= error;
        }

        if (!controllerReleased) {
          cleanupStatus = 'release_unproven_preserved';
        } else if (!detachSucceeded || !stopSucceeded || !unmounted) {
          cleanupStatus = 'release_proven_cleanup_incomplete_preserved';
        } else if (!probePathValidated ||
            canonicalAppBuild == null ||
            probePath == null ||
            resolvedProbePath == null) {
          cleanupStatus = 'release_proven_profile_validation_failed_preserved';
        } else {
          try {
            await _deleteContainedProbe(
              appBuildPath: canonicalAppBuild!,
              probePath: probePath!,
              expectedProbePath: resolvedProbePath!,
            );
            cleanupStatus = 'released_and_deleted';
          } on Object catch (error) {
            cleanupError ??= error;
            cleanupStatus = 'release_proven_delete_failed_preserved';
          }
        }

        elapsed.stop();
      }

      final failureReason =
          primaryError == null ? null : _safeCollectionReason(primaryError);
      final failureType =
          primaryError == null ? null : _safeExceptionType(primaryError);
      final cleanupFailureType =
          cleanupError == null ? null : _safeExceptionType(cleanupError);
      final status = primaryError == null ? 'portal_ready' : 'failed';

      // This output is deliberately a closed, credential-free record for the
      // controller. It contains no URL, query, body, cookie, DOM, path, or
      // exception message/stack payload.
      print('JW_PUBLIC_PORTAL_PROBE_RESULT status=$status');
      print('last_successful_stage=$lastSuccessfulBoundary');
      print('root_finished_on_portal_login=$rootFinishedOnPortalLogin');
      print('pre_reload_handshake_matched=$preReloadHandshakeMatched');
      print('portal_login_target_ready=$portalReady');
      print('failure_boundary=${failedBoundary ?? 'none'}');
      if (failureType != null) print('failure_type=$failureType');
      if (failureReason != null) print('failure_reason=$failureReason');
      if (cleanupFailureType != null) {
        print('cleanup_failure_type=$cleanupFailureType');
      }
      print('cleanup_status=$cleanupStatus');
      print('elapsed_ms=${elapsed.elapsedMilliseconds}');
      print('safe_diagnostics=${safeStages.join('|')}');
      print('boundary_trace=${trace.join('|')}');
    },
    skip: !_runProbe || !Platform.isWindows,
  );
}
