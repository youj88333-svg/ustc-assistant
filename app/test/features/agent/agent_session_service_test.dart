import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_grounding_policy.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_budget.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_invocation_summary.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

// ---------------------------------------------------------------------------
// Scripted fake provider.
// ---------------------------------------------------------------------------

/// A scripted [LlmProvider] that replays a queue of "call responses". Each
/// response is a list of [LlmEvent]s to emit for one `stream()` invocation.
/// The fake asserts the API key is non-empty and discards it immediately
/// (never retained). The number of `stream()` calls is counted so tests can
/// assert the 8-model-call budget.
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this._script);

  final List<List<LlmEvent>> _script;
  int streamCallCount = 0;
  String? _lastSeenKey;

  /// Every `LlmRequest` passed to `stream()`, in call order, so tests can
  /// assert on the exact conversation sent to the model.
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    _lastSeenKey = apiKey;
    requests.add(request);
    streamCallCount++;
    final index = streamCallCount - 1;
    if (index >= _script.length) {
      yield const ErrorEvent('script_exhausted');
      return;
    }
    for (final event in _script[index]) {
      if (cancellation.isCancelled) {
        yield const CompletedEvent();
        return;
      }
      yield event;
    }
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  /// Confirms the key was seen and never retained beyond the call boundary.
  bool sawKey(String key) => _lastSeenKey == key;
}

/// Builds the canonical scripted loop from the brief:
/// call 1 -> tool_use(get_schedule)
/// call 2 -> tool_use(search_campus_catalog)
/// call 3 -> final text + citations
List<List<LlmEvent>> _canonicalLoop() => [
  // call 1: a tool_use for get_schedule.
  [
    const ToolUseCompletedEvent(
      id: 'tu-1',
      name: 'get_schedule',
      input: {'date': '2026-07-29'},
    ),
    const UsageEvent(inputTokens: 100, outputTokens: 10),
    const CompletedEvent(),
  ],
  // call 2: a tool_use for search_campus_catalog.
  [
    const ToolUseCompletedEvent(
      id: 'tu-2',
      name: 'search_campus_catalog',
      input: {'q': '图书馆'},
    ),
    const UsageEvent(inputTokens: 200, outputTokens: 20),
    const CompletedEvent(),
  ],
  // call 3: final assistant text with citations.
  [
    const TextDeltaEvent('明天没有课。图书馆在东区。'),
    const UsageEvent(inputTokens: 300, outputTokens: 30),
    const CompletedEvent(),
  ],
];

// ---------------------------------------------------------------------------
// Fake tools.
// ---------------------------------------------------------------------------

class _FakeScheduleTool implements AgentTool {
  @override
  String get name => 'get_schedule';
  @override
  String get description => 'Reads the course schedule for a date.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'date': {'type': 'string'},
    },
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    // Bind a run-local reference the model can later resolve.
    final ref = context.references.bind(
      kind: 'schedule',
      localId: 'schedule-2026-07-29',
    );
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {'courses': <Map<String, Object?>>[], 'semester': '2026春'},
      references: [
        AgentToolReference(
          kind: 'schedule',
          ref: ref,
          localId: 'schedule-2026-07-29',
        ),
      ],
    );
  }
}

class _FakeCatalogTool implements AgentTool {
  @override
  String get name => 'search_campus_catalog';
  @override
  String get description => 'Searches the campus catalog.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'q': {'type': 'string'},
    },
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final ref = context.references.bind(
      kind: 'catalog',
      localId: 'catalog-lib',
    );
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {'results': <Map<String, Object?>>[]},
      references: [
        AgentToolReference(kind: 'catalog', ref: ref, localId: 'catalog-lib'),
      ],
    );
  }
}

class _PausingTool implements AgentTool {
  _PausingTool({
    this.includeUserAction = true,
    this.throwOnPendingCancel = false,
  });

  final bool includeUserAction;
  final bool throwOnPendingCancel;
  final Completer<void> paused = Completer<void>();
  final Completer<AgentToolResult> _terminal = Completer<AgentToolResult>();
  int cancelCount = 0;
  int signalCancelCount = 0;
  int activeCancellationSubscriptions = 0;
  StreamSubscription<void>? _cancellationSubscription;

  @override
  String get name => 'pause_tool';

  @override
  String get description => 'Pauses for a local user action.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    activeCancellationSubscriptions++;
    _cancellationSubscription = context.cancellation.onCancel.listen((_) {
      signalCancelCount++;
      activeCancellationSubscriptions--;
      unawaited(_cancellationSubscription?.cancel());
      _cancellationSubscription = null;
      if (!_terminal.isCompleted) {
        _terminal.complete(
          const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'cancelled',
          ),
        );
      }
    });
    if (!paused.isCompleted) paused.complete();
    return AgentToolResult(
      status: AgentToolStatus.needsUserAction,
      errorCode: 'needs_user_login',
      userAction: includeUserAction
          ? const AgentUserAction(
              type: AgentUserActionType.writeConfirmation,
              opaqueHandle: 'local-job',
            )
          : null,
      pendingInvocation: AgentPendingToolInvocation(
        result: _terminal.future,
        cancel: () async {
          context.cancellation.cancel();
          cancelCount++;
          if (throwOnPendingCancel) {
            throw StateError('invalid_job_state');
          }
          if (!_terminal.isCompleted) {
            _terminal.complete(
              const AgentToolResult(
                status: AgentToolStatus.error,
                errorCode: 'cancelled',
              ),
            );
          }
        },
      ),
    );
  }
}

class _CancellingScheduleTool implements AgentTool {
  int executeCount = 0;

  @override
  String get name => 'get_schedule';

  @override
  String get description => 'Cancels the run after the first tool starts.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    context.cancellation.cancel();
    return const AgentToolResult(
      status: AgentToolStatus.success,
      payload: {'courses': <Object?>[]},
    );
  }
}

class _CountingCatalogTool implements AgentTool {
  int executeCount = 0;

  @override
  String get name => 'search_campus_catalog';

  @override
  String get description => 'Counts executions.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    return const AgentToolResult(
      status: AgentToolStatus.success,
      payload: {'results': <Object?>[]},
    );
  }
}

/// A get_schedule tool that counts actual executions and returns one concrete
/// event reference whenever it actually runs. It never rejects on its own: a
/// bounded relation lookup (title query or exact single-day events) is
/// permitted to run and yields exactly one event ref, while unbounded calls
/// are intercepted by the session layer before reaching the registry (so their
/// executeCount stays at whatever the allowed calls produced).
class _CountingEventScheduleTool implements AgentTool {
  int executeCount = 0;

  @override
  String get name => 'get_schedule';

  @override
  String get description => 'Counts executions; returns one event reference.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    final ref = context.references.bind(kind: 'event', localId: 'event-1');
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const <String, Object?>{},
      references: [
        AgentToolReference(kind: 'event', ref: ref, localId: 'event-1'),
      ],
    );
  }
}

/// A create_schedule_relation tool that records the proposed conflict state so
/// a session test can assert expected-state enforcement passes/repairs it.
class _RecordingRelationTool implements AgentTool {
  final List<String> conflictStates = [];

  @override
  String get name => 'create_schedule_relation';

  @override
  String get description => 'Records a relation; records the proposed state.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    conflictStates.add((arguments['conflict_state'] as String?) ?? '');
    return const AgentToolResult(
      status: AgentToolStatus.success,
      payload: {'result': 'created_schedule_relation'},
    );
  }
}

class _GuidanceScheduleTool implements AgentTool {
  @override
  String get name => 'get_schedule';

  @override
  String get description => 'Returns bounded narrowing guidance.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async => const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'result_too_large',
    payload: {'guidance': 'Narrow the date range and retry.'},
  );
}

/// A get_schedule tool that mimics the Task 7 summary-first guard: a no-query
/// `events` view (the default) returns `schedule_summary_required` with
/// summary guidance; a `course_summary` view succeeds. Counts executions so a
/// test can assert that after the model changes to `course_summary` the call
/// is NOT duplicate-blocked (different arguments => a different fingerprint).
class _SummaryFirstScheduleTool implements AgentTool {
  int executeCount = 0;

  @override
  String get name => 'get_schedule';

  @override
  String get description => 'Peers at the view argument to mimic the guard.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    final view = arguments['view'];
    if (view != 'course_summary') {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'schedule_summary_required',
        payload: {
          'guidance': '日期范围较大，请改用 view=course_summary；若需要具体课次，请缩小日期范围。',
        },
      );
    }
    return const AgentToolResult(
      status: AgentToolStatus.success,
      payload: {'groups': <Object?>[]},
    );
  }
}

/// A schedule tool that binds [eventCount] event refs, simulating a large
/// schedule query. Used to verify deduplication of local navigation actions.
class _ManyEventRefsScheduleTool implements AgentTool {
  _ManyEventRefsScheduleTool({this.eventCount = 241});

  final int eventCount;

  @override
  String get name => 'get_schedule';

  @override
  String get description => 'Binds many event refs.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final refs = <AgentToolReference>[];
    for (var i = 0; i < eventCount; i++) {
      final localId = 'event-$i';
      final ref = context.references.bind(kind: 'event', localId: localId);
      refs.add(AgentToolReference(kind: 'event', ref: ref, localId: localId));
    }
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {'events': <Map<String, Object?>>[]},
      references: refs,
    );
  }
}

/// A tasks tool that binds many task refs, simulating a large task query.
class _ManyEventRefsTasksTool implements AgentTool {
  @override
  String get name => 'get_tasks';

  @override
  String get description => 'Binds many task refs.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final refs = <AgentToolReference>[];
    for (var i = 0; i < 50; i++) {
      final localId = 'task-$i';
      final ref = context.references.bind(kind: 'task', localId: localId);
      refs.add(AgentToolReference(kind: 'task', ref: ref, localId: localId));
    }
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {'tasks': <Map<String, Object?>>[]},
      references: refs,
    );
  }
}

class _FakePendingReviewsTool implements AgentTool {
  @override
  String get name => 'get_pending_event_reviews';
  @override
  String get description => 'Pending attendance/listening reviews.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async => const AgentToolResult(
    status: AgentToolStatus.success,
    payload: {'pending': <Object?>[]},
  );
}

class _FakePendingPlanBlockReviewsTool implements AgentTool {
  @override
  String get name => 'get_pending_planblock_reviews';
  @override
  String get description => 'Pending planblock reviews.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async => const AgentToolResult(
    status: AgentToolStatus.success,
    payload: {'pending': <Object?>[]},
  );
}

/// A tool that reports success and optionally counts executions.
class _CountingSuccessTool implements AgentTool {
  _CountingSuccessTool({required this.name, this.onExecute});

  @override
  final String name;
  final void Function()? onExecute;
  int executeCount = 0;

  @override
  String get description => 'Default tool';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    onExecute?.call();
    return const AgentToolResult(status: AgentToolStatus.success, payload: {});
  }
}

/// A write tool that always fails (e.g. a declined/errored terminal write).
class _FailingWriteTool implements AgentTool {
  @override
  String get name => 'plan_task';
  @override
  String get description => 'Plans a task execution block (always fails here).';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async => const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'target_not_found',
    payload: {'guidance': '该任务已不存在，无法为该任务安排时间段。'},
  );
}

/// A plan_task write tool whose outcome (status + errorCode) is configurable
/// per test, and which counts its executions so a test can assert the write is
/// never re-executed after a failed terminal outcome.
class _ConfigurablePlanTaskTool implements AgentTool {
  _ConfigurablePlanTaskTool({
    required this.status,
    this.errorCode,
    this.onExecute,
  });

  final AgentToolStatus status;
  final String? errorCode;
  final void Function()? onExecute;
  int executeCount = 0;

  @override
  String get name => 'plan_task';
  @override
  String get description => 'Plans a task execution block.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    onExecute?.call();
    if (status == AgentToolStatus.success) {
      return const AgentToolResult(
        status: AgentToolStatus.success,
        payload: {},
      );
    }
    return AgentToolResult(
      status: status,
      errorCode: errorCode ?? 'write_commit_failed',
      payload: {'guidance': '写操作未成功，请检查后重试。'},
    );
  }
}

/// A create_schedule_relation tool whose outcome (status + errorCode) is
/// configurable per test, with an optional order callback for sequential
/// confirmation assertions. Counts executions so tests can assert the relation
/// write runs exactly once.
class _ConfigurableRelationTool implements AgentTool {
  _ConfigurableRelationTool({
    required this.status,
    this.errorCode,
    this.onExecute,
  });

  final AgentToolStatus status;
  final String? errorCode;
  final void Function()? onExecute;
  int executeCount = 0;

  @override
  String get name => 'create_schedule_relation';

  @override
  String get description => 'Creates a no-conflict relation (configurable).';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    executeCount++;
    onExecute?.call();
    if (status == AgentToolStatus.success) {
      return const AgentToolResult(
        status: AgentToolStatus.success,
        payload: {'result': 'created_schedule_relation'},
      );
    }
    return AgentToolResult(
      status: status,
      errorCode: errorCode ?? 'write_commit_failed',
      payload: {'guidance': '关系未写入，请检查后重试。'},
    );
  }
}

/// A `create_task` write tool whose outcome is driven per call by the
/// [outcomes] list (indexed by call ordinal) and which counts executions so
/// tests can assert the burst runs each planned write exactly once. A result
/// `code` of `'success'` yields a successful write; anything else is an error
/// with that error code.
class _BurstCreateTaskTool implements AgentTool {
  _BurstCreateTaskTool(List<String> outcomes, {this.cancelOn})
    : outcomes = List.of(outcomes);

  final List<String> outcomes;
  final int? cancelOn;
  int executeCount = 0;

  @override
  String get name => 'create_task';

  @override
  String get description => 'Creates an independent Task (configurable).';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final index = executeCount;
    executeCount++;
    if (cancelOn != null && index == cancelOn) {
      context.cancellation.cancel();
    }
    final code = index < outcomes.length ? outcomes[index] : 'success';
    if (code == 'success') {
      return const AgentToolResult(
        status: AgentToolStatus.success,
        payload: {'result': 'created_task'},
      );
    }
    return AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: code,
      payload: {'guidance': '写操作未成功，请检查后重试。'},
    );
  }
}

/// A grounding policy that always classifies the user text as a create-task
/// burst with [limit] (32 by default) allowed create_task calls and a narrowed
/// first-request tool set of `{get_schedule, create_task}`. Used so the burst
/// tests exercise the session service's burst path deterministically regardless
/// of the userText phrasing.
class _CreateTaskBurstPolicy extends AgentGroundingPolicy {
  const _CreateTaskBurstPolicy();

  @override
  AgentGroundingRequirement? classify(String userText) =>
      AgentGroundingRequirement(
        lookupTools: const {'get_schedule'},
        terminalTools: const {'create_task'},
        mutationIntent: true,
        initialAllowedTools: const ['get_schedule', 'create_task'],
        createTaskBurstLimit: 32,
      );
}

class _ConcurrentBlockingProvider implements LlmProvider {
  final Map<String, Completer<void>> _started = {};
  final Map<String, Completer<void>> _release = {};
  final Set<String> cancelledLabels = {};

  Future<void> waitStarted(String label) =>
      (_started[label] ??= Completer<void>()).future;

  void release(String label) {
    final completer = _release[label] ??= Completer<void>();
    if (!completer.isCompleted) completer.complete();
  }

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    final label = request.messages
        .expand((message) => message.content)
        .whereType<LlmTextBlock>()
        .last
        .text;
    final started = _started[label] ??= Completer<void>();
    if (!started.isCompleted) started.complete();
    final release = _release[label] ??= Completer<void>();
    while (!release.isCompleted && !cancellation.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (cancellation.isCancelled) {
      cancelledLabels.add(label);
      yield const CompletedEvent();
      return;
    }
    yield TextDeltaEvent('done:$label');
    yield const CompletedEvent();
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}

class _SummaryOverlapProvider implements LlmProvider {
  final Completer<void> summaryStarted = Completer<void>();
  final Completer<void> runBStarted = Completer<void>();
  final Completer<void> _releaseSummary = Completer<void>();

