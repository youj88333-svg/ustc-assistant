// M7: `NativeJwGateway` — a `BridgeGateway`-compatible shell over the native
// WebView2 JW collection pipeline.
//
// The minimal sync coordinator (SyncCoordinator) speaks the Bridge protocol
// shape (capabilities / startCollection / poll / resumeLogin / cancel /
// shutdown). This gateway implements that same surface but drives the native
// `JwCollector` over the real `JwWebViewAdapter` instead of a Python Bridge
// child process. The sync layer above is untouched (`SyncCoordinator` /
// `SyncSource` stay identical).
//
// Semantics:
//   - `capabilities()` returns the fixed configured semester
//     (`461 / 2026fall / 2026 秋季学期`, from `generated_source_defaults.dart`).
//     No dynamic semester discovery in minimal (documented boundary).
//   - `startCollection` starts a `JwCollector` job (one collector per job so
//     the gateway-side jobId matches the collector's event stream) and buffers
//     its `SourceCollectionEvent`s in the Bridge poll shape.
//   - `poll` returns new events since `after`, plus the terminal `result`
//     (the SourceBundle map) / `errorCode`.
//   - `resumeLogin` / `cancel` forward to the owning collector; `shutdown`
//     closes the active adapter/page.
//
// Concurrency: the `SyncCoordinator` serializes all sync entry points through
// its `_busy` flag, so this gateway never runs two jobs concurrently in
// practice; `bridge_busy` semantics are preserved at the coordinator layer.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/config/generated_source_defaults.dart';
import '../data/bridge_client.dart'
    show
        BridgeCapabilities,
        BridgeJob,
        BridgeJobPoll,
        BridgeProtocolError,
        BridgeSemesterCapability,
        BridgeGateway;
import '../domain/sync_state.dart' show SyncSource;
import 'jw_collector.dart';
import 'jw_source_bundle_builder.dart' show defaultDartProducer;
import 'jw_web_session.dart' show JwWebviewController;
import 'jw_webview_adapter.dart';
import 'source_collection_gateway.dart';

// Constructor parameters keep public-facing names (not private-field
// initializing formals); the lint is cosmetic only.
// ignore_for_file: prefer_initializing_formals

/// The configured default semester triple (from
/// `core/config/generated_source_defaults.dart`; cannot be derived from the
/// calendar year — red line).
const BridgeSemesterCapability kDefaultJwSemester = BridgeSemesterCapability(
  semesterId: kDefaultJwSemesterId,
  semesterKey: kDefaultJwSemesterKey,
  displayName: kDefaultJwSemesterDisplayName,
);

/// Whether the minimal sync page uses the Python Bridge fallback instead of
/// the native WebView2 channel. Kept at false so the native channel is the
/// default and the Bridge remains switchable for emergency fallback (red line:
/// 一源一通道, never both at once).
const bool kUsePythonBridgeFallback = false;

/// Implements the Bridge gateway surface over the native WebView2 collector.
class NativeJwGateway implements BridgeGateway {
  NativeJwGateway({
    JwWebviewControllerFactory? controllerFactory,
    BridgeSemesterCapability semester = kDefaultJwSemester,
    Future<String> Function()? userDataPath,
    void Function(String)? safeDiagnostic,
  }) : _controllerFactory = controllerFactory,
       _semester = semester,
       _userDataPath = userDataPath,
       _externalDiagnostic = safeDiagnostic;

  final JwWebviewControllerFactory? _controllerFactory;
  final BridgeSemesterCapability _semester;
  final Future<String> Function()? _userDataPath;

  /// Optional caller-supplied privacy-safe diagnostic sink (stage names and
  /// stable error codes only — never URL/account/query/DOM). Wired through to
  /// the adapter's `safeDiagnostic`.
  final void Function(String)? _externalDiagnostic;

  /// Broadcast stream of privacy-safe stage diagnostics emitted by the active
  /// adapter (e.g. `attempt:jw.portal.login`, `activationDispatched`,
  /// `urlMatched:target`, `domReady:target`, …). Zero listeners is safe.
  late final StreamController<String> _diagnosticsController =
      StreamController<String>.broadcast();

  /// Stream of privacy-safe stage diagnostics (see [_externalDiagnostic]).
  Stream<String> get diagnostics => _diagnosticsController.stream;

  /// Forwards a privacy-safe stage to the caller sink and the diagnostics
  /// stream. Never mutates collection behavior; a throwing consumer is safe.
  void _emitDiagnostic(String event) {
    try {
      _externalDiagnostic?.call(event);
      if (!_diagnosticsController.isClosed) {
        _diagnosticsController.add(event);
      }
    } on Object {
      // Diagnostics must never break collection.
    }
  }

  /// The active page adapter's visible WebView (exposed for embedding in the
  /// sync page). One live adapter per active job.
  JwWebViewAdapter? _activeAdapter;
  final Map<String, JwCollector> _collectors = <String, JwCollector>{};
  final Map<String, StreamSubscription<SourceCollectionEvent>>
  _collectorSubscriptions = <String, StreamSubscription<SourceCollectionEvent>>{};
  final Map<String, List<Map<String, dynamic>>> _eventBuffers =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, bool> _terminal = <String, bool>{};
  final Map<String, Map<String, dynamic>?> _results = <String, Map<String, dynamic>?>{};
  final Map<String, String?> _errorCodes = <String, String?>{};
  bool _shutdown = false;

