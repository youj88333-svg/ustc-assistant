import 'calendar_contract.dart';

bool isCalendarDate(DateTime value) =>
    value.isUtc &&
    value.year >= 1 &&
    value.year <= 9998 &&
    value.hour == 0 &&
    value.minute == 0 &&
    value.second == 0 &&
    value.millisecond == 0 &&
    value.microsecond == 0;

void validateCalendarQuery(CalendarQuery query) {
  final days = query.endDayExclusive.difference(query.firstDay).inDays;
  if (!isCalendarDate(query.firstDay) ||
      !isCalendarDate(query.endDayExclusive) ||
      days < 1 ||
      days > 62 ||
      query.limit < 1 ||
      query.limit > 500) {
    throw const CalendarFailure(CalendarFailureCode.invalidInput);
  }
}

void validatePersonalDraft(PersonalEventDraft draft) {
  if (draft.title.trim().isEmpty ||
      draft.title.length > 200 ||
      draft.location.length > 200 ||
      draft.note.length > 4000 ||
      [
        draft.title,
        draft.location,
        draft.note,
      ].any((v) => v.contains('\u0000')) ||
      !draft.start.isUtc ||
      !draft.end.isUtc ||
      draft.start.year < 1 ||
      draft.start.year > 9998 ||
      draft.end.year < 1 ||
      draft.end.year > 9998 ||
      !draft.end.isAfter(draft.start) ||
      draft.end.difference(draft.start) > const Duration(days: 366) ||
      (draft.allDay &&
          (!isCalendarDate(draft.start) || !isCalendarDate(draft.end))) ||
      (!draft.weekly && draft.untilDay != null) ||
      (draft.untilDay != null &&
          (!isCalendarDate(draft.untilDay!) ||
              draft.untilDay!.isBefore(draft.anchorDay)))) {
    throw const CalendarFailure(CalendarFailureCode.invalidInput);
  }
}

void validateCalendarIdentity(CalendarIdentity identity) {
  if (identity.localId <= 0 ||
      identity.ordinal < 0 ||
      identity.ordinal > 521700 ||
      (identity.kind != CalendarKind.personal && identity.ordinal != 0)) {
    throw const CalendarFailure(CalendarFailureCode.invalidInput);
  }
}
