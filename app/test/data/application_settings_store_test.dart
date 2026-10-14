import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

import '../support/calendar_legacy_schema.dart';

final _day = DateTime.utc(2026, 10, 12);
final _clock = FixedClock(DateTime.utc(2026, 10, 12, 12));

void main() {
  test(
    'preferences persist both fields, replay exactly, and roll back atomically',
    () async {
      var failCheckpoint = false;
      final store = await _open(
        checkpoint: () async {
          if (failCheckpoint) throw StateError('synthetic settings checkpoint');
        },
      );

      final initial = await store.applicationSettings.inspectSettings();
      expect(initial.preferences.calendarView, DefaultCalendarView.week);
      expect(initial.preferences.includeInactive, isFalse);

      final selected = const DisplayPreferences(
        calendarView: DefaultCalendarView.day,
        includeInactive: true,
      );
      final write = PreferencesWrite(
        operationId: _preferencesId(1),
        context: initial.context,
        preferences: selected,
      );
      final first = await store.applicationSettings.savePreferences(write);
      expect(first.replayed, isFalse);
      final replay = await store.applicationSettings.savePreferences(write);
      expect(replay.replayed, isTrue);
      expect(replay.context, first.context);
      expect(
        (await store.applicationSettings.inspectSettings()).preferences,
        selected,
      );
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);

      await _settingsFailure(
        store.applicationSettings.savePreferences(
          PreferencesWrite(
            operationId: write.operationId,
            context: initial.context,
            preferences: const DisplayPreferences(),
          ),
        ),
        SettingsFailureCode.invalidIntent,
      );

      final beforeFailure = await store.applicationSettings.inspectSettings();
      failCheckpoint = true;
      await _settingsFailure(
        store.applicationSettings.savePreferences(
          PreferencesWrite(
            operationId: _preferencesId(2),
            context: beforeFailure.context,
            preferences: const DisplayPreferences(),
          ),
        ),
        SettingsFailureCode.storageFailed,
      );
      final afterFailure = await store.applicationSettings.inspectSettings();
      expect(afterFailure.context, beforeFailure.context);
      expect(afterFailure.preferences, beforeFailure.preferences);
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);

      failCheckpoint = false;
      final saved = await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: _preferencesId(3),
          context: afterFailure.context,
          preferences: const DisplayPreferences(),
        ),
      );
      expect(saved.context.revision, afterFailure.context.revision + 1);
      expect(
        (await store.applicationSettings.inspectSettings()).preferences,
        const DisplayPreferences(),
      );
    },
  );

  test(
    'confirmation, changed operation intent, and stale settings context write nothing',
    () async {
      final store = await _open();
      final initial = await store.applicationSettings.inspectSettings();
      final calendarContext = await _calendarContext(store);
      await _writeCalendar(
        store,
        calendarContext,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成保留安排',
            start: DateTime.utc(2026, 10, 12, 1),
            end: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );

      await _settingsFailure(
        store.applicationSettings.prepareMaintenance(
          initial.context,
          MaintenanceKind.agenda,
          confirmed: false,
        ),
        SettingsFailureCode.confirmationRequired,
      );
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        1,
      );
      expect(await _count(store, 'app_settings_receipts'), 0);
      expect(await _count(store, 'app_settings_audit'), 0);

      final request = await store.applicationSettings.prepareMaintenance(
        initial.context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      final changedScope = MaintenanceRequest(
        operationId: request.operationId,
        context: request.context,
        kind: MaintenanceKind.reset,
        intentFingerprint: request.intentFingerprint,
      );
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(changedScope),
        SettingsFailureCode.staleContext,
      );
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);

      await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: _preferencesId(11),
          context: initial.context,
          preferences: const DisplayPreferences(
            calendarView: DefaultCalendarView.day,
          ),
        ),
      );
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(request),
        SettingsFailureCode.staleContext,
      );
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        1,
      );
      expect(
        (await _calendarContext(store)).agendaEpoch,
        calendarContext.agendaEpoch,
      );
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);
    },
  );

  test(
    'source work and an unsettled synthetic knowledge load block intent persistence',
    () async {
      final store = await _open();
      final context =
          (await store.applicationSettings.inspectSettings()).context;

      final sourceRequest = await store.applicationSettings.prepareMaintenance(
        context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      final source = await store.publicStore.beginPublicJob(
        PublicSource.campus,
      );
      final pendingLocal = await store.localCalendar.prepare(
        await _calendarContext(store),
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '忙碌拒绝后仍有效的合成意图',
            start: DateTime.utc(2026, 10, 12, 1),
            end: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(sourceRequest),
        SettingsFailureCode.busy,
      );
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).context,
        context,
      );
      await store.publicStore.finishPublicJob(source);
      store.publicStore.releasePublicJob(source);
      await store.localCalendar.commit(pendingLocal);
      expect((await _calendarContext(store)).agendaEpoch, context.agendaEpoch);

      await store.publicStore.beginKnowledgeLoad();
      final loadRequest = await store.applicationSettings.prepareMaintenance(
        context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(loadRequest),
        SettingsFailureCode.busy,
      );
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).context,
        context,
      );
      expect(await _count(store, 'app_maintenance_intent'), 0);
      expect(await _scalar(store, 'SELECT maintenance FROM agenda_state'), 0);
      await store.publicStore.cancelKnowledgeLoad();
    },
  );

  test(
    'stale settings guards leave synthetic knowledge and its references untouched',
    () async {
      final store = await _open();
      await _seedRetainedData(store);
      final oldContext =
          (await store.applicationSettings.inspectSettings()).context;
      final search = await store.publicStore.searchKnowledge('合成');
      expect(search.candidates, hasLength(1));
      final reference = search.candidates.single.reference;
      final beforeRead = await store.publicStore.readKnowledgeMaterial(
        reference,
      );
      expect(beforeRead.document!.markdown, '合成正文');

      await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: _preferencesId(31),
          context: oldContext,
          preferences: const DisplayPreferences(
            calendarView: DefaultCalendarView.day,
          ),
        ),
      );
      final current = await store.applicationSettings.inspectSettings();
      expect(current.context.revision, oldContext.revision + 1);
      final knowledgeEpoch = await _scalar(
        store,
        'SELECT epoch FROM knowledge_state',
      );
      final knowledgeSequence = await _scalar(
        store,
        'SELECT sequence FROM knowledge_state',
      );
      final edition = await _scalar(
        store,
        'SELECT edition FROM knowledge_state',
      );
      final loadCount = await _scalar(
        store,
        'SELECT load_count FROM knowledge_state',
      );
      final consent = await _scalar(
        store,
        'SELECT icourse_consent FROM knowledge_state',
      );
      final icourseGeneration = await _scalar(
        store,
        "SELECT generation FROM public_sources WHERE source='icourse'",
      );
      final materialCount = await _count(store, 'knowledge_materials');
      final sectionCount = await _count(store, 'knowledge_sections');
      final loadCountRows = await _count(store, 'knowledge_loads');
      final loadItemCount = await _count(store, 'knowledge_load_items');
      final auditCount = await _count(store, 'knowledge_audit');

      await _settingsFailure(
        store.publicStore.setIcourseConsent(
          false,
          expectedSettingsContext: oldContext,
        ),
        SettingsFailureCode.staleContext,
      );
      await _settingsFailure(
        store.publicStore.clearKnowledge(
          confirmed: true,
          expectedSettingsContext: oldContext,
        ),
        SettingsFailureCode.staleContext,
      );

      expect(
        (await store.applicationSettings.inspectSettings()).context,
        current.context,
      );
      expect(await store.publicStore.hasIcourseConsent(), isTrue);
      expect(
        await _scalar(store, 'SELECT epoch FROM knowledge_state'),
        knowledgeEpoch,
      );
      expect(
        await _scalar(store, 'SELECT sequence FROM knowledge_state'),
        knowledgeSequence,
      );
      expect(
        await _scalar(store, 'SELECT edition FROM knowledge_state'),
        edition,
      );
      expect(
        await _scalar(store, 'SELECT load_count FROM knowledge_state'),
        loadCount,
      );
      expect(
        await _scalar(store, 'SELECT icourse_consent FROM knowledge_state'),
        consent,
      );
      expect(
        await _scalar(
          store,
          "SELECT generation FROM public_sources WHERE source='icourse'",
        ),
        icourseGeneration,
      );
      expect(await _count(store, 'knowledge_materials'), materialCount);
      expect(await _count(store, 'knowledge_sections'), sectionCount);
      expect(await _count(store, 'knowledge_loads'), loadCountRows);
      expect(await _count(store, 'knowledge_load_items'), loadItemCount);
      expect(await _count(store, 'knowledge_audit'), auditCount);
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);
      final afterRead = await store.publicStore.readKnowledgeMaterial(
        reference,
      );
      expect(afterRead.document!.markdown, beforeRead.document!.markdown);
    },
  );

  test(
    'agenda clear and reset keep their fixed scopes across recovery and replay',
    () async {
      final file = await _tempFile();
      var store = await _open(file: file);
      final originalPreferences = const DisplayPreferences(
        calendarView: DefaultCalendarView.day,
        includeInactive: true,
      );
      final start = await store.applicationSettings.inspectSettings();
      await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: _preferencesId(21),
          context: start.context,
          preferences: originalPreferences,
        ),
      );
      await _seedRetainedData(store);
      await _seedSourceBusiness(store, 41);
      await _createAgendaFixture(store);
      await _setHighWater(store, 900);

      final beforeAgenda = await store.applicationSettings.inspectSettings();
      expect(beforeAgenda.counts.jwCourses, 1);
      expect(beforeAgenda.counts.young, 1);
      expect(beforeAgenda.counts.personal, 2);
      expect(beforeAgenda.counts.tasks, 1);
      expect(beforeAgenda.counts.blocks, 1);
      expect(beforeAgenda.counts.materials, 1);
      final oldCalendarContext = await _calendarContext(store);
      final lateCommand = await store.localCalendar.prepare(
        oldCalendarContext,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成迟到写入',
            start: DateTime.utc(2026, 10, 13, 1),
            end: DateTime.utc(2026, 10, 13, 2),
          ),
        ),
      );
      final agendaRequest = await store.applicationSettings.prepareMaintenance(
        beforeAgenda.context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      final agendaIntent = await store.applicationSettings.beginMaintenance(
        agendaRequest,
      );
      final duplicateBegin = await store.applicationSettings.beginMaintenance(
        agendaRequest,
      );
      expect(
        duplicateBegin.request.operationId,
        agendaIntent.request.operationId,
      );
      expect(duplicateBegin.targetContext, agendaIntent.targetContext);
      expect(
        (await store.applicationSettings.inspectSettings()).context,
        agendaIntent.targetContext,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        2,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.tasks,
        1,
      );
      expect(await _count(store, 'agenda_relations'), 1);
      expect(await _count(store, 'agenda_undo'), 1);
      expect(await _count(store, 'agenda_receipts'), greaterThan(0));
      expect(await _count(store, 'agenda_audit'), greaterThan(0));
      expect(
        agendaIntent.targetContext.resetEpoch,
        beforeAgenda.context.resetEpoch,
      );
      expect(
        agendaIntent.targetContext.agendaEpoch,
        beforeAgenda.context.agendaEpoch + 1,
      );
      await expectLater(
        store.localCalendar.commit(lateCommand),
        throwsA(isA<CalendarFailure>()),
      );
      await expectLater(
        store.publicStore.beginPublicJob(PublicSource.campus),
        throwsA(isA<PublicFailure>()),
      );

      final expanded = MaintenanceRequest(
        operationId: agendaIntent.request.operationId,
        context: agendaIntent.request.context,
        kind: MaintenanceKind.reset,
        intentFingerprint: agendaIntent.request.intentFingerprint,
      );
      await _settingsFailure(
        store.applicationSettings.completeMaintenance(
          MaintenanceIntent(
            request: expanded,
            targetContext: agendaIntent.targetContext,
          ),
        ),
        SettingsFailureCode.invalidIntent,
      );
      final changedFingerprint = MaintenanceRequest(
        operationId: agendaIntent.request.operationId,
        context: agendaIntent.request.context,
        kind: MaintenanceKind.agenda,
        intentFingerprint: 'f' * 64,
      );
      await _settingsFailure(
        store.applicationSettings.completeMaintenance(
          MaintenanceIntent(
            request: changedFingerprint,
            targetContext: agendaIntent.targetContext,
          ),
        ),
        SettingsFailureCode.invalidIntent,
      );
      final changedContext = SettingsContext(
        owner: agendaIntent.request.context.owner,
        resetEpoch: agendaIntent.request.context.resetEpoch + 1,
        agendaEpoch: agendaIntent.request.context.agendaEpoch,
        revision: agendaIntent.request.context.revision,
      );
      final wrongContext = MaintenanceRequest(
        operationId: agendaIntent.request.operationId,
        context: changedContext,
        kind: MaintenanceKind.agenda,
        intentFingerprint: agendaIntent.request.intentFingerprint,
      );
      await _settingsFailure(
        store.applicationSettings.completeMaintenance(
          MaintenanceIntent(
            request: wrongContext,
            targetContext: agendaIntent.targetContext,
          ),
        ),
        SettingsFailureCode.invalidIntent,
      );
      final wrongTarget = SettingsContext(
        owner: agendaIntent.targetContext.owner,
        resetEpoch: agendaIntent.targetContext.resetEpoch + 1,
        agendaEpoch: agendaIntent.targetContext.agendaEpoch,
        revision: agendaIntent.targetContext.revision,
      );
      await _settingsFailure(
        store.applicationSettings.completeMaintenance(
          MaintenanceIntent(
            request: agendaIntent.request,
            targetContext: wrongTarget,
          ),
        ),
        SettingsFailureCode.staleContext,
      );

      await store.close();
      final pendingDb = sqlite3.sqlite3.open(file.path);
      try {
        expect(
          pendingDb
              .select('SELECT maintenance FROM agenda_state')
              .single['maintenance'],
          1,
        );
        expect(
          pendingDb
              .select('SELECT operation_id FROM app_maintenance_intent')
              .single['operation_id'],
          agendaRequest.operationId,
        );
        expect(
          pendingDb
              .select('SELECT COUNT(*) AS n FROM personal_events')
              .single['n'],
          2,
        );
      } finally {
        pendingDb.close();
      }

      store = JwStore(
        NativeDatabase(file),
        ownership: _TestOwnership(),
        clock: _clock,
        knowledgeIdentity: _syntheticKnowledgeIdentity(),
      );
      addTearDown(store.close);
      final recovered = await store.applicationSettings.bootstrapMaintenance();
      expect(recovered, isNotNull);
      expect(recovered!.request.operationId, agendaIntent.request.operationId);
      expect(recovered.request.context, agendaIntent.request.context);
      expect(recovered.targetContext, agendaIntent.targetContext);
      final resumedBegin = await store.applicationSettings.beginMaintenance(
        recovered.request,
      );
      expect(resumedBegin.targetContext, recovered.targetContext);

      final agendaReceipt = await store.applicationSettings.completeMaintenance(
        recovered,
      );
      expect(agendaReceipt.replayed, isFalse);
      await store.initialize();
      final afterAgenda = await store.applicationSettings.inspectSettings();
      expect(afterAgenda.counts.jwCourses, 0);
      expect(afterAgenda.counts.jwExams, 0);
      expect(afterAgenda.counts.young, 0);
      expect(afterAgenda.counts.personal, 0);
      expect(afterAgenda.counts.tasks, 0);
      expect(afterAgenda.counts.blocks, 0);
      expect(afterAgenda.counts.materials, 1);
      expect(afterAgenda.accountBound, isTrue);
      expect(afterAgenda.credentialSaved, isTrue);
      expect(await _count(store, 'jw_credential_audit'), 1);
      expect(afterAgenda.icourseConsent, isTrue);
      expect(afterAgenda.preferences, originalPreferences);
      expect(
        List<int>.from(
          await _scalar(store, 'SELECT ciphertext FROM jw_credentials')
              as Iterable,
        ),
        [0x01, 0x02, 0x03, 0x04],
      );
      expect(afterAgenda.context.owner, beforeAgenda.context.owner);
      expect(afterAgenda.context.resetEpoch, beforeAgenda.context.resetEpoch);
      expect(
        afterAgenda.context.agendaEpoch,
        beforeAgenda.context.agendaEpoch + 1,
      );
      expect(await _count(store, 'jw_permits'), 1);
      expect(await _count(store, 'young_permits'), 1);
      expect(await _count(store, 'jw_semester_catalog'), 1);
      expect(await _count(store, 'jw_preferences'), 1);
      expect(await _count(store, 'young_preferences'), 1);
      expect(
        await _scalar(store, 'SELECT semester_id FROM jw_preferences'),
        17,
      );
      expect(
        await _scalar(
          store,
          'SELECT first_day || \'|\' || last_day FROM young_preferences',
        ),
        '2026-09-01|2026-12-31',
      );
      expect(
        await _scalar(store, 'SELECT options_json FROM jw_semester_catalog'),
        '[]',
      );
      expect(
        await _scalar(store, 'SELECT partition_id FROM jw_permits'),
        'jwp-${'a' * 32}',
      );
      expect(
        await _scalar(store, 'SELECT partition_id FROM young_permits'),
        'yp-${'b' * 32}',
      );
      expect(await _count(store, 'knowledge_sections'), 1);
      expect(await _count(store, 'knowledge_loads'), 1);
      expect(
        await _scalar(store, 'SELECT edition FROM knowledge_state'),
        'synthetic-edition',
      );
      expect(await _scalar(store, 'SELECT load_count FROM knowledge_state'), 1);
      expect(
        await _scalar(store, 'SELECT markdown FROM knowledge_materials'),
        '# 合成保留资料\n\n仅供测试。',
      );
      for (final table in const [
        'agenda_undo',
        'agenda_relations',
        'personal_occurrence_overrides',
        'local_plan_blocks',
        'local_tasks',
        'personal_events',
        'agenda_receipts',
        'agenda_audit',
        'jw_overlays',
        'jw_events',
        'jw_imports',
        'jw_local_receipts',
        'jw_audit',
        'jw_jobs',
        'young_overlays',
        'young_events',
        'young_receipts',
        'young_local_receipts',
        'young_audit',
        'young_jobs',
      ]) {
        expect(
          await _count(store, table),
          0,
          reason: '$table is agenda clear scope',
        );
      }
      expect(await _count(store, 'app_settings_receipts'), 2);
      expect(await _count(store, 'app_settings_audit'), 2);
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_receipts WHERE action='preferences'",
        ),
        1,
      );
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_receipts WHERE action='agenda'",
        ),
        1,
      );
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_audit WHERE action='preferences'",
        ),
        1,
      );
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_audit WHERE action='agenda'",
        ),
        1,
      );
      await _expectHighWater(store, 900);

      final agendaReplay = await store.applicationSettings.completeMaintenance(
        recovered,
      );
      expect(agendaReplay.replayed, isTrue);
      expect(agendaReplay.context, agendaReceipt.context);
      expect(await _count(store, 'app_settings_receipts'), 2);
      expect(await _count(store, 'app_settings_audit'), 2);
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_receipts WHERE action='agenda'",
        ),
        1,
      );
      expect(
        await _scalar(
          store,
          "SELECT COUNT(*) FROM app_settings_audit WHERE action='agenda'",
        ),
        1,
      );

      final currentCalendarContext = await _calendarContext(store);
      final preparedDuringIdle = await store.localCalendar.prepare(
        currentCalendarContext,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成历史回执后提交',
            start: DateTime.utc(2026, 10, 14, 3),
            end: DateTime.utc(2026, 10, 14, 4),
          ),
        ),
      );
      final currentJwTicket = await store.beginJob();
      final currentPublicTicket = await store.publicStore.beginPublicJob(
        PublicSource.campus,
      );
      final replayWhileNewWorkIsActive = await store.applicationSettings
          .completeMaintenance(recovered);
      expect(replayWhileNewWorkIsActive.replayed, isTrue);
      await store.failJob(currentJwTicket);
      expect(
        await _scalar(store, 'SELECT status FROM jw_jobs WHERE job_id=?', [
          currentJwTicket.stamp.jobId,
        ]),
        'failed',
      );
      await store.publicStore.ensurePublicJob(currentPublicTicket);
      await store.publicStore.finishPublicJob(currentPublicTicket);
      store.publicStore.releasePublicJob(currentPublicTicket);
      expect(
        await _scalar(
          store,
          "SELECT active_job FROM public_sources WHERE source='campus'",
        ),
        isNull,
      );
      final preparedReceipt = await store.localCalendar.commit(
        preparedDuringIdle,
      );
      expect(preparedReceipt.replayed, isFalse);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        1,
      );

      await _seedSourceBusiness(store, 61);
      await _createAgendaFixture(store);
      await _setHighWater(store, 1200);
      final beforeReset = await store.applicationSettings.inspectSettings();
      final resetRequest = await store.applicationSettings.prepareMaintenance(
        beforeReset.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      final resetIntent = await store.applicationSettings.beginMaintenance(
        resetRequest,
      );
      expect(
        resetIntent.targetContext.resetEpoch,
        beforeReset.context.resetEpoch + 1,
      );
      expect(
        resetIntent.targetContext.agendaEpoch,
        beforeReset.context.agendaEpoch + 1,
      );
      expect(await _count(store, 'jw_permits'), 0);
      expect(await _count(store, 'young_permits'), 0);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.jwCourses,
        1,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.materials,
        1,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).credentialSaved,
        isTrue,
      );

      await _settingsFailure(
        store.applicationSettings.completeMaintenance(recovered),
        SettingsFailureCode.busy,
      );
      await expectLater(
        store.publicStore.setIcourseConsent(false),
        throwsA(isA<PublicFailure>()),
      );
      await expectLater(
        store.publicStore.beginKnowledgeLoad(),
        throwsA(isA<PublicFailure>()),
      );
      expect(
        (await store.applicationSettings.inspectSettings()).icourseConsent,
        isTrue,
      );
      expect(await _count(store, 'knowledge_loads'), 1);

      final resetReceipt = await store.applicationSettings.completeMaintenance(
        resetIntent,
      );
      expect(resetReceipt.replayed, isFalse);
      final afterReset = await store.applicationSettings.inspectSettings();
      expect(afterReset.context.owner, beforeReset.context.owner);
      expect(afterReset.context.resetEpoch, beforeReset.context.resetEpoch + 1);
      expect(
        afterReset.context.agendaEpoch,
        beforeReset.context.agendaEpoch + 1,
      );
      expect(afterReset.accountBound, isFalse);
      expect(afterReset.credentialSaved, isFalse);
      expect(afterReset.icourseConsent, isFalse);
      expect(afterReset.preferences, const DisplayPreferences());
      expect(afterReset.counts.jwCourses, 0);
      expect(afterReset.counts.young, 0);
      expect(afterReset.counts.personal, 0);
      expect(afterReset.counts.tasks, 0);
      expect(afterReset.counts.blocks, 0);
      expect(afterReset.counts.materials, 0);
      for (final table in const [
        'jw_account',
        'jw_credentials',
        'jw_credential_audit',
        'jw_permits',
        'young_permits',
        'jw_preferences',
        'jw_semester_catalog',
        'young_preferences',
        'knowledge_sections',
        'knowledge_materials',
        'knowledge_load_items',
        'knowledge_loads',
        'knowledge_audit',
      ]) {
        expect(await _count(store, table), 0, reason: '$table is reset scope');
      }
      for (final table in const [
        'agenda_undo',
        'agenda_relations',
        'personal_occurrence_overrides',
        'local_plan_blocks',
        'local_tasks',
        'personal_events',
        'agenda_receipts',
        'agenda_audit',
        'jw_overlays',
        'jw_events',
        'jw_imports',
        'jw_local_receipts',
        'jw_audit',
        'jw_jobs',
        'young_overlays',
        'young_events',
        'young_receipts',
        'young_local_receipts',
        'young_audit',
        'young_jobs',
      ]) {
        expect(await _count(store, table), 0, reason: '$table is reset scope');
      }
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);
      await _expectHighWater(store, 1200);

      final resetReplay = await store.applicationSettings.completeMaintenance(
        resetIntent,
      );
      expect(resetReplay.replayed, isTrue);
      expect(resetReplay.context, resetReceipt.context);
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);
      expect(
        await _scalar(store, 'SELECT action FROM app_settings_receipts'),
        'reset',
      );
      expect(
        await _scalar(store, 'SELECT action FROM app_settings_audit'),
        'reset',
      );

      final postResetContext = await _calendarContext(store);
      final newEvent = await _writeCalendar(
        store,
        postResetContext,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '重置后可新建',
            start: DateTime.utc(2026, 10, 14, 1),
            end: DateTime.utc(2026, 10, 14, 2),
          ),
        ),
      );
      expect(newEvent.target!.identity.localId, greaterThan(1200));
      final newTask = await _writeCalendar(
        store,
        postResetContext,
        const CreateTask(TaskDraft(title: '重置后新任务')),
      );
      expect(newTask.task!.localId, greaterThan(1200));
    },
  );

  test(
    'maintenance checkpoint failures roll back whole transactions and retain retry scope',
    () async {
      var failCheckpoint = false;
      final store = await _open(
        checkpoint: () async {
          if (failCheckpoint) {
            throw StateError('synthetic maintenance checkpoint');
          }
        },
      );
      await _seedRetainedData(store);
      await _seedSourceBusiness(store, 71);
      await _createAgendaFixture(store);
      final original = await store.applicationSettings.inspectSettings();

      final request = await store.applicationSettings.prepareMaintenance(
        original.context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      failCheckpoint = true;
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(request),
        SettingsFailureCode.storageFailed,
      );
      failCheckpoint = false;
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).context,
        original.context,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        2,
      );
      expect((await _scalar(store, 'SELECT maintenance FROM agenda_state')), 0);
      expect(
        (await _scalar(store, 'SELECT reset_epoch FROM jw_state')),
        original.context.resetEpoch,
      );
      expect(await _count(store, 'jw_permits'), 1);
      expect(await _count(store, 'app_settings_receipts'), 0);
      expect(await _count(store, 'app_settings_audit'), 0);

      final intent = await store.applicationSettings.beginMaintenance(request);
      failCheckpoint = true;
      await _settingsFailure(
        store.applicationSettings.completeMaintenance(intent),
        SettingsFailureCode.storageFailed,
      );
      failCheckpoint = false;
      final stillPending = await store.applicationSettings
          .bootstrapMaintenance();
      expect(stillPending, isNotNull);
      expect(stillPending!.request.operationId, request.operationId);
      expect(
        stillPending.targetContext,
        (await store.applicationSettings.inspectSettings()).context,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        2,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.tasks,
        1,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.jwCourses,
        1,
      );
      expect(
        (await store.applicationSettings.inspectSettings()).counts.materials,
        1,
      );
      expect(await _count(store, 'jw_overlays'), 1);
      expect(await _count(store, 'jw_permits'), 1);
      expect((await _scalar(store, 'SELECT maintenance FROM agenda_state')), 1);
      expect(await _count(store, 'agenda_receipts'), greaterThan(0));
      expect(await _count(store, 'app_settings_receipts'), 0);
      expect(await _count(store, 'app_settings_audit'), 0);

      final receipt = await store.applicationSettings.completeMaintenance(
        stillPending,
      );
      expect(receipt.replayed, isFalse);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        0,
      );
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);

      final afterAgenda = await store.applicationSettings.inspectSettings();
      final knowledgeEpoch = await _scalar(
        store,
        'SELECT epoch FROM knowledge_state',
      );
      final resetRequest = await store.applicationSettings.prepareMaintenance(
        afterAgenda.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      failCheckpoint = true;
      await _settingsFailure(
        store.applicationSettings.beginMaintenance(resetRequest),
        SettingsFailureCode.storageFailed,
      );
      failCheckpoint = false;
      expect(await store.applicationSettings.bootstrapMaintenance(), isNull);
      expect(
        (await store.applicationSettings.inspectSettings()).context,
        afterAgenda.context,
      );
      expect(await _scalar(store, 'SELECT maintenance FROM agenda_state'), 0);
      expect(
        await _scalar(store, 'SELECT reset_epoch FROM jw_state'),
        afterAgenda.context.resetEpoch,
      );
      expect(
        await _scalar(store, 'SELECT epoch FROM knowledge_state'),
        knowledgeEpoch,
      );
      expect(await _count(store, 'jw_permits'), 1);
      expect(await _count(store, 'young_permits'), 1);
      expect(await _count(store, 'app_maintenance_intent'), 0);
      expect(await _count(store, 'app_settings_receipts'), 1);
      expect(await _count(store, 'app_settings_audit'), 1);

      final resetIntent = await store.applicationSettings.beginMaintenance(
        resetRequest,
      );
      expect(
        resetIntent.targetContext.resetEpoch,
        afterAgenda.context.resetEpoch + 1,
      );
      expect(await _count(store, 'jw_permits'), 0);
      expect(await _count(store, 'young_permits'), 0);
      final resetReceipt = await store.applicationSettings.completeMaintenance(
        resetIntent,
      );
      expect(resetReceipt.replayed, isFalse);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.materials,
        0,
      );
      expect(await _count(store, 'app_settings_receipts'), 1);
    },
  );

  test(
    'bootstrap rejects an orphaned barrier and an unknown persisted scope',
    () async {
      final orphan = await _open();
      await orphan.customStatement(
        'UPDATE agenda_state SET maintenance=1 WHERE singleton=1',
      );
      await _settingsFailure(
        orphan.applicationSettings.bootstrapMaintenance(),
        SettingsFailureCode.invalidIntent,
      );
      await orphan.close();

      final corrupt = await _open();
      final context =
          (await corrupt.applicationSettings.inspectSettings()).context;
      final request = await corrupt.applicationSettings.prepareMaintenance(
        context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      await corrupt.applicationSettings.beginMaintenance(request);
      // Model a corrupt/future disk file without weakening production CHECKs.
      await corrupt.customStatement('PRAGMA ignore_check_constraints=ON');
      await corrupt.customStatement(
        'UPDATE app_maintenance_intent SET scope_version=2 WHERE singleton=1',
      );
      await corrupt.customStatement('PRAGMA ignore_check_constraints=OFF');
      await _settingsFailure(
        corrupt.applicationSettings.bootstrapMaintenance(),
        SettingsFailureCode.invalidIntent,
      );
      expect(
        (await _scalar(corrupt, 'SELECT maintenance FROM agenda_state')),
        1,
      );
    },
  );

  test(
    'schema nine upgrade preserves old synthetic facts and rolls back a late collision',
    () async {
      final file = await _tempFile();
      var store = await _open(file: file);
      await _seedRetainedData(store);
      await _seedSourceBusiness(store, 81);
      await _createAgendaFixture(store);
      await _setHighWater(store, 1500);
      final beforeUpgradeContext =
          (await store.applicationSettings.inspectSettings()).context;
      await store.close();

      _makeSyntheticVersionNine(file);
      var raw = sqlite3.sqlite3.open(file.path);
      Map<String, List<List<Object?>>> before;
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 9);
        before = _legacyFacts(raw);
      } finally {
        raw.close();
      }

      store = await _open(file: file);
      raw = sqlite3.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 15);
        expect(_legacyFacts(raw), before);
        expect(
          raw
              .select('SELECT owner_id,reset_epoch FROM jw_state')
              .single['reset_epoch'],
          beforeUpgradeContext.resetEpoch,
        );
        expect(
          raw.select('SELECT epoch FROM agenda_state').single['epoch'],
          beforeUpgradeContext.agendaEpoch + 1,
        );
        expect(
          List<int>.from(
            raw
                    .select('SELECT ciphertext FROM jw_credentials')
                    .single['ciphertext']
                as Iterable,
          ),
          [0x01, 0x02, 0x03, 0x04],
        );
      } finally {
        raw.close();
      }
      final migrated = await store.applicationSettings.inspectSettings();
      expect(migrated.preferences, const DisplayPreferences());
      expect(migrated.context.owner, beforeUpgradeContext.owner);
      await store.close();

      _makeSyntheticVersionNine(file);
      raw = sqlite3.sqlite3.open(file.path);
      try {
        raw.execute(
          'CREATE TABLE app_settings_receipts (synthetic_collision TEXT)',
        );
        raw.execute(
          "INSERT INTO app_settings_receipts VALUES ('keep-on-failure')",
        );
        raw.execute('PRAGMA user_version=9');
        before = _legacyFacts(raw);
      } finally {
        raw.close();
      }
      await expectLater(
        _open(file: file),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.code,
            'code',
            FailureCode.storageFailed,
          ),
        ),
      );
      raw = sqlite3.sqlite3.open(file.path);
      try {
        expect(_legacyFacts(raw), before);
        expect(raw.select('PRAGMA user_version').single['user_version'], 9);
        expect(
          raw
              .select(
                "SELECT name FROM sqlite_master WHERE name='app_settings'",
              )
              .length,
          0,
        );
        expect(
          raw
              .select(
                "SELECT name FROM sqlite_master WHERE name='app_maintenance_intent'",
              )
              .length,
          0,
        );
        expect(
          raw
              .select('SELECT synthetic_collision FROM app_settings_receipts')
              .single['synthetic_collision'],
          'keep-on-failure',
        );
        raw.execute('DROP TABLE app_settings_receipts');
      } finally {
        raw.close();
      }
      store = await _open(file: file);
      expect(
        (await store.applicationSettings.inspectSettings()).preferences,
        const DisplayPreferences(),
      );
      expect(await _count(store, 'app_settings'), 1);
    },
  );
}

