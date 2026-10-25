import 'package:flutter/painting.dart';

/// The event colors used by every calendar presentation of the same title.
final class CalendarEventColors {
  const CalendarEventColors({
    required this.fill,
    required this.ink,
    required this.edge,
  });

  final Color fill;
  final Color ink;
  final Color edge;
  @override
  bool operator ==(Object other) =>
      other is CalendarEventColors &&
      other.fill == fill &&
      other.ink == ink &&
      other.edge == edge;
  @override
  int get hashCode => Object.hash(fill, ink, edge);
}

/// Canonicalizes a title before it is used as a display color key.
String normalizeCalendarTitle(String title) =>
    title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Returns a stable, title-derived color set for a calendar event.
///
/// The hash is deliberately local and explicit. It does not depend on Dart's
/// process-dependent [Object.hashCode], event identity, source, or query order.
CalendarEventColors calendarColorsForTitle(String title) {
  final hash = _stableTitleHash(normalizeCalendarTitle(title));
  final hue = (hash % 360) + _hashFraction(hash, 360);
  final fillSaturation = 0.28 + _hashFraction(hash, 360) * 0.12;
  final fillLightness = 0.92 + _hashFraction(hash, 360000) * 0.03;
  final inkSaturation = 0.68 + _hashFraction(hash, 360000000) * 0.10;
  final inkLightness = 0.18 + _hashFraction(hash, 1000000) * 0.04;
  final edgeSaturation = 0.65 + _hashFraction(hash, 10000000) * 0.10;
  final edgeLightness = 0.22 + _hashFraction(hash, 100000) * 0.03;

  return CalendarEventColors(
    fill: HSLColor.fromAHSL(1, hue, fillSaturation, fillLightness).toColor(),
    ink: HSLColor.fromAHSL(1, hue, inkSaturation, inkLightness).toColor(),
    edge: HSLColor.fromAHSL(1, hue, edgeSaturation, edgeLightness).toColor(),
  );
}

double _hashFraction(int hash, int divisor) =>
    ((hash ~/ divisor) % 1000) / 1000;

int _stableTitleHash(String normalizedTitle) {
  // Keep intermediate values below 2^53 so the arithmetic is stable on both
  // native Dart and JavaScript-backed Flutter runtimes.
  const modulus = 4294967291;
  var hash = 2166136261;
  for (final rune in normalizedTitle.runes) {
    hash = (hash * 65599 + rune) % modulus;
  }
  // Mix the final unit too: names differing only by a trailing digit should
  // not land on adjacent hues or quantize to the same pale fill.
  hash ^= hash >> 16;
  hash = (hash * 65599) % modulus;
  hash ^= hash >> 11;
  return hash;
}
