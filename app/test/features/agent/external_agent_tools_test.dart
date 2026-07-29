import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';

/// A fake [QuerySourceGateway] that returns scripted events per request type,
/// recording every request for assertions.
class FakeQueryGateway implements QuerySourceGateway {
  FakeQueryGateway({this.icourseResult, this.campusSearchResult});

  final List<SourceQuery> requests = [];
  final Map<String, List<String>> resumeCalls = {};
  final List<String> cancelCalls = [];

  /// The envelope to return for iCourse queries.
  final QueryResultEnvelope? icourseResult;
  /// The envelope to return for campus_search queries.
  final QueryResultEnvelope? campusSearchResult;

  /// What the next young_enrolment query should emit.
  YoungBehaviour? nextYoung;

  @override
  Future<void> cancel(String jobId) async {
    cancelCalls.add(jobId);
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    resumeCalls[jobId] = [password ?? ''];
  }

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) async* {
    requests.add(request);
    if (request is YoungEnrolmentQueryRequest) {
      final behaviour = nextYoung ?? YoungBehaviour.complete();
      if (behaviour.needsLogin) {
        yield SourceQueryProgress(jobId: 'young-1', phase: 'starting');
        yield SourceQueryNeedsLogin(jobId: 'young-1');
      } else {
        yield SourceQueryProgress(jobId: 'young-1', phase: 'starting');
        yield SourceQueryCompleted(jobId: 'young-1', result: behaviour.result!);
      }
      return;
    }
    if (request is IcourseQueryRequest) {
      yield SourceQueryProgress(jobId: 'icourse-1', phase: 'starting');
      yield SourceQueryCompleted(
        jobId: 'icourse-1',
        result: icourseResult ?? _defaultIcourseEnvelope(),
      );
      return;
    }
    if (request is CampusSearchQueryRequest) {
      yield SourceQueryProgress(jobId: 'search-1', phase: 'starting');
      yield SourceQueryCompleted(
        jobId: 'search-1',
        result: campusSearchResult ?? _defaultCampusSearchEnvelope(),
      );
      return;
    }
    if (request is CampusDetailQueryRequest) {
      yield SourceQueryProgress(jobId: 'detail-1', phase: 'starting');
      yield SourceQueryCompleted(
        jobId: 'detail-1',
        result: _defaultCampusDetailEnvelope(),
      );
      return;
    }
    yield SourceQueryFailed(jobId: 'unknown', code: 'query_failed');
  }
}

class YoungBehaviour {
  YoungBehaviour.complete({QueryResultEnvelope? result})
    : needsLogin = false,
      result = result ?? _defaultYoungEnvelope();
  const YoungBehaviour.needsLogin()
    : needsLogin = true,
      result = null;
  final bool needsLogin;
  final QueryResultEnvelope? result;
}

QueryResultEnvelope _envelope(Map<String, dynamic> data) =>
    QueryResultEnvelope(json: {
      'schemaVersion': '1.0',
      'queryType': 'icourse',
      'generatedAt': '2026-07-29T09:00:00+08:00',
      'data': data,
      'metadata': <String, dynamic>{},
      'references': <String>[],
    });

QueryResultEnvelope _defaultIcourseEnvelope() => _envelope({
  'course': '数据结构',
  'teachers': <String>['张老师'],
  'summary': 'A course.',
});

QueryResultEnvelope _defaultYoungEnvelope() => QueryResultEnvelope(json: {
  'schemaVersion': '1.0',
  'queryType': 'young_enrolment',
  'generatedAt': '2026-07-29T09:00:00+08:00',
  'data': <String, dynamic>{
    'activities': <Map<String, Object?>>[
      {'title': '志愿活动一', 'category': '志愿', 'status': 'open'},
    ],
  },
  'metadata': <String, dynamic>{},
  'references': <String>[],
});

QueryResultEnvelope _defaultCampusSearchEnvelope() => QueryResultEnvelope(json: {
  'schemaVersion': '1.0',
  'queryType': 'campus_search',
  'generatedAt': '2026-07-29T09:00:00+08:00',
  'data': <String, dynamic>{
    'query': 'lib',
    'results': <Map<String, Object?>>[
      {'entryId': 'campus_1', 'title': 'Library notice', 'category': 'notice'},
      {'entryId': 'campus_2', 'title': 'Library hours', 'category': 'notice'},
    ],
  },
  'metadata': <String, dynamic>{'resultCount': 2},
  'references': <String>['https://teach.ustc.edu.cn/x'],
});

QueryResultEnvelope _defaultCampusDetailEnvelope() => QueryResultEnvelope(json: {
  'schemaVersion': '1.0',
  'queryType': 'campus_detail',
  'generatedAt': '2026-07-29T09:00:00+08:00',
  'data': <String, dynamic>{
    'entryId': 'campus_1',
    'title': 'Library notice',
    'body': 'The library is open.',
  },
  'metadata': <String, dynamic>{'stale': false},
  'references': <String>['https://teach.ustc.edu.cn/x'],
});

