import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/knowledge_contract.dart';
import '../core/application_version.dart';
import '../core/young_daily_sync_contract.dart';
import 'app_shell_contract.dart';
import 'settings_contract.dart';
import 'source_settings_page.dart';

const _settingsMuted = Color(0xFF66736C);

enum _SettingsSection { sources, agent, reminders, display, dataPrivacy, about }

/// Formal settings projection for the existing source and local settings ports.
///
/// The page owns no source, preference, knowledge, or maintenance state. Every
/// write carries the snapshot context that was visible when the user acted.
final class ApplicationSettingsPage extends StatefulWidget {
  const ApplicationSettingsPage({
    super.key,
    required this.settings,
    required this.controller,
    this.diagnosticsBuilder,
    this.agentBuilder,
    this.remindersBuilder,
    this.logsBuilder,
    this.dailySync,
  });

  final ApplicationSettingsPort settings;
  final AppShellPort controller;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? agentBuilder;
  final WidgetBuilder? remindersBuilder;
  final WidgetBuilder? logsBuilder;
  final YoungDailySyncControlPort? dailySync;

  @override
  State<ApplicationSettingsPage> createState() =>
      _ApplicationSettingsPageState();
}

final class _ApplicationSettingsPageState
    extends State<ApplicationSettingsPage> {
  _SettingsSection _section = _SettingsSection.sources;
  int _generation = 0;
  bool _localPending = false;
  bool _cancelPending = false;
  SettingsFailureCode? _localFailure;
  DisplayPreferences? _preferenceDraft;
  SettingsContext? _preferenceDraftContext;

  @override
  void initState() {
    super.initState();
    _scheduleInitialRefresh();
  }

  @override
  void didUpdateWidget(covariant ApplicationSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings) ||
        !identical(oldWidget.controller, widget.controller)) {
      _generation++;
      _localPending = false;
      _cancelPending = false;
      _localFailure = null;
      _preferenceDraft = null;
      _preferenceDraftContext = null;
      if (!identical(oldWidget.settings, widget.settings)) {
        _scheduleInitialRefresh();
      }
    }
  }

  void _scheduleInitialRefresh() {
    final port = widget.settings;
    final generation = _generation;
    scheduleMicrotask(() {
      if (_sameInstallation(port, generation)) {
        unawaited(_refresh(port, generation));
      }
    });
  }

  Future<void> _refresh(ApplicationSettingsPort port, int generation) async {
    try {
      await port.refreshSettings();
    } on Object {
      if (_sameInstallation(port, generation)) {
        setState(() => _localFailure = SettingsFailureCode.storageFailed);
      }
    }
  }

  bool _sameInstallation(ApplicationSettingsPort port, int generation) =>
      mounted && identical(widget.settings, port) && _generation == generation;

  bool _sameSnapshot(
    ApplicationSettingsPort port,
    int generation,
    SettingsContext context,
  ) =>
      _sameInstallation(port, generation) &&
      port.settingsView.snapshot?.context == context;

  bool _canStart(
    ApplicationSettingsPort port,
    int generation,
    SettingsContext context,
  ) {
    if (!_sameSnapshot(port, generation, context) || _localPending) {
      return false;
    }
    final view = port.settingsView;
    final shell = widget.controller.view;
    return view.canWrite &&
        !shell.globallyBusy &&
        !shell.actionPending &&
        !shell.progressUnavailable;
  }

  void _selectSection(_SettingsSection next) {
    if (next == _section) return;
    setState(() {
      _section = next;
      _localFailure = null;
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.settings,
    builder: (context, _) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final view = widget.settings.settingsView;
        final snapshot = view.snapshot;
        final preferences =
            snapshot != null && _preferenceDraftContext == snapshot.context
            ? _preferenceDraft ?? snapshot.preferences
            : snapshot?.preferences;
        final writable =
            snapshot != null &&
            _canStart(widget.settings, _generation, snapshot.context);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '设置',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              key: const ValueKey('settings-sections-scroll'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _sectionChip(
                    _SettingsSection.sources,
                    '来源',
                    Icons.school_outlined,
                  ),
                  const SizedBox(width: 8),
                  if (widget.agentBuilder != null)
                    _sectionChip(
                      _SettingsSection.agent,
                      'Agent',
                      Icons.auto_awesome_outlined,
                    ),
                  if (widget.agentBuilder != null) const SizedBox(width: 8),
                  if (widget.remindersBuilder != null)
                    _sectionChip(
                      _SettingsSection.reminders,
                      '晨报与提醒',
                      Icons.notifications_active_outlined,
                    ),
                  if (widget.remindersBuilder != null) const SizedBox(width: 8),
                  _sectionChip(
                    _SettingsSection.display,
                    '显示',
                    Icons.tune_rounded,
                  ),
                  const SizedBox(width: 8),
                  _sectionChip(
                    _SettingsSection.dataPrivacy,
                    '数据与隐私',
                    Icons.shield_outlined,
                  ),
                  const SizedBox(width: 8),
                  _sectionChip(
                    _SettingsSection.about,
                    '关于',
                    Icons.info_outline,
                  ),
                ],
              ),
            ),
            if (_localFailure != null || view.failure != null) ...[
              const SizedBox(height: 8),
              _SettingsNotice(
                message: _settingsFailureMessage(
                  _localFailure ?? view.failure!,
                ),
                isError: true,
              ),
            ],
            if (snapshot != null &&
                !writable &&
                _section != _SettingsSection.sources &&
                _section != _SettingsSection.agent &&
                _section != _SettingsSection.reminders) ...[
              const SizedBox(height: 8),
              const _SettingsNotice(message: '本机有操作或恢复正在进行；新的设置操作暂不可用。'),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: switch (_section) {
                _SettingsSection.sources => SourceSettingsPage(
                  dailySync: widget.dailySync,
                  key: const ValueKey('application-settings-sources'),
                  controller: widget.controller,
                  diagnosticsBuilder: widget.diagnosticsBuilder,
                ),
                _SettingsSection.agent =>
                  widget.agentBuilder?.call(context) ??
                      _loadingSection('模型设置尚未装配。'),
                _SettingsSection.reminders =>
                  widget.remindersBuilder?.call(context) ??
                      _loadingSection('晨报与提醒尚未装配。'),
                _SettingsSection.display => _displaySection(
                  context,
                  preferences,
                  snapshot?.context,
                  writable,
                ),
                _SettingsSection.dataPrivacy => _dataPrivacySection(
                  context,
                  view,
                  snapshot,
                  writable,
                ),
                _SettingsSection.about => _aboutSection(),
              },
            ),
          ],
        );
      },
    ),
  );

  Widget _sectionChip(_SettingsSection section, String label, IconData icon) =>
      ChoiceChip(
        key: ValueKey('settings-section-${section.name}'),
        selected: _section == section,
        avatar: Icon(icon, size: 18),
        label: Text(label),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) => _selectSection(section),
      );

  Widget _displaySection(
    BuildContext context,
    DisplayPreferences? preferences,
    SettingsContext? settingsContext,
    bool writable,
  ) {
    if (preferences == null || settingsContext == null) {
      return _loadingSection('正在读取显示设置…');
    }
    return _sectionScroll(
      children: [
        _SettingsCard(
          title: '默认日程视图',
          subtitle: '保存后立即应用，并在下次启动时保留。',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('settings-calendar-view-day'),
                label: const Text('日视图'),
                selected: preferences.calendarView == DefaultCalendarView.day,
                onSelected: writable
                    ? (_) => _savePreferences(
                        DisplayPreferences(
                          calendarView: DefaultCalendarView.day,
                          includeInactive: preferences.includeInactive,
                        ),
                        settingsContext,
                      )
                    : null,
              ),
              ChoiceChip(
                key: const ValueKey('settings-calendar-view-week'),
                label: const Text('周视图'),
                selected: preferences.calendarView == DefaultCalendarView.week,
                onSelected: writable
                    ? (_) => _savePreferences(
                        DisplayPreferences(
                          calendarView: DefaultCalendarView.week,
                          includeInactive: preferences.includeInactive,
                        ),
                        settingsContext,
                      )
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SettingsCard(
          title: '默认显示隐藏、跳过及来源失效历史',
          subtitle: '开启后，打开日程时会同时显示隐藏、跳过和已退出有效日程的历史记录。',
          child: SwitchListTile.adaptive(
            key: const ValueKey('settings-include-inactive'),
            contentPadding: EdgeInsets.zero,
            title: const Text('显示隐藏、跳过及来源失效历史'),
            value: preferences.includeInactive,
            onChanged: writable
                ? (value) => _savePreferences(
                    DisplayPreferences(
                      calendarView: preferences.calendarView,
                      includeInactive: value,
                    ),
                    settingsContext,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        const _SettingsCard(
          title: '固定规则',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('所有日期和时刻均使用北京时间（UTC+8）。'),
              SizedBox(height: 6),
              Text('周视图从周一开始；默认主题与 Agent 入口固定。'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _savePreferences(
    DisplayPreferences preferences,
    SettingsContext context,
  ) async {
    final port = widget.settings;
    final generation = _generation;
    if (!_canStart(port, generation, context)) return;
    setState(() {
      _preferenceDraft = preferences;
      _preferenceDraftContext = context;
      _localPending = true;
      _localFailure = null;
    });
    try {
      await port.saveDisplayPreferences(context, preferences);
      if (_sameSnapshot(port, generation, context)) {
        setState(() {
          _preferenceDraft = null;
          _preferenceDraftContext = null;
        });
      }
    } on Object catch (error) {
      if (_sameSnapshot(port, generation, context)) {
        setState(() {
          _preferenceDraft = null;
          _preferenceDraftContext = null;
          _localFailure = _failureCode(error);
        });
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _localPending = false);
      }
    }
  }

  Widget _dataPrivacySection(
    BuildContext context,
    ApplicationSettingsView view,
    SettingsSnapshot? snapshot,
    bool writable,
  ) {
    if (snapshot == null) return _loadingSection('正在读取本地状态…');
    final counts = snapshot.counts;
    return _sectionScroll(
      children: [
        if (widget.logsBuilder != null) ...[
          widget.logsBuilder!.call(context),
          const SizedBox(height: 12),
        ],
        _SettingsCard(
          title: '账号与本机凭据',
          subtitle: '此处仅显示是否已登记，不读取账号内容或密码。',
          footer: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('settings-open-sources'),
              onPressed: () => _selectSection(_SettingsSection.sources),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('前往来源设置'),
            ),
          ),
          child: Column(
            children: [
              _StatusLine(
                label: '学校账号',
                value: snapshot.accountBound ? '已绑定' : '未绑定',
              ),
              _StatusLine(
                label: '加密学校密码',
                value: snapshot.credentialSaved ? '已保存' : '未保存',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SettingsCard(
          title: '本机数据计数',
          subtitle: '包含隐藏、删除后仍保留的记录，用于核对维护范围。',
          child: Column(
            children: [
              _StatusLine(label: '教务课程', value: '${counts.jwCourses}'),
              _StatusLine(label: '教务考试', value: '${counts.jwExams}'),
              _StatusLine(label: '二课日程', value: '${counts.young}'),
              _StatusLine(label: '个人安排', value: '${counts.personal}'),
              _StatusLine(label: '任务', value: '${counts.tasks}'),
              _StatusLine(label: '规划时间块', value: '${counts.blocks}'),
              _StatusLine(label: '资料项', value: '${counts.materials}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _knowledgeCard(context, view, snapshot, writable),
        const SizedBox(height: 12),
        _consentCard(context, snapshot, writable),
        const SizedBox(height: 12),
        _maintenanceCard(context, snapshot, writable),
      ],
    );
  }

  Widget _knowledgeCard(
    BuildContext context,
    ApplicationSettingsView view,
    SettingsSnapshot snapshot,
    bool writable,
  ) {
    final outcome = view.loadOutcome;
    final loading = view.knowledgeLoading;
    return _SettingsCard(
      title: '精选资料',
      subtitle: '首批固定载入 7 项，仅管理本地资料；此处没有搜索或阅读入口。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusLine(label: '当前资料项', value: '${snapshot.counts.materials}'),
          const SizedBox(height: 8),
          if (loading)
            const _SettingsNotice(message: '正在载入固定资料版本；可以取消当前载入。')
          else if (outcome != null)
            _KnowledgeOutcomeNotice(outcome: outcome)
          else
            const Text('尚无本次载入结果。', style: TextStyle(color: _settingsMuted)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('settings-load-knowledge'),
                onPressed: writable
                    ? () => _loadKnowledge(snapshot.context)
                    : null,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('载入首批资料'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-cancel-knowledge'),
                onPressed: loading && !_cancelPending
                    ? _cancelKnowledgeLoad
                    : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('取消载入'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-clear-knowledge'),
                onPressed: writable
                    ? () => _clearKnowledge(context, snapshot.context)
                    : null,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清空资料库'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _consentCard(
    BuildContext context,
    SettingsSnapshot snapshot,
    bool writable,
  ) => _SettingsCard(
    title: '评课联网授权',
    subtitle: '设置不会查询网站；授权只供现有评课查询使用。',
    child: SwitchListTile.adaptive(
      key: const ValueKey('settings-icourse-consent'),
      contentPadding: EdgeInsets.zero,
      title: const Text('允许评课联网查询'),
      subtitle: const Text('查询只发送完成查询所必要的课程或教师关键词。'),
      value: snapshot.icourseConsent,
      onChanged: writable
          ? (allowed) => _changeConsent(context, snapshot.context, allowed)
          : null,
    ),
  );

  Widget _maintenanceCard(
    BuildContext context,
    SettingsSnapshot snapshot,
    bool writable,
  ) => _SettingsCard(
    title: '维护数据',
    subtitle: '每项操作都固定列出删除与保留范围，并需要两次确认。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('settings-clear-agenda'),
          onPressed: writable
              ? () => _runMaintenance(
                  context,
                  snapshot.context,
                  MaintenanceKind.agenda,
                )
              : null,
          icon: const Icon(Icons.event_busy_outlined, size: 18),
          label: const Text('清空日程与任务'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('settings-reset'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: writable
              ? () => _runMaintenance(
                  context,
                  snapshot.context,
                  MaintenanceKind.reset,
                )
              : null,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('完全重置本应用数据'),
        ),
      ],
    ),
  );

  Future<void> _loadKnowledge(SettingsContext context) async {
    final port = widget.settings;
    final generation = _generation;
    if (!_canStart(port, generation, context)) return;
    setState(() {
      _localPending = true;
      _localFailure = null;
    });
    try {
      await port.loadKnowledge();
    } on Object catch (error) {
      if (_sameSnapshot(port, generation, context)) {
        setState(() => _localFailure = _failureCode(error));
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _localPending = false);
      }
    }
  }

  Future<void> _cancelKnowledgeLoad() async {
    final port = widget.settings;
    final generation = _generation;
    final snapshot = port.settingsView.snapshot;
    final contextGuard = snapshot?.context;
    if (!_sameInstallation(port, generation) ||
        !port.settingsView.knowledgeLoading ||
        _cancelPending) {
      return;
    }
    setState(() {
      _cancelPending = true;
      _localFailure = null;
    });
    try {
      await port.cancelKnowledgeLoad();
    } on Object catch (error) {
      final stillCurrent = contextGuard == null
          ? _sameInstallation(port, generation) &&
                port.settingsView.knowledgeLoading
          : _sameSnapshot(port, generation, contextGuard);
      if (stillCurrent) {
        setState(() => _localFailure = _failureCode(error));
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _cancelPending = false);
      }
    }
  }

  Future<void> _clearKnowledge(
    BuildContext dialogContext,
    SettingsContext context,
  ) async {
    final port = widget.settings;
    final generation = _generation;
    if (!_canStart(port, generation, context)) return;
    final confirmed = await _confirmTwoStages(
      dialogContext: dialogContext,
      port: port,
      generation: generation,
      context: context,
      title: '清空本地资料库？',
      scope:
          '将清理本地资料文本、片段与索引、载入批次和回执，以及当前引用。\n\n'
          '学校与个人日程、任务、学校密码、账号、目录、来源许可、模型 Key 和对话历史会保留。'
          '清理会先排空资料载入；迟到的载入结果不会重新写回。',
      finalTitle: '再次确认清空资料',
      finalAction: '确认清空资料',
    );
    if (!confirmed || !_canStart(port, generation, context)) return;
    setState(() {
      _localPending = true;
      _localFailure = null;
    });
    try {
      await port.clearKnowledge(context, confirmed: true);
    } on Object catch (error) {
      if (_sameSnapshot(port, generation, context)) {
        setState(() => _localFailure = _failureCode(error));
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _localPending = false);
      }
    }
  }

  Future<void> _runMaintenance(
    BuildContext dialogContext,
    SettingsContext context,
    MaintenanceKind kind,
  ) async {
    final port = widget.settings;
    final generation = _generation;
    if (!_canStart(port, generation, context)) return;
    final isReset = kind == MaintenanceKind.reset;
    final confirmed = await _confirmTwoStages(
      dialogContext: dialogContext,
      port: port,
      generation: generation,
      context: context,
      title: isReset ? '完全重置本应用数据？' : '清空日程与任务？',
      scope: isReset
          ? '将删除本应用保存的账号、共享密码、来源目录与成功范围、日程和覆盖、'
                '个人安排与例外、任务与时间块、关系、撤销状态、资料库、旧审计回执、'
                '模型 Key、模型配置和对话历史、联网同意、显示偏好及本应用正式/观测登记的来源分区。\n\n'
                '保留安装文件、数据库容器、目录所有权、单调世代与 ID 高水位及最小恢复账本。'
                '不会删除旧工程、系统浏览器或任意目录。重置完成后回到默认 Agent，可重新绑定账号。'
          : '将删除教务与二课日程及覆盖、个人安排与例外、任务与时间块、关系、撤销状态，'
                '以及相关作业、回执和审计记录。\n\n'
                '账号、共享密码、来源目录与成功学期/日期范围、来源分区与许可、资料库、'
                '模型 Key、模型配置、对话历史、联网同意和显示偏好会保留。清空日程不会删除密码。',
      finalTitle: isReset ? '再次确认完全重置' : '再次确认清空日程与任务',
      finalAction: isReset ? '确认完全重置' : '确认清空日程与任务',
    );
    if (!confirmed || !_canStart(port, generation, context)) return;
    setState(() {
      _localPending = true;
      _localFailure = null;
    });
    try {
      await port.runMaintenance(context, kind, confirmed: true);
    } on Object catch (error) {
      if (_sameSnapshot(port, generation, context)) {
        setState(() => _localFailure = _failureCode(error));
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _localPending = false);
      }
    }
  }

  Future<void> _changeConsent(
    BuildContext dialogContext,
    SettingsContext context,
    bool allowed,
  ) async {
    final port = widget.settings;
    final generation = _generation;
    if (!_canStart(port, generation, context)) return;
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('settings-consent-confirmation'),
        title: Text(allowed ? '开启评课联网授权？' : '关闭评课联网授权？'),
        content: Text(
          allowed
              ? '开启后，现有评课查询仅发送完成查询所必要的课程或教师关键词。'
                    '设置不会联网查询；关闭授权会使相应查询许可失效。'
              : '关闭后，评课联网查询授权会失效。设置不会联网查询，也不会删除本地资料。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(allowed ? '开启授权' : '关闭授权'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_canStart(port, generation, context)) return;
    setState(() {
      _localPending = true;
      _localFailure = null;
    });
    try {
      await port.setIcourseConsent(context, allowed: allowed, confirmed: true);
    } on Object catch (error) {
      if (_sameSnapshot(port, generation, context)) {
        setState(() => _localFailure = _failureCode(error));
      }
    } finally {
      if (_sameInstallation(port, generation)) {
        setState(() => _localPending = false);
      }
    }
  }

  Future<bool> _confirmTwoStages({
    required BuildContext dialogContext,
    required ApplicationSettingsPort port,
    required int generation,
    required SettingsContext context,
    required String title,
    required String scope,
    required String finalTitle,
    required String finalAction,
  }) async {
    final first = await showDialog<bool>(
      context: dialogContext,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('settings-confirm-first'),
        title: Text(title),
        content: Text(scope),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('继续确认'),
          ),
        ],
      ),
    );
    if (!dialogContext.mounted ||
        !_canStart(port, generation, context) ||
        first != true) {
      return false;
    }

    final second = await showDialog<bool>(
      context: dialogContext,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('settings-confirm-final'),
        title: Text(finalTitle),
        content: const Text('请再次确认上述固定范围。操作提交后不能撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(finalAction),
          ),
        ],
      ),
    );
    return second == true && _canStart(port, generation, context);
  }

  Widget _aboutSection() => _sectionScroll(
    children: [
      _SettingsCard(
        title: 'USTC Assistant · $applicationDisplayVersion',
        child: Text(
          '工程版本 $applicationVersion · ${defaultTargetPlatform == TargetPlatform.android ? 'Android 开发验证版' : 'Windows x64 私有交付版'}',
        ),
      ),
      const SizedBox(height: 12),
      const _SettingsCard(
        title: '本地优先',
        child: Text('日程、任务和设置保存在本机。学校来源保持只读；联网功能仅在相应授权后由明确操作使用。'),
      ),
      const SizedBox(height: 12),
      const _SettingsCard(
        title: 'Agent 状态',
        child: Text('连接学校模型服务后，可用对话查询、规划日程和管理个人安排。修改按你的许可执行，学校来源保持只读。'),
      ),
      const SizedBox(height: 12),
      const _SettingsCard(
        title: '时间与显示',
        child: Text('时间固定为北京时间，周视图从周一开始。主题和默认 Agent 入口固定。'),
      ),
    ],
  );

  Widget _loadingSection(String message) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: _SettingsNotice(message: message),
    ),
  );

  Widget _sectionScroll({required List<Widget> children}) =>
      SingleChildScrollView(
        key: ValueKey('settings-section-${_section.name}-scroll'),
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      );
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(
              subtitle!,
              style: const TextStyle(color: _settingsMuted, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          child,
          if (footer != null) ...[const SizedBox(height: 10), footer!],
        ],
      ),
    ),
  );
}

final class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, softWrap: true)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

final class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({required this.message, this.isError = false});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.errorContainer : scheme.tertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: isError
                ? scheme.onErrorContainer
                : scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, softWrap: true)),
        ],
      ),
    );
  }
}

