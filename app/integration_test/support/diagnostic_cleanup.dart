import 'dart:io';

import 'package:path/path.dart' as p;

const _diagnosticSegmentNames = <String>{
  'diagnostic-0.jsonl',
  'diagnostic-1.jsonl',
  'diagnostic-2.jsonl',
  'diagnostic-3.jsonl',
};
const _maximumDiagnosticSegmentBytes = 256 * 1024;

/// Validates only the fixed diagnostic segments in a fixture-owned formal
/// directory. It never reads file contents or follows directory entries.
Future<void> assertKnownFormalDiagnosticsDirectory(Directory formalRoot) async {
  final formalPath = _normal(formalRoot.path);
  if (await FileSystemEntity.type(formalPath, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.windows.equals(
        formalPath,
        _normal(await formalRoot.resolveSymbolicLinks()),
      )) {
    throw StateError('The owned formal root changed during cleanup.');
  }

  final diagnosticsPath = _normal(p.windows.join(formalPath, 'diagnostics'));
  if (!p.windows.equals(p.windows.dirname(diagnosticsPath), formalPath) ||
      !p.windows.equals(p.windows.basename(diagnosticsPath), 'diagnostics') ||
      await FileSystemEntity.type(diagnosticsPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError(
      'The formal diagnostics directory is not a plain directory.',
    );
  }
  final diagnostics = Directory(diagnosticsPath);
  if (!p.windows.equals(
    diagnosticsPath,
    _normal(await diagnostics.resolveSymbolicLinks()),
  )) {
    throw StateError(
      'The formal diagnostics directory changed during cleanup.',
    );
  }

  await for (final entry in diagnostics.list(followLinks: false)) {
    final path = _normal(entry.path);
    final name = p.windows.basename(path);
    if (!p.windows.equals(p.windows.dirname(path), diagnosticsPath) ||
        !p.windows.isWithin(diagnosticsPath, path) ||
        !_diagnosticSegmentNames.contains(name) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw StateError(
        'The formal diagnostics directory contains an unknown entry.',
      );
    }

    final file = File(path);
    if (!p.windows.equals(path, _normal(await file.resolveSymbolicLinks()))) {
      throw StateError('A formal diagnostics segment is linked.');
    }
    final length = await file.length();
    if (length > _maximumDiagnosticSegmentBytes ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.windows.equals(path, _normal(await file.resolveSymbolicLinks())) ||
        await file.length() > _maximumDiagnosticSegmentBytes ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.windows.equals(path, _normal(await file.resolveSymbolicLinks()))) {
      throw StateError(
        'A formal diagnostics segment is not a bounded plain file.',
      );
    }
  }

  if (await FileSystemEntity.type(diagnosticsPath, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.windows.equals(
        diagnosticsPath,
        _normal(await diagnostics.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(formalPath, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.windows.equals(
        formalPath,
        _normal(await formalRoot.resolveSymbolicLinks()),
      )) {
    throw StateError(
      'The owned formal diagnostics path changed during cleanup.',
    );
  }
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));
