import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_semester_default.dart';

void main() {
  test('default selection follows Beijing calendar boundaries', () {
    final options = [
      _option(7101, '2025-2026 秋季学期'),
      _option(7102, '2025-2026 春季学期'),
      _option(7103, '2025-2026 第三学期'),
      _option(7104, '2026-2027 秋季学期'),
    ];

    // 16:00 UTC is midnight in Beijing on the next calendar day.
    expect(defaultJwSemester(options, DateTime.utc(2026, 12, 31, 16)), 7104);
    expect(defaultJwSemester(options, DateTime.utc(2026, 1, 31, 15, 59)), 7101);
    expect(defaultJwSemester(options, DateTime.utc(2026, 1, 31, 16)), 7102);
    expect(defaultJwSemester(options, DateTime.utc(2026, 6, 30, 16)), 7103);
    expect(defaultJwSemester(options, DateTime.utc(2026, 7, 31, 16)), 7104);
    expect(defaultJwSemester(options, DateTime.utc(2026, 2, 1)), 7102);
  });

  test('supports explicit semester labels in academic-year forms', () {
    final academicYearOptions = [
      _option(301, '2026-2027学年第一学期'),
      _option(302, '2026-2027学年第二学期'),
      _option(303, '2026-2027学年第三学期'),
    ];

    expect(
      defaultJwSemester(academicYearOptions, DateTime.utc(2026, 10, 1)),
      301,
    );
    expect(
      defaultJwSemester(academicYearOptions, DateTime.utc(2027, 3, 1)),
      302,
    );
    expect(
      defaultJwSemester(academicYearOptions, DateTime.utc(2027, 7, 1)),
      303,
    );
    expect(
      defaultJwSemester([
        _option(404, '2026-2027-1'),
      ], DateTime.utc(2026, 10, 1)),
      404,
    );
    expect(
      defaultJwSemester([_option(505, '2027 春季学期')], DateTime.utc(2027, 3, 1)),
      505,
    );
    expect(
      defaultJwSemester([_option(606, '2027夏季学期')], DateTime.utc(2027, 7, 1)),
      606,
    );
  });

  test('uses one unique label match and never guesses from id or selected', () {
    expect(
      defaultJwSemester([
        _option(999999, '2026-2027 秋季学期'),
        _option(2026, '不可识别的学期', selected: true),
      ], DateTime.utc(2026, 10, 1)),
      999999,
    );
    expect(
      defaultJwSemester([
        _option(2026, '2030秋季学期', selected: true),
      ], DateTime.utc(2026, 10, 1)),
      isNull,
    );
    expect(
      defaultJwSemester([
        _option(71, '2026秋季学期'),
        _option(72, '2026 秋季'),
      ], DateTime.utc(2026, 10, 1)),
      isNull,
    );
    expect(defaultJwSemester(const [], DateTime.utc(2026, 10, 1)), isNull);
  });
}

JwSemesterOption _option(int id, String name, {bool selected = false}) =>
    JwSemesterOption(id: id, name: name, selected: selected);
