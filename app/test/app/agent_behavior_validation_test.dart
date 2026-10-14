import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/agent_behavior_validation.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

const _authority = AgentAuthority(
  owner: 'synthetic-validation-owner',
  resetEpoch: 1,
  historyEpoch: 0,
  configRevision: 1,
);
const _syntheticKey = 'SYNTHETIC_TEST_KEY_4ac9';
const _replySentinel = '合成模型回复泄漏哨兵';
const _privateNote = '优先复习等效电路';
const _validationModel = 'synthetic-behavior-model';

void main() {
  test(
    'explicit start completes 14 synthetic cases without leaking replies or secrets',
    () async {
      final configuration = _ConfigurationOnly();
      final gateways = <_SyntheticGateway>[];
      var factoryCalls = 0;
      final runner = AgentBehaviorValidationRunner(
        modelConfiguration: configuration,
        gatewayFactory: () {
          factoryCalls++;
          final gateway = _SyntheticGateway();
          gateways.add(gateway);
          return gateway;
        },
      );

      expect(runner.view.busy, isFalse);
      expect(runner.view.requests, 0);
      expect(runner.view.results, isEmpty);
      expect(factoryCalls, 0);
      expect(configuration.inspectCalls, 0);
      expect(configuration.leaseCalls, 0);

      await runner.start();

      expect(runner.view.busy, isFalse);
      expect(runner.view.failure, isNull);
      expect(
        runner.view.results,
        hasLength(AgentBehaviorValidationRunner.caseCount),
      );
      expect(runner.view.requests, greaterThan(0));
      expect(
        runner.view.requests,
        lessThanOrEqualTo(AgentBehaviorValidationRunner.requestLimit),
      );
      expect(runner.view.inputTokens, isNotNull);
      expect(runner.view.outputTokens, isNotNull);
      expect(runner.view.inputTokens, greaterThan(0));
      expect(runner.view.outputTokens, greaterThan(0));
      expect(configuration.illegalCalls, isEmpty);
      expect(configuration.leaseCalls, runner.view.requests);
      expect(configuration.issuedLeases, hasLength(runner.view.requests));
      expect(
        configuration.issuedLeases.every((lease) => !lease.isAvailable),
        isTrue,
      );
      expect(gateways, hasLength(AgentBehaviorValidationRunner.caseCount));
      expect(gateways.every((gateway) => gateway.listModelCalls == 0), isTrue);
      expect(
        gateways.fold<int>(
          0,
          (count, gateway) => count + gateway.generateCalls,
        ),
        runner.view.requests,
      );
      expect(
        gateways.expand((gateway) => gateway.receivedKeys),
        everyElement(_syntheticKey),
      );
      expect(
        gateways
            .expand((gateway) => gateway.requests)
            .every(
              (request) =>
                  request.modelId == _validationModel &&
                  !request.messages.any(
                    (message) =>
                        (message.content ?? '').contains(_syntheticKey) ||
                        (message.content ?? '').contains(
                          'synthetic-validation-placeholder',
                        ),
                  ),
            ),
        isTrue,
      );

      final summaryText = runner.safeSummary();
      final summary = jsonDecode(summaryText) as Map<String, dynamic>;
      expect(summary['cases'], AgentBehaviorValidationRunner.caseCount);
      expect(summary['plannedCases'], AgentBehaviorValidationRunner.caseCount);
      expect(summary['requests'], runner.view.requests);
      expect(summary.keys.toSet(), {
        'kind',
        'busy',
        'cases',
        'plannedCases',
        'requests',
        'requestLimit',
        'inputTokens',
        'outputTokens',
        'failure',
        'syntheticOnly',
        'realModelQualityRequiresReview',
        'results',
      });
      expect(summary.containsKey('reply'), isFalse);
      final rows = (summary['results'] as List).cast<Map<String, dynamic>>();
      expect(rows, hasLength(AgentBehaviorValidationRunner.caseCount));
      for (final row in rows) {
        expect(row.keys.toSet(), {
          'scenario',
          'business',
          'constraints',
          'requests',
          'replyNeedsReview',
          'failure',
        });
        expect(row.containsKey('reply'), isFalse);
      }
      final personalRead = rows.singleWhere(
        (row) => row['scenario'] == AgentBehaviorCase.personalRead.name,
      );
      expect(personalRead['business'], isFalse);
      expect(personalRead['constraints'], isTrue);
      final adviceOnly = rows.singleWhere(
        (row) => row['scenario'] == AgentBehaviorCase.adviceOnly.name,
      );
      expect(adviceOnly['business'], isFalse);
      expect(adviceOnly['constraints'], isTrue);
      for (final sentinel in [
        _syntheticKey,
        'synthetic-validation-placeholder',
        _replySentinel,
        _privateNote,
        '验核复习',
        'validation-course-0',
        'synthetic-validation-owner',
      ]) {
        expect(summaryText, isNot(contains(sentinel)));
      }
      expect(configuration.inspectCalls, greaterThan(0));
      await runner.close();
    },
  );

  test(
    'start refuses missing key, consent, or toolReady before creating a gateway',
    () async {
      final cases = [
        (_ConfigurationOnly(keySaved: false), AgentFailureCode.keyRequired),
        (_ConfigurationOnly(consent: false), AgentFailureCode.consentRequired),
        (
          _ConfigurationOnly(
            report: const AgentCapabilityReport(text: true, streaming: true),
          ),
          AgentFailureCode.modelRequired,
        ),
      ];
      for (final (configuration, expectedFailure) in cases) {
        var factoryCalls = 0;
        final runner = AgentBehaviorValidationRunner(
          modelConfiguration: configuration,
          gatewayFactory: () {
            factoryCalls++;
            return _SyntheticGateway();
          },
        );
        await runner.start();
        expect(runner.view.failure, expectedFailure);
        expect(runner.view.results, isEmpty);
        expect(runner.view.requests, 0);
        expect(factoryCalls, 0);
        expect(configuration.leaseCalls, 0);
        expect(configuration.illegalCalls, isEmpty);
        await runner.close();
      }
    },
  );

  test(
    'usage stays unknown when a synthetic request fails without ModelCompleted',
    () async {
      final configuration = _ConfigurationOnly();
      final gateways = <_SyntheticGateway>[];
      final runner = AgentBehaviorValidationRunner(
        modelConfiguration: configuration,
        gatewayFactory: () {
          final gateway = _SyntheticGateway(
            failFirstGenerate: gateways.isEmpty,
          );
          gateways.add(gateway);
          return gateway;
        },
      );

      await runner.start();

      expect(runner.view.failure, isNull);
      expect(
        runner.view.results,
        hasLength(AgentBehaviorValidationRunner.caseCount),
      );
      expect(runner.view.results.first.failure, AgentFailureCode.networkFailed);
      expect(gateways.first.generateCalls, 1);
      expect(gateways.first.requests, hasLength(1));
      expect(runner.view.requests, greaterThan(0));
      expect(runner.view.inputTokens, isNull);
      expect(runner.view.outputTokens, isNull);
      expect(configuration.illegalCalls, isEmpty);
      await runner.close();
    },
  );

  test(
    'approval waits for the original delayed answer before the next turn',
    () async {
      final configuration = _ConfigurationOnly();
      final gateways = <_SyntheticGateway>[];
      final runner = AgentBehaviorValidationRunner(
        modelConfiguration: configuration,
        gatewayFactory: () {
          final gateway = _SyntheticGateway(
            proposeThenDelayApprovalAnswer: gateways.isEmpty,
          );
          gateways.add(gateway);
          return gateway;
        },
      );
      addTearDown(() async {
        for (final gateway in gateways) {
          gateway.releaseApprovalAnswer();
        }
        await runner.close();
      });

      final work = runner.start();
      final firstGateway = await _waitForGateway(gateways);
      await firstGateway.approvalAnswerStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(firstGateway.requests, hasLength(2));
      expect(
        firstGateway.requests[1].messages.any(
          (message) =>
              message.role == 'user' &&
              (message.content ?? '').contains('我今天下午不想上课了'),
        ),
        isTrue,
      );
      expect(
        firstGateway.requests[1].messages
            .where((message) => message.role == 'tool')
            .map((message) => message.content ?? '')
            .join('\n'),
        contains('"status":"committed"'),
      );
      expect(runner.view.busy, isTrue);
      expect(runner.view.results, isEmpty);
      expect(runner.view.failure, isNull);
      expect(firstGateway.cancelCalls, 0);
      expect(firstGateway.closeCalls, 0);

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(firstGateway.generateCalls, 2);
      expect(firstGateway.cancelCalls, 0);
      expect(firstGateway.closeCalls, 0);
      expect(gateways, hasLength(1));
      expect(runner.view.requests, 2);
      expect(runner.view.failure, isNull);

      firstGateway.releaseApprovalAnswer();
      await work.timeout(const Duration(seconds: 20));

      expect(runner.view.busy, isFalse);
      expect(runner.view.failure, isNull);
      expect(
        runner.view.results,
        hasLength(AgentBehaviorValidationRunner.caseCount),
      );
      expect(runner.view.results.first.failure, isNull);
      expect(firstGateway.generateCalls, 3);
      expect(firstGateway.cancelCalls, 0);
      expect(configuration.illegalCalls, isEmpty);
      await runner.close();
    },
  );

  test(
    'stop drains its synthetic gateway, restart works, and close is terminal',
    () async {
      final configuration = _ConfigurationOnly();
      final gateways = <_SyntheticGateway>[];
      var firstGateway = true;
      final runner = AgentBehaviorValidationRunner(
        modelConfiguration: configuration,
        gatewayFactory: () {
          final gateway = _SyntheticGateway(hangFirstGenerate: firstGateway);
          firstGateway = false;
          gateways.add(gateway);
          return gateway;
        },
      );

      final firstWork = runner.start();
      final hangingGateway = await _waitForGateway(gateways);
      await hangingGateway.generationStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(runner.view.busy, isTrue);
      expect(runner.view.requests, 1);
      await runner.stop();
      await firstWork;
      expect(runner.view.busy, isFalse);
      expect(runner.view.failure, AgentFailureCode.cancelled);
      expect(hangingGateway.cancelCalls, greaterThan(0));
      expect(hangingGateway.closeCalls, greaterThan(0));
      expect(configuration.illegalCalls, isEmpty);

      await runner.start();
      expect(runner.view.failure, isNull);
      expect(
        runner.view.results,
        hasLength(AgentBehaviorValidationRunner.caseCount),
      );
      expect(configuration.illegalCalls, isEmpty);
      final requestsAtClose = runner.view.requests;
      final factoriesAtClose = gateways.length;
      await runner.close();
      await runner.start();
      expect(runner.view.requests, requestsAtClose);
      expect(gateways.length, factoriesAtClose);
      expect(configuration.illegalCalls, isEmpty);
    },
  );
}

