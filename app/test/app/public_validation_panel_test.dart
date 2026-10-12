import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/public_validation_panel.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'obtains consent, reads candidates by reference, preserves source filters and next cursors',
    (tester) async {
      final queries = _FakePublicQueryPort()..consent = false;
      final knowledge = _FakeKnowledgePort();
      final candidate = _candidate(
        reference: const PublicReference('course-ref-private'),
        provider: PublicProvider.icourse,
        title: 'Synthetic course',
        terms: const [PublicTerm(code: '2026S', label: '2026 春')],
      );
      final candidateNext = const PublicCursor('course-cursor-private');
      queries.courseSearchPages = [
        _result(candidates: [candidate], next: candidateNext),
        _result(candidates: [candidate]),
      ];
      queries.courseReadResult = _result(
        document: _document(
          provider: PublicProvider.icourse,
          markdown: '## 合成课程\n\n![封面](https://assets.example.test/image.png)',
          course: candidate.course,
          reviews: const [
            PublicReview(
              text: 'Synthetic review',
              locator: '点评 1',
              term: '2026S',
            ),
          ],
        ),
        next: const PublicCursor('review-cursor-private'),
      );
      addTearDown(queries.dispose);
      addTearDown(knowledge.dispose);
      await _mount(tester, queries, knowledge);

      await tester.enterText(
        find.byKey(const ValueKey('public-validation-course-keyword')),
        '合成课程词',
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-course-search')),
      );
      expect(find.text('首次评课公开查询授权'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-course-consent')),
      );
      expect(queries.hasConsentCalls, 1);
      expect(queries.setConsentCalls, 1);
      expect(queries.consent, isTrue);
      expect(queries.lastCourseKeyword, '合成课程词');

      await _tap(tester, find.text('按受控引用读取').first);
      expect(
        identical(queries.lastCourseReference, candidate.reference),
        isTrue,
      );
      expect(queries.lastCourseTerm, isNull);
      expect(queries.lastCourseSort, CourseReviewSort.upvote);
      expect(
        find.byKey(const ValueKey('public-validation-blocked-image')),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('public-validation-course-term')),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('2026 春').last);
      expect(queries.lastCourseTerm, '2026S');

      await tester.tap(
        find.byKey(const ValueKey('public-validation-course-sort')),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('来源排序：最新').last);
      expect(queries.lastCourseSort, CourseReviewSort.newest);

      final reviewCursor = queries.courseReadResult.next!;
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-course-review-next')),
      );
      expect(identical(queries.lastCourseCursor, reviewCursor), isTrue);
      expect(
        identical(queries.lastCourseReference, candidate.reference),
        isTrue,
      );

      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-course-next')),
      );
      expect(identical(queries.lastCourseSearchCursor, candidateNext), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(queries.closeCalls, 0);
    },
  );

  testWidgets('keeps legal empty results distinct from fixed-code failures', (
    tester,
  ) async {
    final queries = _FakePublicQueryPort()
      ..consent = true
      ..courseSearchPages = [_result()];
    final knowledge = _FakeKnowledgePort();
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await tester.enterText(
      find.byKey(const ValueKey('public-validation-course-keyword')),
      'empty synthetic',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-course-search')),
    );
    expect(find.text('本次查询返回合法空结果。'), findsOneWidget);
    expect(find.textContaining('请求失败码：'), findsNothing);

    queries.courseFailure = const PublicFailure(PublicFailureCode.sourceSchema);
    await tester.enterText(
      find.byKey(const ValueKey('public-validation-course-keyword')),
      'failure synthetic',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-course-search')),
    );
    expect(find.textContaining('请求失败码：sourceSchema'), findsOneWidget);
    expect(find.text('本次查询返回合法空结果。'), findsNothing);
  });

  testWidgets(
    'local knowledge remains searchable while a public source is busy',
    (tester) async {
      final queries = _FakePublicQueryPort()
        ..consent = true
        ..holdNextCourseSearch = true;
      final knowledge = _FakeKnowledgePort()
        ..knowledgeSearchResult = _result(
          candidates: [
            _candidate(
              reference: const PublicReference('local-ref-private'),
              provider: PublicProvider.teach,
              title: 'Synthetic local result',
              snippet: 'Local matching snippet',
            ),
          ],
        );
      final localCandidate = knowledge.knowledgeSearchResult.candidates.single;
      addTearDown(queries.dispose);
      addTearDown(knowledge.dispose);
      await _mount(tester, queries, knowledge);

      await tester.enterText(
        find.byKey(const ValueKey('public-validation-course-keyword')),
        'source pending',
      );
      await tester.tap(
        find.byKey(const ValueKey('public-validation-course-search')),
      );
      await tester.pump();
      expect(find.text('公开来源查询中'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('public-validation-knowledge-keyword')),
        '本地词',
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-knowledge-search')),
      );
      expect(knowledge.lastSearchKeyword, '本地词');
      expect(find.text('Synthetic local result'), findsOneWidget);
      expect(find.text('Local matching snippet'), findsOneWidget);
      expect(queries.courseSearchCalls, 1);
      await _tap(tester, find.text('按受控引用读取').last);
      expect(knowledge.readCalls, 1);
      expect(
        identical(knowledge.lastReadReference, localCandidate.reference),
        isTrue,
      );
      expect(knowledge.lastReadMaxCharacters, 12000);

      queries.completeCourseSearch();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('clears knowledge only after two confirmations', (tester) async {
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort();
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-knowledge-clear')),
    );
    expect(find.text('清除本地知识库？'), findsOneWidget);
    await _tap(tester, find.text('继续'));
    expect(find.text('再次确认清除知识库'), findsOneWidget);
    expect(knowledge.clearCalls, 0);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-clear-confirm')),
    );
    expect(knowledge.clearCalls, 1);
    expect(knowledge.lastClearConfirmed, isTrue);
    expect(find.text('知识库清理请求已完成。'), findsOneWidget);
  });

  testWidgets('can cancel the independent local material load', (tester) async {
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort()..holdNextLoad = true;
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-knowledge-load')),
    );
    expect(knowledge.loadCalls, 1);
    expect(find.text('首批清单载入中'), findsOneWidget);
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-knowledge-cancel-load')),
    );
    expect(knowledge.cancelLoadCalls, 1);
    await tester.pumpAndSettle();
    expect(find.textContaining('首批清单载入已取消'), findsOneWidget);
  });

  testWidgets('finance keyword query is explicitly unavailable', (
    tester,
  ) async {
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort();
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await tester.tap(
      find.byKey(const ValueKey('public-validation-campus-column')),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.text('财务业务指南').last);
    await tester.enterText(
      find.byKey(const ValueKey('public-validation-campus-keyword')),
      '财务关键词',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-campus-browse')),
    );

    expect(queries.browseCalls, 0);
    expect(
      find.byKey(const ValueKey('public-validation-failure-unavailable')),
      findsOneWidget,
    );
    expect(find.textContaining('财务栏目来源关键词检索当前不可用'), findsOneWidget);
    expect(find.textContaining('合法空结果'), findsNothing);
  });

  testWidgets(
    'browses a fixed campus column and reads its returned reference',
    (tester) async {
      final queries = _FakePublicQueryPort();
      final knowledge = _FakeKnowledgePort();
      final article = _candidate(
        reference: const PublicReference('campus-ref-private'),
        provider: PublicProvider.teach,
        origin: EvidenceOrigin.online,
        title: 'Synthetic campus article',
        snippet: 'Synthetic listing entry',
      );
      queries.campusBrowseResult = _result(candidates: [article]);
      addTearDown(queries.dispose);
      addTearDown(knowledge.dispose);
      await _mount(tester, queries, knowledge);

      await tester.enterText(
        find.byKey(const ValueKey('public-validation-campus-keyword')),
        '教务词',
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-campus-browse')),
      );
      expect(queries.lastCampusColumn, CampusColumn.teachNotice);
      expect(queries.lastCampusKeyword, '教务词');
      await _tap(tester, find.text('按受控引用读取').last);
      expect(queries.readCampusCalls, 1);
      expect(identical(queries.lastCampusReference, article.reference), isTrue);
    },
  );

  testWidgets(
    'continues campus article reads with bound cursor and replaces the chunk',
    (tester) async {
      const reference = PublicReference('campus-long-body-reference');
      const cursor = PublicCursor('campus-long-body-next');
      final queries = _FakePublicQueryPort();
      final knowledge = _FakeKnowledgePort();
      queries.campusBrowseResult = _result(
        candidates: [
          _candidate(
            reference: reference,
            provider: PublicProvider.teach,
            origin: EvidenceOrigin.online,
            title: 'Synthetic long campus article',
          ),
        ],
      );
      queries.campusReadPages = [
        _result(
          document: _document(
            provider: PublicProvider.teach,
            origin: EvidenceOrigin.online,
            markdown: '校园正文第一片段',
          ),
          next: cursor,
        ),
        _result(
          document: _document(
            provider: PublicProvider.teach,
            origin: EvidenceOrigin.online,
            markdown: '校园正文第二片段',
          ),
        ),
      ];
      addTearDown(queries.dispose);
      addTearDown(knowledge.dispose);
      await _mount(tester, queries, knowledge);

      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-campus-browse')),
      );
      final candidate = find.byKey(
        const ValueKey('public-validation-campus-candidate-0'),
      );
      await _tap(
        tester,
        find.descendant(of: candidate, matching: find.text('按受控引用读取')),
      );
      expect(find.text('校园正文第一片段'), findsOneWidget);
      expect(find.text('来源版本：synthetic-source-v1'), findsNWidgets(2));
      expect(find.text('适用人群：合成人群'), findsNWidgets(2));
      expect(find.text('覆盖范围：合成范围'), findsNWidgets(2));
      expect(find.text('内容质量：已校核内容'), findsNWidgets(2));

      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-campus-document-next')),
      );
      expect(queries.readCampusCalls, 2);
      expect(identical(queries.lastCampusReference, reference), isTrue);
      expect(queries.lastCampusSectionStart, 0);
      expect(queries.lastCampusMaxCharacters, 12000);
      expect(identical(queries.lastCampusReadCursor, cursor), isTrue);
      expect(find.text('校园正文第一片段'), findsNothing);
      expect(find.text('校园正文第二片段'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('public-validation-campus-document-next')),
        findsNothing,
      );
    },
  );

  testWidgets('continues local material reads through the knowledge port', (
    tester,
  ) async {
    const reference = PublicReference('knowledge-long-body-reference');
    const cursor = PublicCursor('knowledge-long-body-next');
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort();
    knowledge.knowledgeSearchResult = _result(
      candidates: [
        _candidate(
          reference: reference,
          provider: PublicProvider.teach,
          title: 'Synthetic long knowledge material',
        ),
      ],
    );
    knowledge.knowledgeReadPages = [
      _result(
        document: _document(
          provider: PublicProvider.teach,
          markdown: '本地正文第一片段',
        ),
        next: cursor,
      ),
      _result(
        document: _document(
          provider: PublicProvider.teach,
          markdown: '本地正文第二片段',
        ),
      ),
    ];
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await tester.enterText(
      find.byKey(const ValueKey('public-validation-knowledge-keyword')),
      '材料词',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-knowledge-search')),
    );
    final candidate = find.byKey(
      const ValueKey('public-validation-knowledge-candidate-0'),
    );
    await _tap(
      tester,
      find.descendant(of: candidate, matching: find.text('按受控引用读取')),
    );
    expect(find.text('本地正文第一片段'), findsOneWidget);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-knowledge-document-next')),
    );
    expect(knowledge.readCalls, 2);
    expect(identical(knowledge.lastReadReference, reference), isTrue);
    expect(knowledge.lastReadSectionStart, 0);
    expect(knowledge.lastReadMaxCharacters, 12000);
    expect(identical(knowledge.lastReadCursor, cursor), isTrue);
    expect(find.text('本地正文第一片段'), findsNothing);
    expect(find.text('本地正文第二片段'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('public-validation-knowledge-document-next')),
      findsNothing,
    );
  });

  testWidgets('a new campus query drops the previous article continuation', (
    tester,
  ) async {
    const cursor = PublicCursor('old-campus-article-next');
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort();
    queries.campusBrowseResult = _result(
      candidates: [
        _candidate(
          reference: const PublicReference('old-campus-article'),
          provider: PublicProvider.teach,
          origin: EvidenceOrigin.online,
          title: 'Synthetic previous article',
        ),
      ],
    );
    queries.campusReadResult = _result(
      document: _document(
        provider: PublicProvider.teach,
        origin: EvidenceOrigin.online,
        markdown: '旧校园正文',
      ),
      next: cursor,
    );
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-campus-browse')),
    );
    final candidate = find.byKey(
      const ValueKey('public-validation-campus-candidate-0'),
    );
    await _tap(
      tester,
      find.descendant(of: candidate, matching: find.text('按受控引用读取')),
    );
    expect(
      find.byKey(const ValueKey('public-validation-campus-document-next')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('public-validation-campus-keyword')),
      '新校园关键词',
    );
    await tester.pumpAndSettle();
    expect(find.text('旧校园正文'), findsNothing);
    expect(
      find.byKey(const ValueKey('public-validation-campus-document-next')),
      findsNothing,
    );
  });

  testWidgets('cancelling a campus continuation drops its old cursor', (
    tester,
  ) async {
    const reference = PublicReference('campus-cancel-reference');
    const cursor = PublicCursor('campus-cancel-next');
    final queries = _FakePublicQueryPort();
    final knowledge = _FakeKnowledgePort();
    queries.campusBrowseResult = _result(
      candidates: [
        _candidate(
          reference: reference,
          provider: PublicProvider.teach,
          origin: EvidenceOrigin.online,
          title: 'Synthetic campus article to cancel',
        ),
      ],
    );
    queries.campusReadPages = [
      _result(
        document: _document(
          provider: PublicProvider.teach,
          origin: EvidenceOrigin.online,
          markdown: '待续校园正文',
        ),
        next: cursor,
      ),
    ];
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-campus-browse')),
    );
    final candidate = find.byKey(
      const ValueKey('public-validation-campus-candidate-0'),
    );
    await _tap(
      tester,
      find.descendant(of: candidate, matching: find.text('按受控引用读取')),
    );
    queries.holdNextCampusRead = true;
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-campus-document-next')),
    );
    expect(find.text('公开来源查询中'), findsOneWidget);
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-cancel-source')),
    );

    expect(queries.cancelCalls, 1);
    expect(find.text('待续校园正文'), findsNothing);
    expect(
      find.byKey(const ValueKey('public-validation-campus-document-next')),
      findsNothing,
    );
  });

  testWidgets('recovery retry calls the port and leaves the source busy', (
    tester,
  ) async {
    final queries = _FakePublicQueryPort()
      ..emit(const PublicJobView(phase: PublicJobPhase.recovery));
    final knowledge = _FakeKnowledgePort();
    addTearDown(queries.dispose);
    addTearDown(knowledge.dispose);
    await _mount(tester, queries, knowledge);

    expect(find.text('公开来源正在恢复；新在线查询保持忙碌'), findsOneWidget);
    await _tap(
      tester,
      find.byKey(const ValueKey('public-validation-retry-recovery')),
    );
    expect(queries.retryRecoveryCalls, 1);
    expect(find.text('公开来源正在恢复；新在线查询保持忙碌'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('public-validation-course-search')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'copied safety summary excludes keywords, references and source text',
    (tester) async {
      final queries = _FakePublicQueryPort()
        ..consent = true
        ..courseSearchPages = [
          _result(
            candidates: [
              _candidate(
                reference: const PublicReference('do-not-copy-reference'),
                provider: PublicProvider.icourse,
                title: 'do-not-copy-source-title',
                snippet: 'do-not-copy-snippet',
              ),
            ],
          ),
        ];
      final knowledge = _FakeKnowledgePort();
      final copied = <String>[];
      _captureClipboard(tester, copied);
      addTearDown(() => _resetClipboard(tester));
      addTearDown(queries.dispose);
      addTearDown(knowledge.dispose);
      await _mount(tester, queries, knowledge);
      await tester.enterText(
        find.byKey(const ValueKey('public-validation-course-keyword')),
        'do-not-copy-keyword',
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-course-search')),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('public-validation-copy-summary')),
      );

      final summary = jsonDecode(copied.single) as Map<String, dynamic>;
      expect(summary['kind'], 'public-query-validation-v1');
      expect(summary['knowledge'], containsPair('materials', 4));
      expect(copied.single, isNot(contains('do-not-copy-keyword')));
      expect(copied.single, isNot(contains('do-not-copy-reference')));
      expect(copied.single, isNot(contains('do-not-copy-source-title')));
      expect(copied.single, isNot(contains('do-not-copy-snippet')));
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  PublicQueryPort queries,
  KnowledgePort knowledge,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PublicValidationPanel(queries: queries, knowledge: knowledge),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

PublicQueryResult _result({
  List<PublicCandidate> candidates = const [],
  PublicDocument? document,
  PublicCursor? next,
}) => PublicQueryResult(
  candidates: candidates,
  coverage: PublicCoverage(
    scope: 'synthetic bounded scope',
    returned: candidates.length + (document == null ? 0 : 1),
    observed: 2,
    totalReported: 5,
    excluded: 1,
    truncated: false,
    complete: true,
  ),
  document: document,
  next: next,
);

PublicCandidate _candidate({
  required PublicReference reference,
  required PublicProvider provider,
  required String title,
  String snippet = '',
  List<PublicTerm> terms = const [],
  EvidenceOrigin? origin,
}) => PublicCandidate(
  reference: reference,
  title: title,
  snippet: snippet,
  evidence: _evidence(
    provider,
    origin:
        origin ??
        (provider == PublicProvider.icourse
            ? EvidenceOrigin.online
            : EvidenceOrigin.localKnowledge),
  ),
  course: provider == PublicProvider.icourse
      ? PublicCourseInfo(
          courseKey: 'course-key-private',
          title: title,
          teacher: 'Synthetic teacher',
          score: 4.2,
          ratingCount: 9,
          reviewCount: 3,
          terms: terms,
        )
      : null,
);

PublicEvidence _evidence(PublicProvider provider, {EvidenceOrigin? origin}) =>
    PublicEvidence(
      provider: provider,
      title: 'Synthetic evidence',
      articleUrl: Uri.parse('https://example.test/synthetic'),
      observedAtUtc: DateTime.utc(2026, 10, 12),
      origin:
          origin ??
          (provider == PublicProvider.icourse
              ? EvidenceOrigin.online
              : EvidenceOrigin.localKnowledge),
      publishedOn: '2026-01-01',
      revision: 'synthetic-v1',
      locator: '合成定位',
      sourceVersion: 'synthetic-source-v1',
      audience: '合成人群',
      coveredScope: '合成范围',
      quality: EvidenceQuality.reviewedContent,
    );

PublicDocument _document({
  required PublicProvider provider,
  String markdown = 'Synthetic bounded body',
  PublicCourseInfo? course,
  List<PublicReview> reviews = const [],
  EvidenceOrigin? origin,
}) => PublicDocument(
  evidence: _evidence(provider, origin: origin),
  markdown: markdown,
  course: course,
  reviews: reviews,
);

void _captureClipboard(WidgetTester tester, List<String> copied) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text'] as String);
      }
      return null;
    },
  );
}

void _resetClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    null,
  );
}

