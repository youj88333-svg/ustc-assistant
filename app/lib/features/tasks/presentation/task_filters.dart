import '../domain/task.dart';

enum TaskFilter {
  active('进行中'),
  blocked('受阻'),
  completed('已完成'),
  cancelled('已取消');

  const TaskFilter(this.label);

  final String label;

  TaskState get state => TaskState.values.byName(name);
}

List<TaskItem> filterTasks(Iterable<TaskItem> tasks, TaskFilter filter) => tasks
    .where((task) => task.deletedAt == null && task.state == filter.state)
    .toList(growable: false);

List<TaskItem> undatedBandTasks(Iterable<TaskItem> tasks) => tasks
    .where(
      (task) =>
          task.deletedAt == null &&
          task.deadlineAt == null &&
          (task.state == TaskState.active || task.state == TaskState.blocked),
    )
    .toList(growable: false);

Map<int, List<TaskItem>> datedBandTasks({
  required Iterable<TaskItem> tasks,
  required DateTime weekStart,
  required DateTime now,
  bool hideCompleted = false,
}) {
  final result = <int, List<TaskItem>>{};
  final start = _date(weekStart);
  final end = start.add(const Duration(days: 7));
  final currentWeek = !_date(now).isBefore(start) && _date(now).isBefore(end);
  for (final task in tasks) {
    if (task.deletedAt != null ||
        task.deadlineAt == null ||
        task.state == TaskState.cancelled ||
        (hideCompleted && task.state == TaskState.completed)) {
      continue;
    }
    final deadlineDate = _date(task.deadlineAt!);
    int? weekday;
    if (!deadlineDate.isBefore(start) && deadlineDate.isBefore(end)) {
      weekday = task.deadlineAt!.weekday;
    } else if (currentWeek &&
        deadlineDate.isBefore(_date(now)) &&
        (task.state == TaskState.active || task.state == TaskState.blocked)) {
      weekday = now.weekday;
    }
    if (weekday != null) {
      result.putIfAbsent(weekday, () => []).add(task);
    }
  }
  return result;
}

DateTime _date(DateTime value) => DateTime(value.year, value.month, value.day);
