import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../core/contracts.dart';
import '../core/public_query_contract.dart';
import '../core/settings_contract.dart';
import '../core/work_lease.dart';
import '../data/jw_store.dart';
import '../source/public_html_parser.dart';
import '../source/public_http.dart';
import '../source/public_source_contract.dart';

final class _Reference {
  const _Reference(this.item, this.authority, this.observed, this.expiry);
  final SourcePublicItem item;
  final PublicAuthority authority;
  final DateTime observed;
  final DateTime expiry;
}

sealed class _Continuation {
  const _Continuation(this.intent, this.authority, this.expiry);
  final String intent;
  final PublicAuthority authority;
  final DateTime expiry;
}

final class _ListPage extends _Continuation {
  const _ListPage(
    super.intent,
    super.authority,
    super.expiry,
    this.page,
    this.offset,
    this.observed,
  );
  final SourcePublicPage page;
  final int offset;
  final DateTime observed;
}

final class _CoursePage extends _Continuation {
  const _CoursePage(
    super.intent,
    super.authority,
    super.expiry,
    this.document,
    this.index,
    this.character,
    this.observed,
  );
  final SourcePublicDocument document;
  final int index;
  final int character;
  final DateTime observed;
}

final class _ArticlePage extends _Continuation {
  const _ArticlePage(
    super.intent,
    super.authority,
    super.expiry,
    this.document,
    this.body,
    this.offset,
    this.observed,
  );
  final SourcePublicDocument document;
  final String body;
  final int offset;
  final DateTime observed;
}

