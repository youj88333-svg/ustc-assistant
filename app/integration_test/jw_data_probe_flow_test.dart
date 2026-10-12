import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_candidate_identity.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_data_probe_fixture.dart';

const _schemaFailures = <String, (String, String)>{
  'index_duplicate': ('index_schema', 'json_duplicate'),
  'index_bad_type': ('index_schema', 'index_ids'),
  'index_wrong_shape': ('index_schema', 'index_shape'),
  'datum_missing': ('datum_schema', 'datum_shape'),
  'datum_depth': ('datum_schema', 'json_depth'),
  'lesson_set_missing': ('datum_schema', 'lesson_set'),
  'lesson_set_extra': ('datum_schema', 'lesson_set'),
  'group_link': ('datum_schema', 'group_lesson'),
  'schedule_link': ('datum_schema', 'schedule_link'),
  'date_invalid': ('datum_schema', 'schedule_date'),
  'time_invalid': ('datum_schema', 'schedule_time'),
  'datum_duplicate_json': ('datum_schema', 'json_duplicate'),
  'exam_pagination': ('exams_schema', 'exam_pagination'),
  'exam_bad_date': ('exams_schema', 'exam_date'),
  'identity_bad_value': ('identity_schema', 'identity_missing'),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fixed JW data probe validates read-only contracts and discards stale results',
    (tester) async {
      await tester.runAsync(() async {
        const modes = [
          'normal',
          'empty_index',
          'index_duplicate',
          'index_bad_type',
          'index_wrong_shape',
          'index_mime',
          'index_redirect',
          'datum_missing',
          'datum_oversize',
          'datum_depth',
          'lesson_set_missing',
          'lesson_set_extra',
          'group_link',
          'schedule_link',
          'date_invalid',
          'time_invalid',
          'datum_duplicate_json',
          'datum_mime',
          'exam_pagination',
          'exam_bad_date',
          'identity_changed',
          'identity_nested_label',
          'identity_bad_value',
          'empty_exams',
          'unknownsemester',
          'direct_route',
          'csp',
          'cancel',
          'navigation',
        ];
        var directOperation = 900000000;

        for (final mode in modes) {
          debugPrint('Synthetic JW data case: $mode');
          final fixture = await JwDataProbeFixture.start(mode);
          final root = await Directory.systemTemp.createTemp('ustc_jw_data_');
          final owner = await DemoDirectory.acquire(p.join(root.path, 'owned'));
          final browser = NativeObservationBrowser();
          final events = <BrowserEvent>[];
          final subscription = browser.events.listen(events.add);
          final leases = WorkLeasePool();
          final coordinator = ObservationCoordinator(
            browser: browser,
            assets: ObservationAssets(owner),
            leases: leases,
            target: ObservationTarget.fixture(fixture.initialUri),
          );
          try {
            await coordinator.initialize();
            await coordinator.open();
            await _waitReady(coordinator, events);
            final page = events.lastWhere(
              (event) => event.kind == BrowserEventKind.ready,
            );

            if (mode == 'normal') {
              // URL and lesson IDs are never accepted as caller-controlled
              // inputs to the fixed native operation.
              for (final extra in [
                {'url': 'http://127.0.0.1:1/forbidden'},
                {
                  'lessonIds': [11, 12],
                },
              ]) {
                await expectLater(
                  const MethodChannel(
                    'ustc_assistant/observation_v1',
                  ).invokeMethod<Object>('readJwDataProbe', {
                    'session': page.session,
                    'document': page.document,
                    'operation': directOperation++,
                    'semesterId': 20261,
                    ...extra,
                  }),
                  throwsA(
                    isA<PlatformException>().having(
                      (error) => error.details,
                      'reason',
                      'invalidSnapshot',
                    ),
                  ),
                );
              }
              expect(
                fixture.requests.where(
                  (request) =>
                      request.contains('student-info') ||
                      request.contains('get-data') ||
                      request.contains('/datum'),
                ),
                isEmpty,
              );
            }

            if (mode == 'csp') {
              final reply = await _startDirectDataProbe(
                browser,
                page,
                operation: directOperation++,
                semesterId: 20261,
              );
              expect(reply.phase, JwProbePhase.failed);
              expect(reply.code, isNot(JwDataProbeCode.ok));
              expect(
                fixture.requests.where(
                  (request) =>
                      request.contains('student-info') ||
                      request.contains('get-data') ||
                      request.contains('/datum'),
                ),
                isEmpty,
              );
              _expectSafeSummary(coordinator.dataProbeView.safeSummary);
              continue;
            }

            await coordinator
                .runProbe('TEST0001')
                .timeout(const Duration(seconds: 40));
            expect(coordinator.probeView.code, JwProbeCode.ok);
            expect(
              coordinator.probeView.identity,
              JwCandidateIdentity.candidateMatches,
            );
            expect(leases.isBusy, isTrue);
            final selectedSemesterId = coordinator.probeView.semesters
                .singleWhere((semester) => semester.selected)
                .id;

            if (mode == 'unknownsemester') {
              await expectLater(
                coordinator.runDataProbe('TEST0001', semesterId: 20263),
                throwsA(
                  isA<AppFailure>().having(
                    (failure) => failure.code,
                    'code',
                    FailureCode.invalidSnapshot,
                  ),
                ),
              );
              expect(
                fixture.requests.where(
                  (request) =>
                      request.contains('get-data') ||
                      request.contains('/datum'),
                ),
                isEmpty,
              );
              final reply = await _startDirectDataProbe(
                browser,
                page,
                operation: directOperation++,
                semesterId: 20263,
              );
              expect(reply.phase, JwProbePhase.failed);
              expect(reply.code, JwDataProbeCode.semesterUnknown);
              expect(reply.diagnostics?.reason, 'semester_unknown');
              expect(
                fixture.requests.where(
                  (request) =>
                      request.contains('get-data') ||
                      request.contains('/datum'),
                ),
                isEmpty,
              );
              _expectSafeSummary(coordinator.dataProbeView.safeSummary);
              continue;
            }

            if (mode == 'cancel' || mode == 'navigation') {
              final probe = coordinator.runDataProbe(
                'TEST0001',
                semesterId: selectedSemesterId,
              );
              await fixture.indexEntered.future.timeout(
                const Duration(seconds: 20),
              );
              expect(leases.isBusy, isTrue);
              if (mode == 'cancel') {
                final cancellation = coordinator.cancelDataProbe();
                if (!fixture.releaseIndex.isCompleted) {
                  fixture.releaseIndex.complete();
                }
                await cancellation;
              } else {
                try {
                  await browser.exerciseFixture(
                    session: page.session,
                    document: page.document,
                    action: 'sameDocument',
                  );
                } on AppFailure catch (failure) {
                  expect(failure.code, FailureCode.staleResult);
                }
                if (!fixture.releaseIndex.isCompleted) {
                  fixture.releaseIndex.complete();
                }
              }
              await probe.timeout(const Duration(seconds: 40));
              final elapsed = Stopwatch()..start();
              while (coordinator.view.phase != ObservationPhase.idle) {
                if (elapsed.elapsed > const Duration(seconds: 20)) {
                  fail('data probe did not drain after $mode');
                }
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
              expect(
                coordinator.dataProbeView.code,
                anyOf(JwDataProbeCode.cancelled, JwDataProbeCode.staleResult),
              );
              expect(leases.isBusy, isFalse);
              expect(
                fixture.requests.where((request) => request.contains('/datum')),
                isEmpty,
              );
              _expectSafeSummary(coordinator.dataProbeView.safeSummary);
              continue;
            }

            await coordinator
                .runDataProbe('TEST0001', semesterId: selectedSemesterId)
                .timeout(const Duration(seconds: 40));
            final view = coordinator.dataProbeView;
            final summary = _expectSafeSummary(view.safeSummary);
            expect(leases.isBusy, isTrue);
            expect(
              () => leases.acquire(),
              throwsA(
                isA<AppFailure>().having(
                  (failure) => failure.code,
                  'code',
                  FailureCode.busy,
                ),
              ),
            );

            if (mode == 'normal' ||
                mode == 'identity_nested_label' ||
                mode == 'direct_route' ||
                mode == 'empty_exams') {
              expect(view.phase, JwProbePhase.done, reason: view.safeSummary);
              expect(view.code, JwDataProbeCode.ok);
              expect(summary['identity'], 'candidateMatches');
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(diagnostics['reason'], 'none');
              expect(diagnostics['checks'], {
                'identityBefore': 'ok',
                'course': 'ok',
                'index': 'ok',
                'datum': 'ok',
                'exams': 'ok',
                'identityAfter': 'ok',
              });
              expect(diagnostics['identityReads'], 2);
              expect(diagnostics['lessonIds'], 2);
              expect(diagnostics['lessons'], 2);
              expect(diagnostics['groups'], 2);
              expect(diagnostics['schedules'], 2);
              expect(diagnostics['datedSchedules'], 2);
              expect(diagnostics['timedSchedules'], 2);
              expect(diagnostics['linkedSchedules'], 2);
              expect(diagnostics['examRows'], mode == 'empty_exams' ? 0 : 1);
              expect(diagnostics['datedExams'], mode == 'empty_exams' ? 0 : 1);
              expect(diagnostics['semesterAccepted'], isTrue);
              expect(diagnostics['identityStable'], isTrue);
              expect(diagnostics['emptyCourse'], isFalse);
              expect(diagnostics['emptyExams'], mode == 'empty_exams');
              expect(diagnostics['pagination'], isFalse);
              expect(diagnostics['selfRouteBound'], mode != 'direct_route');
              expect(fixture.acceptedIndexQueries, [
                {'bizTypeId': '2', 'semesterId': '20261', 'dataId': '571'},
              ]);
              expect(fixture.acceptedDatumBodies, [
                <int>[11, 12],
              ]);
              if (mode == 'empty_exams') {
                expect(summary.containsKey('complete'), isFalse);
                expect(diagnostics.containsKey('complete'), isFalse);
              }
              expect(
                fixture.requests.where((request) => request.contains('/datum')),
                ['POST /for-std/course-table/datum'],
              );
            } else if (mode == 'empty_index') {
              expect(view.phase, JwProbePhase.done, reason: view.safeSummary);
              expect(view.code, JwDataProbeCode.ok);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(diagnostics['emptyCourse'], isTrue);
              expect(diagnostics['lessonIds'], 0);
              expect(summary.containsKey('complete'), isFalse);
              expect(diagnostics.containsKey('complete'), isFalse);
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['datum'],
                'skipped',
              );
              expect(fixture.acceptedDatumBodies, isEmpty);
              expect(
                fixture.requests.where((request) => request.contains('/datum')),
                isEmpty,
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
              expect(
                (diagnostics['checks']
                    as Map<String, dynamic>)['identityAfter'],
                'ok',
              );
            } else if (mode == 'datum_mime') {
              expect(view.phase, JwProbePhase.failed);
              expect(view.code, JwDataProbeCode.datumMime);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['datum'],
                'error',
              );
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['exams'],
                'ok',
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
            } else if (mode == 'datum_oversize') {
              expect(view.phase, JwProbePhase.failed);
              expect(view.code, JwDataProbeCode.datumTooLarge);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['datum'],
                'error',
              );
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['exams'],
                'ok',
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
            } else if (mode == 'index_mime') {
              expect(view.phase, JwProbePhase.failed);
              expect(view.code, JwDataProbeCode.indexMime);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['index'],
                'error',
              );
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['datum'],
                'skipped',
              );
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['exams'],
                'ok',
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
            } else if (mode == 'index_redirect') {
              expect(view.phase, JwProbePhase.failed);
              expect(view.code, JwDataProbeCode.networkFailed);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['index'],
                'error',
              );
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['exams'],
                'ok',
              );
              expect(fixture.redirectTargetRequests, 0);
              expect(
                fixture.requests.where((request) => request.contains('/datum')),
                isEmpty,
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
            } else if (mode == 'identity_changed') {
              expect(view.phase, JwProbePhase.failed);
              expect(view.code, JwDataProbeCode.identityChanged);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(diagnostics['reason'], 'identity_changed');
              expect(diagnostics['identityStable'], isFalse);
              expect(
                (diagnostics['checks']
                    as Map<String, dynamic>)['identityAfter'],
                'error',
              );
              expect(view.identity, JwCandidateIdentity.unavailable);
            } else {
              final failure = _schemaFailures[mode]!;
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.code.wire, failure.$1);
              final diagnostics =
                  summary['diagnostics'] as Map<String, dynamic>;
              expect(diagnostics['reason'], failure.$2);
              expect(
                (diagnostics['checks'] as Map<String, dynamic>)['exams'],
                mode.startsWith('exam_') ? 'error' : 'ok',
                reason: 'exam diagnostics must continue for $mode',
              );
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/571'),
              );
              if (mode == 'identity_bad_value') {
                expect(
                  (diagnostics['checks'] as Map<String, dynamic>)['index'],
                  'skipped',
                );
                expect(
                  (diagnostics['checks'] as Map<String, dynamic>)['datum'],
                  'skipped',
                );
                expect(view.identity, JwCandidateIdentity.unavailable);
                expect(
                  fixture.requests.where(
                    (request) =>
                        request.contains('get-data') ||
                        request.contains('/datum'),
                  ),
                  isEmpty,
                );
              }
            }
            expect(
              fixture.rejectedRequests,
              0,
              reason: '$mode: ${fixture.requests.join(', ')}',
            );
            expect(
              fixture.requests,
              isNot(contains('POST /for-std/course-table')),
            );
            expect(leases.isBusy, isTrue);
          } catch (error) {
            debugPrint(
              'Synthetic JW data failure before cleanup: $mode, '
              'phase=${coordinator.view.phase.name}, '
              'probe=${coordinator.dataProbeView.code.wire}, '
              'type=${error.runtimeType}',
            );
            debugPrint(
              'Synthetic directory metadata: ${coordinator.probeView.safeSummary}',
            );
            debugPrint(
              'Synthetic data metadata: ${coordinator.dataProbeView.safeSummary}',
            );
            // All expectations here concern loopback fixture values or closed
            // metadata. Keep the initial failure visible if drain also fails.
            if (error is TestFailure) {
              debugPrint('Synthetic expectation: ${error.message}');
            }
            rethrow;
          } finally {
            if (!fixture.releaseIndex.isCompleted) {
              fixture.releaseIndex.complete();
            }
            await coordinator.shutdown();
            await subscription.cancel();
            await browser.dispose();
            await owner.release();
            await fixture.close();
            await root.delete(recursive: true);
          }
        }
      });
    },
  );
}