  void releaseSummary() {
    if (!_releaseSummary.isCompleted) _releaseSummary.complete();
  }

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    if (request.tools.isEmpty) {
      if (!summaryStarted.isCompleted) summaryStarted.complete();
      await _releaseSummary.future;
      yield const TextDeltaEvent('summary');
      yield const CompletedEvent();
      return;
    }

    final userText = request.messages
        .expand((message) => message.content)
        .whereType<LlmTextBlock>()
        .last
        .text;
    if (userText == 'run-a') {
      yield const TextDeltaEvent('done-a');
      yield const UsageEvent(inputTokens: 20000, outputTokens: 10);
      yield const CompletedEvent();
      return;
    }

    if (!runBStarted.isCompleted) runBStarted.complete();
    while (!cancellation.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    yield const CompletedEvent();
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}

Map<String, Object?> _scheduleBuilder(Map<String, Object?> raw) => {
  'courses': raw['courses'],
  'semester': raw['semester'],
  'guidance': raw['guidance'],
};

Map<String, Object?> _catalogBuilder(Map<String, Object?> raw) => {
  'results': raw['results'],
};

/// The default tool set used by the harness when a test does not override it.
final List<AgentTool> _defaultTools = [_FakeScheduleTool(), _FakeCatalogTool()];

// ---------------------------------------------------------------------------
// Test harness.
// ---------------------------------------------------------------------------

/// A fixed Beijing clock so ActionLog timestamps and run timestamps are
/// deterministic in assertions.
class _SequenceClock implements BeijingClock {
  _SequenceClock(this._start);
  final DateTime _start;
  int _ticks = 0;

  @override
  DateTime now() {
    _ticks += 1;
    return _start.add(Duration(milliseconds: _ticks));
  }

