// Design basis: docs/architecture/07-12 and docs/reference/sources/campus.md.
// This Android QA test
// uses one app-private temporary owner, loopback HTTP, and approved bundled
// public materials only. It does not contact a school or model endpoint.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/knowledge_service.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/bundled_knowledge_loader.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';
import 'package:ustc_assistant_m0/source/public_html_parser.dart';
import 'package:ustc_assistant_m0/source/public_source_contract.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
const _fixturePrefix = 'a3_public_';
final _clock = FixedClock(DateTime.utc(2026, 10, 16, 1));
const _articlePath = '/service/svc-student/2690.html';
const _reimbursementPath = '/2021/0128/c22118a470108/page.psp';
const _listingHtml =
    '''
<html><body>
  <ul class="article-list with-tag">
    <li class="post type-post status-publish post-2690">
      <span class="post"><a href="$_articlePath">A3合成公告</a></span>
    </li>
  </ul>
</body></html>
''';
final _articleBody = List<String>.filled(120, 'A3合成正文。').join();
final _articleHtml =
    '''
<html><body>
  <article id="post-2690" class="post type-post status-publish">
    <h1>A3合成公告</h1>
    <p>$_articleBody</p>
    <figure class="photo photo-large align-none">
      <img src="/wp-content/uploads/a3-public-flow.png" alt="合成流程图">
    </figure>
  </article>
</body></html>
''';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object>{
    'schoolVerified': false,
    'modelConnected': false,
  };

  testWidgets(
    'Android public HTTP and bundled knowledge stay within a temporary private owner',
    (tester) async {
      await tester.runAsync(() async {
        final fixtureRoot = await _createFixtureRoot();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = Uri(
          scheme: 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
        );
        final targets = PublicHttpTargets.loopback({
          for (final provider in PublicProvider.values) provider: origin,
        });
        final parser = _LoopbackParser(origin);
        final cancellationReceived = Completer<void>();
        final releaseCancellation = Completer<void>();
        final cancellationHandlerDone = Completer<void>();
        final serverHandlerFailures = <String>[];
        var listingRequests = 0;
        var articleRequests = 0;
        var financeRequests = 0;
        final serverSubscription = server.listen((request) {
          unawaited(() async {
            try {
              if (request.uri.path == '/category/notice') {
                listingRequests++;
                if (request.uri.queryParameters['s'] == 'redirect') {
                  request.response
                    ..statusCode = HttpStatus.found
                    ..headers.set(HttpHeaders.locationHeader, '/ywzn/list.psp');
                  await request.response.close();
                  return;
                }
                if (request.uri.queryParameters['s'] == 'cancel') {
                  final response = request.response
                    ..statusCode = HttpStatus.ok
                    ..headers.set(
                      HttpHeaders.contentTypeHeader,
                      'text/html; charset=utf-8',
                    )
                    ..headers.chunkedTransferEncoding = true;
                  response.write('<html><body>');
                  await response.flush();
                  cancellationReceived.complete();
                  await releaseCancellation.future;
                  try {
                    response.write(_listingHtml);
                    await response.close();
                  } on HttpException {
                    // Expected: cancellation has already closed the client.
                  } on SocketException {
                    // Expected: cancellation has already closed the client.
                  }
                  return;
                }
                await _reply(request, _listingHtml);
                return;
              }
              if (request.uri.path == _articlePath) {
                articleRequests++;
                await _reply(request, _articleHtml);
                return;
              }
              if (request.uri.path == '/ywzn/list.psp') {
                financeRequests++;
                await _reply(
                  request,
                  '<html><body>unexpected route</body></html>',
                );
                return;
              }
              await _reply(
                request,
                '<html><body>unexpected route</body></html>',
              );
            } on Object catch (error) {
              serverHandlerFailures.add(error.runtimeType.toString());
            } finally {
              if (request.uri.queryParameters['s'] == 'cancel' &&
                  !cancellationHandlerDone.isCompleted) {
                cancellationHandlerDone.complete();
              }
            }
          }());
        });

        _AndroidA3Harness? harness;
        var canRemoveFixture = false;
        try {
          harness = await _AndroidA3Harness.open(
            fixturePath: fixtureRoot.directory.path,
            targets: targets,
            parser: parser,
          );
          expect(JwStore.currentSchemaVersion, 20);

          final listing = await harness.queries.browseCampus(
            CampusColumn.teachNotice,
            pageSize: 1,
          );
          expect(listing.candidates, hasLength(1));
          expect(listing.candidates.single.title, 'A3合成公告');
          expect(listing.candidates.single.evidence.publishedOn, isNull);
          expect(listing.coverage.listingOrder, PublicListingOrder.unknown);
          expect(listing.coverage.complete, isTrue);
          await harness.queries.ensurePublicResult(listing);

          var article = await harness.queries.readCampusArticle(
            listing.candidates.single.reference,
            maxCharacters: 80,
          );
          expect(article.document, isNotNull);
          expect(article.next, isNotNull);
          expect(article.coverage.complete, isFalse);
          var continuationCount = 1;
          while (article.next != null) {
            article = await harness.queries.readCampusArticle(
              listing.candidates.single.reference,
              maxCharacters: 80,
              cursor: article.next,
            );
            continuationCount++;
          }
          expect(continuationCount, greaterThan(1));
          expect(article.coverage.complete, isFalse);
          expect(listingRequests, 1);
          expect(articleRequests, 1);
          report['publicListingReturned'] = listing.coverage.returned;
          report['articleContinuationPages'] = continuationCount;
          report['unknownDatePreserved'] = true;
          report['incompleteArticlePreserved'] = true;

          await expectLater(
            harness.queries.browseCampus(
              CampusColumn.teachNotice,
              keywords: 'redirect',
              pageSize: 1,
            ),
            throwsA(
              isA<PublicFailure>().having(
                (failure) => failure.code,
                'code',
                PublicFailureCode.unsafeTarget,
              ),
            ),
          );
          expect(financeRequests, 0);
          report['unregisteredRedirectRejected'] = true;

          for (final column in [
            CampusColumn.financeBusiness,
            CampusColumn.financeFaq,
          ]) {
            await expectLater(
              harness.queries.browseCampus(
                column,
                keywords: column == CampusColumn.financeBusiness ? '报销' : null,
                pageSize: 1,
              ),
              throwsA(
                isA<PublicFailure>().having(
                  (failure) => failure.code,
                  'code',
                  PublicFailureCode.unavailable,
                ),
              ),
            );
          }
          expect(financeRequests, 0);
          report['financeSearchAndFaqUnavailable'] = true;

          final delayed = harness.queries.browseCampus(
            CampusColumn.teachNotice,
            keywords: 'cancel',
            pageSize: 1,
          );
          final delayedFailure = expectLater(
            delayed,
            throwsA(
              isA<PublicFailure>().having(
                (failure) => failure.code,
                'code',
                PublicFailureCode.cancelled,
              ),
            ),
          );
          await cancellationReceived.future.timeout(const Duration(seconds: 5));
          expect(harness.leases.isBusy, isTrue);
          expect((await harness.campusState()).activeJob, isNotNull);
          await expectLater(
            harness.queries.browseCampus(
              CampusColumn.teachNotice,
              keywords: 'must not start while C2 is occupied',
              pageSize: 1,
            ),
            throwsA(
              isA<PublicFailure>().having(
                (failure) => failure.code,
                'code',
                PublicFailureCode.busy,
              ),
            ),
          );
          await harness.queries.cancel().timeout(const Duration(seconds: 5));
          await delayedFailure;
          final cancelledCampusState = await harness.campusState();
          expect(cancelledCampusState.activeJob, isNull);
          releaseCancellation.complete();
          await cancellationHandlerDone.future.timeout(
            const Duration(seconds: 5),
          );
          expect(await harness.campusState(), cancelledCampusState);
          expect(serverHandlerFailures, isEmpty);
          report['cancelReleasedC3Job'] = true;
          report['lateListingAccepted'] = false;
          report['c3UnchangedAfterLateResponse'] = true;

          final initialKnowledge = await harness.knowledge.inspectKnowledge();
          expect(initialKnowledge.materialCount, 0);
          final loaded = await harness.knowledge.loadBundledEdition();
          expect(loaded.state, KnowledgeLoadState.done);
          expect(loaded.accepted, 7);
          expect(loaded.total, 7);
          var summary = await harness.knowledge.inspectKnowledge();
          expect(summary.materialCount, 7);
          expect(summary.edition, isNotNull);

          final deferred = await _searchAndRead(
            harness.knowledge,
            keyword: '缓考',
            articlePath: '/service/svc-student/2690.html',
          );
          final reimbursement = await _searchAndRead(
            harness.knowledge,
            keyword: '报销',
            articlePath: _reimbursementPath,
          );
          expect(deferred.origin, EvidenceOrigin.localKnowledge);
          expect(reimbursement.origin, EvidenceOrigin.localKnowledge);
          expect(deferred.applicability, MaterialApplicability.unknown);
          expect(reimbursement.applicability, MaterialApplicability.unknown);
          expect(deferred.quality, EvidenceQuality.reviewedContent);
          expect(reimbursement.quality, EvidenceQuality.reviewedContent);

          final repeated = await harness.knowledge.loadBundledEdition();
          expect(repeated.state, KnowledgeLoadState.done);
          expect(repeated.accepted, 0);
          expect(repeated.unchanged, 7);
          summary = await harness.knowledge.inspectKnowledge();
          expect(summary.materialCount, 7);
          report['bundledMaterialsLoaded'] = summary.materialCount;
          report['repeatedLoadUnchanged'] = repeated.unchanged;
          report['knowledgeApplicabilityUnknown'] = true;

          await harness.close();
          harness = null;
          harness = await _AndroidA3Harness.open(
            fixturePath: fixtureRoot.directory.path,
            targets: targets,
            parser: parser,
          );
          summary = await harness.knowledge.inspectKnowledge();
          expect(summary.materialCount, 7);
          expect(summary.loadCount, 2);
          await _searchAndRead(
            harness.knowledge,
            keyword: '缓考',
            articlePath: '/service/svc-student/2690.html',
          );
          report['knowledgeSurvivedReopen'] = true;

          await harness.knowledge.clearKnowledge(confirmed: true);
          expect((await harness.knowledge.inspectKnowledge()).materialCount, 0);
          await harness.close();
          harness = null;
          harness = await _AndroidA3Harness.open(
            fixturePath: fixtureRoot.directory.path,
            targets: targets,
            parser: parser,
          );
          summary = await harness.knowledge.inspectKnowledge();
          expect(summary.materialCount, 0);
          expect(summary.loadCount, 0);
          report['knowledgeClearSurvivedReopen'] = true;
          canRemoveFixture = true;
        } finally {
          if (!releaseCancellation.isCompleted) {
            releaseCancellation.complete();
          }
          try {
            await harness?.close();
            canRemoveFixture = true;
          } on Object {
            canRemoveFixture = false;
          }
          await serverSubscription.cancel();
          await server.close(force: true);
          final removed =
              canRemoveFixture && await _removeFixtureRoot(fixtureRoot);
          report['cleanupComplete'] = removed;
          report['fixtureRetained'] = !removed;
          if (!removed) {
            throw StateError('A3 synthetic fixture cleanup is incomplete');
          }
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  tearDown(() => binding.reportData = report);
}

Future<PublicEvidence> _searchAndRead(
  KnowledgeService knowledge, {
  required String keyword,
  required String articlePath,
}) async {
  final search = await knowledge.searchKnowledge(keyword, pageSize: 20);
  final candidates = search.candidates
      .where((candidate) => candidate.evidence.articleUrl.path == articlePath)
      .toList();
  expect(candidates, hasLength(1));
  final read = await knowledge.readKnowledgeMaterial(
    candidates.single.reference,
  );
  expect(read.document, isNotNull);
  expect(read.document!.markdown, isNotEmpty);
  expect(read.coverage.complete, isTrue);
  expect(read.document!.evidence.applicability, MaterialApplicability.unknown);
  expect(read.document!.evidence.coveredScope, isNotEmpty);
  return read.document!.evidence;
}

Future<void> _reply(HttpRequest request, String html) async {
  request.response
    ..statusCode = HttpStatus.ok
    ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
    ..write(html);
  await request.response.close();
}

Future<_QaFixtureRoot> _createFixtureRoot() async {
  final privateRoot = await _platform
      .invokeMethod<String>('privateDataRoot')
      .timeout(const Duration(seconds: 5));
  if (privateRoot == null ||
      !p.posix.isAbsolute(privateRoot) ||
      p.posix.normalize(privateRoot) != privateRoot ||
      !privateRoot.contains('/cn.ustcassistant.mobile.qa/') ||
      !privateRoot.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('Only the isolated Android QA no-backup root is allowed.');
  }
  if (await Directory(privateRoot).resolveSymbolicLinks() != privateRoot) {
    throw StateError('Android QA root is not canonical.');
  }
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final directory = Directory(
    p.posix.join(privateRoot, '$_fixturePrefix$suffix'),
  );
  await directory.create();
  if (await directory.resolveSymbolicLinks() != directory.path) {
    throw StateError('Android A3 fixture path is not canonical.');
  }
  return _QaFixtureRoot(privateRoot, directory);
}

Future<bool> _removeFixtureRoot(_QaFixtureRoot fixtureRoot) async {
  final path = fixtureRoot.directory.path;
  final name = p.posix.basename(path);
  if (!RegExp(r'^a3_public_[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(name) ||
      p.posix.dirname(path) != fixtureRoot.privateRoot ||
      !p.posix.isWithin(fixtureRoot.privateRoot, path) ||
      p.posix.normalize(path) != path) {
    return false;
  }
  try {
    if (await Directory(fixtureRoot.privateRoot).resolveSymbolicLinks() !=
        fixtureRoot.privateRoot) {
      return false;
    }
    if (!await fixtureRoot.directory.exists()) return true;
    if (await fixtureRoot.directory.resolveSymbolicLinks() != path) {
      return false;
    }
    await Directory(path).delete(recursive: true);
    return !await Directory(path).exists();
  } on Object {
    return false;
  }
}

final class _QaFixtureRoot {
  const _QaFixtureRoot(this.privateRoot, this.directory);
  final String privateRoot;
  final Directory directory;
}

final class _AndroidA3Harness {
  _AndroidA3Harness({
    required this.directories,
    required this.store,
    required this.leases,
    required this.queries,
    required this.knowledge,
  });

  final AndroidDirectories directories;
  final JwStore store;
  final WorkLeasePool leases;
  final PublicQueryCoordinator queries;
  final KnowledgeService knowledge;
  bool _closed = false;

  static Future<_AndroidA3Harness> open({
    required String fixturePath,
    required PublicHttpTargets targets,
    required PublicSourceParser parser,
  }) async {
    AndroidDirectories? directories;
    JwStore? store;
    PublicQueryCoordinator? queries;
    KnowledgeService? knowledge;
    try {
      directories = await AndroidDirectories.acquire(fixturePath);
      store = JwStore(
        openJwDatabase(directories.formal),
        ownership: directories.formal,
        clock: _clock,
        modelCredentialProtector: _SyntheticModelCredentialProtector(),
      );
      await store.initialize().timeout(const Duration(seconds: 45));
      final leases = WorkLeasePool();
      queries = PublicQueryCoordinator(
        store: store.publicStore,
        leases: leases,
        clock: _clock,
        targets: targets,
        parser: parser,
        sessionFactory: (source) =>
            IoPublicHttpSession(targets: targets, source: source),
      );
      knowledge = KnowledgeService(
        store: store.publicStore,
        loader: BundledKnowledgeLoader().load,
      );
      return _AndroidA3Harness(
        directories: directories,
        store: store,
        leases: leases,
        queries: queries,
        knowledge: knowledge,
      );
    } on Object {
      await queries?.close();
      await knowledge?.close();
      await store?.close();
      if (directories != null) {
        await directories.formal.release();
        await directories.demo.release();
      }
      rethrow;
    }
  }

  Future<({int generation, int sequence, String? activeJob})>
  campusState() async {
    final row = await store
        .customSelect(
          'SELECT generation,sequence,active_job FROM public_sources WHERE source=?',
          variables: [Variable.withString(PublicSource.campus.name)],
        )
        .getSingle();
    return (
      generation: row.read<int>('generation'),
      sequence: row.read<int>('sequence'),
      activeJob: row.read<String?>('active_job'),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    await queries.close();
    await knowledge.close();
    await store.close();
    directories.formal.ensureDatabaseFilesSafe(filename: 'jw.sqlite');
    for (final suffix in ['', '-wal', '-shm']) {
      directories.formal.checkedChildPath('jw.sqlite$suffix', directory: false);
    }
    await directories.formal.release();
    await directories.demo.release();
    _closed = true;
  }
}

/// Adapts only the fixed parser's source origin to the in-process test server.
/// The parser still validates the current HTML shape and extracts the fields.
final class _LoopbackParser implements PublicSourceParser {
  _LoopbackParser(this.origin);
  final Uri origin;
  final FixedPublicHtmlParser _parser = const FixedPublicHtmlParser();

  Uri _canonical(Uri uri, PublicProvider provider) => uri.replace(
    scheme: 'https',
    host: switch (provider) {
      PublicProvider.icourse => 'icourse.club',
      PublicProvider.teach => 'www.teach.ustc.edu.cn',
      PublicProvider.finance => 'finance.ustc.edu.cn',
    },
    port: 443,
  );

  Uri _loopback(Uri uri) => origin.replace(
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  );

  SourcePublicPage _page(SourcePublicPage page) => SourcePublicPage(
    items: [
      for (final item in page.items)
        SourcePublicItem(
          key: item.key,
          title: item.title,
          uri: _loopback(item.uri),
          provider: item.provider,
          publishedOn: item.publishedOn,
          snippet: item.snippet,
          course: item.course,
        ),
    ],
    nextPage: page.nextPage == null ? null : _loopback(page.nextPage!),
    totalReported: page.totalReported,
    excluded: page.excluded,
    listingOrder: page.listingOrder,
  );

  SourcePublicDocument _document(SourcePublicDocument document) =>
      SourcePublicDocument(
        provider: document.provider,
        title: document.title,
        uri: _loopback(document.uri),
        markdown: document.markdown,
        publishedOn: document.publishedOn,
        updatedOn: document.updatedOn,
        course: document.course,
        reviews: document.reviews,
        attachmentLinks: document.attachmentLinks,
        excluded: document.excluded,
        contentComplete: document.contentComplete,
      );

  @override
  SourcePublicPage courses(String html, Uri uri) =>
      _page(_parser.courses(html, _canonical(uri, PublicProvider.icourse)));

  @override
  SourcePublicDocument course(String html, Uri uri) =>
      _document(_parser.course(html, _canonical(uri, PublicProvider.icourse)));

  @override
  SourcePublicPage campus(String html, Uri uri, CampusColumn column) =>
      _page(_parser.campus(html, _canonical(uri, column.provider), column));

  @override
  SourcePublicDocument article(String html, Uri uri, PublicProvider provider) =>
      _document(_parser.article(html, _canonical(uri, provider), provider));
}

final class _SyntheticModelCredentialProtector
    implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-a3-public-only/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext.map((byte) => byte ^ 0xA5).toList());

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0xA5).toList());
}
