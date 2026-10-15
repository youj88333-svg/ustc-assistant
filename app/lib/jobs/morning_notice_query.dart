import 'dart:async';

import '../core/contracts.dart';
import '../core/morning_notice_contract.dart';
import '../core/public_query_contract.dart';

const _maximumPagesPerProvider = 5;
const _pageSize = 20;
const _maximumOperations = 20;
const _maximumArticleReads = 6;
const _maximumExcerptCharacters = 1000;
const _networkWindow = Duration(seconds: 60);

typedef _NoticeKey = (PublicProvider, Uri);

final class _ProviderPlan {
  const _ProviderPlan(this.provider, this.column);

  final PublicProvider provider;
  final CampusColumn column;
}

const _providerPlans = <_ProviderPlan>[
  _ProviderPlan(PublicProvider.teach, CampusColumn.teachNotice),
  _ProviderPlan(PublicProvider.finance, CampusColumn.financeNotice),
];

final class _CoverageState {
  _CoverageState(this.provider);

  final PublicProvider provider;
  int pages = 0;
  int matched = 0;
  int unknownDates = 0;
  PublicFailureCode? failure;
  bool reachedEnd = false;
  bool truncated = false;

  MorningNoticeCoverage freeze() => MorningNoticeCoverage(
    provider: provider,
    pages: pages,
    matched: matched,
    unknownDates: unknownDates,
    complete: reachedEnd && !truncated && unknownDates == 0 && failure == null,
    failure: failure,
  );
}

final class _ListedNotice {
  _ListedNotice(this.candidate, this.publishedDay);

  final PublicCandidate candidate;
  DateTime? publishedDay;
  bool dateConflict = false;

  void mergeDate(DateTime? incoming) {
    if (incoming == null || dateConflict) return;
    final known = publishedDay;
    if (known == null) {
      publishedDay = incoming;
    } else if (known != incoming) {
      publishedDay = null;
      dateConflict = true;
    }
  }
}

final class _QueryState {
  _QueryState({required this.deadlineUtc});

  final DateTime deadlineUtc;
  final Map<PublicProvider, _CoverageState> coverage = {
    for (final plan in _providerPlans)
      plan.provider: _CoverageState(plan.provider),
  };
  final Map<_NoticeKey, _ListedNotice> listed = {};
  int operations = 0;
}

final class _NetworkDeadlineExceeded implements Exception {
  const _NetworkDeadlineExceeded();
}

final class _QueryCancelled implements Exception {
  const _QueryCancelled();
}

final class _OperationLimitReached implements Exception {
  const _OperationLimitReached();
}

/// Reads the two registered public notice columns within a bounded window.
/// This class never cancels or closes the shared PublicQueryPort.
final class MorningNoticeQuery {
  MorningNoticeQuery({required this.source, required this.clock});

  final PublicQueryPort source;
  final AppClock clock;

