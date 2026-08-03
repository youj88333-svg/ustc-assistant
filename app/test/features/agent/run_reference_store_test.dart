import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';

void main() {
  group('RunReferenceStore with encoded occurrence locators', () {
    final locator = RecurringOccurrenceLocator(
      seriesId: 'series/with:separator',
      occurrenceKey: 'series/with:separator@2026-09-01T09:45:00',
    );
    final encodedLocator = encodeCalendarEventLocator(locator);

    test('binding is idempotent under kind event', () {
      final store = RunReferenceStore(runId: 'r1');
      final ref1 = store.bind(kind: 'event', localId: encodedLocator);
      final ref2 = store.bind(kind: 'event', localId: encodedLocator);
      expect(ref1, ref2);
      expect(store.resolve(ref: ref1, kind: 'event'), encodedLocator);
    });

    test('kinds are isolated', () {
      final store = RunReferenceStore(runId: 'r1');
      final ref = store.bind(kind: 'event', localId: encodedLocator);
      expect(store.resolve(ref: ref, kind: 'event'), encodedLocator);
      expect(store.resolve(ref: ref, kind: 'task'), isNull);
      expect(store.resolve(ref: ref, kind: 'schedule'), isNull);
    });

    test('cross-run expiry invalidates the ref', () {
      final storeA = RunReferenceStore(runId: 'a');
      final storeB = RunReferenceStore(runId: 'b');
      final ref = storeA.bind(kind: 'event', localId: encodedLocator);
      expect(storeA.resolve(ref: ref, kind: 'event'), encodedLocator);
      expect(storeB.resolve(ref: ref, kind: 'event'), isNull);
    });

    test('the generated ref hides the encoded locator and its source '
        'identifiers', () {
      final store = RunReferenceStore(runId: 'r1');
      final ref = store.bind(kind: 'event', localId: encodedLocator);

      expect(ref, startsWith('ref_'));
      expect(ref, isNot(contains(encodedLocator)));
      expect(ref, isNot(contains(locator.seriesId)));
      expect(ref, isNot(contains(locator.occurrenceKey)));
    });
  });

  group('RunReferenceStore reserves the opaque ref pattern', () {
    test('a bound ref never equals the encoded locator', () {
      final store = RunReferenceStore(runId: 'r1');
      final ref = store.bind(
        kind: 'event',
        localId: encodeCalendarEventLocator(
          const StoredEventLocator(eventId: 'evt_1'),
        ),
      );
      expect(ref, isNot(equals('ref_')));
      expect(ref.length, greaterThan('ref_'.length));
    });
  });
}