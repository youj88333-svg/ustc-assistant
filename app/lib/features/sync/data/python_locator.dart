import 'dart:io';

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
  Future<ProcessResultValue> run(String executable, List<String> arguments);
}

class IoPythonCommandRunner implements PythonCommandRunner {
  const IoPythonCommandRunner();

  @override
  Future<ProcessResultValue> run(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments, runInShell: false);
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

  Future<String> locate({String? savedExecutable}) async {
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
      if (await _canImport(candidate)) return candidate;
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
    if (path.isEmpty || !await _canImport(path)) {
      throw const PythonLocationError('bridge_import_failed');
    }
    return path;
  }

  Future<bool> _canImport(String executable) async {
    final result = await runner.run(executable, const [
      '-c',
      'import ustc_assistant.bridge',
    ]);
    return result.exitCode == 0;
  }
}
