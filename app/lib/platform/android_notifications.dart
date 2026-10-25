import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/reminder_contract.dart';

/// AlarmManager has no general queue enumeration. A readback here means the
/// private mirror was persisted and the system registration call succeeded.
final class AndroidNotifications
    implements
        NotificationPlatformPort,
        NotificationActivationStatusPort,
        NotificationPublicationControlPort,
        NotificationSystemControlPort {
  AndroidNotifications()
    : _channel = const MethodChannel('ustc_assistant/android_notifications_v1'),
      _testing = false {
    _listen();
  }
  @visibleForTesting
  AndroidNotifications.forTesting(this._channel) : _testing = true {
    _listen();
  }

  final MethodChannel _channel;
  final bool _testing;
  final _activations = StreamController<NotificationActivation>.broadcast();
  final _failures = StreamController<ReminderFailure>.broadcast();
  final _seen = <String>{};
  final _order = Queue<String>();
  Future<Object?>? _owned;
  Future<NotificationCapability>? _initializing;
  Future<void>? _closing;
  bool _closed = false, _draining = false, _drainRequested = false;
  bool _ready = false;
  int _deliveryFailures = 0;
  bool get _supported =>
      _testing || defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<NotificationActivation> get activations => _activations.stream;
  @override
  Stream<ReminderFailure> get activationFailures => _failures.stream;

  void _listen() {
    _activations.onListen = () {
      _drainRequested = true;
      _drain();
    };
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'activationsChanged' || call.arguments != null) {
        throw MissingPluginException();
      }
      _drainRequested = true;
      _drain();
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
    // Keep ownership beyond the caller timeout. A late native result cannot
    // authorize a second overlapping mutation or be mistaken for a new call.
    unawaited(
      raw.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(
        () {
          if (identical(_owned, raw)) _owned = null;
          scheduleMicrotask(_drain);
        },
      ),
    );
    try {
      await started.future.timeout(
        const Duration(seconds: 16),
        onTimeout: () {
          // A queued request that gives up must never start a native mutation
          // later. Its predecessor still owns the channel until it drains.
          abandoned = true;
          throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
        },
      );
      return await raw.timeout(
        Duration(seconds: method == 'requestNotifications' ? 90 : 8),
      );
    } on PlatformException catch (error) {
      throw ReminderFailure(switch (error.code) {
        'invalid_input' => ReminderFailureCode.invalidInput,
        'stale' => ReminderFailureCode.stale,
        'maintenance' || 'busy' => ReminderFailureCode.maintenance,
        'disabled_by_system' => ReminderFailureCode.disabledBySystem,
        'publish_failed' => ReminderFailureCode.publishFailed,
        'cancel_failed' => ReminderFailureCode.cancelFailed,
        'cleanup_pending' => ReminderFailureCode.cleanupPending,
        'storage_failed' => ReminderFailureCode.storageFailed,
        'closed' => ReminderFailureCode.closed,
        _ => ReminderFailureCode.platformUnavailable,
      });
    } catch (_) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
  }

  static Never _invalid() =>
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
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

  static int _integer(Object? value, {int maximum = 8640000000000000}) {
    if (value is! int || value < 0 || value > maximum) _invalid();
    return value;
  }

  static String _text(Object? value, int maximum, {bool required = false}) {
    if (value is! String ||
        value.runes.length > maximum ||
        required && value.trim().isEmpty ||
        value.runes.any(
          (c) => c < 32 || c >= 127 && c <= 159 || c >= 0xd800 && c <= 0xdfff,
        )) {
      _invalid();
    }
    return value;
  }

  static Map<String, Object> _identity(NotificationRequest request) => {
    'id': _opaque(request.id, 1, 16),
    'deliveryAtUnixMs': _integer(request.deliveryAtUtc.millisecondsSinceEpoch),
    'digest': _opaque(request.digest, 64, 64),
    'token': _opaque(request.token, 16, 64),
  };
  NotificationCapability _capability(Object? raw) {
    final map = _map(raw, {
      'available',
      'enabledBySystem',
      'schedulesAfterExit',
      'activationAvailable',
      'exactScheduling',
      'queueEvidence',
      'maximumPending',
      'deliveryFailures',
    });
    for (final field in [
      'available',
      'enabledBySystem',
      'schedulesAfterExit',
      'activationAvailable',
      'exactScheduling',
    ]) {
      if (map[field] is! bool) _invalid();
    }
    if (map['queueEvidence'] != 'localRegistration') _invalid();
    final maximum = _integer(map['maximumPending'], maximum: 512);
    if (maximum < 1) _invalid();
    final failures = _integer(map['deliveryFailures'], maximum: 1000000);
    if (failures > _deliveryFailures && !_closed) {
      _failures.add(const ReminderFailure(ReminderFailureCode.publishFailed));
    }
    _deliveryFailures = failures;
    return NotificationCapability(
      available: map['available'] as bool,
      enabledBySystem: map['enabledBySystem'] as bool,
      schedulesAfterExit: map['schedulesAfterExit'] as bool,
      activationAvailable: map['activationAvailable'] as bool,
      exactScheduling: map['exactScheduling'] as bool,
      queueEvidence: NotificationQueueEvidence.localRegistration,
      maximumPending: maximum,
    );
  }

  @override
  Future<NotificationCapability> initialize() => _initializing ??= () async {
    try {
      final capability = _capability(await _invoke('initialize'));
      _ready = capability.available && capability.activationAvailable;
      _drainRequested = true;
      scheduleMicrotask(_drain);
      return capability;
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
      'allowed': allowed.values.toList(),
    });
  }

  @override
  Future<void> blockDelivery() => _void('blockDelivery');
  @override
  Future<void> schedule(NotificationRequest request) async {
    if (!request.deliveryAtUtc.isUtc) _invalid();
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
  Future<NotificationCapability> requestNotifications() async =>
      _capability(await _invoke('requestNotifications'));
  @override
  Future<NotificationCapability> requestExactAlarms() async =>
      _capability(await _invoke('requestExactAlarms'));
  @override
  Future<void> openSystemSettings() => _void('openSystemSettings');

  void _drain() {
    if (_closed ||
        _closing != null ||
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
        if (_closed || _closing != null) return;
        if (raw is! List || raw.length > 32) _invalid();
        final parsed = raw.map((item) {
          final map = _map(item, {'id', 'digest', 'token'});
          return NotificationActivation(
            _opaque(map['id'], 1, 16),
            _opaque(map['digest'], 64, 64),
            _opaque(map['token'], 16, 64),
          );
        }).toList();
        for (final activation in parsed) {
          final key =
              '${activation.id}/${activation.digest}/${activation.token}';
          if (!_seen.add(key)) continue;
          _order.addLast(key);
          if (_order.length > 1024) _seen.remove(_order.removeFirst());
          _activations.add(activation);
        }
      } on ReminderFailure catch (failure) {
        if (!_closed && _closing == null) _failures.add(failure);
      } finally {
        _draining = false;
        if (_drainRequested) scheduleMicrotask(_drain);
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
            .timeout(const Duration(seconds: 8));
      }
      _closed = true;
      if (_supported) _channel.setMethodCallHandler(null);
      await _activations.close();
      await _failures.close();
      // No native clear/block on ordinary exit: registered alarms outlive Dart.
    } catch (_) {
      _closing = null;
      throw const ReminderFailure(ReminderFailureCode.cleanupPending);
    }
  }();
}
