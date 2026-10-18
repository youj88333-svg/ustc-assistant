import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/diagnostics_contract.dart';
import '../platform/android_file_access.dart';
import 'app_design.dart';

typedef DiagnosticLogSaver = Future<bool> Function(String contents);

/// Settings surface for local diagnostics. It only reads health counters and
/// delegates the closed export bundle to the user's chosen save location.
final class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({super.key, required this.diagnostics, this.save});

  final DiagnosticsPort diagnostics;
  final DiagnosticLogSaver? save;

  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

final class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  late DiagnosticsView _view = _readView(widget.diagnostics);
  int _generation = 0;
  bool _refreshing = false;
  bool _clearing = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant DiagnosticsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.diagnostics, widget.diagnostics)) {
      _generation++;
      _view = _readView(widget.diagnostics);
      _refreshing = false;
      _clearing = false;
      _notice = null;
      _scheduleRefresh();
    }
  }

  bool _isCurrent(DiagnosticsPort port, int generation) =>
      mounted &&
      identical(widget.diagnostics, port) &&
      _generation == generation;

  void _scheduleRefresh() {
    final port = widget.diagnostics;
    final generation = _generation;
    Future<void>.microtask(() async {
      if (_isCurrent(port, generation)) {
        await _refresh(port, generation);
      }
    });
  }

  Future<void> _refresh(
    DiagnosticsPort port,
    int generation, {
    bool showBusy = false,
  }) async {
    if (!_isCurrent(port, generation)) return;
    if (showBusy) {
      setState(() {
        _refreshing = true;
        _notice = null;
      });
    }
    var failed = false;
    try {
      await port.flush();
    } on Object {
      failed = true;
    }
    if (!_isCurrent(port, generation)) return;
    setState(() {
      _view = _readView(port);
      _refreshing = false;
      _notice = failed ? '日志状态刷新失败。' : null;
    });
  }

  Future<void> _confirmAndClear() async {
    if (_clearing) return;
    final port = widget.diagnostics;
    final generation = _generation;
    final first = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('diagnostics-clear-confirmation-first'),
        title: const Text('清除诊断日志？'),
        content: const Text('这只会清除最近的本地诊断日志，不会删除日程、任务、Agent 历史或凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('继续确认'),
          ),
        ],
      ),
    );
    if (!mounted ||
        !identical(widget.diagnostics, port) ||
        _generation != generation ||
        first != true) {
      return;
    }

    final second = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('diagnostics-clear-confirmation-final'),
        title: const Text('再次确认清除诊断日志'),
        content: const Text('清除后无法恢复。操作范围仍只有诊断日志，不影响业务记录、Agent 历史或凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('清除诊断日志'),
          ),
        ],
      ),
    );
    if (!_isCurrent(port, generation) || second != true) return;

    setState(() {
      _clearing = true;
      _notice = null;
    });
    try {
      await port.clear();
      if (!_isCurrent(port, generation)) return;
      setState(() {
        _view = _readView(port);
        _clearing = false;
      });
      _showMessage('诊断日志已清除。');
    } on Object {
      if (!_isCurrent(port, generation)) return;
      setState(() {
        _view = _readView(port);
        _clearing = false;
        _notice = '未能清除诊断日志，请稍后重试。';
      });
    } finally {
      if (_isCurrent(port, generation) && _clearing) {
        setState(() => _clearing = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => WorkspaceSection(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('本地诊断日志', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('日志只保存在本地，最近 7 天最多 4 段、每段 256 KiB（合计 1 MiB）；每次导出最多 1000 条。'),
        const SizedBox(height: 6),
        const Text(
          '内容限于固定事件、阶段、工具类别、结果、错误码、计数和耗时等安全字段；不含账号、密码、模型 Key 或私人对话正文。不会自动上传。',
        ),
        const SizedBox(height: 12),
        Semantics(
          key: const ValueKey('diagnostics-health'),
          label:
              '日志${_view.available ? '可用' : '不可用'}，丢弃 ${_view.dropped} 条，非法 ${_view.invalid} 条',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('状态：${_view.available ? '可用' : '不可用'}'),
              const SizedBox(height: 4),
              Text('丢弃记录：${_view.dropped}　非法记录：${_view.invalid}'),
            ],
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(
            _notice!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DiagnosticsExportButton(
              diagnostics: widget.diagnostics,
              save: widget.save,
            ),
            OutlinedButton.icon(
              key: const ValueKey('diagnostics-refresh-button'),
              onPressed: _refreshing || _clearing
                  ? null
                  : () => _refresh(
                      widget.diagnostics,
                      _generation,
                      showBusy: true,
                    ),
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: const Text('刷新状态'),
            ),
            TextButton.icon(
              key: const ValueKey('diagnostics-clear-button'),
              onPressed: _clearing || _refreshing ? null : _confirmAndClear,
              icon: _clearing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline_rounded),
              label: const Text('清除诊断日志'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Compact export action for an Agent error notice.
final class DiagnosticsExportButton extends StatefulWidget {
  const DiagnosticsExportButton({
    super.key,
    required this.diagnostics,
    this.save,
  });

  final DiagnosticsPort diagnostics;
  final DiagnosticLogSaver? save;

  @override
  State<DiagnosticsExportButton> createState() =>
      _DiagnosticsExportButtonState();
}

final class _DiagnosticsExportButtonState
    extends State<DiagnosticsExportButton> {
  int _generation = 0;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant DiagnosticsExportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.diagnostics, widget.diagnostics) ||
        oldWidget.save != widget.save) {
      _generation++;
      _busy = false;
    }
  }

  bool _isCurrent(DiagnosticsPort port, int generation) =>
      mounted &&
      identical(widget.diagnostics, port) &&
      _generation == generation;

  Future<void> _export() async {
    if (_busy) return;
    final port = widget.diagnostics;
    final saver = widget.save ?? saveDiagnosticLog;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      await port.flush();
      if (!_isCurrent(port, generation)) return;
      final contents = await port.exportRecent();
      if (!_isCurrent(port, generation)) return;
      final saved = await saver(contents);
      if (saved) {
        try {
          port.record(
            const DiagnosticEvent(
              name: DiagnosticEventName.logsExported,
              stage: DiagnosticStage.export,
              outcome: DiagnosticOutcome.complete,
            ),
          );
        } on Object {
          // Export success remains true even if best-effort logging fails.
        }
        if (!_isCurrent(port, generation)) return;
        _showMessage('日志已导出，请自行发送给维护者。');
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        _showMessage('未能导出日志，请稍后重试。');
      }
    } finally {
      if (_isCurrent(port, generation)) {
        setState(() => _busy = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('diagnostics-export-button'),
    onPressed: _busy ? null : _export,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    icon: _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.download_rounded, size: 18),
    label: Text(_busy ? '正在导出…' : '导出日志'),
  );
}

Future<bool> saveDiagnosticLog(String contents) async {
  if (Platform.isAndroid) {
    return const AndroidFileAccess().saveDiagnosticLog(contents);
  }
  final location = await getSaveLocation(
    suggestedName: 'USTC-Assistant-diagnostics.json',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ],
  );
  if (location == null) return false;
  if (!await isPlainDiagnosticLogTarget(location.path)) {
    throw const _DiagnosticSaveFailure();
  }

  await XFile.fromData(
    utf8.encode(contents),
    mimeType: 'application/json',
    name: p.basename(location.path),
  ).saveTo(location.path);
  return true;
}

@visibleForTesting
Future<bool> isPlainDiagnosticLogTarget(String selectedPath) async {
  if (selectedPath.isEmpty || !p.isAbsolute(selectedPath)) return false;
  final target = p.normalize(selectedPath);
  if (p.extension(target).toLowerCase() != '.json') return false;
  if (Platform.isWindows && !_isOrdinaryWindowsPath(target)) return false;

  var parent = p.dirname(target);
  while (true) {
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    if (Platform.isWindows) {
      final attributes = _windowsFileAttributes(parent);
      if (attributes == null ||
          attributes & _fileAttributeReparsePoint != 0 ||
          attributes & _fileAttributeDirectory == 0 ||
          attributes & _fileAttributeDevice != 0) {
        return false;
      }
    }
    final next = p.dirname(parent);
    if (next == parent) break;
    parent = next;
  }

  final type = await FileSystemEntity.type(target, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    final attributes = Platform.isWindows
        ? _windowsFileAttributes(target)
        : null;
    return attributes == null ||
        attributes & _fileAttributeReparsePoint == 0 &&
            attributes & _fileAttributeDirectory == 0 &&
            attributes & _fileAttributeDevice == 0;
  }
  if (type != FileSystemEntityType.file) return false;
  if (!Platform.isWindows) return true;
  final attributes = _windowsFileAttributes(target);
  return attributes != null &&
      attributes & _fileAttributeReparsePoint == 0 &&
      attributes & _fileAttributeDirectory == 0 &&
      attributes & _fileAttributeDevice == 0;
}

const _fileAttributeDirectory = 0x10;
const _fileAttributeDevice = 0x40;
const _fileAttributeReparsePoint = 0x400;

int? _windowsFileAttributes(String path) {
  if (!Platform.isWindows) return null;
  final library = DynamicLibrary.open('kernel32.dll');
  final getFileAttributes = library
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');
  final nativePath = path.toNativeUtf16();
  try {
    final attributes = getFileAttributes(nativePath);
    return attributes == 0xffffffff ? null : attributes;
  } finally {
    malloc.free(nativePath);
  }
}

bool _isOrdinaryWindowsPath(String path) {
  final normalized = p.windows.normalize(path);
  if (normalized.startsWith('\\\\?\\') || normalized.startsWith('\\\\.\\')) {
    return false;
  }
  final basename = p.windows.basename(normalized);
  final stem = basename.split('.').first.trim().toLowerCase();
  return !const {
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  }.contains(stem);
}

DiagnosticsView _readView(DiagnosticsPort port) {
  try {
    return port.diagnosticsView;
  } on Object {
    return const DiagnosticsView(available: false);
  }
}

final class _DiagnosticSaveFailure implements Exception {
  const _DiagnosticSaveFailure();
}
