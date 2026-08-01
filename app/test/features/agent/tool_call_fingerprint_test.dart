import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/tool_call_fingerprint.dart';

void main() {
  group('ToolCallFingerprint.of — deterministic across map key order', () {
    test('top-level map key order does not change the fingerprint', () {
      expect(
        ToolCallFingerprint.of('get_schedule', {'b': 2, 'a': 1}),
        ToolCallFingerprint.of('get_schedule', {'a': 1, 'b': 2}),
      );
    });

    test('nested map key order does not change the fingerprint', () {
      final a = ToolCallFingerprint.of('get_schedule', {
        'date': {'year': 2026, 'month': 8, 'day': 1},
        'room': 'A',
      });
      final b = ToolCallFingerprint.of('get_schedule', {
        'room': 'A',
        'date': {'day': 1, 'month': 8, 'year': 2026},
      });
      expect(a, b);
    });

    test('list order remains significant', () {
      final a = ToolCallFingerprint.of('x', {'items': ['a', 'b']});
      final b = ToolCallFingerprint.of('x', {'items': ['b', 'a']});
      expect(a, isNot(b));
    });

    test('different tool names produce different fingerprints', () {
      expect(
        ToolCallFingerprint.of('get_schedule', {'d': '2026-08-01'}),
        isNot(ToolCallFingerprint.of('get_tasks', {'d': '2026-08-01'})),
      );
    });

    test('different values produce different fingerprints', () {
      expect(
        ToolCallFingerprint.of('get_schedule', {'date': '2026-08-01'}),
        isNot(ToolCallFingerprint.of('get_schedule', {'date': '2026-08-02'})),
      );
    });

    test('nested lists inside maps keep order significant', () {
      final a = ToolCallFingerprint.of('x', {
        'outer': {'inner': [1, 2]},
      });
      final b = ToolCallFingerprint.of('x', {
        'outer': {'inner': [2, 1]},
      });
      expect(a, isNot(b));
    });

    test('scalar, null, and primitives are deterministic', () {
      final a = ToolCallFingerprint.of('x', {'n': 1, 's': 'a', 'z': null});
      final b = ToolCallFingerprint.of('x', {'z': null, 's': 'a', 'n': 1});
      expect(a, b);
    });
  });
}