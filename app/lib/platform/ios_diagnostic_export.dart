import 'package:flutter/services.dart';

import '../core/diagnostics_contract.dart';
import 'android_file_access.dart' show validateDiagnosticExport;

/// Sends only the rebuilt diagnostic whitelist to the native iOS file picker.
final class IOSDiagnosticExport {
  const IOSDiagnosticExport({this.channel = const MethodChannel(_channelName)});

  static const _channelName = 'ustc_assistant/diagnostics_v1';
  final MethodChannel channel;

  Future<bool> saveDiagnosticLog(String contents) async {
    final safeContents = validateDiagnosticExport(contents);
    try {
      final saved = await channel.invokeMethod<Object?>('saveDiagnosticLog', {
        'contents': safeContents,
      });
      if (saved is! bool) throw const FormatException('diagnostic_save');
      return saved;
    } on Object {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.exportFailed);
    }
  }
}
