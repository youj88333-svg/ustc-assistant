import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';

void main() {
  test('accepts only the exact versioned academic-details map', () {
    final valid = JwAcademicDetails().toMap();
    expect(JwAcademicDetails.fromMap(valid).toMap(), valid);

    final withUnknownField = JwAcademicDetails().toMap()
      ..['futureField'] = 'opaque';
    final withMissingField = JwAcademicDetails().toMap()
      ..remove('semesterName');
    final withWrongVersion = JwAcademicDetails().toMap()
      ..['version'] = 'jw-academic-details-v0';

    for (final invalid in [
      withUnknownField,
      withMissingField,
      withWrongVersion,
    ]) {
      expect(
        () => JwAcademicDetails.fromMap(invalid),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('keeps nullable observed fields distinct from malformed values', () {
    final empty = JwAcademicDetails.fromMap(JwAcademicDetails().toMap());
    expect(empty.virtual, isNull);
    expect(empty.exerciseClass, isNull);
    expect(empty.lessonId, isNull);
    expect(empty.groupId, isNull);
    expect(empty.weekIndex, isNull);
    expect(empty.weekday, isNull);
    expect(empty.periods, isNull);

    for (final invalid in <(String, Object?)>[
      ('virtual', 'true'),
      ('exerciseClass', 1),
      ('lessonId', 12.0),
      ('weekday', '3'),
      ('periods', false),
      ('campus', 7),
      ('teachers', [1]),
      ('lessonId', 0),
      ('periods', 33),
    ]) {
      final malformed = JwAcademicDetails().toMap()..[invalid.$1] = invalid.$2;
      expect(
        () => JwAcademicDetails.fromMap(malformed),
        throwsA(isA<FormatException>()),
        reason: 'invalid ${invalid.$1} must not be coerced',
      );
    }

    final outOfRange = JwAcademicDetails().toMap()..['weekday'] = 8;
    expect(
      () => JwAcademicDetails.fromMap(outOfRange),
      throwsA(isA<FormatException>()),
    );
  });

  test('sorts and deduplicates teachers into an immutable set', () {
    final details = JwAcademicDetails(
      teachers: const ['Zoe', 'Alice', 'Mina', 'Alice', 'Zoe'],
    );

    expect(details.teachers, ['Alice', 'Mina', 'Zoe']);
    expect(
      () => details.teachers.add('New Teacher'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test(
    'puts the classroom first and preserves known location parts and fallbacks',
    () {
      final fullLocation = JwAcademicDetails(
        campus: '东区',
        building: '东区',
        room: '教学楼 301',
        roomCode: 'R-301',
        customPlace: '线上会议室',
      );
      final roomCodeLocation = JwAcademicDetails(
        campus: '东区',
        building: '理科楼',
        roomCode: 'L-202',
        customPlace: '备用地点',
      );
      final fallbackLocation = JwAcademicDetails(customPlace: '线上会议室');

      expect(fullLocation.locationLabel, '教学楼 301 · 东区');
      expect(roomCodeLocation.locationLabel, 'L-202 · 理科楼 · 东区');
      expect(fallbackLocation.locationLabel, '线上会议室');
      expect(
        JwAcademicDetails(
          campus: '东区',
          building: '教学楼',
          customPlace: '机房 A',
        ).locationLabel,
        '机房 A · 教学楼 · 东区',
      );
      expect(JwAcademicDetails().locationLabel, isEmpty);
    },
  );

  test(
    'does not infer a semester from exam facts and preserves supplied labels',
    () {
      final examWithoutDirectoryLabel = JwAcademicDetails(
        examType: '期末考试',
        examNote: '综合楼机房',
      );
      final labeledCourse = _details(semesterName: '2026 年秋季');
      final restored = JwAcademicDetails.decode(
        jsonEncode(labeledCourse.toMap()),
      );

      expect(examWithoutDirectoryLabel.semesterName, isEmpty);
      expect(labeledCourse.semesterName, '2026 年秋季');
      expect(
        labeledCourse.withTeachers(['Other Teacher']).semesterName,
        '2026 年秋季',
      );
      expect(restored.semesterName, '2026 年秋季');
      expect(restored.toMap(), labeledCourse.toMap());
    },
  );

  test('round-trips all normalized facts through the versioned map', () {
    final original = _details(
      teachers: const ['Zoe', 'Alice', 'Zoe'],
      semesterName: '2026 年秋季',
    );
    final encoded = jsonEncode(original.toMap());
    final decoded = JwAcademicDetails.decode(encoded);

    expect(decoded.toMap(), original.toMap());
    expect(decoded.teachers, ['Alice', 'Zoe']);
    expect(decoded.equivalentTo(original), isTrue);
  });

  test('teacher-only equivalence does not hide other academic changes', () {
    final first = _details(teachers: const ['Alice']);
    final reordered = _details(teachers: const ['Zoe', 'Alice', 'Zoe']);
    final teacherOnlyChange = first.withTeachers(['Mina']);
    final semesterChange = _details(
      teachers: const ['Mina'],
      semesterName: '2026 年秋季',
    );

    expect(first.equivalentTo(reordered), isFalse);
    expect(first.equivalentTo(reordered, ignoreTeachers: true), isTrue);
    expect(first.equivalentTo(teacherOnlyChange), isFalse);
    expect(first.equivalentTo(teacherOnlyChange, ignoreTeachers: true), isTrue);
    expect(first.equivalentTo(semesterChange, ignoreTeachers: true), isFalse);
  });

  test(
    'rejects invalid text, limits, and oversized encoded facts without echoing',
    () {
      const marker = 'PRIVATE_RAW_SCHOOL_VALUE';
      final overLimitTeachers = List<String>.generate(
        65,
        (index) => 'Teacher $index',
      );
      final overEncodedLimit = List<String>.generate(
        64,
        (index) => '${index.toString().padLeft(2, '0')}${_repeat('"', 98)}',
      );

      for (final invalid in <JwAcademicDetails Function()>[
        () => JwAcademicDetails(campus: _repeat('x', 201)),
        () => JwAcademicDetails(examNote: _repeat('x', 4001)),
        () => JwAcademicDetails(customPlace: ' leading'),
        () => JwAcademicDetails(courseCode: 'bad\u0001value'),
        () => JwAcademicDetails(teachers: overLimitTeachers),
        () => JwAcademicDetails(teachers: [_repeat('x', 101)]),
        () => JwAcademicDetails(teachers: ['']),
        () => JwAcademicDetails(
          campus: _repeat('"', 200),
          building: _repeat('"', 200),
          room: _repeat('"', 200),
          roomCode: _repeat('"', 200),
          customPlace: _repeat('"', 200),
          courseCode: _repeat('"', 200),
          courseType: _repeat('"', 200),
          semesterName: _repeat('"', 200),
          examType: _repeat('"', 200),
          examNote: _repeat('"', 4000),
          teachers: overEncodedLimit,
        ),
        () => JwAcademicDetails(examNote: '$marker\u0001'),
      ]) {
        _expectRedactedFormatFailure(invalid, marker);
      }
    },
  );

  test(
    'malformed JSON and typed-map errors do not disclose their source text',
    () {
      const marker = 'PRIVATE_RAW_SCHOOL_RESPONSE';
      final malformedMap = JwAcademicDetails().toMap()
        ..['campus'] = marker
        ..['lessonId'] = 'not-an-integer';

      _expectRedactedFormatFailure(
        () => JwAcademicDetails.fromMap(malformedMap),
        marker,
      );
      _expectRedactedFormatFailure(
        () => JwAcademicDetails.decode('{"campus":"$marker",'),
        marker,
      );
    },
  );
}

JwAcademicDetails _details({
  List<String> teachers = const ['Alice'],
  String semesterName = '',
}) => JwAcademicDetails(
  campus: '东区',
  building: '理科楼',
  room: '302',
  roomCode: 'L-302',
  customPlace: '备用线上地点',
  virtual: false,
  teachers: teachers,
  courseCode: 'MATH-101',
  courseType: '必修',
  semesterName: semesterName,
  lessonId: 101,
  groupId: 4,
  weekIndex: 3,
  weekday: 2,
  periods: 2,
  exerciseClass: false,
  examType: '期末考试',
  examNote: '携带学生证',
);

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

void _expectRedactedFormatFailure(void Function() action, String marker) {
  try {
    action();
    fail('Expected invalid academic details to be rejected.');
  } on FormatException catch (error) {
    expect(error.toString(), isNot(contains(marker)));
  }
}
