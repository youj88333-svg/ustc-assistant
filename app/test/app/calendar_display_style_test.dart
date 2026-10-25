import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/calendar_display_style.dart';

void main() {
  test('numbered event names remain visually distinct', () {
    final colors = List.generate(
      12,
      (index) => calendarColorsForTitle('实验 ${index + 1}'),
    );
    expect(colors.map((color) => color.fill).toSet(), hasLength(12));
    expect(colors.map((color) => color.edge).toSet(), hasLength(12));
  });
  test('normalizes title whitespace and case before choosing colors', () {
    expect(normalizeCalendarTitle('  Intro\n to\t AI  '), 'intro to ai');
    expect(
      calendarColorsForTitle('  Intro\n to\t AI  '),
      calendarColorsForTitle('intro to ai'),
    );
    expect(
      calendarColorsForTitle('  高等  数学 '),
      calendarColorsForTitle('高等 数学'),
    );
  });

  test(
    'same normalized name stays identical across calendar presentations',
    () {
      final firstPresentation = calendarColorsForTitle('复变函数');
      final otherPresentation = calendarColorsForTitle('  复变函数  ');

      expect(otherPresentation.fill, firstPresentation.fill);
      expect(otherPresentation.ink, firstPresentation.ink);
      expect(otherPresentation.edge, firstPresentation.edge);
    },
  );

  test('typical Chinese and English names receive distinguishable colors', () {
    const titles = [
      '高等数学',
      '线性代数',
      '大学物理',
      '数据结构',
      '算法设计',
      '实验课',
      '社团活动',
      'English Communication',
      'Physics Lab',
      'Project Meeting',
    ];
    final fills = titles
        .map((title) => calendarColorsForTitle(title).fill)
        .toSet();

    expect(fills, hasLength(titles.length));
  });

  test('each representative color keeps readable same-hue text and border', () {
    const titles = [
      '高等数学',
      '线性代数',
      '大学物理',
      'English Communication',
      'Physics Lab',
    ];

    for (final title in titles) {
      final colors = calendarColorsForTitle(title);
      expect(_contrast(colors.fill, colors.ink), greaterThanOrEqualTo(4.5));
      expect(_contrast(colors.fill, colors.edge), greaterThanOrEqualTo(4.5));
    }
  });
}

double _contrast(Color background, Color foreground) {
  final backgroundLuminance = background.computeLuminance();
  final foregroundLuminance = foreground.computeLuminance();
  final lighter = backgroundLuminance > foregroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  final darker = backgroundLuminance > foregroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
