import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/diagnostics_contract.dart';

/// Best-effort, local-only diagnostic storage. It owns no application assets.
final class DiagnosticJournal implements DiagnosticsPort {
  DiagnosticJournal._({
    required String directoryPath,
    required this._ensureOwnership,
    required this._checkedPath,
    required this.clock,
    required this.versions,
  }) : _directoryPath = p.normalize(p.absolute(directoryPath));

  static const segmentNames = <String>[
    'diagnostic-0.jsonl',
    'diagnostic-1.jsonl',
    'diagnostic-2.jsonl',
    'diagnostic-3.jsonl',
  ];

  final String _directoryPath;
  final void Function() _ensureOwnership;
  final String Function(String filename) _checkedPath;
  final AppClock clock;
  final DiagnosticVersions versions;
  final Queue<_QueuedRecord> _queue = Queue<_QueuedRecord>();
  final List<_Segment> _segments = List<_Segment>.generate(
    diagnosticSegmentCount,
    (_) => _Segment(),
  );
  late final Random _random = Random.secure();

  bool _available = true;
  bool _closed = false;
  bool _closing = false;
  bool _maintenance = false;
  bool _snapshotting = false;
  bool _draining = false;
  bool _truncated = false;
  int _dropped = 0;
  int _invalid = 0;
  int _activeSegment = 0;
  int _sequence = 0;
  Future<void>? _drainFuture;
  Future<void>? _closeFuture;
  Future<void> _fileOperations = Future<void>.value();
  Completer<void>? _snapshotDone;

  static Future<DiagnosticJournal> open({
    required String directoryPath,
    required void Function() ensureOwnership,
    required String Function(String filename) checkedPath,
    AppClock clock = const SystemClock(),
    DiagnosticVersions versions = const DiagnosticVersions(),
  }) async {
    final journal = DiagnosticJournal._(
      directoryPath: directoryPath,
      ensureOwnership: ensureOwnership,
      checkedPath: checkedPath,
      clock: clock,
      versions: versions,
    );
    try {
      await journal._initialize();
    } catch (_) {
      journal._available = false;
    }
    return journal;
  }

  @override
  DiagnosticsView get diagnosticsView => DiagnosticsView(
    available: _available && !_closed,
    dropped: _dropped,
    invalid: _invalid,
  );

  @override
  DiagnosticTrace newTrace() {
    if (_closed) throw const DiagnosticsFailure(DiagnosticsFailureCode.closed);
    try {
      final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
      final value = bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      return DiagnosticTrace(value);
    } catch (_) {
      _available = false;
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    }
  }

  @override
  void record(DiagnosticEvent event) {
    if (_closed || _closing || _maintenance || !_available) {
      _dropped++;
      return;
    }
    if (_queue.length + (_draining ? 1 : 0) >= diagnosticQueueLimit) {
      _dropped++;
      return;
    }
    try {
      final record = DiagnosticRecord(
        atUtc: clock.nowUtc.toUtc(),
        event: event,
        sequence: _sequence++,
        versions: versions,
      );
      final encoded = record.encode();
      _queue.add(_QueuedRecord(record, encoded));
      _kickDrain();
    } catch (_) {
      _invalid++;
    }
  }

  @override
  Future<void> flush() async {
    if (_snapshotting) {
      await _snapshotDone?.future;
    }
    while (_queue.isNotEmpty || _draining) {
      _kickDrain();
      final pending = _drainFuture;
      if (pending == null) break;
      await pending;
    }
  }

  @override
  Future<String> exportRecent() {
    if (_closed || _closing) {
      return Future.error(
        const DiagnosticsFailure(DiagnosticsFailureCode.closed),
      );
    }
    return _serializeFileOperation(_exportRecent);
  }

