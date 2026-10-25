import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/calendar_teaching_axis.dart';

void main() {
  test('contains the thirteen official teaching periods', () {
    expect(
      ustcTeachingPeriods
          .map(
            (period) => (period.number, period.startMinute, period.endMinute),
          )
          .toList(),
      const [
        (1, 470, 515),
        (2, 520, 565),
        (3, 585, 630),
        (4, 635, 680),
        (5, 685, 730),
        (6, 840, 885),
        (7, 890, 935),
        (8, 955, 1000),
        (9, 1005, 1050),
        (10, 1055, 1100),
        (11, 1170, 1215),
        (12, 1220, 1265),
        (13, 1270, 1315),
      ],
    );
  });

  test('bands cover 07:00 through midnight without gaps or jumps', () {
    final axis = CalendarTeachingAxis.fit(500);

    expect(axis.bands.first.startMinute, 420);
    expect(axis.bands.last.endMinute, 1440);
    expect(axis.bands.first.top, 0);
    expect(
      axis.bands.last.top + axis.bands.last.height,
      closeTo(axis.height, 1e-9),
    );

    for (var index = 0; index < axis.bands.length; index++) {
      final band = axis.bands[index];
      expect(axis.y(band.startMinute.toDouble()), closeTo(band.top, 1e-8));
      expect(
        axis.y(band.endMinute.toDouble()),
        closeTo(band.top + band.height, 1e-8),
      );
      if (index == 0) continue;

      final previous = axis.bands[index - 1];
      expect(band.startMinute, previous.endMinute);
      expect(band.top, closeTo(previous.top + previous.height, 1e-8));
      expect(
        axis.y(band.startMinute.toDouble()),
        closeTo(axis.y(previous.endMinute.toDouble()), 1e-8),
      );
    }

    final teachingBands = axis.bands.where((band) => band.period != null);
    expect(teachingBands, hasLength(13));
    for (final period in ustcTeachingPeriods) {
      final band = teachingBands.singleWhere(
        (candidate) => candidate.period == period.number,
      );
      expect(band.startMinute, period.startMinute);
      expect(band.endMinute, period.endMinute);
      expect(band.label, '第${period.number}节');
    }
  });

  test('preserves 07:00 and 24:00 endpoints and clamps outside the axis', () {
    final axis = CalendarTeachingAxis.fit(500);

    expect(axis.y(420), 0);
    expect(axis.y(0), 0);
    expect(axis.y(1440), axis.height);
    expect(axis.y(1500), axis.height);
    expect(() => axis.y(double.nan), throwsArgumentError);
    expect(() => axis.y(double.infinity), throwsArgumentError);
  });

  test('maps arbitrary clock times and compresses the known rests', () {
    final axis = CalendarTeachingAxis.fit(500);
    final firstPeriod = _periodBand(axis, 1);
    final fiveMinuteBreak = _gapBand(axis, 515, 520);
    final twentyMinuteBreak = _gapBand(axis, 565, 585);
    final lunch = _gapBand(axis, 730, 840);

    expect(axis.y(510), greaterThan(axis.y(470)));
    expect(axis.y(510), lessThan(axis.y(515)));
    expect(
      axis.y(510.5),
      closeTo(axis.y(470) + firstPeriod.height * (40.5 / 45), 1e-8),
    );
    expect(fiveMinuteBreak.label, '课间');
    expect(twentyMinuteBreak.label, '课间');
    expect(lunch.label, '午休');
    expect(fiveMinuteBreak.height / firstPeriod.height, closeTo(0.10, 1e-9));
    expect(twentyMinuteBreak.height / firstPeriod.height, closeTo(0.25, 1e-9));
    expect(lunch.height / firstPeriod.height, closeTo(0.65, 1e-9));
    expect(axis.y(517.5), closeTo((axis.y(515) + axis.y(520)) / 2, 1e-8));
    expect(axis.y(575), closeTo((axis.y(565) + axis.y(585)) / 2, 1e-8));
    expect(axis.y(790), greaterThan(axis.y(730)));
    expect(axis.y(790), lessThan(axis.y(840)));
  });

  test('keeps a cross-midnight main-grid segment bounded at 24:00', () {
    final axis = CalendarTeachingAxis.fit(500);

    // The day segment of an overnight event ends at midnight; its next-day
    // portion belongs to the separate early-morning strip.
    expect(axis.y(23 * 60 + 30), lessThan(axis.y(1440)));
    expect(axis.y(1440), axis.height);
    expect(axis.y(24 * 60 + 30), axis.height);
  });

  test(
    'fits a typical viewport and raises the minimum for short or large text',
    () {
      final viewportAxis = CalendarTeachingAxis.fit(500);
      final shortAxis = CalendarTeachingAxis.fit(200);
      final largeTextAxis = CalendarTeachingAxis.fit(500, textScale: 2);
      final zeroHeightAxis = CalendarTeachingAxis.fit(0);
      final negativeHeightAxis = CalendarTeachingAxis.fit(-20);

      expect(viewportAxis.height, 500);
      expect(_periodBand(viewportAxis, 1).height, greaterThan(24));
      expect(shortAxis.height, greaterThan(200));
      expect(_periodBand(shortAxis, 1).height, closeTo(24, 1e-8));
      expect(largeTextAxis.height, greaterThan(500));
      expect(_periodBand(largeTextAxis, 1).height, closeTo(48, 1e-8));
      expect(zeroHeightAxis.height, greaterThan(0));
      expect(negativeHeightAxis.height, zeroHeightAxis.height);
    },
  );

  test('rejects non-finite dimensions and invalid text scales', () {
    expect(() => CalendarTeachingAxis.fit(double.nan), throwsArgumentError);
    expect(
      () => CalendarTeachingAxis.fit(double.infinity),
      throwsArgumentError,
    );
    expect(
      () => CalendarTeachingAxis.fit(500, textScale: 0),
      throwsArgumentError,
    );
    expect(
      () => CalendarTeachingAxis.fit(500, textScale: double.negativeInfinity),
      throwsArgumentError,
    );
  });

  test('exposes an immutable band list', () {
    final axis = CalendarTeachingAxis.fit(500);

    expect(() => axis.bands.add(axis.bands.first), throwsUnsupportedError);
  });
}

TeachingAxisBand _periodBand(CalendarTeachingAxis axis, int number) =>
    axis.bands.singleWhere((band) => band.period == number);

TeachingAxisBand _gapBand(CalendarTeachingAxis axis, int start, int end) => axis
    .bands
    .singleWhere((band) => band.startMinute == start && band.endMinute == end);
