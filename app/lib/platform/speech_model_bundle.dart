import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../core/speech_input_contract.dart';

const speechModelVersion = 'sensevoice-int8-2024-07-17';
const speechModelArchiveSha256 =
    '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e';
const speechModelSha256 =
    'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51';
const speechTokensSha256 =
    'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc';

/// Installed, public application assets; not user recordings or C3 data.
final class SpeechModelBundle {
  SpeechModelBundle({String? executableDirectory})
    : executableDirectory = p.normalize(
        p.absolute(
          executableDirectory ?? p.dirname(Platform.resolvedExecutable),
        ),
      ),
      androidAssets = false;
  SpeechModelBundle.android({required String directory})
    : executableDirectory = p.posix.normalize(p.posix.absolute(directory)),
      androidAssets = true;
  final String executableDirectory;
  final bool androidAssets;
  String get modelDirectory => androidAssets
      ? executableDirectory
      : p.join(executableDirectory, 'data', 'speech', 'sensevoice');
  String get libraryPath =>
      p.join(executableDirectory, 'sherpa-onnx-c-api.dll');
  String get modelPath => (androidAssets ? p.posix : p.context).join(
    modelDirectory,
    'model.int8.onnx',
  );
  String get tokensPath =>
      (androidAssets ? p.posix : p.context).join(modelDirectory, 'tokens.txt');

  Future<void> validate() async {
    if (androidAssets ? !Platform.isAndroid : !Platform.isWindows) {
      throw const SpeechInputFailure(
        SpeechInputFailureCode.unsupportedPlatform,
      );
    }
    try {
      await _plain(executableDirectory, directory: true);
      for (final directory
          in androidAssets
              ? <String>[]
              : [
                  p.join(executableDirectory, 'data'),
                  p.join(executableDirectory, 'data', 'speech'),
                  modelDirectory,
                ]) {
        await _plain(directory, directory: true);
      }
      for (final library
          in androidAssets
              ? <String>[]
              : [libraryPath, p.join(executableDirectory, 'onnxruntime.dll')]) {
        await _plain(library, directory: false);
        final size = await File(library).length();
        if (size == 0 || size > 100 * 1024 * 1024) {
          throw const FormatException('speech_library');
        }
      }
      await _verify(modelPath, 239233841, speechModelSha256);
      await _verify(tokensPath, 315894, speechTokensSha256);
    } catch (_) {
      throw const SpeechInputFailure(SpeechInputFailureCode.modelUnavailable);
    }
  }

  Future<void> _verify(String path, int size, String digest) async {
    await _plain(path, directory: false);
    final file = File(path);
    if (await file.length() != size ||
        (await sha256.bind(file.openRead()).first).toString() != digest) {
      throw const FormatException('speech_asset');
    }
    await _plain(path, directory: false);
  }

  Future<void> _plain(String path, {required bool directory}) async {
    final canonical = p.normalize(p.absolute(path));
    if (!p.isWithin(executableDirectory, canonical) &&
        !p.equals(canonical, executableDirectory)) {
      throw const FormatException('speech_asset_path');
    }
    if (canonical.startsWith(r'\\') ||
        canonical.contains(':', 2) ||
        await FileSystemEntity.type(canonical, followLinks: false) !=
            (directory
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file) ||
        !p.equals(
          canonical,
          p.normalize(
            await (directory ? Directory(canonical) : File(canonical))
                .resolveSymbolicLinks(),
          ),
        )) {
      throw const FormatException('speech_asset_path');
    }
    if (androidAssets) return;
    final attributes = _attributes(canonical);
    if (attributes == null ||
        attributes & (0x400 | 0x40) != 0 ||
        (attributes & 0x10 != 0) != directory) {
      throw const FormatException('speech_asset_path');
    }
  }
}

int? _attributes(String path) {
  final getAttributes = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');
  final nativePath = path.toNativeUtf16();
  try {
    final value = getAttributes(nativePath);
    return value == 0xffffffff ? null : value;
  } finally {
    malloc.free(nativePath);
  }
}
