import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/demo_runtime.dart';
import 'app/ios_school_diagnostics_button.dart';
import 'app/jw_sync_panel.dart';
import 'app/young_sync_panel.dart';
import 'core/contracts.dart';
import 'core/settings_contract.dart';
import 'platform/ios_runtime_platform_factory.dart';

const _revision = String.fromEnvironment(
  'USTC_BUILD_REVISION',
  defaultValue: 'unknown',
);
const _platformChannel = MethodChannel('ustc_assistant/platform_v1');

/// Standalone iOS I2 entry used for the private school bridge acceptance.
/// It exposes only the fixed JW and Young sync panels; it does not add model,
/// reminder, daily-sync, voice, or Agent actions to this acceptance surface.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IOSI2App());
}

typedef IOSI2BootstrapOpener =
    Future<RuntimeBootstrap> Function(IOSRuntimePlatformFactory platform);

final class IOSI2App extends StatelessWidget {
  const IOSI2App({super.key, this.openBootstrap});

  @visibleForTesting
  final IOSI2BootstrapOpener? openBootstrap;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: _IOSI2Screen(openBootstrap: openBootstrap),
  );
}

final class _IOSI2Screen extends StatefulWidget {
  const _IOSI2Screen({this.openBootstrap});

  final IOSI2BootstrapOpener? openBootstrap;

  @override
  State<_IOSI2Screen> createState() => _IOSI2ScreenState();
}

