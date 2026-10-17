import 'dart:async';

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import '../jobs/observation_port.dart';
import '../source/observation_contract.dart';

/// A compact observation control panel hosted by the existing M0 screen.
///
/// The port owns the browser session and its lifecycle. This widget only
/// subscribes to its view and never closes the port when it is disposed.
class ObservationPanel extends StatefulWidget {
  const ObservationPanel({super.key, required this.controller});

  final ObservationPort controller;

  @override
  State<ObservationPanel> createState() => _ObservationPanelState();
}

class _ObservationPanelState extends State<ObservationPanel> {
  final Map<_ObservationAction, int> _inFlight = {};
  int _nextToken = 0;
  int _controllerEpoch = 0;
  String? _actionMessage;

  @override
  void didUpdateWidget(covariant ObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controllerEpoch++;
      _inFlight.clear();
      _actionMessage = null;
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<ObservationView>(
    stream: widget.controller.changes,
    initialData: widget.controller.view,
    builder: (context, snapshot) {
      final view = snapshot.data ?? widget.controller.view;
      final anyActionInFlight = _inFlight.isNotEmpty;
      final hasNonCancelActionInFlight = _inFlight.keys.any(
        (action) => action != _ObservationAction.cancel,
      );
      final canOpen =
          (view.phase == ObservationPhase.idle ||
              view.phase == ObservationPhase.closed) &&
          !anyActionInFlight;
      final canInspectOrNavigate =
          view.phase == ObservationPhase.open && !anyActionInFlight;
      final canNavigateJwPage =
          view.phase == ObservationPhase.open &&
          view.ready &&
          _displayableOrigin(view.origin) == 'jw.ustc.edu.cn' &&
          !anyActionInFlight;
      final canCancel =
          (view.phase == ObservationPhase.open ||
              view.phase == ObservationPhase.opening) &&
          !_inFlight.containsKey(_ObservationAction.cancel);
      final canRetryCleanup =
          view.phase == ObservationPhase.recovery && !anyActionInFlight;

      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: constraints.maxWidth < 560 ? 12 : 20,
            vertical: 12,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(constraints.maxWidth < 560 ? 16 : 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'M1 教务观测',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '页面就绪不等于身份核验；尚未采集或导入真实数据',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '账号、密码和验证码请在学校窗口中手填',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '登录后用下面两个入口打开独立页面，无需在学校首页内部切换标签。',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_displayableOrigin(view.origin)
                          case final origin?) ...[
                        const SizedBox(height: 8),
                        Text('当前受控来源：$origin'),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (view.phase == ObservationPhase.idle ||
                              view.phase == ObservationPhase.closed)
                            FilledButton.icon(
                              onPressed: canOpen
                                  ? () => unawaited(
                                      _perform(
                                        _ObservationAction.open,
                                        fallback: _ActionFallback.source,
                                        action: widget.controller.open,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.open_in_browser),
                              label: const Text('打开教务观测窗口'),
                            ),
                          if (view.phase == ObservationPhase.open) ...[
                            OutlinedButton.icon(
                              onPressed: canInspectOrNavigate
                                  ? () => unawaited(
                                      _perform(
                                        _ObservationAction.inspect,
                                        fallback: _ActionFallback.source,
                                        action: widget.controller.inspect,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.fact_check_outlined),
                              label: const Text('检查业务页就绪'),
                            ),
                            OutlinedButton.icon(
                              onPressed: canInspectOrNavigate
                                  ? () => unawaited(
                                      _perform(
                                        _ObservationAction.navigate,
                                        fallback: _ActionFallback.source,
                                        action:
                                            widget.controller.navigateInitial,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新打开教务入口'),
                            ),
                          ],
                          if (view.phase == ObservationPhase.opening ||
                              view.phase == ObservationPhase.open)
                            OutlinedButton.icon(
                              onPressed: canCancel
                                  ? () => unawaited(
                                      _perform(
                                        _ObservationAction.cancel,
                                        fallback: _ActionFallback.cleanup,
                                        action: widget.controller.closeSession,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('取消并清理窗口'),
                            ),
                          if (view.phase == ObservationPhase.recovery)
                            FilledButton.icon(
                              onPressed: canRetryCleanup
                                  ? () => unawaited(
                                      _perform(
                                        _ObservationAction.retryCleanup,
                                        fallback: _ActionFallback.cleanup,
                                        action: widget.controller.retryCleanup,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试清理'),
                            ),
                          OutlinedButton.icon(
                            onPressed: canNavigateJwPage
                                ? () => unawaited(
                                    _perform(
                                      _ObservationAction.jwPage,
                                      fallback: _ActionFallback.source,
                                      action: () =>
                                          widget.controller.navigateJwPage(
                                            JwObservationPage.courseTable,
                                          ),
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text('打开课表页面'),
                          ),
                          OutlinedButton.icon(
                            onPressed: canNavigateJwPage
                                ? () => unawaited(
                                    _perform(
                                      _ObservationAction.jwPage,
                                      fallback: _ActionFallback.source,
                                      action: () =>
                                          widget.controller.navigateJwPage(
                                            JwObservationPage.examArrange,
                                          ),
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.event_note_outlined),
                            label: const Text('打开考试安排'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _status(context, view),
                      if (view.diagnostics.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('最近页面动作（仅显示类型和站点，不含登录内容）'),
                        for (final diagnostic in view.diagnostics.skip(
                          view.diagnostics.length > 5
                              ? view.diagnostics.length - 5
                              : 0,
                        ))
                          Text(_diagnosticMessage(diagnostic)),
                      ],
                      if (hasNonCancelActionInFlight ||
                          _inFlight.containsKey(_ObservationAction.cancel)) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                      if (_actionMessage != null) ...[
                        const SizedBox(height: 12),
                        _notice(context, _actionMessage!),
                      ] else if (view.failure != null) ...[
                        const SizedBox(height: 12),
                        _notice(
                          context,
                          _messageForFailure(
                            view.failure!,
                            fallback: _ActionFallback.source,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _status(BuildContext context, ObservationView view) {
    final message = switch (view.phase) {
      ObservationPhase.idle || ObservationPhase.closed => '观测窗口未打开或已关闭',
      ObservationPhase.opening =>
        _inFlight.containsKey(_ObservationAction.cancel)
            ? '正在请求取消并清理教务观测窗口。'
            : '正在打开教务观测窗口。',
      ObservationPhase.open when view.blocked => '页面操作已被阻止，请查看下方原因；业务身份仍未核验。',
      ObservationPhase.open when view.ready => '页面已就绪，业务身份尚未核验',
      ObservationPhase.open => '窗口已打开，尚未确认业务页面就绪。',
      ObservationPhase.closing => '正在等待窗口与相关资源释放。',
      ObservationPhase.recovery => '清理未完成，仍可能有浏览器资源占用；请重试清理。',
    };
    final colorScheme = Theme.of(context).colorScheme;
    final isRecovery = view.phase == ObservationPhase.recovery;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isRecovery
            ? colorScheme.errorContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isRecovery ? Icons.warning_amber_rounded : Icons.info_outline,
            color: isRecovery
                ? colorScheme.onErrorContainer
                : colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: isRecovery ? colorScheme.onErrorContainer : null,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(color: colorScheme.onErrorContainer),
      ),
    );
  }

  Future<void> _perform(
    _ObservationAction actionType, {
    required _ActionFallback fallback,
    required Future<void> Function() action,
  }) async {
    if (!mounted || _inFlight.containsKey(actionType)) return;
    final epoch = _controllerEpoch;
    final token = ++_nextToken;
    setState(() {
      _inFlight[actionType] = token;
      _actionMessage = null;
    });

    try {
      await action();
    } on AppFailure catch (failure) {
      if (_isCurrent(epoch)) {
        setState(() {
          _actionMessage = _messageForFailure(failure.code, fallback: fallback);
        });
      }
    } catch (_) {
      if (_isCurrent(epoch)) {
        setState(() {
          _actionMessage = _fallbackMessage(fallback);
        });
      }
    } finally {
      if (_inFlight[actionType] == token) {
        _inFlight.remove(actionType);
        if (_isCurrent(epoch)) setState(() {});
      }
    }
  }

  bool _isCurrent(int epoch) => mounted && epoch == _controllerEpoch;
}

enum _ObservationAction {
  open,
  inspect,
  navigate,
  jwPage,
  cancel,
  retryCleanup,
}

enum _ActionFallback { source, cleanup }

String _diagnosticMessage(BrowserDiagnostic diagnostic) {
  final action = switch (diagnostic.code) {
    BrowserDiagnosticCode.topNavigationBlocked => '顶层页面跳转被阻止',
    BrowserDiagnosticCode.frameNavigationBlocked => '内嵌页面跳转被阻止',
    BrowserDiagnosticCode.documentRequestBlocked => '页面文档请求被阻止',
    BrowserDiagnosticCode.insecureDocumentUpgraded => '已将页面请求安全转换为 HTTPS',
    BrowserDiagnosticCode.popupBlocked => '新窗口被阻止',
    BrowserDiagnosticCode.downloadBlocked => '下载被阻止',
    BrowserDiagnosticCode.permissionBlocked => '页面权限申请被拒绝',
    BrowserDiagnosticCode.externalProtocolBlocked => '外部应用跳转被阻止',
  };
  final site = switch (diagnostic.site) {
    BrowserDiagnosticSite.jw => '教务',
    BrowserDiagnosticSite.young => '二课',
    BrowserDiagnosticSite.passport => 'Passport',
    BrowserDiagnosticSite.identity => '统一身份认证',
    BrowserDiagnosticSite.ucas => 'UCAS 认证',
    BrowserDiagnosticSite.gateway => '认证网关',
    BrowserDiagnosticSite.fixture => '本机合成页面',
    BrowserDiagnosticSite.unknown => '未登记目标',
  };
  return '$action · $site · ${diagnostic.scheme.name.toUpperCase()}';
}

String _messageForFailure(
  FailureCode code, {
  required _ActionFallback fallback,
}) {
  if (code == FailureCode.busy) return _busyMessage;
  if (code == FailureCode.cleanupPending ||
      fallback == _ActionFallback.cleanup) {
    return _cleanupMessage;
  }
  if (code == FailureCode.sourceFailed) return _sourceMessage;
  return _fallbackMessage(fallback);
}

const _busyMessage = '当前有其他作业正在处理，请稍后重试。';
const _cleanupMessage = '清理未完成，请重试清理。';
const _sourceMessage = '教务页面操作失败，请检查页面后重试。';

String _fallbackMessage(_ActionFallback fallback) => switch (fallback) {
  _ActionFallback.source => _sourceMessage,
  _ActionFallback.cleanup => _cleanupMessage,
};

String? _displayableOrigin(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final candidate = value.trim();
  final Uri? uri;
  if (candidate.contains('://')) {
    uri = Uri.tryParse(candidate);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return null;
  } else {
    if (RegExp(r'[/\\?#@]').hasMatch(candidate)) return null;
    uri = Uri.tryParse('https://$candidate');
  }
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (!RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  ).hasMatch(host)) {
    return null;
  }
  return host;
}