final class _FakePublicQueryPort implements PublicQueryPort {
  final _changes = StreamController<PublicJobView>.broadcast(sync: true);
  PublicJobView _view = const PublicJobView(phase: PublicJobPhase.idle);
  bool consent = true;
  bool holdNextCourseSearch = false;
  Completer<void>? _courseGate;
  int hasConsentCalls = 0;
  int setConsentCalls = 0;
  int courseSearchCalls = 0;
  int browseCalls = 0;
  int readCampusCalls = 0;
  int retryRecoveryCalls = 0;
  int cancelCalls = 0;
  int closeCalls = 0;
  String? lastCourseKeyword;
  PublicCursor? lastCourseSearchCursor;
  PublicReference? lastCourseReference;
  String? lastCourseTerm;
  CourseReviewSort? lastCourseSort;
  PublicCursor? lastCourseCursor;
  CampusColumn? lastCampusColumn;
  String? lastCampusKeyword;
  PublicReference? lastCampusReference;
  int? lastCampusSectionStart;
  int? lastCampusMaxCharacters;
  PublicCursor? lastCampusReadCursor;
  PublicFailure? courseFailure;
  List<PublicQueryResult> courseSearchPages = [_result()];
  PublicQueryResult courseReadResult = _result(
    document: _document(provider: PublicProvider.icourse),
  );
  PublicQueryResult campusBrowseResult = _result();
  PublicQueryResult campusReadResult = _result(
    document: _document(
      provider: PublicProvider.teach,
      origin: EvidenceOrigin.online,
    ),
  );
  List<PublicQueryResult> campusReadPages = [];
  bool holdNextCampusRead = false;
  Completer<PublicQueryResult>? _campusReadGate;