final class _IOSI2ScreenState extends State<_IOSI2Screen> {
  RuntimeBootstrap? _bootstrap;
  String? _failure;
  String _nativeRevision = 'unknown';
  String _bundleId = 'unknown';
  bool? _revisionMatches;
  bool _busy = true;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    await _openOwnedRuntime();
  }

  Future<void> _openOwnedRuntime() async {
    RuntimeBootstrap? opened;
    try {
      final platform = IOSRuntimePlatformFactory();
      final buildInfo = await _platformChannel
          .invokeMapMethod<String, Object?>('i2BuildInfo')
          .timeout(const Duration(seconds: 5));
      if (buildInfo == null ||
          buildInfo.length != 4 ||
          buildInfo['revision'] is! String ||
          buildInfo['bundleId'] is! String ||
          (buildInfo['bundleId'] as String).isEmpty ||
          buildInfo['authentication'] != 'manual' ||
          buildInfo['schoolStore'] != 'wk-uuid-v1') {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      _nativeRevision = buildInfo['revision'] as String;
      _bundleId = buildInfo['bundleId'] as String;
      _revisionMatches = _isRevision(_revision) && _isRevision(_nativeRevision)
          ? _nativeRevision == _revision
          : null;
      opened =
          await (widget.openBootstrap?.call(platform) ??
              // This entry is the iOS acceptance target; it always uses the iOS
              // private directories, credential protector, and native browser.
              // ignore: invalid_use_of_visible_for_testing_member
              RuntimeBootstrap.open(platformFactory: platform));
      if (!mounted) {
        await opened.close();
        return;
      }
      _bootstrap = opened;
      if (opened.runtime == null) {
        setState(() {
          _failure =
              opened!.settings.settingsView.failure?.name ??
              'runtime_unavailable';
          _busy = false;
        });
        return;
      }
      setState(() {
        _failure = null;
        _busy = false;
      });
    } catch (error) {
      if (opened != null) {
        try {
          await opened.close();
        } catch (_) {
          // Keep the existing owner visible for an explicit recovery action.
          _bootstrap = opened;
          _recordFailure(const AppFailure(FailureCode.ownershipLost));
          return;
        }
        _bootstrap = null;
      }
      _recordFailure(error);
    }
  }

  Future<void> _retry() async {
    if (_busy) return;
    final current = _bootstrap;
    if (current == null) {
      setState(() {
        _busy = true;
        _failure = null;
      });
      await _openOwnedRuntime();
      return;
    }

    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      // Retry the retained bootstrap's unfinished recovery/assembly. Reopening
      // here could acquire a second owner while this one is still held.
      await current.settings.retryMaintenance();
      if (current.runtime == null) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      if (!mounted) return;
      setState(() {
        _failure = null;
        _busy = false;
      });
    } catch (error) {
      _recordFailure(error);
    }
  }

  Future<void> _closeBootstrap() async {
    if (_busy) return;
    final current = _bootstrap;
    if (current == null) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await current.close();
      if (!mounted) return;
      setState(() {
        _bootstrap = null;
        _failure = 'closed';
        _busy = false;
      });
    } catch (error) {
      _recordFailure(error);
    }
  }

  void _recordFailure(Object error) {
    if (!mounted) return;
    setState(() {
      _failure = switch (error) {
        AppFailure(:final code) => code.name,
        SettingsFailure(:final code) => code.name,
        PlatformException(:final code)
            when const {
              'unsafe_directory',
              'storage_failed',
              'unavailable',
              'unsupported_platform',
            }.contains(code) =>
          code,
        _ => 'platform_or_storage_failed',
      };
      _busy = false;
    });
  }

  @override
  void dispose() {
    final bootstrap = _bootstrap;
    if (bootstrap != null) unawaited(bootstrap.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _bootstrap?.runtime;
    return Scaffold(
      appBar: AppBar(
        title: const Text('教务与二课同步'),
        actions: const [IOSSchoolDiagnosticsButton()],
      ),
      body: SafeArea(
        child: _busy
            ? const Center(
                child: CircularProgressIndicator(
                  key: ValueKey('ios-i2-opening'),
                ),
              )
            : runtime == null
            ? _failureView()
            : Column(
                children: [
                  _manualLoginGuidance(context),
                  Expanded(
                    child: IndexedStack(
                      index: _selectedTab,
                      children: [
                        _sourceContent(
                          JwSyncPanel(
                            controller: runtime.jwSync,
                            productMode: true,
                            embedded: true,
                          ),
                        ),
                        _sourceContent(
                          YoungSyncPanel(
                            controller: runtime.youngSync,
                            productMode: true,
                            embedded: true,
                            clock: () => runtime.clock.nowUtc,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: runtime == null
          ? null
          : NavigationBar(
              selectedIndex: _selectedTab,
              onDestinationSelected: (index) =>
                  setState(() => _selectedTab = index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.school_outlined),
                  selectedIcon: Icon(Icons.school),
                  label: '教务',
                ),
                NavigationDestination(
                  icon: Icon(Icons.event_note_outlined),
                  selectedIcon: Icon(Icons.event_note),
                  label: '二课',
                ),
              ],
            ),
    );
  }

  Widget _manualLoginGuidance(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '修订：${_shortRevision(_nativeRevision)} · $_revisionStatus',
              key: const ValueKey('ios-i2-revision'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            SelectableText(
              '应用身份：$_bundleId',
              key: const ValueKey('ios-i2-bundle-id'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              '如学校窗口要求登录、验证码或额外授权，请在该窗口手动完成。看到学校页面后点“返回应用”，再继续本次同步。手动输入的账号密码不会被应用读取；留空密码也不要求模型 Key。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    ),
  );

  String get _revisionStatus => switch (_revisionMatches) {
    true => '一致',
    false => '不一致',
    null => '待确认',
  };

  Widget _sourceContent(Widget panel) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [panel, const SizedBox(height: 20)],
    ),
  );

  Widget _failureView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sync_problem_outlined, size: 42),
          const SizedBox(height: 12),
          const Text('应用无法安全打开同步页面。'),
          const SizedBox(height: 8),
          SelectableText(
            '安全错误码：${_failure ?? 'platform_or_storage_failed'}',
            key: const ValueKey('ios-i2-failure-code'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('ios-i2-retry'),
            onPressed: _busy ? null : _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
          if (_bootstrap != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('ios-i2-close-bootstrap'),
              onPressed: _busy ? null : _closeBootstrap,
              icon: const Icon(Icons.close),
              label: const Text('关闭并释放本次运行'),
            ),
          ],
        ],
      ),
    ),
  );
}

bool _isRevision(String value) => RegExp(r'^[0-9a-f]{7,64}$').hasMatch(value);

String _shortRevision(String value) {
  if (!_isRevision(value)) return 'unknown';
  return value.substring(0, value.length < 12 ? value.length : 12);
}
