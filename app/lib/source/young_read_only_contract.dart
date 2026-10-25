import '../core/contracts.dart';

/// A closed value-kind label; it never contains the value it describes.
final class YoungReadOnlyValueKind {
  const YoungReadOnlyValueKind._(this.wire);

  static const String absent = 'absent';
  static const String nullValue = 'null';
  static const String boolean = 'boolean';
  static const String number = 'number';
  static const String string = 'string';
  static const String array = 'array';
  static const String object = 'object';
  static const String mixed = 'mixed';

  static const Set<String> values = <String>{
    absent,
    nullValue,
    boolean,
    number,
    string,
    array,
    object,
    mixed,
  };

  final String wire;

  static YoungReadOnlyValueKind decode(Object? value) {
    if (value is! String || !values.contains(value)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return YoungReadOnlyValueKind._(value);
  }
}

final class YoungReadOnlyProfile {
  const YoungReadOnlyProfile._({
    required this.observations,
    required this.success,
    required this.code,
    required this.result,
    required this.loginCode,
    required this.username,
  });

  static const Set<String> _fields = <String>{
    'observations',
    'success',
    'code',
    'result',
    'loginCode',
    'username',
  };

  final int observations;
  final String success;
  final String code;
  final String result;
  final String loginCode;
  final String username;

  Map<String, Object?> safeSummary() =>
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'observations': observations,
        'success': success,
        'code': code,
        'result': result,
        'loginCode': loginCode,
        'username': username,
      });
}

final class YoungReadOnlyList {
  const YoungReadOnlyList._({
    required this.observations,
    required this.success,
    required this.code,
    required this.result,
    required this.records,
    required this.count,
    required this.total,
    required this.id,
    required this.title,
    required this.date,
    required this.startTime,
    required this.endTime,
  });

  static const Set<String> _fields = <String>{
    'observations',
    'success',
    'code',
    'result',
    'records',
    'count',
    'total',
    'id',
    'title',
    'date',
    'startTime',
    'endTime',
  };

  final int observations;
  final String success;
  final String code;
  final String result;
  final String records;
  final int count;
  final String total;
  final String id;
  final String title;
  final String date;
  final String startTime;
  final String endTime;

  Map<String, Object?> safeSummary() =>
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'observations': observations,
        'success': success,
        'code': code,
        'result': result,
        'records': records,
        'count': count,
        'total': total,
        'id': id,
        'title': title,
        'date': date,
        'startTime': startTime,
        'endTime': endTime,
      });
}

/// Bounded shape metadata for one Young read-only response observation.
///
/// This object contains no response values, URLs, account identifiers, or
/// browser authentication material. Construct it only from the strict decoder.
final class YoungReadOnlyInspection {
  const YoungReadOnlyInspection._({
    required this.session,
    required this.document,
    required this.operation,
    required this.listening,
    required this.accepted,
    required this.rejected,
    required this.lastRejection,
    required this.profile,
    required this.schedule,
    required this.activities,
  });

  static const Set<String> _fields = <String>{
    'session',
    'document',
    'operation',
    'listening',
    'accepted',
    'rejected',
    'lastRejection',
    'profile',
    'schedule',
    'activities',
  };

  static const Set<String> _successValues = <String>{
    'unobserved',
    'true',
    'false',
    'other',
  };

  static const Set<String> _rejectionValues = <String>{
    'none',
    'target',
    'method',
    'frame',
    'loader',
    'redirect',
    'worker',
    'cache',
    'transport',
    'limit',
    'body',
    'stale',
  };

  static const Set<String> _profileTypeFields = <String>{
    'code',
    'result',
    'loginCode',
    'username',
  };

  static const Set<String> _listTypeFields = <String>{
    'code',
    'result',
    'records',
    'total',
    'id',
    'title',
    'date',
    'startTime',
    'endTime',
  };

  final int session;
  final int document;
  final int operation;
  final bool listening;
  final int accepted;
  final int rejected;
  final String lastRejection;
  final YoungReadOnlyProfile profile;
  final YoungReadOnlyList schedule;
  final YoungReadOnlyList activities;