  @override
  PublicJobView get view => _view;

  @override
  Stream<PublicJobView> get changes => _changes.stream;

  void emit(PublicJobView value) {
    _view = value;
    _changes.add(value);
  }

  @override
  Future<bool> hasIcourseConsent() async {
    hasConsentCalls++;
    return consent;
  }

  @override
  Future<void> setIcourseConsent(bool allowed) async {
    setConsentCalls++;
    consent = allowed;
  }

  @override
  Future<PublicQueryResult> searchCourses(
    String keywords, {
    int pageSize = 20,
    PublicCursor? cursor,
  }) async {
    courseSearchCalls++;
    lastCourseKeyword = keywords;
    lastCourseSearchCursor = cursor;
    if (holdNextCourseSearch) {
      holdNextCourseSearch = false;
      _courseGate = Completer<void>();
      emit(const PublicJobView(phase: PublicJobPhase.requesting));
      await _courseGate!.future;
      _courseGate = null;
      emit(const PublicJobView(phase: PublicJobPhase.idle));
    }
    if (courseFailure != null) throw courseFailure!;
    final index = courseSearchCalls - 1;
    return courseSearchPages[index < courseSearchPages.length ? index : 0];
  }

  void completeCourseSearch() {
    final gate = _courseGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<PublicQueryResult> readCourse(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 10,
    PublicCursor? cursor,
  }) async {
    lastCourseReference = reference;
    lastCourseTerm = term;
    lastCourseSort = sort;
    lastCourseCursor = cursor;
    return courseReadResult;
  }

