import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/public_validation_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/knowledge_service.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/m0_entry.dart' show m3ValidationEnabled;
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

const _tempPrefix = 'ustc_m3_public_';
const _materialKey = 'm3-synthetic-scholarship';
const _markdown = '''
# 合成奖学金申请说明

以下正文只用于 Windows 本机验收，不代表真实学校业务信息。

## 申请条件

申请人须满足以下合成条件，并逐项核对示例材料。

| 核对项目 | 示例结果 |
| --- | --- |
| 来源类型 | 合成内容 |
| 审核状态 | 已复核 |
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'M3 Windows native local knowledge loads, searches, reads, and clears durably',
    (tester) async {
      if (!Platform.isWindows) return;

      expect(m3ValidationEnabled, isFalse);
      await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(_tempPrefix);
        final rootPath = p.windows.normalize(
          p.windows.absolute(temporary.path),
        );
        final databasePath = p.windows.join(rootPath, 'owned');
        final identity = _syntheticIdentity();
        final edition = _syntheticEdition(identity);
        final leases = WorkLeasePool();
        var loaderCalls = 0;
        Future<KnowledgeEdition> loadSyntheticEdition() async {
          loaderCalls++;
          return edition;
        }

        _Harness? harness;
        var mounted = false;
        try {
          harness = await _Harness.open(
            databasePath,
            identity: identity,
            leases: leases,
            loader: loadSyntheticEdition,
          );
          _expectSummary(
            await harness.knowledge.inspectKnowledge(),
            _emptySummary,
          );
          expect(
            loaderCalls,
            0,
            reason: 'Opening the database must not seed it.',
          );

          await _mount(tester, harness);
          mounted = true;
          expect(find.text('材料 0 项；片段 0 项；载入 0 次。'), findsOneWidget);

          await _tap(
            tester,
            find.byKey(const ValueKey('public-validation-knowledge-load')),
          );
          expect(loaderCalls, 1);
          expect(find.text('材料 1 项；片段 2 项；载入 1 次。'), findsOneWidget);

          await _searchAndRead(tester);
          expect(find.text('申请人须满足以下合成条件，并逐项核对示例材料。'), findsOneWidget);
          expect(find.text('已复核'), findsOneWidget);

          await _unmount(tester);
          mounted = false;
          await harness.close();
          harness = null;

          // Reacquiring the same temporary owner and file proves that both the
          // indexed section and its Markdown body survive a native close/reopen.
          harness = await _Harness.open(
            databasePath,
            identity: identity,
            leases: leases,
            loader: loadSyntheticEdition,
          );
          _expectSummary(
            await harness.knowledge.inspectKnowledge(),
            const KnowledgeSummary(
              materialCount: 1,
              sectionCount: 2,
              loadCount: 1,
              loading: false,
              edition: 'm3-synthetic-knowledge-v1',
            ),
          );
          await _mount(tester, harness);
          mounted = true;
          expect(find.text('材料 1 项；片段 2 项；载入 1 次。'), findsOneWidget);
          await _searchAndRead(tester);
          expect(find.text('申请人须满足以下合成条件，并逐项核对示例材料。'), findsOneWidget);
          expect(find.text('已复核'), findsOneWidget);

          await _tap(
            tester,
            find.byKey(const ValueKey('public-validation-knowledge-clear')),
          );
          await _tap(
            tester,
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('继续'),
            ),
          );
          await _tap(
            tester,
            find.byKey(const ValueKey('public-validation-clear-confirm')),
          );
          expect(find.text('材料 0 项；片段 0 项；载入 0 次。'), findsOneWidget);
          expect(loaderCalls, 1);

          await _unmount(tester);
          mounted = false;
          await harness.close();
          harness = null;

          harness = await _Harness.open(
            databasePath,
            identity: identity,
            leases: leases,
            loader: loadSyntheticEdition,
          );
          _expectSummary(
            await harness.knowledge.inspectKnowledge(),
            _emptySummary,
          );
          expect(
            loaderCalls,
            1,
            reason: 'Reopening a cleared store must not reseed it.',
          );
          await _mount(tester, harness);
          mounted = true;
          expect(find.text('材料 0 项；片段 0 项；载入 0 次。'), findsOneWidget);
          await tester.enterText(
            find.byKey(const ValueKey('public-validation-knowledge-keyword')),
            '申请条件',
          );
          await tester.pumpAndSettle();
          await _tap(
            tester,
            find.byKey(const ValueKey('public-validation-knowledge-search')),
          );
          expect(find.text('本次本地检索返回合法空结果。'), findsOneWidget);
          expect(
            find.byKey(
              const ValueKey('public-validation-knowledge-candidate-0'),
            ),
            findsNothing,
          );
          expect(loaderCalls, 1);
        } finally {
          if (mounted) await _unmount(tester);
          final active = harness;
          if (active != null) await active.close();
          await _deleteTemporaryRoot(temporary, rootPath);
        }
      });
    },
    skip: !Platform.isWindows,
  );
}

const _emptySummary = KnowledgeSummary(
  materialCount: 0,
  sectionCount: 0,
  loadCount: 0,
  loading: false,
);

void _expectSummary(KnowledgeSummary actual, KnowledgeSummary expected) {
  expect(actual.materialCount, expected.materialCount);
  expect(actual.sectionCount, expected.sectionCount);
  expect(actual.loadCount, expected.loadCount);
  expect(actual.loading, expected.loading);
  expect(actual.edition, expected.edition);
}

KnowledgeEditionIdentity _syntheticIdentity() => KnowledgeEditionIdentity(
  key: 'm3-synthetic-knowledge-v1',
  catalogDigest: _digest('m3-synthetic-catalog-v1'),
  materialKeys: const [_materialKey],
);

KnowledgeEdition _syntheticEdition(KnowledgeEditionIdentity identity) =>
    KnowledgeEdition(
      key: identity.key,
      catalogDigest: identity.catalogDigest,
      materials: [
        KnowledgeMaterial(
          key: _materialKey,
          title: '合成奖学金申请说明',
          provider: PublicProvider.teach,
          topic: '合成奖学金',
          audience: '合成申请人',
          sourceVersion: 'synthetic-source-v1',
          articleUrl: Uri.parse(
            'https://www.teach.ustc.edu.cn/m3-synthetic-material',
          ),
          sourceDigest: _digest('m3-synthetic-source-v1'),
          coveredScope: '合成申请条件与核对示例',
          markdown: _markdown,
          markdownDigest: _digest(_markdown),
          reviewVersion: 'synthetic-review-v1',
          publishedOn: '2026-01-01',
        ),
      ],
    );

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

Future<void> _mount(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PublicValidationPanel(
          queries: harness.queries,
          knowledge: harness.knowledge,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _searchAndRead(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('public-validation-knowledge-keyword')),
    '申请条件',
  );
  await tester.pumpAndSettle();
  await _tap(
    tester,
    find.byKey(const ValueKey('public-validation-knowledge-search')),
  );
  final candidate = find.byKey(
    const ValueKey('public-validation-knowledge-candidate-0'),
  );
  expect(candidate, findsOneWidget);
  expect(find.text('合成奖学金申请说明'), findsOneWidget);
  await _tap(
    tester,
    find.descendant(of: candidate, matching: find.text('按受控引用读取')),
  );
  expect(find.text('有界材料正文'), findsOneWidget);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _deleteTemporaryRoot(Directory root, String expectedPath) async {
  final tempPath = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  final actualPath = p.windows.normalize(p.windows.absolute(root.path));
  final resolved = p.windows.normalize(await root.resolveSymbolicLinks());
  final resolvedTemp = p.windows.normalize(
    await Directory.systemTemp.resolveSymbolicLinks(),
  );
  if (!p.windows.equals(actualPath, expectedPath) ||
      !p.windows.isWithin(resolvedTemp, resolved) ||
      !p.windows.basename(resolved).startsWith(_tempPrefix) ||
      !p.windows.equals(p.windows.dirname(actualPath), tempPath) ||
      !p.windows.basename(actualPath).startsWith(_tempPrefix) ||
      await FileSystemEntity.type(actualPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing to remove an unexpected M3 test directory.');
  }
  final ownedPath = p.windows.join(actualPath, 'owned');
  final ownedType = await FileSystemEntity.type(ownedPath, followLinks: false);
  if (ownedType != FileSystemEntityType.directory &&
      ownedType != FileSystemEntityType.notFound) {
    throw StateError('Refusing to remove an unexpected M3 owner directory.');
  }
  await root.delete(recursive: true);
}

final class _Harness {
  _Harness({
    required this.owner,
    required this.store,
    required this.queries,
    required this.knowledge,
  });

  final DemoDirectory owner;
  final JwStore store;
  final PublicQueryCoordinator queries;
  final KnowledgeService knowledge;
  bool _closed = false;

  static Future<_Harness> open(
    String directoryPath, {
    required KnowledgeEditionIdentity identity,
    required WorkLeasePool leases,
    required KnowledgeEditionLoader loader,
  }) async {
    final owner = await DemoDirectory.acquire(directoryPath);
    JwStore? store;
    PublicQueryCoordinator? queries;
    KnowledgeService? knowledge;
    try {
      store = JwStore(
        openJwDatabase(owner),
        ownership: owner,
        clock: const SystemClock(),
        knowledgeIdentity: identity,
      );
      await store.initialize();
      queries = PublicQueryCoordinator(
        store: store.publicStore,
        leases: leases,
      );
      knowledge = KnowledgeService(store: store.publicStore, loader: loader);
      return _Harness(
        owner: owner,
        store: store,
        queries: queries,
        knowledge: knowledge,
      );
    } on Object {
      await queries?.close();
      await knowledge?.close();
      await store?.close();
      await owner.release();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await queries.close();
    await knowledge.close();
    await store.close();
    owner.ensureDatabaseFilesSafe(filename: 'jw.sqlite');
    for (final suffix in ['', '-wal', '-shm']) {
      owner.checkedChildPath('jw.sqlite$suffix', directory: false);
    }
    await owner.release();
    _closed = true;
  }
}
