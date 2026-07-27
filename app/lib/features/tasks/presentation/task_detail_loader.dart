import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/plan_block_lifecycle_port.dart';
import '../application/plan_block_service.dart';
import '../application/task_lifecycle_service.dart';
import '../application/undo_service.dart';
import '../domain/plan_block.dart';
import '../domain/task.dart';
import '../domain/task_projection.dart';
import 'plan_block_editor.dart';
import 'task_detail_page.dart';

class TaskDetailLoader extends StatefulWidget {
  const TaskDetailLoader({
    required this.database,
    required this.taskId,
    this.initialNow,
    super.key,
  });

  final AppDatabase database;
  final String taskId;
  final DateTime? initialNow;

  @override
  State<TaskDetailLoader> createState() => _TaskDetailLoaderState();
}

class _TaskDetailData {
  const _TaskDetailData({
    required this.task,
    required this.blocks,
    required this.projection,
    required this.impact,
    required this.undoAvailable,
    required this.tasks,
    required this.planBlocks,
    required this.undo,
  });

  final TaskItem task;
  final List<PlanBlockItem> blocks;
  final TaskProjection projection;
  final PlanBlockImpact impact;
  final bool undoAvailable;
  final TaskLifecycleService tasks;
  final PlanBlockService planBlocks;
  final UndoService undo;
}

class _TaskDetailLoaderState extends State<TaskDetailLoader> {
  late Future<_TaskDetailData?> data = _load();

  DateTime get now => widget.initialNow ?? DateTime.now();

  Future<_TaskDetailData?> _load() async {
    final account = await (widget.database.select(
      widget.database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null) return null;
    int timestamp() => now.millisecondsSinceEpoch;
    final undo = UndoService(
      database: widget.database,
      accountId: account.id,
      now: timestamp,
    );
    final planBlocks = PlanBlockService(
      database: widget.database,
      accountId: account.id,
      now: timestamp,
      undoRecorder: undo,
    );
    final tasks = TaskLifecycleService(
      database: widget.database,
      accountId: account.id,
      now: timestamp,
      undoRecorder: undo,
      planBlocks: planBlocks,
    );
    try {
      final task = await tasks.byId(widget.taskId);
      final rows =
          await (widget.database.select(widget.database.planBlocks)..where(
                (row) =>
                    row.accountId.equals(account.id) &
                    row.taskId.equals(widget.taskId) &
                    row.deletedAt.isNull(),
              ))
              .get();
      final blocks = rows.map(PlanBlockItem.fromRow).toList(growable: false)
        ..sort((a, b) => a.startAt.compareTo(b.startAt));
      return _TaskDetailData(
        task: task,
        blocks: blocks,
        projection: projectTask(
          task,
          now,
          planBlocks: [
            for (final block in blocks)
              PlanBlockSnapshot(
                state: _projectionState(block.status),
                endAt: block.endAt,
              ),
          ],
        ),
        impact: await tasks.terminalImpact(widget.taskId),
        undoAvailable: await undo.canUndo(),
        tasks: tasks,
        planBlocks: planBlocks,
        undo: undo,
      );
    } on TaskNotFoundError {
      return null;
    }
  }

  void _reload() {
    setState(() {
      data = _load();
    });
  }

  Future<void> _mutate(Future<void> Function() action) async {
    await action();
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TaskDetailData?>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final value = snapshot.data;
        if (value == null) return const _MissingTaskPage();
        return TaskDetailPage(
          task: value.task,
          blocks: value.blocks,
          projection: value.projection,
          planImpact: value.impact,
          undoAvailable: value.undoAvailable,
          now: now,
          onSchedule: () => _openPlanEditor(value),
          onComplete: (cancelFuture) => _mutate(
            () => value.tasks.complete(
              value.task.id,
              expectedUpdatedAt: value.task.updatedAt,
              cancelFutureAccepted: cancelFuture,
            ),
          ),
          onCancelTask: () => _mutate(
            () => value.tasks.cancel(
              value.task.id,
              expectedUpdatedAt: value.task.updatedAt,
            ),
          ),
          onReopenTask: () => _mutate(
            () => value.tasks.reopen(
              value.task.id,
              expectedUpdatedAt: value.task.updatedAt,
            ),
          ),
          onToggleBlocked: () => _mutate(
            () => value.task.state == TaskState.blocked
                ? value.tasks.unblock(
                    value.task.id,
                    expectedUpdatedAt: value.task.updatedAt,
                  )
                : value.tasks.block(
                    value.task.id,
                    expectedUpdatedAt: value.task.updatedAt,
                  ),
          ),
          onUndo: () => _mutate(value.undo.undo),
          onEditBlock: (block) => _openPlanEditor(value, block: block),
          onCancelBlock: (block) => _mutate(
            () => value.planBlocks.cancel(
              block.id,
              expectedUpdatedAt: block.updatedAt,
            ),
          ),
          onMarkBlockDone: (block) => _mutate(
            () => value.planBlocks.markDone(
              block.id,
              expectedUpdatedAt: block.updatedAt,
            ),
          ),
          onMarkBlockSkipped: (block) => _mutate(
            () => value.planBlocks.markSkipped(
              block.id,
              expectedUpdatedAt: block.updatedAt,
            ),
          ),
          onRescheduleBlock: (block) =>
              _openPlanEditor(value, block: block, reschedule: true),
        );
      },
    );
  }

  Future<void> _openPlanEditor(
    _TaskDetailData value, {
    PlanBlockItem? block,
    bool reschedule = false,
  }) async {
    final initialStart = block?.startAt ?? now.add(const Duration(hours: 1));
    final initialMinutes = block == null
        ? value.task.estimatedMinutes
        : block.endAt.difference(block.startAt).inMinutes;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: PlanBlockEditor(
            initialStart: initialStart,
            estimatedMinutes: initialMinutes,
            initialTitle: block?.title,
            submitLabel: block == null
                ? '安排时间'
                : reschedule
                ? '重新安排'
                : '保存修改',
            onSubmit: (draft) async {
              if (block == null) {
                await value.planBlocks.create(
                  taskId: value.task.id,
                  title: draft.title,
                  startAt: draft.startAt,
                  endAt: draft.endAt,
                );
              } else if (reschedule) {
                await value.planBlocks.reschedule(
                  block.id,
                  startAt: draft.startAt,
                  endAt: draft.endAt,
                  expectedUpdatedAt: block.updatedAt,
                );
              } else {
                await value.planBlocks.move(
                  block.id,
                  startAt: draft.startAt,
                  endAt: draft.endAt,
                  expectedUpdatedAt: block.updatedAt,
                );
              }
              if (sheetContext.mounted) Navigator.pop(sheetContext);
            },
          ),
        ),
      ),
    );
    if (mounted) _reload();
  }

  PlanBlockProjectionState _projectionState(PlanBlockStatus status) =>
      switch (status) {
        PlanBlockStatus.suggested => PlanBlockProjectionState.suggested,
        PlanBlockStatus.accepted => PlanBlockProjectionState.accepted,
        PlanBlockStatus.done => PlanBlockProjectionState.done,
        PlanBlockStatus.skipped => PlanBlockProjectionState.skipped,
        PlanBlockStatus.rescheduled => PlanBlockProjectionState.rescheduled,
        PlanBlockStatus.cancelled => PlanBlockProjectionState.cancelled,
      };
}

class _MissingTaskPage extends StatelessWidget {
  const _MissingTaskPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Task 详情')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('记录已不存在'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('missing-task-back'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