  /// The visible WebView surface (exposed for embedding in the sync page), or
  /// null before the first job starts.
  Widget? get surface => _activeAdapter?.surface;

  Future<JwWebviewController> _controller() async {
    final factory = _controllerFactory;
    if (factory != null) return factory();
    return createProductionJwWebviewController(
      userDataPath: _userDataPath == null ? null : await _userDataPath(),
    );
  }

  JwWebViewAdapter _makeAdapter() => JwWebViewAdapter(
        controllerFactory: _controller,
        safeDiagnostic: _emitDiagnostic,
      );

  @override
  Future<BridgeCapabilities> capabilities() async => BridgeCapabilities(
        jwSemester: _semester,
      );

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    if (_shutdown) throw StateError('gateway is shut down');
    if (source != SyncSource.jw) {
      throw ArgumentError('NativeJwGateway only supports SyncSource.jw');
    }
    final jobId = 'native:${DateTime.now().microsecondsSinceEpoch}';
    final adapter = _makeAdapter();
    _activeAdapter = adapter;

    final collector = JwCollector(
      pageFactory: () => adapter,
      producer: defaultDartProducer,
      jobId: jobId,
    );
    _collectors[jobId] = collector;
    final buffer = <Map<String, dynamic>>[];
    _eventBuffers[jobId] = buffer;
    _terminal[jobId] = false;
    _results[jobId] = null;
    _errorCodes[jobId] = null;

    final subscription = collector
        .startJwCollection(
          accountId: accountId,
          semester: jwSemester.toJwSemesterConfig(),
        )
        .listen(
      (event) {
        if (!_eventBuffers.containsKey(jobId)) return;
        switch (event) {
          case CollectionStarting():
          case CollectionStatus():
          case CollectionNeedsUserLogin():
            buffer.add(<String, dynamic>{
              'sequence': event.sequence,
              'phase': event.phase,
              'jobId': jobId,
              if (event is CollectionStatus) 'message': event.message,
            });
          case CollectionComplete():
            buffer.add(<String, dynamic>{
              'sequence': event.sequence,
              'phase': 'complete',
              'jobId': jobId,
            });
            _results[jobId] = event.bundle;
            _terminal[jobId] = true;
          case CollectionFailed():
            buffer.add(<String, dynamic>{
              'sequence': event.sequence,
              'phase': 'failed',
              'jobId': jobId,
            });
            _errorCodes[jobId] = event.errorCode;
            _terminal[jobId] = true;
          case CollectionCancelled():
            buffer.add(<String, dynamic>{
              'sequence': event.sequence,
              'phase': 'cancelled',
              'jobId': jobId,
            });
            _errorCodes[jobId] = 'cancelled';
            _terminal[jobId] = true;
        }
      },
      onError: (Object _) {
        if (!_eventBuffers.containsKey(jobId)) return;
        buffer.add(<String, dynamic>{
          'sequence': buffer.length,
          'phase': 'failed',
          'jobId': jobId,
        });
        _errorCodes[jobId] = 'collection_failed';
        _terminal[jobId] = true;
      },
    );
    // Keep the subscription referenced so it is not collected early. The
    // collector stream closes itself on a terminal event.
    _collectorSubscriptions[jobId] = subscription;

    return BridgeJob(id: jobId, phase: 'starting');
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    final buffer = _eventBuffers[jobId];
    if (buffer == null) {
      throw const BridgeProtocolError('job_not_found');
    }
    final events = buffer
        .where((event) => (event['sequence'] as int) >= after)
        .toList(growable: false);
    final nextSequence = buffer.isEmpty
        ? after
        : (buffer.last['sequence'] as int) + 1;
    return BridgeJobPoll(
      events: events,
      nextSequence: nextSequence,
      terminal: _terminal[jobId] ?? false,
      result: _results[jobId],
      errorCode: _errorCodes[jobId],
    );
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    final collector = _collectors[jobId];
    if (collector == null) throw const BridgeProtocolError('job_not_found');
    await collector.resumeLogin(jobId, password: password);
  }

  @override
  Future<void> cancel(String jobId) async {
    final collector = _collectors[jobId];
    if (collector == null) return;
    await collector.cancel(jobId);
  }

  @override
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    final adapter = _activeAdapter;
    _activeAdapter = null;
    if (adapter != null) {
      await adapter.close();
    }
    for (final subscription in _collectorSubscriptions.values) {
      await subscription.cancel();
    }
    _collectorSubscriptions.clear();
    _collectors.clear();
    _eventBuffers.clear();
    if (!_diagnosticsController.isClosed) {
      await _diagnosticsController.close();
    }
  }
}

extension on BridgeSemesterCapability {
  JwSemesterConfig toJwSemesterConfig() => JwSemesterConfig(
        semesterId: semesterId,
        semesterKey: semesterKey,
        displayName: displayName,
      );
}
