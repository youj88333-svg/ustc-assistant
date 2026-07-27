class ReminderDefaults {
  const ReminderDefaults._();

  static List<int> forEvent(String eventType, {bool allDay = false}) {
    if (allDay) return const [];
    return switch (eventType) {
      'exam' => const [1440, 120],
      'second_class' => const [120],
      'course' ||
      'personal' ||
      'entertainment' ||
      'meal' ||
      'campus_affair' ||
      'travel' ||
      'study' => const [15],
      _ => const [],
    };
  }

  static List<int> forTask() => const [1440, 120];

  static List<int> forPlanBlock() => const [10];
}
