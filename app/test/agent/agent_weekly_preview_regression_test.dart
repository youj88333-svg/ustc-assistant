import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/agent_plan_preview.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _now = DateTime.utc(2026, 10, 15);
final _until = DateTime.utc(2026, 10, 29);
const _context = CalendarContext(
  owner: 'synthetic-weekly-preview',
  resetEpoch: 0,
  agendaEpoch: 0,
);

void main() {
  for (final scenario in [
    (
      name: 'cancel bounded repetition without explicitly clearing until',
      bounded: true,
      weekly: false,
      clearUntil: false,
    ),
    (
      name: 'keep bounded repetition',
      bounded: true,
      weekly: true,
      clearUntil: false,
    ),
    (
      name: 'explicitly clear until while keeping repetition',
      bounded: true,
      weekly: true,
      clearUntil: true,
    ),
    (
      name: 'cancel repetition that already has no until',
      bounded: false,
      weekly: false,
      clearUntil: false,
    ),
  ]) {
    final original = _draft(scenario.bounded ? _until : null);
    final unbounded = scenario.weekly && scenario.clearUntil;
    final expectedUntil = scenario.weekly && !scenario.clearUntil
        ? original.untilDay
        : null;

    test('pure preview: ${scenario.name}', () {
      const target = CalendarReference(
        _context,
        CalendarIdentity(CalendarKind.personal, 1),
        1,
      );
      final preview = previewAgentPlan(
        CalendarSnapshot(
          context: _context,
          revision: 1,
          school: const [],
          personal: [PersonalSeries(localId: 1, version: 1, draft: original)],
          overrides: const [],
          relations: const [],
        ),
        [
          AgentPersonalPatch(
            target,
            entireSeries: true,
            weekly: scenario.weekly,
            clearUntil: scenario.clearUntil,
          ),
        ],
        _now,
      );

      expect(preview.complete, !unbounded);
      expect(preview.freeConstraintViolated, unbounded ? isNull : isFalse);
      expect(
        preview.warnings.map((warning) => warning.code),
        unbounded
            ? [AgentPlanPreviewWarningCode.recurringBeyondWindow]
            : isEmpty,
      );
    });

    test('C3 commit and shared undo: ${scenario.name}', () async {
      final store = await _open();
      final calendar = store.localCalendar;
      final (context, _) = await calendar.readPlanContext();
      final created = await calendar.commit(
        await calendar.prepare(context, CreatePersonalEvent(original)),
      );
      final before = await _seriesItems(
        store,
        created.target!.identity.localId,
      );
      expect(before, hasLength(scenario.bounded ? 3 : 5));
      final (_, revision) = await calendar.readPlanContext();
      final settings = await store.agent.inspectAgent();
      final conversation = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        settings.authority,
        conversation,
        '合成日程重复规则修改，不访问学校或模型',
      );
      final changes = [
        AgentPersonalPatch(
          created.target!,
          entireSeries: true,
          weekly: scenario.weekly,
          clearUntil: scenario.clearUntil,
        ),
      ];
      if (unbounded) {
        // Clearing the bound cannot claim that every future repeat is free.
        await expectLater(
          calendar.prepareLocalPlan(
            ticket,
            context,
            revision,
            changes,
            requireFree: true,
          ),
          throwsA(
            isA<CalendarFailure>().having(
              (failure) => failure.code,
              'code',
              CalendarFailureCode.invalidInput,
            ),
          ),
        );
      }
      final plan = await calendar.prepareLocalPlan(
        ticket,
        context,
        revision,
        changes,
        requireFree: !unbounded,
      );
      final receipt = await calendar.commitLocalPlan(
        await calendar.approveLocalPlan(plan),
      );
      expect(receipt.committedCount, 1);
      expect(receipt.undo, isNotNull);
      final after = await _seriesItems(store, created.target!.identity.localId);
      expect(after, hasLength(scenario.weekly ? (unbounded ? 5 : 3) : 1));
      final detail = await calendar.detail(after.first.reference);
      expect(detail.personalDraft!.weekly, scenario.weekly);
      expect(detail.personalDraft!.untilDay, expectedUntil);

      await calendar.commit(
        await calendar.prepare(context, UndoCalendarWrite(receipt.undo!)),
      );
      final restored = await _seriesItems(
        store,
        created.target!.identity.localId,
      );
      expect(restored, hasLength(before.length));
      expect(
        (await calendar.detail(
          restored.first.reference,
        )).personalDraft!.canonical,
        original.canonical,
      );
      expect(
        restored.first.reference.version,
        greaterThan(after.first.reference.version),
      );
    });
  }
}

PersonalEventDraft _draft(DateTime? until) => PersonalEventDraft(
  title: '合成每周安排',
  start: DateTime.utc(2026, 10, 15, 2),
  end: DateTime.utc(2026, 10, 15, 3),
  weekly: true,
  untilDay: until,
);

Future<List<CalendarOccurrence>> _seriesItems(JwStore store, int id) async =>
    (await store.localCalendar.query(
      CalendarQuery(
        firstDay: _now,
        endDayExclusive: _now.add(const Duration(days: 31)),
      ),
    )).items.where((item) => item.reference.identity.localId == id).toList();

Future<JwStore> _open() async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _Ownership(),
    clock: FixedClock(_now),
    modelCredentialProtector: _Protector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-weekly-model',
    modelIds: const ['synthetic-weekly-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: Uint8List.fromList('synthetic-weekly-key'.codeUnits),
  );
  return store;
}

final class _Ownership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _Protector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-weekly-protector/v1';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext);
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(ciphertext);
}
