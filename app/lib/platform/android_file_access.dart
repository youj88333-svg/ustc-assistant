import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';

/// Only user-selected images and a closed diagnostic export cross this port.
/// Content URIs never become filesystem paths or Agent-visible information.
final class AndroidFileAccess {
  const AndroidFileAccess({
    this.channel = const MethodChannel('ustc_assistant/files_v1'),
  });

  final MethodChannel channel;
  static const maximumOriginalBytes = 10 * 1024 * 1024;
  static const maximumExportBytes = 2 * 1024 * 1024;

  Future<List<Uint8List>> pickImages() async {
    Object? response;
    try {
      response = await channel.invokeMethod<Object?>('pickImages', {
        'maximumCount': AgentImage.maximumCount,
      });
      if (response is! List || response.length > AgentImage.maximumCount) {
        throw const AgentFailure(AgentFailureCode.imageRejected);
      }
      final images = <Uint8List>[];
      for (final item in response) {
        if (item is! Uint8List ||
            item.isEmpty ||
            item.length > maximumOriginalBytes) {
          throw const AgentFailure(AgentFailureCode.imageRejected);
        }
        images.add(item);
      }
      return images;
    } on Object catch (error) {
      if (response is List) {
        for (final item in response) {
          if (item is Uint8List) item.fillRange(0, item.length, 0);
        }
      }
      if (error is AgentFailure) rethrow;
      if (error is PlatformException) {
        throw AgentFailure(switch (error.code) {
          'resource_limit' => AgentFailureCode.resourceLimit,
          'busy' => AgentFailureCode.busy,
          'timeout' => AgentFailureCode.timeout,
          'cancelled' => AgentFailureCode.cancelled,
          'unavailable' => AgentFailureCode.toolUnavailable,
          _ => AgentFailureCode.imageRejected,
        });
      }
      throw const AgentFailure(AgentFailureCode.imageRejected);
    }
  }

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

/// Rebuild the journal whitelist before handing the export to a system picker.
String validateDiagnosticExport(String contents) {
  try {
    if (contents.length > AndroidFileAccess.maximumExportBytes ||
        utf8.encode(contents).length > AndroidFileAccess.maximumExportBytes) {
      throw const FormatException('diagnostic_export_size');
    }
    final raw = jsonDecode(contents);
    const fields = {
      'kind',
      'exportedAtUtc',
      'retentionDays',
      'versions',
      'coverage',
      'selectionTruncated',
      'complete',
      'dropped',
      'invalid',
      'records',
    };
    if (raw is! Map<String, dynamic> ||
        raw.length != fields.length ||
        raw.keys.any((key) => !fields.contains(key)) ||
        raw['kind'] != 'ustc-diagnostics-export-v1' ||
        raw['retentionDays'] != diagnosticRetentionDays ||
        !const {
          'retained_recent_events',
          'startup_error_only',
        }.contains(raw['coverage']) ||
        raw['selectionTruncated'] is! bool ||
        raw['complete'] is! bool) {
      throw const FormatException('diagnostic_export_shape');
    }
    final date = raw['exportedAtUtc'];
    if (raw['coverage'] == 'startup_error_only' && raw['complete'] != false) {
      throw const FormatException('diagnostic_export_coverage');
    }
    if (date is! String ||
        date.length > 32 ||
        !date.endsWith('Z') ||
        DateTime.tryParse(date)?.isUtc != true) {
      throw const FormatException('diagnostic_export_date');
    }
    for (final field in ['dropped', 'invalid']) {
      final count = raw[field];
      if (count is! int || count < 0 || count > 9007199254740991) {
        throw const FormatException('diagnostic_export_count');
      }
    }
    final versions = raw['versions'];
    const versionFields = {
      'application',
      'schema',
      'tools',
      'prompt',
      'revision',
    };
    if (versions is! Map<String, dynamic> ||
        versions.length != versionFields.length ||
        versions.keys.any((key) => !versionFields.contains(key)) ||
        versions['application'] is! String ||
        versions['schema'] is! int ||
        versions['tools'] is! String ||
        versions['prompt'] is! String ||
        versions['revision'] is! String) {
      throw const FormatException('diagnostic_export_versions');
    }
    final safeVersions = DiagnosticVersions(
      application: versions['application'] as String,
      schema: versions['schema'] as int,
      tools: versions['tools'] as String,
      prompt: versions['prompt'] as String,
      revision: versions['revision'] as String,
    ).toSafeMap();
    if (versionFields.any((key) => versions[key] != safeVersions[key])) {
      throw const FormatException('diagnostic_export_versions');
    }
    final records = raw['records'];
    if (records is! List || records.length > diagnosticMaximumExportRecords) {
      throw const FormatException('diagnostic_export_records');
    }
    return jsonEncode({
      for (final key in fields)
        key: key == 'records'
            ? records
                  .map(
                    (item) => DiagnosticRecord.decode(jsonEncode(item)).toMap(),
                  )
                  .toList(growable: false)
            : key == 'versions'
            ? safeVersions
            : raw[key],
    });
  } on Object {
    throw const DiagnosticsFailure(DiagnosticsFailureCode.exportFailed);
  }
}
