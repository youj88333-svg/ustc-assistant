import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/reminder_contract.dart';

/// UserNotifications adapter for the private iOS host.
///
/// The native side owns the OS queue and serializes operations. This adapter
/// keeps ownership of a timed-out channel call until its native result drains,
/// so a late mutation cannot overlap a newer one.
final class IOSNotifications
    implements
        NotificationPlatformPort,
        NotificationActivationStatusPort,
        NotificationPublicationControlPort,
        NotificationSystemControlPort {
  IOSNotifications()
    : _channel = const MethodChannel(_channelName),
      _callTimeout = const Duration(seconds: 8),
      _startTimeout = const Duration(seconds: 16),
      _permissionTimeout = const Duration(seconds: 90),
      _testing = false {
    _listen();
  }

  @visibleForTesting
  IOSNotifications.forTesting(
    this._channel, {
    this._callTimeout = const Duration(seconds: 8),
    this._startTimeout = const Duration(seconds: 16),
    this._permissionTimeout = const Duration(seconds: 90),
  }) : _testing = true {
    _listen();
  }

  static const _channelName = 'ustc_assistant/ios_notifications_v1';
  static const _maximumPending = 60;
  static const _maximumRememberedActivations = 1024;
  static const _maximumQueuedActivations = 32;
  static const _safeIntegerMaximum = 8640000000000000;

  final MethodChannel _channel;
  final Duration _callTimeout, _startTimeout, _permissionTimeout;
  final bool _testing;
  final _activations = StreamController<NotificationActivation>.broadcast();
  final _failures = StreamController<ReminderFailure>.broadcast();
  final _pendingActivations = Queue<NotificationActivation>();
  final _seenActivations = <String>{};
  final _activationOrder = Queue<String>();
  Future<Object?>? _owned;
  Future<NotificationCapability>? _initializing;
  Future<void>? _closing;
  bool _closed = false;
  bool _initialized = false;
  bool _capabilityAvailable = false;
  bool _ready = false;
  bool _draining = false;
  bool _drainRequested = false;

  bool get _supported =>
      _testing || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Stream<NotificationActivation> get activations => _activations.stream;

  @override
  Stream<ReminderFailure> get activationFailures => _failures.stream;

  void _listen() {
    _activations.onListen = () {
      _drainRequested = true;
      scheduleMicrotask(_deliverQueuedActivations);
      scheduleMicrotask(_drainActivations);
    };
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'activationsChanged' || call.arguments != null) {
        throw MissingPluginException();
      }
      _drainRequested = true;
      _drainActivations();
      return null;
    });
  }

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    if (_closed || _closing != null) {
      throw const ReminderFailure(ReminderFailureCode.closed);
    }
    if (!_supported) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }

    final predecessor = _owned;
    final started = Completer<void>();
    var abandoned = false;
    var callerTimedOut = false;
    var rawCompleted = false;
    var rawSucceeded = false;
    var lateResultAccepted = false;
    Object? completedValue;

    void acceptTimedOutTakeIfReady() {
      if (method != 'takeActivations' ||
          !callerTimedOut ||
          !rawCompleted ||
          !rawSucceeded ||
          lateResultAccepted) {
        return;
      }
      lateResultAccepted = true;
      _acceptLateActivations(completedValue);
    }

    Future<Object?> invokeNative() {
      started.complete();
      if (abandoned || _closed) {
        throw const ReminderFailure(ReminderFailureCode.closed);
      }
      return _channel.invokeMethod<Object?>(method, arguments);
    }

    final raw = predecessor == null
        ? invokeNative()
        : predecessor.then<Object?>(
            (_) => invokeNative(),
            onError: (Object _, StackTrace _) => invokeNative(),
          );
    _owned = raw;
    if (method == 'takeActivations') {
      // Native take consumes its cold-start queue when it replies. Observe the
      // underlying future so a caller timeout cannot discard a successful
      // late batch. Other methods deliberately get no late-success path.
      unawaited(
        raw.then<void>(
          (value) {
            rawCompleted = true;
            rawSucceeded = true;
            completedValue = value;
            acceptTimedOutTakeIfReady();
          },
          onError: (Object _, StackTrace _) {
            rawCompleted = true;
            rawSucceeded = false;
          },
        ),
      );
    }
    unawaited(
      raw.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(
        () {
          if (identical(_owned, raw)) _owned = null;
          scheduleMicrotask(_drainActivations);
        },
      ),
    );

    try {
      await started.future.timeout(
        _startTimeout,
        onTimeout: () {
          // A queued mutation that gives up must not begin after its caller
          // has already received a timeout result.
          abandoned = true;
          throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
        },
      );
      return await raw.timeout(
        method == 'requestNotifications' ? _permissionTimeout : _callTimeout,
      );
    } on TimeoutException {
      callerTimedOut = true;
      acceptTimedOutTakeIfReady();
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    } on PlatformException catch (error) {
      throw ReminderFailure(switch (error.code) {
        'invalid_input' => ReminderFailureCode.invalidInput,
        'stale' => ReminderFailureCode.stale,
        'maintenance' || 'busy' => ReminderFailureCode.maintenance,
        'disabled_by_system' => ReminderFailureCode.disabledBySystem,
        'capacity_reached' => ReminderFailureCode.capacityReached,
        'publish_failed' => ReminderFailureCode.publishFailed,
        'cancel_failed' => ReminderFailureCode.cancelFailed,
        'cleanup_pending' => ReminderFailureCode.cleanupPending,
        'storage_failed' => ReminderFailureCode.storageFailed,
        'closed' => ReminderFailureCode.closed,
        _ => ReminderFailureCode.platformUnavailable,
      }, nativeFailure: _nativeFailure(error.details));
    } on ReminderFailure {
      rethrow;
    } catch (_) {
      // Do not expose native exception text, arguments, or notification data.
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
  }

  static Never _invalid() =>
      throw const ReminderFailure(ReminderFailureCode.invalidInput);

  static NotificationNativeFailure? _nativeFailure(Object? raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('domain') ||
        !raw.containsKey('code')) {
      return null;
    }
    final domain = NotificationErrorDomain.values
        .where((value) => value.name == raw['domain'])
        .firstOrNull;
    final code = raw['code'];
    if (domain == null ||
        code != null && (code is! int || code < -32768 || code > 32767)) {
      return null;
    }
    return NotificationNativeFailure(domain, code as int?);
  }

  static Map<Object?, Object?> _map(Object? raw, Set<String> fields) {
    if (raw is! Map ||
        raw.length != fields.length ||
        !fields.every(raw.containsKey)) {
      _invalid();
    }
    return raw;
  }

  static String _opaque(Object? value, int minimum, int maximum) {
    if (value is! String ||
        value.length < minimum ||
        value.length > maximum ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      _invalid();
    }
    return value;
  }

  static int _integer(Object? value, {int maximum = _safeIntegerMaximum}) {
    if (value is! int || value < 0 || value > maximum) _invalid();
    return value;
  }

  static String _text(Object? value, int maximum, {bool required = false}) {
    if (value is! String ||
        value.runes.length > maximum ||
        required && value.trim().isEmpty ||
        value.runes.any(
          (scalar) =>
              scalar < 32 ||
              scalar >= 127 && scalar <= 159 ||
              scalar >= 0xd800 && scalar <= 0xdfff,
        )) {
      _invalid();
    }
    return value;
  }

  static Map<String, Object> _identity(NotificationRequest request) {
    if (!request.deliveryAtUtc.isUtc) _invalid();
    return {
      'id': _opaque(request.id, 1, 16),
      'deliveryAtUnixMs': _integer(
        request.deliveryAtUtc.millisecondsSinceEpoch,
      ),
      'digest': _opaque(request.digest, 64, 64),
      'token': _opaque(request.token, 16, 64),
    };
  }

  static const _capabilityFields = <String>{
    'available',
    'enabledBySystem',
    'schedulesAfterExit',
    'activationAvailable',
    'exactScheduling',
    'queueEvidence',
    'maximumPending',
    'authorizationStatus',
    'alertsEnabled',
    'soundsEnabled',
    'lockScreenEnabled',
    'scheduledSummaryEnabled',
  };

  NotificationCapability _capability(Object? raw) {
    final map = _map(raw, _capabilityFields);
    for (final field in const [
      'available',
      'enabledBySystem',
      'schedulesAfterExit',
      'activationAvailable',
    ]) {
      if (map[field] is! bool) _invalid();
    }
    if (map['exactScheduling'] != null ||
        map['queueEvidence'] != 'operatingSystem' ||
        map['maximumPending'] != _maximumPending) {
      _invalid();
    }
    for (final field in const [
      'alertsEnabled',
      'soundsEnabled',
      'lockScreenEnabled',
      'scheduledSummaryEnabled',
    ]) {
      if (map[field] != null && map[field] is! bool) _invalid();
    }
    final authorizationStatus = switch (map['authorizationStatus']) {
      'unknown' => NotificationAuthorizationStatus.unknown,
      'notDetermined' => NotificationAuthorizationStatus.notDetermined,
      'denied' => NotificationAuthorizationStatus.denied,
      'authorized' => NotificationAuthorizationStatus.authorized,
      'provisional' => NotificationAuthorizationStatus.provisional,
      'ephemeral' => NotificationAuthorizationStatus.ephemeral,
      _ => _invalid(),
    };

    return NotificationCapability(
      available: map['available'] as bool,
      enabledBySystem: map['enabledBySystem'] as bool,
      schedulesAfterExit: map['schedulesAfterExit'] as bool,
      activationAvailable: map['activationAvailable'] as bool,
      exactScheduling: null,
      queueEvidence: NotificationQueueEvidence.operatingSystem,
      maximumPending: _maximumPending,
      authorizationStatus: authorizationStatus,
      alertsEnabled: map['alertsEnabled'] as bool?,
      soundsEnabled: map['soundsEnabled'] as bool?,
      lockScreenEnabled: map['lockScreenEnabled'] as bool?,
      scheduledSummaryEnabled: map['scheduledSummaryEnabled'] as bool?,
    );
  }

  Future<NotificationCapability> _readCapability(String method) async {
    final capability = _capability(await _invoke(method));
    if (method == 'initialize') _initialized = true;
    _capabilityAvailable =
        capability.available && capability.activationAvailable;
    _ready = _initialized && _capabilityAvailable;
    _drainRequested = true;
    scheduleMicrotask(_drainActivations);
    return capability;
  }

  @override
  Future<NotificationCapability> initialize() => _initializing ??= () async {
    try {
      return await _readCapability('initialize');
    } finally {
      _initializing = null;
    }
  }();

  Future<void> _void(String method, [Object? arguments]) async {
    if (await _invoke(method, arguments) != null) _invalid();
  }

  @override
  Future<void> bindPublication(ReminderPublication publication) async {
    final allowed = <String, Map<String, Object>>{};
    if (publication.enabled) {
      for (final mapping in publication.prior) {
        if (!publication.invalidPriorIds.contains(mapping.request.id)) {
          allowed[mapping.request.id] = _identity(mapping.request);
        }
      }
      for (final mapping in publication.desired) {
        allowed[mapping.request.id] = _identity(mapping.request);
      }
    }
    if (allowed.length > 2048) _invalid();
    await _void('bindPublication', {
      'authority': {
        'owner': _opaque(publication.context.owner, 1, 96),
        'resetEpoch': _integer(publication.context.resetEpoch),
        'agendaEpoch': _integer(publication.context.agendaEpoch),
        'revision': _integer(publication.revision),
        'enabled': publication.enabled,
      },
      'allowed': allowed.values.toList(growable: false),
    });
  }

  @override
  Future<void> blockDelivery() => _void('blockDelivery');

  @override
  Future<void> schedule(NotificationRequest request) async {
    await _void('schedule', {
      ..._identity(request),
      'title': _text(request.title, 160, required: true),
      'detail': _text(request.detail, 240),
      'location': _text(request.location, 160),
    });
  }

  @override
  Future<List<NotificationPending>> pending() async {
    final raw = await _invoke('pending');
    if (raw is! List || raw.length > 2048) _invalid();
    final ids = <String>{};
    return raw
        .map((item) {
          final map = _map(item, {
            'id',
            'deliveryAtUnixMs',
            'digest',
            'token',
            'title',
            'detail',
            'location',
          });
          final id = _opaque(map['id'], 1, 16);
          if (!ids.add(id)) _invalid();
          return NotificationPending(
            id: id,
            deliveryAtUtc: DateTime.fromMillisecondsSinceEpoch(
              _integer(map['deliveryAtUnixMs']),
              isUtc: true,
            ),
            digest: _opaque(map['digest'], 64, 64),
            token: _opaque(map['token'], 16, 64),
            title: _text(map['title'], 160, required: true),
            detail: _text(map['detail'], 240),
            location: _text(map['location'], 160),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> cancel(String id) => _void('cancel', {'id': _opaque(id, 1, 16)});

  @override
  Future<void> clearOwn() => _void('clear');

  @override
  Future<NotificationCapability> requestNotifications() =>
      _readCapability('requestNotifications');

  @override
  Future<NotificationCapability> requestExactAlarms() =>
      _readCapability('requestExactAlarms');

  @override
  Future<void> openSystemSettings() => _void('openSystemSettings');

  void _deliverQueuedActivations() {
    if (_closed || !_activations.hasListener) return;
    while (_pendingActivations.isNotEmpty) {
      _activations.add(_pendingActivations.removeFirst());
    }
  }

  List<NotificationActivation> _parseActivations(Object? raw) {
    if (raw is! List || raw.length > _maximumQueuedActivations) _invalid();
    return raw
        .map((item) {
          final map = _map(item, {'id', 'digest', 'token'});
          return NotificationActivation(
            _opaque(map['id'], 1, 16),
            _opaque(map['digest'], 64, 64),
            _opaque(map['token'], 16, 64),
          );
        })
        .toList(growable: false);
  }

  void _acceptActivations(Object? raw) {
    // Parse the whole batch before changing local delivery state.
    final parsed = _parseActivations(raw);
    for (final activation in parsed) {
      final key =
          '${activation.id}\u0000${activation.digest}'
          '\u0000${activation.token}';
      if (!_seenActivations.add(key)) continue;
      _activationOrder.addLast(key);
      if (_activationOrder.length > _maximumRememberedActivations) {
        _seenActivations.remove(_activationOrder.removeFirst());
      }
      if (_pendingActivations.length < _maximumQueuedActivations) {
        _pendingActivations.addLast(activation);
      }
    }
    _deliverQueuedActivations();
  }

  void _acceptLateActivations(Object? raw) {
    // close waits for the owned call before closing the streams. If close has
    // already completed, no Dart consumer remains to receive this batch.
    if (_closed) return;
    try {
      _acceptActivations(raw);
    } on ReminderFailure catch (failure) {
      if (!_closed) _failures.add(failure);
    } catch (_) {
      if (!_closed) {
        _failures.add(
          const ReminderFailure(ReminderFailureCode.platformUnavailable),
        );
      }
    }
  }

  void _drainActivations() {
    if (_closed ||
        !_drainRequested ||
        !_ready ||
        !_activations.hasListener ||
        _draining ||
        _owned != null) {
      return;
    }
    _draining = true;
    _drainRequested = false;
    unawaited(() async {
      try {
        final raw = await _invoke('takeActivations');
        if (_closed) return;
        _acceptActivations(raw);
      } on ReminderFailure catch (failure) {
        if (!_closed) _failures.add(failure);
      } finally {
        _draining = false;
        if (_drainRequested) scheduleMicrotask(_drainActivations);
      }
    }());
  }

  @override
  Future<void> close() => _closing ??= () async {
    try {
      final owned = _owned;
      if (owned != null) {
        await owned
            .then<void>((_) {}, onError: (Object _, StackTrace _) {})
            .timeout(_callTimeout);
      }
      _closed = true;
      if (_supported) _channel.setMethodCallHandler(null);
      _pendingActivations.clear();
      await _activations.close();
      await _failures.close();
      // Ordinary close is Dart-only; registered OS notifications remain.
    } catch (_) {
      _closing = null;
      throw const ReminderFailure(ReminderFailureCode.cleanupPending);
    }
  }();
}
