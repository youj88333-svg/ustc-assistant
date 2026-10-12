import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets ||
        input.config.code.targetOS != OS.windows) {
      return;
    }
    final compilerInput = input.config.code.cCompiler == null
        ? await _withWindowsCompiler(input, output)
        : input;
    await CBuilder.library(
      name: 'ustc_directory_win',
      assetName: 'platform/demo_directory.dart',
      sources: ['native/directory_win.c'],
      libraries: ['kernel32'],
      linkModePreference: LinkModePreference.dynamic,
    ).run(input: compilerInput, output: output);
  });
}

Future<BuildInput> _withWindowsCompiler(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  if (!Platform.isWindows) {
    throw StateError('Windows C toolchain requires a Windows build host');
  }
  final programFiles =
      Platform.environment['ProgramFiles(x86)'] ??
      '${Platform.environment['SYSTEMDRIVE'] ?? 'C:'}/Program Files (x86)';
  final locator = File(
    '$programFiles/Microsoft Visual Studio/Installer/vswhere.exe',
  );
  if (!await locator.exists()) {
    throw StateError('Visual Studio locator is unavailable');
  }
  // Read the scalar installation path with the encoding explicitly requested
  // from vswhere. Localized Description JSON is unnecessary for this build.
  final result = await Process.run(
    locator.path,
    [
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
      '-utf8',
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final installation = (result.stdout as String)
      .replaceAll('\uFEFF', '')
      .trim();
  if (result.exitCode != 0 ||
      installation.isEmpty ||
      installation.contains('\n') ||
      installation.contains('\r')) {
    throw StateError('Visual Studio C toolchain discovery failed');
  }
  final root = Directory(installation).uri;
  final versionFile = File.fromUri(
    root.resolve('VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'),
  );
  final version = (await versionFile.readAsString()).trim();
  if (!RegExp(r'^\d+(\.\d+){1,3}$').hasMatch(version)) {
    throw StateError('Visual Studio C toolchain version is invalid');
  }
  final target = switch (input.config.code.targetArchitecture) {
    Architecture.x64 => 'x64',
    Architecture.ia32 => 'x86',
    Architecture.arm64 => 'arm64',
    _ => throw StateError('Unsupported Windows C target architecture'),
  };
  final host = Architecture.current == Architecture.ia32 ? 'x86' : 'x64';
  final binaries = root.resolve(
    'VC/Tools/MSVC/$version/bin/Host$host/$target/',
  );
  final compiler = binaries.resolve('cl.exe');
  final linker = binaries.resolve('link.exe');
  final archiver = binaries.resolve('lib.exe');
  final script = root.resolve('VC/Auxiliary/Build/vcvarsall.bat');
  for (final file in [compiler, linker, archiver, script]) {
    if (!await File.fromUri(file).exists()) {
      throw StateError('Visual Studio C toolchain is incomplete');
    }
  }
  output.dependencies.addAll([
    locator.uri,
    versionFile.uri,
    compiler,
    linker,
    archiver,
    script,
  ]);
  final builder = BuildInputBuilder();
  // Preserve package/output/asset metadata and override only this builder's
  // toolchain configuration, leaving the launcher's input untouched.
  builder.json.addAll(
    jsonDecode(jsonEncode(input.json)) as Map<String, Object?>,
  );
  CodeAssetExtension(
    targetArchitecture: input.config.code.targetArchitecture,
    targetOS: input.config.code.targetOS,
    linkModePreference: input.config.code.linkModePreference,
    sanitizer: input.config.code.sanitizer,
    cCompiler: CCompilerConfig(
      compiler: compiler,
      linker: linker,
      archiver: archiver,
      windows: WindowsCCompilerConfig(
        developerCommandPrompt: DeveloperCommandPrompt(
          script: script,
          arguments: [
            host == target ? host : '${host}_$target',
            '-vcvars_ver=$version',
          ],
        ),
      ),
    ),
  ).setupBuildInput(builder);
  return builder.build();
}