Future<_SyntheticGateway> _waitForGateway(
  List<_SyntheticGateway> gateways,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (gateways.isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic validation gateway was not created.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return gateways.first;
}

final class _ConfigurationOnly implements AgentDataPort {
  _ConfigurationOnly({
    this.keySaved = true,
    this.consent = true,
    this.report = const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
  });

  final bool keySaved, consent;
  final AgentCapabilityReport report;
  final List<String> illegalCalls = [];
  final List<ModelSecretLease> issuedLeases = [];
  int inspectCalls = 0, leaseCalls = 0;

  Future<T> _reject<T>(String call) {
    illegalCalls.add(call);
    return Future<T>.error(StateError('Unexpected AgentDataPort call: $call'));
  }

  @override
  Stream<int> get changes => const Stream<int>.empty();

  @override
  Future<void> initializeAgent() => _reject<void>('initializeAgent');

  @override
  Future<AgentSettingsSnapshot> inspectAgent() async {
    inspectCalls++;
    return AgentSettingsSnapshot(
      authority: _authority,
      keySaved: keySaved,
      consent: consent,
      modelId: _validationModel,
      report: report,
    );
  }

  @override
  Future<void> saveModelConfiguration(
    AgentAuthority expected, {
    required String modelId,
    required List<String> modelIds,
    required AgentCapabilityReport report,
    required bool consent,
    Uint8List? key,
  }) => _reject<void>('saveModelConfiguration');

  @override
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected) async {
    leaseCalls++;
    if (expected != _authority) {
      illegalCalls.add('leaseModelKey:unexpected-authority');
      throw StateError('Unexpected synthetic model authority.');
    }
    final lease = ModelSecretLease(
      Uint8List.fromList(utf8.encode(_syntheticKey)),
    );
    issuedLeases.add(lease);
    return lease;
  }

  @override
  Future<void> invalidateModelWork(AgentAuthority expected) =>
      _reject<void>('invalidateModelWork');

  @override
  Future<void> deleteModelKey(AgentAuthority expected) =>
      _reject<void>('deleteModelKey');

  @override
  Future<void> setModelConsent(AgentAuthority expected, bool consent) =>
      _reject<void>('setModelConsent');

  @override
  Future<List<AgentConversation>> conversations() =>
      _reject<List<AgentConversation>>('conversations');

  @override
  Future<String> createConversation() => _reject<String>('createConversation');

  @override
  Future<List<AgentMessage>> messages(String conversationId) =>
      _reject<List<AgentMessage>>('messages');

  @override
  Future<AgentRunTicket> beginRun(
    AgentAuthority expected,
    String conversationId,
    String text,
  ) => _reject<AgentRunTicket>('beginRun');

  @override
  Future<void> saveAssistant(AgentRunTicket ticket, String text) =>
      _reject<void>('saveAssistant');

  @override
  Future<void> finishRun(AgentRunTicket ticket, AgentMessageStatus status) =>
      _reject<void>('finishRun');

  @override
  Future<void> cancelRun(AgentRunTicket ticket) => _reject<void>('cancelRun');

  @override
  Future<AgentHistoryIntent> beginClearHistory(
    AgentAuthority expected, {
    String? conversationId,
  }) => _reject<AgentHistoryIntent>('beginClearHistory');

  @override
  Future<void> completeClearHistory(AgentHistoryIntent intent) =>
      _reject<void>('completeClearHistory');
}

