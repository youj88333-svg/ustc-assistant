import 'package:flutter/material.dart';

import 'settings_contract.dart';

const _recoveryMuted = Color(0xFF66736C);

/// Startup recovery surface for one already-persisted fixed-scope maintenance
/// intent. The root runtime owns exit handling and durable recovery metadata.
final class MaintenanceRecoveryPage extends StatefulWidget {
  const MaintenanceRecoveryPage({
    super.key,
    required this.settings,
    this.diagnosticsBuilder,
  });

  final ApplicationSettingsPort settings;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  State<MaintenanceRecoveryPage> createState() =>
      _MaintenanceRecoveryPageState();
}

final class _MaintenanceRecoveryPageState
    extends State<MaintenanceRecoveryPage> {
  int _generation = 0;
  bool _retryPending = false;
  SettingsFailureCode? _localFailure;

  @override
  void didUpdateWidget(covariant MaintenanceRecoveryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      _generation++;
      _retryPending = false;
      _localFailure = null;
    }
  }

  bool _current(ApplicationSettingsPort port, int generation) =>
      mounted && identical(widget.settings, port) && generation == _generation;

  Future<void> _retry() async {
    final port = widget.settings;
    final generation = _generation;
    if (!_current(port, generation) ||
        _retryPending ||
        port.settingsView.actionPending ||
        port.settingsView.loading ||
        port.settingsView.maintenance.phase != MaintenancePhase.recovery) {
      return;
    }
    setState(() {
      _retryPending = true;
      _localFailure = null;
    });
    try {
      await port.retryMaintenance();
    } on Object catch (error) {
      if (_current(port, generation)) {
        setState(() => _localFailure = _recoveryFailureCode(error));
      }
    } finally {
      if (_current(port, generation)) {
        setState(() => _retryPending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.settings,
    builder: (context, _) {
      final view = widget.settings.settingsView;
      final progress = view.maintenance;
      final failure = progress.failure ?? view.failure ?? _localFailure;
      final recovery = progress.phase == MaintenancePhase.recovery;
      final canRetry =
          recovery && !_retryPending && !view.actionPending && !view.loading;

      return Scaffold(
        backgroundColor: const Color(0xFFF5F7F6),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.settings_backup_restore_rounded,
                          size: 38,
                          color: Color(0xFF1F6B45),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '正在恢复本机数据',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          progress.activating
                              ? '应用页面尚未载入，可以重试读取本机状态。'
                              : progress.committed
                              ? '数据清理已提交，正在恢复页面。重试只刷新显示。'
                              : _recoveryPhaseText(progress.phase),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _recoveryMuted,
                            height: 1.45,
                          ),
                        ),
                        if (progress.kind != null) ...[
                          const SizedBox(height: 14),
                          _RecoveryScope(
                            kind: progress.kind!,
                            committed: progress.committed,
                          ),
                        ],
                        if (failure != null) ...[
                          const SizedBox(height: 14),
                          _RecoveryNotice(
                            message:
                                failure == SettingsFailureCode.storageFailed &&
                                    (progress.activating || progress.committed)
                                ? '页面读取未能完成。请重试载入本机状态。'
                                : _recoveryFailureText(failure),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          key: const ValueKey('maintenance-recovery-retry'),
                          onPressed: canRetry ? _retry : null,
                          icon: _retryPending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: Text(_retryPending ? '正在重试…' : '重试恢复'),
                        ),
                        const SizedBox(height: 12),
                        const _RecoveryNotice(
                          message: '如果需要关闭应用，请使用系统窗口关闭按钮。下次启动会继续检查并恢复本地数据。',
                        ),
                        if (widget.diagnosticsBuilder != null) ...[
                          const SizedBox(height: 12),
                          widget.diagnosticsBuilder!.call(context),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

final class _RecoveryScope extends StatelessWidget {
  const _RecoveryScope({required this.kind, this.committed = false});
  final MaintenanceKind kind;
  final bool committed;

  @override
  Widget build(BuildContext context) {
    final text = committed
        ? '数据清理已提交，原确认范围不再重复执行。'
        : switch (kind) {
            MaintenanceKind.agenda => '待恢复范围：日程与任务。账号、密码和资料库按原规则保留。',
            MaintenanceKind.reset => '待恢复范围：本应用数据完全重置。安装文件、数据库容器和恢复账本保留。',
          };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E9E5)),
      ),
      child: Text(text, softWrap: true),
    );
  }
}

final class _RecoveryNotice extends StatelessWidget {
  const _RecoveryNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF6F0DF),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE8D7AC)),
    ),
    child: Text(message, softWrap: true, style: const TextStyle(height: 1.4)),
  );
}

String _recoveryPhaseText(MaintenancePhase phase) => switch (phase) {
  MaintenancePhase.idle => '当前没有待恢复的维护操作。',
  MaintenancePhase.preparing => '正在准备固定范围的本地维护。',
  MaintenancePhase.cleaning => '正在释放已登记资源并处理维护范围。',
  MaintenancePhase.committing => '正在保存本地维护结果。',
  MaintenancePhase.refreshing => '维护已提交，正在刷新应用状态。',
  MaintenancePhase.recovery => '维护尚未完成。可以重试同一项恢复操作。',
};

String _recoveryFailureText(SettingsFailureCode code) => switch (code) {
  SettingsFailureCode.busy => '另一项本地操作仍在进行，请稍后重试。',
  SettingsFailureCode.staleContext => '本机状态已更新，请重新打开应用后检查。',
  SettingsFailureCode.confirmationRequired => '维护确认状态无效，请重新发起维护。',
  SettingsFailureCode.invalidIntent => '待恢复的维护范围无法确认；请保留当前数据并重新打开应用。',
  SettingsFailureCode.storageFailed => '本地维护未能完成，已有内容状态以应用当前显示为准。',
  SettingsFailureCode.cleanupPending => '资源清理仍待完成；可以重试，或关闭应用后再次启动。',
  SettingsFailureCode.ownershipLost => '本机数据所有权状态无法确认；请关闭应用并重新启动。',
  SettingsFailureCode.closed => '应用运行状态已关闭；请使用系统窗口关闭后重新启动。',
};

SettingsFailureCode _recoveryFailureCode(Object error) =>
    error is SettingsFailure ? error.code : SettingsFailureCode.storageFailed;
