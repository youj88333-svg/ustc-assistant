import 'package:flutter/material.dart';

import '../application/history_repository.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    required this.repository,
    required this.accountId,
    super.key,
  });

  final HistoryRepository repository;

  /// The account whose action log is shown. History is scoped to this account
  /// inside the database query before sanitizing, so other accounts' safe
  /// summaries never surface here.
  final String accountId;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String? result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('操作历史')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String?>(
              segments: const [
                ButtonSegment(value: null, label: Text('全部')),
                ButtonSegment(value: 'success', label: Text('成功')),
                ButtonSegment(value: 'failure', label: Text('失败')),
              ],
              selected: {result},
              onSelectionChanged: (value) {
                setState(() => result = value.single);
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<HistoryEntry>>(
              future: widget.repository.query(
                widget.accountId,
                filter: HistoryFilter(result: result),
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data!;
                if (entries.isEmpty) {
                  return const Center(child: Text('暂无操作记录'));
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ListTile(
                      leading: Icon(
                        entry.result == 'success'
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                      ),
                      title: Text(entry.safeSummary),
                      subtitle: Text(
                        '${entry.source} · ${entry.actionType} · '
                        '${DateTime.fromMillisecondsSinceEpoch(entry.occurredAt)}',
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