Map<String, dynamic> _expectSafeSummary(String summary) {
  final decoded = jsonDecode(summary) as Map<String, dynamic>;
  expect(decoded['kind'], 'jw-data-contract-v1');
  expect(decoded['sourceAvailable'], isFalse);
  expect(summary, isNot(contains('TEST0001')));
  for (final syntheticValue in [
    '20261',
    '20262',
    '合成学期',
    '合成备用学期',
    '合成课程A',
    '合成课程B',
    '2026-10-15',
    '2026-10-16',
    '2026-10-20',
    'SYN001',
    '571',
  ]) {
    expect(summary, isNot(contains(syntheticValue)));
  }
  if (decoded['diagnostics'] case final Map<String, dynamic> diagnostics) {
    expect(diagnostics.keys.toSet(), {
      'checks',
      'reason',
      'identityReads',
      'lessonIds',
      'lessons',
      'groups',
      'schedules',
      'datedSchedules',
      'timedSchedules',
      'linkedSchedules',
      'examRows',
      'datedExams',
      'semesterAccepted',
      'selfRouteBound',
      'identityStable',
      'emptyCourse',
      'emptyExams',
      'pagination',
      'types',
    });
    final checks = diagnostics['checks'] as Map<String, dynamic>;
    expect(checks.keys.toSet(), {
      'identityBefore',
      'course',
      'index',
      'datum',
      'exams',
      'identityAfter',
    });
    expect(
      checks.values.every(
        (value) => {'pending', 'ok', 'skipped', 'error'}.contains(value),
      ),
      isTrue,
    );
    final types = diagnostics['types'] as Map<String, dynamic>;
    expect(types.keys.toSet(), {
      'lessonIds',
      'lessonList',
      'scheduleGroupList',
      'scheduleList',
      'date',
      'startTime',
      'endTime',
    });
    expect(
      types.values.every(
        (value) => {
          'missing',
          'null',
          'object',
          'array',
          'string',
          'number',
          'boolean',
          'mixed',
        }.contains(value),
      ),
      isTrue,
    );
  }
  return decoded;
}

Future<JwDataProbeReply> _startDirectDataProbe(
  NativeObservationBrowser browser,
  BrowserEvent page, {
  required int operation,
  required int semesterId,
}) async {
  var reply = await browser.startJwDataProbe(
    session: page.session,
    document: page.document,
    operation: operation,
    semesterId: semesterId,
  );
  final elapsed = Stopwatch()..start();
  while (reply.phase == JwProbePhase.running) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('direct synthetic data probe did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    reply = await browser.pollJwDataProbe(
      session: page.session,
      document: page.document,
      operation: operation,
    );
  }
  return reply;
}

Future<void> _waitReady(
  ObservationCoordinator coordinator,
  List<BrowserEvent> events,
) async {
  final elapsed = Stopwatch()..start();
  while (!coordinator.view.ready ||
      !events.any((event) => event.kind == BrowserEventKind.ready)) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('synthetic data document did not become ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
