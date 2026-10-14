import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Internal correlation for an actual local invocation, never a permission,
/// a model field or a semantic comparison of unrelated user requests.
String agentLocalInvocationFingerprint(Map<String, Object?> arguments) {
  Object? canonical(Object? value) => switch (value) {
    Map() => {
      for (final key in value.keys.cast<String>().toList()..sort())
        key: canonical(value[key]),
    },
    List() => value.map(canonical).toList(),
    _ => value,
  };
  final values = Map<String, Object?>.of(arguments)..remove('new_operation');
  return sha256.convert(utf8.encode(jsonEncode(canonical(values)))).toString();
}
