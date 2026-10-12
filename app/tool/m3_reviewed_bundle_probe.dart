import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/data/bundled_knowledge_identity.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/knowledge_markdown.dart';
import 'package:ustc_assistant_m0/data/knowledge_service.dart';
import 'package:ustc_assistant_m0/platform/bundled_knowledge_loader.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

const _optIn = bool.fromEnvironment('USTC_M3_REVIEWED_BUNDLE_PROBE');
const _kind = 'm3-reviewed-bundle-v1';
const _temporaryPrefix = 'ustc_m3_reviewed_bundle_';
const _readLimit = 12000;
const _maximumReadPages = 256;

const _shortTermMaterialKeys = <String, List<String>>{
  '缓考': ['teach-deferred-exam'],
  '证明': ['teach-certificates', 'teach-deferred-exam'],
  '报销': ['finance-business-index', 'finance-student-activities'],
};

Future<void> main() async {
  if (!_optIn || !Platform.isWindows) exit(0);

  WidgetsFlutterBinding.ensureInitialized();
  final probe = _ReviewedBundleProbe();
  try {
    await probe.run();
  } on Object {
    probe.markFailedAtCurrentStage();
  }
  var cleanup = false;
  try {
    cleanup = await probe.cleanup();
  } on Object {
    probe.markFailedAt(_ProbeStage.cleanup);
  }
  if (!cleanup) probe.markFailedAt(_ProbeStage.cleanup);
  final passed = probe.failedAt == null && cleanup;
  final output = <String, Object>{
    'kind': _kind,
    'passed': passed,
    'item': probe.itemCount,
    'read': probe.readCount,
    'replay': probe.replayCount,
    'reopen': probe.reopenCount,
    'clear': probe.clearVerified,
    'reload': probe.reloadCount,
    'cleanup': cleanup,
    if (!passed) 'failedAt': probe.failedAt!.name,
  };
  stdout.writeln(jsonEncode(output));
  await stdout.flush();
  exit(passed ? 0 : 1);
}

final class _ReviewedBundleProbe {
  final BundledKnowledgeLoader _loader = BundledKnowledgeLoader();
  Directory? _temporary;
  String? _temporaryPath;
  String? _ownedPath;
  DemoDirectory? _owner;
  JwStore? _store;
  KnowledgeService? _knowledge;
  _ProbeStage _stage = _ProbeStage.setup;
  _ProbeStage? failedAt;
  int _serviceLoaderCalls = 0;
  int itemCount = 0;
  int readCount = 0;
  int replayCount = 0;
  int reopenCount = 0;
  int reloadCount = 0;
  bool clearVerified = false;
  final Map<String, String> _observedRevisions = {};

