import '../core/contracts.dart';

enum YoungSurface { unknown, portal, accessGate, authentication, application }

final class YoungPageInspection {
  const YoungPageInspection({
    required this.session,
    required this.document,
    required this.ready,
    required this.surface,
    required this.tables,
    required this.calendarRoots,
    required this.paginationControls,
    required this.passwordInputs,
  });

  static const Set<String> _fields = <String>{
    'session',
    'document',
    'ready',
    'surface',
    'tables',
    'calendarRoots',
    'paginationControls',
    'passwordInputs',
  };

  final int session;
  final int document;
  final bool ready;
  final YoungSurface surface;
  final int tables;
  final int calendarRoots;
  final int paginationControls;
  final int passwordInputs;

  factory YoungPageInspection.decode(
    Object? value, {
    required int session,
    required int document,
  }) {
    if (value is! Map ||
        value.length != _fields.length ||
        !value.keys.every(
          (Object? key) => key is String && _fields.contains(key),
        ) ||
        !_fields.every((String field) => value.containsKey(field))) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }

    final snapshotSession = value['session'];
    final snapshotDocument = value['document'];
    final rawReady = value['ready'];
    final rawSurface = value['surface'];
    final rawTables = value['tables'];
    final rawCalendarRoots = value['calendarRoots'];
    final rawPaginationControls = value['paginationControls'];
    final rawPasswordInputs = value['passwordInputs'];

    if (snapshotSession is! int ||
        snapshotSession <= 0 ||
        snapshotDocument is! int ||
        snapshotDocument < 0 ||
        rawReady is! bool ||
        rawSurface is! String) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }

    final tables = _decodeCount(rawTables);
    final calendarRoots = _decodeCount(rawCalendarRoots);
    final paginationControls = _decodeCount(rawPaginationControls);
    final passwordInputs = _decodeCount(rawPasswordInputs);

    final surface = switch (rawSurface) {
      'unknown' => YoungSurface.unknown,
      'portal' => YoungSurface.portal,
      'accessGate' => YoungSurface.accessGate,
      'authentication' => YoungSurface.authentication,
      'application' => YoungSurface.application,
      _ => throw const AppFailure(FailureCode.invalidSnapshot),
    };

    if (snapshotSession != session || snapshotDocument != document) {
      throw const AppFailure(FailureCode.staleResult);
    }

    return YoungPageInspection(
      session: snapshotSession,
      document: snapshotDocument,
      ready: rawReady,
      surface: surface,
      tables: tables,
      calendarRoots: calendarRoots,
      paginationControls: paginationControls,
      passwordInputs: passwordInputs,
    );
  }

  Map<String, Object?> safeSummary() => <String, Object?>{
    'kind': 'young-observation-v1',
    'ready': ready,
    'surface': surface.name,
    'identity': 'notValidated',
    'sourceAvailable': false,
    'structure': <String, Object?>{
      'tables': tables,
      'calendarRoots': calendarRoots,
      'paginationControls': paginationControls,
      'passwordInputs': passwordInputs,
    },
  };

  static int _decodeCount(Object? value) {
    if (value is int && value >= 0 && value <= 4096) {
      return value;
    }
    throw const AppFailure(FailureCode.invalidSnapshot);
  }
}

abstract interface class YoungInspectionBrowserPort {
  Future<YoungPageInspection> inspectYoungPage({
    required int session,
    required int document,
  });
}
