import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';

void main() {
  group('stored event locator', () {
    test('round-trips event_v1', () {
      const locator = StoredEventLocator(eventId: 'evt_123');
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, startsWith('event_v1.'));
      expect(decodeCalendarEventLocator(encoded), locator);
    });

    test('does not leak the literal event id in the encoded form', () {
      const locator = StoredEventLocator(eventId: 'evt_123');
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, isNot(contains('evt_123')));
    });
  });

  group('recurring occurrence locator', () {
    test('round-trips occ_v1', () {
      final locator = RecurringOccurrenceLocator(
        seriesId: 'series/with:separator',
        occurrenceKey: 'series/with:separator@2026-09-01T09:45:00',
      );
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, startsWith('occ_v1.'));
      expect(decodeCalendarEventLocator(encoded), locator);
    });

    test('contains neither the literal series id nor the occurrence key', () {
      final locator = RecurringOccurrenceLocator(
        seriesId: 'series/with:separator',
        occurrenceKey: 'series/with:separator@2026-09-01T09:45:00',
      );
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, isNot(contains(locator.seriesId)));
      expect(encoded, isNot(contains(locator.occurrenceKey)));
      // The atomic "@" separator must not surface in the encoded form either.
      expect(encoded, isNot(contains('@')));
    });

    test('survives a Unicode title in the occurrence key without affecting '
        'round-trip identity', () {
      const seriesId = 'series 课程';
      const key = 'series 课程@2026-09-01T09:45:00';
      final locator = RecurringOccurrenceLocator(
        seriesId: seriesId,
        occurrenceKey: key,
      );
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, isNot(contains(seriesId)));
      expect(decodeCalendarEventLocator(encoded), locator);
    });
  });

  group('recurring series locator', () {
    test('round-trips series_v1', () {
      const locator = RecurringSeriesLocator(seriesId: 'series_42');
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, startsWith('series_v1.'));
      expect(decodeCalendarEventLocator(encoded), locator);
    });

    test('does not leak the literal series id', () {
      const locator = RecurringSeriesLocator(seriesId: 'series_42');
      final encoded = encodeCalendarEventLocator(locator);
      expect(encoded, isNot(contains('series_42')));
    });
  });

  group('source-id separator safety', () {
    test('@ : and / inside source identifiers round-trip because the whole '
        'string is base64url-encoded', () {
      final sourceIds = [
        'series/with:separator',
        '@',
        ':',
        '/',
        'a/b:c@d',
      ];
      for (final seriesId in sourceIds) {
        final occurrence = RecurringOccurrenceLocator(
          seriesId: seriesId,
          occurrenceKey: '$seriesId@2026-09-01T09:45:00',
        );
        final byOccurrence = encodeCalendarEventLocator(occurrence);
        expect(decodeCalendarEventLocator(byOccurrence), occurrence);
        final series = RecurringSeriesLocator(seriesId: seriesId);
        final bySeries = encodeCalendarEventLocator(series);
        expect(decodeCalendarEventLocator(bySeries), series);
      }
    });
  });

  group('rejection', () {
    test('rejects malformed base64url components', () {
      expect(
        () => decodeCalendarEventLocator('event_v1.%%%not-base64%%%'),
        throwsFormatException,
      );
    });

    test('rejects an unknown locator version', () {
      expect(
        () => decodeCalendarEventLocator('event_v9.abc'),
        throwsFormatException,
      );
    });

    test('rejects an empty decoded component', () {
      // base64Url('') == '' so this decodes to an empty id.
      expect(
        () => decodeCalendarEventLocator('event_v1.'),
        throwsFormatException,
      );
    });

    test('rejects a wrong component count', () {
      expect(
        () => decodeCalendarEventLocator('event_v1.a.b'),
        throwsFormatException,
      );
      expect(
        () => decodeCalendarEventLocator('occ_v1.a'),
        throwsFormatException,
      );
      // Unknown prefix with a plausible count is still rejected.
      expect(
        () => decodeCalendarEventLocator('occ_v1.a.b.c'),
        throwsFormatException,
      );
    });

    test('throws FormatException(invalid_event_locator) for empty input', () {
      expect(
        () => decodeCalendarEventLocator(''),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'invalid_event_locator',
          ),
        ),
      );
    });

    test('rejects a truncated component prefix', () {
      expect(
        () => decodeCalendarEventLocator('event'),
        throwsFormatException,
      );
      expect(
        () => decodeCalendarEventLocator('event_v1'),
        throwsFormatException,
      );
    });
  });
}