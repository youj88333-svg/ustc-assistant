import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_semester_catalog.dart';

void main() {
  test('codec accepts and round-trips the 256-entry bound', () {
    final options = [
      for (var id = 1; id <= 256; id++)
        JwSemesterOption(id: id, name: '合成学期 $id', selected: id == 256),
    ];
    final catalog = JwSemesterCatalog.fromOptions(options);
    final decoded = JwSemesterCatalog.decode(catalog.encode());

    expect(decoded.options, hasLength(256));
    for (var index = 0; index < options.length; index++) {
      expect(decoded.options[index].id, options[index].id);
      expect(decoded.options[index].name, options[index].name);
      expect(decoded.options[index].selected, options[index].selected);
    }
  });

  test('rejects out-of-bound, duplicate, and multiple-selected options', () {
    final tooMany = [
      for (var id = 1; id <= 257; id++)
        JwSemesterOption(id: id, name: '学期 $id', selected: false),
    ];
    _expectInvalid(() => JwSemesterCatalog.fromOptions(tooMany));
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions([
        const JwSemesterOption(id: 1, name: '2026秋季', selected: false),
        const JwSemesterOption(id: 1, name: '2027春季', selected: false),
      ]),
    );
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions([
        const JwSemesterOption(id: 1, name: '2026秋季', selected: true),
        const JwSemesterOption(id: 2, name: '2027春季', selected: true),
      ]),
    );
  });

  test('rejects malformed shapes and invalid option fields', () {
    for (final encoded in [
      'not-json',
      '[]',
      '[{"id":1,"name":"2026秋季"}]',
      '[{"id":1,"name":"2026秋季","selected":false,"extra":true}]',
      '[{"id":"1","name":"2026秋季","selected":false}]',
    ]) {
      _expectInvalid(() => JwSemesterCatalog.decode(encoded));
    }

    final maximumName = List.filled(120, '学').join();
    expect(
      JwSemesterCatalog.fromOptions([
        JwSemesterOption(id: 7, name: maximumName, selected: false),
      ]).options,
      hasLength(1),
    );

    _expectInvalid(
      () => JwSemesterCatalog.fromOptions(const [
        JwSemesterOption(id: 0, name: '2026秋季', selected: false),
      ]),
    );
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions(const [
        JwSemesterOption(id: 2147483648, name: '2026秋季', selected: false),
      ]),
    );
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions([
        JwSemesterOption(
          id: 1,
          name: List.filled(121, '学').join(),
          selected: false,
        ),
      ]),
    );
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions(const [
        JwSemesterOption(id: 1, name: '2026秋季<', selected: false),
      ]),
    );
    _expectInvalid(
      () => JwSemesterCatalog.fromOptions(const [
        JwSemesterOption(id: 1, name: '2026秋季\n', selected: false),
      ]),
    );
  });
}

void _expectInvalid(Object? Function() action) {
  expect(
    action,
    throwsA(
      isA<AppFailure>().having(
        (failure) => failure.code,
        'failure code',
        FailureCode.invalidSnapshot,
      ),
    ),
  );
}
