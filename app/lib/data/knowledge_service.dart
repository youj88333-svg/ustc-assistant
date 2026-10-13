import 'dart:async';

import '../core/knowledge_contract.dart';
import '../core/public_query_contract.dart';
import '../core/settings_contract.dart';
import 'jw_store.dart';

typedef KnowledgeEditionLoader = Future<KnowledgeEdition> Function();

/// Local maintenance is separate from the source lease and read-only ports.
/// The ticket exists before the asset await, so clear/cancel rejects late work.
final class KnowledgeService implements KnowledgePort {
  KnowledgeService({
    required this.store,
    required this.loader,
    this.assetTimeout = const Duration(seconds: 15),
  });
  final PublicStore store;
  final KnowledgeEditionLoader loader;
  final Duration assetTimeout;
  Future<void>? _work;
  KnowledgeLoadTicket? _ticket;
  bool _cancelled = false, _closing = false, _clearing = false;

  bool get isLoading => _work != null;

  void _open() {
    if (_closing) throw const PublicFailure(PublicFailureCode.closed);
  }

  @override
  Future<KnowledgeSummary> inspectKnowledge() {
    _open();
    return store.inspectKnowledge();
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
  }) {
    _open();
    return store.searchKnowledge(
      keywords,
      provider: provider,
      topic: topic,
      audience: audience,
      version: version,
      pageSize: pageSize,
      cursor: cursor,
    );
  }

  @override
  Future<PublicQueryResult> readKnowledgeMaterial(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) {
    _open();
    return store.readKnowledgeMaterial(
      reference,
      sectionStart: sectionStart,
      maxCharacters: maxCharacters,
      cursor: cursor,
    );
  }

  void _check() {
    if (_cancelled || _closing || _ticket?.cancelled == true) {
      throw const PublicFailure(PublicFailureCode.cancelled);
    }
  }

  @override
  Future<KnowledgeLoadOutcome> loadBundledEdition() async {
    _open();
    if (_work != null || _clearing) {
      throw const PublicFailure(PublicFailureCode.busy);
    }
    final done = Completer<void>();
    _work = done.future;
    _cancelled = false;
    try {
      // A previous failed settlement is retried before admitting a new batch.
      if (_ticket != null) {
        await store.finishKnowledgeLoad(
          _ticket!,
          KnowledgeLoadState.failed,
          failure: PublicFailureCode.storageFailed,
        );
        _ticket = null;
      }
      _ticket = await store.beginKnowledgeLoad();
      _check();
      final edition = await loader().timeout(assetTimeout);
      _check();
      await store.bindKnowledgeEdition(_ticket!, edition);
      for (final material in edition.materials) {
        _check();
        await store.acceptKnowledgeMaterial(_ticket!, material);
      }
      _check();
      final result = await store.finishKnowledgeLoad(
        _ticket!,
        KnowledgeLoadState.done,
      );
      _ticket = null;
      return result;
    } on Object catch (error) {
      final code = error is PublicFailure
          ? error.code
          : error is TimeoutException
          ? PublicFailureCode.resourceLimit
          : PublicFailureCode.sourceSchema;
      final state = code == PublicFailureCode.cancelled
          ? KnowledgeLoadState.cancelled
          : KnowledgeLoadState.failed;
      final ticket = _ticket;
      if (ticket == null) {
        return KnowledgeLoadOutcome(
          state: state,
          accepted: 0,
          unchanged: 0,
          total: 0,
          failure: code,
        );
      }
      try {
        final result = await store.finishKnowledgeLoad(
          ticket,
          state,
          failure: code,
        );
        _ticket = null;
        return result;
      } on Object {
        // Keep the unsettled capability for retry/close. Committed counters
        // reflect prior commits, never the failed transaction callback.
        return KnowledgeLoadOutcome(
          state: KnowledgeLoadState.failed,
          accepted: ticket.accepted,
          unchanged: ticket.unchanged,
          total: ticket.total,
          failure: PublicFailureCode.storageFailed,
        );
      }
    } finally {
      _work = null;
      done.complete();
    }
  }

  @override
  Future<void> cancelKnowledgeLoad() async {
    _cancelled = true;
    await store.cancelKnowledgeLoad();
    await _work;
    if (_ticket != null) {
      await store.finishKnowledgeLoad(
        _ticket!,
        KnowledgeLoadState.cancelled,
        failure: PublicFailureCode.cancelled,
      );
      _ticket = null;
    }
  }

  @override
  Future<void> clearKnowledge({
    required bool confirmed,
    SettingsContext? expectedSettingsContext,
  }) async {
    _open();
    if (!confirmed) throw const PublicFailure(PublicFailureCode.invalidRequest);
    if (_clearing) throw const PublicFailure(PublicFailureCode.busy);
    _clearing = true;
    try {
      // Persist invalidation before awaiting the bounded asset batch. A late
      // loader cannot accept data, and the product reports done only on drain.
      await store.clearKnowledge(
        confirmed: true,
        expectedSettingsContext: expectedSettingsContext,
      );
      _cancelled = true;
      await _work;
      if (_ticket != null) {
        await store.finishKnowledgeLoad(
          _ticket!,
          KnowledgeLoadState.cancelled,
          failure: PublicFailureCode.cancelled,
        );
        _ticket = null;
      }
    } finally {
      _clearing = false;
    }
  }

  Future<void> close() async {
    _closing = true;
    await cancelKnowledgeLoad();
  }
}
