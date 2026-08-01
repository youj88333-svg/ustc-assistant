/// 严格读取模型传入的 write-tool 参数。
///
/// 所有校验失败都以 [FormatException] 抛出，由 [AgentWriteTool.execute] 统一
/// 映射为 `invalid_write_arguments`。可选方法仅在键缺失或显式为 null 时返回
/// null；一旦键存在, 类型不匹配立即抛错, 不做静默回退。
final class WriteArgumentReader {
  WriteArgumentReader(this._values, Set<String> allowedKeys)
      : _allowedKeys = Set.unmodifiable(allowedKeys);

  final Map<String, Object?> _values;
  final Set<String> _allowedKeys;

  /// 键是否存在（无论值是否显式为 null）。
  bool contains(String key) => _values.containsKey(key);

  /// 拒绝所有不在白名单内的键（schema 中未声明的字段一律非法）。
  void rejectUnknownKeys() {
    final unknown = _values.keys.toSet().difference(_allowedKeys);
    if (unknown.isNotEmpty) throw FormatException('unknown keys: $unknown');
  }

  String requiredString(String key) {
    final value = _values[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be non-blank text');
    }
    return value.trim();
  }

  String? optionalString(String key) {
    final value = _values[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('$key must be text');
    return value;
  }

  bool? optionalBool(String key) {
    final value = _values[key];
    if (value == null) return null;
    if (value is! bool) throw FormatException('$key must be a boolean');
    return value;
  }

  int? optionalInt(String key) {
    final value = _values[key];
    if (value == null) return null;
    // bool 也是 Object? 的子类型，但绝不允许当作整数。int 是严格精确匹配。
    if (value is! int) throw FormatException('$key must be an integer');
    return value;
  }

  List<String> requiredStringList(String key) {
    final value = _values[key];
    if (value is! List) throw FormatException('$key must be a list of strings');
    final result = <String>[];
    for (final element in value) {
      if (element is! String) throw FormatException('$key elements must be strings');
      result.add(element);
    }
    return result;
  }

  List<int> requiredIntList(String key) {
    final value = _values[key];
    if (value is! List) throw FormatException('$key must be a list of integers');
    final result = <int>[];
    for (final element in value) {
      if (element is! int) throw FormatException('$key elements must be integers');
      result.add(element);
    }
    return result;
  }

  List<String>? optionalStringList(String key) {
    final value = _values[key];
    if (value == null) return null;
    return requiredStringList(key);
  }

  String requiredEnum(String key, Set<String> values) {
    final value = requiredString(key);
    if (!values.contains(value)) throw FormatException('$key has invalid value');
    return value;
  }

  String? optionalEnum(String key, Set<String> values) {
    final value = _values[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('$key must be text');
    if (!values.contains(value)) throw FormatException('$key has invalid value');
    return value;
  }
}