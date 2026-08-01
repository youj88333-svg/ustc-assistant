import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/write_argument_reader.dart';

void main() {
  group('WriteArgumentReader', () {
    test('requiredString returns trimmed text and rejects blank/absent/non-string', () {
      final r = WriteArgumentReader({'title': '  健身  ', 'x': 5}, {'title', 'x'});
      expect(r.requiredString('title'), '健身');
      expect(() => r.requiredString('missing'), throwsFormatException);
      expect(() => WriteArgumentReader({'title': '   '}, {'title'}).requiredString('title'), throwsFormatException);
      expect(() => WriteArgumentReader({'title': ''}, {'title'}).requiredString('title'), throwsFormatException);
      expect(() => WriteArgumentReader({'title': 42}, {'title'}).requiredString('title'), throwsFormatException);
    });

    test('optionalString returns null when absent or null, throws on wrong type', () {
      final r = WriteArgumentReader({'a': 'x', 'b': null, 'c': 7}, {'a', 'b', 'c'});
      expect(r.optionalString('a'), 'x');
      expect(r.optionalString('b'), isNull);
      expect(r.optionalString('missing'), isNull);
      expect(() => r.optionalString('c'), throwsFormatException);
    });

    test('optionalBool supports true/false/null and rejects other types', () {
      final r = WriteArgumentReader({'a': true, 'b': false, 'c': null, 'd': 'yes'}, {'a', 'b', 'c', 'd'});
      expect(r.optionalBool('a'), isTrue);
      expect(r.optionalBool('b'), isFalse);
      expect(r.optionalBool('c'), isNull);
      expect(r.optionalBool('missing'), isNull);
      expect(() => r.optionalBool('d'), throwsFormatException);
    });

    test('optionalInt rejects booleans and non-integers', () {
      final r = WriteArgumentReader({'a': 5, 'b': true, 'c': '5', 'd': 3.7}, {'a', 'b', 'c', 'd'});
      expect(r.optionalInt('a'), 5);
      expect(() => r.optionalInt('b'), throwsFormatException);
      expect(() => r.optionalInt('c'), throwsFormatException);
      expect(() => r.optionalInt('d'), throwsFormatException);
      expect(r.optionalInt('missing'), isNull);
    });

    test('requiredStringList validates element types and presence', () {
      final r = WriteArgumentReader({'tags': ['a', 'b'], 'bad': ['a', 5]}, {'tags', 'bad'});
      expect(r.requiredStringList('tags'), ['a', 'b']);
      expect(() => r.requiredStringList('bad'), throwsFormatException);
      expect(() => r.requiredStringList('missing'), throwsFormatException);
    });

    test('requiredIntList validates element types and presence', () {
      final r = WriteArgumentReader({'off': [15, 120], 'bad': [15, 'x'], 'badBool': [true]}, {'off', 'bad', 'badBool'});
      expect(r.requiredIntList('off'), [15, 120]);
      expect(() => r.requiredIntList('bad'), throwsFormatException);
      expect(() => r.requiredIntList('badBool'), throwsFormatException);
      expect(() => r.requiredIntList('missing'), throwsFormatException);
    });

    test('optionalStringList returns null when absent, validates when present', () {
      final r = WriteArgumentReader({'tags': ['a'], 'bad': [1]}, {'tags', 'bad'});
      expect(r.optionalStringList('tags'), ['a']);
      expect(r.optionalStringList('missing'), isNull);
      expect(() => r.optionalStringList('bad'), throwsFormatException);
    });

    test('requiredEnum requires a member of the allowed set', () {
      final r = WriteArgumentReader({'importance': 'high'}, {'importance'});
      expect(r.requiredEnum('importance', const {'low', 'normal', 'high', 'critical'}), 'high');
      expect(
        () => r.requiredEnum('importance', const {'low', 'normal'}),
        throwsFormatException,
      );
    });

    test('optionalEnum returns null when absent, throws on unknown value', () {
      final r = WriteArgumentReader({'mode': 'listen'}, {'mode'});
      expect(r.optionalEnum('missing', const {'listen', 'not_listen'}), isNull);
      expect(r.optionalEnum('mode', const {'listen', 'not_listen'}), 'listen');
      expect(
        () => r.optionalEnum('mode', const {'silent'}),
        throwsFormatException,
      );
    });

    test('rejects unknown keys and enum fallback', () {
      final reader = WriteArgumentReader(
        {'mode': 'silent', 'extra': true},
        {'mode'},
      );
      expect(reader.rejectUnknownKeys, throwsFormatException);

      final enumReader = WriteArgumentReader({'mode': 'silent'}, {'mode'});
      expect(
        () => enumReader.requiredEnum('mode', const {'listen', 'not_listen'}),
        throwsFormatException,
      );
    });

    test('contains reflects key presence', () {
      final r = WriteArgumentReader({'a': null}, {'a', 'b'});
      expect(r.contains('a'), isTrue);
      expect(r.contains('b'), isFalse);
    });

    test('rejectUnknownKeys passes when every key is allowed', () {
      final r = WriteArgumentReader({'a': 1, 'b': 'x'}, {'a', 'b'});
      expect(() => r.rejectUnknownKeys(), returnsNormally);
    });
  });
}