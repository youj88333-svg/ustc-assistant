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
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_probe_fixture.dart';

const _courseFailureReasons = <String, String>{
  'empty_select': 'literal_missing',
  'literal_context_fake': 'literal_missing',
  'literal_unsupported': 'literal_unsupported',
  'legacy_comment_catalog': 'literal_unsupported',
  'function_between_duplicate': 'literal_duplicate',
  'late_regex_rejects_assignments': 'literal_unsupported',
  'bad_first_rhs_duplicate': 'literal_duplicate',
  'escaped_duplicate_key': 'literal_key_conflict',
  'fractional_selection': 'selection_invalid',
  'literal_duplicate': 'literal_duplicate',
  'literal_key_conflict': 'literal_key_conflict',
  'catalog_duplicate': 'catalog_duplicate',
  'catalog_id': 'catalog_id',
  'catalog_name': 'catalog_name',
  'selection_unknown': 'selection_unknown',
  'selection_missing': 'selection_missing',
  'literal_map': 'literal_unsupported',
  'catalog_limit': 'catalog_limit',
  'static_over_limit_257': 'options_limit',
  'invalid_option_json': 'option_value',
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fixed JW probe captures native primitives and rejects unsafe evidence',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in [
          'home',
          'normal',
          'empty',
          'all_semesters',
          'static_history_81',
          'static_boundary_256',
          'static_over_limit_257',
          'json_catalog',
          'json_null',
          'json_boundary_256',
          'empty_select',
          'literal_context_fake',
          'literal_unsupported',
          'legacy_comment_catalog',
          'function_between_duplicate',
          'late_regex_rejects_assignments',
          'bad_first_rhs_duplicate',
          'escaped_duplicate_key',
          'fractional_selection',
          'literal_duplicate',
          'literal_key_conflict',
          'catalog_duplicate',
          'catalog_id',
          'catalog_name',
          'selection_unknown',
          'selection_missing',
          'literal_map',
          'catalog_limit',
          'invalid_option_json',
          'observed_shape',
          'duplicate_semester_selects',
          'invalid_semester_option',
          'mismatch',
          'conflict',
          'missing',
          'pagination',
          'mime',
          'oversize',
          'redirect',
          'slow',
          'navigation',
          'exam_no_body',
          'exam_bad_row',
          'csp',
          'worker',
        ]) {
          debugPrint('Synthetic JW case: $mode');
          final fixture = await JwProbeFixture.start(mode);
          final root = await Directory.systemTemp.createTemp('ustc_jw_probe_');
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
            if (mode == 'home') {
              final home = events.lastWhere(
                (event) => event.kind == BrowserEventKind.ready,
              );
              await coordinator.runProbe('TEST0001');
              expect(
                coordinator.probeView.code,
                JwProbeCode.studentContextMissing,
              );
              expect(
                fixture.requests.where(
                  (request) => request.contains('student-info'),
                ),
                isEmpty,
              );
              // No arbitrary URL, inferred /classinfo route or caller ID.
              for (final args in [
                {
                  'session': home.session,
                  'document': home.document,
                  'page': 'courseTable',
                  'url': 'http://127.0.0.1:1/forbidden',
                },
                {
                  'session': home.session,
                  'document': home.document,
                  'page': 'https://jw.ustc.edu.cn/classinfo',
                },
              ]) {
                await expectLater(
                  const MethodChannel(
                    'ustc_assistant/observation_v1',
                  ).invokeMethod<Object>('navigateJwPage', args),
                  throwsA(
                    isA<PlatformException>().having(
                      (error) => error.details,
                      'reason',
                      'invalidSnapshot',
                    ),
                  ),
                );
              }
              expect(fixture.launcherCookieStates, isEmpty);
              await coordinator.navigateJwPage(JwObservationPage.courseTable);
              expect(
                coordinator.probeView.identity,
                JwCandidateIdentity.unavailable,
              );
              await _waitReady(coordinator, events, newerThan: home.document);
              final course = events.lastWhere(
                (event) => event.kind == BrowserEventKind.ready,
              );
              expect(course.session, home.session);
              await expectLater(
                browser.navigateJwPage(
                  session: home.session,
                  document: home.document,
                  page: JwObservationPage.examArrange,
                ),
                throwsA(
                  isA<AppFailure>().having(
                    (failure) => failure.code,
                    'code',
                    FailureCode.staleResult,
                  ),
                ),
              );
              await coordinator.runProbe('TEST0001');
              expect(
                coordinator.probeView.code,
                JwProbeCode.ok,
                reason: coordinator.probeView.safeSummary,
              );
              expect(
                coordinator.probeView.identity,
                JwCandidateIdentity.candidateMatches,
              );
              await coordinator.navigateJwPage(JwObservationPage.examArrange);
              expect(
                coordinator.probeView.identity,
                JwCandidateIdentity.unavailable,
              );
              await _waitReady(coordinator, events, newerThan: course.document);
              expect(
                events
                    .lastWhere((event) => event.kind == BrowserEventKind.ready)
                    .session,
                home.session,
              );
              await coordinator.runProbe('TEST0001');
              expect(
                coordinator.probeView.code,
                JwProbeCode.ok,
                reason: coordinator.probeView.safeSummary,
              );
              expect(
                coordinator.probeView.identity,
                JwCandidateIdentity.candidateMatches,
              );
              expect(fixture.launcherCookieStates, [true, true]);
              expect(fixture.forbiddenRequests, 0);
              expect(leases.isBusy, isTrue);
              continue;
            }
            if (mode == 'normal') {
              final context = events.lastWhere(
                (event) => event.kind == BrowserEventKind.ready,
              );
              await expectLater(
                const MethodChannel(
                  'ustc_assistant/observation_v1',
                ).invokeMethod<Object>('readJwProbe', {
                  'session': context.session,
                  'document': context.document,
                  'operation': 1,
                  'url': 'http://127.0.0.1:1/forbidden',
                }),
                throwsA(
                  isA<PlatformException>().having(
                    (error) => error.details,
                    'reason',
                    'invalidSnapshot',
                  ),
                ),
              );
              expect(
                fixture.requests.where(
                  (request) => request.contains('student-info'),
                ),
                isEmpty,
              );
            }
            if (mode == 'worker') {
              await fixture.workerReady.future.timeout(
                const Duration(seconds: 15),
              );
              expect(
                fixture.workerStatus,
                'ready',
                reason: '${fixture.requests}',
              );
            }
            final probe = coordinator.runProbe('TEST0001');
            if (mode == 'slow' || mode == 'navigation') {
              await fixture.identityEntered.future.timeout(
                const Duration(seconds: 10),
              );
              if (mode == 'slow') {
                await coordinator.cancelProbe();
              } else {
                final context = events.lastWhere(
                  (event) => event.kind == BrowserEventKind.ready,
                );
                try {
                  await browser.exerciseFixture(
                    session: context.session,
                    document: context.document,
                    action: 'sameDocument',
                  );
                } on AppFailure catch (failure) {
                  expect(failure.code, FailureCode.staleResult);
                }
                final closing = Stopwatch()..start();
                while (coordinator.view.phase != ObservationPhase.idle) {
                  if (closing.elapsed > const Duration(seconds: 20)) {
                    fail('navigation did not drain');
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 30));
                }
              }
              await probe;
              expect(coordinator.view.phase, ObservationPhase.idle);
              expect(
                coordinator.probeView.identity,
                JwCandidateIdentity.unavailable,
              );
              expect(leases.isBusy, isFalse);
              expect(
                fixture.requests.where(
                  (request) => request.contains('exam-arrange'),
                ),
                isEmpty,
              );
              continue;
            }
            await probe.timeout(const Duration(seconds: 40));
            final view = coordinator.probeView;
            expect(view.busy, isFalse, reason: mode);
            expect(view.safeSummary, isNot(contains('TEST000')), reason: mode);
            for (final syntheticValue in [
              'TEST0001',
              'SYN001',
              'fake',
              '有效目录',
              '第二目录',
              '后续目录',
              '合成',
              'Synthetic semester',
              '2026秋合成',
              '2026春合成',
              '2026 秋季学期（合成）',
              '2026 春季学期（合成）',
              '461',
              '441',
              '700',
              '760',
              '999',
              '731',
              '732',
            ]) {
              expect(
                view.safeSummary,
                isNot(contains(syntheticValue)),
                reason: '$mode leaked a synthetic value',
              );
            }
            for (final semester in view.semesters) {
              expect(
                view.safeSummary,
                isNot(contains(semester.id.toString())),
                reason: '$mode leaked a semester id',
              );
              expect(
                view.safeSummary,
                isNot(contains(semester.name)),
                reason: '$mode leaked a semester name',
              );
            }
            expect(
              fixture.requests.every((request) => request.startsWith('GET ')),
              isTrue,
            );
            expect(fixture.forbiddenRequests, 0, reason: mode);
            if (mode == 'normal' ||
                mode == 'empty' ||
                mode == 'pagination' ||
                mode == 'all_semesters' ||
                mode == 'static_history_81' ||
                mode == 'static_boundary_256' ||
                mode == 'json_catalog' ||
                mode == 'json_null' ||
                mode == 'json_boundary_256') {
              expect(view.code, JwProbeCode.ok, reason: view.safeSummary);
              expect(view.identity, JwCandidateIdentity.candidateMatches);
              final expectedSemesterOptions = switch (mode) {
                'static_history_81' => 81,
                'static_boundary_256' || 'json_boundary_256' => 256,
                _ => 2,
              };
              expect(view.summary!.semesterOptions, expectedSemesterOptions);
              expect(view.summary!.examHeader, isTrue);
              expect(view.summary!.examRows, mode == 'empty' ? 0 : 1);
              expect(view.summary!.pagination, mode == 'pagination');
              if (mode == 'all_semesters') {
                expect(view.summary!.semesterSelect, isTrue);
                expect(view.semesters, hasLength(2));
                expect(view.semesters.first.id, 461);
                expect(view.semesters.first.selected, isTrue);
                expect(view.summary!.stageResults, {
                  'identity': JwProbeCode.ok,
                  'course': JwProbeCode.ok,
                  'exams': JwProbeCode.ok,
                });
                _expectCourseDiagnostics(
                  view.summary!.courseDiagnostics,
                  reason: 'none',
                  source: 'serverSelect',
                  serverOptions: 2,
                  liveOptions: 2,
                  literalAssignments: 0,
                  literalItems: 0,
                  literalParsed: false,
                );
                _expectCandidateChecks(view.safeSummary, course: 'ok');
              }
              if (mode == 'static_history_81') {
                expect(view.semesters, hasLength(81));
                expect(view.semesters.first.id, 81000);
                expect(view.semesters.last.id, 81080);
                expect(
                  view.semesters.map((semester) => semester.id).toSet(),
                  hasLength(81),
                );
                expect(
                  List<int>.generate(
                    81,
                    (index) => index,
                  ).every((index) => view.semesters[index].id == 81000 + index),
                  isTrue,
                );
                expect(view.semesters.first.selected, isTrue);
                expect(
                  view.semesters
                      .skip(1)
                      .every((semester) => !semester.selected),
                  isTrue,
                );
                expect(view.safeSummary, isNot(contains('81000')));
                expect(view.safeSummary, isNot(contains('81080')));
                expect(
                  view.safeSummary,
                  isNot(contains('History synthetic semester')),
                );
                _expectCourseDiagnostics(
                  view.summary!.courseDiagnostics,
                  reason: 'none',
                  source: 'serverSelect',
                  serverOptions: 81,
                  liveOptions: 1,
                  literalAssignments: 0,
                  literalItems: 0,
                  literalParsed: false,
                );
                expect(view.summary!.stageResults, {
                  'identity': JwProbeCode.ok,
                  'course': JwProbeCode.ok,
                  'exams': JwProbeCode.ok,
                });
                _expectCandidateChecks(view.safeSummary, course: 'ok');
              }
              if (mode == 'static_boundary_256') {
                expect(view.semesters, hasLength(256));
                expect(view.semesters.first.id, 100000);
                expect(view.semesters.last.id, 100255);
                expect(view.semesters.first.selected, isTrue);
                expect(
                  view.semesters
                      .skip(1)
                      .every((semester) => !semester.selected),
                  isTrue,
                );
                final expectedMaximumLabel = List<String>.filled(
                  120,
                  String.fromCharCode(92),
                ).join();
                expect(
                  view.semesters.every(
                    (semester) => semester.name == expectedMaximumLabel,
                  ),
                  isTrue,
                );
                expect(
                  view.semesters.map((semester) => semester.id).toSet(),
                  hasLength(256),
                );
                expect(
                  List<int>.generate(256, (index) => index).every(
                    (index) => view.semesters[index].id == 100000 + index,
                  ),
                  isTrue,
                );
                expect(view.safeSummary, isNot(contains('100000')));
                expect(view.safeSummary, isNot(contains('100255')));
                expect(view.safeSummary, isNot(contains(expectedMaximumLabel)));
                _expectCourseDiagnostics(
                  view.summary!.courseDiagnostics,
                  reason: 'none',
                  source: 'serverSelect',
                  serverOptions: 256,
                  liveOptions: 256,
                  literalAssignments: 0,
                  literalItems: 0,
                  literalParsed: false,
                );
                expect(view.summary!.stageResults, {
                  'identity': JwProbeCode.ok,
                  'course': JwProbeCode.ok,
                  'exams': JwProbeCode.ok,
                });
                _expectCandidateChecks(view.safeSummary, course: 'ok');
              }
              if (mode == 'json_boundary_256') {
                expect(view.semesters, hasLength(256));
                expect(view.semesters.first.id, 120000);
                expect(view.semesters.last.id, 120255);
                expect(view.semesters.first.name, 'JSON boundary 1');
                expect(view.semesters.last.name, 'JSON boundary 256');
                expect(view.semesters.first.selected, isTrue);
                expect(
                  view.semesters
                      .skip(1)
                      .every((semester) => !semester.selected),
                  isTrue,
                );
                expect(
                  view.semesters.map((semester) => semester.id).toSet(),
                  hasLength(256),
                );
                expect(
                  List<int>.generate(256, (index) => index).every((index) {
                    final semester = view.semesters[index];
                    return semester.id == 120000 + index &&
                        semester.name == 'JSON boundary ${index + 1}';
                  }),
                  isTrue,
                );
                expect(view.safeSummary, isNot(contains('120000')));
                expect(view.safeSummary, isNot(contains('120255')));
                expect(view.safeSummary, isNot(contains('JSON boundary 1')));
                expect(view.safeSummary, isNot(contains('JSON boundary 256')));
                _expectCourseDiagnostics(
                  view.summary!.courseDiagnostics,
                  reason: 'none',
                  source: 'serverJson',
                  serverOptions: 0,
                  liveOptions: 0,
                  literalAssignments: 2,
                  literalItems: 256,
                  literalParsed: true,
                );
                expect(view.summary!.stageResults, {
                  'identity': JwProbeCode.ok,
                  'course': JwProbeCode.ok,
                  'exams': JwProbeCode.ok,
                });
                _expectCandidateChecks(view.safeSummary, course: 'ok');
              }
              if (mode == 'json_catalog' || mode == 'json_null') {
                expect(view.summary!.semesterSelect, isTrue);
                expect(view.summary!.examHeader, isTrue);
                expect(view.semesters, hasLength(2));
                expect(view.semesters.first.id, 461);
                expect(view.semesters.first.name, '2026秋合成');
                expect(view.semesters.first.selected, mode == 'json_catalog');
                expect(view.semesters.last.id, 441);
                expect(view.semesters.last.name, '2026春合成');
                expect(
                  view.semesters.every((semester) => !semester.selected),
                  mode == 'json_null',
                );
                _expectCourseDiagnostics(
                  view.summary!.courseDiagnostics,
                  reason: 'none',
                  source: 'serverJson',
                  serverOptions: 0,
                  liveOptions: 2,
                  literalAssignments: 2,
                  literalItems: 2,
                  literalParsed: true,
                );
                expect(view.summary!.stageResults, {
                  'identity': JwProbeCode.ok,
                  'course': JwProbeCode.ok,
                  'exams': JwProbeCode.ok,
                });
                _expectCandidateChecks(view.safeSummary, course: 'ok');
              }
              if (mode == 'normal') {
                // Terminal fetch completion must release native operation
                // occupancy without requiring a new browser/document.
                await coordinator.runProbe('TEST0001');
                expect(coordinator.probeView.code, JwProbeCode.ok);
                expect(
                  coordinator.probeView.identity,
                  JwCandidateIdentity.candidateMatches,
                );
                expect(
                  fixture.requests
                      .where((request) => request.contains('student-info'))
                      .length,
                  2,
                );
              }
            } else if (_courseFailureReasons.containsKey(mode)) {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.code, JwProbeCode.courseSchema);
              expect(view.stage, 'course');
              expect(view.identity, JwCandidateIdentity.candidateMatches);
              expect(view.summary, isNotNull);
              expect(view.summary!.stageResults, {
                'identity': JwProbeCode.ok,
                'course': JwProbeCode.courseSchema,
                'exams': JwProbeCode.ok,
              });
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/17'),
                reason: 'a course schema failure must not skip the exam read',
              );
              _expectCourseDiagnostics(
                view.summary!.courseDiagnostics,
                reason: _courseFailureReasons[mode]!,
                source: 'none',
                serverOptions: switch (mode) {
                  'invalid_option_json' => 1,
                  'static_over_limit_257' => 257,
                  _ => 0,
                },
                liveOptions: switch (mode) {
                  'empty_select' => 2,
                  'invalid_option_json' => 1,
                  'static_over_limit_257' => 257,
                  _ => 0,
                },
                literalAssignments: switch (mode) {
                  'literal_duplicate' ||
                  'function_between_duplicate' ||
                  'bad_first_rhs_duplicate' => 3,
                  'literal_key_conflict' ||
                  'escaped_duplicate_key' ||
                  'fractional_selection' ||
                  'catalog_duplicate' ||
                  'catalog_id' ||
                  'catalog_name' ||
                  'selection_unknown' ||
                  'literal_map' ||
                  'catalog_limit' => 2,
                  'selection_missing' => 1,
                  _ => 0,
                },
                literalItems: switch (mode) {
                  'catalog_duplicate' => 2,
                  'fractional_selection' => 1,
                  'catalog_id' ||
                  'catalog_name' ||
                  'selection_unknown' ||
                  'selection_missing' => 1,
                  'catalog_limit' => 257,
                  _ => 0,
                },
                literalParsed: {
                  'catalog_duplicate',
                  'catalog_id',
                  'catalog_name',
                  'selection_unknown',
                  'selection_missing',
                  'fractional_selection',
                  'catalog_limit',
                }.contains(mode),
              );
              if (mode == 'static_over_limit_257') {
                expect(view.semesters, isEmpty);
                expect(view.summary!.semesterOptions, 0);
                expect(view.summary!.semesterSelect, isTrue);
                expect(view.safeSummary, isNot(contains('200000')));
                expect(view.safeSummary, isNot(contains('200256')));
                expect(
                  view.safeSummary,
                  isNot(contains('Over limit synthetic semester')),
                );
              }
              _expectCandidateChecks(view.safeSummary, course: 'course_schema');
            } else if (mode == 'observed_shape' ||
                mode == 'duplicate_semester_selects' ||
                mode == 'invalid_semester_option') {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.code, JwProbeCode.courseSchema);
              expect(view.stage, 'course');
              expect(view.identity, JwCandidateIdentity.candidateMatches);
              expect(view.summary, isNotNull);
              expect(view.summary!.stageResults, {
                'identity': JwProbeCode.ok,
                'course': JwProbeCode.courseSchema,
                'exams': JwProbeCode.ok,
              });
              expect(
                fixture.requests,
                contains('GET /for-std/exam-arrange/info/17'),
                reason: 'a course schema failure must not skip the exam read',
              );
              _expectCandidateChecks(view.safeSummary, course: 'course_schema');
              if (mode == 'observed_shape') {
                expect(view.summary!.semesterSelect, isFalse);
                expect(view.summary!.semesterOptions, 0);
                expect(view.summary!.examHeader, isTrue);
                expect(view.summary!.examTables, 1);
                expect(view.summary!.examRows, 0);
              } else if (mode == 'duplicate_semester_selects') {
                expect(view.summary!.semesterSelect, isFalse);
              } else {
                expect(view.summary!.semesterSelect, isTrue);
              }
            } else if (mode == 'mismatch') {
              expect(view.identity, JwCandidateIdentity.candidateMismatch);
            } else if (mode == 'conflict') {
              expect(view.identity, JwCandidateIdentity.candidateConflict);
            } else if (mode == 'missing') {
              expect(view.identity, JwCandidateIdentity.unavailable);
              expect(view.code, JwProbeCode.identitySchema);
            } else if (mode == 'exam_no_body' || mode == 'exam_bad_row') {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.code, JwProbeCode.examsSchema);
              expect(view.identity, JwCandidateIdentity.candidateMatches);
            } else if (mode == 'worker') {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.code, JwProbeCode.serviceWorkerControlled);
              expect(view.identity, JwCandidateIdentity.unavailable);
              expect(
                fixture.requests.where(
                  (request) => request.contains('student-info'),
                ),
                isEmpty,
              );
            } else if (mode == 'csp') {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.identity, JwCandidateIdentity.unavailable);
              expect(
                fixture.requests.where(
                  (request) => request.contains('student-info'),
                ),
                isEmpty,
              );
            } else {
              expect(view.phase, JwProbePhase.failed, reason: view.safeSummary);
              expect(view.identity, JwCandidateIdentity.unavailable);
            }
          } catch (error) {
            // Only synthetic case names, fixed phases/codes and exception type;
            // never browser assets, response text or projected private values.
            debugPrint(
              'Synthetic JW failure before cleanup: $mode, '
              'phase=${coordinator.view.phase.name}, '
              'probe=${coordinator.probeView.code.wire}, '
              'type=${error.runtimeType}',
            );
            rethrow;
          } finally {
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

void _expectCandidateChecks(String summary, {required String course}) {
  final decoded = jsonDecode(summary) as Map<String, dynamic>;
  expect(decoded['kind'], 'jw-candidate-contract-v3');
  expect(decoded['sourceAvailable'], isFalse);
  expect(decoded['checks'], {
    'identity': 'ok',
    'course': course,
    'exams': 'ok',
  });
  final structure = decoded['structure'] as Map<String, dynamic>;
  expect(structure.keys.toSet(), {
    'identityLabels',
    'semesterOptions',
    'semesterSelect',
    'semesterVariables',
    'examTables',
    'examHeader',
    'examRows',
    'pagination',
    'courseDiagnostics',
  });
  final diagnostics = structure['courseDiagnostics'] as Map<String, dynamic>;
  expect(diagnostics.keys.toSet(), {
    'reason',
    'source',
    'serverOptions',
    'liveOptions',
    'literalAssignments',
    'literalItems',
    'literalParsed',
  });
}

void _expectCourseDiagnostics(
  JwCourseDiagnostics diagnostics, {
  required String reason,
  required String source,
  required int serverOptions,
  required int liveOptions,
  required int literalAssignments,
  required int literalItems,
  required bool literalParsed,
}) {
  expect(diagnostics.reason, reason);
  expect(diagnostics.source, source);
  expect(diagnostics.serverOptions, serverOptions);
  expect(diagnostics.liveOptions, liveOptions);
  expect(diagnostics.literalAssignments, literalAssignments);
  expect(diagnostics.literalItems, literalItems);
  expect(diagnostics.literalParsed, literalParsed);
}

Future<void> _waitReady(
  ObservationCoordinator coordinator,
  List<BrowserEvent> events, {
  int? newerThan,
}) async {
  final elapsed = Stopwatch()..start();
  while (!coordinator.probeView.available ||
      (newerThan != null &&
          !events.any(
            (event) =>
                event.kind == BrowserEventKind.ready &&
                event.document > newerThan,
          ))) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('synthetic business document not ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