Future<JwStore> _open({File? file, Future<void> Function()? checkpoint}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _TestOwnership(),
    clock: _clock,
    onSettingsCheckpoint: checkpoint,
    knowledgeIdentity: _syntheticKnowledgeIdentity(),
  );
  try {
    await store.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<void> _seedRetainedData(JwStore store) async {
  final context = (await store.applicationSettings.inspectSettings()).context;
  final jwPartitionId = 'jwp-${'a' * 32}';
  final youngPartitionId = 'yp-${'b' * 32}';
  final jwPartitionMetadata = jsonEncode({
    'id': jwPartitionId,
    'ownerId': context.owner,
    'purpose': 'initial',
    'attempt': 'jw-1-1',
    'resetEpoch': context.resetEpoch,
  });
  final youngPartitionMetadata = jsonEncode({
    'id': youngPartitionId,
    'ownerId': context.owner,
    'purpose': 'initial',
    'attempt': 'young-1-1',
    'resetEpoch': context.resetEpoch,
  });
  final materialMetadata = jsonEncode({
    'key': 'synthetic/material',
    'title': '合成保留资料',
    'provider': 'teach',
    'topic': 'synthetic-topic',
    'audience': 'synthetic-audience',
    'sourceVersion': 'synthetic-source-version',
    'articleUrl': 'https://www.teach.ustc.edu.cn/synthetic',
    'materialUrl': null,
    'sourceDigest': 'c' * 64,
    'scope': 'synthetic-scope',
    'reviewVersion': 'synthetic-review',
    'publishedOn': null,
    'updatedOn': null,
  });
  await store.customStatement(
    "INSERT OR REPLACE INTO jw_account VALUES (1,'SYNTHETICACCOUNT')",
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO jw_credentials VALUES (1,'synthetic-protector',X'01020304')",
  );
  await store.customStatement(
    "INSERT INTO jw_credential_audit(action,committed_at) VALUES ('saved',1791806400000000)",
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO jw_preferences VALUES (1,17)",
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO jw_semester_catalog VALUES (1,'[]',1791806400000000)",
  );
  await store.customStatement(
    'INSERT OR REPLACE INTO jw_permits VALUES (?,?,1)',
    [jwPartitionId, jwPartitionMetadata],
  );
  await store.customStatement(
    'INSERT OR REPLACE INTO young_permits VALUES (?,?,1)',
    [youngPartitionId, youngPartitionMetadata],
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO young_preferences VALUES (1,'2026-09-01','2026-12-31')",
  );
  await store.customStatement(
    'UPDATE knowledge_state SET edition=?,load_count=1,icourse_consent=1 WHERE singleton=1',
    ['synthetic-edition'],
  );
  await store.customStatement(
    'INSERT OR REPLACE INTO knowledge_materials VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    [
      'synthetic/material',
      'synthetic-revision',
      materialMetadata,
      '# 合成保留资料\n\n仅供测试。',
      '合成保留资料',
      'teach',
      'synthetic-topic',
      'synthetic-audience',
      'synthetic-source-version',
      1791806400000000,
      20,
    ],
  );
  await store.customStatement(
    'INSERT OR REPLACE INTO knowledge_sections VALUES (?,?,?,?,?,?)',
    ['synthetic/material', 0, '合成章节', '合成正文', '合成纯文本', '合成检索文本'],
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO knowledge_loads VALUES ('synthetic-load','synthetic-edition',0,0,'done',1,0,1)",
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO knowledge_load_items VALUES ('synthetic-load','synthetic/material','synthetic-revision','accepted')",
  );
  await store.customStatement(
    "INSERT OR REPLACE INTO knowledge_audit VALUES (1,'synthetic-load',1,1791806400000000)",
  );
}

