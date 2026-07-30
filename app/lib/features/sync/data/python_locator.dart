import 'dart:convert';
import 'dart:io';

import 'bridge_client.dart';

class PythonLocationError implements Exception {
  const PythonLocationError(this.code);

  final String code;
}

class ProcessResultValue {
  const ProcessResultValue({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class PythonCommandRunner {
  Future<ProcessResultValue> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  });
}

class IoPythonCommandRunner implements PythonCommandRunner {
  const IoPythonCommandRunner();

  @override
  Future<ProcessResultValue> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }
  ) async {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: false,
      environment: environment,
    );
    return ProcessResultValue(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}

class PythonLocator {
  PythonLocator({
    this.runner = const IoPythonCommandRunner(),
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final PythonCommandRunner runner;
  final Map<String, String> environment;

  Future<String> locate({
    String? savedExecutable,
    String requiredModule = 'ustc_assistant.bridge',
    Map<String, String>? importEnvironment,
  }) async {
    final probeEnvironment = importEnvironment ?? environment;
    final candidates = <String>[];
    if (savedExecutable != null && savedExecutable.trim().isNotEmpty) {
      candidates.add(savedExecutable.trim());
    }
    final condaPrefix = environment['CONDA_PREFIX'];
    final condaName = environment['CONDA_DEFAULT_ENV'];
    if (condaPrefix != null && condaName == 'ustc_assistant') {
      candidates.add(
        Platform.isWindows
            ? '$condaPrefix${Platform.pathSeparator}python.exe'
            : '$condaPrefix${Platform.pathSeparator}bin${Platform.pathSeparator}python',
      );
    }
    for (final candidate in candidates.toSet()) {
      if (await _canImport(candidate, requiredModule, probeEnvironment)) {
        return candidate;
      }
    }
    final resolved = await runner.run('conda', const [
      'run',
      '-n',
      'ustc_assistant',
      'python',
      '-c',
      'import sys; print(sys.executable)',
    ]);
    if (resolved.exitCode != 0) {
      throw const PythonLocationError('conda_resolution_failed');
    }
    final path = resolved.stdout.trim().split(RegExp(r'\r?\n')).last.trim();
    if (path.isEmpty || !await _canImport(path, requiredModule, probeEnvironment)) {
      throw const PythonLocationError('bridge_import_failed');
    }
    return path;
  }

  Future<bool> _canImport(
    String executable,
    String requiredModule,
    Map<String, String> environment,
  ) async {
    final result = await runner.run(executable, [
      '-c',
      'import importlib; importlib.import_module(${jsonEncode(requiredModule)})',
    ], environment: environment);
    return result.exitCode == 0;
  }
}

/// Finds a source worktree from an explicit start directory, including the
/// normal Windows application start directory at `<worktree>/app`.
Directory? findBridgeDevelopmentRoot(Directory startDirectory) {
  var current = startDirectory.absolute;
  while (true) {
    final queryJobs = File(
      '${current.path}${Platform.pathSeparator}src${Platform.pathSeparator}'
      'ustc_assistant${Platform.pathSeparator}bridge${Platform.pathSeparator}'
      'query_jobs.py',
    );
    if (queryJobs.existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) return null;
    current = parent;
  }
}

/// Supplies the Bridge with explicit source and writable data roots without
/// relying on the process current directory.
BridgeLaunchOptions resolveBridgeLaunchOptions({
  Directory? startDirectory,
  Map<String, String>? environment,
}) {
  final resolvedEnvironment = Map<String, String>.from(
    environment ?? Platform.environment,
  );
  final worktreeRoot = findBridgeDevelopmentRoot(
    startDirectory ?? Directory.current,
  );
  if (worktreeRoot != null) {
    final sourceRoot = '${worktreeRoot.path}${Platform.pathSeparator}src';
    final dataRoot = Directory(
      '${worktreeRoot.path}${Platform.pathSeparator}tmp'
      '${Platform.pathSeparator}bridge-data',
    );
    dataRoot.createSync(recursive: true);
    final existingPythonPath = resolvedEnvironment['PYTHONPATH'];
    final separator = Platform.isWindows ? ';' : ':';
    resolvedEnvironment['PYTHONPATH'] = existingPythonPath == null ||
            existingPythonPath.isEmpty
        ? sourceRoot
        : '$sourceRoot$separator$existingPythonPath';
    resolvedEnvironment['USTC_ASSISTANT_SOURCE_ROOT'] = worktreeRoot.path;
    resolvedEnvironment['USTC_ASSISTANT_DATA_ROOT'] = dataRoot.path;
    return BridgeLaunchOptions(
      workingDirectory: worktreeRoot.path,
      environment: resolvedEnvironment,
    );
  }

  final appData = resolvedEnvironment['LOCALAPPDATA'] ??
      resolvedEnvironment['APPDATA'] ??
      Directory.systemTemp.path;
  final dataRoot = Directory(
    '$appData${Platform.pathSeparator}USTC Campus Assistant',
  );
  dataRoot.createSync(recursive: true);
  resolvedEnvironment['USTC_ASSISTANT_DATA_ROOT'] = dataRoot.path;
  return BridgeLaunchOptions(
    workingDirectory: dataRoot.path,
    environment: resolvedEnvironment,
  );
}
