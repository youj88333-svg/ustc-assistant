import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../jobs/observation_port.dart';
import '../source/observation_contract.dart';
import '../source/young_observation_contract.dart';

/// The M2.1 page exposes browser observation only. It never treats page
/// readiness or visible structure as proof of a Young business identity.
class YoungObservationPanel extends StatefulWidget {
  const YoungObservationPanel({super.key, required this.controller});

  final YoungObservationPort controller;

  @override
  State<YoungObservationPanel> createState() => _YoungObservationPanelState();
}

class _YoungObservationPanelState extends State<YoungObservationPanel> {
  final Map<_YoungAction, int> _inFlight = {};
  int _nextToken = 0;
  int _nextCopyToken = 0;
  int? _activeCopyToken;
  int _controllerEpoch = 0;
  late ObservationView _view;
  late StreamSubscription<ObservationView> _subscription;
  String? _actionMessage;
  String? _copyStatus;
  bool _copying = false;

  @override
  void initState() {
    super.initState();
    _listenToController();
  }

  @override
  void didUpdateWidget(covariant YoungObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controllerEpoch++;
      unawaited(_subscription.cancel());
      _inFlight.clear();
      _actionMessage = null;
      _copyStatus = null;
      _invalidateCopy();
      _listenToController();
    }
  }

  void _listenToController() {
    final epoch = _controllerEpoch;
    _view = widget.controller.view;
    _subscription = widget.controller.changes.listen((view) {
      if (!_isCurrent(epoch)) return;
      setState(() {
        if (!identical(_view.youngInspection, view.youngInspection)) {
          _copyStatus = null;
          _invalidateCopy();
        }
        _view = view;
      });
    });
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _invalidateCopy();
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final epoch = _controllerEpoch;
    final inspection = view.youngInspection;
    final hasNonCancelAction = _inFlight.keys.any(
      (action) => action != _YoungAction.cancel,
    );
    final anyAction = _inFlight.isNotEmpty || _copying;
    final canOpen = view.phase == ObservationPhase.idle && !anyAction;
    final canInspectOrReturn =
        view.phase == ObservationPhase.open &&
        !hasNonCancelAction &&
        !_inFlight.containsKey(_YoungAction.cancel);
    final canCancel =
        (view.phase == ObservationPhase.opening ||
            view.phase == ObservationPhase.open) &&
        !_inFlight.containsKey(_YoungAction.cancel);
    final canRetryCleanup =
        view.phase == ObservationPhase.recovery && !anyAction;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: constraints.maxWidth < 560 ? 12 : 20,
          vertical: 12,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(constraints.maxWidth < 560 ? 16 : 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '二课接入验证',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '本轮只验证登录链和页面结构；业务身份、已报名日程采集和活动查询尚未启用。',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '请在二课窗口中手动输入学校登录信息。本入口不使用教务已保存的密码，也不执行报名、退出、签到或申报等业务操作。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '登录后可手动进入个人日程或活动列表，再检查页面结构。页面就绪不代表业务身份已核验。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_displayableSite(view.origin) case final site?) ...[
                      const SizedBox(height: 8),
                      Text('当前白名单站点：$site'),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (view.phase == ObservationPhase.idle)
                          FilledButton.icon(
                            onPressed: canOpen
                                ? () => unawaited(
                                    _perform(
                                      _YoungAction.open,
                                      fallback: _YoungFallback.observation,
                                      action: widget.controller.open,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.open_in_browser),
                            label: const Text('打开二课观测窗口'),
                          ),
                        if (view.phase == ObservationPhase.open) ...[
                          OutlinedButton.icon(
                            onPressed: canInspectOrReturn
                                ? () => unawaited(
                                    _perform(
                                      _YoungAction.inspect,
                                      fallback: _YoungFallback.observation,
                                      action:
                                          widget.controller.inspectYoungPage,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('检查二课页面结构'),
                          ),
                          OutlinedButton.icon(
                            onPressed: canInspectOrReturn
                                ? () => unawaited(
                                    _perform(
                                      _YoungAction.navigate,
                                      fallback: _YoungFallback.observation,
                                      action: widget.controller.navigateInitial,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('回到二课入口'),
                          ),
                        ],
                        if (view.phase == ObservationPhase.opening ||
                            view.phase == ObservationPhase.open)
                          OutlinedButton.icon(
                            onPressed: canCancel
                                ? () => unawaited(
                                    _perform(
                                      _YoungAction.cancel,
                                      fallback: _YoungFallback.cleanup,
                                      action: widget.controller.closeSession,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('取消并清理二课窗口'),
                          ),
                        if (view.phase == ObservationPhase.recovery)
                          FilledButton.icon(
                            onPressed: canRetryCleanup
                                ? () => unawaited(
                                    _perform(
                                      _YoungAction.retryCleanup,
                                      fallback: _YoungFallback.cleanup,
                                      action: widget.controller.retryCleanup,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试二课清理'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _status(context, view),
                    if (inspection != null) ...[
                      const SizedBox(height: 14),
                      _inspection(context, inspection, epoch),
                    ],
                    if (view.diagnostics.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text('最近页面动作（仅显示类型和站点）'),
                      for (final diagnostic in view.diagnostics.skip(
                        view.diagnostics.length > 5
                            ? view.diagnostics.length - 5
                            : 0,
                      ))
                        Text(_diagnosticMessage(diagnostic)),
                    ],
                    if (hasNonCancelAction ||
                        _inFlight.containsKey(_YoungAction.cancel)) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_actionMessage != null) ...[
                      const SizedBox(height: 12),
                      _notice(context, _actionMessage!),
                    ] else if (view.failure != null) ...[
                      const SizedBox(height: 12),
                      _notice(context, _messageForFailure(view.failure!)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inspection(
    BuildContext context,
    YoungPageInspection inspection,
    int epoch,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '当前文档结构：${_surfaceLabel(inspection.surface)}',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text('业务身份未验证；此结果不启用日程同步或活动查询。'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              Text('表格：${inspection.tables}'),
              Text('日历根节点：${inspection.calendarRoots}'),
              Text('分页控件：${inspection.paginationControls}'),
              Text('密码输入框：${inspection.passwordInputs}'),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _copying
                  ? null
                  : () => unawaited(_copyInspection(inspection, epoch)),
              icon: const Icon(Icons.copy_outlined),
              label: Text(_copying ? '正在复制摘要' : '复制二课脱敏摘要'),
            ),
          ),
          if (_copyStatus != null) ...[
            const SizedBox(height: 8),
            Text(_copyStatus!),
          ],
        ],
      ),
    );
  }

  Future<void> _copyInspection(
    YoungPageInspection inspection,
    int epoch,
  ) async {
    if (!_isCurrent(epoch)) return;
    if (!identical(widget.controller.view.youngInspection, inspection)) {
      setState(() => _copyStatus = '页面已变化，请重新检查后复制摘要。');
      return;
    }
    final token = ++_nextCopyToken;
    _activeCopyToken = token;
    setState(() {
      _copying = true;
      _copyStatus = null;
    });
    try {
      final safeJson = jsonEncode(inspection.safeSummary());
      await Clipboard.setData(ClipboardData(text: safeJson));
      if (_isCurrent(epoch) &&
          _activeCopyToken == token &&
          identical(widget.controller.view.youngInspection, inspection)) {
        setState(() => _copyStatus = '已复制二课脱敏摘要。');
      }
    } catch (_) {
      if (_isCurrent(epoch) && _activeCopyToken == token) {
        setState(() => _copyStatus = '复制失败，请稍后重试。');
      }
    } finally {
      if (_isCurrent(epoch) && _activeCopyToken == token) {
        setState(() {
          _copying = false;
          _activeCopyToken = null;
        });
      }
    }
  }

  Widget _status(BuildContext context, ObservationView view) {
    final message = switch (view.phase) {
      ObservationPhase.idle => '二课观测窗口未打开或已清理。来源能力仍不可用。',
      ObservationPhase.closed => '二课观测端口已关闭，不能再次打开。来源能力仍不可用。',
      ObservationPhase.opening =>
        _inFlight.containsKey(_YoungAction.cancel)
            ? '正在请求取消并清理二课观测窗口。'
            : '正在打开二课观测窗口。',
      ObservationPhase.open when view.blocked => '页面操作被阻止；业务身份仍未验证，来源能力仍不可用。',
      ObservationPhase.open when view.ready => '页面已就绪，业务身份仍未验证，来源能力仍不可用。',
      ObservationPhase.open => '观测窗口已打开。页面就绪状态不能证明身份，来源能力仍不可用。',
      ObservationPhase.closing => '正在等待二课窗口及相关资源释放。',
      ObservationPhase.recovery => '二课清理未完成，浏览器资源仍可能占用；请重试清理。',
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
    _YoungAction actionType, {
    required _YoungFallback fallback,
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
        setState(
          () => _actionMessage = _messageForAction(failure.code, fallback),
        );
      }
    } catch (_) {
      if (_isCurrent(epoch)) {
        setState(() => _actionMessage = _fallbackMessage(fallback));
      }
    } finally {
      if (_isCurrent(epoch) && _inFlight[actionType] == token) {
        setState(() => _inFlight.remove(actionType));
      }
    }
  }

  bool _isCurrent(int epoch) => mounted && epoch == _controllerEpoch;

  void _invalidateCopy() {
    _nextCopyToken++;
    _activeCopyToken = null;
    _copying = false;
  }
}

enum _YoungAction { open, inspect, navigate, cancel, retryCleanup }

enum _YoungFallback { observation, cleanup }

String _surfaceLabel(YoungSurface surface) => switch (surface) {
  YoungSurface.unknown => '未知页面',
  YoungSurface.portal => '二课门户',
  YoungSurface.accessGate => '站点访问认证',
  YoungSurface.authentication => '登录认证页面',
  YoungSurface.application => '二课业务页面',
};

String? _displayableSite(String? value) {
  if (value == null) return null;
  final candidate = value.toLowerCase();
  const sites = <String, String>{
    'https://young.ustc.edu.cn': '二课',
    'https://passport.ustc.edu.cn': 'Passport',
    'https://id.ustc.edu.cn': '统一身份认证',
    'https://ucas.ustc.edu.cn': 'UCAS',
    'https://analytics.ustc.edu.cn': 'Analytics',
  };
  return sites[candidate];
}

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
    BrowserDiagnosticSite.ucas => 'UCAS',
    BrowserDiagnosticSite.gateway => '认证网关',
    BrowserDiagnosticSite.fixture => '本机合成页面',
    BrowserDiagnosticSite.unknown => '未登记目标',
  };
  final scheme = switch (diagnostic.scheme) {
    BrowserDiagnosticScheme.http => 'HTTP',
    BrowserDiagnosticScheme.https => 'HTTPS',
    BrowserDiagnosticScheme.other => '其它协议',
  };
  return '$action · $site · $scheme';
}

String _messageForAction(FailureCode code, _YoungFallback fallback) {
  if (code == FailureCode.cleanupPending ||
      fallback == _YoungFallback.cleanup) {
    return '清理未完成，请重试二课清理。';
  }
  return _messageForFailure(code);
}

String _messageForFailure(FailureCode code) => switch (code) {
  FailureCode.busy || FailureCode.ownerConflict => '当前有其他观测作业正在处理，请稍后重试。',
  FailureCode.cancelled => '二课观测操作已取消。',
  FailureCode.staleResult => '页面已变化，请重新检查页面结构。',
  FailureCode.incompleteSnapshot ||
  FailureCode.invalidSnapshot => '二课页面结构检查未通过，请重新检查。',
  FailureCode.idempotencyConflict => '当前页面与检查结果不匹配，请重新检查。',
  FailureCode.sourceFailed => '二课页面操作失败，请检查页面后重试。',
  FailureCode.storageFailed => '二课观测资源操作失败，请重试。',
  FailureCode.cleanupPending || FailureCode.followUpPending => '清理未完成，请重试二课清理。',
  FailureCode.unsafeDirectory ||
  FailureCode.ownershipLost => '二课观测资源不可用，请重试清理或重新打开。',
  FailureCode.unsupportedPlatform => '当前平台不支持二课观测。',
  FailureCode.closed => '二课观测窗口已关闭，请重新打开。',
};

String _fallbackMessage(_YoungFallback fallback) => switch (fallback) {
  _YoungFallback.observation => '二课页面操作失败，请检查页面后重试。',
  _YoungFallback.cleanup => '清理未完成，请重试二课清理。',
};
