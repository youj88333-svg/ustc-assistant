/// A fixed teaching period from the USTC teaching calendar.
final class TeachingPeriod {
  const TeachingPeriod({
    required this.number,
    required this.startMinute,
    required this.endMinute,
  }) : assert(startMinute < endMinute);

  final int number;
  final int startMinute;
  final int endMinute;
}

/// Offline 2026 autumn teaching periods, expressed as minutes after midnight.
const List<TeachingPeriod> ustcTeachingPeriods = <TeachingPeriod>[
  TeachingPeriod(number: 1, startMinute: 470, endMinute: 515),
  TeachingPeriod(number: 2, startMinute: 520, endMinute: 565),
  TeachingPeriod(number: 3, startMinute: 585, endMinute: 630),
  TeachingPeriod(number: 4, startMinute: 635, endMinute: 680),
  TeachingPeriod(number: 5, startMinute: 685, endMinute: 730),
  TeachingPeriod(number: 6, startMinute: 840, endMinute: 885),
  TeachingPeriod(number: 7, startMinute: 890, endMinute: 935),
  TeachingPeriod(number: 8, startMinute: 955, endMinute: 1000),
  TeachingPeriod(number: 9, startMinute: 1005, endMinute: 1050),
  TeachingPeriod(number: 10, startMinute: 1055, endMinute: 1100),
  TeachingPeriod(number: 11, startMinute: 1170, endMinute: 1215),
  TeachingPeriod(number: 12, startMinute: 1220, endMinute: 1265),
  TeachingPeriod(number: 13, startMinute: 1270, endMinute: 1315),
];

/// One linearly mapped band on the compressed teaching-day axis.
final class TeachingAxisBand {
  const TeachingAxisBand({
    required this.startMinute,
    required this.endMinute,
    required this.top,
    required this.height,
    required this.label,
    this.period,
  }) : assert(startMinute < endMinute),
       assert(height >= 0);

  final int startMinute;
  final int endMinute;
  final double top;
  final double height;
  final String label;
  final int? period;
}

/// A 07:00–24:00 display axis with exact, linear interpolation within bands.
///
/// The separate 00:00–07:00 early-morning strip is owned by the UI and is not
/// part of this mapping.
final class CalendarTeachingAxis {
  CalendarTeachingAxis._(this.height, this.bands);

  factory CalendarTeachingAxis.fit(
    double availableHeight, {
    double textScale = 1,
  }) {
    if (!availableHeight.isFinite) {
      throw ArgumentError.value(
        availableHeight,
        'availableHeight',
        'must be finite',
      );
    }
    if (!textScale.isFinite || textScale <= 0) {
      throw ArgumentError.value(
        textScale,
        'textScale',
        'must be finite and positive',
      );
    }

    final specs = _buildBandSpecs();
    final totalWeight = specs.fold<double>(0, (sum, spec) => sum + spec.weight);
    final minimumHeight = totalWeight * _minimumPeriodHeight * textScale;
    if (!minimumHeight.isFinite) {
      throw ArgumentError.value(
        textScale,
        'textScale',
        'produces a non-finite minimum axis height',
      );
    }
    final height = availableHeight > minimumHeight
        ? availableHeight
        : minimumHeight;
    final unitHeight = height / totalWeight;
    var top = 0.0;
    final bands = <TeachingAxisBand>[];
    for (final spec in specs) {
      final bandHeight = unitHeight * spec.weight;
      bands.add(
        TeachingAxisBand(
          startMinute: spec.startMinute,
          endMinute: spec.endMinute,
          top: top,
          height: bandHeight,
          label: spec.label,
          period: spec.period,
        ),
      );
      top += bandHeight;
    }

    return CalendarTeachingAxis._(
      height,
      List<TeachingAxisBand>.unmodifiable(bands),
    );
  }

  static const double _minimumPeriodHeight = 24;

  final double height;
  final List<TeachingAxisBand> bands;

  /// Maps any minute to the axis, clamping only at 07:00 and midnight.
  double y(double minute) {
    if (!minute.isFinite) {
      throw ArgumentError.value(minute, 'minute', 'must be finite');
    }
    if (minute <= _axisStartMinute) return 0;
    if (minute >= _axisEndMinute) return height;

    for (final band in bands) {
      if (minute <= band.endMinute) {
        final fraction =
            (minute - band.startMinute) / (band.endMinute - band.startMinute);
        return band.top + band.height * fraction;
      }
    }
    return height;
  }

  static const double _axisStartMinute = 420;
  static const double _axisEndMinute = 1440;
}

final class _BandSpec {
  const _BandSpec({
    required this.startMinute,
    required this.endMinute,
    required this.weight,
    required this.label,
    this.period,
  });

  final int startMinute;
  final int endMinute;
  final double weight;
  final String label;
  final int? period;
}

List<_BandSpec> _buildBandSpecs() {
  final specs = <_BandSpec>[];
  var cursor = CalendarTeachingAxis._axisStartMinute.toInt();
  for (final period in ustcTeachingPeriods) {
    if (period.startMinute > cursor) {
      specs.add(_gapSpec(cursor, period.startMinute));
    }
    specs.add(
      _BandSpec(
        startMinute: period.startMinute,
        endMinute: period.endMinute,
        weight: 1,
        label: '第${period.number}节',
        period: period.number,
      ),
    );
    cursor = period.endMinute;
  }
  specs.add(_gapSpec(cursor, CalendarTeachingAxis._axisEndMinute.toInt()));
  return List<_BandSpec>.unmodifiable(specs);
}

_BandSpec _gapSpec(int startMinute, int endMinute) {
  final range = (startMinute, endMinute);
  final (weight, label) = switch (range) {
    (420, 470) => (0.50, '早间'),
    (730, 840) => (0.65, '午休'),
    (1100, 1170) => (0.50, '晚间'),
    (1315, 1440) => (0.75, '晚间'),
    _ when endMinute - startMinute == 5 => (0.10, '课间'),
    _ when endMinute - startMinute == 20 => (0.25, '课间'),
    _ => throw StateError('Unexpected gap $startMinute–$endMinute'),
  };
  return _BandSpec(
    startMinute: startMinute,
    endMinute: endMinute,
    weight: weight,
    label: label,
  );
}
