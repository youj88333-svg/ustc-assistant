import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/knowledge_service.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('KnowledgeService', () {
    test(
      'starts empty, loads explicitly, and reports a repeated edition unchanged',
      () async {
        final materials = [
          _material('teach-one', '第一份合成指南', '合成关键词甲。'),
          _material('teach-two', '第二份合成指南', '合成关键词乙。'),
        ];
        final identity = _identity(
          materials.map((value) => value.key).toList(),
        );
        final store = await _openStore(identity);
        var loaderCalls = 0;
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () async {
            loaderCalls++;
            return _edition(identity, materials);
          },
        );

        final initial = await service.inspectKnowledge();
        expect(initial.materialCount, 0);
        expect(initial.sectionCount, 0);
        expect(initial.loadCount, 0);
        expect(initial.loading, isFalse);
        expect((await service.searchKnowledge('合成关键词甲')).candidates, isEmpty);
        expect(loaderCalls, 0);

        // A local maintenance batch does not acquire or invalidate a campus lease.
        final campusJob = await store.publicStore.beginPublicJob(
          PublicSource.campus,
        );
        final loaded = await service.loadBundledEdition();
        await store.publicStore.ensurePublicJob(campusJob);
        await store.publicStore.finishPublicJob(campusJob);
        store.publicStore.releasePublicJob(campusJob);

        expect(loaded.state, KnowledgeLoadState.done);
        expect(loaded.accepted, 2);
        expect(loaded.unchanged, 0);
        expect(loaded.total, 2);
        expect(loaded.hasCommittedChanges, isTrue);
        final repeated = await service.loadBundledEdition();
        expect(repeated.state, KnowledgeLoadState.done);
        expect(repeated.accepted, 0);
        expect(repeated.unchanged, 2);
        expect(repeated.total, 2);
        expect(repeated.hasCommittedChanges, isFalse);
        expect(loaderCalls, 2);

        final summary = await service.inspectKnowledge();
        expect(summary.materialCount, 2);
        expect(summary.loadCount, 2);
        expect(summary.edition, identity.key);
        expect(
          (await service.searchKnowledge('合成关键词甲')).candidates,
          hasLength(1),
        );
        expect(
          (await service.searchKnowledge('合成关键词乙')).candidates,
          hasLength(1),
        );
        await service.close();
      },
    );

    test(
      'rejects a second batch while the first asset read is pending',
      () async {
        final materials = [_material('teach-one', '合成指南', '合成正文。')];
        final identity = _identity(['teach-one']);
        final store = await _openStore(identity);
        final entered = Completer<void>();
        final edition = Completer<KnowledgeEdition>();
        var loaderCalls = 0;
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () {
            loaderCalls++;
            if (!entered.isCompleted) entered.complete();
            return edition.future;
          },
        );

        final first = service.loadBundledEdition();
        await entered.future;
        await expectLater(
          service.loadBundledEdition(),
          throwsA(_failure(PublicFailureCode.busy)),
        );
        expect(loaderCalls, 1);

        edition.complete(_edition(identity, materials));
        final outcome = await first;
        expect(outcome.state, KnowledgeLoadState.done);
        expect(outcome.accepted, 1);
        expect((await service.inspectKnowledge()).materialCount, 1);
        await service.close();
      },
    );

    test(
      'clear invalidates a begin queued behind a C3 transaction and allows retry',
      () async {
        final identity = _identity(['teach-one']);
        final checkpointEntered = Completer<void>();
        final releaseCheckpoint = Completer<void>();
        var blockCheckpoint = true;
        final store = await _openStore(
          identity,
          onKnowledgeCheckpoint: () async {
            if (!blockCheckpoint) return;
            blockCheckpoint = false;
            checkpointEntered.complete();
            await releaseCheckpoint.future;
          },
        );
        final inFlightMaterial = _material(
          'teach-one',
          '排队清理竞态合成材料',
          '阻塞中的事务不得提交。',
        );
        final priorTicket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          priorTicket,
          _edition(identity, [inFlightMaterial]),
        );
        final blockedWrite = store.publicStore.acceptKnowledgeMaterial(
          priorTicket,
          inFlightMaterial,
        );
        await checkpointEntered.future;

        final retryMaterial = _material('teach-one', '清理后的合成材料', '清理后新批次可以提交。');
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () async => _edition(identity, [retryMaterial]),
        );
        // The public store begin is queued behind the blocked transaction before
        // clear advances the memory generation and queues its own transaction.
        final staleLoad = service.loadBundledEdition();
        await Future<void>.delayed(Duration.zero);
        final clearing = service.clearKnowledge(confirmed: true);
        releaseCheckpoint.complete();

        await expectLater(
          blockedWrite,
          throwsA(_failure(PublicFailureCode.cancelled)),
        );
        final staleOutcome = await staleLoad;
        await clearing;
        expect(staleOutcome.state, KnowledgeLoadState.cancelled);
        expect(staleOutcome.accepted, 0);
        expect(staleOutcome.failure, PublicFailureCode.cancelled);
        expect((await service.inspectKnowledge()).materialCount, 0);
        expect((await service.inspectKnowledge()).loading, isFalse);

        final retried = await service.loadBundledEdition();
        expect(retried.state, KnowledgeLoadState.done);
        expect(retried.accepted, 1);
        expect(
          (await service.searchKnowledge('清理后新批次可以提交')).candidates,
          hasLength(1),
        );
        await service.close();
      },
    );

    test(
      'cancel invalidates an edition that arrives after the asset wait',
      () async {
        final identity = _identity(['teach-one']);
        final store = await _openStore(identity);
        final entered = Completer<void>();
        final edition = Completer<KnowledgeEdition>();
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () {
            entered.complete();
            return edition.future;
          },
        );

        final pending = service.loadBundledEdition();
        await entered.future;
        final cancelled = service.cancelKnowledgeLoad();
        edition.complete(
          _edition(identity, [_material('teach-one', '迟到的合成指南', '不应入库。')]),
        );
        await cancelled;
        final outcome = await pending;

        expect(outcome.state, KnowledgeLoadState.cancelled);
        expect(outcome.failure, PublicFailureCode.cancelled);
        expect((await service.inspectKnowledge()).materialCount, 0);
        expect((await service.inspectKnowledge()).loading, isFalse);
        await service.close();
      },
    );

    test(
      'clear invalidates a late edition and leaves the knowledge store empty',
      () async {
        final identity = _identity(['teach-one']);
        final store = await _openStore(identity);
        final entered = Completer<void>();
        final edition = Completer<KnowledgeEdition>();
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () {
            entered.complete();
            return edition.future;
          },
        );

        final pending = service.loadBundledEdition();
        await entered.future;
        var cleared = false;
        final clearing = service
            .clearKnowledge(confirmed: true)
            .then((_) => cleared = true);
        await Future<void>.delayed(Duration.zero);
        expect(cleared, isFalse);
        edition.complete(
          _edition(identity, [_material('teach-one', '迟到的合成指南', '不得恢复清理内容。')]),
        );
        final outcome = await pending;
        await clearing;
        expect(cleared, isTrue);

        expect(outcome.state, KnowledgeLoadState.cancelled);
        expect((await service.inspectKnowledge()).materialCount, 0);
        expect((await service.inspectKnowledge()).loading, isFalse);
        await service.close();
      },
    );

    test(
      'close drains a pending edition before the database can be closed',
      () async {
        final identity = _identity(['teach-one']);
        final store = await _openStore(identity);
        final entered = Completer<void>();
        final edition = Completer<KnowledgeEdition>();
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () {
            entered.complete();
            return edition.future;
          },
        );

        final pending = service.loadBundledEdition();
        await entered.future;
        var closeFinished = false;
        final closing = service.close().whenComplete(
          () => closeFinished = true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(closeFinished, isFalse);

        edition.complete(
          _edition(identity, [_material('teach-one', '迟到的合成指南', '关闭后不得入库。')]),
        );
        final outcome = await pending;
        await closing;

        expect(outcome.state, KnowledgeLoadState.cancelled);
        expect((await store.publicStore.inspectKnowledge()).materialCount, 0);
        expect((await store.publicStore.inspectKnowledge()).loading, isFalse);
        expect(
          () => service.inspectKnowledge(),
          throwsA(_failure(PublicFailureCode.closed)),
        );
        await store.close();
      },
    );

    test(
      'a failed second material preserves the first commit and retry counts',
      () async {
        final materials = [
          _material('teach-one', '第一份合成指南', '保留第一条提交。'),
          _material('teach-two', '第二份合成指南', '第二条在重试时提交。'),
        ];
        final identity = _identity(['teach-one', 'teach-two']);
        var checkpointCalls = 0;
        final store = await _openStore(
          identity,
          onKnowledgeCheckpoint: () async {
            checkpointCalls++;
            if (checkpointCalls == 2) {
              throw StateError('Synthetic checkpoint failure.');
            }
          },
        );
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () async => _edition(identity, materials),
        );

        final failed = await service.loadBundledEdition();
        expect(failed.state, KnowledgeLoadState.failed);
        expect(failed.accepted, 1);
        expect(failed.unchanged, 0);
        expect(failed.total, 2);
        expect(failed.failure, PublicFailureCode.storageFailed);
        expect(failed.hasCommittedChanges, isTrue);
        expect(
          (await service.searchKnowledge('保留第一条提交')).candidates,
          hasLength(1),
        );
        expect(
          (await service.searchKnowledge('第二条在重试时提交')).candidates,
          isEmpty,
        );

        final retried = await service.loadBundledEdition();
        expect(retried.state, KnowledgeLoadState.done);
        expect(retried.accepted, 1);
        expect(retried.unchanged, 1);
        expect(retried.total, 2);
        expect(retried.failure, isNull);
        expect((await service.inspectKnowledge()).materialCount, 2);
        expect(
          (await service.searchKnowledge('保留第一条提交')).candidates,
          hasLength(1),
        );
        expect(
          (await service.searchKnowledge('第二条在重试时提交')).candidates,
          hasLength(1),
        );
        expect(checkpointCalls, 3);
        await service.close();
      },
    );

    test(
      'C3 rejects image and raw HTML Markdown with stable schema failures',
      () async {
        final rejectedBodies = [
          '# Synthetic guide\n\n![Synthetic diagram](https://www.teach.ustc.edu.cn/diagram.png)',
          '# Synthetic guide\n\n<script>synthetic()</script>',
        ];

        for (var index = 0; index < rejectedBodies.length; index++) {
          final identity = _identity(['teach-one']);
          final store = await _openStore(identity);
          final material = _material(
            'teach-one',
            '合成材料 $index',
            rejectedBodies[index],
          );
          final service = KnowledgeService(
            store: store.publicStore,
            loader: () async => _edition(identity, [material]),
          );

          final outcome = await service.loadBundledEdition();
          expect(outcome.state, KnowledgeLoadState.failed);
          expect(outcome.accepted, 0);
          expect(outcome.failure, PublicFailureCode.sourceSchema);
          expect((await service.inspectKnowledge()).materialCount, 0);
          expect((await service.inspectKnowledge()).loading, isFalse);
          await service.close();
          await store.close();
        }
      },
    );

    test(
      'C3 accepts HTTPS source metadata and rejects an HTTP article URL',
      () async {
        final identity = _identity(['teach-one']);
        final store = await _openStore(identity);
        final valid = _material('teach-one', 'HTTPS 合成指南', 'HTTPS 来源正文。');
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () async => _edition(identity, [valid]),
        );

        final accepted = await service.loadBundledEdition();
        expect(accepted.state, KnowledgeLoadState.done);
        expect(accepted.accepted, 1);
        await service.clearKnowledge(confirmed: true);

        final insecure = _material(
          'teach-one',
          'HTTP 合成指南',
          'HTTP 来源必须拒绝。',
          articleUrl: Uri.parse(
            'http://www.teach.ustc.edu.cn/synthetic/article',
          ),
        );
        final rejected = await KnowledgeService(
          store: store.publicStore,
          loader: () async => _edition(identity, [insecure]),
        ).loadBundledEdition();
        expect(rejected.state, KnowledgeLoadState.failed);
        expect(rejected.accepted, 0);
        expect(rejected.failure, PublicFailureCode.unsafeTarget);
        expect((await store.publicStore.inspectKnowledge()).materialCount, 0);
      },
    );

    test(
      'an empty configured edition is unavailable and never auto-created',
      () async {
        final identity = _identity(const []);
        final store = await _openStore(identity);
        var loaderCalls = 0;
        final service = KnowledgeService(
          store: store.publicStore,
          loader: () async {
            loaderCalls++;
            return _edition(identity, const []);
          },
        );

        final outcome = await service.loadBundledEdition();
        expect(outcome.state, KnowledgeLoadState.failed);
        expect(outcome.accepted, 0);
        expect(outcome.total, 0);
        expect(outcome.failure, PublicFailureCode.unavailable);
        expect(loaderCalls, 0);
        final summary = await service.inspectKnowledge();
        expect(summary.materialCount, 0);
        expect(summary.loadCount, 0);
        expect(summary.loading, isFalse);
        await service.close();
      },
    );
  });
}

