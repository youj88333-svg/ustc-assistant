import 'package:flutter/material.dart';

import '../application/agent_configuration_service.dart';
import '../application/agent_permission_policy_service.dart';
import '../application/cancellation_signal.dart';
import '../data/drift_chat_repository.dart';
import '../data/protected_agent_secret_store.dart';
import '../domain/llm_protocol.dart';
import 'agent_permission_section.dart';
import 'agent_setup_panel.dart';

/// Maps a [LlmProtocolException] code to user-friendly Chinese copy that never
/// echoes the API key, the raw error, request headers, or response body.
///
/// `cancelled` returns null so callers can silently abort without surfacing an
/// error to the user.
String? safeErrorCopy(String code) {
  switch (code) {
    case 'auth_failed':
      return 'API Key 无效或已过期';
    case 'rate_limited':
      return '请求过于频繁，请稍后重试';
    case 'server_error':
      return '学校模型服务暂时不可用';
    case 'transport_error':
      return '无法连接学校模型服务，请检查校园网或 iWAN';
    case 'protocol_error':
      return '学校模型服务返回了非预期的响应';
    case 'probe_tool_not_emitted':
      return '该模型未发出工具调用，不能作为 Agent 模型';
    case 'probe_tool_empty_input':
      return '该模型的工具调用缺少输入，不能作为 Agent 模型';
    case 'probe_incomplete':
      return '探测未完成，请稍后重试';
    case 'probe_no_text':
      return '该模型未返回文本，不能作为 Agent 模型';
    case 'cancelled':
      return null;
    default:
      return '学校模型服务返回了非预期的响应';
  }
}

/// The `/settings/agent` page: configure the school model service.
///
/// The page depends on injected services so it stays free of `dart:io`, Windows
/// DPAPI, and network code. All platform wiring lives in the router loader.
///
/// Security is load-bearing:
/// * The API Key field uses obscured text and never initializes with the
///   stored key — only a masked 已设置/未设置 indicator (from [hasKey]) is shown.
/// * Saving invokes both [LlmProvider.probeText] and [LlmProvider.probeTools]
///   before the key is persisted and the Agent enabled.
/// * Model changes invoke both probes with the existing key + the new model
///   before [setModel] is called; a failed probe reverts the selection.
/// * Errors are surfaced via [safeErrorCopy] only — never the raw key or error.
class AgentSettingsPage extends StatefulWidget {
  const AgentSettingsPage({
    required this.accountId,
    required this.config,
    required this.secrets,
    required this.provider,
    required this.chatRepository,
    required this.policyService,
    super.key,
  });

  final String accountId;
  final AgentConfigurationService config;
  final AgentSecretStore secrets;
  final LlmProvider provider;
  final DriftChatRepository chatRepository;
  final AgentPermissionPolicyService policyService;

  /// Whether the Agent is configured and ready to send: a key is stored, the
  /// Agent is enabled, and a model is set. Task 11's chat page consumes this to
  /// decide between the setup panel and the enabled composer.
  static Future<bool> isConfigured({
    required String accountId,
    required AgentConfigurationService config,
    required AgentSecretStore secrets,
  }) async {
    final snapshot = await config.load(accountId);
    if (!await secrets.hasKey(accountId)) return false;
    return snapshot.enabled && snapshot.model.isNotEmpty;
  }

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  final _keyController = TextEditingController();
  AgentSettingsSnapshot? _snapshot;
  bool _hasKey = false;
  List<String> _models = const [];
  String? _selectedModel;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  CancellationSignal? _activeCancellation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _activeCancellation?.cancel();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final accountId = widget.accountId;
    final snapshot = await widget.config.load(accountId);
    final hasKey = await widget.secrets.hasKey(accountId);
    List<String> models = const [];
    String? probeError;
    // Attempt to populate the model list using the stored key if present; a
    // failure here is non-fatal — the user can still save a key first.
    if (hasKey) {
      final key = await widget.secrets.readKey(accountId);
      if (key != null) {
        final cancellation = CancellationSignal();
        _activeCancellation = cancellation;
        try {
          models = await widget.provider.listModels(
            apiKey: key,
            cancellation: cancellation,
          );
        } on LlmProtocolException catch (e) {
          probeError = safeErrorCopy(e.code);
        } finally {
          _activeCancellation = null;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _hasKey = hasKey;
      final availableModels = models.isEmpty
          ? const [AgentConfigurationService.defaultModel]
          : models;
      _models = availableModels.contains(snapshot.model)
          ? availableModels
          : [...availableModels, snapshot.model];
      _selectedModel = snapshot.model;
      _loading = false;
      _error = probeError;
    });
  }