  int millis() => now().millisecondsSinceEpoch;
}

Future<void> _seedAccount(AppDatabase database, String accountId) => database
    .into(database.localAccounts)
    .insert(
      LocalAccountsCompanion.insert(
        id: accountId,
        maskedHint: 'PB****0000',
        isActive: const Value(true),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

Future<void> _failAgentActionLogWrites(AppDatabase database) =>
    database.customStatement('''
CREATE TRIGGER fail_agent_action_log
BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent' AND NEW.action_type = 'read_only_run'
BEGIN
  SELECT RAISE(FAIL, 'terminal action log failure');
END
''');

AgentSessionService _buildService({
  required AppDatabase database,
  required LlmProvider provider,
  required BeijingClock clock,
  List<AgentTool>? tools,
  AgentGroundingPolicy? groundingPolicy,
  String model = 'deepseek-v4-flash',
  String protectedAccount = 'PB12345678',
  AgentUserActionResumeCallback? userActionResumer,
  Map<String, ToolPayloadBuilder>? payloadBuilders,
}) {
  final chatRepository = DriftChatRepository(database);
  final privacyFilter = OutboundPrivacyFilter(
    protectedAccount: protectedAccount,
    toolBuilders:
        payloadBuilders ??
        {
          'get_schedule': _scheduleBuilder,
          'search_campus_catalog': _catalogBuilder,
        },
  );
  final registry = AgentToolRegistry(
    tools: tools ?? _defaultTools,
    privacyFilter: privacyFilter,
  );
  return AgentSessionService(
    chatRepository: chatRepository,
    database: database,
    provider: provider,
    contextBuilder: const AgentContextBuilder(),
    privacyFilter: privacyFilter,
    registry: registry,
    clock: clock,
    model: model,
    // Ephemeral key provider closure: tests must never need real DPAPI.
    apiKeyProvider: ({required String accountId}) async => 'ephemeral-test-key',
    userActionResumer: userActionResumer,
    groundingPolicy: groundingPolicy ?? const AgentGroundingPolicy(),
  );
}

void main() {
  const account = 'a';
  late AppDatabase database;
  late DriftChatRepository chatRepository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await _seedAccount(database, account);
    chatRepository = DriftChatRepository(database);
  });

  group('AgentSessionService.send — canonical scripted loop', () {
    test(
      'completes the 3-call loop and persists final assistant text',
      () async {
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        final states = await service
            .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
            .toList();

        // Exactly three model calls were made.
        expect(provider.streamCallCount, 3);

        // The final view state is completed with the streamed final text.
        final terminal = states.last;
        expect(terminal.state, AgentRunState.completed);
        expect(terminal.text, contains('明天没有课'));
        expect(terminal.text, contains('图书馆在东区'));

        // The run record is persisted as completed.
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs, hasLength(1));
        expect(runs.single.status, AgentRunState.completed.name);
        expect(runs.single.model, 'deepseek-v4-flash');
        expect(runs.single.errorCode, isNull);
        // Token usage from the last UsageEvent is recorded.
        expect(runs.single.inputTokens, 300);
        expect(runs.single.outputTokens, 30);

        // The user message and the final assistant message are persisted.
        final messages = await chatRepository.recentMessages(
          account,
          limit: 50,
        );
        expect(messages.where((m) => m.role == ChatRole.user), hasLength(1));
        expect(
          messages.where((m) => m.role == ChatRole.user).single.content,
          '明天有什么课？图书馆在哪？',
        );
        final assistant = messages
            .where((m) => m.role == ChatRole.assistant)
            .single;
        expect(assistant.state, ChatMessageState.completed);
        expect(assistant.content, contains('明天没有课'));
      },
    );

    test('emits tool-running states between model calls', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();

      // The view should transition through running and at least one
      // tool-running state before completing.
      expect(states, isNotEmpty);
      expect(states.last.state, AgentRunState.completed);
      // Tool summaries are surfaced collapsed.
      final toolStates = states.where((s) => s.toolSummaries.isNotEmpty);
      expect(toolStates, isNotEmpty);
      // Two tools were executed across the run.
      final allToolNames = toolStates
          .expand((s) => s.toolSummaries.map((t) => t.toolName))
          .toSet();
      expect(allToolNames, {'get_schedule', 'search_campus_catalog'});
    });

    test('source references are surfaced in the final view', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();

      final terminal = states.last;
      // External source tools have been retired (v9 convergence); no tool
      // forwards refs to sourceReferences as public citations. Local-tool
      // refs emit a deduplicated local action instead.
      expect(terminal.sourceReferences, isEmpty);
      // One deduplicated local schedule action (not one per event ref).
      expect(terminal.localActions, hasLength(1));
      expect(terminal.localActions.single, AgentLocalAction.schedule);
    });
  });

  group('local navigation actions (deduplication)', () {
    // Regression: 241 event refs must produce ONE local "查看日程" action,
    // not 241 inert chips. The root cause was the session service copying
    // every per-event AgentToolReference into sourceReferences with no
    // dedup. The fix: local tools emit one deduplicated AgentLocalAction
    // per data domain; sourceReferences is reserved for public citations.
    test(
      '241 event refs produce one local schedule action and no source refs',
      () async {
        // A schedule tool that binds 241 event refs across multiple calls.
        final tool = _ManyEventRefsScheduleTool(eventCount: 241);
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'date': '2026-07-29'},
            ),
            const CompletedEvent(),
          ],
          // A second call to the same tool — must NOT add a second action.
          [
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'get_schedule',
              input: {'date': '2026-07-30'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('这是你的日程。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: '查日程')
            .toList();

        final terminal = states.last;
        // Exactly ONE schedule action, despite 241 refs across two calls.
        expect(terminal.localActions, hasLength(1));
        expect(terminal.localActions.single, AgentLocalAction.schedule);
        // ZERO source references from the local schedule tool.
        expect(terminal.sourceReferences, isEmpty);
      },
    );

    test(
      'schedule + tasks tools produce one action each, deduplicated',
      () async {
        final scheduleTool = _FakeScheduleTool();
        final tasksTool = _ManyEventRefsTasksTool();
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'get_tasks',
              input: {},
            ),
            const CompletedEvent(),
          ],
          // Call both AGAIN — must NOT duplicate the actions.
          [
            const ToolUseCompletedEvent(
              id: 'tu-3',
              name: 'get_schedule',
              input: {},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-4',
              name: 'get_tasks',
              input: {},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('done'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [scheduleTool, tasksTool],
        );

        final states = await service
            .send(accountId: account, userText: '查日程和任务')
            .toList();

        final terminal = states.last;
        // One schedule + one tasks, despite each being called twice.
        expect(terminal.localActions, hasLength(2));
        expect(terminal.localActions, contains(AgentLocalAction.schedule));
        expect(terminal.localActions, contains(AgentLocalAction.tasks));
        // No local refs forwarded to sourceReferences.
        expect(terminal.sourceReferences, isEmpty);
      },
    );

    // Task 11 step 4: a successful object-mutating lifecycle tool emits a
    // navigation chip for its domain (查看日程/查看任务), so the user can jump
    // to the affected page. Config-clear tools (clear_reminder,
    // clear_user_overlay, reset_permission_policy, unlink_task_event) and
    // undo_last_action touch no schedule/task object the user would navigate
    // to, so they produce NO chip.
    test('mutation tools map to a local action; config clears and undo do not',
        () {
      // Object-mutating tools: schedule domain.
      expect(
        AgentSessionService.localActionForTool('update_event'),
        AgentLocalAction.schedule,
      );
      expect(
        AgentSessionService.localActionForTool('delete_schedule_relation'),
        AgentLocalAction.schedule,
      );
      // Object-mutating tools: task domain.
      expect(
        AgentSessionService.localActionForTool('update_task'),
        AgentLocalAction.tasks,
      );
      expect(
        AgentSessionService.localActionForTool('update_plan_block'),
        AgentLocalAction.tasks,
      );
      // Config-clear tools and undo: no navigation chip.
      expect(AgentSessionService.localActionForTool('clear_reminder'), isNull);
      expect(
        AgentSessionService.localActionForTool('clear_user_overlay'),
        isNull,
      );
      expect(
        AgentSessionService.localActionForTool('reset_permission_policy'),
        isNull,
      );
      expect(
        AgentSessionService.localActionForTool('unlink_task_event'),
        isNull,
      );
      expect(
        AgentSessionService.localActionForTool('undo_last_action'),
        isNull,
      );
    });
  });

  group('first model request shape', () {
    test(
      'the current user question appears exactly once in the first request',
      () async {
        // Seed one prior completed turn so history is non-empty and distinct
        // from the current question.
        final priorRun = await chatRepository.startRun(
          accountId: account,
          model: 'deepseek-v4-flash',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: priorRun,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '上学期有几门课？',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: priorRun,
          role: ChatRole.assistant,
          state: ChatMessageState.completed,
          content: '上学期有五门课。',
        );

        const currentQuestion = '明天有什么课？图书馆在哪？';
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        await service
            .send(accountId: account, userText: currentQuestion)
            .toList();

        // The provider recorded the first request.
        expect(provider.requests, isNotEmpty);
        final firstRequest = provider.requests.first;

        // Collect every user-text block across all messages in the request.
        final userTexts = firstRequest.messages
            .where((m) => m.role == 'user')
            .expand((m) => m.content)
            .whereType<LlmTextBlock>()
            .map((b) => b.text)
            .toList();

        // The current question must appear EXACTLY once (regression guard
        // against the build() duplication bug where the just-persisted user
        // message was also in `history`).
        final occurrences = userTexts.where((t) => t == currentQuestion).length;
        expect(
          occurrences,
          1,
          reason:
              'current question must appear exactly once; '
              'got $occurrences in $userTexts',
        );

        // Prior-turn history is present and separate from the current question.
        expect(userTexts, anyElement(contains('上学期有几门课？')));
        // The current question is the LAST user text block (build appends it
        // as the final user message).
        expect(userTexts.last, currentQuestion);
      },
    );
  });

  group('tool_not_allowed', () {
    test(
      'an unregistered tool call returns tool_not_allowed and the run completes',
      () async {
        // Script a call that requests a tool the registry does not know.
        final script = [
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'delete_everything',
              input: {},
            ),
            const CompletedEvent(),
          ],
          // After the tool_result error, the model emits final text.
          [const TextDeltaEvent('我无法执行该操作。'), const CompletedEvent()],
        ];
        final provider = _ScriptedProvider(script);
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        // Register only the schedule tool; delete_everything is unknown.
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
          tools: [_FakeScheduleTool()],
        );

        final states = await service
            .send(accountId: account, userText: '删除所有数据')
            .toList();

        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.completed);
        // The run reached a safe terminal state.
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs.single.status, AgentRunState.completed.name);
      },
    );
  });

  group('invalid JSON fails safely', () {
    test(
      'a tool_use whose input is not a map is contained as an error result',
      () async {
        // The fake provider always emits input as a Map (per the protocol), so
        // we simulate invalid arguments by having a tool whose schema rejects
        // them. The registry must not throw and the loop must continue.
        final script = [
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'unexpected': 'garbage'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('抱歉，参数有误。'), const CompletedEvent()],
        ];
        final provider = _ScriptedProvider(script);
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        final states = await service
            .send(accountId: account, userText: '查课表')
            .toList();

        expect(states.last.state, AgentRunState.completed);
        expect(provider.streamCallCount, 2);
      },
    );
  });

  group('temporary references expire with the run', () {
    test('a ref bound in run 1 is not resolvable in run 2', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final firstStates = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();
      // External source refs are retired (v9); local-tool refs emit a
      // deduplicated local action, not a sourceReference.
      expect(firstStates.last.sourceReferences, isEmpty);

      // Run a second turn with a fresh provider script. The store is per-run,
      // so refs from run 1 must not resolve in run 2.
      final provider2 = _ScriptedProvider(_canonicalLoop());
      // Replace the service's provider by building a new one sharing the db.
      final service2 = _buildService(
        database: database,
        provider: provider2,
        clock: clock,
      );
      await service2.send(accountId: account, userText: '再查一次').toList();

      // Two separate runs persisted.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs, hasLength(2));
    });
  });

  group('hard limits', () {
    test('8 model calls is a hard limit', () async {
      // Script an infinite tool-calling loop. The runtime must hard-stop at 8
      // model calls and finish the run safely.
      final endlessToolCall = [
        const ToolUseCompletedEvent(
          id: 'tu-loop',
          name: 'get_schedule',
          input: {'date': '2026-07-29'},
        ),
        const CompletedEvent(),
      ];
      final script = List<List<LlmEvent>>.filled(20, endlessToolCall);
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '无限循环')
          .toList();

      expect(provider.streamCallCount, lessThanOrEqualTo(8));
      // The run terminates (not running).
      expect(states.last.state, isNot(AgentRunState.running));
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, isNot(AgentRunState.running.name));
    });

    test('12 tool calls is a hard limit', () async {
      // Each model call emits two tool uses, so tool calls outpace model
      // calls. The runtime must hard-stop at 12 tool calls.
      final twoToolsPerCall = [
        const ToolUseCompletedEvent(
          id: 'tu-a',
          name: 'get_schedule',
          input: {'date': '2026-07-29'},
        ),
        const ToolUseCompletedEvent(
          id: 'tu-b',
          name: 'search_campus_catalog',
          input: {'q': 'x'},
        ),
        const CompletedEvent(),
      ];
      final script = List<List<LlmEvent>>.filled(20, twoToolsPerCall);
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '无限工具')
          .toList();

      // Tool calls capped at 12; model calls at 8 (the tighter bound wins
      // first here, but tool count must never exceed 12).
      expect(states.last.state, isNot(AgentRunState.running));
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, isNot(AgentRunState.running.name));
    });
  });

  group('stop prevents a new call', () {
    test(
      'cancel mid-run finishes the in-flight stream then stops before the next call',
      () async {
        // A provider that, on the first call, emits a tool_use then waits for
        // cancellation before completing; the runtime should finish the tool,
        // then NOT start call 2.
        final provider = _CancellableProvider();
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        // Start the run and cancel shortly after the first tool use fires.
        final collected = <AgentRunViewState>[];
        final sub = service
            .send(accountId: account, userText: '查课表')
            .listen(collected.add);

        // Wait for the first tool use to land, then cancel.
        await provider.firstToolUseFired.future;
        await service.cancel(accountId: account);
        await sub.asFuture<void>(null);
        await sub.cancel();

        // Only one model call was started; the second was never initiated.
        expect(provider.streamCallCount, 1);
        // The run is cancelled, not completed.
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs.single.status, AgentRunState.cancelled.name);
        expect(collected.last.state, AgentRunState.cancelled);
      },
    );
  });

  group('aggregated ActionLog', () {
    test(
      'completed send emits one stable terminal when ActionLog write fails',
      () async {
        await _failAgentActionLogWrites(database);
        final provider = _ScriptedProvider([
          [const TextDeltaEvent('completed answer'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: 'complete')
            .toList()
            .timeout(const Duration(seconds: 1));

        final terminals = states
            .where(
              (state) => const {
                AgentRunState.completed,
                AgentRunState.cancelled,
                AgentRunState.failed,
                AgentRunState.interrupted,
              }.contains(state.state),
            )
            .toList();
        expect(terminals, hasLength(1));
        expect(terminals.single.state, AgentRunState.completed);
        expect(terminals.single.runId, isNotEmpty);
        expect(
          states.every((state) => state.runId == terminals.single.runId),
          isTrue,
        );
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs.single.id, terminals.single.runId);
        expect(runs.single.status, AgentRunState.completed.name);
      },
    );

    test(
      'cancelled send emits one stable terminal when ActionLog write fails',
      () async {
        await _failAgentActionLogWrites(database);
        final provider = _CancellableProvider();
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );
        final states = <AgentRunViewState>[];
        final subscription = service
            .send(accountId: account, userText: 'cancel')
            .listen(states.add);
        final done = subscription.asFuture<void>();

        await provider.firstToolUseFired.future;
        await service.cancel(accountId: account);
        await done.timeout(const Duration(seconds: 1));

        final terminals = states
            .where(
              (state) => const {
                AgentRunState.completed,
                AgentRunState.cancelled,
                AgentRunState.failed,
                AgentRunState.interrupted,
              }.contains(state.state),
            )
            .toList();
        expect(terminals, hasLength(1));
        expect(terminals.single.state, AgentRunState.cancelled);
        expect(terminals.single.runId, isNotEmpty);
        expect(
          states.every((state) => state.runId == terminals.single.runId),
          isTrue,
        );
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs.single.id, terminals.single.runId);
        expect(runs.single.status, AgentRunState.cancelled.name);
      },
    );

    test(
      'pre-terminal persistence failure emits one safe failure and closes',
      () async {
        await database.customStatement('''
CREATE TRIGGER fail_agent_run_start
BEFORE INSERT ON agent_runs
BEGIN
  SELECT RAISE(FAIL, 'run start failure');
END
''');
        final service = _buildService(
          database: database,
          provider: _ScriptedProvider(const []),
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: 'fail before terminal')
            .toList()
            .timeout(const Duration(seconds: 1));

        expect(states, hasLength(1));
        expect(states.single.state, AgentRunState.failed);
        expect(states.single.errorCode, 'runtime_error');
      },
    );

    test(
      'a completed run appends exactly one safe ActionLog with no user text',
      () async {
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        await service
            .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
            .toList();

        final logs = await (database.select(
          database.actionLogs,
        )..where((row) => row.actionType.equals('read_only_run'))).get();
        expect(logs, hasLength(1));
        final log = logs.single;
        expect(log.source, 'agent');
        expect(log.actionType, 'read_only_run');
        expect(log.result, 'success');
        // The safe summary is a tool-category count, NOT user text or raw
        // results.
        expect(log.safeSummary, contains('get_schedule'));
        expect(log.safeSummary, contains('search_campus_catalog'));
        expect(log.safeSummary, isNot(contains('明天有什么课')));
        expect(log.safeSummary, isNot(contains('图书馆在东区')));
        // Account is attributed.
        expect(log.accountId, account);
      },
    );

    test(
      'a cancelled run appends one ActionLog with result cancelled',
      () async {
        final provider = _CancellableProvider();
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        final sub = service
            .send(accountId: account, userText: '查课表')
            .listen((_) {});
        await provider.firstToolUseFired.future;
        await service.cancel(accountId: account);
        await sub.asFuture<void>(null);
        await sub.cancel();

        final logs = await (database.select(
          database.actionLogs,
        )..where((row) => row.actionType.equals('read_only_run'))).get();
        expect(logs, hasLength(1));
        expect(logs.single.result, 'cancelled');
        expect(logs.single.safeSummary, isNot(contains('查课表')));
      },
    );

    test('a failed run appends one ActionLog with result failed', () async {
      final script = [
        [const ErrorEvent('upstream_error', retryable: false)],
      ];
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '查课表')
          .toList();

      expect(states.last.state, AgentRunState.failed);
      final logs = await (database.select(
        database.actionLogs,
      )..where((row) => row.actionType.equals('read_only_run'))).get();
      expect(logs, hasLength(1));
      expect(logs.single.result, 'failed');
      expect(logs.single.safeSummary, isNot(contains('查课表')));
    });
  });

  group('retry', () {
    test(
      'retryLast creates a new run and never overwrites the failed run',
      () async {
        // First run fails.
        var provider = _ScriptedProvider([
          [const ErrorEvent('upstream_error')],
        ]);
        var clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        var service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );
        await service.send(accountId: account, userText: '查课表').toList();

        var runs = await (database.select(database.agentRuns)).get();
        expect(runs, hasLength(1));
        final failedRunId = runs.single.id;
        expect(runs.single.status, AgentRunState.failed.name);

        // Retry: new provider that succeeds.
        provider = _ScriptedProvider(_canonicalLoop());
        clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );
        final states = await service.retryLast(accountId: account).toList();

        expect(states.last.state, AgentRunState.completed);
        runs = await (database.select(database.agentRuns)).get();
        // The failed run is preserved AND a new run exists.
        expect(runs, hasLength(2));
        expect(runs.map((r) => r.id), contains(failedRunId));
        expect(
          runs.where((r) => r.status == AgentRunState.failed.name),
          hasLength(1),
        );
        expect(
          runs.where((r) => r.status == AgentRunState.completed.name),
          hasLength(1),
        );
      },
    );

    test(
      'retry does not duplicate the replayed user message in context',
      () async {
        const original = 'retry this exact message';
        final failedProvider = _ScriptedProvider([
          [const ErrorEvent('upstream_error')],
        ]);
        var service = _buildService(
          database: database,
          provider: failedProvider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );
        await service.send(accountId: account, userText: original).toList();

        final retryProvider = _ScriptedProvider([
          [const TextDeltaEvent('done'), const CompletedEvent()],
        ]);
        service = _buildService(
          database: database,
          provider: retryProvider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 13)),
        );
        await service.retryLast(accountId: account).toList();

        final replayed = retryProvider.requests.single.messages
            .expand((message) => message.content)
            .whereType<LlmTextBlock>()
            .where((block) => block.text == original);
        expect(replayed, hasLength(1));
      },
    );
  });

  group('account-scoped lifecycle and tool cancellation', () {
    test('second run for the same account is rejected', () async {
      final provider = _ConcurrentBlockingProvider();
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
      );
      final firstStates = <AgentRunViewState>[];
      final firstSubscription = service
          .send(accountId: account, userText: 'run-a')
          .listen(firstStates.add);
      final firstDone = firstSubscription.asFuture<void>();
      await provider.waitStarted('run-a');

      final rejected = await service
          .send(accountId: account, userText: 'run-a-second')
          .toList();

      expect(rejected, hasLength(1));
      expect(rejected.single.state, AgentRunState.failed);
      expect(rejected.single.errorCode, 'run_already_active');
      await service.cancel(accountId: account);
      await firstDone.timeout(const Duration(seconds: 1));
      expect(firstStates.last.state, AgentRunState.cancelled);
    });

    test('cancel for account A cannot cancel account B', () async {
      const accountB = 'b';
      await _seedAccount(database, accountB);
      final provider = _ConcurrentBlockingProvider();
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
      );
      final statesA = <AgentRunViewState>[];
      final statesB = <AgentRunViewState>[];
      final subA = service
          .send(accountId: account, userText: 'run-a')
          .listen(statesA.add);
      final doneA = subA.asFuture<void>();
      await provider.waitStarted('run-a');
      final subB = service
          .send(accountId: accountB, userText: 'run-b')
          .listen(statesB.add);
      final doneB = subB.asFuture<void>();
      await provider.waitStarted('run-b');

      expect(provider.cancelledLabels, isNot(contains('run-a')));
      await service.cancel(accountId: account);
      provider.release('run-b');
      await Future.wait([
        doneA.timeout(const Duration(seconds: 1)),
        doneB.timeout(const Duration(seconds: 1)),
      ]);

      expect(statesA.last.state, AgentRunState.cancelled);
      expect(statesB.last.state, AgentRunState.completed);
      expect(provider.cancelledLabels, contains('run-a'));
      expect(provider.cancelledLabels, isNot(contains('run-b')));
    });

    test('finishing summary A cannot clear active run B', () async {
      final provider = _SummaryOverlapProvider();
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
      );
      final statesA = <AgentRunViewState>[];
      final statesB = <AgentRunViewState>[];
      final subA = service
          .send(accountId: account, userText: 'run-a')
          .listen(statesA.add);
      final doneA = subA.asFuture<void>();
      await provider.summaryStarted.future;

      final subB = service
          .send(accountId: account, userText: 'run-b')
          .listen(statesB.add);
      final doneB = subB.asFuture<void>();
      await provider.runBStarted.future;

      provider.releaseSummary();
      await doneA.timeout(const Duration(seconds: 1));
      await service.cancel(accountId: account);
      await doneB.timeout(const Duration(seconds: 1));

      expect(statesA.last.state, AgentRunState.completed);
      expect(statesB.last.state, AgentRunState.cancelled);
    });

    test('cancel between two tool uses prevents tool two', () async {
      final cancelling = _CancellingScheduleTool();
      final second = _CountingCatalogTool();
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {},
          ),
          const ToolUseCompletedEvent(
            id: 'tu-2',
            name: 'search_campus_catalog',
            input: {},
          ),
          const CompletedEvent(),
        ],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [cancelling, second],
      );

      final states = await service
          .send(accountId: account, userText: 'cancel between tools')
          .toList();

      expect(cancelling.executeCount, 1);
      expect(second.executeCount, 0);
      expect(provider.streamCallCount, 1);
      expect(states.last.state, AgentRunState.cancelled);
    });

    test('result_too_large guidance reaches the next model request', () async {
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-guidance',
            name: 'get_schedule',
            input: {},
          ),
          const CompletedEvent(),
        ],
        [const TextDeltaEvent('narrowed'), const CompletedEvent()],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [_GuidanceScheduleTool()],
      );

      await service
          .send(accountId: account, userText: 'show a large range')
          .toList();

      final toolResult = provider.requests[1].messages
          .expand((message) => message.content)
          .whereType<LlmToolResultBlock>()
          .single;
      final payload =
          jsonDecode(toolResult.content as String) as Map<String, Object?>;
      expect(payload, {
        'code': 'result_too_large',
        'guidance': 'Narrow the date range and retry.',
      });
    });

    test('summary guard guidance reaches the next request and a changed '
        'course_summary call is not duplicate-blocked', () async {
      // Call 1: the model makes a wrong no-query `events` (default view)
      // call, which the guard rejects with schedule_summary_required.
      // Call 2: after seeing the guidance, the model retries with
      // view=course_summary, which succeeds.
      final tool = _SummaryFirstScheduleTool();
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-wide',
            name: 'get_schedule',
            input: {'from': '2026-07-01', 'through': '2026-08-04'},
          ),
          const CompletedEvent(),
        ],
        [
          const ToolUseCompletedEvent(
            id: 'tu-summary',
            name: 'get_schedule',
            input: {
              'view': 'course_summary',
              'from': '2026-07-01',
              'through': '2026-08-04',
            },
          ),
          const CompletedEvent(),
        ],
        [const TextDeltaEvent('这是本学期课程概览。'), const CompletedEvent()],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
      );

      final states = await service
          .send(accountId: account, userText: '我下学期有什么课')
          .toList();

      // The run completes grounded.
      expect(states.last.state, AgentRunState.completed);

      // The first tool_result (fed to call 2) carried the guard error code
      // and its guidance. Each subsequent request replays prior turns, so we
      // target the LAST tool result block in the request, which is the one
      // just produced by the preceding call.
      final firstToolResult = provider.requests[1].messages
          .expand((message) => message.content)
          .whereType<LlmToolResultBlock>()
          .last;
      final firstPayload =
          jsonDecode(firstToolResult.content as String) as Map<String, Object?>;
      expect(firstPayload['code'], 'schedule_summary_required');
      expect(firstPayload['guidance'], contains('course_summary'));

      // The changed course_summary call executed and was NOT duplicate
      // blocked (its arguments differ from the rejected events call, so its
      // fingerprint differs).
      expect(tool.executeCount, 2);

      // The tool_result for the successful course_summary (the last block in
      // request 2 = call 3's input) reflects the success.
      final secondToolResult = provider.requests[2].messages
          .expand((message) => message.content)
          .whereType<LlmToolResultBlock>()
          .last;
      expect(secondToolResult.isError, isFalse);
    });
  });

  group('summary scheduling', () {
    test(
      'after a successful run, schedules a tool-disabled summary when needsSummary is true',
      () async {
        // Seed a large history so AgentContextBuilder.needsSummary returns true.
        // We insert many completed turns directly via the repository.
        for (var i = 0; i < 60; i++) {
          final runId = await chatRepository.startRun(
            accountId: account,
            model: 'deepseek-v4-flash',
          );
          await chatRepository.appendMessage(
            accountId: account,
            runId: runId,
            role: ChatRole.user,
            state: ChatMessageState.completed,
            content: '这是一段很长的用户消息用于撑大上下文窗口 ${'x' * 200} 编号 $i',
          );
          await chatRepository.appendMessage(
            accountId: account,
            runId: runId,
            role: ChatRole.assistant,
            state: ChatMessageState.completed,
            content: '这是助手的回复 ${'y' * 200} 编号 $i',
          );
        }

        // The canonical loop succeeds with a LARGE reported input-token count
        // (>= 18000) so AgentContextBuilder.needsSummary returns true via the
        // real-usage path. Then a summary request is appended by the service.
        // The provider script must cover the user run (3 calls) plus the
        // summary request (1 call).
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'date': '2026-07-29'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'search_campus_catalog',
              input: {'q': '图书馆'},
            ),
            const CompletedEvent(),
          ],
          [
            const TextDeltaEvent('这是最终回复。'),
            // Large real usage so needsSummary triggers via the real-usage path.
            const UsageEvent(inputTokens: 20000, outputTokens: 30),
            const CompletedEvent(),
          ],
          // Summary request: final text only, no tools.
          [
            const TextDeltaEvent('这是一份简洁的摘要。'),
            const UsageEvent(inputTokens: 500, outputTokens: 50),
            const CompletedEvent(),
          ],
        ]);
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        await service.send(accountId: account, userText: '再问一个问题').toList();

        // 3 calls for the user run + 1 for the summary.
        expect(provider.streamCallCount, 4);

        // The summary was persisted.
        final summary = await chatRepository.latestSummary(account);
        expect(summary, isNotNull);
        expect(summary!.content, contains('摘要'));
        expect(summary.model, 'deepseek-v4-flash');
      },
    );

    test('summary failure does not block the chat', () async {
      // Seed large history.
      for (var i = 0; i < 60; i++) {
        final runId = await chatRepository.startRun(
          accountId: account,
          model: 'deepseek-v4-flash',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '长消息 ${'x' * 200} $i',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.assistant,
          state: ChatMessageState.completed,
          content: '长回复 ${'y' * 200} $i',
        );
      }

      // The user run succeeds with large reported input tokens (so
      // needsSummary triggers), then the summary request fails with an error.
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {'date': '2026-07-29'},
          ),
          const CompletedEvent(),
        ],
        [
          const ToolUseCompletedEvent(
            id: 'tu-2',
            name: 'search_campus_catalog',
            input: {'q': '图书馆'},
          ),
          const CompletedEvent(),
        ],
        [
          const TextDeltaEvent('这是最终回复。'),
          const UsageEvent(inputTokens: 20000, outputTokens: 30),
          const CompletedEvent(),
        ],
        // Summary request fails.
        [const ErrorEvent('summary_failed')],
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '再问一个问题')
          .toList();

      // The user run still completed despite the summary failure.
      expect(states.last.state, AgentRunState.completed);
      final runs = await (database.select(database.agentRuns)).get();
      expect(
        runs.where((r) => r.status == AgentRunState.completed.name),
        isNotEmpty,
      );
      // No summary persisted (the failure was swallowed).
      final summary = await chatRepository.latestSummary(account);
      expect(summary, isNull);
      // Still only ONE ActionLog for the user run (summary does not log).
      final logs = await (database.select(
        database.actionLogs,
      )..where((row) => row.actionType.equals('read_only_run'))).get();
      expect(logs, hasLength(1));
      expect(logs.single.result, 'success');
    });
  });

  group('resumeUserAction', () {
    test('unknown paused run fails without starting work', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .resumeUserAction(accountId: account, runId: 'missing')
          .toList();

      expect(states.single.state, AgentRunState.failed);
      expect(states.single.errorCode, 'paused_run_not_found');
      expect(provider.streamCallCount, 0);
    });

    test('cancel terminates a paused invocation and the owning run', () async {
      final tool = _PausingTool();
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-pause',
            name: 'pause_tool',
            input: {},
          ),
          const CompletedEvent(),
        ],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
      );
      final states = <AgentRunViewState>[];
      final subscription = service
          .send(accountId: account, userText: 'pause')
          .listen(states.add);
      final done = subscription.asFuture<void>();

      await tool.paused.future;
      await Future<void>.delayed(Duration.zero);
      expect(states.last.state, AgentRunState.waitingForUser);
      await service.cancel(accountId: account);
      await done;

      expect(tool.cancelCount, 1);
      expect(states.last.state, AgentRunState.cancelled);
      expect(provider.streamCallCount, 1);
    });

    test('dispose terminates a paused invocation', () async {
      final tool = _PausingTool();
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-pause',
            name: 'pause_tool',
            input: {},
          ),
          const CompletedEvent(),
        ],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
      );
      final states = <AgentRunViewState>[];
      final subscription = service
          .send(accountId: account, userText: 'pause')
          .listen(states.add);
      final done = subscription.asFuture<void>();

      await tool.paused.future;
      await service.dispose();
      await done;

      expect(tool.cancelCount, 1);
      expect(states.last.state, AgentRunState.cancelled);
    });

    test(
      'starting account B does not cancel the previous paused account A',
      () async {
        const secondAccount = 'b';
        await _seedAccount(database, secondAccount);
        final tool = _PausingTool();
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pause',
              name: 'pause_tool',
              input: {},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('account b'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );
        final firstStates = <AgentRunViewState>[];
        final firstSubscription = service
            .send(accountId: account, userText: 'pause')
            .listen(firstStates.add);
        final firstDone = firstSubscription.asFuture<void>();
        await tool.paused.future;

        final secondStates = await service
            .send(accountId: secondAccount, userText: 'continue')
            .toList();
        expect(tool.cancelCount, 0);
        expect(firstStates.last.state, AgentRunState.waitingForUser);

        await service.cancel(accountId: account);
        await firstDone;

        expect(tool.cancelCount, 1);
        expect(firstStates.last.state, AgentRunState.cancelled);
        expect(secondStates.last.state, AgentRunState.completed);
        expect(provider.streamCallCount, 2);
      },
    );

    test(
      'duplicate local cancel conflict cannot break cancel dispose or another account',
      () async {
        Future<void> exercise(
          Future<void> Function(
            AgentSessionService service,
            StreamSubscription<AgentRunViewState> subscription,
            List<AgentRunViewState> states,
          )
          action,
        ) async {
          final tool = _PausingTool(throwOnPendingCancel: true);
          final provider = _ScriptedProvider([
            [
              const ToolUseCompletedEvent(
                id: 'tu-pause',
                name: 'pause_tool',
                input: {},
              ),
              const CompletedEvent(),
            ],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
            tools: [tool],
          );
          final states = <AgentRunViewState>[];
          final subscription = service
              .send(accountId: account, userText: 'pause')
              .listen(states.add);
          final done = subscription.asFuture<void>();
          await tool.paused.future;
          await Future<void>.delayed(Duration.zero);

          await action(service, subscription, states);
          await done.timeout(const Duration(seconds: 1));

          expect(tool.signalCancelCount, 1);
          expect(tool.cancelCount, 1);
          expect(tool.activeCancellationSubscriptions, 0);
          expect(states.last.state, AgentRunState.cancelled);
        }

        await exercise((service, subscription, states) async {
          await service.cancel(accountId: account);
        });

        await exercise((service, subscription, states) async {
          await service.dispose();
        });

        const secondAccount = 'b';
        await _seedAccount(database, secondAccount);
        final switchTool = _PausingTool(throwOnPendingCancel: true);
        final switchProvider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pause',
              name: 'pause_tool',
              input: {},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('account b'), const CompletedEvent()],
        ]);
        final switchService = _buildService(
          database: database,
          provider: switchProvider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [switchTool],
        );
        final firstStates = <AgentRunViewState>[];
        final firstSubscription = switchService
            .send(accountId: account, userText: 'pause')
            .listen(firstStates.add);
        final firstDone = firstSubscription.asFuture<void>();
        await switchTool.paused.future;

        final secondStates = await switchService
            .send(accountId: secondAccount, userText: 'continue')
            .toList()
            .timeout(const Duration(seconds: 1));
        expect(switchTool.cancelCount, 0);
        await switchService.cancel(accountId: account);
        await firstDone.timeout(const Duration(seconds: 1));

        expect(switchTool.signalCancelCount, 1);
        expect(switchTool.cancelCount, 1);
        expect(switchTool.activeCancellationSubscriptions, 0);
        expect(firstStates.last.state, AgentRunState.cancelled);
        expect(secondStates.last.state, AgentRunState.completed);
      },
    );

    test(
      'malformed needs-user-action cancels pending work even when cancel throws',
      () async {
        final tool = _PausingTool(
          includeUserAction: false,
          throwOnPendingCancel: true,
        );
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pause',
              name: 'pause_tool',
              input: {},
            ),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: 'pause')
            .toList()
            .timeout(const Duration(seconds: 1));

        expect(tool.signalCancelCount, 1);
        expect(tool.cancelCount, 1);
        expect(tool.activeCancellationSubscriptions, 0);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'invalid_user_action');
        expect(provider.streamCallCount, 1);
        final resumeStates = await service
            .resumeUserAction(accountId: account, runId: states.first.runId)
            .toList();
        expect(resumeStates.single.errorCode, 'paused_run_not_found');
      },
    );

    test(
      'resume callback failure cancels the pending invocation and run',
      () async {
        final tool = _PausingTool();
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pause',
              name: 'pause_tool',
              input: {},
            ),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          userActionResumer:
              ({
                required String accountId,
                required AgentUserAction action,
              }) async {
                throw StateError('interactive_login_failed');
              },
        );
        final states = <AgentRunViewState>[];
        final subscription = service
            .send(accountId: account, userText: 'pause')
            .listen(states.add);
        final done = subscription.asFuture<void>();
        await tool.paused.future;
        await Future<void>.delayed(Duration.zero);
        final runId = states.last.runId;

        await service
            .resumeUserAction(accountId: account, runId: runId)
            .drain<void>()
            .timeout(const Duration(seconds: 1));
        await done.timeout(const Duration(seconds: 1));

        expect(tool.signalCancelCount, 1);
        expect(tool.cancelCount, 1);
        expect(tool.activeCancellationSubscriptions, 0);
        expect(states.last.state, AgentRunState.cancelled);
        final resumeStates = await service
            .resumeUserAction(accountId: account, runId: runId)
            .toList();
        expect(resumeStates.single.errorCode, 'paused_run_not_found');
      },
    );
  });

  group('grounding: explicit operational requests', () {
    test(
      'pending event review: plain answer -> forced tool use -> grounded final',
      () async {
        final provider = _ScriptedProvider([
          // Call 1 (auto): model answers plain text, no tool call.
          [const TextDeltaEvent('有待确认的出勤项。'), const CompletedEvent()],
          // Call 2 (any, narrowed): forced to call the review tool.
          [
            const ToolUseCompletedEvent(
              id: 'tu-review',
              name: 'get_pending_event_reviews',
              input: {},
            ),
            const CompletedEvent(),
          ],
          // Call 3: grounded final answer.
          [const TextDeltaEvent('你有 2 节课需要确认出勤。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FakePendingReviewsTool()],
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        // 3 model calls: initial, one forced correction, final.
        expect(provider.streamCallCount, 3);
        // The corrective (second) request forced `any`, narrowed declarations,
        // and omitted the original unsupported text from replay.
        final second = provider.requests[1];
        expect(second.toolChoice, LlmToolChoice.any);
        final secondToolNames = second.tools.map((t) => t.name).toSet();
        expect(secondToolNames, {'get_pending_event_reviews'});
        // Final answer grounded and accepted.
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.text, contains('需要确认出勤'));
      },
    );

    test('pending planblock review follows the same forced path', () async {
      final provider = _ScriptedProvider([
        [const TextDeltaEvent('已列出待确认的执行块。'), const CompletedEvent()],
        [
          const ToolUseCompletedEvent(
            id: 'tu-pb',
            name: 'get_pending_planblock_reviews',
            input: {},
          ),
          const CompletedEvent(),
        ],
        [const TextDeltaEvent('有 1 个执行块待你确认。'), const CompletedEvent()],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
        tools: [_FakePendingPlanBlockReviewsTool()],
      );

      final states = await service
          .send(accountId: account, userText: '有哪些执行块需要我确认？')
          .toList();

      expect(provider.streamCallCount, 3);
      expect(provider.requests[1].toolChoice, LlmToolChoice.any);
      expect(provider.requests[1].tools.map((t) => t.name).toSet(), {
        'get_pending_planblock_reviews',
      });
      expect(states.last.state, AgentRunState.completed);
    });

    test(
      'plan task hallucination: two success-prose responses -> grounding_failed',
      () async {
        var executed = 0;
        final tasksTool = _CountingSuccessTool(
          name: 'get_tasks',
          onExecute: () => executed++,
        );
        final provider = _ScriptedProvider([
          // Call 1: success prose without plan_task.
          [const TextDeltaEvent('已为你安排好了任务时间段。'), const CompletedEvent()],
          // Call 2 (forced any): still success prose without plan_task.
          [const TextDeltaEvent('任务已安排成功。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [tasksTool],
        );

        final states = await service
            .send(accountId: account, userText: '给完成操作系统大作业安排明天下午两点')
            .toList();

        // Two model calls, no corrective loop runs on forever.
        expect(provider.streamCallCount, 2);
        final terminal = states.last;
        expect(terminal.state, AgentRunState.failed);
        expect(terminal.errorCode, 'grounding_failed');
        // The unsupported success prose is replaced by the fixed safe notice.
        expect(terminal.text, '我还没有实际查询或执行这项操作，请重试。');
        // No PlanBlock write tool ran and no task was even queried.
        expect(executed, 0);
        // No business write: no PlanBlock rows were created for the
        // hallucinated plan_task, and no agent write audit for plan_task.
        final blocks = await (database.select(database.planBlocks)).get();
        expect(blocks, isEmpty);
        final writeLogs = await (database.select(
          database.actionLogs,
        )..where((row) => row.actionType.equals('plan_task'))).get();
        expect(writeLogs, isEmpty);
      },
    );

    test(
      'declined mutation is settled as non-success, not re-corrected, no false success',
      () async {
        // Simulate a write intent where the model DOES attempt the terminal
        // write but it yields a non-success (declined) result, then the model
        // dishonestly reports completion. It must NOT be re-corrected into a
        // repeat attempt AND its false success text must be overridden by a
        // fixed non-success statement — success is decided by the structured
        // tool result, not the model's wording.
        final provider = _ScriptedProvider([
          // Call 1: attempt plan_task, which fails with target_not_found.
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan-x',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-02T14:00:00+08:00',
                'end_at': '2026-08-02T15:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          // Call 2: the model falsely claims success.
          [const TextDeltaEvent('已经完成，任务时间段已安排成功。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FailingWriteTool()],
        );

        final states = await service
            .send(accountId: account, userText: '给完成操作系统大作业安排明天下午两点')
            .toList();

        // Two calls only — the attempted (failed) write was NOT re-corrected.
        expect(provider.streamCallCount, 2);
        // The run never lands on a success conclusion.
        expect(states.last.state, isNot(AgentRunState.completed));
        // The false success claim is replaced by the fixed non-success text.
        expect(states.last.text, isNot(contains('安排成功')));
        expect(states.last.text, contains('没有修改数据'));
        // The preserved safe error code is traceable.
        expect(states.last.errorCode, 'target_not_found');
      },
    );

    test(
      'free greeting: one auto call, no tools, original response preserved',
      () async {
        final provider = _ScriptedProvider([
          [const TextDeltaEvent('你好！我是你的校园助手。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
        );

        final states = await service
            .send(accountId: account, userText: '你好，介绍一下自己')
            .toList();

        expect(provider.streamCallCount, 1);
        final request = provider.requests.single;
        expect(request.toolChoice, LlmToolChoice.auto);
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.text, contains('校园助手'));
      },
    );

    test('capability question does not force a write', () async {
      final provider = _ScriptedProvider([
        [const TextDeltaEvent('我可以帮你修改日程。'), const CompletedEvent()],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
      );

      final states = await service
          .send(accountId: account, userText: '你能不能修改日程？')
          .toList();

      // One plain auto call; no forced write, no correction.
      expect(provider.streamCallCount, 1);
      expect(provider.requests.single.toolChoice, LlmToolChoice.auto);
      expect(states.last.state, AgentRunState.completed);
    });

    test(
      'forced-choice protocol error: one fallback auto request, no infinite retry',
      () async {
        final provider = _ScriptedProvider([
          // Call 1: initial auto, plain answer.
          [const TextDeltaEvent('这是出勤情况。'), const CompletedEvent()],
          // Call 2: forced `any` request -> protocol_error before any content.
          [const ErrorEvent('protocol_error')],
          // Call 3: compat fallback (auto) -> grounded final.
          [
            const ToolUseCompletedEvent(
              id: 'tu-review2',
              name: 'get_pending_event_reviews',
              input: {},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('确认完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FakePendingReviewsTool()],
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        // 4 calls: initial + any(protocol error) + auto fallback + final.
        expect(provider.streamCallCount, 4);
        // The fallback (third) request is `auto`, not a second `any`.
        expect(provider.requests[2].toolChoice, LlmToolChoice.auto);
        // No infinite retry: the run terminates.
        expect(states.last.state, AgentRunState.completed);
      },
    );

    test(
      'forced-choice auth_failed: fail immediately, NO auto fallback',
      () async {
        final provider = _ScriptedProvider([
          // Call 1: initial auto, plain answer.
          [const TextDeltaEvent('这是出勤情况。'), const CompletedEvent()],
          // Call 2: forced `any` request -> auth_failed.
          [const ErrorEvent('auth_failed')],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FakePendingReviewsTool()],
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        // auth_failed is NOT a compatibility problem: exactly two model calls,
        // no auto fallback into a third.
        expect(provider.streamCallCount, 2);
        expect(provider.requests[1].toolChoice, LlmToolChoice.any);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'auth_failed');
      },
    );

    test(
      'forced-choice rate_limited: fail after provider retries, NO session fallback',
      () async {
        final provider = _ScriptedProvider([
          [const TextDeltaEvent('这是出勤情况。'), const CompletedEvent()],
          // The provider already exhausted its own retries; it surfaces a final
          // rate_limited error. The SESSION must not fall back to auto.
          [const ErrorEvent('rate_limited')],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FakePendingReviewsTool()],
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'rate_limited');
      },
    );

    test(
      'forced-choice transport error: fail immediately, NOT a compatibility issue',
      () async {
        for (final code in const [
          'transport_error',
          'stream_transport_error',
        ]) {
          final provider = _ScriptedProvider([
            [const TextDeltaEvent('这是出勤情况。'), const CompletedEvent()],
            [ErrorEvent(code)],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
            tools: [_FakePendingReviewsTool()],
          );

          final states = await service
              .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
              .toList();

          expect(provider.streamCallCount, 2, reason: 'code=$code');
          expect(states.last.state, AgentRunState.failed, reason: 'code=$code');
          expect(states.last.errorCode, code, reason: 'code=$code');
        }
      },
    );

    test(
      'forced-choice produced content then errored: NO compatibility fallback',
      () async {
        // The forced `any` request partially emitted text/tool content before
        // erroring. A late transport/protocol error after content is NOT a
        // forced-choice compatibility problem, so no auto fallback may occur.
        final tool = _FakePendingReviewsTool();
        final provider = _ScriptedProvider([
          [const TextDeltaEvent('这是出勤情况。'), const CompletedEvent()],
          [
            const ToolUseCompletedEvent(
              id: 'tu-review-late',
              name: 'get_pending_event_reviews',
              input: {},
            ),
            const ErrorEvent('protocol_error'),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        // The tool was attempted but the stream errored AFTER content, so the
        // run fails immediately with the upstream error — no second `auto`
        // correction.
        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'protocol_error');
      },
    );

    test(
      'stop during a pending corrective request issues no subsequent model call',
      () async {
        // A provider that blocks on the first call so we can cancel while a
        // corrective request is pending — no subsequent model call may occur.
        final provider = _CancelDuringGroundingProvider();
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_FakePendingReviewsTool()],
        );

        final states = <AgentRunViewState>[];
        final sub = service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .listen(states.add);
        // Wait for the first model call to start (plain answer blocks), then
        // cancel while the corrective request is pending.
        await provider.firstCallStarted.future;
        await service.cancel(accountId: account);
        await sub.asFuture<void>(null);
        await sub.cancel();

        // Only the first call was ever started; no corrective call followed.
        expect(provider.streamCallCount, 1);
        expect(states.last.state, AgentRunState.cancelled);
      },
    );
  });

  group('grounding: terminal write outcome is authoritative', () {
    test(
      'a failed terminal write overrides false success prose and is not re-run',
      () async {
        // A terminal write that returns each non-success code, with the model
        // then falsely claiming success. The final visible text must NOT carry
        // the success claim and the write must NOT be re-executed.
        const failureCodes = <String>{
          'user_declined',
          'permission_denied',
          'target_not_found',
          'invalid_write_arguments',
          'write_commit_failed',
          'cancelled',
        };
        for (final code in failureCodes) {
          final tool = _ConfigurablePlanTaskTool(
            status: AgentToolStatus.error,
            errorCode: code,
          );
          final provider = _ScriptedProvider([
            // Call 1: attempt the terminal write (it fails with [code]).
            [
              ToolUseCompletedEvent(
                id: 'tu-plan-$code',
                name: 'plan_task',
                input: {'ref_task': 'ref_1'},
              ),
              const CompletedEvent(),
            ],
            // Call 2: the model dishonestly claims success.
            [const TextDeltaEvent('已经完成，任务时间段已安排成功。'), const CompletedEvent()],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
            tools: [tool],
          );

          final states = await service
              .send(accountId: account, userText: '给完成操作系统大作业安排明天下午两点')
              .toList();

          // Two calls only: the failed terminal write is NOT re-corrected into
          // a repeat attempt, so the write ran exactly once.
          expect(provider.streamCallCount, 2, reason: 'code=$code');
          expect(tool.executeCount, 1, reason: 'code=$code');
          // The false success claim is replaced by a fixed non-success text.
          expect(
            states.last.text,
            isNot(contains('已经完成')),
            reason: 'code=$code',
          );
          expect(
            states.last.text,
            isNot(contains('安排成功')),
            reason: 'code=$code',
          );
          expect(states.last.text, contains('没有修改数据'), reason: 'code=$code');
          // The run never lands on a success conclusion.
          expect(
            states.last.state,
            isNot(AgentRunState.completed),
            reason: 'code=$code',
          );
          // The safe error code is preserved.
          expect(states.last.errorCode, code, reason: 'code=$code');
        }
      },
    );

    test(
      'a successful terminal write preserves the model completion prose',
      () async {
        final tool = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final provider = _ScriptedProvider([
          // Call 1: attempt the terminal write (succeeds).
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan-ok',
              name: 'plan_task',
              input: {'ref_task': 'ref_1'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: the model reports completion.
          [const TextDeltaEvent('已经完成，任务时间段已安排成功。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: '给完成操作系统大作业安排明天下午两点')
            .toList();

        // Success grounded by the structured result: the completion prose is
        // preserved normally.
        expect(provider.streamCallCount, 2);
        expect(tool.executeCount, 1);
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.text, contains('安排成功'));
        expect(states.last.errorCode, isNull);
      },
    );

    test(
      'a failed read lookup for a read intent is not treated as terminal override',
      () async {
        // A pure read intent (schedule query) whose single lookup fails. It
        // has NO terminal write, so the failure must NOT be mistaken for a
        // completed mutation; it must instead follow the read grounding path
        // (a bounded correction, then grounding_failed) rather than emit a
        // "没有修改数据" terminal-override statement.
        final provider = _ScriptedProvider([
          // Call 1: attempt get_schedule, which fails.
          [
            const ToolUseCompletedEvent(
              id: 'tu-sched-fail',
              name: 'get_schedule',
              input: {'date': '2026-07-30'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: plain text, no lookup -> triggers the single correction.
          [const TextDeltaEvent('我查不到。'), const CompletedEvent()],
          // Call 3 (corrective): still no legal lookup; correction exhausted.
          [const TextDeltaEvent('还是查不到。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0)),
          tools: [_GuidanceScheduleTool()],
        );

        final states = await service
            .send(accountId: account, userText: '明天有什么课？')
            .toList();

        // The read failure settles as grounding_failed, NOT as a write
        // terminal-override (which would be wrong for a read).
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'grounding_failed');
      },
    );

    test(
      'event-event relation is grounded by get_schedule alone, never forced get_plan_blocks',
      () async {
        // A create_schedule_relation write that only needs schedule refs. The
        // EITHER/OR lookup requirement must be satisfied by get_schedule alone;
        // the run must NOT be re-corrected to demand get_plan_blocks.
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final relation = _CountingSuccessTool(name: 'create_schedule_relation');
        final provider = _ScriptedProvider([
          // Call 1: get_schedule, then terminal create_schedule_relation.
          [
            const ToolUseCompletedEvent(
              id: 'tu-s',
              name: 'get_schedule',
              input: {'date': '2026-08-03'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-r',
              name: 'create_schedule_relation',
              input: {'kind': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: final completion prose.
          [const TextDeltaEvent('已记录为冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12, 0, 0)),
          tools: [schedule, blocks, relation],
        );

        final states = await service
            .send(accountId: account, userText: '把2026年3月的那两节计算机网络课记录为冲突')
            .toList();

        // No correction was issued: get_schedule satisfied the lookup group.
        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.completed);
        // get_plan_blocks was never demanded and never called.
        expect(blocks.executeCount, 0);
        expect(relation.executeCount, 1);
      },
    );

    test(
      'PlanBlock-PlanBlock relation is grounded by get_plan_blocks alone',
      () async {
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final relation = _CountingSuccessTool(name: 'create_schedule_relation');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-b',
              name: 'get_plan_blocks',
              input: {'task': '复习'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-r',
              name: 'create_schedule_relation',
              input: {'kind': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已记录为冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12, 0, 0)),
          tools: [schedule, blocks, relation],
        );

        final states = await service
            .send(accountId: account, userText: '记录这两个执行块互相冲突')
            .toList();

        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.completed);
        expect(schedule.executeCount, 0);
        expect(relation.executeCount, 1);
      },
    );

    test(
      'relation with no ref at all is grounding_failed, no fake success',
      () async {
        // The model claims success with NO lookup and NO terminal write call.
        // The EITHER/OR groups must not be considered satisfied by nothing.
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final relation = _CountingSuccessTool(name: 'create_schedule_relation');
        final provider = _ScriptedProvider([
          // Call 1: success prose without any relation/lookup tool.
          [const TextDeltaEvent('已记录两节课的冲突。'), const CompletedEvent()],
          // Call 2 (forced any): still no legal tool.
          [const TextDeltaEvent('已记录为冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12, 0, 0)),
          tools: [schedule, blocks, relation],
        );

        final states = await service
            .send(accountId: account, userText: '记录这两节课的冲突')
            .toList();

        expect(provider.streamCallCount, 2);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'grounding_failed');
        expect(relation.executeCount, 0);
        expect(schedule.executeCount, 0);
        expect(blocks.executeCount, 0);
      },
    );
  });

  group('grounding: bounded relation runs', () {
    test(
      'relation first-request declarations are narrowed to the registered members',
      () async {
        final relation = _RecordingRelationTool();
        final schedule = _CountingEventScheduleTool();
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final provider = _ScriptedProvider([
          // Call 1: the model uses create_schedule_relation directly.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r1',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: final completion prose.
          [const TextDeltaEvent('已记录。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
          tools: [relation, schedule, blocks],
        );

        await service.send(accountId: account, userText: '记录这两节课的冲突').toList();

        // The FIRST model request declares ONLY the relation family, not the
        // whole registry.
        final first = provider.requests.first;
        final names = first.tools.map((t) => t.name).toSet();
        expect(names, {
          'get_schedule',
          'get_plan_blocks',
          'create_schedule_relation',
        });
        // Tool choice remains auto (free chat is never forced).
        expect(first.toolChoice, LlmToolChoice.auto);
      },
    );

    test(
      'relation get_schedule bounds: exact-day no-query and query views run once, unbounded calls are rejected and never reach the registry',
      () async {
        final cases =
            <({Map<String, Object?> input, bool executes, String? error})>[
              (
                input: {'from': '2026-09-01', 'through': '2026-09-01'},
                executes: true,
                error: null,
              ),
              (
                input: {'query': '计算机网络', 'view': 'events'},
                executes: true,
                error: null,
              ),
              (
                input: const {},
                executes: false,
                error: 'relation_lookup_requires_bound',
              ),
              (
                input: {'from': '2026-09-01'},
                executes: false,
                error: 'relation_lookup_requires_bound',
              ),
              (
                input: {'from': '2026-09-01', 'through': '2026-09-02'},
                executes: false,
                error: 'relation_lookup_requires_bound',
              ),
              (
                input: {
                  'from': '2026-09-01',
                  'through': '2026-09-01',
                  'view': 'course_summary',
                },
                executes: false,
                error: 'relation_lookup_requires_bound',
              ),
            ];

        for (final c in cases) {
          final schedule = _CountingEventScheduleTool();
          final relation = _RecordingRelationTool();
          final provider = _ScriptedProvider([
            // Call 1: get_schedule with this case's input.
            [
              ToolUseCompletedEvent(
                id: 'tu-s1',
                name: 'get_schedule',
                input: c.input,
              ),
              const CompletedEvent(),
            ],
            // Call 2: relation write (only reached in the executing paths).
            [
              const ToolUseCompletedEvent(
                id: 'tu-r1',
                name: 'create_schedule_relation',
                input: {'conflict_state': 'no_conflict'},
              ),
              const CompletedEvent(),
            ],
            [const TextDeltaEvent('已查到。'), const CompletedEvent()],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
            tools: [schedule, relation],
          );

          await service
              .send(accountId: account, userText: '记录这两节课的冲突')
              .toList();

          // The session guard gates BEFORE the registry: bounded cases run the
          // tool's counter, unbounded cases are intercepted and never execute.
          expect(schedule.executeCount, c.executes ? 1 : 0, reason: 'input=$c');

          if (c.error != null) {
            // The rejected call persists an error row in its own invocation
            // row, and the model hears the new error code. Rows accumulate
            // across loop cases, and each send adds exactly one get_schedule
            // invocation, so the last get_schedule row is THIS send's.
            final rows = await database.select(database.toolInvocations).get();
            final scheduleRows = rows
                .where((r) => r.toolName == 'get_schedule')
                .toList();
            expect(scheduleRows, isNotEmpty, reason: 'input=$c');
            final row = scheduleRows.last;
            expect(
              row.errorCode,
              'relation_lookup_requires_bound',
              reason: 'input=$c',
            );
            expect(
              row.status,
              ToolInvocationLifecycleState.error.storageName,
              reason: 'input=$c',
            );
            expect(
              provider.requests[1].messages
                  .expand((m) => m.content)
                  .whereType<LlmToolResultBlock>()
                  .any((tr) {
                    final payload =
                        jsonDecode(tr.content as String)
                            as Map<String, Object?>;
                    return payload['code'] == 'relation_lookup_requires_bound';
                  }),
              isTrue,
              reason: 'input=$c',
            );
          }
        }
      },
    );

    test(
      'expected no_conflict vs model conflict_state: first mismatch returns relation_state_mismatch, one changed call succeeds',
      () async {
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final relation = _RecordingRelationTool();
        final provider = _ScriptedProvider([
          // Call 1: model records conflict, but the user chose -> expected no_conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r1',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: the model corrected to no_conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r2',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已记录为不冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
          tools: [schedule, relation],
        );

        final states = await service
            .send(accountId: account, userText: '记录这两节课的冲突，我选择去量子物理 B')
            .toList();

        // The FIRST mismatch was surfaced to the model as an error, and the
        // corrected call (no_conflict) succeeded — the run completes.
        expect(states.last.state, AgentRunState.completed);
        expect(relation.conflictStates, contains('no_conflict'));
      },
    );

    test(
      'second consecutive mismatch ends safely without confirmation',
      () async {
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final relation = _RecordingRelationTool();
        final provider = _ScriptedProvider([
          // Two calls both recording conflict despite expected no_conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r1',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-r2',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
          tools: [schedule, relation],
        );

        final states = await service
            .send(accountId: account, userText: '记录这两节课的冲突，我选择去量子物理 B')
            .toList();

        // No confirmation card was shown; the run ended without landing on a
        // success conclusion and the user's choice was never silently written
        // as conflict.
        expect(relation.conflictStates, isNot(contains('no_conflict')));
        expect(states.last.state, isNot(AgentRunState.completed));
      },
    );

    test(
      'expected conflict vs model no_conflict: direction-aware guidance pushes toward conflict',
      () async {
        // Symmetric of the no_conflict-mismatch test: the user is UNRESOLVED
        // (expected conflict), the model wrongly proposes no_conflict. The
        // first-mismatch guidance must point the model toward conflict, and the
        // single corrected call must then record conflict — proving the
        // guidance is direction-aware, not hardcoded to no_conflict.
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final relation = _RecordingRelationTool();
        final provider = _ScriptedProvider([
          // Call 1: model records no_conflict, but the user is unresolved ->
          // expected conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r1',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: the model corrected to conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-r2',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已记录为冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
          tools: [schedule, relation],
        );

        final states = await service
            .send(accountId: account, userText: '记录为冲突，我还没决定')
            .toList();

        // The first mismatch was surfaced as an error carrying the
        // conflict-direction guidance (NOT "改为 no_conflict"), and the single
        // corrected call (conflict) succeeded — the run completes.
        final firstResult = provider.requests[1].messages
            .expand((m) => m.content)
            .whereType<LlmToolResultBlock>()
            .first;
        final payload =
            jsonDecode(firstResult.content as String) as Map<String, Object?>;
        expect(payload['code'], 'relation_state_mismatch');
        final guidance = payload['guidance'] as String;
        expect(guidance, contains('改为 conflict'));
        expect(guidance, isNot(contains('改为 no_conflict')));
        expect(states.last.state, AgentRunState.completed);
        expect(relation.conflictStates, contains('conflict'));
        expect(relation.conflictStates, isNot(contains('no_conflict')));
      },
    );
  });

  group('grounding: sequential write and partial completion (Task 3)', () {
    test(
      'sequential confirmation: plan_task succeeds before get_plan_blocks, relation confirmation after new PlanBlock ref, run completes after relation',
      () async {
        // The full successful workflow: get_tasks + get_schedule (shared turn),
        // plan_task, get_plan_blocks, create_schedule_relation, final text.
        // Assert the ordering via a shared call-order record.
        final order = <String>[];
        final plan = _ConfigurablePlanTaskTool(
          status: AgentToolStatus.success,
          onExecute: () => order.add('plan_task'),
        );
        var relationDone = false;
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.success,
          onExecute: () {
            order.add('create_schedule_relation');
            relationDone = true;
          },
        );
        final blocks = _CountingSuccessTool(
          name: 'get_plan_blocks',
          onExecute: () => order.add('get_plan_blocks'),
        );
        final tasks = _CountingSuccessTool(
          name: 'get_tasks',
          onExecute: () => order.add('get_tasks'),
        );
        final schedule = _CountingSuccessTool(
          name: 'get_schedule',
          onExecute: () => order.add('get_schedule'),
        );
        final provider = _ScriptedProvider([
          // Call 1: the two independent reads share one provider turn.
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-sched',
              name: 'get_schedule',
              input: {
                'from': '2026-08-03',
                'through': '2026-08-03',
                'view': 'events',
              },
            ),
            const CompletedEvent(),
          ],
          // Call 2: plan_task succeeds.
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          // Call 3: reads the new PlanBlock ref (must come AFTER plan_task).
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          // Call 4: relation write with no_conflict.
          [
            const ToolUseCompletedEvent(
              id: 'tu-rel',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          // Call 5: final text.
          [const TextDeltaEvent('已完成安排并保存关系。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        // Sequential ordering: get_plan_blocks runs strictly after plan_task,
        // the relation after that, and the run completes after relation success.
        expect(
          order.indexOf('plan_task'),
          lessThan(order.indexOf('get_plan_blocks')),
        );
        expect(
          order.indexOf('get_plan_blocks'),
          lessThan(order.indexOf('create_schedule_relation')),
        );
        expect(relationDone, isTrue);
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.errorCode, isNull);
        // plan_task called exactly once; relation called exactly once.
        expect(plan.executeCount, 1);
        expect(relation.executeCount, 1);
        // Within 8 model calls and 12 tool calls. The exact successful workflow
        // runs one tool per write step (reads share a turn), so the total tool
        // executions here are the five supporting/terminal calls (well under
        // the 12-call budget).
        expect(provider.streamCallCount, 5);
        final totalToolExecutions =
            plan.executeCount +
            relation.executeCount +
            blocks.executeCount +
            tasks.executeCount +
            schedule.executeCount;
        expect(totalToolExecutions, lessThanOrEqualTo(12));
      },
    );

    test(
      'declined planning settles failed user_declined when model stops before any relation',
      () async {
        // PlanBlock declined AND the model never attempts a relation. The
        // supporting-write branch returns overrideSupportingFailure BEFORE any
        // correction is issued (a correction could never build a relation from
        // a declined PlanBlock).
        final plan = _ConfigurablePlanTaskTool(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
        );
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.success,
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          // Final text claims success.
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        // No correction was issued — the run settles deterministically as a
        // completed supporting failure.
        expect(provider.streamCallCount, 3);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'user_declined');
        expect(states.last.text, contains('未创建执行时间段'));
        expect(states.last.text, isNot(contains('没有修改数据')));
        expect(relation.executeCount, 0);
        // plan_task runs exactly once (never re-called).
        expect(plan.executeCount, 1);
      },
    );

    test('cancelled planning settles failed cancelled, 未创建执行时间段', () async {
      final plan = _ConfigurablePlanTaskTool(
        status: AgentToolStatus.error,
        errorCode: 'cancelled',
      );
      final relation = _ConfigurableRelationTool(
        status: AgentToolStatus.success,
      );
      final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
      final tasks = _CountingSuccessTool(name: 'get_tasks');
      final schedule = _CountingSuccessTool(name: 'get_schedule');
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-tasks',
            name: 'get_tasks',
            input: {'status': 'active'},
          ),
          const CompletedEvent(),
        ],
        [
          const ToolUseCompletedEvent(
            id: 'tu-plan',
            name: 'plan_task',
            input: {
              'ref_task': 'ref_1',
              'start_at': '2026-08-03T14:00:00+08:00',
            },
          ),
          const CompletedEvent(),
        ],
        [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
        tools: [tasks, schedule, plan, blocks, relation],
      );

      final states = await service
          .send(accountId: account, userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突')
          .toList();

      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'cancelled');
      expect(states.last.text, contains('未创建执行时间段'));
      expect(plan.executeCount, 1);
      expect(relation.executeCount, 0);
    });

    test(
      'technical error planning settles failed safe error, 未创建执行时间段',
      () async {
        final plan = _ConfigurablePlanTaskTool(
          status: AgentToolStatus.error,
          errorCode: 'write_commit_failed',
        );
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.success,
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'write_commit_failed');
        // The fallback supporting-failure message states no time block was
        // created.
        expect(states.last.text, contains('执行时间段未创建'));
        expect(plan.executeCount, 1);
      },
    );

    test(
      'successful plan then declined relation: partial success preserved, 执行时间段已创建',
      () async {
        // PlanBlock succeeds; relation is declined (user_declined). This is a
        // PARTIAL completion: the PlanBlock is preserved, the relation reports
        // the declined partial fact. Must NOT say "没有修改数据".
        final plan = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-rel',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        // Partial: run failed, preserved safe relation code, partial message.
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'user_declined');
        expect(states.last.text, contains('执行时间段已创建'));
        expect(states.last.text, isNot(contains('没有修改数据')));
        expect(plan.executeCount, 1);
        expect(relation.executeCount, 1);
      },
    );

    test(
      'successful plan then cancelled relation: partial success, 已取消 variant',
      () async {
        final plan = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.error,
          errorCode: 'cancelled',
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-rel',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'cancelled');
        expect(states.last.text, contains('执行时间段已创建'));
      },
    );

    test(
      'successful plan then technical relation error: partial success, safe relation error',
      () async {
        final plan = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.error,
          errorCode: 'write_commit_failed',
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-rel',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'write_commit_failed');
        // Partial-success fact retained: 执行时间段已创建.
        expect(states.last.text, contains('执行时间段已创建'));
        expect(states.last.text, isNot(contains('没有修改数据')));
      },
    );

    test(
      'successful plan then model omits relation after correction: failed relation_not_grounded_after_plan, PlanBlock preserved',
      () async {
        // PlanBlock succeeds but the model never attempts the relation, even
        // after the single correction. Correction is exhausted with no relation
        // attempt -> partialFailure with relation_not_grounded_after_plan; the
        // PlanBlock (and its ActionLog) must remain recorded.
        final plan = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.success,
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          // Final text claims success without ever attempting the relation ->
          // triggers the single corrective call.
          [const TextDeltaEvent('已经完成。'), const CompletedEvent()],
          // Corrective call: still no relation attempt; correction exhausted.
          [const TextDeltaEvent('我已经完成了。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        // The relation was never attempted; after correction is exhausted the
        // run settles as partialFailure.
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'relation_not_grounded_after_plan');
        expect(states.last.text, contains('执行时间段已创建'));
        expect(states.last.text, isNot(contains('没有修改数据')));
        expect(relation.executeCount, 0);
        // PlanBlock ran exactly once and was preserved (never re-run/rolled
        // back by the failed or omitted relation).
        expect(plan.executeCount, 1);
      },
    );

    test(
      'successful plan then successful relation: completed, model final text accepted',
      () async {
        final plan = _ConfigurablePlanTaskTool(status: AgentToolStatus.success);
        final relation = _ConfigurableRelationTool(
          status: AgentToolStatus.success,
        );
        final blocks = _CountingSuccessTool(name: 'get_plan_blocks');
        final tasks = _CountingSuccessTool(name: 'get_tasks');
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-tasks',
              name: 'get_tasks',
              input: {'status': 'active'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-plan',
              name: 'plan_task',
              input: {
                'ref_task': 'ref_1',
                'start_at': '2026-08-03T14:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-blocks',
              name: 'get_plan_blocks',
              input: {'task': '操作系统大作业'},
            ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-rel',
              name: 'create_schedule_relation',
              input: {'conflict_state': 'no_conflict'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已完成安排并保存了不冲突关系。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 3, 12)),
          tools: [tasks, schedule, plan, blocks, relation],
        );

        final states = await service
            .send(
              accountId: account,
              userText: '给完成操作系统大作业安排明天下午两点，并记录它与其他安排不冲突',
            )
            .toList();

        expect(states.last.state, AgentRunState.completed);
        expect(states.last.errorCode, isNull);
        // Model final text accepted (not overridden).
        expect(states.last.text, contains('已完成安排'));
        expect(plan.executeCount, 1);
        expect(relation.executeCount, 1);
      },
    );
  });

  group('grounding: terminal move stay completed (real regression)', () {
    test(
      'confirmed move_jw_course_day completes and never becomes grounding_failed',
      () async {
        final schedule = _CountingSuccessTool(name: 'get_schedule');
        final move = _CountingSuccessTool(name: 'move_jw_course_day');
        final provider = _ScriptedProvider([
          // Call 1: the terminal write succeeds.
          [
            const ToolUseCompletedEvent(
              id: 'tu-move',
              name: 'move_jw_course_day',
              input: {
                'action': 'move',
                'source_date': '2026-10-01',
                'target_date': '2026-09-26',
              },
            ),
            const CompletedEvent(),
          ],
          // Call 2: plain final model turn (no further tool).
          [
            const TextDeltaEvent('已把 10 月 1 号的课程移到 9 月 26 号。'),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 8, 1, 12)),
          tools: [schedule, move],
        );

        final states = await service
            .send(accountId: account, userText: '国庆要调课，请把10月1号的调到9月26号')
            .toList();

        // The terminal write succeeded -> run completed, null error, no
        // grounding_failed regression.
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.errorCode, isNull);
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs.single.status, AgentRunState.completed.name);
        expect(runs.single.errorCode, isNull);
        // One business write (the move executed once).
        expect(move.executeCount, 1);
        // One success ActionLog for the run.
        final logs = await (database.select(
          database.actionLogs,
        )..where((row) => row.actionType.equals('read_only_run'))).get();
        expect(logs, hasLength(1));
        expect(logs.single.result, 'success');
      },
    );
  });

  group('privacy and key handling', () {
    test('the API key is supplied per call and never persisted', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      await service.send(accountId: account, userText: '查课表').toList();

      expect(provider.sawKey('ephemeral-test-key'), isTrue);
      // The key must not appear in any persisted row.
      final messages = await chatRepository.recentMessages(account, limit: 50);
      for (final m in messages) {
        expect(m.content, isNot(contains('ephemeral-test-key')));
      }
      final logs = await (database.select(database.actionLogs)).get();
      for (final l in logs) {
        expect(l.safeSummary, isNot(contains('ephemeral-test-key')));
      }
    });

    test(
      'user text that fails privacy inspection is rejected before any run starts',
      () async {
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        final states = await service
            .send(accountId: account, userText: '我的账号是 PB12345678 帮我查')
            .toList();

        // No model call was made.
        expect(provider.streamCallCount, 0);
        // No run was persisted.
        final runs = await (database.select(database.agentRuns)).get();
        expect(runs, isEmpty);
        // The view reflects a failed/rejected state.
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.text, isNot(contains('PB12345678')));
      },
    );
  });

  group('sanitization: W5 chatter/ref output regression', () {
    test(
      'a tool-use turn with interstitial text does not leak into the final answer',
      () async {
        // W5: previously, the interstitial tool-use turn text ("我来查一下…")
        // accumulated into the assistant draft alongside the final answer,
        // producing chatter. Now a tool-use turn's text is discarded (restored
        // to the pre-turn visible draft); the collapsed tile is the only
        // progress, and the final no-tool turn commits its filtered text.
        final provider = _ScriptedProvider([
          // Call 1: interstitial chatter + a tool use in the SAME turn.
          [
            const TextDeltaEvent('我来查一下你的日程，请稍等。'),
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'date': '2026-07-29'},
            ),
            const CompletedEvent(),
          ],
          // Call 2: final answer.
          [const TextDeltaEvent('你明天上午有课。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: '查日程')
            .toList();

        expect(provider.streamCallCount, 2);
        final terminal = states.last;
        expect(terminal.state, AgentRunState.completed);
        // Only the final turn's text is committed.
        expect(terminal.text, '你明天上午有课。');
        expect(terminal.text, isNot(contains('我来查一下')));
        // The interstitial chatter was not persisted either.
        final persisted = await chatRepository.recentMessages(
          account,
          limit: 50,
        );
        final assistantMsgs = persisted
            .where((m) => m.role == ChatRole.assistant)
            .toList();
        for (final m in assistantMsgs) {
          expect(m.content, isNot(contains('我来查一下')));
        }
        expect(assistantMsgs.last.content, '你明天上午有课。');
      },
    );

    test(
      'a timestamp history prefix and ref tokens are filtered from output',
      () async {
        // W5: a single final turn that BEGINS with a history timestamp marker
        // and regurgitates a run-local ref token. Both must be removed from the
        // committed answer: leading marker stripped, ref_* replaced by 该条目.
        final provider = _ScriptedProvider([
          [
            const TextDeltaEvent(
              '[2026-08-01T19:42] 我找到了 ref_YCSEZ4aCQvqoVwR6rGyGvw。明天有课。',
            ),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: '查日程')
            .toList();

        expect(states.last.state, AgentRunState.completed);
        final text = states.last.text;
        // Leading history marker stripped.
        expect(text, isNot(startsWith('[')));
        expect(text, isNot(contains('[2026-08-01T19:42]')));
        // The ref token is replaced, never leaked raw.
        expect(text, isNot(contains('ref_')));
        expect(text, contains('该条目'));
        // Legitimate answer preserved.
        expect(text, contains('明天有课'));
        // And the persisted copy matches the filtered view (no raw ref).
        final persisted = await chatRepository.recentMessages(
          account,
          limit: 50,
        );
        final assistant = persisted
            .where((m) => m.role == ChatRole.assistant)
            .single;
        expect(assistant.content, isNot(contains('ref_')));
        expect(assistant.content, isNot(contains('[2026-08-01T19:42]')));
      },
    );
  });

  group('sanitization: W8 repeated get_conflicts bound', () {
    test(
      'an exact repeated get_conflicts executes only once; repeat is bounded',
      () async {
        // W8: the model keeps calling get_conflicts with identical args. The
        // first fingerprint executes; the exact repeat is blocked with
        // `repeated_tool_call` guidance and never reaches the registry a second
        // time.
        final tool = _CountingSuccessTool(name: 'get_conflicts');
        final provider = _ScriptedProvider([
          // Call 1: two identical get_conflicts in the SAME turn.
          [
            const ToolUseCompletedEvent(
              id: 'tu-c1',
              name: 'get_conflicts',
              input: {'from': '2026-08-01', 'to': '2026-08-07'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-c2',
              name: 'get_conflicts',
              input: {
                'to': '2026-08-07',
                'from': '2026-08-01',
              }, // same content, different key order
            ),
            const CompletedEvent(),
          ],
          // Call 2: final answer.
          [const TextDeltaEvent('本周没有课表冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: '请处理一下。')
            .toList();

        // Free-chat text is accepted without a corrective loop.
        expect(provider.streamCallCount, 2);
        // ONE registry execution despite two identical tool_use blocks.
        expect(tool.executeCount, 1);
        final terminal = states.last;
        expect(terminal.state, AgentRunState.completed);
        expect(terminal.text, contains('没有课表冲突'));
        // The blocked duplicate carried a repeated_tool_call result to the model,
        // which then answered. Assert the model saw it via the second request.
        final secondRequest = provider.requests[1];
        final toolResults = secondRequest.messages
            .expand((m) => m.content)
            .whereType<LlmToolResultBlock>()
            .toList();
        expect(toolResults, hasLength(2));
        final codes = toolResults.map((tr) {
          final json = jsonDecode(tr.content as String) as Map<String, Object?>;
          return json['code'];
        }).toList();
        // First result is a real success payload; second is the bounded repeat.
        expect(codes.where((c) => c == 'repeated_tool_call'), hasLength(1));
      },
    );

    test(
      'changed arguments on the same tool execute normally (no false dedup)',
      () async {
        final tool = _CountingSuccessTool(name: 'get_conflicts');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_conflicts',
              input: {'from': '2026-08-01', 'to': '2026-08-07'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'get_conflicts',
              input: {'from': '2026-08-08', 'to': '2026-08-14'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('两段都查过了。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );

        final states = await service
            .send(accountId: account, userText: '继续处理。')
            .toList();

        // Both executed because the arguments differ.
        expect(tool.executeCount, 2);
        expect(states.last.state, AgentRunState.completed);
      },
    );
  });

  group('safe summary privacy (dedicated)', () {
    test(
      'argument summaries never contain ref_ or a student id literal PB2408',
      () {
        final args = <String, Object?>{
          'date': '2026-07-29',
          'ref_task': 'ref_1',
          'studentId': 'PB2408',
          'apiKey': 'sk-secret',
          'startAt': '2026-08-02T14:00:00+08:00',
          'scope': 'week',
          'count': 3,
          'nested': {'studentId': 'PB2408', 'name': 'Alice'},
        };
        final summary = summarizeToolArguments('plan_task', args);
        expect(summary, isNot(contains('ref_')));
        expect(summary, isNot(contains('PB2408')));
        expect(summary, isNot(contains('sk-secret')));
        expect(summary, isNot(contains('Alice')));
        // Allowed fields survive deterministically.
        expect(summary, contains('date=2026-07-29'));
        expect(summary, contains('startAt=2026-08-02T14:00:00+08:00'));
        expect(summary, contains('scope=week'));
        expect(summary, contains('count=3'));
        // Nested data is reduced to a bare count, never its contents.
        expect(summary, contains('nested=map(2)'));
      },
    );

    test(
      'result summaries carry lifecycle and safe error only, no payload values',
      () {
        final result = AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'tool_not_allowed',
          payload: {
            'courses': [
              {'title': 'PB2408 secret', 'id': 42},
            ],
            'studentId': 'PB2408',
          },
        );
        final summary = summarizeToolResult(result);
        expect(summary, contains('status=error'));
        expect(summary, contains('error=tool_not_allowed'));
        expect(summary, isNot(contains('PB2408')));
        expect(summary, isNot(contains('secret')));
        // Top-level counts only; no nested values.
        expect(summary, contains('courses=list(1)'));
        expect(summary, isNot(contains('title')));
        expect(summary, isNot(contains('id')));
      },
    );
  });

  group('tool invocation lifecycle persistence', () {
    test(
      'script success persists one running->terminal row per tool_use with safe summaries',
      () async {
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        await service
            .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
            .toList();

        // Exactly two invocation rows: one per tool_use block.
        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(2));
        final names = rows.map((r) => r.toolName).toSet();
        expect(names, {'get_schedule', 'search_campus_catalog'});
        // Every row reached a terminal success state with a finish time.
        for (final row in rows) {
          expect(row.status, ToolInvocationLifecycleState.success.storageName);
          expect(row.finishedAt, isNotNull);
          expect(row.accountId, account);
        }
        // Privacy: no ref and no student id in any safe summary.
        for (final row in rows) {
          expect(row.safeArgumentsSummary, isNot(contains('ref_')));
          expect(row.safeArgumentsSummary, isNot(contains('PB2408')));
          expect(row.safeResultSummary, isNot(contains('ref_')));
          expect(row.safeResultSummary, isNot(contains('PB2408')));
        }
        // UI count equals the persisted invocation count for the run.
        final runs = await (database.select(database.agentRuns)).get();
        final runId = runs.single.id;
        final restored = await chatRepository.toolInvocationsForRuns(
          accountId: account,
          runIds: {runId},
        );
        expect(restored, hasLength(2));
        expect(restored.length, rows.length);
      },
    );

    test(
      'deterministic error result persists an error row with a safe code',
      () async {
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'date': '2026-07-29'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('我查不到。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [_GuidanceScheduleTool()],
        );

        await service.send(accountId: account, userText: '查课表').toList();

        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(1));
        expect(
          rows.single.status,
          ToolInvocationLifecycleState.error.storageName,
        );
        expect(rows.single.errorCode, 'result_too_large');
        expect(rows.single.safeArgumentsSummary, isNot(contains('ref_')));
        expect(rows.single.safeArgumentsSummary, isNot(contains('PB2408')));
        expect(rows.single.safeResultSummary, contains('result_too_large'));
      },
    );

    test(
      'duplicate fingerprint call persists a second error row, no second execution',
      () async {
        final tool = _CountingSuccessTool(name: 'get_conflicts');
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-c1',
              name: 'get_conflicts',
              input: {'from': '2026-08-01', 'to': '2026-08-07'},
            ),
            const ToolUseCompletedEvent(
              id: 'tu-c2',
              name: 'get_conflicts',
              input: {'to': '2026-08-07', 'from': '2026-08-01'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('本周没有课表冲突。'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );

        await service.send(accountId: account, userText: '继续处理。').toList();

        // One registry execution, but TWO rows: the repeated model tool_use
        // still consumes a row finished as an error.
        expect(tool.executeCount, 1);
        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(2));
        final codes = rows.map((r) => r.errorCode).toSet();
        expect(codes, contains('repeated_tool_call'));
        expect(codes, contains(isNull));
      },
    );

    test(
      'budget rejection persists the exceeded call as an error row',
      () async {
        final twoToolsPerCall = [
          const ToolUseCompletedEvent(
            id: 'tu-a',
            name: 'get_schedule',
            input: {'date': '2026-07-29'},
          ),
          const ToolUseCompletedEvent(
            id: 'tu-b',
            name: 'search_campus_catalog',
            input: {'q': 'x'},
          ),
          const CompletedEvent(),
        ];
        final provider = _ScriptedProvider(
          List<List<LlmEvent>>.filled(20, twoToolsPerCall),
        );
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: '无限工具')
            .toList();

        // The call that tripped the budget ceiling still gets a row.
        expect(states.last.state, isNot(AgentRunState.running));
        final rows = await database.select(database.toolInvocations).get();
        expect(rows, isNotEmpty);
        expect(
          rows.any((r) => r.errorCode == 'tool_call_budget_exceeded'),
          isTrue,
        );
      },
    );

    test(
      'cancellation persists every unstarted tool_use as a cancelled row',
      () async {
        final provider = _CancellableProvider();
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final subscription = service
            .send(accountId: account, userText: '查课表')
            .listen((_) {});
        await provider.firstToolUseFired.future;
        await service.cancel(accountId: account);
        await subscription.asFuture<void>(null);
        await subscription.cancel();

        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(1));
        expect(
          rows.single.status,
          ToolInvocationLifecycleState.cancelled.storageName,
        );
        expect(rows.single.safeArgumentsSummary, isNot(contains('ref_')));
        expect(rows.single.safeArgumentsSummary, isNot(contains('PB2408')));
      },
    );

    test(
      'pause tool marks the same row waiting then finishes it terminal',
      () async {
        final tool = _PausingTool();
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pause',
              name: 'pause_tool',
              input: {},
            ),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
        );
        final states = <AgentRunViewState>[];
        final subscription = service
            .send(accountId: account, userText: 'pause')
            .listen(states.add);
        final done = subscription.asFuture<void>();

        // While paused, the row must be in the waiting_user state.
        await tool.paused.future;
        await Future<void>.delayed(Duration.zero);
        var rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(1));
        expect(
          rows.single.status,
          ToolInvocationLifecycleState.waitingUser.storageName,
        );

        await service.cancel(accountId: account);
        await done;

        // After terminal (cancelled), the SAME row id moved waiting -> terminal.
        rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(1));
        expect(
          rows.single.status,
          ToolInvocationLifecycleState.cancelled.storageName,
        );
      },
    );
  });

  group('create task burst — session integration', () {
    // Builds a provider that emits a single model-call turn of [count]
    // create_task tool uses (ids tu-0..tu-count-1, distinct inputs so each
    // call is a unique fingerprint), then a final text turn with no tools.
    List<List<LlmEvent>> burstScript(int count) => [
      [
        for (var i = 0; i < count; i++)
          ToolUseCompletedEvent(
            id: 'tu-$i',
            name: 'create_task',
            input: {'title': 'T$i', 'date': '2026-08-${(i % 9) + 1}'},
          ),
        const CompletedEvent(),
      ],
      [const TextDeltaEvent('final burst answer'), const CompletedEvent()],
    ];

    test('13 create_task calls under a 32 limit run as a burst: all execute, '
        '13 rows, no budget error, completed', () async {
      final tool = _BurstCreateTaskTool(List.filled(13, 'success'));
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(tool.executeCount, 13);
      expect(provider.streamCallCount, 2);
      final errorCodes = states.map((s) => s.errorCode).toSet();
      expect(errorCodes.contains('tool_call_budget_exceeded'), isFalse);
      expect(states.last.state, AgentRunState.completed);
      final rows = await database.select(database.toolInvocations).get();
      expect(rows, hasLength(13));
      expect(rows.where((r) => r.status == 'success').length, 13);
    });

    test(
      'a normal turn before and after the burst leaves the normal count at two '
      'and the burst does not consume the normal quota',
      () async {
        // Call 1: one course_summary-ish normal get_schedule before.
        // Call 2: the 13-call burst.
        // Call 3: one normal read after.
        // Call 4: final text.
        final provider = _ScriptedProvider([
          [
            const ToolUseCompletedEvent(
              id: 'tu-pre',
              name: 'get_schedule',
              input: {'date': '2026-07-29'},
            ),
            const CompletedEvent(),
          ],
          [
            for (var i = 0; i < 13; i++)
              ToolUseCompletedEvent(
                id: 'tu-b$i',
                name: 'create_task',
                input: {'title': 'B$i'},
              ),
            const CompletedEvent(),
          ],
          [
            const ToolUseCompletedEvent(
              id: 'tu-post',
              name: 'search_campus_catalog',
              input: {'q': 'x'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('done'), const CompletedEvent()],
        ]);
        final tool = _BurstCreateTaskTool(List.filled(13, 'success'));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _CreateTaskBurstPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '每周创建 Task')
            .toList();

        expect(states.last.state, AgentRunState.completed);
        // 1 normal get_schedule + 1 normal search + 13 burst = 15 tool rows.
        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(15));
        expect(tool.executeCount, 13);
      },
    );

    test('33 create_task calls return create_task_burst_too_large with zero '
        'registry executions and zero successful rows', () async {
      final tool = _BurstCreateTaskTool(List.filled(33, 'success'));
      final provider = _ScriptedProvider([
        [
          for (var i = 0; i < 33; i++)
            ToolUseCompletedEvent(
              id: 'tu-t$i',
              name: 'create_task',
              input: {'title': 'T$i'},
            ),
          const CompletedEvent(),
        ],
      ]);
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'create_task_burst_too_large');
      expect(tool.executeCount, 0);
      // Blocked/error invocation rows for every received block.
      final rows = await database.select(database.toolInvocations).get();
      expect(rows, hasLength(33));
      expect(rows.where((r) => r.status == 'error').length, 33);
      expect(rows.where((r) => r.status == 'success'), isEmpty);
      // Zero Task writes. Tasks live in a separate table; assert no success
      // summary rows were produced.
      expect(
        rows
            .map((r) => r.safeResultSummary)
            .where((s) => s.contains('status=success')),
        isEmpty,
      );
    });

    test(
      'a mixed turn that exceeds remaining normal quota is rejected with '
      'create_task_burst_requires_dedicated_turn and nothing executes',
      () async {
        // Consume the full normal budget with non-burst turns first, so the
        // mixed create_task turn cannot fit. Use repeated get_schedule calls.
        final pre = List.generate(
          AgentRunToolBudget.normalLimit,
          (i) => const ToolUseCompletedEvent(
            id: 'tu-pre',
            name: 'get_schedule',
            input: {'date': '2026-07-29'},
          ),
        );
        final provider = _ScriptedProvider([
          [...pre, const CompletedEvent()],
          // Mixed turn: 8 calls, includes create_task but exceeds none remaining.
          [
            for (var i = 0; i < 4; i++)
              ToolUseCompletedEvent(
                id: 'tu-m$i',
                name: 'get_schedule',
                input: {'date': '2026-07-29'},
              ),
            for (var i = 0; i < 4; i++)
              ToolUseCompletedEvent(
                id: 'tu-c$i',
                name: 'create_task',
                input: {'title': 'C$i'},
              ),
            const CompletedEvent(),
          ],
        ]);
        final tool = _BurstCreateTaskTool(List.filled(4, 'success'));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _CreateTaskBurstPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '每周创建 Task')
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(
          states.last.errorCode,
          'create_task_burst_requires_dedicated_turn',
        );
        // None of the mixed turn's create_task tools executed.
        expect(tool.executeCount, 0);
      },
    );

    test(
      'a second eligible pure burst turn returns create_task_burst_already_used '
      'and none of its calls executes',
      () async {
        final tool = _BurstCreateTaskTool(List.filled(13, 'success'));
        final provider = _ScriptedProvider([
          // First burst turn.
          [
            for (var i = 0; i < 13; i++)
              ToolUseCompletedEvent(
                id: 'tu-a$i',
                name: 'create_task',
                input: {'title': 'A$i'},
              ),
            const CompletedEvent(),
          ],
          // Second burst turn (still 13 pure create_task).
          [
            for (var i = 0; i < 13; i++)
              ToolUseCompletedEvent(
                id: 'tu-b$i',
                name: 'create_task',
                input: {'title': 'B$i'},
              ),
            const CompletedEvent(),
          ],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _CreateTaskBurstPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '每周创建 Task')
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'create_task_burst_already_used');
        // Only the first burst's 13 create_task ran.
        expect(tool.executeCount, 13);
        final rows = await database.select(database.toolInvocations).get();
        // 13 successful burst rows + 13 rejected rows.
        expect(rows, hasLength(26));
      },
    );

    test('13 success -> completed with the lease accepting and 13 independent '
        'writes remaining', () async {
      final tool = _BurstCreateTaskTool(List.filled(13, 'success'));
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(tool.executeCount, 13);
      expect(states.last.state, AgentRunState.completed);
      expect(states.last.text, contains('final burst answer'));
    });

    test('12 success + 1 declined -> failed/create_task_burst_partial with the '
        'lease message persisted and 12 writes remaining', () async {
      final outcomes = List.generate(12, (_) => 'success');
      outcomes.add('user_declined');
      final tool = _BurstCreateTaskTool(outcomes);
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(tool.executeCount, 13);
      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'create_task_burst_partial');
      expect(states.last.text, '已创建 12 个 Task，1 个未完成。其中 1 个已取消。');
      expect(states.last.text, isNot(contains('没有修改数据')));
      expect(states.last.text, isNot(contains('请求失败，未生成回答')));

      final persisted = await database.select(database.chatMessages).get();
      final assistant = persisted
          .where((m) => m.role == ChatRole.assistant.name)
          .last;
      expect(assistant.content, '已创建 12 个 Task，1 个未完成。其中 1 个已取消。');
      final rows = await database.select(database.toolInvocations).get();
      expect(rows.where((r) => r.status == 'success').length, 12);
      expect(rows.where((r) => r.status == 'error').length, 1);
    });

    test('12 success + 1 technical error -> failed/create_task_burst_partial, '
        '12 writes remaining', () async {
      final outcomes = List.generate(12, (_) => 'success');
      outcomes.add('write_failed');
      final tool = _BurstCreateTaskTool(outcomes);
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'create_task_burst_partial');
      expect(states.last.text, '已创建 12 个 Task，1 个未完成。失败原因：write_failed 1 个。');
      expect(states.last.text, isNot(contains('没有修改数据')));
      final rows = await database.select(database.toolInvocations).get();
      expect(rows.where((r) => r.status == 'success').length, 12);
    });

    test('0 success + 13 declined -> failed/create_task_burst_failed with zero '
        'successful writes', () async {
      final tool = _BurstCreateTaskTool(List.filled(13, 'user_declined'));
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      expect(tool.executeCount, 13);
      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'create_task_burst_failed');
      expect(states.last.text, '未创建任何 Task。其中 13 个已取消。');
      expect(states.last.text, isNot(contains('没有修改数据')));
      final rows = await database.select(database.toolInvocations).get();
      expect(rows.where((r) => r.status == 'success'), isEmpty);
    });

    test(
      '12 success + 1 duplicate -> repeated_tool_call counted and partial',
      () async {
        // 12 distinct successes, then a 13th call that is an EXACT duplicate
        // of the first (same title -> same fingerprint). The fingerprint guard
        // blocks it as repeated_tool_call before a second registry execution.
        final tool = _BurstCreateTaskTool(List.filled(12, 'success'));
        final provider = _ScriptedProvider([
          [
            for (var i = 0; i < 12; i++)
              ToolUseCompletedEvent(
                id: 'tu-d$i',
                name: 'create_task',
                input: {'title': 'Dup$i'},
              ),
            // Exact duplicate of tu-d0.
            const ToolUseCompletedEvent(
              id: 'tu-dup',
              name: 'create_task',
              input: {'title': 'Dup0'},
            ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('final'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _CreateTaskBurstPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '每周创建 Task')
            .toList();

        // The duplicate is never re-executed.
        expect(tool.executeCount, 12);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'create_task_burst_partial');
        expect(
          states.last.text,
          '已创建 12 个 Task，1 个未完成。失败原因：repeated_tool_call 1 个。',
        );
        final rows = await database.select(database.toolInvocations).get();
        expect(rows, hasLength(13));
        expect(
          rows.where((r) => r.errorCode == 'repeated_tool_call').length,
          1,
        );
      },
    );

    test('Stop after N success -> cancelled with N writes remaining and '
        'remaining calls not replayed', () async {
      // 13 success outcomes but cancel during the 5th call (index 4).
      final tool = _BurstCreateTaskTool(
        List.filled(13, 'success'),
        cancelOn: 4,
      );
      final provider = _ScriptedProvider(burstScript(13));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _CreateTaskBurstPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '每周创建 Task')
          .toList();

      // Cancellation wins over any partial aggregation.
      expect(states.last.state, AgentRunState.cancelled);
      // The 5th call (index 4) executes successfully and itself triggers the
      // cancel; the 8 remaining blocks are recorded cancelled and NEVER
      // replayed or executed.
      expect(tool.executeCount, 5);
      final rows = await database.select(database.toolInvocations).get();
      // 5 succeeded + 8 cancelled rows.
      expect(rows.where((r) => r.status == 'success').length, 5);
      expect(
        rows
            .where(
              (r) =>
                  r.status ==
                  ToolInvocationLifecycleState.cancelled.storageName,
            )
            .length,
        8,
      );
    });
  });

  // Task 10: the sequential mutation ledger aggregates a lifecycle mutation
  // run's terminal results into a 成功/拒绝/失败/未处理 count and overrides the
  // model's (possibly false) text. It never expands the budget, never saves
  // titles/refs, and never auto-continues.
  group('mutation ledger — sequential lifecycle aggregation (Task 10)', () {
    // A configurable lifecycle write tool whose outcome sequence is scripted.
    // Each execute() returns the next outcome in the list. Distinct inputs keep
    // every call a unique fingerprint so the dedup guard never fires.
    List<List<LlmEvent>> lifecycleScript(int count, List<String> outcomes) =>
        [
          [
            for (var i = 0; i < count; i++)
              ToolUseCompletedEvent(
                id: 'tu-$i',
                name: 'delete_schedule_relation',
                input: {'ref_relation': 'ref_$i'},
              ),
            const CompletedEvent(),
          ],
          [const TextDeltaEvent('已删除全部关系。'), const CompletedEvent()],
        ];

    test(
      'all-success lifecycle run stays completed (ledger has no override)',
      () async {
        final tool = _LifecycleWriteTool(
          name: 'delete_schedule_relation',
          outcomes: List.filled(3, 'success'),
        );
        final provider = _ScriptedProvider(lifecycleScript(3, ['success']));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _DeleteRelationPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '删除这两节课的冲突关系')
            .toList();

        expect(tool.executeCount, 3);
        expect(states.last.state, AgentRunState.completed);
      },
    );

    test(
      'partial lifecycle run (2 success + 1 declined) -> failed '
      'mutation_partial with the ledger count message',
      () async {
        final tool = _LifecycleWriteTool(
          name: 'delete_schedule_relation',
          outcomes: ['success', 'success', 'user_declined'],
        );
        final provider = _ScriptedProvider(lifecycleScript(3, ['x']));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _DeleteRelationPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '删除这两节课的冲突关系')
            .toList();

        expect(tool.executeCount, 3);
        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'mutation_partial');
        // The ledger's deterministic count message overrides the model's false
        // "已删除全部关系" text.
        expect(states.last.text, contains('成功 2'));
        expect(states.last.text, contains('拒绝 1'));
        expect(states.last.text, isNot(contains('已删除全部关系')));
      },
    );

    test(
      'all-failed lifecycle run -> failed mutation_failed with the count '
      'message and safe error code',
      () async {
        final tool = _LifecycleWriteTool(
          name: 'delete_schedule_relation',
          outcomes: ['target_not_found', 'permission_denied'],
        );
        final provider = _ScriptedProvider(lifecycleScript(2, ['x']));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
          tools: [tool],
          groundingPolicy: const _DeleteRelationPolicy(),
        );

        final states = await service
            .send(accountId: account, userText: '删除这两节课的冲突关系')
            .toList();

        expect(states.last.state, AgentRunState.failed);
        expect(states.last.errorCode, 'mutation_failed');
        expect(states.last.text, contains('成功 0'));
        expect(states.last.text, contains('失败 2'));
        expect(states.last.text, contains('target_not_found 1'));
        expect(states.last.text, contains('permission_denied 1'));
      },
    );

    test('the ledger message never leaks titles, refs, or ids', () async {
      final tool = _LifecycleWriteTool(
        name: 'delete_schedule_relation',
        outcomes: ['reference_not_found'],
        payload: {'title': '量子物理 B', 'ref': 'ref_42', 'id': 'rel-999'},
      );
      final provider = _ScriptedProvider(lifecycleScript(1, ['x']));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _DeleteRelationPolicy(),
      );

      final states = await service
          .send(accountId: account, userText: '删除这两节课的冲突关系')
          .toList();

      expect(states.last.text, isNot(contains('量子物理')));
      expect(states.last.text, isNot(contains('ref_42')));
      expect(states.last.text, isNot(contains('rel-999')));
    });

    test('the ledger does not expand the budget (3 calls stay within 12)',
        () async {
      final tool = _LifecycleWriteTool(
        name: 'delete_schedule_relation',
        outcomes: List.filled(3, 'success'),
      );
      final provider = _ScriptedProvider(lifecycleScript(3, ['x']));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        tools: [tool],
        groundingPolicy: const _DeleteRelationPolicy(),
      );

      await service
          .send(accountId: account, userText: '删除这两节课的冲突关系')
          .toList();

      // 3 normal tool rows, no budget error.
      final rows = await database.select(database.toolInvocations).get();
      expect(rows, hasLength(3));
      expect(
        rows.where((r) => r.errorCode == 'tool_call_budget_exceeded').length,
        0,
      );
    });
  });

  // Task 10 §5: a single forced-correction boundary. A lifecycle mutation
  // that calls NO tool on the first try is forced ONCE with the related tools
  // + tool_choice=any; free chat is never corrected; after a reject/stale/
  // cancel/tech-error the same delete is never auto-retried.
  group(
    'mutation ledger — single forced-correction boundary (Task 10 §5)',
    () {
      test(
        'lifecycle mutation with no tool on first try -> one forced any call '
        'with narrowed tools',
        () async {
          final tool = _LifecycleWriteTool(
            name: 'delete_schedule_relation',
            outcomes: ['success'],
          );
          final provider = _ScriptedProvider([
            // Call 1 (auto): plain answer, no tool call.
            [const TextDeltaEvent('已删除关系。'), const CompletedEvent()],
            // Call 2 (any, narrowed): forced to call delete_schedule_relation.
            [
              const ToolUseCompletedEvent(
                id: 'tu-del',
                name: 'delete_schedule_relation',
                input: {'ref_relation': 'ref_1'},
              ),
              const CompletedEvent(),
            ],
            // Call 3: grounded final answer.
            [
              const TextDeltaEvent('已删除该冲突关系。'),
              const CompletedEvent(),
            ],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
            tools: [tool],
            groundingPolicy: const _DeleteRelationPolicy(),
          );

          final states = await service
              .send(accountId: account, userText: '删除这两节课的冲突关系')
              .toList();

          // 3 model calls: initial, one forced correction, final.
          expect(provider.streamCallCount, 3);
          // The corrective (second) request forced `any`.
          final second = provider.requests[1];
          expect(second.toolChoice, LlmToolChoice.any);
          final secondToolNames = second.tools.map((t) => t.name).toSet();
          expect(secondToolNames, contains('delete_schedule_relation'));
          // Final answer grounded and accepted.
          expect(states.last.state, AgentRunState.completed);
        },
      );

      test(
        'a rejected lifecycle delete is never auto-retried (no second '
        'correction)',
        () async {
          final tool = _LifecycleWriteTool(
            name: 'delete_schedule_relation',
            outcomes: ['user_declined'],
          );
          final provider = _ScriptedProvider([
            // Call 1: attempt delete, declined by user.
            [
              const ToolUseCompletedEvent(
                id: 'tu-del',
                name: 'delete_schedule_relation',
                input: {'ref_relation': 'ref_1'},
              ),
              const CompletedEvent(),
            ],
            // Call 2: the model falsely claims success.
            [const TextDeltaEvent('已删除该关系。'), const CompletedEvent()],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
            tools: [tool],
            groundingPolicy: const _DeleteRelationPolicy(),
          );

          final states = await service
              .send(accountId: account, userText: '删除这两节课的冲突关系')
              .toList();

          // Two calls only — the declined write was NOT re-corrected.
          expect(provider.streamCallCount, 2);
          expect(states.last.state, AgentRunState.failed);
          // The ledger's count overrides the false success claim.
          expect(states.last.text, contains('拒绝 1'));
          expect(states.last.text, isNot(contains('已删除该关系')));
        },
      );

      test(
        'a technical-error lifecycle delete is never auto-retried',
        () async {
          final tool = _LifecycleWriteTool(
            name: 'delete_schedule_relation',
            outcomes: ['stale_target'],
          );
          final provider = _ScriptedProvider([
            [
              const ToolUseCompletedEvent(
                id: 'tu-del',
                name: 'delete_schedule_relation',
                input: {'ref_relation': 'ref_1'},
              ),
              const CompletedEvent(),
            ],
            [const TextDeltaEvent('已删除。'), const CompletedEvent()],
          ]);
          final service = _buildService(
            database: database,
            provider: provider,
            clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
            tools: [tool],
            groundingPolicy: const _DeleteRelationPolicy(),
          );

          final states = await service
              .send(accountId: account, userText: '删除这两节课的冲突关系')
              .toList();

          expect(provider.streamCallCount, 2);
          expect(states.last.state, AgentRunState.failed);
          expect(states.last.text, contains('失败 1'));
          expect(states.last.text, contains('stale_target 1'));
        },
      );

      test('free chat is never corrected (one auto call, no forcing)', () async {
        final provider = _ScriptedProvider([
          [const TextDeltaEvent('你好！'), const CompletedEvent()],
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );

        final states = await service
            .send(accountId: account, userText: '你好，介绍一下自己')
            .toList();

        expect(provider.streamCallCount, 1);
        final request = provider.requests.single;
        expect(request.toolChoice, LlmToolChoice.auto);
        expect(states.last.state, AgentRunState.completed);
      });
    },
  );
}

// ---------------------------------------------------------------------------
// Task 10 helpers: a configurable lifecycle write tool and a delete-relation
// grounding policy, used by the mutation-ledger integration tests.
// ---------------------------------------------------------------------------

/// A lifecycle write tool whose outcome sequence is scripted. Each execute()
/// returns the next outcome in [outcomes]. Distinct inputs keep every call a
/// unique fingerprint so the dedup guard never fires prematurely. An optional
/// [payload] is attached to error results so tests can assert it never leaks.
class _LifecycleWriteTool implements AgentTool {
  _LifecycleWriteTool({
    required this.name,
    required this.outcomes,
    this.payload,
  });

  @override
  final String name;
  final List<String> outcomes;
  final Map<String, Object?>? payload;
  int executeCount = 0;

  @override
  String get description => 'A lifecycle write tool (configurable).';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final index = executeCount;
    executeCount++;
    final code = index < outcomes.length ? outcomes[index] : 'success';
    if (code == 'success') {
      return const AgentToolResult(
        status: AgentToolStatus.success,
        payload: {'result': 'ok'},
      );
    }
    return AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: code,
      payload: payload ?? const {'guidance': '写操作未成功。'},
    );
  }
}

/// A grounding policy that always classifies the user text as a
/// delete_schedule_relation mutation with a get_schedule_relations lookup.
/// Used so the ledger integration tests exercise the lifecycle mutation path
/// deterministically regardless of the userText phrasing.
class _DeleteRelationPolicy extends AgentGroundingPolicy {
  const _DeleteRelationPolicy();

  @override
  AgentGroundingRequirement? classify(String userText) =>
      const AgentGroundingRequirement(
        lookupTools: {'get_schedule_relations'},
        terminalTools: {'delete_schedule_relation'},
        mutationIntent: true,
      );
}

// ---------------------------------------------------------------------------
// A provider that emits one tool_use and then blocks until cancelled, to test
// stop-prevents-a-new-call semantics.
// ---------------------------------------------------------------------------

class _CancellableProvider implements LlmProvider {
  int streamCallCount = 0;
  final Completer<void> firstToolUseFired = Completer<void>();

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    streamCallCount++;
    if (streamCallCount == 1) {
      yield const ToolUseCompletedEvent(
        id: 'tu-1',
        name: 'get_schedule',
        input: {'date': '2026-07-29'},
      );
      if (!firstToolUseFired.isCompleted) firstToolUseFired.complete();
      // Wait until cancelled, then end the stream cleanly.
      while (!cancellation.isCancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      yield const CompletedEvent();
      return;
    }
    // A second call should never happen; emit an error if it does.
    yield const ErrorEvent('unexpected_second_call');
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}

/// A provider whose first call yields a plain answer (making a corrective
/// request pending) and then blocks until cancelled. A second call is an
/// unexpected error — proving stop during a pending corrective request issues
/// no further model call.
class _CancelDuringGroundingProvider implements LlmProvider {
  int streamCallCount = 0;
  int attemptsAfterFirst = 0;
  final Completer<void> firstCallStarted = Completer<void>();

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    streamCallCount++;
    if (streamCallCount == 1) {
      if (!firstCallStarted.isCompleted) firstCallStarted.complete();
      yield const TextDeltaEvent('这是出勤情况。');
      // Block until cancelled so the run stays in a corrective-pending state.
      while (!cancellation.isCancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      yield const CompletedEvent();
      return;
    }
    attemptsAfterFirst++;
    yield const ErrorEvent('unexpected_second_call');
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}
