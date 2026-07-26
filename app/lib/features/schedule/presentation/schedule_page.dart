import 'package:flutter/material.dart';

import '../../tasks/presentation/task_center_page.dart';
import '../domain/schedule_projection.dart';
import 'week_timetable.dart';

enum ScheduleSection { week, tasks }

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage>
    with AutomaticKeepAliveClientMixin {
  ScheduleSection selected = ScheduleSection.week;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<ScheduleSection>(
            segments: const [
              ButtonSegment(
                value: ScheduleSection.week,
                icon: Icon(Icons.calendar_view_week),
                label: Text('周视图'),
              ),
              ButtonSegment(
                value: ScheduleSection.tasks,
                icon: Icon(Icons.task_alt),
                label: Text('任务'),
              ),
            ],
            selected: {selected},
            onSelectionChanged: (selection) {
              setState(() => selected = selection.single);
            },
          ),
        ),
        Expanded(
          child: switch (selected) {
            ScheduleSection.week => WeekTimetable(
              projection: buildWeek(
                ScheduleQuery(
                  selectedDate: DateTime.now(),
                  events: const [],
                ),
              ),
              onEventSelected: (_) {},
            ),
            ScheduleSection.tasks => const TaskCenterPage(),
          },
        ),
      ],
    );
  }
}
