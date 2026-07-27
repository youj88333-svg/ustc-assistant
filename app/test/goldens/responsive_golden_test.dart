import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/chat/presentation/chat_shell_page.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';

void main() {
  for (final viewport in const {
    'windows-1440x900': Size(1440, 900),
    'phone-390x844': Size(390, 844),
    'phone-412x915': Size(412, 915),
  }.entries) {
    testWidgets('chat shell ${viewport.key}', (tester) async {
      tester.view.physicalSize = viewport.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ChatShellPage())),
      );
      await expectLater(
        find.byType(ChatShellPage),
        matchesGoldenFile('chat-${viewport.key}.png'),
      );
    });

    testWidgets('seven day week ${viewport.key}', (tester) async {
      tester.view.physicalSize = viewport.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sunday = EffectiveEvent.timed(
        id: 'sunday',
        title: 'Sunday event',
        location: 'West Campus',
        startAt: DateTime(2026, 7, 26, 9, 45),
        endAt: DateTime(2026, 7, 26, 11, 20),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekTimetable(
              projection: buildWeek(
                ScheduleQuery(
                  selectedDate: DateTime(2026, 7, 20),
                  events: [sunday],
                ),
              ),
              onEventSelected: (_) {},
            ),
          ),
        ),
      );
      if (viewport.value.width < 600) {
        await tester.drag(
          find.byKey(const Key('week-horizontal-scroll')),
          const Offset(-900, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('周日').hitTestable(), findsOneWidget);
        expect(find.text('Sunday event').hitTestable(), findsOneWidget);
      }
      await expectLater(
        find.byType(WeekTimetable),
        matchesGoldenFile('week-${viewport.key}.png'),
      );
    });
  }
}
