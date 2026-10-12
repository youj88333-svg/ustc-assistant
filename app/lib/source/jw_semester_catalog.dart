import 'dart:convert';

import '../core/contracts.dart';
import 'jw_probe_contract.dart';

/// A bounded directory for local selection, never source or identity authority.
final class JwSemesterCatalog {
  JwSemesterCatalog._(this.options);

  final List<JwSemesterOption> options;

  factory JwSemesterCatalog.fromOptions(List<JwSemesterOption> options) {
    final ids = <int>{};
    var selected = 0;
    if (options.isEmpty || options.length > 256) _invalid();
    for (final option in options) {
      if (option.id <= 0 ||
          option.id > 2147483647 ||
          !ids.add(option.id) ||
          option.name.runes.isEmpty ||
          option.name.runes.length > 120 ||
          RegExp(r'[\x00-\x1F\x7F-\x9F<>]').hasMatch(option.name)) {
        _invalid();
      }
      if (option.selected) selected++;
    }
    if (selected > 1) _invalid();
    return JwSemesterCatalog._(List.unmodifiable(options));
  }

  factory JwSemesterCatalog.decode(String encoded) {
    if (encoded.length > 131072) _invalid();
    try {
      final values = jsonDecode(encoded);
      if (values is! List || values.isEmpty || values.length > 256) _invalid();
      final options = <JwSemesterOption>[];
      for (final value in values) {
        if (value is! Map<String, dynamic> ||
            value.length != 3 ||
            value['id'] is! int ||
            value['name'] is! String ||
            value['selected'] is! bool) {
          _invalid();
        }
        options.add(
          JwSemesterOption(
            id: value['id'] as int,
            name: value['name'] as String,
            selected: value['selected'] as bool,
          ),
        );
      }
      return JwSemesterCatalog.fromOptions(options);
    } on AppFailure {
      rethrow;
    } on Object {
      _invalid();
    }
  }

  String encode() => jsonEncode([
    for (final option in options)
      {'id': option.id, 'name': option.name, 'selected': option.selected},
  ]);

  static Never _invalid() =>
      throw const AppFailure(FailureCode.invalidSnapshot);

  @override
  String toString() => 'JwSemesterCatalog';
}
