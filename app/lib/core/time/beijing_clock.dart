abstract interface class BeijingClock {
  DateTime now();
}

class SystemBeijingClock implements BeijingClock {
  const SystemBeijingClock();

  @override
  DateTime now() {
    final shifted = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }
}

class FixedBeijingClock implements BeijingClock {
  const FixedBeijingClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
