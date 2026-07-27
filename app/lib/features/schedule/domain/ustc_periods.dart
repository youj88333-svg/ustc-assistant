class UstcPeriod {
  const UstcPeriod(this.number, this.startMinutes, this.endMinutes);

  final int number;
  final int startMinutes;
  final int endMinutes;
}

abstract final class UstcPeriods {
  /// 日网格下界（含），同时是凌晨事项带的上界（不含）。
  /// 0:00 至此之前的事件进入凌晨事项带，不落入日网格。
  static const dayStartMinutes = 7 * 60;
  /// 日网格上界（不含）。至此之前的事件落入日网格。
  static const dayEndMinutes = 24 * 60;

  /// 中科大官方节次时间表（见教务校历）。
  static const values = [
    UstcPeriod(1, 7 * 60 + 50, 8 * 60 + 35),
    UstcPeriod(2, 8 * 60 + 40, 9 * 60 + 25),
    UstcPeriod(3, 9 * 60 + 45, 10 * 60 + 30),
    UstcPeriod(4, 10 * 60 + 35, 11 * 60 + 20),
    UstcPeriod(5, 11 * 60 + 25, 12 * 60 + 10),
    UstcPeriod(6, 14 * 60, 14 * 60 + 45),
    UstcPeriod(7, 14 * 60 + 50, 15 * 60 + 35),
    UstcPeriod(8, 15 * 60 + 55, 16 * 60 + 40),
    UstcPeriod(9, 16 * 60 + 45, 17 * 60 + 30),
    UstcPeriod(10, 17 * 60 + 35, 18 * 60 + 20),
    UstcPeriod(11, 19 * 60 + 30, 20 * 60 + 15),
    UstcPeriod(12, 20 * 60 + 20, 21 * 60 + 5),
    UstcPeriod(13, 21 * 60 + 10, 21 * 60 + 55),
  ];

  static UstcPeriod byNumber(int number) =>
      values.singleWhere((period) => period.number == number);

  /// 日网格分隔线位置：每个节次的起始线，加上 break 不小于 [minBreakMinutes]
  /// 时上一节的结束线。默认 30 分钟只框出午休（12:10-14:00）、晚间间隔
  /// （18:20-19:30）以及末节后到网格底（21:55-24:00）等大空档，
  /// 5/20 分钟课间不画线，避免视觉杂乱。
  static List<int> boundaries({int minBreakMinutes = 30}) {
    final lines = <int>{};
    for (var i = 0; i < values.length; i++) {
      lines.add(values[i].startMinutes);
      final nextStart =
          i + 1 < values.length
          ? values[i + 1].startMinutes
          : dayEndMinutes;
      final gap = nextStart - values[i].endMinutes;
      if (gap >= minBreakMinutes) {
        lines.add(values[i].endMinutes);
      }
    }
    final sorted = lines.toList()..sort();
    return sorted;
  }
}