  /// Collects notices for the date represented by [day]'s calendar
  /// components. The date is normalized to UTC midnight as a Beijing day key.
  Future<MorningNoticeBatch> collect(
    DateTime day, {
    bool Function()? isCancelled,
  }) async {
    final targetDay = DateTime.utc(day.year, day.month, day.day);
    final startedAtUtc = clock.nowUtc.toUtc();
    final state = _QueryState(deadlineUtc: startedAtUtc.add(_networkWindow));

    try {
      for (final plan in _providerPlans) {
        _checkCancelled(isCancelled);
        await _collectProvider(plan, state, isCancelled);
      }

      final matching = <_ListedNotice>[];
      for (final plan in _providerPlans) {
        final providerRows = state.listed.entries
            .where((entry) => entry.key.$1 == plan.provider)
            .map((entry) => entry.value)
            .toList();
        final coverage = state.coverage[plan.provider]!;
        coverage.unknownDates = providerRows
            .where((row) => row.dateConflict || row.publishedDay == null)
            .length;
        final providerMatches = providerRows
            .where((row) => !row.dateConflict && row.publishedDay == targetDay)
            .toList();
        coverage.matched = providerMatches.length;
        matching.addAll(providerMatches);
      }

      final excerpts = <_NoticeKey, (String, DateTime)>{};
      for (final row in matching.take(_maximumArticleReads)) {
        _checkCancelled(isCancelled);
        final evidence = row.candidate.evidence;
        final key = (evidence.provider, evidence.articleUrl);
        final coverage = state.coverage[evidence.provider]!;
        try {
          final result = await _invokePort(
            state,
            isCancelled,
            () => source.readCampusArticle(
              row.candidate.reference,
              maxCharacters: _maximumExcerptCharacters,
            ),
          );
          final document = result.document;
          if (document == null ||
              document.evidence.provider != evidence.provider ||
              document.evidence.articleUrl != evidence.articleUrl) {
            coverage.failure ??= PublicFailureCode.sourceSchema;
            continue;
          }
          excerpts[key] = (
            _clipRunes(document.markdown, _maximumExcerptCharacters),
            document.evidence.observedAtUtc.toUtc(),
          );
        } on _QueryCancelled {
          rethrow;
        } on _NetworkDeadlineExceeded {
          rethrow;
        } on _OperationLimitReached {
          for (final pending in matching.skipWhile((item) => item != row)) {
            final provider = pending.candidate.evidence.provider;
            state.coverage[provider]!.failure ??=
                PublicFailureCode.resourceLimit;
          }
          break;
        } on PublicFailure catch (failure) {
          coverage.failure ??= failure.code;
        } on Object {
          coverage.failure ??= PublicFailureCode.unavailable;
        }
      }

      final notices = <MorningNotice>[];
      for (final row in matching) {
        final evidence = row.candidate.evidence;
        final key = (evidence.provider, evidence.articleUrl);
        final excerpt = excerpts[key];
        notices.add(
          MorningNotice(
            provider: evidence.provider,
            title: row.candidate.title,
            articleUrl: evidence.articleUrl,
            publishedDay: row.publishedDay!,
            observedAtUtc: excerpt?.$2 ?? evidence.observedAtUtc,
            excerpt: excerpt?.$1 ?? '',
          ),
        );
      }

      final batch = MorningNoticeBatch(
        day: targetDay,
        notices: notices,
        coverage: [
          for (final plan in _providerPlans)
            state.coverage[plan.provider]!.freeze(),
        ],
        operations: state.operations,
      );
      _checkCancelled(isCancelled);
      _ensureBeforeDeadline(state);
      return batch;
    } on _QueryCancelled {
      throw const PublicFailure(PublicFailureCode.cancelled);
    } on _NetworkDeadlineExceeded {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
  }

  Future<void> _collectProvider(
    _ProviderPlan plan,
    _QueryState state,
    bool Function()? isCancelled,
  ) async {
    final coverage = state.coverage[plan.provider]!;
    PublicCursor? cursor;

    while (coverage.pages < _maximumPagesPerProvider && !coverage.reachedEnd) {
      _checkCancelled(isCancelled);
      PublicQueryResult result;
      try {
        result = await _invokePort(
          state,
          isCancelled,
          () => source.browseCampus(
            plan.column,
            pageSize: _pageSize,
            cursor: cursor,
          ),
        );
      } on _QueryCancelled {
        rethrow;
      } on _NetworkDeadlineExceeded {
        rethrow;
      } on _OperationLimitReached {
        coverage.failure ??= PublicFailureCode.resourceLimit;
        return;
      } on PublicFailure catch (failure) {
        coverage.failure ??= failure.code;
        return;
      } on Object {
        coverage.failure ??= PublicFailureCode.unavailable;
        return;
      }

      coverage.pages++;
      for (final candidate in result.candidates) {
        _checkCancelled(isCancelled);
        final evidence = candidate.evidence;
        if (evidence.provider != plan.provider) {
          coverage.failure ??= PublicFailureCode.sourceSchema;
          break;
        }
        final key = (plan.provider, evidence.articleUrl);
        final publishedDay = parseMorningPublishedDay(evidence.publishedOn);
        final prior = state.listed[key];
        if (prior == null) {
          state.listed[key] = _ListedNotice(candidate, publishedDay);
        } else {
          prior.mergeDate(publishedDay);
        }
      }

      if (coverage.failure == PublicFailureCode.sourceSchema) return;
      if (result.next == null) {
        coverage.reachedEnd = true;
        coverage.truncated =
            result.coverage.truncated || !result.coverage.complete;
      } else {
        cursor = result.next;
      }
    }

    if (!coverage.reachedEnd) {
      coverage.truncated = true;
      coverage.failure ??= PublicFailureCode.resourceLimit;
    }
  }

  Future<T> _invokePort<T>(
    _QueryState state,
    bool Function()? isCancelled,
    Future<T> Function() invocation,
  ) async {
    _checkCancelled(isCancelled);
    if (state.operations >= _maximumOperations) {
      throw const _OperationLimitReached();
    }
    final remaining = state.deadlineUtc.difference(clock.nowUtc.toUtc());
    if (remaining <= Duration.zero) {
      throw const _NetworkDeadlineExceeded();
    }

    state.operations++;
    try {
      final result = await invocation().timeout(
        remaining,
        onTimeout: () => throw const _NetworkDeadlineExceeded(),
      );
      _checkCancelled(isCancelled);
      _ensureBeforeDeadline(state);
      return result;
    } on _QueryCancelled {
      rethrow;
    } on Object {
      _checkCancelled(isCancelled);
      _ensureBeforeDeadline(state);
      rethrow;
    }
  }

  void _checkCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const _QueryCancelled();
  }

  void _ensureBeforeDeadline(_QueryState state) {
    if (!clock.nowUtc.toUtc().isBefore(state.deadlineUtc)) {
      throw const _NetworkDeadlineExceeded();
    }
  }

  String _clipRunes(String value, int maximum) =>
      String.fromCharCodes(value.runes.take(maximum));
}