  Future<void> run() async {
    _stage = _ProbeStage.temporary;
    _temporary = await Directory.systemTemp.createTemp(_temporaryPrefix);
    _temporaryPath = p.windows.normalize(p.windows.absolute(_temporary!.path));
    _ownedPath = p.windows.join(_temporaryPath!, 'owned');

    _stage = _ProbeStage.openStore;
    await _openStore();

    _stage = _ProbeStage.initialEmpty;
    _expectEmpty(await _knowledge!.inspectKnowledge());
    _require(_serviceLoaderCalls == 0);

    _stage = _ProbeStage.bundle;
    _require(identical(_loader.identity, bundledKnowledgeIdentity));
    final edition = await _loader.load();
    final sections = _validateEdition(edition);

    _stage = _ProbeStage.initialLoad;
    final firstLoad = await _knowledge!.loadBundledEdition();
    _expectLoad(firstLoad, accepted: 7, unchanged: 0);
    _expectLoaded(await _knowledge!.inspectKnowledge(), sections, loadCount: 1);
    _require(_serviceLoaderCalls == 1);
    itemCount = firstLoad.accepted;

    _stage = _ProbeStage.initialRead;
    await _verifyEveryMaterial(edition);
    await _verifyTwoCharacterSearches(edition);

    _stage = _ProbeStage.replay;
    final replay = await _knowledge!.loadBundledEdition();
    _expectLoad(replay, accepted: 0, unchanged: 7);
    replayCount = replay.unchanged;
    _expectLoaded(await _knowledge!.inspectKnowledge(), sections, loadCount: 2);
    _require(_serviceLoaderCalls == 2);

    _stage = _ProbeStage.reopen;
    _require(await _closeStore());
    _require(_owner == null && _store == null && _knowledge == null);
    await _openStore();
    _require(_serviceLoaderCalls == 2);
    _expectLoaded(await _knowledge!.inspectKnowledge(), sections, loadCount: 2);
    await _verifyEveryMaterial(edition);
    reopenCount = edition.materials.length;

    final staleReference = (await _searchMaterial(
      edition.materials.first,
    )).reference;
    _stage = _ProbeStage.clear;
    await _knowledge!.clearKnowledge(confirmed: true);
    _expectEmpty(await _knowledge!.inspectKnowledge());
    _require(_serviceLoaderCalls == 2);
    var staleReferenceRejected = false;
    try {
      await _knowledge!.readKnowledgeMaterial(staleReference);
    } on PublicFailure catch (failure) {
      staleReferenceRejected = failure.code == PublicFailureCode.staleReference;
    }
    _require(staleReferenceRejected);
    clearVerified = true;

    _stage = _ProbeStage.clearReopen;
    _require(await _closeStore());
    _require(_owner == null && _store == null && _knowledge == null);
    await _openStore();
    _require(_serviceLoaderCalls == 2);
    _expectEmpty(await _knowledge!.inspectKnowledge());
    final clearedSearch = await _knowledge!.searchKnowledge(
      edition.materials.first.title,
    );
    _require(
      clearedSearch.version == publicQueryVersion &&
          clearedSearch.candidates.isEmpty &&
          clearedSearch.coverage.complete,
    );
    _require(_serviceLoaderCalls == 2);

    _stage = _ProbeStage.reload;
    final reload = await _knowledge!.loadBundledEdition();
    _expectLoad(reload, accepted: 7, unchanged: 0);
    reloadCount = reload.accepted;
    _require(_serviceLoaderCalls == 3);
    _expectLoaded(await _knowledge!.inspectKnowledge(), sections, loadCount: 1);
    await _verifyEveryMaterial(edition);
  }

  Future<void> _openStore() async {
    final owner = await DemoDirectory.acquire(_ownedPath!);
    _owner = owner;
    _require(p.windows.equals(owner.path, _ownedPath!));
    final store = JwStore(
      openJwDatabase(owner),
      ownership: owner,
      clock: const SystemClock(),
    );
    _store = store;
    _require(identical(store.knowledgeIdentity, bundledKnowledgeIdentity));
    await store.initialize();
    _knowledge = KnowledgeService(
      store: store.publicStore,
      loader: _loadBundledEdition,
    );
  }

  Future<KnowledgeEdition> _loadBundledEdition() {
    _serviceLoaderCalls++;
    return _loader.load();
  }

  int _validateEdition(KnowledgeEdition edition) {
    final identity = bundledKnowledgeIdentity;
    _require(edition.key == identity.key);
    _require(edition.catalogDigest == identity.catalogDigest);
    _require(edition.materials.length == identity.materialKeys.length);
    _require(edition.materials.length == 7);
    final observedKeys = edition.materials.map((item) => item.key).toList();
    _require(_sameStrings(observedKeys, identity.materialKeys));
    _require(observedKeys.toSet().length == observedKeys.length);

    final titles = <String>{};
    var sectionCount = 0;
    for (final item in edition.materials) {
      _require(item.markdown.trim().isNotEmpty);
      _require(titles.add(item.title));
      _require(item.articleUrl.scheme == 'https');
      _require(item.publishedOn == null || _validDate(item.publishedOn!));
      _require(item.updatedOn == null || _validDate(item.updatedOn!));
      sectionCount += knowledgeSections(item.markdown).length;
    }
    _require(sectionCount > 0);
    return sectionCount;
  }

  Future<void> _verifyEveryMaterial(KnowledgeEdition edition) async {
    for (final material in edition.materials) {
      final candidate = await _searchMaterial(material);
      await _readEntireMaterial(material, candidate.reference);
      readCount++;
    }
  }

