import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/reminder_contract.dart';

/// The fixed Windows notification channel for this application.
///
/// This adapter only reports what the native bridge confirms. In particular,
/// a successful method-channel call is the boundary at which a schedule is
/// considered accepted by the platform.
final class WindowsNotifications
    implements NotificationPlatformPort, NotificationActivationStatusPort {
  WindowsNotifications()
    : _channel = const MethodChannel('ustc_assistant/notifications'),
      _forTesting = false;

  /// Creates an adapter for a synthetic method-channel messenger.
  ///
  /// This test seam bypasses platform detection. Production callers should use
  /// the default constructor, which always uses the fixed application channel.
  @visibleForTesting
  WindowsNotifications.forTesting(MethodChannel channel)
    : _channel = channel,
      _forTesting = true;

  static const Duration _pollInterval = Duration(milliseconds: 400);
  static const Duration _callTimeout = Duration(seconds: 2);
  static const Duration _closeDrainTimeout = Duration(seconds: 2);
  static const int _maxPending = 1024;
  static const int _maxActivations = 32;
  static const int _maxRememberedActivations = 1024;

  final MethodChannel _channel;
  final bool _forTesting;
  final StreamController<NotificationActivation> _activationController =
      StreamController<NotificationActivation>.broadcast();
  final StreamController<ReminderFailure> _failureController =
      StreamController<ReminderFailure>.broadcast();
  final Queue<String> _activationOrder = Queue<String>();
  final Set<String> _seenActivations = <String>{};

  Future<NotificationCapability>? _initializeFuture;
  Future<void>? _closeFuture;
  Future<Object?>? _activationPollRaw;
  NotificationCapability? _capability;
  Timer? _pollTimer;
  bool _closed = false;
  bool _pollingPaused = false;
  int _generation = 0;

  /// Polling failures are emitted as safe enum-only errors and pause polling.
  /// A caller may explicitly resume with [retryActivationPolling].
  @override
  Stream<ReminderFailure> get activationFailures => _failureController.stream;

  @override
  Stream<NotificationActivation> get activations {
    // Consuming an already-delivered activation does not register an OS
    // identity and must also work after reminders were disabled.
    if (_supported) _startPolling();
    return _activationController.stream;
  }

  bool get _supported =>
      _forTesting || defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<NotificationCapability> initialize() {
    if (_closed) {
      return Future<NotificationCapability>.error(
        const ReminderFailure(ReminderFailureCode.closed),
      );
    }
    return _initializeFuture ??= _initialize().whenComplete(() {
      _initializeFuture = null;
    });
  }

  Future<NotificationCapability> _initialize() async {
    if (!_supported) {
      const capability = NotificationCapability(
        available: false,
        enabledBySystem: false,
        schedulesAfterExit: false,
        activationAvailable: false,
      );
      _capability = capability;
      return capability;
    }

    final raw = await _invoke('initialize', null);
    final capability = _parseCapability(raw);
    if (_closed) {
      throw const ReminderFailure(ReminderFailureCode.closed);
    }
    _capability = capability;
    if (capability.available && capability.activationAvailable) {
      _pollingPaused = false;
      _startPolling();
    }
    return capability;
  }

  @override
  Future<List<NotificationPending>> pending() async {
    _ensureOperational();
    final raw = await _invoke('pending', null);
    return _parsePending(raw);
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    _ensureOperational();
    _validateRequest(request);
    await _invoke('schedule', <String, Object>{
      'id': request.id,
      'deliveryAtUnixMs': request.deliveryAtUtc.millisecondsSinceEpoch,
      'digest': request.digest,
      'token': request.token,
      'title': request.title,
      'detail': request.detail,
      'location': request.location,
    });
  }

  @override
  Future<void> cancel(String id) async {
    _ensureOperational();
    if (!_validOpaque(id, minLength: 1, maxLength: 16)) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    await _invoke('cancel', <String, Object>{'id': id});
  }

  @override
  Future<void> clearOwn() async {
    _ensureOperational();
    final result = await _invoke('clear', null);
    if (result != null) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
  }

  /// Resumes the single 400 ms activation poll after a reported poll failure.
  /// This does not create a second timer or overlap a still-owned native call.
  void retryActivationPolling() {
    if (_closed) {
      throw const ReminderFailure(ReminderFailureCode.closed);
    }
    final capability = _capability;
    if (!_supported ||
        capability == null ||
        !capability.available ||
        !capability.activationAvailable) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    _pollingPaused = false;
    _startPolling();
  }

  void _startPolling() {
    if (_closed ||
        _pollingPaused ||
        _pollTimer != null ||
        _activationPollRaw != null) {
      return;
    }
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_pollActivations());
    });
  }

  Future<void> _pollActivations() async {
    if (_closed || _pollingPaused || _activationPollRaw != null) return;
    final generation = _generation;
    late final Future<Object?> raw;
    try {
      raw = _channel.invokeMethod<Object?>('activations');
    } on Object catch (error) {
      _handlePollFailure(error, generation);
      return;
    }
    _activationPollRaw = raw;
    // Keep ownership until the method-channel future itself settles, even if
    // the bounded wait below times out. This prevents overlapping native polls.
    unawaited(
      raw.then<void>(
        (_) => _releasePoll(raw),
        onError: (Object error, StackTrace stack) => _releasePoll(raw),
      ),
    );

    try {
      final value = await raw.timeout(_callTimeout);
      final parsed = _parseActivations(value);
      if (_closed || generation != _generation) return;
      for (final activation in parsed) {
        final key =
            '${activation.id}\u0000${activation.digest}'
            '\u0000${activation.token}';
        if (!_seenActivations.add(key)) continue;
        _activationOrder.addLast(key);
        if (_activationOrder.length > _maxRememberedActivations) {
          _seenActivations.remove(_activationOrder.removeFirst());
        }
        if (!_closed && generation == _generation) {
          _activationController.add(activation);
        }
      }
    } on Object catch (error) {
      _handlePollFailure(error, generation);
    }
  }

  void _releasePoll(Future<Object?> raw) {
    if (identical(_activationPollRaw, raw)) {
      _activationPollRaw = null;
      if (!_closed && !_pollingPaused) _startPolling();
    }
  }

  void _handlePollFailure(Object error, int generation) {
    if (_closed || generation != _generation) return;
    _pollingPaused = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _failureController.add(_failureFor(error));
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;

    Object? closeError;
    try {
      final initializing = _initializeFuture;
      if (initializing != null) {
        try {
          await initializing.timeout(_closeDrainTimeout);
        } on Object {
          // Keep close bounded if the native initialization is stuck.
        }
      }
      final ownedPoll = _activationPollRaw;
      if (ownedPoll != null) {
        try {
          await ownedPoll.timeout(_closeDrainTimeout);
        } on Object {
          // Poll errors are already normalized by the polling path. A bounded
          // drain allows close to continue if the native messenger is stuck.
        }
      }
      if (_supported) {
        final result = await _invoke('close', null);
        if (result != null) {
          throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
        }
      }
    } on Object catch (error) {
      closeError = error;
    } finally {
      await _activationController.close();
      await _failureController.close();
    }
    if (closeError != null) throw _failureFor(closeError);
  }

  void _ensureOperational() {
    if (_closed) {
      throw const ReminderFailure(ReminderFailureCode.closed);
    }
    if (!_supported) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    final capability = _capability;
    if (capability == null || !capability.available) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
  }

  Future<Object?> _invoke(String method, Object? arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on Object catch (error) {
      throw _failureFor(error);
    }
  }

  static ReminderFailure _failureFor(Object error) {
    if (error is ReminderFailure) return error;
    if (error is PlatformException) {
      final code = switch (error.code) {
        'invalidInput' ||
        'invalid_input' ||
        'bad_arguments' => ReminderFailureCode.invalidInput,
        'stale' => ReminderFailureCode.stale,
        'maintenance' => ReminderFailureCode.maintenance,
        'disabledBySystem' ||
        'disabled_by_system' => ReminderFailureCode.disabledBySystem,
        'publishFailed' ||
        'publish_failed' => ReminderFailureCode.publishFailed,
        'cancelFailed' || 'cancel_failed' => ReminderFailureCode.cancelFailed,
        'cleanupPending' ||
        'cleanup_pending' => ReminderFailureCode.cleanupPending,
        'storageFailed' ||
        'storage_failed' => ReminderFailureCode.storageFailed,
        'closed' => ReminderFailureCode.closed,
        'platformUnavailable' ||
        'platform_unavailable' ||
        'unsupported' => ReminderFailureCode.platformUnavailable,
        _ => ReminderFailureCode.platformUnavailable,
      };
      return ReminderFailure(code);
    }
    return const ReminderFailure(ReminderFailureCode.platformUnavailable);
  }

  static NotificationCapability _parseCapability(Object? raw) {
    final map = _strictMap(raw, const <String>{
      'available',
      'enabledBySystem',
      'schedulesAfterExit',
      'activationAvailable',
    });
    final available = map['available'];
    final enabledBySystem = map['enabledBySystem'];
    final schedulesAfterExit = map['schedulesAfterExit'];
    final activationAvailable = map['activationAvailable'];
    if (available is! bool ||
        enabledBySystem is! bool ||
        schedulesAfterExit is! bool ||
        activationAvailable is! bool) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    return NotificationCapability(
      available: available,
      enabledBySystem: enabledBySystem,
      schedulesAfterExit: schedulesAfterExit,
      activationAvailable: activationAvailable,
    );
  }

  static List<NotificationPending> _parsePending(Object? raw) {
    if (raw is! List || raw.length > _maxPending) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    final result = <NotificationPending>[];
    for (final item in raw) {
      final map = _strictMap(item, const <String>{
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
        'title',
        'detail',
        'location',
      });
      final id = map['id'];
      final deliveryAtUnixMs = map['deliveryAtUnixMs'];
      final digest = map['digest'];
      final token = map['token'];
      final title = map['title'];
      final detail = map['detail'];
      final location = map['location'];
      if (id is! String ||
          !_validOpaque(id, minLength: 1, maxLength: 16) ||
          deliveryAtUnixMs is! int ||
          digest is! String ||
          !_validOpaque(digest, minLength: 64, maxLength: 64) ||
          token is! String ||
          !_validOpaque(token, minLength: 16, maxLength: 64) ||
          title is! String ||
          !_validText(title, minLength: 1, maxLength: 160) ||
          title.trim().isEmpty ||
          detail is! String ||
          !_validText(detail, minLength: 0, maxLength: 240) ||
          location is! String ||
          !_validText(location, minLength: 0, maxLength: 160)) {
        throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
      }
      final deliveryAtUtc = _utcFromMilliseconds(deliveryAtUnixMs);
      result.add(
        NotificationPending(
          id: id,
          deliveryAtUtc: deliveryAtUtc,
          digest: digest,
          token: token,
          title: title,
          detail: detail,
          location: location,
        ),
      );
    }
    return List<NotificationPending>.unmodifiable(result);
  }

  static List<NotificationActivation> _parseActivations(Object? raw) {
    if (raw is! List || raw.length > _maxActivations) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    final result = <NotificationActivation>[];
    for (final item in raw) {
      final map = _strictMap(item, const <String>{'id', 'digest', 'token'});
      final id = map['id'];
      final digest = map['digest'];
      final token = map['token'];
      if (id is! String ||
          !_validOpaque(id, minLength: 1, maxLength: 16) ||
          digest is! String ||
          !_validOpaque(digest, minLength: 64, maxLength: 64) ||
          token is! String ||
          !_validOpaque(token, minLength: 16, maxLength: 64)) {
        throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
      }
      result.add(NotificationActivation(id, digest, token));
    }
    return List<NotificationActivation>.unmodifiable(result);
  }

  static Map<Object?, Object?> _strictMap(
    Object? raw,
    Set<String> expectedKeys,
  ) {
    if (raw is! Map ||
        raw.length != expectedKeys.length ||
        raw.keys.any((key) => key is! String || !expectedKeys.contains(key))) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    return Map<Object?, Object?>.from(raw);
  }

  static void _validateRequest(NotificationRequest request) {
    if (!_validOpaque(request.id, minLength: 1, maxLength: 16) ||
        !_validOpaque(request.digest, minLength: 64, maxLength: 64) ||
        !_validOpaque(request.token, minLength: 16, maxLength: 64) ||
        !request.deliveryAtUtc.isUtc ||
        !_validText(request.title, minLength: 1, maxLength: 160) ||
        request.title.trim().isEmpty ||
        !_validText(request.detail, minLength: 0, maxLength: 240) ||
        !_validText(request.location, minLength: 0, maxLength: 160)) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    _utcFromMilliseconds(request.deliveryAtUtc.millisecondsSinceEpoch);
  }

  static bool _validOpaque(
    String value, {
    required int minLength,
    required int maxLength,
  }) {
    if (value.length < minLength || value.length > maxLength) return false;
    for (final unit in value.codeUnits) {
      final alphaNumeric =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5a) ||
          (unit >= 0x61 && unit <= 0x7a);
      if (!alphaNumeric && unit != 0x5f && unit != 0x2d) return false;
    }
    return true;
  }

  static bool _validText(
    String value, {
    required int minLength,
    required int maxLength,
  }) {
    final length = value.runes.length;
    if (length < minLength || length > maxLength) return false;
    for (final rune in value.runes) {
      if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) return false;
    }
    return true;
  }

  static DateTime _utcFromMilliseconds(int milliseconds) {
    try {
      final value = DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      );
      if (value.millisecondsSinceEpoch != milliseconds) {
        throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
      }
      return value;
    } on ReminderFailure {
      rethrow;
    } on Object {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
  }
}
