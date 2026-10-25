import 'jw_probe_contract.dart';

/// Matches the Beijing calendar target to labels in a fresh school directory.
/// IDs are opaque. Missing or ambiguous labels require an explicit selection.
int? defaultJwSemester(List<JwSemesterOption> options, DateTime nowUtc) {
  final beijing = nowUtc.toUtc().add(const Duration(hours: 8));
  final year = beijing.month == 1 ? beijing.year - 1 : beijing.year;
  final season = switch (beijing.month) {
    >= 2 && <= 6 => '春',
    7 => '夏',
    _ => '秋',
  };
  final matches = options.where((option) {
    final key = _semesterKey(option.name);
    return key?.$1 == year && key?.$2 == season;
  }).toList();
  return matches.length == 1 ? matches.single.id : null;
}

(int, String)? _semesterKey(String name) {
  final normalized = name.replaceAll(RegExp(r'\s+'), '');
  final seasons = RegExp(r'[春夏秋]').allMatches(normalized).toList();
  final years = RegExp(
    r'(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])',
  ).allMatches(normalized).map((match) => int.parse(match[0]!)).toList();
  if (years.isEmpty || years.length > 2) return null;
  String? season;
  if (seasons.length == 1) {
    season = seasons.single[0];
  } else if (seasons.isEmpty && years.length == 2) {
    // Explicit academic-year labels: 第一/二/三学期 or YYYY-YYYY-1/2/3.
    final ordinal = RegExp(r'第([一二三123])学期').firstMatch(normalized)?[1];
    final numeric = RegExp(
      r'^(?:19|20)[0-9]{2}[-–—/](?:19|20)[0-9]{2}[-–—/]([123])$',
    ).firstMatch(normalized)?[1];
    season = switch (ordinal ?? numeric) {
      '一' || '1' => '秋',
      '二' || '2' => '春',
      '三' || '3' => '夏',
      _ => null,
    };
  }
  if (season == null) return null;
  if (years.length == 1) return (years.single, season);
  if (years[1] != years[0] + 1) return null;
  return (season == '秋' ? years[0] : years[1], season);
}