  Future<PublicCandidate> _searchMaterial(KnowledgeMaterial material) async {
    _require(material.title.runes.length <= 80);
    final result = await _knowledge!.searchKnowledge(
      material.title,
      pageSize: 20,
    );
    _require(result.version == publicQueryVersion);
    _require(
      result.coverage.scope == 'acceptedKnowledge' &&
          result.coverage.returned == result.candidates.length &&
          result.coverage.complete &&
          result.next == null,
    );
    PublicCandidate? match;
    for (final candidate in result.candidates) {
      if (candidate.title != material.title) continue;
      _require(match == null);
      match = candidate;
    }
    final found = match;
    if (found == null) throw const _ProbeCheckFailed();
    _require(found.snippet.trim().isNotEmpty);
    _verifyEvidence(found.evidence, material);
    return found;
  }

  Future<void> _verifyTwoCharacterSearches(KnowledgeEdition edition) async {
    final byKey = {for (final item in edition.materials) item.key: item};
    for (final entry in _shortTermMaterialKeys.entries) {
      final result = await _knowledge!.searchKnowledge(entry.key, pageSize: 20);
      _require(result.version == publicQueryVersion);
      _require(
        result.coverage.scope == 'acceptedKnowledge' &&
            result.coverage.returned == result.candidates.length &&
            result.coverage.complete &&
            result.next == null,
      );
      final hitTitles = result.candidates.map((item) => item.title).toSet();
      for (final key in entry.value) {
        final expected = byKey[key];
        if (expected == null) throw const _ProbeCheckFailed();
        _require(hitTitles.contains(expected.title));
        final candidate = result.candidates.singleWhere(
          (item) => item.title == expected.title,
        );
        _verifyEvidence(candidate.evidence, expected);
      }
    }
  }

  Future<void> _readEntireMaterial(
    KnowledgeMaterial material,
    PublicReference reference,
  ) async {
    final expected = knowledgeSections(
      material.markdown,
    ).map((section) => section.markdown).join('\n\n');
    _require(expected.isNotEmpty);
    final collected = StringBuffer();
    PublicCursor? cursor;
    var pages = 0;
    do {
      final requestedCursor = cursor;
      final result = await _knowledge!.readKnowledgeMaterial(
        reference,
        sectionStart: 0,
        maxCharacters: _readLimit,
        cursor: requestedCursor,
      );
      pages++;
      _require(pages <= _maximumReadPages);
      _require(result.version == publicQueryVersion);
      final document = result.document;
      if (document == null) throw const _ProbeCheckFailed();
      _verifyEvidence(document.evidence, material);
      _require(
        result.coverage.scope == 'selectedMaterialSections' &&
            result.coverage.returned == document.markdown.runes.length &&
            result.coverage.observed == expected.runes.length &&
            result.coverage.truncated ==
                (requestedCursor != null || result.next != null) &&
            result.coverage.complete ==
                (requestedCursor == null && result.next == null),
      );
      collected.write(document.markdown);
      cursor = result.next;
    } while (cursor != null);
    _require(collected.toString() == expected);
  }

  void _verifyEvidence(PublicEvidence evidence, KnowledgeMaterial material) {
    _require(evidence.provider == material.provider);
    _require(evidence.title == material.title);
    _require(evidence.articleUrl == material.articleUrl);
    _require(evidence.materialUrl == material.materialUrl);
    _require(evidence.sourceVersion == material.sourceVersion);
    _require(evidence.audience == material.audience);
    _require(evidence.coveredScope == material.coveredScope);
    _require(evidence.publishedOn == material.publishedOn);
    _require(evidence.updatedOn == material.updatedOn);
    _require(evidence.quality == EvidenceQuality.reviewedContent);
    _require(evidence.applicability == MaterialApplicability.unknown);
    _require(evidence.origin == EvidenceOrigin.localKnowledge);
    _require(evidence.observedAtUtc.isUtc);
    final revision = evidence.revision;
    _require(revision != null && revision.isNotEmpty);
    final previous = _observedRevisions[material.key];
    _require(previous == null || previous == revision);
    _observedRevisions[material.key] = revision!;
    _require(evidence.locator != null && evidence.locator!.isNotEmpty);
  }

  void _expectEmpty(KnowledgeSummary summary) {
    _require(
      summary.materialCount == 0 &&
          summary.sectionCount == 0 &&
          summary.loadCount == 0 &&
          !summary.loading &&
          summary.edition == null,
    );
  }

