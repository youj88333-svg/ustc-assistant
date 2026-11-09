import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/demo_runtime.dart';
import 'app/m0_app.dart';
import 'app/product_app.dart';
import 'app/runtime_diagnostics.dart';
import 'core/contracts.dart';
import 'core/diagnostics_contract.dart';
import 'm0_entry.dart' show OwnedApplication;
import 'platform/ios_runtime_platform_factory.dart';
import 'platform/transient_diagnostics.dart';

const _revision = String.fromEnvironment(
  'USTC_BUILD_REVISION',
  defaultValue: 'unknown',
);
const _platform = MethodChannel('ustc_assistant/platform_v1');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IOSI4App());
}

typedef IOSI4BootstrapOpener =
    Future<RuntimeBootstrap> Function(IOSRuntimePlatformFactory factory);

/// The ordinary product surface on the same private iOS installation.
/// No model, school job or system permission is started by this entry.
final class IOSI4App extends StatefulWidget {
  const IOSI4App({super.key, this.openBootstrap});

  @visibleForTesting
  final IOSI4BootstrapOpener? openBootstrap;

  @override
  State<IOSI4App> createState() => _IOSI4AppState();
}

final class _IOSI4AppState extends State<IOSI4App> {
  final _diagnostics = TransientDiagnostics(
    versions: const DiagnosticVersions(
      application: '0.4.0',
      revision: _revision,
    ),
  );
  RuntimeBootstrap? _bootstrap;
  String? _buildInformation;
  FailureCode? _failure;
  bool _opening = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_opening || _bootstrap != null) return;
    final generation = ++_generation;
    setState(() {
      _opening = true;
      _failure = null;
    });
    try {
      final raw = await _platform
          .invokeMethod<Object?>('i4BuildInfo')
          .timeout(const Duration(seconds: 5));
      final information = iosI4BuildInformation(
        raw,
        expectedRevision: _revision,
      );
      const factory = IOSRuntimePlatformFactory();
      final opened =
          await (widget.openBootstrap?.call(factory) ??
              // Only the production iOS factory owns this installation.
              RuntimeBootstrap.open(
                // ignore: invalid_use_of_visible_for_testing_member
                platformFactory: factory,
                diagnosticApplicationVersion: '0.4.0',
              ));
      if (!mounted || generation != _generation) {
        await opened.close();
        return;
      }
      setState(() {
        _bootstrap = opened;
        _buildInformation = information;
        _opening = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      final code = error is AppFailure ? error.code : FailureCode.storageFailed;
      recordDiagnostic(
        _diagnostics,
        DiagnosticEvent(
          name: DiagnosticEventName.applicationFailed,
          stage: DiagnosticStage.startup,
          outcome: DiagnosticOutcome.failure,
          code: diagnosticCode(code.name),
        ),
      );
      setState(() {
        _failure = code;
        _opening = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    final bootstrap = _bootstrap;
    if (bootstrap != null) unawaited(bootstrap.close());
    unawaited(_diagnostics.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = _bootstrap;
    if (bootstrap != null) {
      return OwnedApplication(
        bootstrap: bootstrap,
        enableOnboarding: false,
        privateBuildInformation: _buildInformation,
      );
    }
    if (_failure != null) {
      return M0StartupFailureApp(
        code: _failure!,
        diagnostics: _diagnostics,
        onRetry: _opening ? null : _open,
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: productTheme,
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: CircularProgressIndicator(key: ValueKey('ios-i4-opening')),
          ),
        ),
      ),
    );
  }
}

/// Validate only fixed build metadata, never directory paths or business data.
@visibleForTesting
String iosI4BuildInformation(Object? raw, {required String expectedRevision}) {
  const keys = {
    'revision',
    'bundleId',
    'version',
    'buildNumber',
    'authentication',
    'notificationBackend',
    'imagePicker',
  };
  if (raw is! Map ||
      raw.length != keys.length ||
      raw.keys.any((key) => !keys.contains(key)) ||
      raw['authentication'] != 'manual' ||
      raw['notificationBackend'] != 'user-notifications-v1' ||
      raw['imagePicker'] != 'photosui-imageio-v1') {
    throw const AppFailure(FailureCode.invalidSnapshot);
  }
  final revision = raw['revision'];
  final bundleId = raw['bundleId'];
  final version = raw['version'];
  final build = raw['buildNumber'];
  if (revision is! String ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(revision) ||
      bundleId is! String ||
      bundleId.length > 255 ||
      !RegExp(r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$').hasMatch(bundleId) ||
      version is! String ||
      !RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(version) ||
      build is! String ||
      !RegExp(r'^\d{1,10}$').hasMatch(build) ||
      (expectedRevision != 'unknown' && revision != expectedRevision)) {
    throw const AppFailure(FailureCode.invalidSnapshot);
  }
  return '版本 $version ($build) · iOS 私用版\n'
      '修订：$revision（${expectedRevision == 'unknown' ? '待确认' : '一致'}）\n'
      '应用身份：$bundleId\n'
      '学校登录：手动 · 图片：系统照片选择器\n'
      'iOS 不提供 Widget 和语音输入。';
}
