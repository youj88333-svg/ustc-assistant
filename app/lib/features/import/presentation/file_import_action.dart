import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../../accounts/application/account_service.dart';
import '../data/source_bundle_decoder.dart';
import '../domain/import_result.dart';

class ImportFileCandidate {
  const ImportFileCandidate({
    required this.name,
    required this.length,
    required this.readBytes,
  });

  final String name;
  final int length;
  final Future<Uint8List> Function() readBytes;
}

abstract interface class ImportFilePicker {
  Future<ImportFileCandidate?> pickJson();
}

class SystemImportFilePicker implements ImportFilePicker {
  const SystemImportFilePicker();

  @override
  Future<ImportFileCandidate?> pickJson() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SourceBundle JSON', extensions: ['json']),
      ],
    );
    if (file == null) return null;
    return ImportFileCandidate(
      name: file.name,
      length: await file.length(),
      readBytes: file.readAsBytes,
    );
  }
}

typedef TargetAccountConfirmer =
    Future<String?> Function(
      List<AccountSummary> accounts,
      String? preselectedAccountId,
    );
typedef FileBundleImporter =
    Future<ImportResult> Function(
      Uint8List bytes, {
      required String accountId,
      required ImportOrigin origin,
    });

sealed class FileImportOutcome {
  const FileImportOutcome();
}

class FileImportCancelled extends FileImportOutcome {
  const FileImportCancelled();
}

class FileImportRejected extends FileImportOutcome {
  const FileImportRejected(this.code);

  final String code;
}

class FileImportCompleted extends FileImportOutcome {
  const FileImportCompleted(this.result);

  final ImportResult result;
}

class FileImportAction {
  const FileImportAction({
    required this.accounts,
    required this.picker,
    required this.confirmTarget,
    required this.importBundle,
  });

  final AccountService accounts;
  final ImportFilePicker picker;
  final TargetAccountConfirmer confirmTarget;
  final FileBundleImporter importBundle;

  Future<FileImportOutcome> run() async {
    final candidate = await picker.pickJson();
    if (candidate == null) return const FileImportCancelled();
    if (candidate.length > SourceBundleDecoder.maxBundleBytes) {
      return const FileImportRejected('limit_exceeded');
    }
    final summaries = await accounts.summaries();
    if (summaries.isEmpty) {
      return const FileImportRejected('no_account');
    }
    final preselected = summaries.where((item) => item.active).firstOrNull?.id;
    final target = await confirmTarget(summaries, preselected);
    if (target == null) return const FileImportCancelled();
    if (!summaries.any((item) => item.id == target)) {
      return const FileImportRejected('account_not_found');
    }
    final bytes = await candidate.readBytes();
    if (bytes.length > SourceBundleDecoder.maxBundleBytes) {
      return const FileImportRejected('limit_exceeded');
    }
    final result = await importBundle(
      bytes,
      accountId: target,
      origin: ImportOrigin.file,
    );
    return FileImportCompleted(result);
  }
}