/// A fake [AgentConfigurationService] that returns a configurable consent flag.
class FakeAgentConfigurationService implements AgentConfigurationService {
  FakeAgentConfigurationService({this.icourseConsent = false});
  bool icourseConsent;

  @override
  Future<AgentSettingsSnapshot> load(String accountId) async =>
      AgentSettingsSnapshot(
        accountId: accountId,
        model: 'deepseek-v4-flash',
        enabled: true,
        icourseConsent: icourseConsent,
        systemPromptVersion: 1,
        updatedAt: 1,
      );

  @override
  Future<void> setIcourseConsent(String accountId, bool consent) async {
    icourseConsent = consent;
  }

  // The remaining members are unused by the tools; throw to catch misuse.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeAgentConfigurationService.${invocation.memberName}');
}

/// The external-tools test harness: registry + context with a fake query
/// gateway and a fake configuration service.
class _Harness {
  _Harness({
    required this.gateway,
    required this.config,
    required this.accountId,
    required this.references,
  }) : privacyFilter = OutboundPrivacyFilter(
          protectedAccount: 'PB12345678',
          toolBuilders: agentToolPayloadBuilders(),
        );

  final FakeQueryGateway gateway;
  final FakeAgentConfigurationService config;
  final String accountId;
  final RunReferenceStore references;
  final OutboundPrivacyFilter privacyFilter;

  AgentToolRegistry registry() => AgentToolRegistry(
        tools: externalAgentTools(gateway: gateway, config: config),
        privacyFilter: privacyFilter,
      );

  AgentToolContext context() => AgentToolContext(
        accountId: accountId,
        runId: 'run-test',
        clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0)),
        cancellation: CancellationSignal(),
        references: references,
      );

  Future<AgentToolResult> execute(String tool, Map<String, Object?> args) async {
    final result = await registry().execute(
      toolName: tool,
      arguments: args,
      context: context(),
    );
    return result;
  }
}