final class _KnowledgeOutcomeNotice extends StatelessWidget {
  const _KnowledgeOutcomeNotice({required this.outcome});
  final KnowledgeLoadOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final message = switch (outcome.state) {
      KnowledgeLoadState.done =>
        '载入完成：新增 ${outcome.accepted} 项，未变化 ${outcome.unchanged} 项，共 ${outcome.total} 项。',
      KnowledgeLoadState.cancelled =>
        '载入已取消：已处理 ${outcome.accepted + outcome.unchanged} 项，共 ${outcome.total} 项。',
      KnowledgeLoadState.failed =>
        '载入未完成：已处理 ${outcome.accepted + outcome.unchanged} 项，共 ${outcome.total} 项；请以当前计数为准。',
    };
    return _SettingsNotice(
      message: message,
      isError: outcome.state == KnowledgeLoadState.failed,
    );
  }
}

String _settingsFailureMessage(SettingsFailureCode code) => switch (code) {
  SettingsFailureCode.busy => '另一项本地操作正在进行，请稍后再试。',
  SettingsFailureCode.staleContext => '设置状态已更新，请重新打开并确认这项操作。',
  SettingsFailureCode.confirmationRequired => '确认状态已失效，请重新确认这项操作。',
  SettingsFailureCode.invalidIntent => '这项本地操作无法处理。',
  SettingsFailureCode.storageFailed => '本地保存或维护失败；已有数据状态以当前计数为准。',
  SettingsFailureCode.cleanupPending => '维护尚未完成，请重试恢复。',
  SettingsFailureCode.ownershipLost => '本机数据状态已变化，请重新打开应用后查看。',
  SettingsFailureCode.closed => '应用状态已关闭，请重新打开应用。',
};

SettingsFailureCode _failureCode(Object error) =>
    error is SettingsFailure ? error.code : SettingsFailureCode.storageFailed;