  @override
  Future<PublicQueryResult> browseCampus(
    CampusColumn column, {
    String? keywords,
    int pageSize = 20,
    PublicCursor? cursor,
  }) async {
    browseCalls++;
    lastCampusColumn = column;
    lastCampusKeyword = keywords;
    return campusBrowseResult;
  }

  @override
  Future<PublicQueryResult> readCampusArticle(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) async {
    readCampusCalls++;
    lastCampusReference = reference;
    lastCampusSectionStart = sectionStart;
    lastCampusMaxCharacters = maxCharacters;
    lastCampusReadCursor = cursor;
    if (holdNextCampusRead) {
      holdNextCampusRead = false;
      _campusReadGate = Completer<PublicQueryResult>();
      emit(const PublicJobView(phase: PublicJobPhase.requesting));
      return _campusReadGate!.future;
    }
    final index = readCampusCalls - 1;
    return campusReadPages.isNotEmpty && index < campusReadPages.length
        ? campusReadPages[index]
        : campusReadResult;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final gate = _campusReadGate;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(const PublicFailure(PublicFailureCode.cancelled));
    }
    emit(const PublicJobView(phase: PublicJobPhase.idle));
  }

  @override
  Future<void> retryRecovery() async {
    retryRecoveryCalls++;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  Future<void> dispose() => _changes.close();
}

