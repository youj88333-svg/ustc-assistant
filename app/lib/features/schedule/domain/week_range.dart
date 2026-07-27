class WeekRange {
  WeekRange._(this.days);

  factory WeekRange.forDate(DateTime beijingDate) {
    final date = DateTime(beijingDate.year, beijingDate.month, beijingDate.day);
    final monday = date.subtract(Duration(days: date.weekday - 1));
    return WeekRange._(
      List.unmodifiable(
        List.generate(7, (index) => monday.add(Duration(days: index))),
      ),
    );
  }

  final List<DateTime> days;

  DateTime get start => days.first;
  DateTime get endExclusive => days.last.add(const Duration(days: 1));

  bool contains(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    return !date.isBefore(start) && date.isBefore(endExclusive);
  }
}
