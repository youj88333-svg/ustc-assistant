import 'dart:convert';

import 'diagnostics_contract.dart';

/// Parses only the closed exported protocol, never a generic app/debug bundle.
Map<String, Object?> analyzeDiagnosticExport(String contents) {
  if (utf8.encode(contents).length > 2 * 1024 * 1024 + 16384) {
    throw const FormatException('diagnostic_bundle_size');
  }
  final raw = jsonDecode(contents);
  if (raw is! Map<String, dynamic> ||
      raw['kind'] != 'ustc-diagnostics-export-v1' ||
      raw.keys.any(
        (k) => !const {
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
        }.contains(k),
      ) ||
      raw['records'] is! List ||
      (raw['records'] as List).length > diagnosticMaximumExportRecords ||
      raw['complete'] is! bool ||
      raw['selectionTruncated'] is! bool ||
      !const {
        'retained_recent_events',
        'startup_error_only',
      }.contains(raw['coverage']) ||
      raw['retentionDays'] != diagnosticRetentionDays) {
    throw const FormatException('diagnostic_bundle_shape');
  }
  for (final key in ['invalid', 'dropped']) {
    if (raw[key] is! int ||
        (raw[key] as int) < 0 ||
        (raw[key] as int) > 2147483647) {
      throw const FormatException('diagnostic_bundle_count');
    }
  }
  final versions = raw['versions'];
  if (versions is! Map<String, dynamic> ||
      versions.keys.any(
        (k) => !const {
          'application',
          'schema',
          'tools',
          'prompt',
          'revision',
        }.contains(k),
      )) {
    throw const FormatException('diagnostic_bundle_versions');
  }
  final safeVersions = DiagnosticVersions(
    application: versions['application'] is String
        ? versions['application'] as String
        : 'unknown',
    schema: versions['schema'] is int ? versions['schema'] as int : 0,
    tools: versions['tools'] is String
        ? versions['tools'] as String
        : 'unknown',
    prompt: versions['prompt'] is String
        ? versions['prompt'] as String
        : 'unknown',
    revision: versions['revision'] is String
        ? versions['revision'] as String
        : 'unknown',
  ).toSafeMap();
  final records =
      (raw['records'] as List)
          .map((v) => DiagnosticRecord.decode(jsonEncode(v)))
          .toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
  final traces = <String, List<DiagnosticRecord>>{};
  final untraced = <DiagnosticRecord>[];
  for (final record in records) {
    final trace = record.event.trace;
    if (trace == null) {
      untraced.add(record);
    } else {
      traces.putIfAbsent(trace.value, () => []).add(record);
    }
  }
  final traceList = traces.entries.toList();
  final recentTraces = traceList.skip(
    traceList.length > 20 ? traceList.length - 20 : 0,
  );
  return {
    'kind': 'ustc-diagnostics-analysis-v1',
    'versions': safeVersions,
    'complete': raw['complete'],
    'selectionTruncated': raw['selectionTruncated'],
    'recordCount': records.length,
    'coverage': raw['coverage'],
    'invalid': raw['invalid'],
    'dropped': raw['dropped'],
    'reproduction': 'synthetic_contract_only',
    'traces': [
      for (final entry in recentTraces)
        {
          'trace': entry.key,
          'versions': entry.value.first.versions.toSafeMap(),
          'events': entry.value.length,
          'firstAtUtc': entry.value.first.atUtc.toIso8601String(),
          'lastAtUtc': entry.value.last.atUtc.toIso8601String(),
          'lastEvent': entry.value.last.event.name.name,
          'problems': [
            for (final record in entry.value.where(_isProblem)) record.toMap(),
          ],
          'committedTools': [
            for (final record in entry.value.where(
              (r) =>
                  r.event.outcome == DiagnosticOutcome.committed &&
                  r.event.tool != null,
            ))
              record.event.tool!.name,
          ],
          'committedStages': [
            for (final record in entry.value.where(
              (r) =>
                  r.event.outcome == DiagnosticOutcome.committed &&
                  r.event.stage != null,
            ))
              record.event.stage!.name,
          ],
        },
    ],
    'untracedProblems': [
      for (final record in untraced.where(_isProblem).take(20)) record.toMap(),
    ],
  };
}

bool _isProblem(DiagnosticRecord record) =>
    record.event.issue != null ||
    record.event.code != null ||
    const {
      DiagnosticOutcome.failure,
      DiagnosticOutcome.cancelled,
      DiagnosticOutcome.recovery,
    }.contains(record.event.outcome);
