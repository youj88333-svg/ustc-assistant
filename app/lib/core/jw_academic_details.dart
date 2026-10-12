import 'dart:convert';

/// Normalized school facts, never a progress or diagnostic payload.
/// A null details object on an old event means not collected, not absent.
final class JwAcademicDetails {
  JwAcademicDetails({
    this.campus = '',
    this.building = '',
    this.room = '',
    this.roomCode = '',
    this.customPlace = '',
    this.virtual,
    List<String> teachers = const [],
    this.courseCode = '',
    this.courseType = '',
    this.semesterName = '',
    this.lessonId,
    this.groupId,
    this.weekIndex,
    this.weekday,
    this.periods,
    this.exerciseClass,
    this.examType = '',
    this.examNote = '',
  }) : teachers = List.unmodifiable(teachers.toSet().toList()..sort()) {
    for (final value in [
      campus,
      building,
      room,
      roomCode,
      customPlace,
      courseCode,
      courseType,
      semesterName,
      examType,
    ]) {
      _validateText(value, 200);
    }
    _validateText(examNote, 4000);
    if (this.teachers.length > 64) _invalid();
    for (final teacher in this.teachers) {
      _validateText(teacher, 100);
      if (teacher.isEmpty) _invalid();
    }
    for (final id in [lessonId, groupId]) {
      if (id != null && (id < 1 || id > 2147483647)) _invalid();
    }
    if ((weekIndex != null && (weekIndex! < 1 || weekIndex! > 256)) ||
        (weekday != null && (weekday! < 1 || weekday! > 7)) ||
        (periods != null && (periods! < 1 || periods! > 32))) {
      _invalid();
    }
    if (jsonEncode(toMap()).length > maximumEncodedLength) _invalid();
  }

  static const version = 'jw-academic-details-v1';
  static const maximumEncodedLength = 24576;
  final String campus;
  final String building;
  final String room;
  final String roomCode;
  final String customPlace;
  final bool? virtual;
  final List<String> teachers;
  final String courseCode;
  final String courseType;
  final String semesterName;
  final int? lessonId;
  final int? groupId;
  final int? weekIndex;
  final int? weekday;
  final int? periods;
  final bool? exerciseClass;
  final String examType;
  final String examNote;

  String get locationLabel {
    final primaryRoom = room.isNotEmpty
        ? room
        : roomCode.isNotEmpty
        ? roomCode
        : customPlace;
    final parts = [
      campus,
      building,
      primaryRoom,
    ].where((value) => value.isNotEmpty).toSet();
    return parts.isEmpty ? customPlace : parts.join(' · ');
  }

  Map<String, Object?> toMap() => {
    'version': version,
    'campus': campus,
    'building': building,
    'room': room,
    'roomCode': roomCode,
    'customPlace': customPlace,
    'virtual': virtual,
    'teachers': teachers,
    'courseCode': courseCode,
    'courseType': courseType,
    'semesterName': semesterName,
    'lessonId': lessonId,
    'groupId': groupId,
    'weekIndex': weekIndex,
    'weekday': weekday,
    'periods': periods,
    'exerciseClass': exerciseClass,
    'examType': examType,
    'examNote': examNote,
  };

  factory JwAcademicDetails.fromMap(Object? source) {
    try {
      if (source is! Map<String, dynamic> ||
          source.length != 19 ||
          source['version'] != version ||
          !source.keys.every(
            const {
              'version',
              'campus',
              'building',
              'room',
              'roomCode',
              'customPlace',
              'virtual',
              'teachers',
              'courseCode',
              'courseType',
              'semesterName',
              'lessonId',
              'groupId',
              'weekIndex',
              'weekday',
              'periods',
              'exerciseClass',
              'examType',
              'examNote',
            }.contains,
          )) {
        _invalid();
      }
      final names = source['teachers'];
      if (names is! List ||
          names.length > 64 ||
          names.any((v) => v is! String)) {
        _invalid();
      }
      return JwAcademicDetails(
        campus: source['campus'] as String,
        building: source['building'] as String,
        room: source['room'] as String,
        roomCode: source['roomCode'] as String,
        customPlace: source['customPlace'] as String,
        virtual: source['virtual'] as bool?,
        teachers: names.cast<String>(),
        courseCode: source['courseCode'] as String,
        courseType: source['courseType'] as String,
        semesterName: source['semesterName'] as String,
        lessonId: source['lessonId'] as int?,
        groupId: source['groupId'] as int?,
        weekIndex: source['weekIndex'] as int?,
        weekday: source['weekday'] as int?,
        periods: source['periods'] as int?,
        exerciseClass: source['exerciseClass'] as bool?,
        examType: source['examType'] as String,
        examNote: source['examNote'] as String,
      );
    } on Object {
      _invalid();
    }
  }

  factory JwAcademicDetails.decode(String source) {
    try {
      if (source.length > maximumEncodedLength) _invalid();
      return JwAcademicDetails.fromMap(jsonDecode(source));
    } on Object {
      _invalid();
    }
  }

  JwAcademicDetails withTeachers(List<String> names) => JwAcademicDetails(
    campus: campus,
    building: building,
    room: room,
    roomCode: roomCode,
    customPlace: customPlace,
    virtual: virtual,
    teachers: names,
    courseCode: courseCode,
    courseType: courseType,
    semesterName: semesterName,
    lessonId: lessonId,
    groupId: groupId,
    weekIndex: weekIndex,
    weekday: weekday,
    periods: periods,
    exerciseClass: exerciseClass,
    examType: examType,
    examNote: examNote,
  );

  bool equivalentTo(JwAcademicDetails other, {bool ignoreTeachers = false}) {
    final left = toMap(), right = other.toMap();
    if (ignoreTeachers) {
      left.remove('teachers');
      right.remove('teachers');
    }
    return jsonEncode(left) == jsonEncode(right);
  }

  static void _validateText(String value, int limit) {
    if (value.length > limit ||
        value.trim() != value ||
        RegExp(r'[\x00-\x08\x0e-\x1f\x7f-\x9f]').hasMatch(value)) {
      _invalid();
    }
  }

  static Never _invalid() =>
      throw const FormatException('Invalid academic details');
  @override
  String toString() => 'JwAcademicDetails';
}