void main() {
  group('search_icourse consent', () {
    test('refuses first use with consent_required before consent', () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: false),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute('search_icourse', {
        'course': '数据结构',
      });

      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'consent_required');
      // The gateway was never called.
      expect(harness.gateway.requests, isEmpty);
    });

    test('after consent sends only course + necessary teacher terms', () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute('search_icourse', {
        'course': '数据结构',
        'teachers': ['张老师', '李老师'],
      });

      expect(result.status, AgentToolStatus.success);
      // Exactly one iCourse request was made.
      expect(harness.gateway.requests, hasLength(1));
      final req = harness.gateway.requests.single as IcourseQueryRequest;
      expect(req.course, '数据结构');
      expect(req.teachers, ['张老师', '李老师']);
      // The request carries NO schedule times, locations, user identity, or
      // JW bundle. The SourceQuery type itself has no such fields, but assert
      // the model payload also stays minimal.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('accountId')));
      expect(encoded, isNot(contains('expectedUsername')));
      expect(encoded, isNot(contains('password')));
    });
  });

  group('search_campus_catalog + read_campus_detail refs', () {
    test('campus search returns refs, detail accepts only current-run refs',
        () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final search = await harness.execute('search_campus_catalog', {
        'query': 'lib',
      });
      expect(search.status, AgentToolStatus.success);
      final results = search.payload['results']! as List;
      expect(results, hasLength(2));
      // Each result has a ref_* token, no raw entryId in the payload.
      final first = results.first! as Map<String, Object?>;
      expect(first['ref'], startsWith('ref_'));
      final encoded = jsonEncode(search.payload);
      expect(encoded, isNot(contains('campus_1')));
      expect(encoded, isNot(contains('campus_2')));

      // Resolve the ref and read detail.
      final ref = first['ref']! as String;
      final detail = await harness.execute('read_campus_detail', {
        'ref': ref,
      });
      expect(detail.status, AgentToolStatus.success);
      // The detail request used the resolved entryId, not a URL.
      final detailReq =
          harness.gateway.requests.last as CampusDetailQueryRequest;
      expect(detailReq.entryIds, ['campus_1']);
    });

    test('detail rejects a ref not bound in this run', () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute('read_campus_detail', {
        'ref': 'ref_unknown',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
      expect(harness.gateway.requests, isEmpty);
    });

    test('detail rejects a raw URL passed as ref (no URL from tool args)',
        () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute('read_campus_detail', {
        'ref': 'https://teach.ustc.edu.cn/evil',
      });
      // A URL is not a ref_* token and never resolves.
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
      expect(harness.gateway.requests, isEmpty);
    });
  });

  group('read_campus_detail limits', () {
    test('rejects more than 3 entry refs with result_too_large', () async {
      // Build a search envelope with 4 catalog entries so we can bind 4 refs.
      final fourResultEnvelope = QueryResultEnvelope(json: {
        'schemaVersion': '1.0',
        'queryType': 'campus_search',
        'generatedAt': '2026-07-29T09:00:00+08:00',
        'data': <String, dynamic>{
          'query': 'lib',
          'results': <Map<String, Object?>>[
            for (var i = 1; i <= 4; i++)
              {'entryId': 'campus_$i', 'title': 'Item $i', 'category': 'notice'},
          ],
        },
        'metadata': <String, dynamic>{'resultCount': 4},
        'references': <String>[],
      });
      final harness = _Harness(
        gateway: FakeQueryGateway(campusSearchResult: fourResultEnvelope),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-b'),
      );
      final search = await harness.execute('search_campus_catalog', {
        'query': 'lib',
      });
      final results = search.payload['results']! as List;
      expect(results, hasLength(4));
      final refs = results
          .map((r) => (r! as Map<String, Object?>)['ref'] as String)
          .toList();

      final detail = await harness.execute('read_campus_detail', {
        'refs': refs,
      });
      expect(detail.status, AgentToolStatus.error);
      expect(detail.errorCode, 'result_too_large');
      // The detail tool made NO gateway request (it rejected the >3 refs
      // before calling the gateway). Only the prior search request exists.
      expect(
        harness.gateway.requests.whereType<CampusDetailQueryRequest>(),
        isEmpty,
      );
    });

    test('rejects more than one discovered-link level with invalid_arguments',
        () async {
      final harness = _Harness(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final search = await harness.execute('search_campus_catalog', {
        'query': 'lib',
      });
      final results = search.payload['results']! as List;
      final ref = (results.first! as Map<String, Object?>)['ref']! as String;

      // The "one discovered-link level" limit is modeled as a max of 3
      // followLinkIds (a flat list of discovered links at one level).
      // Passing more than 3 followLinkIds is rejected with invalid_arguments.
      final detail = await harness.execute('read_campus_detail', {
        'ref': ref,
        'followLinkIds': ['link_1', 'link_2', 'link_3', 'link_4'],
      });
      expect(detail.status, AgentToolStatus.error);
      expect(detail.errorCode, 'invalid_arguments');
    });
  });

  group('search_current_second_class_activities Young login pause', () {
    test('needs_user_login pauses the run; tool returns needs_user_login code',
        () async {
      final gateway = FakeQueryGateway()
        ..nextYoung = const YoungBehaviour.needsLogin();
      final harness = _Harness(
        gateway: gateway,
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute(
        'search_current_second_class_activities',
        {},
      );

      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'needs_user_login');
      // The payload carries the jobId so the UI can resume.
      expect(result.payload['jobId'], 'young-1');
      // The tool did NOT auto-resume and did NOT receive a password.
      expect(gateway.resumeCalls, isEmpty);
    });

    test('completed young query returns activities, no raw ids', () async {
      final gateway = FakeQueryGateway()
        ..nextYoung = YoungBehaviour.complete();
      final harness = _Harness(
        gateway: gateway,
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );

      final result = await harness.execute(
        'search_current_second_class_activities',
        {},
      );
      expect(result.status, AgentToolStatus.success);
      final activities = result.payload['activities']! as List;
      expect(activities, hasLength(1));
      final first = activities.first! as Map<String, Object?>;
      expect(first['title'], '志愿活动一');
      // SECURITY: no enrol/cancel action exposed.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('enrol')));
      expect(encoded, isNot(contains('cancel')));
      expect(encoded, isNot(contains('报名')));
    });
  });

  group('no tool can enrol or cancel an activity', () {
    test('input schemas expose no enrol/cancel/subscribe arguments', () async {
      final tools = externalAgentTools(
        gateway: FakeQueryGateway(),
        config: FakeAgentConfigurationService(),
      );
      for (final tool in tools) {
        // No input schema property names an enrol/cancel/subscribe/register
        // action — the tools are read-only and accept no mutative argument.
        final schemaJson = jsonEncode(tool.inputSchema);
        expect(schemaJson, isNot(contains('"enrol')));
        expect(schemaJson, isNot(contains('"cancel')));
        expect(schemaJson, isNot(contains('"subscribe')));
        expect(schemaJson, isNot(contains('"register')));
        // Each tool description explicitly declares it is read-only and
        // cannot enrol/cancel (a safety instruction to the model).
        final desc = tool.description.toLowerCase();
        expect(desc, contains('read-only'));
      }
    });

    test('completed young query payload exposes no enrol/cancel action', () async {
      final gateway = FakeQueryGateway()
        ..nextYoung = YoungBehaviour.complete();
      final harness = _Harness(
        gateway: gateway,
        config: FakeAgentConfigurationService(icourseConsent: true),
        accountId: 'a',
        references: RunReferenceStore(runId: 'run-a'),
      );
      final result = await harness.execute(
        'search_current_second_class_activities',
        {},
      );
      expect(result.status, AgentToolStatus.success);
      final encoded = jsonEncode(result.payload);
      // No action verbs that would let the model enrol or cancel.
      expect(encoded, isNot(contains('"enrol"')));
      expect(encoded, isNot(contains('"cancel"')));
      expect(encoded, isNot(contains('"subscribe"')));
      expect(encoded, isNot(contains('"register"')));
    });
  });
}
