import 'package:flutter/material.dart';

import '../core/onboarding_contract.dart';
import '../core/reminder_contract.dart';
import 'agent_settings_panel.dart';
import 'agent_workspace_contract.dart';
import 'app_design.dart';
import 'app_shell_contract.dart';
import 'onboarding_controller.dart';
import 'onboarding_permissions_step.dart';
import 'onboarding_source_step.dart';
import 'settings_contract.dart';

/// Four short, resumable forms. Only page progress is stored here; domain
/// controllers still own identity, imports, model verification and consent.
final class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.progress,
    required this.shell,
    required this.settings,
    required this.agent,
    required this.reminders,
    required this.reminderChanges,
    required this.initialReminderView,
    this.configureSystemAccess,
    this.logsBuilder,
  });
  final OnboardingController progress;
  final AppShellPort shell;
  final ApplicationSettingsPort settings;
  final AgentWorkspacePort agent;
  final ReminderDataPort reminders;
  final Stream<ReminderRuntimeView> reminderChanges;
  final ReminderRuntimeView initialReminderView;
  final Future<void> Function(NotificationAccessAction)? configureSystemAccess;
  final WidgetBuilder? logsBuilder;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  bool _savePassword = false, _childBusy = false;
  bool _stoppingModel = false, _modelStopFailed = false;
  OnboardingStep? _visibleStep;

  @override
  void didUpdateWidget(covariant OnboardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.progress, widget.progress) ||
        !identical(oldWidget.shell, widget.shell)) {
      _clearDraft();
      _visibleStep = null;
      _childBusy = false;
      _stoppingModel = false;
      _modelStopFailed = false;
    }
  }

  void _clearDraft() {
    _account.clear();
    _password.clear();
    _savePassword = false;
  }

  @override
  void dispose() {
    _clearDraft();
    _account.dispose();
    _password.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy =>
      widget.progress.pending ||
      widget.shell.view.globallyBusy ||
      widget.shell.view.actionPending ||
      widget.shell.view.progressUnavailable ||
      widget.agent.view.busy ||
      _stoppingModel ||
      _childBusy;

  Future<void> _stopModel() async {
    if (_stoppingModel || !widget.agent.view.busy) return;
    final port = widget.agent;
    final progress = widget.progress;
    setState(() {
      _stoppingModel = true;
      _modelStopFailed = false;
    });
    try {
      await port.stop();
    } on Object {
      if (mounted &&
          identical(widget.agent, port) &&
          identical(widget.progress, progress)) {
        setState(() => _modelStopFailed = true);
      }
    } finally {
      if (mounted &&
          identical(widget.agent, port) &&
          identical(widget.progress, progress)) {
        setState(() => _stoppingModel = false);
      }
    }
  }

  void _childBusyChanged(bool value) {
    if (mounted && value != _childBusy) setState(() => _childBusy = value);
  }

  Future<void> _go(OnboardingStep step) async {
    if (_busy) return;
    final old = widget.progress.snapshot?.step;
    FocusManager.instance.primaryFocus?.unfocus();
    if (await widget.progress.navigate(step)) {
      if (!mounted) return;
      // Credentials are a short-lived draft for the two school steps only.
      if (old == OnboardingStep.sync &&
          step.index > OnboardingStep.sync.index) {
        _clearDraft();
      }
      _childBusy = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  Future<void> _defer() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (await widget.progress.defer()) {
      if (mounted) _clearDraft();
    }
  }

  Future<void> _next(OnboardingStep step, {bool skip = false}) async {
    if (_busy) return;
    if (step == OnboardingStep.account &&
        !skip &&
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    if (step == OnboardingStep.account && skip) _clearDraft();
    if (step == OnboardingStep.permissions) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (await widget.progress.complete()) {
        if (mounted) _clearDraft();
      }
    } else {
      await _go(OnboardingStep.values[step.index + 1]);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.progress, widget.shell, widget.agent]),
    builder: (context, _) {
      final progress = widget.progress;
      final snapshot = progress.snapshot;
      final step = snapshot?.step ?? OnboardingStep.account;
      if (_visibleStep != step) {
        _visibleStep = step;
        _childBusy = false;
      }
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (popped, _) {
          if (!popped && !_busy && !progress.loading && !progress.failure) {
            if (step.index > 0) {
              _go(OnboardingStep.values[step.index - 1]);
            } else {
              _defer();
            }
          }
        },
        child: Scaffold(
          backgroundColor: AppUi.canvas,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final padding = constraints.maxWidth < 500 ? 20.0 : 40.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            padding,
                            16,
                            padding,
                            12,
                          ),
                          child: Row(
                            children: [
                              Image.asset(
                                'assets/branding/ustc_assistant_icon_concept_v1.png',
                                width: 36,
                                height: 36,
                                excludeFromSemantics: true,
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'USTC Assistant',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (!progress.loading && !progress.failure)
                                TextButton(
                                  key: const ValueKey('setup-defer'),
                                  onPressed: _busy ? null : _defer,
                                  child: const Text('稍后设置'),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _scroll,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              24,
                              padding,
                              24,
                            ),
                            child: progress.loading
                                ? const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(32),
                                      child: CircularProgressIndicator(),
                                    ),
                                  )
                                : progress.failure
                                ? _loadFailure(context)
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        '${step.index + 1} / 4 · 首次设置',
                                        style: const TextStyle(
                                          color: AppUi.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _title(step),
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _description(step),
                                        style: const TextStyle(
                                          color: AppUi.muted,
                                          height: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      KeyedSubtree(
                                        key: ValueKey(step),
                                        child: _body(step),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                        if (!progress.loading && !progress.failure) ...[
                          const Divider(height: 1),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              12,
                              padding,
                              16,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_busy) ...[
                                  const Text(
                                    '请先完成或取消当前操作，再继续设置。',
                                    style: TextStyle(color: AppUi.muted),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                if (step == OnboardingStep.model &&
                                    widget.agent.view.busy)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      key: const ValueKey('setup-stop-model'),
                                      onPressed: _stoppingModel
                                          ? null
                                          : _stopModel,
                                      icon: const Icon(
                                        Icons.stop_circle_outlined,
                                      ),
                                      label: Text(
                                        _stoppingModel ? '正在取消…' : '取消模型操作',
                                      ),
                                    ),
                                  ),
                                if (_modelStopFailed)
                                  const Text(
                                    '暂未能取消，请稍后再试。',
                                    style: TextStyle(color: AppUi.error),
                                  ),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.end,
                                  children: [
                                    if (step.index > 0)
                                      TextButton(
                                        key: const ValueKey('setup-back'),
                                        onPressed: _busy
                                            ? null
                                            : () => _go(
                                                OnboardingStep
                                                    .values[step.index - 1],
                                              ),
                                        child: const Text('上一步'),
                                      ),
                                    TextButton(
                                      key: const ValueKey('setup-skip'),
                                      onPressed: _busy
                                          ? null
                                          : () => _next(step, skip: true),
                                      child: Text(
                                        step == OnboardingStep.permissions
                                            ? '保持当前选择'
                                            : '跳过这步',
                                      ),
                                    ),
                                    FilledButton(
                                      key: const ValueKey('setup-next'),
                                      onPressed: _busy
                                          ? null
                                          : () => _next(step),
                                      child: Text(
                                        step == OnboardingStep.permissions
                                            ? '开始使用'
                                            : '下一步',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _loadFailure(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('暂时无法保存或读取设置进度，已完成的登录、同步和授权不会撤销。'),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: widget.progress.pending ? null : widget.progress.refresh,
        child: const Text('重试读取进度'),
      ),
      if (widget.logsBuilder != null) widget.logsBuilder!(context),
    ],
  );

  Widget _body(OnboardingStep step) => switch (step) {
    OnboardingStep.account => Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.shell.view.accountBound) ...[
            const Text('学校账号已绑定。密码留空即可使用本机已保存的密码。'),
            const SizedBox(height: 16),
          ],
          TextFormField(
            key: const ValueKey('setup-account'),
            controller: _account,
            enabled: !widget.shell.view.accountBound,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '学号或工号',
              helperText: widget.shell.view.accountBound
                  ? '本机已有绑定，无需重复填写。'
                  : '首次同步时校验学校身份',
            ),
            validator: (value) {
              final code = value?.trim() ?? '';
              if (code.isEmpty && widget.shell.view.accountBound) return null;
              return RegExp(r'^[A-Za-z0-9]{3,32}$').hasMatch(code)
                  ? null
                  : '请输入学号或工号，也可以跳过这步。';
            },
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('setup-password'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '学校密码（可选）',
              helperText: '留空时可在学校窗口手动登录',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _savePassword,
            onChanged: _busy
                ? null
                : (value) => setState(() => _savePassword = value ?? false),
            title: const Text('同步成功后加密保存在本机'),
            subtitle: const Text('教务与二课共用，之后可自动登录。学校窗口手填的密码不会被读取或保存。'),
          ),
          const SizedBox(height: 12),
          const Text(
            '下一步才会打开学校登录页；验证码和学校额外授权由你完成。',
            style: TextStyle(color: AppUi.muted),
          ),
        ],
      ),
    ),
    OnboardingStep.sync => OnboardingSourceStep(
      controller: widget.shell,
      account: () => _account.text.trim().isEmpty ? null : _account.text.trim(),
      password: () => _password.text.isEmpty ? null : _password.text,
      savePassword: () => _savePassword,
      today: () => widget.shell.today,
      onBusyChanged: _childBusyChanged,
    ),
    OnboardingStep.model => AgentSettingsPanel(
      controller: widget.agent,
      setupMode: true,
      onBusyChanged: _childBusyChanged,
    ),
    OnboardingStep.permissions => OnboardingPermissionsStep(
      settings: widget.settings,
      agent: widget.agent,
      reminders: widget.reminders,
      reminderChanges: widget.reminderChanges,
      initialReminderView: widget.initialReminderView,
      configureSystemAccess: widget.configureSystemAccess,
      onBusyChanged: _childBusyChanged,
    ),
  };

  static String _title(OnboardingStep step) => switch (step) {
    OnboardingStep.account => '先连上你的学校账号',
    OnboardingStep.sync => '把课表和二课带进来',
    OnboardingStep.model => '选一个模型来帮忙',
    OnboardingStep.permissions => '决定它能帮你做什么',
  };
  static String _description(OnboardingStep step) => switch (step) {
    OnboardingStep.account => '教务与二课使用同一个学校账号，无需另外注册。',
    OnboardingStep.sync => '两项可分别同步或稍后再做。学校数据只读，已保存的日程会保留。',
    OnboardingStep.model => '支持学校服务与 DeepSeek 官方服务。Key 只在应用中填写，验证后加密保存在本机。',
    OnboardingStep.permissions => '每项都由你选择，随时可以在设置中修改。关闭某项也能继续使用其他功能。',
  };
}
