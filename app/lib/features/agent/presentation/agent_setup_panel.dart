import 'package:flutter/material.dart';

import '../application/agent_configuration_service.dart';
import '../application/cancellation_signal.dart';
import '../data/anthropic_llm_provider.dart';
import '../data/protected_agent_secret_store.dart';
import '../domain/llm_protocol.dart';
import 'agent_settings_page.dart';

/// A reusable onboarding panel that guides initial API Key entry, runs both
/// LLM probes, and enables the Agent on success.
///
/// This widget is shown when the Agent is unconfigured (no key or disabled).
/// Task 11's chat page embeds it behind its "setup action" so an unconfigured
/// chat surface can guide the user into configuration without leaving context.
/// It is also embedded in [AgentSettingsPage] when the Agent is unconfigured.
///
/// The panel takes the same injected services as the settings page and stays
/// free of `dart:io`, Windows DPAPI, and network code. Security rules mirror
/// the settings page: the key field is obscured, never pre-filled, probed
/// before persistence, and errors surface via [safeErrorCopy] only.
class AgentSetupPanel extends StatefulWidget {
  const AgentSetupPanel({
    required this.accountId,
    required this.config,
    required this.secrets,
    required this.provider,
    this.onConfigured,
    super.key,
  });

  final String accountId;
  final AgentConfigurationService config;
  final AgentSecretStore secrets;
  final LlmProvider provider;
  final VoidCallback? onConfigured;

  @override
  State<AgentSetupPanel> createState() => _AgentSetupPanelState();
}

class _AgentSetupPanelState extends State<AgentSetupPanel> {
  final _keyController = TextEditingController();
  bool _busy = false;
  String? _error;
  CancellationSignal? _activeCancellation;

  @override
  void dispose() {
    _activeCancellation?.cancel();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _saveAndEnable() async {
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
      await widget.provider.probeText(
        apiKey: key,
        model: AgentConfigurationService.defaultModel,
        cancellation: cancellation,
      );
      await widget.provider.probeTools(
        apiKey: key,
        model: AgentConfigurationService.defaultModel,
        cancellation: cancellation,
      );
      await widget.secrets.saveKey(widget.accountId, key);
      await widget.config.enable(widget.accountId, true);
      _keyController.clear();
      if (!mounted) return;
      widget.onConfigured?.call();
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.school, size: 48),
          const SizedBox(height: 8),
          Text(
            '配置学校模型服务',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text(
            '需连接校园网或 iWAN，使用学校模型服务 https://api.llm.ustc.edu.cn。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('agent-setup-key-field'),
            controller: _keyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '输入学校模型服务 API Key',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('agent-setup-save'),
            onPressed: _busy ? null : _saveAndEnable,
            child: const Text('保存并启用'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