Future<void> _seedSourceBusiness(JwStore store, int id) async {
  final start = DateTime.utc(2026, 10, 12, 1).microsecondsSinceEpoch;
  final end = DateTime.utc(2026, 10, 12, 2).microsecondsSinceEpoch;
  await store.customStatement(
    'INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,academic_json,starts_at,ends_at,presence,version) VALUES (?,?,?,?,?,?,?,?,?,?)',
    [
      id,
      'synthetic-jw-$id',
      'course',
      17,
      '合成教务事件',
      null,
      start,
      end,
      'observed',
      1,
    ],
  );
  await store.customStatement(
    "INSERT INTO jw_overlays(local_id,hidden,note,attendance,listening) VALUES (?,1,'合成覆盖','attend','listening')",
    [id],
  );
  await store.customStatement(
    'INSERT INTO young_events(local_id,external_id,item_id,title,place,starts_at,ends_at,presence,version) VALUES (?,?,?,?,?,?,?,?,?)',
    [
      id + 1,
      'synthetic-young-$id',
      'synthetic-item-$id',
      '合成二课事件',
      '合成地点',
      start,
      end,
      'observed',
      1,
    ],
  );
  await store.customStatement(
    "INSERT INTO young_overlays(local_id,hidden,note,attendance) VALUES (?,1,'合成二课覆盖','attend')",
    [id + 1],
  );
}

