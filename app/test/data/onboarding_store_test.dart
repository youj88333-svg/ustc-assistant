import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/onboarding_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  test(
    'fresh setup can defer and resume across restart, independent of display settings',
    () async {
      final file = await _file();
      var store = await _open(file: file);
      var setup = await store.onboarding.inspect();
      expect(setup.status, OnboardingStatus.active);
      expect(setup.step, OnboardingStep.account);
      setup = await store.onboarding.save(
        setup.context,
        status: OnboardingStatus.deferred,
        step: OnboardingStep.model,
      );
      await store.close();
      store = await _open(file: file);
      final resumed = await store.onboarding.inspect();
      expect(resumed.context, setup.context);
      expect(resumed.status, OnboardingStatus.deferred);
      expect(resumed.step, OnboardingStep.model);
      final settings = await store.applicationSettings.inspectSettings();
      await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: 'preferences-${List.filled(32, 'a').join()}',
          context: settings.context,
          preferences: const DisplayPreferences(
            calendarView: DefaultCalendarView.day,
          ),
        ),
      );
      final done = await store.onboarding.save(
        resumed.context,
        status: OnboardingStatus.done,
        step: OnboardingStep.permissions,
      );
      expect(done.context.revision, setup.context.revision + 1);
      expect(
        (await store.applicationSettings.inspectSettings())
            .preferences
            .calendarView,
        DefaultCalendarView.day,
      );
    },
  );

  test(
    'schema19 upgrade preserves data and opts existing installation out of forced guide',
    () async {
      final file = await _file();
      var store = await _open(file: file);
      final settings = await store.applicationSettings.inspectSettings();
      await store.applicationSettings.savePreferences(
        PreferencesWrite(
          operationId: 'preferences-${List.filled(32, 'b').join()}',
          context: settings.context,
          preferences: const DisplayPreferences(
            calendarView: DefaultCalendarView.day,
            includeInactive: true,
          ),
        ),
      );
      final context = (await store.localCalendar.query(
        CalendarQuery(
          firstDay: DateTime.utc(2026, 10, 25),
          endDayExclusive: DateTime.utc(2026, 10, 26),
        ),
      )).context;
      final prepared = await store.localCalendar.prepare(
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成升级保留',
            start: DateTime.utc(2026, 10, 25, 1),
            end: DateTime.utc(2026, 10, 25, 2),
          ),
        ),
      );
      await store.localCalendar.commit(prepared);
      await store.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE onboarding_state');
      raw.execute('PRAGMA user_version=19');
      raw.close();
      store = await _open(file: file);
      expect((await store.onboarding.inspect()).status, OnboardingStatus.done);
      final migrated = await store.applicationSettings.inspectSettings();
      expect(migrated.preferences.includeInactive, isTrue);
      expect(migrated.preferences.calendarView, DefaultCalendarView.day);
      expect(migrated.counts.personal, 1);
    },
  );

  test(
    'late migration collision rolls back and can retry without losing old settings',
    () async {
      final file = await _file();
      final store = await _open(file: file);
      await store.close();
      var raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE onboarding_state');
      raw.execute('PRAGMA user_version=19');
      raw.execute('CREATE TABLE onboarding_state(sentinel TEXT)');
      raw.execute("INSERT INTO onboarding_state VALUES('owned-synthetic')");
      raw.close();
      await expectLater(_open(file: file), throwsA(isA<AppFailure>()));
      raw = sqlite.sqlite3.open(file.path);
      expect(raw.select('PRAGMA user_version').single['user_version'], 19);
      expect(
        raw.select('SELECT * FROM onboarding_state').single['sentinel'],
        'owned-synthetic',
      );
      expect(
        raw.select('SELECT revision FROM app_settings').single['revision'],
        1,
      );
      raw.execute('DROP TABLE onboarding_state');
      raw.close();
      final retried = await _open(file: file);
      expect(
        (await retried.onboarding.inspect()).status,
        OnboardingStatus.done,
      );
    },
  );

  test(
    'concurrent stale navigation is rejected, clear agenda preserves, reset restarts',
    () async {
      final store = await _open();
      final initial = await store.onboarding.inspect();
      final first = store.onboarding.save(
        initial.context,
        status: OnboardingStatus.deferred,
        step: OnboardingStep.model,
      );
      final stale = store.onboarding.save(
        initial.context,
        status: OnboardingStatus.done,
        step: OnboardingStep.permissions,
      );
      await expectLater(stale, _failure(FailureCode.staleResult));
      final saved = await first;
      await _maintenance(store, MaintenanceKind.agenda);
      expect((await store.onboarding.inspect()).context, saved.context);
      await _maintenance(store, MaintenanceKind.reset);
      final reset = await store.onboarding.inspect();
      expect(reset.status, OnboardingStatus.active);
      expect(reset.step, OnboardingStep.account);
      expect(reset.context.resetEpoch, saved.context.resetEpoch + 1);
      await expectLater(
        store.onboarding.save(
          saved.context,
          status: OnboardingStatus.done,
          step: OnboardingStep.permissions,
        ),
        _failure(FailureCode.staleResult),
      );
    },
  );

  test(
    'maintenance failure keeps old progress and barrier; retry resets exactly once',
    () async {
      var fail = false;
      final store = await _open(
        checkpoint: () async {
          if (fail) throw StateError('synthetic rollback');
        },
      );
      final initial = await store.onboarding.inspect();
      await store.onboarding.save(
        initial.context,
        status: OnboardingStatus.done,
        step: OnboardingStep.permissions,
      );
      final settings = await store.applicationSettings.inspectSettings();
      final request = await store.applicationSettings.prepareMaintenance(
        settings.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      final intent = await store.applicationSettings.beginMaintenance(request);
      await expectLater(
        store.onboarding.inspect(),
        _failure(FailureCode.cleanupPending),
      );
      fail = true;
      await expectLater(
        store.applicationSettings.completeMaintenance(intent),
        throwsA(isA<SettingsFailure>()),
      );
      expect(
        (await store
                .customSelect('SELECT status FROM onboarding_state')
                .getSingle())
            .read<String>('status'),
        'done',
      );
      fail = false;
      await store.applicationSettings.completeMaintenance(intent);
      final reset = await store.onboarding.inspect();
      await store.applicationSettings.completeMaintenance(intent);
      expect((await store.onboarding.inspect()).context, reset.context);
    },
  );

  test(
    'lost owner and corrupt navigation fail without replacing existing state',
    () async {
      final owner = _Owner();
      final store = await _open(owner: owner);
      final initial = await store.onboarding.inspect();
      owner.held = false;
      await expectLater(
        store.onboarding.save(
          initial.context,
          status: OnboardingStatus.done,
          step: OnboardingStep.permissions,
        ),
        _failure(FailureCode.ownershipLost),
      );
      owner.held = true;
      await store.customStatement('PRAGMA ignore_check_constraints=ON');
      await store.customStatement(
        "UPDATE onboarding_state SET status='future' WHERE singleton=1",
      );
      await expectLater(
        store.onboarding.inspect(),
        _failure(FailureCode.storageFailed),
      );
    },
  );
}

Matcher _failure(FailureCode code) =>
    throwsA(isA<AppFailure>().having((e) => e.code, 'code', code));

Future<void> _maintenance(JwStore store, MaintenanceKind kind) async {
  final settings = await store.applicationSettings.inspectSettings();
  final request = await store.applicationSettings.prepareMaintenance(
    settings.context,
    kind,
    confirmed: true,
  );
  await store.applicationSettings.completeMaintenance(
    await store.applicationSettings.beginMaintenance(request),
  );
}

Future<File> _file() async {
  final directory = await Directory.systemTemp.createTemp(
    'onboarding-synthetic-',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return File('${directory.path}/synthetic.sqlite');
}

Future<JwStore> _open({
  File? file,
  _Owner? owner,
  Future<void> Function()? checkpoint,
}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: owner ?? _Owner(),
    clock: FixedClock(DateTime.utc(2026, 10, 25)),
    onSettingsCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  try {
    await store.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  return store;
}

final class _Owner implements AssetOwnership {
  bool held = true;
  @override
  bool get isHeld => held;
  @override
  void ensureHeld() {
    if (!held) throw const AppFailure(FailureCode.ownershipLost);
  }
}
