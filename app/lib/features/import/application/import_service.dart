import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../data/import_repository.dart';
import '../data/source_bundle_decoder.dart';
import '../domain/import_result.dart';
import '../domain/source_bundle.dart';
import '../domain/source_bundle_error.dart';
import 'reminder_reconciler.dart';

class ImportService {
  ImportService({
    required this.database,
    required this.decoder,
    this.reminderReconciler = const NoopReminderReconciler(),
  }) : repository = ImportRepository(database);

  final AppDatabase database;
  final SourceBundleDecoder decoder;
  final ReminderReconciler reminderReconciler;
  final ImportRepository repository;
  static const _uuid = Uuid();

  Future<ImportResult> importBytes(
    Uint8List bytes, {
    required String accountId,
    required ImportOrigin origin,
  }) async {
    final bundle = decoder.decode(bytes);
    bundle.requireSubject(accountId);

    final existing = await repository.batchByBundleId(
      accountId,
      bundle.bundleId,
    );
    if (existing != null) {
      if (existing.digest != bundle.digest) {
        throwSourceBundleError('duplicate_identity');
      }
      return ImportResult(
        status: ImportStatus.replayed,
        bundleId: bundle.bundleId,
        source: bundle.source,
        importedEntityCount: 0,
      );
    }

    final result = await database.transaction(
      () => _importTransaction(bundle, accountId, origin),
    );
    try {
      await reminderReconciler.reconcile(
        accountId: accountId,
        source: bundle.source,
      );
      return result;
    } catch (_) {
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: bundle.source,
        actionType: 'reminder_reconcile',
        result: 'retryable_failure',
        safeSummary: 'Reminder reconciliation is pending.',
        occurredAt: DateTime.now().millisecondsSinceEpoch,
      );
      return result.copyWith(reminderReconciliationPending: true);
    }
  }

  Future<ImportResult> _importTransaction(
    SourceBundle bundle,
    String accountId,
    ImportOrigin origin,
  ) async {
    final now = bundle.collectedAt.millisecondsSinceEpoch;
    final batchId = _uuid.v4();
    await database
        .into(database.importBatches)
        .insert(
          ImportBatchesCompanion.insert(
            id: batchId,
            accountId: accountId,
            bundleId: bundle.bundleId,
            digest: bundle.digest,
            source: bundle.source,
            scopeKey: bundle.snapshot.scopeKey,
            importedAt: now,
            origin: origin.name,
          ),
        );

    final localIds = <String, String>{};
    for (final record in bundle.data.sourceRecords) {
      final prior = await repository.sourceRecordByExternalId(
        accountId: accountId,
        source: bundle.source,
        externalId: record.externalId,
      );
      localIds['${record.entityType}\u0000${record.entityExternalId}'] =
          prior?.localEntityId ?? _uuid.v4();
    }

    for (final series in bundle.data.courseSeries) {
      await database
          .into(database.courseSeries)
          .insertOnConflictUpdate(
            CourseSeriesCompanion.insert(
              id: localIds['course_series\u0000${series.externalId}']!,
              accountId: accountId,
              source: bundle.source,
              externalId: series.externalId,
              title: series.title,
              courseCode: Value(series.courseCode),
              semesterKey: series.semesterKey,
              participantsJson: Value(jsonEncode(series.participants)),
              sourceDetailsJson: jsonEncode(series.sourceDetails),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    final sourceStatuses = {
      for (final record in bundle.data.sourceRecords)
        '${record.entityType}\u0000${record.entityExternalId}':
            record.sourceStatus,
    };
    for (final event in bundle.data.calendarEvents) {
      final timed = event.time.kind == 'timed';
      final localId = localIds['calendar_event\u0000${event.externalId}']!;
      final existingEvent = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(localId))).getSingleOrNull();
      await database
          .into(database.calendarEvents)
          .insertOnConflictUpdate(
            CalendarEventsCompanion.insert(
              id: localId,
              accountId: accountId,
              source: bundle.source,
              externalId: Value(event.externalId),
              sourceSeriesExternalId: Value(event.seriesExternalId),
              title: event.title,
              description: Value(event.descriptionText),
              type: event.eventType,
              status: Value(
                sourceStatuses['calendar_event\u0000${event.externalId}'] ==
                        'cancelled'
                    ? 'cancelled'
                    : 'active',
              ),
              startAt: Value(
                timed ? event.time.startAt!.millisecondsSinceEpoch : null,
              ),
              endAt: Value(
                timed ? event.time.endAt!.millisecondsSinceEpoch : null,
              ),
              allDay: !timed,
              startDate: Value(timed ? null : event.time.startDate),
              endDateExclusive: Value(
                timed ? null : event.time.endDateExclusive,
              ),
              timezone: event.time.timezone,
              locationName: Value(event.location['name'] as String?),
              buildingName: Value(event.location['building'] as String?),
              campusName: Value(event.location['campus'] as String?),
              participantsJson: Value(jsonEncode(event.participants)),
              sourceDetailsJson: Value(jsonEncode(event.sourceDetails)),
              importance: Value(event.sourceDefaults['importance'] as String),
              completionPolicy: const Value('auto_complete'),
              createdAt: existingEvent?.createdAt ?? now,
              updatedAt: now,
            ),
          );
    }

    for (final relation in bundle.data.scheduleRelations) {
      await database
          .into(database.scheduleRelations)
          .insertOnConflictUpdate(
            ScheduleRelationsCompanion.insert(
              id: localIds['schedule_relation\u0000${relation.externalId}']!,
              accountId: accountId,
              source: Value(bundle.source),
              externalId: Value(relation.externalId),
              relationType: Value(relation.relationType),
              primaryEntityType: Value(
                relation.primary['entityType'] as String,
              ),
              primaryEntityId: Value(
                localIds['${relation.primary['entityType']}\u0000'
                    '${relation.primary['externalId']}'],
              ),
              relatedEntityType: Value(
                relation.related['entityType'] as String,
              ),
              relatedEntityId: Value(
                localIds['${relation.related['entityType']}\u0000'
                    '${relation.related['externalId']}'],
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    final observedRecordIds = <String>{};
    for (final record in bundle.data.sourceRecords) {
      final prior = await repository.sourceRecordByExternalId(
        accountId: accountId,
        source: bundle.source,
        externalId: record.externalId,
      );
      observedRecordIds.add(record.externalId);
      await database
          .into(database.sourceRecords)
          .insertOnConflictUpdate(
            SourceRecordsCompanion.insert(
              id: prior?.id ?? _uuid.v4(),
              accountId: accountId,
              source: bundle.source,
              entityType: record.entityType,
              externalId: record.externalId,
              localEntityId:
                  localIds['${record.entityType}\u0000${record.entityExternalId}']!,
              sourceStatus: record.sourceStatus,
              presence: 'observed',
              scopeKey: bundle.snapshot.scopeKey,
              importBatchId: Value(batchId),
              sourceUpdatedAt: Value(
                record.sourceUpdatedAt?.millisecondsSinceEpoch,
              ),
              firstObservedAt: prior?.firstObservedAt ?? now,
              lastObservedAt: now,
            ),
          );
    }
    await _markAbsentRecords(
      bundle: bundle,
      accountId: accountId,
      observedRecordIds: observedRecordIds,
      now: now,
    );

    await database
        .into(database.syncRuns)
        .insert(
          SyncRunsCompanion.insert(
            id: _uuid.v4(),
            accountId: accountId,
            source: bundle.source,
            trigger: origin.name,
            state: 'success',
            resultCode: const Value('imported'),
            startedAt: now,
            finishedAt: Value(now),
            importBatchId: Value(batchId),
          ),
        );
    await database.actionLogsRepository.append(
      accountId: accountId,
      source: bundle.source,
      actionType: 'source_import',
      result: 'success',
      safeSummary: 'Complete source snapshot imported.',
      occurredAt: now,
    );

    return ImportResult(
      status: ImportStatus.imported,
      bundleId: bundle.bundleId,
      source: bundle.source,
      importedEntityCount:
          bundle.data.calendarEvents.length +
          bundle.data.courseSeries.length +
          bundle.data.scheduleRelations.length,
    );
  }

  Future<void> _markAbsentRecords({
    required SourceBundle bundle,
    required String accountId,
    required Set<String> observedRecordIds,
    required int now,
  }) async {
    final records = await repository.sourceRecordsFor(
      accountId: accountId,
      source: bundle.source,
    );
    for (final record in records) {
      if (observedRecordIds.contains(record.externalId)) {
        continue;
      }
      var presence = 'outside_scope';
      if (bundle.source == 'ustc_jw') {
        if (record.scopeKey == bundle.snapshot.scopeKey) {
          presence = 'missing_within_scope';
        } else {
          continue;
        }
      } else if (record.entityType == 'calendar_event') {
        final event =
            await (database.select(database.calendarEvents)
                  ..where((row) => row.id.equals(record.localEntityId)))
                .getSingleOrNull();
        if (event != null) {
          final from = bundle.snapshot.scope['fromDate'] as String;
          final through = bundle.snapshot.scope['throughDate'] as String;
          final eventDate = event.allDay
              ? event.startDate!
              : DateTime.fromMillisecondsSinceEpoch(event.startAt!, isUtc: true)
                    .add(const Duration(hours: 8))
                    .toIso8601String()
                    .substring(0, 10);
          if (eventDate.compareTo(from) >= 0 &&
              eventDate.compareTo(through) <= 0) {
            presence = 'missing_within_scope';
          }
        }
      }
      await (database.update(
        database.sourceRecords,
      )..where((row) => row.id.equals(record.id))).write(
        SourceRecordsCompanion(
          presence: Value(presence),
          lastObservedAt: Value(now),
        ),
      );
    }
  }
}