  static YoungReadOnlyInspection decode(
    Object? value, {
    required int session,
    required int document,
    required int operation,
  }) {
    final root = _closedMap(value, _fields);
    final snapshotSession = _positiveInt(root['session']);
    final snapshotDocument = _nonNegativeInt(root['document']);
    final snapshotOperation = _positiveInt(root['operation']);
    final listening = root['listening'];
    if (listening is! bool) _invalid();
    final accepted = _boundedInt(root['accepted'], maximum: 1024);
    final rejected = _boundedInt(root['rejected'], maximum: 4096);
    final rejection = root['lastRejection'];
    if (rejection is! String || !_rejectionValues.contains(rejection)) {
      _invalid();
    }

    final profile = _decodeProfile(root['profile']);
    final schedule = _decodeList(root['schedule']);
    final activities = _decodeList(root['activities']);
    if (accepted !=
        profile.observations +
            schedule.observations +
            activities.observations) {
      _invalid();
    }

    if (snapshotSession != session ||
        snapshotDocument != document ||
        snapshotOperation != operation) {
      throw const AppFailure(FailureCode.staleResult);
    }

    return YoungReadOnlyInspection._(
      session: snapshotSession,
      document: snapshotDocument,
      operation: snapshotOperation,
      listening: listening,
      accepted: accepted,
      rejected: rejected,
      lastRejection: rejection,
      profile: profile,
      schedule: schedule,
      activities: activities,
    );
  }

  /// A closed, immutable projection suitable for display or copying.
  /// Internal binding tokens and all response values are intentionally omitted.
  Map<String, Object?> safeSummary() =>
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'kind': 'young-readonly-observation-v1',
        'listening': listening,
        'accepted': accepted,
        'rejected': rejected,
        'lastRejection': lastRejection,
        'profile': profile.safeSummary(),
        'schedule': schedule.safeSummary(),
        'activities': activities.safeSummary(),
        'identity': 'notValidated',
        'sourceAvailable': false,
      });

  YoungReadOnlyInspection withListening(bool value) =>
      YoungReadOnlyInspection._(
        session: session,
        document: document,
        operation: operation,
        listening: value,
        accepted: accepted,
        rejected: rejected,
        lastRejection: lastRejection,
        profile: profile,
        schedule: schedule,
        activities: activities,
      );

  static YoungReadOnlyProfile _decodeProfile(Object? value) {
    final map = _closedMap(value, YoungReadOnlyProfile._fields);
    final observations = _boundedInt(map['observations'], maximum: 1024);
    final success = _success(map['success']);
    final types = <String, String>{
      for (final field in _profileTypeFields)
        field: YoungReadOnlyValueKind.decode(map[field]).wire,
    };
    _validateObservationDefaults(
      observations: observations,
      success: success,
      types: types,
    );
    return YoungReadOnlyProfile._(
      observations: observations,
      success: success,
      code: types['code']!,
      result: types['result']!,
      loginCode: types['loginCode']!,
      username: types['username']!,
    );
  }

  static YoungReadOnlyList _decodeList(Object? value) {
    final map = _closedMap(value, YoungReadOnlyList._fields);
    final observations = _boundedInt(map['observations'], maximum: 1024);
    final success = _success(map['success']);
    final count = _boundedInt(map['count'], maximum: 5000);
    final types = <String, String>{
      for (final field in _listTypeFields)
        field: YoungReadOnlyValueKind.decode(map[field]).wire,
    };
    _validateObservationDefaults(
      observations: observations,
      success: success,
      types: types,
    );
    if (observations == 0 && count != 0) _invalid();
    return YoungReadOnlyList._(
      observations: observations,
      success: success,
      code: types['code']!,
      result: types['result']!,
      records: types['records']!,
      count: count,
      total: types['total']!,
      id: types['id']!,
      title: types['title']!,
      date: types['date']!,
      startTime: types['startTime']!,
      endTime: types['endTime']!,
    );
  }

  static void _validateObservationDefaults({
    required int observations,
    required String success,
    required Map<String, String> types,
  }) {
    if (observations == 0) {
      if (success != 'unobserved' ||
          types.values.any((String kind) => kind != 'absent')) {
        _invalid();
      }
    } else if (success == 'unobserved') {
      _invalid();
    }
  }

  static String _success(Object? value) {
    if (value is! String || !_successValues.contains(value)) _invalid();
    return value;
  }

  static Map<String, Object?> _closedMap(Object? value, Set<String> fields) {
    if (value is! Map ||
        value.length != fields.length ||
        !value.keys.every(
          (Object? key) => key is String && fields.contains(key),
        ) ||
        !fields.every(value.containsKey)) {
      _invalid();
    }
    return value.cast<String, Object?>();
  }

  static int _positiveInt(Object? value) {
    if (value is! int || value <= 0) _invalid();
    return value;
  }

  static int _nonNegativeInt(Object? value) {
    if (value is! int || value < 0) _invalid();
    return value;
  }

  static int _boundedInt(Object? value, {required int maximum}) {
    if (value is! int || value < 0 || value > maximum) _invalid();
    return value;
  }

  static Never _invalid() =>
      throw const AppFailure(FailureCode.invalidSnapshot);
}

abstract interface class YoungReadOnlyBrowserPort {
  Future<YoungReadOnlyInspection> startYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  });

  Future<YoungReadOnlyInspection> readYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  });

  Future<void> stopYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  });
}