  void _expectLoaded(
    KnowledgeSummary summary,
    int sectionCount, {
    required int loadCount,
  }) {
    _require(
      summary.materialCount == 7 &&
          summary.sectionCount == sectionCount &&
          summary.loadCount == loadCount &&
          !summary.loading &&
          summary.edition == bundledKnowledgeIdentity.key,
    );
  }

  void _expectLoad(
    KnowledgeLoadOutcome outcome, {
    required int accepted,
    required int unchanged,
  }) {
    _require(
      outcome.state == KnowledgeLoadState.done &&
          outcome.accepted == accepted &&
          outcome.unchanged == unchanged &&
          outcome.total == 7 &&
          outcome.failure == null,
    );
  }

  Future<bool> _closeStore() async {
    var closed = true;
    final knowledge = _knowledge;
    if (knowledge != null) {
      try {
        await knowledge.close();
        _knowledge = null;
      } on Object {
        closed = false;
      }
    }
    final store = _store;
    if (store != null) {
      try {
        await store.close();
        _store = null;
      } on Object {
        closed = false;
      }
    }
    final owner = _owner;
    if (owner != null && _store == null) {
      try {
        owner.ensureDatabaseFilesSafe(filename: 'jw.sqlite');
        for (final suffix in ['', '-wal', '-shm']) {
          owner.checkedChildPath('jw.sqlite$suffix', directory: false);
        }
        await owner.release();
        _owner = null;
      } on Object {
        closed = false;
      }
    }
    return closed && _owner == null && _store == null && _knowledge == null;
  }

  Future<bool> cleanup() async {
    _stage = _ProbeStage.cleanup;
    var okay = await _closeStore();
    final temporary = _temporary;
    final expectedPath = _temporaryPath;
    if (temporary == null) return okay;
    if (expectedPath == null) return false;
    if (_owner != null || _store != null || _knowledge != null) return false;
    try {
      final actualPath = p.windows.normalize(
        p.windows.absolute(temporary.path),
      );
      final resolvedPath = p.windows.normalize(
        await temporary.resolveSymbolicLinks(),
      );
      final tempPath = p.windows.normalize(
        p.windows.absolute(Directory.systemTemp.path),
      );
      final resolvedTempPath = p.windows.normalize(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      if (!p.windows.equals(actualPath, expectedPath) ||
          !p.windows.equals(resolvedPath, actualPath) ||
          !p.windows.equals(p.windows.dirname(actualPath), tempPath) ||
          !p.windows.equals(tempPath, resolvedTempPath) ||
          !p.windows.basename(actualPath).startsWith(_temporaryPrefix) ||
          await FileSystemEntity.type(actualPath, followLinks: false) !=
              FileSystemEntityType.directory) {
        return false;
      }

      final rootEntries = await temporary.list(followLinks: false).toList();
      final ownedPath = p.windows.join(actualPath, 'owned');
      final ownedEntries = <FileSystemEntity>[];
      for (final entry in rootEntries) {
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.directory ||
            !p.windows.equals(entry.path, ownedPath) ||
            !p.windows.equals(
              p.windows.normalize(
                await Directory(entry.path).resolveSymbolicLinks(),
              ),
              ownedPath,
            )) {
          return false;
        }
        ownedEntries.addAll(
          await Directory(ownedPath).list(followLinks: false).toList(),
        );
      }
      if (rootEntries.length > 1) return false;

      const databaseFiles = {'jw.sqlite', 'jw.sqlite-wal', 'jw.sqlite-shm'};
      for (final entry in ownedEntries) {
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file ||
            !databaseFiles.contains(
              p.windows.basename(entry.path).toLowerCase(),
            )) {
          return false;
        }
      }

      await temporary.delete(recursive: true);
      _temporary = null;
      return okay;
    } on Object {
      okay = false;
    }
    return okay;
  }

  void markFailedAtCurrentStage() => failedAt ??= _stage;
  void markFailedAt(_ProbeStage stage) => failedAt ??= stage;

  static bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _validDate(String value) =>
      RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value);

  static void _require(bool condition) {
    if (!condition) throw const _ProbeCheckFailed();
  }
}

enum _ProbeStage {
  setup,
  temporary,
  openStore,
  initialEmpty,
  bundle,
  initialLoad,
  initialRead,
  replay,
  reopen,
  clear,
  clearReopen,
  reload,
  cleanup,
}

final class _ProbeCheckFailed implements Exception {
  const _ProbeCheckFailed();
}