Future<JwStore> _openStore(
  KnowledgeEditionIdentity identity, {
  Future<void> Function()? onKnowledgeCheckpoint,
}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 10, 12)),
    knowledgeIdentity: identity,
    onKnowledgeCheckpoint: onKnowledgeCheckpoint,
  );
  await store.initialize();
  addTearDown(store.close);
  return store;
}

KnowledgeEditionIdentity _identity(List<String> keys) =>
    KnowledgeEditionIdentity(
      key: 'synthetic-campus-edition-v1',
      catalogDigest: List<String>.filled(64, 'c').join(),
      materialKeys: List.unmodifiable(keys),
    );

KnowledgeEdition _edition(
  KnowledgeEditionIdentity identity,
  List<KnowledgeMaterial> materials,
) => KnowledgeEdition(
  key: identity.key,
  catalogDigest: identity.catalogDigest,
  materials: materials,
);

KnowledgeMaterial _material(
  String key,
  String title,
  String markdown, {
  Uri? articleUrl,
}) => KnowledgeMaterial(
  key: key,
  title: title,
  provider: PublicProvider.teach,
  topic: 'synthetic-topic',
  audience: 'synthetic-audience',
  sourceVersion: 'synthetic-v1',
  articleUrl:
      articleUrl ??
      Uri.parse('https://www.teach.ustc.edu.cn/synthetic/article'),
  sourceDigest: fingerprintBytes('synthetic source $key'),
  coveredScope: 'Synthetic scope only.',
  markdown: markdown,
  markdownDigest: fingerprintBytes(markdown),
  reviewVersion: 'synthetic-review-v1',
);

Matcher _failure(PublicFailureCode code) => isA<PublicFailure>().having(
  (failure) => failure.code,
  'failure code',
  code,
);

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
