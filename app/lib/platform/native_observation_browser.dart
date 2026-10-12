import 'dart:async';

import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../source/jw_authentication_contract.dart';
import '../source/jw_collection_contract.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';
import '../source/observation_contract.dart';
import '../source/young_observation_contract.dart';
import '../source/young_read_only_contract.dart';
import '../source/young_active_contract.dart';

/// P-only fixed operations; no arbitrary script, URL or session asset API.
final class NativeObservationBrowser
    implements
        ObservationBrowserPort,
        JwProbeBrowserPort,
        JwDataProbeBrowserPort,
        JwCollectionBrowserPort,
        JwAuthenticationBrowserPort,
        YoungAuthenticationBrowserPort,
        YoungInspectionBrowserPort,
        YoungReadOnlyBrowserPort,
        YoungBusinessBrowserPort,
        YoungBusinessPreparationBrowserPort {
  NativeObservationBrowser({
    MethodChannel? channel,
    this.fixtureDeniedUri,
    this.fixtureUpgradeFromOrigin,
    this.fixtureUpgradeToOrigin,
    this.fixtureCertificatePem,
  }) : _channel =
           channel ?? const MethodChannel('ustc_assistant/observation_v1') {
    _channel.setMethodCallHandler(_onMethod);
  }
  final MethodChannel _channel;
  // The native Debug build validates this fixed loopback test destination.
  final Uri? fixtureDeniedUri;
  final Uri? fixtureUpgradeFromOrigin;
  final Uri? fixtureUpgradeToOrigin;
  final String? fixtureCertificatePem;
  final _events = StreamController<BrowserEvent>.broadcast();
  ObservationTarget? _target;
  int? _session;
  bool _disposed = false;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  Future<JwLoginState> _loginCall(
    String method, {
    required int session,
    required int document,
    required int operation,
    JwSecretLease? credentials,
  }) async {
    final source = method == 'advanceYoungLogin' || method == 'submitYoungLogin'
        ? ObservationSource.young
        : ObservationSource.jw;
    if (_target?.source != source) {
      credentials?.revoke();
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (session != _session || document < 0 || operation <= 0) {
      credentials?.revoke();
      throw const AppFailure(FailureCode.staleResult);
    }
    final bytes = credentials?.take();
    try {
      final result = await _invoke<Object>(method, {
        'session': session,
        'document': document,
        'operation': operation,
        'credentialBytes': ?bytes,
      });
      final states = JwLoginState.values.where((state) => state.name == result);
      if (states.length != 1) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      return states.single;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<JwLoginState> advanceJwLogin({
    required int session,
    required int document,
    required int operation,
  }) => _loginCall(
    'advanceJwLogin',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<JwLoginState> submitJwLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  }) => _loginCall(
    'submitJwLogin',
    session: session,
    document: document,
    operation: operation,
    credentials: credentials,
  );

  @override
  Future<JwLoginState> advanceYoungLogin({
    required int session,
    required int document,
    required int operation,
  }) => _loginCall(
    'advanceYoungLogin',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<JwLoginState> submitYoungLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  }) => _loginCall(
    'submitYoungLogin',
    session: session,
    document: document,
    operation: operation,
    credentials: credentials,
  );

  String? _origin(Object? value) =>
      value is String && (_target?.allowedOrigins.contains(value) ?? false)
      ? value
      : null;

  BrowserDiagnostic? _diagnostic(Object? value) {
    if (value is! Map) return null;
    final codes = BrowserDiagnosticCode.values.where(
      (code) => code.name == value['code'],
    );
    final sites = BrowserDiagnosticSite.values.where(
      (site) => site.name == value['site'],
    );
    final schemes = BrowserDiagnosticScheme.values.where(
      (scheme) => scheme.name == value['scheme'],
    );
    if (codes.isEmpty || sites.isEmpty || schemes.isEmpty) return null;
    return BrowserDiagnostic(
      code: codes.single,
      site: sites.single,
      scheme: schemes.single,
    );
  }

  Future<void> _onMethod(MethodCall call) async {
    if (_disposed || call.method != 'event') return;
    final session = _session;
    if (session == null) return;
    final data = call.arguments;
    if (data is! Map ||
        data['session'] != session ||
        data['document'] is! int ||
        (data['document'] as int) < 0) {
      return;
    }
    final kind = BrowserEventKind.values.where(
      (item) => item.name == data['kind'],
    );
    if (kind.isEmpty) return;
    final diagnostic = _diagnostic(data['diagnostic']);
    if (kind.single == BrowserEventKind.diagnostic && diagnostic == null) {
      return;
    }
    _events.add(
      BrowserEvent(
        session: session,
        document: data['document'] as int,
        kind: kind.single,
        origin: _origin(data['origin']),
        diagnostic: diagnostic,
      ),
    );
  }

  Future<T?> _invoke<T>(String method, Map<String, Object> args) async {
    if (_disposed) throw const AppFailure(FailureCode.closed);
    const jwMethods = {
      'navigateJwPage',
      'advanceJwLogin',
      'submitJwLogin',
      'readJwProbe',
      'pollJwProbe',
      'cancelJwProbe',
      'readJwDataProbe',
      'pollJwDataProbe',
      'cancelJwDataProbe',
      'readJwCollection',
      'pollJwCollection',
      'cancelJwCollection',
    };
    if (jwMethods.contains(method) && _target?.source != ObservationSource.jw) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    const youngMethods = {
      'advanceYoungLogin',
      'submitYoungLogin',
      'prepareYoungBusinessPage',
      'startYoungReadOnly',
      'readYoungReadOnly',
      'stopYoungReadOnly',
      'startYoungBusiness',
      'dispatchYoungBusinessStep',
      'pollYoungBusinessStep',
      'finishYoungBusiness',
      'navigateYoungBusinessPage',
    };
    if (youngMethods.contains(method) &&
        _target?.source != ObservationSource.young) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    } on PlatformException catch (error) {
      if (error.code == 'app_failure' &&
          youngMethods.contains(method) &&
          error.details is Map) {
        final detail = error.details as Map;
        final codes = FailureCode.values.where((v) => v.name == detail['code']);
        final reasons = YoungBusinessRejection.values.where(
          (v) => v.name == detail['reason'],
        );
        if (detail.length == 2 && codes.length == 1 && reasons.length == 1) {
          throw YoungBusinessException(codes.single, reasons.single);
        }
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      final matches = FailureCode.values.where(
        (code) => code.name == error.details,
      );
      throw AppFailure(
        error.code == 'app_failure' && matches.isNotEmpty
            ? matches.single
            : FailureCode.sourceFailed,
      );
    } catch (_) {
      throw const AppFailure(FailureCode.sourceFailed);
    }
  }

  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    _session = session;
    _target = target;
    await _invoke<void>('open', {
      'session': session,
      'profilePath': profilePath,
      'initialUrl': target.initialUri.toString(),
      'source': target.source.name,
      'allowedOrigins': target.allowedOrigins,
      'testMode': target.isFixture,
      'recoveryOnly': recoveryOnly,
      if (target.isFixture && fixtureDeniedUri != null)
        'fixtureDeniedUrl': fixtureDeniedUri.toString(),
      if (target.isFixture && fixtureUpgradeFromOrigin != null)
        'fixtureUpgradeFromOrigin': fixtureUpgradeFromOrigin.toString(),
      if (target.isFixture && fixtureUpgradeToOrigin != null)
        'fixtureUpgradeToOrigin': fixtureUpgradeToOrigin.toString(),
      if (target.isFixture && fixtureCertificatePem != null)
        'fixtureCertificatePem': fixtureCertificatePem!,
    });
  }

  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) async {
    final result = await _invoke<Object>('inspect', {
      'session': session,
      'document': document,
    });
    if (result is! Map ||
        result['session'] != session ||
        result['document'] != document ||
        result['ready'] is! bool) {
      throw const AppFailure(FailureCode.staleResult);
    }
    return BrowserInspection(
      session: session,
      document: document,
      ready: result['ready'] as bool,
      origin: _origin(result['origin']),
    );
  }

  @override
  Future<YoungPageInspection> inspectYoungPage({
    required int session,
    required int document,
  }) async {
    if (_target?.source != ObservationSource.young) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (session != _session || document < 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final result = await _invoke<Object>('inspectYoungPage', {
      'session': session,
      'document': document,
    });
    return YoungPageInspection.decode(
      result,
      session: session,
      document: document,
    );
  }

  @override
  Future<YoungReadOnlyInspection> startYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) => _youngReadOnlyCall(
    'startYoungReadOnly',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<YoungReadOnlyInspection> readYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) => _youngReadOnlyCall(
    'readYoungReadOnly',
    session: session,
    document: document,
    operation: operation,
  );

  Future<YoungReadOnlyInspection> _youngReadOnlyCall(
    String method, {
    required int session,
    required int document,
    required int operation,
  }) async {
    if (session != _session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final result = await _invoke<Object>(method, {
      'session': session,
      'document': document,
      'operation': operation,
    });
    return YoungReadOnlyInspection.decode(
      result,
      session: session,
      document: document,
      operation: operation,
    );
  }

  @override
  Future<void> stopYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) async {
    if (session != _session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    await _invoke<void>('stopYoungReadOnly', {
      'session': session,
      'document': document,
      'operation': operation,
    });
  }

  void _youngBusinessBinding(int session, int document, [int operation = 1]) {
    if (_target?.source != ObservationSource.young) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (_session != session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  @override
  Future<void> startYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _youngBusinessBinding(session, document, operation);
    await _invoke<void>('startYoungBusiness', {
      'session': session,
      'document': document,
      'operation': operation,
    });
  }

  @override
  Future<void> dispatchYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
    required YoungBusinessEndpoint endpoint,
    int page = 0,
    String? day,
  }) async {
    _youngBusinessBinding(session, document, operation);
    if (step <= 0 ||
        step > 64000 ||
        page < 0 ||
        page > 1000 ||
        (endpoint == YoungBusinessEndpoint.profile &&
            (page != 0 || day != null)) ||
        (endpoint != YoungBusinessEndpoint.profile && page == 0) ||
        (endpoint == YoungBusinessEndpoint.schedule
            ? day == null
            : day != null)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    await _invoke<void>('dispatchYoungBusinessStep', {
      'session': session,
      'document': document,
      'operation': operation,
      'step': step,
      'endpoint': endpoint.name,
      'page': page,
      'day': ?day,
    });
  }

  @override
  Future<YoungBusinessStepReply> pollYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
  }) async {
    _youngBusinessBinding(session, document, operation);
    if (step <= 0 || step > 64000) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final result = await _invoke<Object>('pollYoungBusinessStep', {
      'session': session,
      'document': document,
      'operation': operation,
      'step': step,
    });
    return YoungBusinessStepReply.decode(
      result,
      session: session,
      document: document,
      operation: operation,
      step: step,
    );
  }

  @override
  Future<void> finishYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _youngBusinessBinding(session, document, operation);
    await _invoke<void>('finishYoungBusiness', {
      'session': session,
      'document': document,
      'operation': operation,
    });
  }

  @override
  Future<void> navigateYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _youngBusinessBinding(session, document);
    await _invoke<void>('navigateYoungBusinessPage', {
      'session': session,
      'document': document,
      'page': page.name,
    });
  }

  @override
  Future<bool> prepareYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _youngBusinessBinding(session, document);
    final value = await _invoke<Object>('prepareYoungBusinessPage', {
      'session': session,
      'document': document,
      'page': page.name,
    });
    if (value is! bool) throw const AppFailure(FailureCode.invalidSnapshot);
    return value;
  }

  @override
  Future<void> navigateInitial(int session) async =>
      _invoke<void>('navigateInitial', {'session': session});
  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async {
    if (session != _session || document < 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    await _invoke<void>('navigateJwPage', {
      'session': session,
      'document': document,
      'page': page.name,
    });
  }

  @override
  Future<void> close(int session) async =>
      _invoke<void>('close', {'session': session});
  @override
  Future<bool> drained(int session) async =>
      await _invoke<bool>('drained', {'session': session}) ?? false;

  Future<JwProbeReply> _probeCall(
    String method, {
    required int session,
    required int document,
    required int operation,
  }) async {
    if (session != _session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final result = await _invoke<Object>(method, {
      'session': session,
      'document': document,
      'operation': operation,
    });
    if (result is! String) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return JwProbeReply.decode(result, operation: operation);
  }

  @override
  Future<JwProbeReply> startJwProbe({
    required int session,
    required int document,
    required int operation,
  }) => _probeCall(
    'readJwProbe',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<JwProbeReply> pollJwProbe({
    required int session,
    required int document,
    required int operation,
  }) => _probeCall(
    'pollJwProbe',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<JwProbeReply> cancelJwProbe({
    required int session,
    required int document,
    required int operation,
  }) => _probeCall(
    'cancelJwProbe',
    session: session,
    document: document,
    operation: operation,
  );

  Future<JwDataProbeReply> _dataProbeCall(
    String method, {
    required int session,
    required int document,
    required int operation,
    int? semesterId,
  }) async {
    if (session != _session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    if (semesterId != null && (semesterId <= 0 || semesterId > 2147483647)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final result = await _invoke<Object>(method, {
      'session': session,
      'document': document,
      'operation': operation,
      'semesterId': ?semesterId,
    });
    if (result is! String) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return JwDataProbeReply.decode(result, operation: operation);
  }

  @override
  Future<JwDataProbeReply> startJwDataProbe({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  }) => _dataProbeCall(
    'readJwDataProbe',
    session: session,
    document: document,
    operation: operation,
    semesterId: semesterId,
  );

  @override
  Future<JwDataProbeReply> pollJwDataProbe({
    required int session,
    required int document,
    required int operation,
  }) => _dataProbeCall(
    'pollJwDataProbe',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<JwDataProbeReply> cancelJwDataProbe({
    required int session,
    required int document,
    required int operation,
  }) => _dataProbeCall(
    'cancelJwDataProbe',
    session: session,
    document: document,
    operation: operation,
  );

  Future<JwCollectionReply> _collectionCall(
    String method, {
    required int session,
    required int document,
    required int operation,
    int? semesterId,
  }) async {
    if (session != _session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    if (semesterId != null && (semesterId <= 0 || semesterId > 2147483647)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final result = await _invoke<Object>(method, {
      'session': session,
      'document': document,
      'operation': operation,
      'semesterId': ?semesterId,
    });
    if (result is! String) throw const AppFailure(FailureCode.invalidSnapshot);
    return JwCollectionReply.decode(result, operation: operation);
  }

  @override
  Future<JwCollectionReply> startJwCollection({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  }) => _collectionCall(
    'readJwCollection',
    session: session,
    document: document,
    operation: operation,
    semesterId: semesterId,
  );
  @override
  Future<JwCollectionReply> pollJwCollection({
    required int session,
    required int document,
    required int operation,
  }) => _collectionCall(
    'pollJwCollection',
    session: session,
    document: document,
    operation: operation,
  );
  @override
  Future<JwCollectionReply> cancelJwCollection({
    required int session,
    required int document,
    required int operation,
  }) => _collectionCall(
    'cancelJwCollection',
    session: session,
    document: document,
    operation: operation,
  );

  /// Fixture driver only. Release native builds reject every action.
  Future<void> exerciseFixture({
    required int session,
    required int document,
    required String action,
  }) async {
    const actions = {
      'topDenied',
      'frameDenied',
      'popup',
      'authentication',
      'redirectDenied',
      'submitAuthForm',
      'submitFrameAuthForm',
      'frameNext',
      'frameLate',
      'frameSecure',
      'download',
      'permission',
      'external',
      'sameDocument',
      'nextDocument',
      'userClose',
      'youngReadProfile',
      'youngReadSchedule',
      'youngReadActivities',
      'youngConcurrent',
      'youngRedirect',
      'youngWrongMethod',
      'youngFrame',
      'youngWorker',
      'youngLate',
      'youngMalformed',
      'youngSecret',
      'youngCache',
      'youngServiceWorker',
      'youngOversizedRedirect',
      'youngSameUrlPush',
      'youngSameUrlReplace',
      'youngHistoryBack',
      'youngHistoryForward',
      'youngRouteAfterBody',
    };
    if (_target?.isFixture != true || !actions.contains(action)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    await _invoke<void>('exerciseFixture', {
      'session': session,
      'document': document,
      'action': action,
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