final class _SyntheticGateway implements ModelGatewayPort {
  _SyntheticGateway({
    this.hangFirstGenerate = false,
    this.failFirstGenerate = false,
    this.proposeThenDelayApprovalAnswer = false,
  });

  final bool hangFirstGenerate, failFirstGenerate;
  final bool proposeThenDelayApprovalAnswer;
  final generationStarted = Completer<void>();
  final approvalAnswerStarted = Completer<void>();
  final _approvalAnswerGate = Completer<void>();
  final List<String> receivedKeys = [];
  final List<ModelRequest> requests = [];
  int listModelCalls = 0, generateCalls = 0, cancelCalls = 0, closeCalls = 0;
  StreamController<ModelEvent>? _hangingStream;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    listModelCalls++;
    secret.revoke();
    return const [_validationModel];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    generateCalls++;
    final bytes = secret.take();
    receivedKeys.add(String.fromCharCodes(bytes));
    bytes.fillRange(0, bytes.length, 0);
    requests.add(request);
    if (hangFirstGenerate && generateCalls == 1) {
      final stream = StreamController<ModelEvent>(
        onListen: () {
          if (!generationStarted.isCompleted) generationStarted.complete();
        },
      );
      _hangingStream = stream;
      return stream.stream;
    }
    if (failFirstGenerate && generateCalls == 1) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.networkFailed),
      );
    }
    if (proposeThenDelayApprovalAnswer && generateCalls == 1) {
      if (!generationStarted.isCompleted) generationStarted.complete();
      return Stream<ModelEvent>.fromIterable([
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: [
            ModelToolCall(
              id: 'validation_approval',
              name: 'propose_local_changes',
              argumentsJson: jsonEncode({
                'changes': [
                  {
                    'type': 'create_task',
                    'local_key': 'validation_approval',
                    'title': '合成批准延迟任务',
                  },
                ],
              }),
            ),
          ],
        ),
      ]);
    }
    if (proposeThenDelayApprovalAnswer && generateCalls == 2) {
      if (!generationStarted.isCompleted) generationStarted.complete();
      if (!approvalAnswerStarted.isCompleted) {
        approvalAnswerStarted.complete();
      }
      return _approvalAnswerGate.future.asStream().asyncExpand(
        (_) => _completedAnswer(),
      );
    }
    if (!generationStarted.isCompleted) generationStarted.complete();
    return _completedAnswer();
  }

  Stream<ModelEvent> _completedAnswer() => Stream<ModelEvent>.fromIterable([
    const ModelTextDelta(_replySentinel),
    ModelCompleted(finishReason: 'stop', inputTokens: 7, outputTokens: 3),
  ]);

  void releaseApprovalAnswer() {
    if (!_approvalAnswerGate.isCompleted) _approvalAnswerGate.complete();
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCalls++;
    releaseApprovalAnswer();
    final stream = _hangingStream;
    if (stream != null && !stream.isClosed) await stream.close();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    releaseApprovalAnswer();
    final stream = _hangingStream;
    if (stream != null && !stream.isClosed) await stream.close();
  }
}
