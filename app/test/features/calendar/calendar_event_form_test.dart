import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/presentation/calendar_event_form.dart';

Widget fixture(
  Future<void> Function(CalendarEventSubmission) onSubmit, {
  DateTime? start,
  DateTime? end,
}) => MaterialApp(
  home: Scaffold(
    body: CalendarEventForm(
      initialStart: start ?? DateTime(2026, 7, 27, 9),
      initialEnd: end ?? DateTime(2026, 7, 27, 10),
      onSubmit: onSubmit,
    ),
  ),
);

void main() {
  testWidgets('form creates timed event with default completion policy', (
    tester,
  ) async {
    CalendarEventSubmission? submission;
    await tester.pumpWidget(fixture((value) async => submission = value));
    await tester.enterText(find.byKey(const Key('event-title')), '写作业');
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-event')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('save-event')));
    await tester.pump();

    expect(submission?.event.allDay, isFalse);
    expect(submission?.event.completionPolicy, CompletionPolicy.autoAfterEnd);
    expect(submission?.reminderOffsetsMinutes, [15]);
  });

  testWidgets('all-day toggle uses an exclusive next-day end', (tester) async {
    CalendarEventSubmission? submission;
    await tester.pumpWidget(fixture((value) async => submission = value));
    await tester.enterText(find.byKey(const Key('event-title')), '全天事项');
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-event')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('save-event')));
    await tester.pump();

    expect(submission?.event.allDay, isTrue);
    expect(
      submission?.event.endDateExclusive,
      submission?.event.startDate?.add(const Duration(days: 1)),
    );
    expect(submission?.reminderOffsetsMinutes, isEmpty);
  });

  testWidgets('empty title stays in form with validation message', (
    tester,
  ) async {
    await tester.pumpWidget(fixture((_) async {}));
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-event')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('save-event')));
    await tester.pump();

    expect(find.byKey(const Key('event-validation-error')), findsOneWidget);
  });
}