Future<void> _createAgendaFixture(JwStore store) async {
  final context = await _calendarContext(store);
  final left = await _writeCalendar(
    store,
    context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: '合成个人安排甲',
        start: DateTime.utc(2026, 10, 12, 3),
        end: DateTime.utc(2026, 10, 12, 4),
        note: '保留于维护前',
      ),
    ),
  );
  final completed = await _writeCalendar(
    store,
    context,
    SetPersonalOccurrenceState(left.target!, completed: true),
  );
  final right = await _writeCalendar(
    store,
    context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: '合成个人安排乙',
        start: DateTime.utc(2026, 10, 12, 3, 30),
        end: DateTime.utc(2026, 10, 12, 4, 30),
      ),
    ),
  );
  await _writeCalendar(
    store,
    context,
    SaveCalendarRelation(
      left: completed.target!,
      right: right.target!,
      kind: CalendarRelationKind.notConflict,
      note: '合成日程关系',
    ),
  );
  final task = await _writeCalendar(
    store,
    context,
    const CreateTask(TaskDraft(title: '合成任务')),
  );
  await _writeCalendar(
    store,
    context,
    CreatePlanBlock(
      task.task!,
      PlanBlockDraft(
        startsAtUtc: DateTime.utc(2026, 10, 12, 7),
        endsAtUtc: DateTime.utc(2026, 10, 12, 8),
        note: '合成规划块',
      ),
    ),
  );
}

