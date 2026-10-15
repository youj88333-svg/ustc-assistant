import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _day = DateTime.utc(2026, 10, 15);
final _now = DateTime.utc(2026, 10, 15, 0);
final _syntheticKey = Uint8List.fromList('synthetic-model-key-01'.codeUnits);

void main() {
  test(
    'manual reminder snapshot guards concurrent rules and target edits',
    () async {
      final store = await _open();
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic reminder editor race',
            start: _now.add(const Duration(hours: 3)),
            end: _now.add(const Duration(hours: 4)),
            weekly: true,
          ),
        ),
      );
      final target = ReminderTarget.calendar(created.target!);
      const seriesPair = ReminderPair(
        ReminderRule.before(15),
        ReminderRule.none(),
      );
      const changedPair = ReminderPair(
        ReminderRule.before(10),
        ReminderRule.none(),
      );
      await store.features.saveReminderPair(target, seriesPair, series: true);
      final displayed = await store.features.inspectReminder(target);
      expect(displayed.pair.canonical, seriesPair.canonical);
      expect(displayed.origin, ReminderPairOrigin.series);
      expect(displayed.series, isFalse);
      expect(displayed.overridePresent, isFalse);
      final seriesDisplay = await store.features.inspectReminder(
        target,
        series: true,
      );
      expect(seriesDisplay.series, isTrue);
      expect(seriesDisplay.overridePresent, isTrue);

      await store.features.saveReminderPair(target, changedPair, series: true);
      final changedRevision =
          (await store.features.inspectReminders()).revision;
      await expectLater(
        store.features.saveInspectedReminder(displayed, ReminderPair.timed),
        throwsA(
          isA<ReminderFailure>().having(
            (e) => e.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
      expect(
        (await store.features.inspectReminders()).revision,
        changedRevision,
      );
      expect(await store.features.readReminderPair(target), isNull);
      final latest = await store.features.inspectReminder(target);
      await store.features.saveInspectedReminder(latest, seriesPair);
      expect(
        (await store.features.readReminderPair(target))!.canonical,
        seriesPair.canonical,
      );

      final beforeTargetEdit = await store.features.inspectReminder(target);
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(created.target!, completed: true),
      );
      await expectLater(
        store.features.saveInspectedReminder(beforeTargetEdit, null),
        throwsA(
          isA<ReminderFailure>().having(
            (e) => e.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
    },
  );

  test(
    'inspection distinguishes retained incompatible override from inheritance',
    () async {
      final store = await _open();
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic retained time kind rule',
            start: _day,
            end: _day.add(const Duration(days: 1)),
            allDay: true,
          ),
        ),
      );
      await store.features.saveReminderPair(
        ReminderTarget.calendar(created.target!),
        ReminderPair.allDay,
      );
      await _write(
        store,
        context,
        UpdatePersonalOccurrence(
          created.target!,
          PersonalEventDraft(
            title: 'synthetic retained time kind rule',
            start: _now.add(const Duration(hours: 3)),
            end: _now.add(const Duration(hours: 4)),
          ),
        ),
      );
      final current = (await _window(store)).items.single.reference;
      final inspection = await store.features.inspectReminder(
        ReminderTarget.calendar(current),
      );
      expect(inspection.allDay, isFalse);
      expect(inspection.origin, ReminderPairOrigin.defaults);
      expect(inspection.overridePresent, isTrue);
      expect(inspection.pair.canonical, ReminderPair.timed.canonical);
      await store.features.saveInspectedReminder(inspection, null);
      expect(
        (await store.features.inspectReminder(
          ReminderTarget.calendar(current),
        )).overridePresent,
        isFalse,
      );
    },
  );

  test('schema 15 upgrade preserves synthetic C3 and Agent assets', () async {
    final file = await _temporaryDatabase('m6-schema15-');
    var store = await _open(file: file);
    final context = await _context(store);
    final event = await _write(
      store,
      context,
      CreatePersonalEvent(
        PersonalEventDraft(
          title: 'schema 15 synthetic event',
          start: DateTime.utc(2026, 10, 15, 2),
          end: DateTime.utc(2026, 10, 15, 3),
        ),
      ),
    );
    final task = await _write(
      store,
      context,
      const CreateTask(TaskDraft(title: 'schema 15 synthetic task')),
    );
    final block = await _write(
      store,
      context,
      CreatePlanBlock(
        task.task!,
        PlanBlockDraft(
          startsAtUtc: DateTime.utc(2026, 10, 15, 4),
          endsAtUtc: DateTime.utc(2026, 10, 15, 5),
          location: 'synthetic room',
        ),
      ),
    );
    await _configureSyntheticAgent(store);
    await store.agent.createConversation();
    final ownerBefore = await _scalar(store, 'SELECT owner_id FROM jw_state');
    await store.close();

    _rewindToSchema15(file);
    expect(_schemaVersion(file), 15);
    store = await _open(file: file);

    expect(await _scalar(store, 'PRAGMA user_version'), 18);
    expect(await _scalar(store, 'SELECT owner_id FROM jw_state'), ownerBefore);
    final settings = await store.features.inspectReminders();
    expect(settings.preferences.enabled, isFalse);
    expect(settings.preferences.morningEnabled, isFalse);
    expect(settings.preferences.privateDisplay, isFalse);
    expect(settings.preferences.timed.canonical, ReminderPair.timed.canonical);
    expect(
      settings.preferences.allDay.canonical,
      ReminderPair.allDay.canonical,
    );

    final window = await _window(store);
    expect(
      window.items
          .singleWhere(
            (item) =>
                item.reference.identity.kind == CalendarKind.personal &&
                item.reference.identity.localId ==
                    event.target!.identity.localId,
          )
          .title,
      'schema 15 synthetic event',
    );
    final restoredTask = (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items.single;
    expect(restoredTask.reference.localId, task.task!.localId);
    expect(restoredTask.draft.title, 'schema 15 synthetic task');
    final restoredBlock = (await store.localCalendar.taskDetail(
      restoredTask.reference,
    )).blocks.single;
    expect(
      restoredBlock.reference.identity.localId,
      block.target!.identity.localId,
    );
    expect(restoredBlock.draft.location, 'synthetic room');
    expect(await _scalar(store, 'SELECT COUNT(*) FROM agent_conversations'), 1);
    expect((await store.agent.inspectAgent()).keySaved, isTrue);
  });

  test(
    'default opt-ins stay off until C3 changes feed a desired publication',
    () async {
      final store = await _open();
      final initial = await store.features.inspectReminders();
      expect(initial.preferences.enabled, isFalse);
      expect(initial.preferences.morningEnabled, isFalse);
      expect(initial.preferences.timed.canonical, ReminderPair.timed.canonical);
      expect(
        initial.preferences.allDay.canonical,
        ReminderPair.allDay.canonical,
      );

      final context = await _context(store);
      final event = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic private appointment',
            start: DateTime.utc(2026, 10, 15, 2),
            end: DateTime.utc(2026, 10, 15, 3),
            location: 'synthetic private location',
            note: 'synthetic private note must not enter publication',
          ),
        ),
      );
      final task = await _write(
        store,
        context,
        CreateTask(
          TaskDraft(
            title: 'synthetic deadline task',
            description: 'synthetic task description',
            note: 'synthetic task note',
            deadlineAtUtc: DateTime.utc(2026, 10, 15, 8),
          ),
        ),
      );
      final block = await _write(
        store,
        context,
        CreatePlanBlock(
          task.task!,
          PlanBlockDraft(
            startsAtUtc: DateTime.utc(2026, 10, 15, 4),
            endsAtUtc: DateTime.utc(2026, 10, 15, 5),
            location: 'synthetic block location',
            note: 'synthetic block note',
          ),
        ),
      );

      final disabled = await store.features.prepareReminderPublication();
      expect(disabled.enabled, isFalse);
      expect(disabled.desired, isEmpty);
      await store.features.saveReminderPreferences(
        initial,
        initial.preferences.copyWith(enabled: true, privateDisplay: true),
      );
      final publication = await store.features.prepareReminderPublication();

      expect(publication.enabled, isTrue);
      expect(publication.desired.map((m) => m.target.kind).toSet(), {
        ReminderKind.personal,
        ReminderKind.planBlock,
        ReminderKind.taskDeadline,
      });
      expect(publication.desired, hasLength(3));
      final eventMapping = publication.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.personal,
      );
      final blockMapping = publication.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.planBlock,
      );
      final taskMapping = publication.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.taskDeadline,
      );
      expect(eventMapping.target.localId, event.target!.identity.localId);
      expect(blockMapping.target.localId, block.target!.identity.localId);
      expect(taskMapping.target.localId, task.task!.localId);
      expect(publication.desired.every((m) => m.slot == 0), isTrue);
      expect(publication.desired.every((m) => m.request.id.isNotEmpty), isTrue);
      expect(
        publication.desired.every((m) => m.request.token.isNotEmpty),
        isTrue,
      );
      expect(eventMapping.request.title, '日程提醒');
      expect(eventMapping.request.location, isEmpty);
      expect(taskMapping.request.title, '任务截止提醒');
      for (final mapping in publication.desired) {
        expect(mapping.request.title, isNot(contains('synthetic private')));
        expect(
          mapping.request.detail,
          isNot(contains('synthetic private note')),
        );
        expect(mapping.request.detail, isNot(contains('synthetic task note')));
        expect(mapping.request.detail, isNot(contains('synthetic block note')));
      }

      final accepted = eventMapping.request;
      await store.features.recordReminderAccepted(publication, accepted.id);
      final activation = NotificationActivation(
        accepted.id,
        accepted.digest,
        accepted.token,
      );
      expect(await store.features.resolveNotification(activation), isNotNull);
      expect(
        await store.features.resolveNotification(
          NotificationActivation(accepted.id, accepted.digest, 'forged-token'),
        ),
        isNull,
      );

      final currentWindow = await _window(store);
      final currentEvent = currentWindow.items.singleWhere(
        (item) => item.reference.identity == event.target!.identity,
      );
      await _write(
        store,
        context,
        UpdatePersonalSeries(
          currentEvent.reference,
          PersonalEventDraft(
            title: 'synthetic appointment moved',
            start: DateTime.utc(2026, 10, 15, 3),
            end: DateTime.utc(2026, 10, 15, 4),
            location: 'synthetic new location',
            note: 'new synthetic note',
          ),
        ),
      );
      expect(
        await store.features.reminderPublicationCurrent(publication),
        isFalse,
      );
      await expectLater(
        store.features.recordReminderAccepted(publication, accepted.id),
        throwsA(
          isA<ReminderFailure>().having(
            (failure) => failure.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );

      final movedPublication = await store.features
          .prepareReminderPublication();
      final moved = movedPublication.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.personal,
      );
      expect(moved.logicalKey, eventMapping.logicalKey);
      expect(moved.request.id, accepted.id);
      expect(moved.request.digest, isNot(accepted.digest));
      expect(moved.accepted, isFalse);
      expect(movedPublication.invalidPriorIds, contains(accepted.id));

      await store.features.recordReminderAccepted(
        movedPublication,
        moved.request.id,
      );
      await store.features.recordReminderCancelled(moved.request.id);
      expect(
        (await _window(
          store,
        )).items.any((item) => item.title == 'synthetic appointment moved'),
        isTrue,
      );
      final afterCancel = await store.features.prepareReminderPublication();
      final stillDesired = afterCancel.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.personal,
      );
      expect(stillDesired.logicalKey, moved.logicalKey);
      expect(stillDesired.accepted, isFalse);

      await store.features.recordReminderAccepted(
        afterCancel,
        stillDesired.request.id,
      );
      final latestActivation = NotificationActivation(
        stillDesired.request.id,
        stillDesired.request.digest,
        stillDesired.request.token,
      );
      final latestWindow = await _window(store);
      final latestEvent = latestWindow.items.singleWhere(
        (item) => item.reference.identity == event.target!.identity,
      );
      await _write(
        store,
        context,
        DeletePersonalSeries(latestEvent.reference, confirmed: true),
      );
      expect(
        await store.features.resolveNotification(latestActivation),
        isNull,
      );

      // Model a C3 epoch invalidation with synthetic state only. The accepted
      // native identity must stop resolving even while its object still exists.
      final beforeEpochChange = await store.features
          .prepareReminderPublication();
      final currentBlock = beforeEpochChange.desired.singleWhere(
        (m) => m.target.kind == ReminderKind.planBlock,
      );
      await store.features.recordReminderAccepted(
        beforeEpochChange,
        currentBlock.request.id,
      );
      await store.customStatement(
        'UPDATE agenda_state SET epoch=epoch+1 WHERE singleton=1',
      );
      expect(
        await store.features.resolveNotification(
          NotificationActivation(
            currentBlock.request.id,
            currentBlock.request.digest,
            currentBlock.request.token,
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'a failed C3 transaction never advances reminder expected state',
    () async {
      var failAtCheckpoint = false;
      final store = await _open(
        onCalendarCheckpoint: () async {
          if (failAtCheckpoint) {
            throw StateError('synthetic rollback checkpoint');
          }
        },
      );
      final context = await _context(store);
      final event = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'rollback baseline',
            start: DateTime.utc(2026, 10, 15, 2),
            end: DateTime.utc(2026, 10, 15, 3),
          ),
        ),
      );
      var settings = await store.features.inspectReminders();
      await store.features.saveReminderPreferences(
        settings,
        settings.preferences.copyWith(enabled: true),
      );
      final before = await store.features.prepareReminderPublication();
      expect(before.desired, hasLength(1));
      final rollbackTarget = (await _window(store)).items.singleWhere(
        (item) =>
            item.reference.identity.localId == event.target!.identity.localId,
      );

      failAtCheckpoint = true;
      await expectLater(
        _write(
          store,
          context,
          UpdatePersonalSeries(
            rollbackTarget.reference,
            PersonalEventDraft(
              title: 'must roll back',
              start: DateTime.utc(2026, 10, 15, 4),
              end: DateTime.utc(2026, 10, 15, 5),
            ),
          ),
        ),
        throwsA(
          isA<CalendarFailure>().having(
            (failure) => failure.code,
            'code',
            CalendarFailureCode.storageFailed,
          ),
        ),
      );
      failAtCheckpoint = false;

      expect(await store.features.reminderPublicationCurrent(before), isTrue);
      expect(
        (await store.features.prepareReminderPublication())
            .desired
            .single
            .request
            .digest,
        before.desired.single.request.digest,
      );
      expect((await _window(store)).items.single.title, 'rollback baseline');
      settings = await store.features.inspectReminders();
      expect(settings.revision, greaterThan(0));
    },
  );

  test(
    'personal exact reminder pair takes precedence over its series pair',
    () async {
      final store = await _open();
      final context = await _context(store);
      await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic weekly series',
            start: DateTime.utc(2026, 10, 15, 2),
            end: DateTime.utc(2026, 10, 15, 3),
            weekly: true,
            untilDay: DateTime.utc(2026, 10, 29),
          ),
        ),
      );
      final window = await store.localCalendar.query(
        CalendarQuery(
          firstDay: _day,
          endDayExclusive: DateTime.utc(2026, 10, 30),
        ),
      );
      final occurrences = window.items
          .where(
            (item) => item.reference.identity.kind == CalendarKind.personal,
          )
          .toList();
      expect(occurrences, hasLength(3));
      final first = ReminderTarget.calendar(occurrences[0].reference);
      final exact = const ReminderPair(
        ReminderRule.before(15),
        ReminderRule.none(),
      );
      const series = ReminderPair(ReminderRule.before(60), ReminderRule.none());
      await store.features.saveReminderPair(first, series, series: true);
      await store.features.saveReminderPair(first, exact);
      expect(
        (await store.features.readReminderPair(first))?.canonical,
        exact.canonical,
      );
      expect(
        (await store.features.readReminderPair(first, series: true))?.canonical,
        series.canonical,
      );

      final settings = await store.features.inspectReminders();
      await store.features.saveReminderPreferences(
        settings,
        settings.preferences.copyWith(enabled: true),
      );
      final publication = await store.features.prepareReminderPublication();
      final firstReminder = publication.desired.singleWhere(
        (m) =>
            m.target.localId == first.localId &&
            m.target.ordinal == first.ordinal,
      );
      final secondReminder = publication.desired.singleWhere(
        (m) =>
            m.target.localId == first.localId &&
            m.target.ordinal == occurrences[1].reference.identity.ordinal,
      );
      expect(
        firstReminder.request.deliveryAtUtc,
        occurrences[0].startsAtUtc.subtract(const Duration(minutes: 15)),
      );
      expect(
        secondReminder.request.deliveryAtUtc,
        occurrences[1].startsAtUtc.subtract(const Duration(minutes: 60)),
      );
    },
  );
}