  Future<String> _exportRecent() async {
    if (_closed) throw const DiagnosticsFailure(DiagnosticsFailureCode.closed);
    if (!_available) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    }
    await flush();
    if (!_available) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    }
    if (_snapshotting || _maintenance) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.exportFailed);
    }

    _snapshotting = true;
    _snapshotDone = Completer<void>();
    try {
      final now = clock.nowUtc.toUtc();
      await _sanitizeSegments(now);
      final records = <DiagnosticRecord>[];
      for (final segment in _segments) {
        records.addAll(segment.records);
      }
      records.sort((left, right) => left.sequence.compareTo(right.sequence));
      final recent = records.length <= diagnosticMaximumExportRecords
          ? records
          : records.sublist(records.length - diagnosticMaximumExportRecords);
      final exportedAt = clock.nowUtc.toUtc();
      return jsonEncode(<String, Object?>{
        'kind': 'ustc-diagnostics-export-v1',
        'exportedAtUtc': exportedAt.toIso8601String(),
        'retentionDays': diagnosticRetentionDays,
        'versions': versions.toSafeMap(),
        'coverage': 'retained_recent_events',
        'selectionTruncated': records.length > diagnosticMaximumExportRecords,
        'complete':
            _available &&
            _dropped == 0 &&
            _invalid == 0 &&
            !_truncated &&
            records.length <= diagnosticMaximumExportRecords &&
            _queue.isEmpty,
        'dropped': _dropped,
        'invalid': _invalid,
        'records': recent.map((record) => record.toMap()).toList(),
      });
    } on _JournalUnavailable {
      _available = false;
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    } catch (_) {
      _available = false;
      throw const DiagnosticsFailure(DiagnosticsFailureCode.exportFailed);
    } finally {
      _snapshotting = false;
      _snapshotDone?.complete();
      _snapshotDone = null;
      _kickDrain();
    }
  }

  @override
  Future<void> clear() {
    if (_closed || _closing) {
      return Future.error(
        const DiagnosticsFailure(DiagnosticsFailureCode.closed),
      );
    }
    return _serializeFileOperation(_clear);
  }

  Future<void> _clear() async {
    if (_closed) throw const DiagnosticsFailure(DiagnosticsFailureCode.closed);
    if (!_available) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    }
    if (_maintenance) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.exportFailed);
    }
    await flush();
    if (!_available) {
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    }
    _maintenance = true;
    final dropsAtStart = _dropped;
    try {
      for (final name in segmentNames) {
        final path = await _plainFilePath(name, allowMissing: true);
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await File(path).delete();
        }
      }
      final dropsDuringClear = _dropped - dropsAtStart;
      _queue.clear();
      for (final segment in _segments) {
        segment.reset();
      }
      _activeSegment = 0;
      _invalid = 0;
      _dropped = dropsDuringClear;
      _truncated = false;
      _maintenance = false;
      record(const DiagnosticEvent(name: DiagnosticEventName.logsCleared));
      await flush();
      if (!_available) {
        throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
      }
    } on DiagnosticsFailure {
      rethrow;
    } on _JournalUnavailable {
      _available = false;
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    } catch (_) {
      _available = false;
      throw const DiagnosticsFailure(DiagnosticsFailureCode.unavailable);
    } finally {
      _maintenance = false;
      _kickDrain();
    }
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final pending = _serializeFileOperation(_finishClose);
    _closeFuture = pending;
    return pending;
  }

  Future<T> _serializeFileOperation<T>(Future<T> Function() action) {
    final previous = _fileOperations;
    final done = Completer<void>();
    _fileOperations = done.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        done.complete();
      }
    }();
  }

  Future<void> _finishClose() async {
    try {
      await flush();
    } catch (_) {
      _available = false;
    } finally {
      _closed = true;
      _closing = false;
    }
  }

  Future<void> _initialize() async {
    _ensureOwner();
    if (!p.isAbsolute(_directoryPath) ||
        await FileSystemEntity.type(_directoryPath, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const _JournalUnavailable();
    }
    final now = clock.nowUtc.toUtc();
    await _sanitizeSegments(now);

    int newestSequence = -1;
    for (var index = 0; index < _segments.length; index++) {
      final segment = _segments[index];
      for (final record in segment.records) {
        if (record.sequence >= newestSequence) {
          newestSequence = record.sequence;
          _activeSegment = index;
        }
      }
    }
    if (_segments.every((segment) => segment.records.isNotEmpty)) {
      // At capacity we cannot prove that earlier diagnostic rows were kept.
      _truncated = true;
    }
    for (final segment in _segments) {
      for (final record in segment.records) {
        if (record.sequence >= _sequence) _sequence = record.sequence + 1;
      }
    }
  }

  void _ensureOwner() {
    try {
      _ensureOwnership();
    } catch (_) {
      throw const _JournalUnavailable();
    }
  }

  Future<String> _plainFilePath(
    String filename, {
    required bool allowMissing,
  }) async {
    if (!segmentNames.contains(filename)) throw const _JournalUnavailable();
    _ensureOwner();
    late final String returned;
    try {
      returned = _checkedPath(filename);
    } catch (_) {
      throw const _JournalUnavailable();
    }
    final path = p.normalize(p.absolute(returned));
    if (!p.equals(p.dirname(path), _directoryPath) ||
        !p.equals(p.basename(path), filename)) {
      throw const _JournalUnavailable();
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound && allowMissing) return path;
    if (type != FileSystemEntityType.file) throw const _JournalUnavailable();
    return path;
  }

  Future<void> _sanitizeSegments(DateTime nowUtc) async {
    final cutoff = nowUtc.subtract(
      const Duration(days: diagnosticRetentionDays),
    );
    final mtimes = <DateTime?>[];
    for (var index = 0; index < segmentNames.length; index++) {
      final name = segmentNames[index];
      final path = await _plainFilePath(name, allowMissing: true);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        _segments[index].reset();
        mtimes.add(null);
        continue;
      }

      final modified = (await FileStat.stat(path)).modified;
      mtimes.add(modified);
      final opened = await File(path).open(mode: FileMode.read);
      late final List<int> bytes;
      try {
        final length = await opened.length();
        if (length > diagnosticSegmentBytes) {
          _invalid++;
          _segments[index].reset(existed: true, modified: modified);
          await _writeSegment(index);
          continue;
        }
        bytes = await opened.read(diagnosticSegmentBytes + 1);
      } finally {
        await opened.close();
      }
      if (bytes.length > diagnosticSegmentBytes) {
        _invalid++;
        _segments[index].reset(existed: true, modified: modified);
        await _writeSegment(index);
        continue;
      }

      if (bytes.isEmpty) {
        _segments[index].reset(existed: true, modified: modified);
        continue;
      }

      final source = utf8.decode(bytes, allowMalformed: true);
      final terminated = source.endsWith('\n');
      final lines = source.split('\n');
      final valid = <DiagnosticRecord>[];
      final canonical = <String>[];
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        final line = lines[lineIndex];
        final isLast = lineIndex == lines.length - 1;
        if (isLast && line.isEmpty && terminated) continue;
        if (line.isEmpty || isLast && !terminated) {
          _invalid++;
          continue;
        }
        try {
          final record = DiagnosticRecord.decode(line);
          if (record.atUtc.isAfter(nowUtc.add(const Duration(minutes: 5)))) {
            _invalid++;
            continue;
          }
          if (record.atUtc.isBefore(cutoff)) continue;
          final normalized = record.encode();
          valid.add(record);
          canonical.add(normalized);
        } catch (_) {
          _invalid++;
        }
      }
      final segment = _segments[index];
      segment
        ..records = valid
        ..encoded = canonical
        ..bytes = _encodedBytes(canonical)
        ..exists = true
        ..modified = modified;
      final normalizedText = _segmentText(canonical);
      if (normalizedText != source) {
        await _writeSegment(index);
      }
    }
    for (var index = 0; index < _segments.length; index++) {
      _segments[index].modified ??= mtimes[index];
    }
  }

  void _kickDrain() {
    if (_draining ||
        _snapshotting ||
        _maintenance ||
        _closed ||
        !_available ||
        _queue.isEmpty) {
      return;
    }
    _draining = true;
    _drainFuture = _drain();
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && _available && !_closed && !_maintenance) {
        final item = _queue.removeFirst();
        try {
          await _append(item);
        } catch (_) {
          _available = false;
          _dropped += 1 + _queue.length;
          _queue.clear();
          break;
        }
      }
    } finally {
      _draining = false;
      _drainFuture = null;
      _kickDrain();
    }
  }

  Future<void> _append(_QueuedRecord item) async {
    final now = clock.nowUtc.toUtc();
    if (item.record.atUtc.isBefore(
      now.subtract(const Duration(days: diagnosticRetentionDays)),
    )) {
      _dropped++;
      return;
    }
    await _pruneExpired(now);
    final lineBytes = utf8.encode(item.encoded).length + 1;
    var target = _activeSegment;
    if (_segments[target].bytes + lineBytes > diagnosticSegmentBytes) {
      target = (target + 1) % diagnosticSegmentCount;
      if (_segments[target].records.isNotEmpty) _truncated = true;
      _segments[target].reset(existed: _segments[target].exists);
      await _writeSegment(target);
      _activeSegment = target;
    }
    final path = await _plainFilePath(segmentNames[target], allowMissing: true);
    final file = File(path);
    final handle = await file.open(mode: FileMode.append);
    try {
      final currentLength = await handle.length();
      if (currentLength + lineBytes > diagnosticSegmentBytes) {
        throw const _JournalUnavailable();
      }
      await handle.writeString('${item.encoded}\n', encoding: utf8);
      await handle.flush();
    } finally {
      await handle.close();
    }
    final segment = _segments[target];
    segment
      ..records.add(item.record)
      ..encoded.add(item.encoded)
      ..bytes += lineBytes
      ..exists = true;
    _activeSegment = target;
  }

  Future<void> _pruneExpired(DateTime nowUtc) async {
    final cutoff = nowUtc.subtract(
      const Duration(days: diagnosticRetentionDays),
    );
    for (var index = 0; index < _segments.length; index++) {
      final segment = _segments[index];
      final keep = <DiagnosticRecord>[];
      final encoded = <String>[];
      for (var itemIndex = 0; itemIndex < segment.records.length; itemIndex++) {
        final record = segment.records[itemIndex];
        if (record.atUtc.isBefore(cutoff)) continue;
        keep.add(record);
        encoded.add(segment.encoded[itemIndex]);
      }
      if (keep.length == segment.records.length) continue;
      segment
        ..records = keep
        ..encoded = encoded
        ..bytes = _encodedBytes(encoded);
      await _writeSegment(index);
    }
  }

  Future<void> _writeSegment(int index) async {
    final segment = _segments[index];
    final text = _segmentText(segment.encoded);
    if (utf8.encode(text).length > diagnosticSegmentBytes) {
      throw const _JournalUnavailable();
    }
    final path = await _plainFilePath(segmentNames[index], allowMissing: true);
    await File(path).writeAsString(text, encoding: utf8, flush: true);
    segment
      ..bytes = utf8.encode(text).length
      ..exists = true
      ..modified = DateTime.now();
  }

  static String _segmentText(List<String> lines) =>
      lines.isEmpty ? '' : '${lines.join('\n')}\n';

  static int _encodedBytes(List<String> lines) => lines.isEmpty
      ? 0
      : lines.fold<int>(0, (sum, line) => sum + utf8.encode(line).length + 1);
}

final class _QueuedRecord {
  const _QueuedRecord(this.record, this.encoded);
  final DiagnosticRecord record;
  final String encoded;
}

final class _Segment {
  List<DiagnosticRecord> records = <DiagnosticRecord>[];
  List<String> encoded = <String>[];
  int bytes = 0;
  bool exists = false;
  DateTime? modified;

  void reset({bool existed = false, DateTime? modified}) {
    records = <DiagnosticRecord>[];
    encoded = <String>[];
    bytes = 0;
    exists = existed;
    this.modified = modified;
  }
}

final class _JournalUnavailable implements Exception {
  const _JournalUnavailable();
}