Future<CalendarWriteReceipt> _writeCalendar(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<CalendarContext> _calendarContext(JwStore store) async =>
    (await store.localCalendar.query(
      CalendarQuery(
        firstDay: _day,
        endDayExclusive: _day.add(const Duration(days: 7)),
        includeHidden: true,
        includeSkipped: true,
      ),
    )).context;

Future<void> _setHighWater(JwStore store, int value) async {
  for (final table in const [
    'personal_events',
    'local_tasks',
    'local_plan_blocks',
    'agenda_relations',
    'agenda_audit',
    'jw_events',
    'young_events',
  ]) {
    await store.customStatement(
      'UPDATE sqlite_sequence SET seq=? WHERE name=?',
      [value, table],
    );
  }
}

Future<void> _expectHighWater(JwStore store, int value) async {
  for (final table in const [
    'personal_events',
    'local_tasks',
    'local_plan_blocks',
    'agenda_relations',
    'agenda_audit',
    'jw_events',
    'young_events',
  ]) {
    expect(
      await _scalar(store, 'SELECT seq FROM sqlite_sequence WHERE name=?', [
        table,
      ]),
      value,
      reason: '$table sequence survives fixed-scope deletion',
    );
  }
}

Future<int> _count(JwStore store, String table) async =>
    (await _scalar(store, 'SELECT COUNT(*) FROM $table')) as int;

Future<Object?> _scalar(
  JwStore store,
  String sql, [
  List<Object?> args = const [],
]) async =>
    (await store
            .customSelect(
              sql,
              variables: [
                for (final arg in args)
                  if (arg is int)
                    Variable.withInt(arg)
                  else
                    Variable.withString(arg as String),
              ],
            )
            .getSingle())
        .data
        .values
        .single;

Future<void> _settingsFailure<T>(Future<T> action, SettingsFailureCode code) =>
    expectLater(
      action,
      throwsA(
        isA<SettingsFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

String _preferencesId(int value) =>
    'preferences-${value.toRadixString(16).padLeft(32, '0')}';

KnowledgeEditionIdentity _syntheticKnowledgeIdentity() =>
    KnowledgeEditionIdentity(
      key: 'synthetic-settings-edition',
      catalogDigest: List<String>.filled(64, 'c').join(),
      materialKeys: const ['synthetic/material'],
    );

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('m44-settings-store-');
  addTearDown(() async {
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!dir.absolute.path.toLowerCase().startsWith(prefix.toLowerCase()) ||
        !dir.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('m44-settings-store-')) {
      throw StateError('Unexpected synthetic temporary root');
    }
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
            'store.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic temporary entry');
      }
      await entry.delete();
    }
    await dir.delete();
  });
  return File('${dir.path}${Platform.pathSeparator}store.sqlite');
}