Future<JwStore> _open({
  File? file,
  Future<void> Function()? onCalendarCheckpoint,
}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _SyntheticOwnership(),
    clock: FixedClock(_now),
    modelCredentialProtector: _SyntheticProtector(),
    onCalendarCheckpoint: onCalendarCheckpoint,
  );
  try {
    await store.initialize();
    await store.agent.initializeAgent();
    await store.features.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<AgentSettingsSnapshot> _configureSyntheticAgent(JwStore store) async {
  final snapshot = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    snapshot.authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _syntheticKey,
  );
  return store.agent.inspectAgent();
}

Future<CalendarContext> _context(JwStore store) async =>
    (await _window(store)).context;

Future<CalendarWindow> _window(JwStore store) => store.localCalendar.query(
  CalendarQuery(
    firstDay: _day,
    endDayExclusive: _day.add(const Duration(days: 2)),
  ),
);

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<Object?> _scalar(JwStore store, String sql) async =>
    (await store.customSelect(sql).getSingle()).data.values.single;

void _rewindToSchema15(File file) {
  final database = sqlite3.sqlite3.open(file.path);
  try {
    database.execute('BEGIN IMMEDIATE');
    database.execute('DROP TABLE IF EXISTS young_daily_sync');
    database.execute('ALTER TABLE jw_events DROP COLUMN source_retired');
    database.execute('ALTER TABLE young_events DROP COLUMN source_retired');
    for (final table in const [
      'm6_native_map',
      'm6_reminder_overrides',
      'm6_expected',
      'm6_state',
      'm6_briefs',
      'm6_brief_suppressed',
    ]) {
      database.execute('DROP TABLE IF EXISTS $table');
    }
    database.execute('PRAGMA user_version=15');
    database.execute('COMMIT');
  } on Object {
    database.execute('ROLLBACK');
    rethrow;
  } finally {
    database.close();
  }
}

int _schemaVersion(File file) {
  final database = sqlite3.sqlite3.open(file.path);
  try {
    return database.select('PRAGMA user_version').single['user_version'] as int;
  } finally {
    database.close();
  }
}

Future<File> _temporaryDatabase(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
      throw StateError('Unexpected synthetic M6 database root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
            'store.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic M6 database asset');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}store.sqlite');
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-m6-protector/v1';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
  );
}