final class _FakeKnowledgePort implements KnowledgePort {
  KnowledgeSummary summary = const KnowledgeSummary(
    materialCount: 4,
    sectionCount: 12,
    loadCount: 2,
    loading: false,
    edition: 'private-edition-name',
  );
  PublicQueryResult knowledgeSearchResult = _result();
  PublicQueryResult knowledgeReadResult = _result(
    document: _document(provider: PublicProvider.teach),
  );
  List<PublicQueryResult> knowledgeReadPages = [];
  bool holdNextLoad = false;
  Completer<KnowledgeLoadOutcome>? _loadGate;
  int inspectCalls = 0;
  int searchCalls = 0;
  int readCalls = 0;
  int loadCalls = 0;
  int cancelLoadCalls = 0;
  int clearCalls = 0;
  String? lastSearchKeyword;
  PublicReference? lastReadReference;
  int? lastReadSectionStart;
  int? lastReadMaxCharacters;
  PublicCursor? lastReadCursor;
  bool? lastClearConfirmed;

  @override
  Future<KnowledgeSummary> inspectKnowledge() async {
    inspectCalls++;
    return summary;
  }

  @override
  Future<PublicQueryResult> searchKnowledge(
    String keywords, {
    PublicProvider? provider,
    String? topic,
    String? audience,
    String? version,
    int pageSize = 20,
    PublicCursor? cursor,
  }) async {
    searchCalls++;
    lastSearchKeyword = keywords;
    return knowledgeSearchResult;
  }

