class UstcPeriod {
  const UstcPeriod(this.number, this.startMinutes, this.endMinutes);

  final int number;
  final int startMinutes;
  final int endMinutes;
}

abstract final class UstcPeriods {
  static const dayStartMinutes = 7 * 60 + 30;
  static const dayEndMinutes = 22 * 60;

  static const values = [
    UstcPeriod(1, 7 * 60 + 50, 8 * 60 + 35),
    UstcPeriod(2, 8 * 60 + 40, 9 * 60 + 25),
    UstcPeriod(3, 9 * 60 + 45, 10 * 60 + 30),
    UstcPeriod(4, 10 * 60 + 35, 11 * 60 + 20),
    UstcPeriod(5, 11 * 60 + 25, 12 * 60 + 10),
    UstcPeriod(6, 13 * 60 + 30, 14 * 60 + 15),
    UstcPeriod(7, 14 * 60 + 20, 15 * 60 + 5),
    UstcPeriod(8, 15 * 60 + 15, 16 * 60),
    UstcPeriod(9, 16 * 60 + 5, 16 * 60 + 50),
    UstcPeriod(10, 18 * 60 + 30, 19 * 60 + 15),
    UstcPeriod(11, 19 * 60 + 20, 20 * 60 + 5),
    UstcPeriod(12, 20 * 60 + 10, 20 * 60 + 55),
    UstcPeriod(13, 21 * 60, 21 * 60 + 45),
  ];

  static UstcPeriod byNumber(int number) =>
      values.singleWhere((period) => period.number == number);
}
