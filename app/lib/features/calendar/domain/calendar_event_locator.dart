import 'dart:convert';

/// A reversible, versioned, opaque-locally identity for a calendar entity.
///
/// Locators are the LOCAL implementation identity handed from the app to the
/// model-facing layers (e.g. bound into [`RunReferenceStore`](../agent/application/run_reference_store.dart)
/// as the `localId` for a `ref_*` token). Because every identity component is
/// UTF-8 + unpadded base64url encoded, no literal `seriesId`, `occurrenceKey`,
/// `eventId` or account/source id ever appears in the encoded form — the
/// encoding is reversible but not human-readable, and separator chars such as
/// `@`, `:`, and `/` inside source ids are naturally safe.
///
/// The format is explicit and versioned so it can evolve without ambiguity:
///
/// ```text
/// event_v1.<base64url(eventId)>
/// occ_v1.<base64url(seriesId)>.<base64url(occurrenceKey)>
/// series_v1.<base64url(seriesId)>
/// ```
sealed class CalendarEventLocator {
  const CalendarEventLocator();
}

/// Locates a single, stored (non-recurring) calendar event by its DB event id.
final class StoredEventLocator extends CalendarEventLocator {
  const StoredEventLocator({required this.eventId});

  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is StoredEventLocator && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(StoredEventLocator, eventId);

  @override
  String toString() => 'StoredEventLocator(${_mask(eventId)})';
}

/// Locates one concrete occurrence of a recurring series by [seriesId] plus an
/// [occurrenceKey] (an occurrence-anchored discriminator, e.g. the original
/// start time). The occurrence is NOT materialized as a stored event; its
/// identity is fully derived from this pair via the recurrence projection.
final class RecurringOccurrenceLocator extends CalendarEventLocator {
  const RecurringOccurrenceLocator({
    required this.seriesId,
    required this.occurrenceKey,
  });

  final String seriesId;

  final String occurrenceKey;

  @override
  bool operator ==(Object other) =>
      other is RecurringOccurrenceLocator &&
      other.seriesId == seriesId &&
      other.occurrenceKey == occurrenceKey;

  @override
  int get hashCode => Object.hash(RecurringOccurrenceLocator, seriesId, occurrenceKey);

  @override
  String toString() =>
      'RecurringOccurrenceLocator(${_mask(seriesId)}, ${_mask(occurrenceKey)})';
}

/// Locates a whole recurring series by its [seriesId].
final class RecurringSeriesLocator extends CalendarEventLocator {
  const RecurringSeriesLocator({required this.seriesId});

  final String seriesId;

  @override
  bool operator ==(Object other) =>
      other is RecurringSeriesLocator && other.seriesId == seriesId;

  @override
  int get hashCode => Object.hash(RecurringSeriesLocator, seriesId);

  @override
  String toString() => 'RecurringSeriesLocator(${_mask(seriesId)})';
}

/// Encodes [locator] into its versioned string form (UTF-8 + unpadded base64url
/// components). The result is reversible via [decodeCalendarEventLocator] and
/// contains no literal identity component.
String encodeCalendarEventLocator(CalendarEventLocator locator) {
  return switch (locator) {
    StoredEventLocator(:final eventId) => 'event_v1.${_enc(eventId)}',
    RecurringOccurrenceLocator(:final seriesId, :final occurrenceKey) =>
      'occ_v1.${_enc(seriesId)}.${_enc(occurrenceKey)}',
    RecurringSeriesLocator(:final seriesId) => 'series_v1.${_enc(seriesId)}',
  };
}

/// Decodes a versioned locator string back into a [CalendarEventLocator].
///
/// The decoder requires the exact component count for each version and rejects
/// any empty decoded identity component. On any malformed input it throws a
/// [FormatException] carrying `'invalid_event_locator'`.
CalendarEventLocator decodeCalendarEventLocator(String value) {
  if (value.isEmpty) {
    throw const FormatException('invalid_event_locator');
  }

  final parts = value.split('.');
  final version = parts.first;

  switch (version) {
    case 'event_v1':
      _requireComponentCount(parts, expected: 2);
      return StoredEventLocator(eventId: _dec(parts[1]));
    case 'occ_v1':
      _requireComponentCount(parts, expected: 3);
      return RecurringOccurrenceLocator(
        seriesId: _dec(parts[1]),
        occurrenceKey: _dec(parts[2]),
      );
    case 'series_v1':
      _requireComponentCount(parts, expected: 2);
      return RecurringSeriesLocator(seriesId: _dec(parts[1]));
    default:
      // Unknown version / locator family.
      throw const FormatException('invalid_event_locator');
  }
}

void _requireComponentCount(List<String> parts, {required int expected}) {
  if (parts.length != expected) {
    throw const FormatException('invalid_event_locator');
  }
}

/// UTF-8 encodes [text] then base64url-encodes without padding.
String _enc(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

/// Unpadded-base64url-decodes back to text, re-adding padding as required.
String _dec(String component) {
  var padded = component;
  switch (component.length % 4) {
    case 2:
      padded = '$component==';
    case 3:
      padded = '$component=';
  }
  final decoded = base64Url.decode(padded);
  final text = utf8.decode(decoded);
  if (text.isEmpty) {
    throw const FormatException('invalid_event_locator');
  }
  return text;
}

/// Masks identity components inside debug strings so accidental logs never leak
/// a raw series/event id or occurrence key.
String _mask(String value) {
  if (value.length <= 4) return '***';
  return '...${value.substring(value.length - 4)}';
}