  Future<void> _refreshSnapshot() async {
    final snapshot = await widget.config.load(widget.accountId);
    final hasKey = await widget.secrets.hasKey(widget.accountId);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _hasKey = hasKey;
      if (!_models.contains(snapshot.model)) {
        _models = [..._models, snapshot.model];
      }
      _selectedModel = snapshot.model;
    });
  }

  Future<void> _saveKey() async {
    if (_busy) return;
    final key = _keyController.text;
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final cancellation = CancellationSignal();
    _activeCancellation = cancellation;
    try {
      final models = await widget.provider.listModels(
        apiKey: key,
        cancellation: cancellation,
      );
      if (models.isEmpty) {
        throw const LlmProtocolException('model_unavailable');
      }
      final selected = _selectedModel;
      final model = selected != null && models.contains(selected)
          ? selected
          : models.contains(AgentConfigurationService.defaultModel)
          ? AgentConfigurationService.defaultModel
          : models.first;
      await widget.provider.probeText(
        apiKey: key,
        model: model,
        cancellation: cancellation,
      );
      await widget.provider.probeTools(
        apiKey: key,
        model: model,
        cancellation: cancellation,
      );
      await widget.config.configureWithKey(
        accountId: widget.accountId,
        apiKey: key,
        model: model,
        secrets: widget.secrets,
      );
      if (!mounted) return;
      setState(() {
        _models = models;
        _selectedModel = model;
      });
      _keyController.clear();
      await _refreshSnapshot();
    } on LlmProtocolException catch (e) {
      if (!mounted) return;
      final copy = safeErrorCopy(e.code);
      if (copy != null) {
        setState(() => _error = copy);
      }
    } finally {
      _activeCancellation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteKey() async {
    final confirmed = await _confirm('删除已保存的 API Key？删除后将无法发送消息，但聊天记录会保留。');
    if (confirmed != true) return;
    await widget.config.deleteKeyAndDisable(
      accountId: widget.accountId,
      secrets: widget.secrets,
    );
    await _refreshSnapshot();
  }

  Future<void> _changeModel(String? model) async {
    if (model == null) return;
    if (model == _selectedModel) return;
    final previous = _selectedModel;
    setState(() {
      _busy = true;
      _error = null;
      _selectedModel = model;
    });
    final key = await widget.secrets.readKey(widget.accountId);
    if (key == null) {
      // No key stored: cannot probe; revert and prompt to save a key first.
      if (!mounted) return;
      setState(() {
        _selectedModel = previous;
        _error = '请先保存 API Key';
        _busy = false;
      });
      return;
    }
    final cancellation = CancellationSignal();
    _activeCancellation = cancellation;
    try {
      await widget.provider.probeText(
        apiKey: key,
        model: model,
        cancellation: cancellation,
      );
      await widget.provider.probeTools(
        apiKey: key,
        model: model,
        cancellation: cancellation,
      );
      await widget.config.setModel(widget.accountId, model);
      await _refreshSnapshot();
    } on LlmProtocolException catch (e) {
      if (!mounted) return;
      final copy = safeErrorCopy(e.code);
      setState(() {
        _selectedModel = previous;
        if (copy != null) _error = copy;
      });
    } finally {
      _activeCancellation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleConsent(bool value) async {
    await widget.config.setIcourseConsent(widget.accountId, value);
    await _refreshSnapshot();
  }

  Future<void> _clearSummary() async {
    final confirmed = await _confirm('清除当前会话摘要？聊天消息会保留。');
    if (confirmed != true) return;
    await widget.config.clearSummary(widget.accountId);
  }

  Future<void> _clearConversation() async {
    final confirmed = await _confirm('清除全部会话？将删除消息、运行记录和摘要；API Key 与业务数据会保留。');
    if (confirmed != true) return;
    await widget.config.clearConversation(widget.accountId);
  }

  Future<void> _viewSummary() async {
    final summary = await widget.chatRepository.latestSummary(widget.accountId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('当前会话摘要'),
        content: SizedBox(
          width: double.maxFinite,
          child: summary == null
              ? const Text('暂无摘要')
              : Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(summary.content),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(String title) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('模型服务')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final snapshot = _snapshot;
    final configured = _hasKey && (snapshot?.enabled ?? false);
    return Scaffold(
      appBar: AppBar(title: const Text('模型服务')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Fixed school Host + campus/iWAN requirement (static, read-only).
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('学校模型服务'),
            subtitle: const Text(
              'https://api.llm.ustc.edu.cn\n需连接校园网或 iWAN 后使用',
            ),
          ),
          if (!configured) ...[
            // Unconfigured onboarding: the reusable setup panel guides initial
            // Key entry + probe + enable. Task 11's chat page reuses the same
            // widget for its "setup action".
            AgentSetupPanel(
              accountId: widget.accountId,
              config: widget.config,
              secrets: widget.secrets,
              provider: widget.provider,
              onConfigured: _refreshSnapshot,
            ),
          ] else ...[
            const Divider(),
            // API Key section (replace/delete).
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('API Key'),
              subtitle: Text(_hasKey ? '已设置' : '未设置'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('agent-api-key-field'),
                controller: _keyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: '输入学校模型服务 API Key',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('agent-save-key'),
                    onPressed: _busy ? null : _saveKey,
                    child: const Text('保存并启用'),
                  ),
                  if (_hasKey)
                    OutlinedButton(
                      key: const Key('agent-delete-key'),
                      onPressed: _busy ? null : _deleteKey,
                      child: const Text('删除'),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                key: const Key('agent-error'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            // Model selection.
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('模型'),
              subtitle: const Text('默认 deepseek-v4-flash'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButton<String>(
                key: const Key('agent-model-dropdown'),
                value: _selectedModel,
                items: _models
                    .map(
                      (m) => DropdownMenuItem<String>(value: m, child: Text(m)),
                    )
                    .toList(),
                onChanged: _busy ? null : _changeModel,
                isExpanded: true,
              ),
            ),
            // iCourse consent.
            SwitchListTile(
              key: const Key('agent-icourse-consent'),
              secondary: const Icon(Icons.school),
              title: const Text('允许 Agent 查询我的 iCourse 信息'),
              subtitle: const Text('关闭后 Agent 不会读取你的 iCourse 数据'),
              value: snapshot?.icourseConsent ?? false,
              onChanged: _toggleConsent,
            ),
            const Divider(),
            // Agent 权限：每类写操作的确认模式、恢复默认与最近变更。
            AgentPermissionSection(
              accountId: widget.accountId,
              policyService: widget.policyService,
            ),
            const Divider(),
            // Summary section.
            ListTile(
              key: const Key('agent-view-summary'),
              leading: const Icon(Icons.summarize),
              title: const Text('当前会话摘要'),
              subtitle: const Text('查看将随请求发送的摘要'),
              onTap: _viewSummary,
            ),
            ListTile(
              key: const Key('agent-clear-summary'),
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清除摘要'),
              subtitle: const Text('保留聊天消息'),
              onTap: _clearSummary,
            ),
            ListTile(
              key: const Key('agent-clear-conversation'),
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清除会话'),
              subtitle: const Text('保留 API Key 与业务数据'),
              onTap: _clearConversation,
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Agent 已配置，可在聊天中使用。'),
            ),
          ],
        ],
      ),
    );
  }
}