/// C2 is the only online admission point. No model, cookie jar or school
/// account is involved; every call owns the existing global source lease.
final class PublicQueryCoordinator
    implements PublicQueryPort, PublicResultGuardPort, PublicReviewReadPort {
  PublicQueryCoordinator({
    required this.store,
    required this.leases,
    this.clock = const SystemClock(),
    PublicHttpTargets? targets,
    PublicSessionFactory? sessionFactory,
    this.parser = const FixedPublicHtmlParser(),
    this.jobTimeout = const Duration(seconds: 60),
    this.drainTimeout = const Duration(seconds: 5),
  }) : targets = targets ?? PublicHttpTargets() {
    _sessions =
        sessionFactory ??
        (source) => IoPublicHttpSession(targets: this.targets, source: source);
  }

  final PublicStore store;
  final WorkLeasePool leases;
  final AppClock clock;
  final PublicHttpTargets targets;
  final PublicSourceParser parser;
  final Duration jobTimeout;
  final Duration drainTimeout;
  late final PublicSessionFactory _sessions;
  final _changes = StreamController<PublicJobView>.broadcast();
  final Map<String, _Reference> _references = {};
  final Map<String, _Continuation> _pages = {};
  final _issuedResults = Expando<(PublicAuthority, DateTime)>();
  PublicJobView _view = const PublicJobView(phase: PublicJobPhase.idle);
  WorkLease? _lease;
  PublicJobTicket? _ticket;
  PublicHttpSession? _session;
  Future<void>? _work;
  bool _cancelled = false, _closing = false;

  @override
  PublicJobView get view => _view;
  @override
  Stream<PublicJobView> get changes => _changes.stream;

  @override
  Future<void> ensurePublicResult(PublicQueryResult result) async {
    final issued = _issuedResults[result];
    if (_closing || issued == null || !clock.nowUtc.isBefore(issued.$2)) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await store.ensureAuthority(issued.$1);
    if (_closing) throw const PublicFailure(PublicFailureCode.cancelled);
  }

  void _publish(
    PublicJobPhase phase, {
    PublicSource? source,
    PublicFailureCode? failure,
    int returned = 0,
  }) {
    _view = PublicJobView(
      phase: phase,
      source: source ?? _view.source,
      failure: failure,
      returned: returned,
    );
    if (!_changes.isClosed) _changes.add(_view);
  }

  @override
  Future<bool> hasIcourseConsent() => store.hasIcourseConsent();
  @override
  Future<void> setIcourseConsent(
    bool allowed, {
    SettingsContext? expectedSettingsContext,
  }) async {
    if (_closing) throw const PublicFailure(PublicFailureCode.closed);
    if (_ticket?.authority.source == PublicSource.icourse) await cancel();
    await store.setIcourseConsent(
      allowed,
      expectedSettingsContext: expectedSettingsContext,
    );
    _forget(PublicSource.icourse);
  }

  void _forget(PublicSource source) {
    _references.removeWhere((_, r) => r.authority.source == source);
    _pages.removeWhere((_, p) => p.authority.source == source);
  }

  void refreshAfterMaintenance() {
    if (_closing ||
        _lease != null ||
        _work != null ||
        _session != null ||
        _ticket != null) {
      throw const PublicFailure(PublicFailureCode.busy);
    }
    _references.clear();
    _pages.clear();
    _view = const PublicJobView(phase: PublicJobPhase.idle);
    _changes.add(_view);
  }

  String _nonce() => List.generate(
    18,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  void _prune() {
    final now = clock.nowUtc;
    _references.removeWhere((_, r) => !now.isBefore(r.expiry));
    _pages.removeWhere((_, p) => !now.isBefore(p.expiry));
    for (final source in PublicSource.values) {
      while (_references.values
              .where((r) => r.authority.source == source)
              .length >=
          256) {
        _references.remove(
          _references.entries
              .firstWhere((e) => e.value.authority.source == source)
              .key,
        );
      }
      while (_pages.values.where((p) => p.authority.source == source).length >=
          256) {
        _pages.remove(
          _pages.entries
              .firstWhere((e) => e.value.authority.source == source)
              .key,
        );
      }
    }
    // Bound the retained anonymous snapshots as well as their count.
    int size(_Continuation p) => switch (p) {
      _ListPage() => p.page.items.fold(
        0,
        (sum, i) => sum + utf8.encode(i.title + i.snippet).length,
      ),
      _ArticlePage() => utf8.encode(p.body).length,
      _CoursePage() => p.document.reviews.fold(
        0,
        (sum, r) => sum + utf8.encode(r.text).length,
      ),
    };
    var bytes = _pages.values.fold<int>(0, (sum, p) => sum + size(p));
    while (bytes > 16 * 1024 * 1024 && _pages.isNotEmpty) {
      final first = _pages.keys.first;
      bytes -= size(_pages.remove(first)!);
    }
  }

  Future<void> _check(PublicJobTicket ticket) async {
    if (_cancelled ||
        _closing ||
        !identical(_ticket, ticket) ||
        _lease?.isHeld != true) {
      throw const PublicFailure(PublicFailureCode.cancelled);
    }
    await store.ensurePublicJob(ticket);
    if (_cancelled || _closing || !identical(_ticket, ticket)) {
      throw const PublicFailure(PublicFailureCode.cancelled);
    }
  }

  Future<PublicQueryResult> _run(
    PublicSource source,
    Future<PublicQueryResult> Function(PublicJobTicket, PublicHttpSession) body,
  ) async {
    if (_closing || _view.phase == PublicJobPhase.closed) {
      throw const PublicFailure(PublicFailureCode.closed);
    }
    if (_lease != null || _view.phase != PublicJobPhase.idle) {
      throw const PublicFailure(PublicFailureCode.busy);
    }
    try {
      _lease = leases.acquire();
    } on AppFailure {
      throw const PublicFailure(PublicFailureCode.busy);
    }
    _cancelled = false;
    final work = Completer<void>();
    _work = work.future;
    _publish(PublicJobPhase.requesting, source: source);
    PublicFailureCode? failed;
    try {
      final ticket = await store.beginPublicJob(source);
      _ticket = ticket;
      await _check(ticket);
      final session = _sessions(source);
      _session = session;
      final result = await body(ticket, session).timeout(jobTimeout);
      await _check(ticket);
      _publish(PublicJobPhase.settling, source: source);
      // A result is not accepted until both transport and C3 settle.
      await session.close().timeout(drainTimeout);
      await _check(ticket);
      await store.finishPublicJob(ticket);
      await store.ensureAuthority(ticket.authority);
      if (_cancelled || _closing) {
        throw const PublicFailure(PublicFailureCode.cancelled);
      }
      _release();
      _publish(
        PublicJobPhase.idle,
        source: source,
        returned: result.document == null
            ? result.candidates.length
            : result.coverage.returned,
      );
      _issuedResults[result] = (
        ticket.authority,
        clock.nowUtc.add(const Duration(minutes: 10)),
      );
      return result;
    } on Object catch (error) {
      failed = error is PublicFailure
          ? error.code
          : error is TimeoutException
          ? PublicFailureCode.resourceLimit
          : PublicFailureCode.sourceSchema;
      _cancelled = true;
      _ticket?.cancelled = true;
      _forget(source);
      try {
        await _abort();
      } on Object {
        _publish(
          PublicJobPhase.recovery,
          source: source,
          failure: PublicFailureCode.cleanupPending,
        );
        throw const PublicFailure(PublicFailureCode.cleanupPending);
      }
      _publish(PublicJobPhase.idle, source: source, failure: failed);
      throw PublicFailure(failed);
    } finally {
      _work = null;
      work.complete();
    }
  }

  void _release() {
    final ticket = _ticket;
    if (ticket != null) store.releasePublicJob(ticket);
    _ticket = null;
    _session = null;
    _lease?.release();
    _lease = null;
  }

  Future<void> _abort() async {
    final session = _session;
    final ticket = _ticket;
    final lease = _lease;
    _publish(PublicJobPhase.settling);
    await session?.close().timeout(drainTimeout);
    if (ticket != null) await store.cancelPublicJob(ticket);
    if (identical(_lease, lease) && identical(_ticket, ticket)) _release();
  }

  @override
  Future<void> cancel() async {
    if (_lease == null) return;
    _cancelled = true;
    _ticket?.cancelled = true;
    // Interrupt I/O promptly; _run remains responsible for C3 and the lease.
    try {
      await _session?.close().timeout(drainTimeout);
    } on Object {
      /* retry in settlement */
    }
    await _work;
    if (_view.phase == PublicJobPhase.recovery) {
      throw const PublicFailure(PublicFailureCode.cleanupPending);
    }
  }

  @override
  Future<void> retryRecovery() async {
    if (_work != null) throw const PublicFailure(PublicFailureCode.busy);
    if (_view.phase != PublicJobPhase.recovery) return;
    final done = Completer<void>();
    _work = done.future;
    try {
      await _abort();
      _publish(PublicJobPhase.idle, failure: PublicFailureCode.cancelled);
    } on Object {
      _publish(
        PublicJobPhase.recovery,
        failure: PublicFailureCode.cleanupPending,
      );
      throw const PublicFailure(PublicFailureCode.cleanupPending);
    } finally {
      _work = null;
      done.complete();
    }
  }

  @override
  Future<void> close() async {
    if (_view.phase == PublicJobPhase.closed) return;
    _closing = true;
    try {
      await cancel();
    } on PublicFailure {
      await retryRecovery();
    }
    if (_lease != null) {
      throw const PublicFailure(PublicFailureCode.cleanupPending);
    }
    _references.clear();
    _pages.clear();
    _publish(PublicJobPhase.closed);
    await _changes.close();
  }

  Future<_Reference> _reference(
    PublicReference reference,
    PublicSource source,
  ) async {
    _prune();
    final value = _references[reference.value];
    if (value == null || value.authority.source != source) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await store.ensureAuthority(value.authority);
    targets.requireAllowed(value.item.uri, source);
    return value;
  }

  Future<_Continuation> _continuation(
    PublicCursor cursor,
    String intent,
    PublicSource source,
  ) async {
    _prune();
    final page = _pages[cursor.value];
    if (page == null ||
        page.intent != intent ||
        page.authority.source != source) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await store.ensureAuthority(page.authority);
    return page;
  }

  PublicCursor _cursor(_Continuation page) {
    _prune();
    final key = _nonce();
    _pages[key] = page;
    return PublicCursor(key);
  }

  PublicEvidence _itemEvidence(SourcePublicItem item, DateTime observed) =>
      PublicEvidence(
        provider: item.provider,
        title: item.title,
        articleUrl: item.uri,
        observedAtUtc: observed,
        origin: EvidenceOrigin.online,
        publishedOn: item.publishedOn,
      );
  PublicEvidence _documentEvidence(
    SourcePublicDocument doc,
    DateTime observed,
    String locator,
  ) => PublicEvidence(
    provider: doc.provider,
    title: doc.title,
    articleUrl: doc.uri,
    observedAtUtc: observed,
    origin: EvidenceOrigin.online,
    publishedOn: doc.publishedOn,
    updatedOn: doc.updatedOn,
    locator: locator,
  );

  Future<PublicHtmlPage> _get(PublicHttpSession session, Uri requested) async {
    final provider = targets.providerFor(requested);
    targets.requireAllowed(requested, provider.source);
    final response = await session.get(requested);
    targets.requireAllowed(response.uri, provider.source);
    String path(Uri value) {
      final normal = value.path.replaceFirst(RegExp(r'/$'), '');
      return provider == PublicProvider.finance
          ? normal.replaceFirst(RegExp(r'\.htm$'), '.psp')
          : normal;
    }

    Map<String, String> intent(Uri value) => SplayTreeMap<String, String>.from({
      for (final entry in value.queryParameters.entries)
        if (entry.value.isNotEmpty &&
            !(entry.key == 'sort_by' && entry.value == 'upvote') &&
            !(entry.key == 'page' && entry.value == '1'))
          entry.key: entry.value,
    });
    if (targets.providerFor(response.uri) != provider ||
        path(requested) != path(response.uri) ||
        fingerprint(intent(requested)) != fingerprint(intent(response.uri))) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return response;
  }

  Future<PublicQueryResult> _listing(
    PublicJobTicket ticket,
    PublicHttpSession session,
    String intent,
    Uri initial,
    int size,
    PublicCursor? cursor,
    SourcePublicPage Function(String, Uri) parse,
  ) async {
    SourcePublicPage page;
    var offset = 0;
    var observed = clock.nowUtc;
    var cached = false;
    if (cursor != null) {
      final old = await _continuation(cursor, intent, ticket.authority.source);
      if (old is! _ListPage) {
        throw const PublicFailure(PublicFailureCode.staleReference);
      }
      page = old.page;
      offset = old.offset;
      observed = old.observed;
      cached = true;
      if (offset >= page.items.length && page.nextPage != null) {
        targets.requireAllowed(page.nextPage!, ticket.authority.source);
        final response = await _get(session, page.nextPage!);
        await _check(ticket);
        page = parse(response.html, response.uri);
        observed = clock.nowUtc;
        offset = 0;
        cached = false;
      }
    } else {
      final response = await _get(session, initial);
      await _check(ticket);
      page = parse(response.html, response.uri);
    }
    if (page.items.length > 256) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    final candidates = <PublicCandidate>[];
    await _check(ticket);
    for (final item in page.items.skip(offset).take(size)) {
      if (item.provider.source != ticket.authority.source) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      targets.requireAllowed(item.uri, ticket.authority.source);
      _prune();
      final key = _nonce();
      _references[key] = _Reference(
        item,
        ticket.authority,
        observed,
        clock.nowUtc.add(const Duration(minutes: 10)),
      );
      candidates.add(
        PublicCandidate(
          reference: PublicReference(key),
          title: item.title,
          evidence: _itemEvidence(item, observed),
          snippet: clipPublicText(item.snippet, 400),
          course: item.course,
        ),
      );
    }
    PublicCursor? next;
    final end = offset + candidates.length;
    if (end < page.items.length || page.nextPage != null) {
      next = _cursor(
        _ListPage(
          intent,
          ticket.authority,
          clock.nowUtc.add(const Duration(minutes: 10)),
          page,
          end,
          observed,
        ),
      );
    }
    return PublicQueryResult(
      candidates: candidates,
      next: next,
      coverage: PublicCoverage(
        scope: ticket.authority.source == PublicSource.icourse
            ? 'courseCandidates'
            : 'selectedCampusColumn',
        returned: candidates.length,
        observed: page.items.length,
        totalReported: page.totalReported,
        excluded: page.excluded,
        truncated: end < page.items.length,
        complete: next == null,
        cached: cached,
      ),
    );
  }

  @override
  Future<PublicQueryResult> searchCourses(
    String keywords, {
    int pageSize = 20,
    PublicCursor? cursor,
  }) {
    final query = publicKeywords(keywords);
    requirePublicPageSize(pageSize);
    return _run(
      PublicSource.icourse,
      (ticket, session) => _listing(
        ticket,
        session,
        fingerprint(['courses', query, pageSize]),
        targets.courseSearch(query),
        pageSize,
        cursor,
        parser.courses,
      ),
    );
  }

  @override
  Future<PublicQueryResult> browseCampus(
    CampusColumn column, {
    String? keywords,
    int pageSize = 20,
    PublicCursor? cursor,
  }) {
    final query = keywords == null || keywords.trim().isEmpty
        ? null
        : publicKeywords(keywords);
    requirePublicPageSize(pageSize);
    if (column == CampusColumn.financeFaq ||
        column.provider == PublicProvider.finance && query != null) {
      return Future.error(const PublicFailure(PublicFailureCode.unavailable));
    }
    return _run(
      PublicSource.campus,
      (ticket, session) => _listing(
        ticket,
        session,
        fingerprint(['campus', column.name, query, pageSize]),
        targets.campusColumn(column, query),
        pageSize,
        cursor,
        (html, uri) => parser.campus(html, uri, column),
      ),
    );
  }

  void _requireDocument(_Reference ref, SourcePublicDocument doc) {
    targets.requireAllowed(doc.uri, ref.authority.source);
    if (doc.provider != ref.item.provider) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    String? identity(Uri uri) {
      final expression = switch (ref.item.provider) {
        PublicProvider.icourse => RegExp(r'^/course/([0-9]+)/$'),
        PublicProvider.teach => RegExp(r'/([0-9]+)\.html$'),
        PublicProvider.finance => RegExp(r'c[0-9]+a([0-9]+)/page\.'),
      };
      return expression.firstMatch(uri.path)?.group(1);
    }

    if (identity(doc.uri) == null ||
        identity(doc.uri) != identity(ref.item.uri) ||
        doc.course != null &&
            (doc.course!.courseKey != ref.item.course?.courseKey ||
                doc.course!.teacher != ref.item.course?.teacher)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
  }

  @override
  Future<PublicQueryResult> readCourse(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 10,
    PublicCursor? cursor,
    int maxCharacters = 12000,
  }) {
    requirePublicPageSize(pageSize);
    requirePublicTextRange(0, maxCharacters);
    if (term != null && !RegExp(r'^[0-9]{1,12}$').hasMatch(term)) {
      return Future.error(
        const PublicFailure(PublicFailureCode.invalidRequest),
      );
    }
    return _run(PublicSource.icourse, (ticket, session) async {
      final ref = await _reference(reference, PublicSource.icourse);
      final intent = fingerprint([
        'course',
        reference.value,
        term,
        sort.name,
        pageSize,
        maxCharacters,
      ]);
      SourcePublicDocument doc;
      var index = 0, character = 0;
      var observed = clock.nowUtc;
      var cached = false;
      if (cursor != null) {
        final old = await _continuation(cursor, intent, PublicSource.icourse);
        if (old is! _CoursePage) {
          throw const PublicFailure(PublicFailureCode.staleReference);
        }
        doc = old.document;
        index = old.index;
        character = old.character;
        observed = old.observed;
        cached = true;
      } else {
        if (term != null) {
          final response = await _get(
            session,
            targets.courseRead(ref.item.uri, null, sort),
          );
          await _check(ticket);
          final base = parser.course(response.html, response.uri);
          _requireDocument(ref, base);
          if (!base.course!.terms.any((t) => t.code == term)) {
            throw const PublicFailure(PublicFailureCode.invalidRequest);
          }
        }
        final response = await _get(
          session,
          targets.courseRead(ref.item.uri, term, sort),
        );
        await _check(ticket);
        doc = parser.course(response.html, response.uri);
        _requireDocument(ref, doc);
        observed = clock.nowUtc;
      }
      final from = index;
      final fromCharacter = character;
      final reviews = <PublicReview>[];
      var budget = maxCharacters;
      while (index < doc.reviews.length &&
          reviews.length < pageSize &&
          budget > 0) {
        final original = doc.reviews[index];
        final runes = original.text.runes.toList();
        final text = String.fromCharCodes(runes.skip(character).take(budget));
        final end = character + text.runes.length;
        reviews.add(
          PublicReview(
            text: text,
            term: original.term,
            locator: '${original.locator} · 字符 $character–$end',
          ),
        );
        budget -= text.runes.length;
        if (end < runes.length) {
          character = end;
          break;
        }
        index++;
        character = 0;
      }
      await _check(ticket);
      PublicCursor? next;
      if (index < doc.reviews.length) {
        next = _cursor(
          _CoursePage(
            intent,
            ticket.authority,
            ref.expiry,
            doc,
            index,
            character,
            observed,
          ),
        );
      }
      return PublicQueryResult(
        document: PublicDocument(
          course: doc.course,
          markdown: doc.markdown,
          evidence: _documentEvidence(doc, observed, '公开点评 $from–$index'),
          reviews: reviews,
        ),
        next: next,
        coverage: PublicCoverage(
          scope: 'observedCourseReviews',
          returned: reviews.length,
          observed: doc.reviews.length,
          totalReported: doc.course?.reviewCount,
          excluded: doc.excluded,
          truncated:
              from > 0 ||
              fromCharacter > 0 ||
              next != null ||
              !doc.contentComplete,
          complete:
              from == 0 &&
              fromCharacter == 0 &&
              next == null &&
              doc.contentComplete,
          cached: cached,
        ),
      );
    });
  }

  @override
  Future<PublicQueryResult> readCourseSlice(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 5,
    int maxCharacters = 2400,
    PublicCursor? cursor,
  }) => readCourse(
    reference,
    term: term,
    sort: sort,
    pageSize: pageSize,
    maxCharacters: maxCharacters,
    cursor: cursor,
  );

  @override
  Future<PublicQueryResult> readCampusArticle(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) {
    requirePublicTextRange(sectionStart, maxCharacters);
    return _run(PublicSource.campus, (ticket, session) async {
      final ref = await _reference(reference, PublicSource.campus);
      final intent = fingerprint([
        'article',
        reference.value,
        sectionStart,
        maxCharacters,
      ]);
      SourcePublicDocument doc;
      String body;
      var offset = 0;
      var observed = clock.nowUtc;
      var cached = false;
      if (cursor != null) {
        final old = await _continuation(cursor, intent, PublicSource.campus);
        if (old is! _ArticlePage) {
          throw const PublicFailure(PublicFailureCode.staleReference);
        }
        doc = old.document;
        body = old.body;
        offset = old.offset;
        observed = old.observed;
        cached = true;
      } else {
        final response = await _get(session, ref.item.uri);
        await _check(ticket);
        doc = parser.article(response.html, response.uri, ref.item.provider);
        _requireDocument(ref, doc);
        final headings = RegExp(
          r'^#{1,6}\s+',
          multiLine: true,
        ).allMatches(doc.markdown).map((m) => m.start).toList();
        if (sectionStart == 0) {
          body = doc.markdown;
        } else if (sectionStart < headings.length) {
          body = doc.markdown.substring(headings[sectionStart]);
        } else {
          throw const PublicFailure(PublicFailureCode.invalidRequest);
        }
        observed = clock.nowUtc;
      }
      final runes = body.runes.toList();
      final text = String.fromCharCodes(runes.skip(offset).take(maxCharacters));
      final end = offset + text.runes.length;
      await _check(ticket);
      PublicCursor? next;
      if (end < runes.length) {
        next = _cursor(
          _ArticlePage(
            intent,
            ticket.authority,
            ref.expiry,
            doc,
            body,
            end,
            observed,
          ),
        );
      }
      return PublicQueryResult(
        document: PublicDocument(
          markdown: text,
          attachmentLinks: doc.attachmentLinks,
          evidence: _documentEvidence(
            doc,
            observed,
            '节 $sectionStart · 字符 $offset–$end',
          ),
        ),
        next: next,
        coverage: PublicCoverage(
          scope: 'selectedArticleText',
          returned: text.runes.length,
          observed: runes.length,
          excluded: doc.excluded,
          truncated: next != null || !doc.contentComplete || offset > 0,
          complete: offset == 0 && next == null && doc.contentComplete,
          cached: cached,
        ),
      );
    });
  }
}
