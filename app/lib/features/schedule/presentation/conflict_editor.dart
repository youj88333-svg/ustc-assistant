import 'package:flutter/material.dart';

import '../application/conflict_service.dart';

class ConflictPairDraft {
  const ConflictPairDraft({
    required this.id,
    required this.left,
    required this.right,
    required this.leftTitle,
    required this.rightTitle,
    this.state = ConflictState.unclassified,
    this.scope = ConflictScope.occurrence,
    this.reason,
  });

  final String id;
  final EventConflictParticipant left;
  final EventConflictParticipant right;
  final String leftTitle;
  final String rightTitle;
  final ConflictState state;
  final ConflictScope scope;
  final String? reason;
}

class ConflictEditor extends StatefulWidget {
  const ConflictEditor({
    required this.pairs,
    required this.onClassify,
    this.onBeforeSave,
    super.key,
  });

  final List<ConflictPairDraft> pairs;
  final Future<void> Function(
    EventConflictParticipant left,
    EventConflictParticipant right,
    ConflictState state, {
    required ConflictScope scope,
    String? reason,
  })
  onClassify;
  final Future<void> Function()? onBeforeSave;

  @override
  State<ConflictEditor> createState() => _ConflictEditorState();
}

class _ConflictEditorState extends State<ConflictEditor> {
  late final Map<String, ConflictState> _states = {
    for (final pair in widget.pairs) pair.id: pair.state,
  };
  late final Map<String, ConflictScope> _scopes = {
    for (final pair in widget.pairs) pair.id: pair.scope,
  };
  late final Map<String, TextEditingController> _reasons = {
    for (final pair in widget.pairs)
      pair.id: TextEditingController(text: pair.reason),
  };
  bool saving = false;

  @override
  void dispose() {
    for (final controller in _reasons.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: widget.pairs.length,
            separatorBuilder: (_, _) => const Divider(height: 24),
            itemBuilder: (context, index) {
              final pair = widget.pairs[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${pair.leftTitle} / ${pair.rightTitle}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<ConflictState>(
                    key: Key('conflict-state-${pair.id}'),
                    initialValue: _states[pair.id],
                    decoration: const InputDecoration(labelText: '关系'),
                    items: const [
                      DropdownMenuItem(
                        value: ConflictState.unclassified,
                        child: Text('暂不分类'),
                      ),
                      DropdownMenuItem(
                        value: ConflictState.conflict,
                        child: Text('冲突'),
                      ),
                      DropdownMenuItem(
                        value: ConflictState.nonConflict,
                        child: Text('不冲突'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _states[pair.id] = value);
                      }
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('应用到当前及未来兼容课次'),
                    value: _scopes[pair.id] == ConflictScope.currentAndFuture,
                    onChanged:
                        pair.left.hasStableSeriesIdentity &&
                            pair.right.hasStableSeriesIdentity
                        ? (enabled) {
                            setState(
                              () => _scopes[pair.id] = enabled
                                  ? ConflictScope.currentAndFuture
                                  : ConflictScope.occurrence,
                            );
                          }
                        : null,
                  ),
                  TextField(
                    controller: _reasons[pair.id],
                    decoration: const InputDecoration(labelText: '原因（可选）'),
                    maxLines: 2,
                  ),
                ],
              );
            },
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('save-conflicts'),
              onPressed: saving ? null : _save,
              child: Text(saving ? '保存中' : '保存'),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.onBeforeSave?.call();
      for (final pair in widget.pairs) {
        final reason = _reasons[pair.id]!.text.trim();
        await widget.onClassify(
          pair.left,
          pair.right,
          _states[pair.id]!,
          scope: _scopes[pair.id]!,
          reason: reason.isEmpty ? null : reason,
        );
      }
      if (mounted) Navigator.of(context).maybePop();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
