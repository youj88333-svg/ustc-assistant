import 'dart:convert';
import 'dart:io';

import 'package:ustc_assistant_m0/core/diagnostics_analysis.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      !arguments.single.toLowerCase().endsWith('.json')) {
    stderr.writeln('用法：dart run tool/diagnostics_summary.dart <导出的诊断.json>');
    exitCode = 2;
    return;
  }
  try {
    final path = arguments.single;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('diagnostic_file');
    }
    final handle = await File(path).open();
    late final List<int> bytes;
    try {
      if (await handle.length() > 2 * 1024 * 1024 + 16384) {
        throw const FormatException('diagnostic_size');
      }
      bytes = await handle.read(2 * 1024 * 1024 + 16385);
    } finally {
      await handle.close();
    }
    final summary = analyzeDiagnosticExport(utf8.decode(bytes));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
  } catch (_) {
    stderr.writeln('无法读取有效的安全诊断包；没有输出文件原文或异常内容。');
    exitCode = 1;
  }
}