  @override
  Future<PublicQueryResult> readKnowledgeMaterial(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) async {
    readCalls++;
    lastReadReference = reference;
    lastReadSectionStart = sectionStart;
    lastReadMaxCharacters = maxCharacters;
    lastReadCursor = cursor;
    final index = readCalls - 1;
    return knowledgeReadPages.isNotEmpty && index < knowledgeReadPages.length
        ? knowledgeReadPages[index]
        : knowledgeReadResult;
  }

  @override
  Future<KnowledgeLoadOutcome> loadBundledEdition() {
    loadCalls++;
    if (!holdNextLoad) {
      return Future.value(
        const KnowledgeLoadOutcome(
          state: KnowledgeLoadState.done,
          accepted: 1,
          unchanged: 3,
          total: 4,
        ),
      );
    }
    holdNextLoad = false;
    _loadGate = Completer<KnowledgeLoadOutcome>();
    return _loadGate!.future;
  }

  @override
  Future<void> cancelKnowledgeLoad() async {
    cancelLoadCalls++;
    final gate = _loadGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete(
        const KnowledgeLoadOutcome(
          state: KnowledgeLoadState.cancelled,
          accepted: 1,
          unchanged: 0,
          total: 4,
        ),
      );
    }
  }

  @override
  Future<void> clearKnowledge({required bool confirmed}) async {
    clearCalls++;
    lastClearConfirmed = confirmed;
    summary = const KnowledgeSummary(
      materialCount: 0,
      sectionCount: 0,
      loadCount: 2,
      loading: false,
    );
  }

  Future<void> dispose() async {}
}
