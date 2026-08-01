import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/assistant_text_filter.dart';

/// Feeds [deltas] through a single [AssistantTextFilter] via [AssistantTextFilter.add]
/// and returns the concatenation of `add` outputs plus the `finish()` flush.
String filterAll(List<String> deltas) {
  final filter = AssistantTextFilter();
  final out = StringBuffer();
  for (final delta in deltas) {
    out.write(filter.add(delta));
  }
  out.write(filter.finish());
  return out.toString();
}

void main() {
  group('AssistantTextFilter — leading history markers', () {
    test('a timestamp history marker split across deltas is removed', () {
      expect(filterAll(['[2026-08-01T19:', '42] 正文']), '正文');
    });

    test('a whole-marker delta is removed', () {
      expect(filterAll(['[2026-08-01T19:42] 正文']), '正文');
    });

    test('multiple leading markers are all removed', () {
      expect(
        filterAll(['[2026-08-01T08:00][2026-08-01T09:00] 结果']),
        '结果',
      );
    });

    test('a body-internal timestamp is preserved (not a leading marker)', () {
      expect(filterAll(['正文时间 [2026-08-01T19:42]']),
          '正文时间 [2026-08-01T19:42]');
    });

    test('a leading bracket that is not a marker is preserved', () {
      expect(filterAll(['[通知] 今天放假']), '[通知] 今天放假');
    });

    test('a leading digit-bracket numbered list opening is preserved', () {
      expect(filterAll(['[2] 正文']), '[2] 正文');
    });

    test('a leading digit-bracket section number is preserved', () {
      expect(filterAll(['[3] 首先…']), '[3] 首先…');
    });

    test('a leading year-in-bracket that is not a timestamp is preserved', () {
      expect(filterAll(['[2025年度] 存储']), '[2025年度] 存储');
    });

    test('a split digit-bracket non-marker (no closing ] yet) is held then preserved',
        () {
      // Same stream semantics as a split timestamp: an incomplete "[2" is held
      // (could be a marker start), and once ']' arrives it resolves as content.
      expect(filterAll(['[2', '] 正文']), '[2] 正文');
    });

    test('a lone opening bracket held across deltas then resolved', () {
      // '[2' is a plausible marker prefix; '[通' is not. The filter holds the
      // marker-boundary characters until it can decide.
      expect(filterAll(['[', '2026-08-01T19:42] 正文']), '正文');
    });
  });

  group('AssistantTextFilter — ref_ leakage', () {
    test('a ref token split across deltas becomes 该条目', () {
      expect(filterAll(['找到 ref_YCSEZ4aC', 'QvqoVwR6rGyGvw。']),
          '找到该条目。');
    });

    test('a complete ref token in one delta becomes 该条目', () {
      expect(filterAll(['参见 ref_ABC123XYZ 的说明']), '参见该条目 的说明');
    });

    test('multiple ref tokens terminated by content are all replaced', () {
      expect(filterAll(['ref_AAA 与 ref_BBB 完成']), '该条目 与该条目 完成');
    });

    test('a bare trailing ref_ prefix at stream end is dropped, not persisted', () {
      expect(filterAll(['结果见 ref_']), '结果见');
    });

    test('an unterminated split ref token is dropped at stream end', () {
      expect(filterAll(['结果见 ref_AB']), '结果见');
    });

    test('a trailing complete ref with no terminator is dropped at stream end', () {
      // 'ref_BBB' runs to the end with no follower; it may be a split token, so
      // the safe behavior is to drop rather than persist a dangling token.
      expect(filterAll(['ref_AAA 与 ref_BBB']), '该条目 与');
    });

    test('ordinary text with no ref or marker passes through unchanged', () {
      expect(filterAll(['明天没有课。', '图书馆在东区。']),
          '明天没有课。图书馆在东区。');
    });
  });

  group('AssistantTextFilter — incremental output', () {
    test('add() emits only the newly-decided safe prefix', () {
      final filter = AssistantTextFilter();
      // First delta ends with an incomplete ref token -> nothing decidable yet.
      expect(filter.add('找到 ref_ABC'), '找到');
      // Second delta completes and terminates the ref -> flush 该条目。
      expect(filter.add('DEF。完成'), '该条目。完成');
      expect(filter.finish(), '');
    });
  });
}