void _makeSyntheticVersionNine(File file) {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    raw.execute('BEGIN');
    removeSettingsTablesForLegacyFixture(raw);
    raw.execute('PRAGMA user_version=9');
    raw.execute('COMMIT');
  } finally {
    raw.close();
  }
}

Map<String, List<List<Object?>>> _legacyFacts(sqlite3.Database raw) => {
  for (final query in const [
    'SELECT owner_id,reset_epoch FROM jw_state',
    'SELECT * FROM jw_account',
    'SELECT account_id,mechanism,ciphertext FROM jw_credentials',
    'SELECT * FROM jw_credential_audit',
    'SELECT * FROM jw_preferences',
    'SELECT * FROM jw_semester_catalog',
    'SELECT * FROM jw_permits',
    'SELECT * FROM young_permits',
    'SELECT * FROM young_preferences',
    'SELECT * FROM jw_imports',
    'SELECT * FROM jw_events',
    'SELECT * FROM jw_overlays',
    'SELECT * FROM jw_local_receipts',
    'SELECT * FROM jw_audit',
    'SELECT * FROM jw_jobs',
    'SELECT * FROM young_events',
    'SELECT * FROM young_overlays',
    'SELECT * FROM young_receipts',
    'SELECT * FROM young_local_receipts',
    'SELECT * FROM young_audit',
    'SELECT * FROM young_jobs',
    'SELECT * FROM knowledge_state',
    'SELECT * FROM knowledge_materials',
    'SELECT * FROM knowledge_sections',
    'SELECT * FROM knowledge_loads',
    'SELECT * FROM knowledge_load_items',
    'SELECT * FROM knowledge_audit',
    'SELECT * FROM personal_events',
    'SELECT * FROM personal_occurrence_overrides',
    'SELECT * FROM local_tasks',
    'SELECT * FROM local_plan_blocks',
    'SELECT * FROM agenda_undo',
    'SELECT * FROM agenda_relations',
    'SELECT * FROM agenda_receipts',
    'SELECT * FROM agenda_audit',
    'SELECT name,seq FROM sqlite_sequence ORDER BY name',
  ])
    query: [
      for (final row in raw.select(query))
        [
          for (final value in row.values)
            value is Uint8List ? value.toList() : value,
        ],
    ],
};

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
