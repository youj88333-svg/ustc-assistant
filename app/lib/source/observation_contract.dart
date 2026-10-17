import '../core/contracts.dart';

enum BrowserEventKind {
  navigating,
  ready,
  blocked,
  diagnostic,
  userClosed,
  failed,
}

/// Registered JW business launchers. The school resolves its own detail route.
enum JwObservationPage { courseTable, examArrange }

enum BrowserDiagnosticCode {
  topNavigationBlocked,
  frameNavigationBlocked,
  documentRequestBlocked,
  insecureDocumentUpgraded,
  popupBlocked,
  downloadBlocked,
  permissionBlocked,
  externalProtocolBlocked,
}

enum BrowserDiagnosticSite {
  jw,
  young,
  passport,
  identity,
  ucas,
  gateway,
  fixture,
  unknown,
}

enum BrowserDiagnosticScheme { http, https, other }

/// Closed metadata vocabulary; no URI, path, query, headers or page content.
final class BrowserDiagnostic {
  const BrowserDiagnostic({
    required this.code,
    required this.site,
    required this.scheme,
  });
  final BrowserDiagnosticCode code;
  final BrowserDiagnosticSite site;
  final BrowserDiagnosticScheme scheme;
}

final class BrowserEvent {
  const BrowserEvent({
    required this.session,
    required this.document,
    required this.kind,
    this.origin,
    this.diagnostic,
  });
  final int session;
  final int document;
  final BrowserEventKind kind;
  final String? origin;
  final BrowserDiagnostic? diagnostic;
}

final class BrowserInspection {
  const BrowserInspection({
    required this.session,
    required this.document,
    required this.ready,
    this.origin,
    this.windowVisible,
    this.windowForeground,
  });
  final int session;
  final int document;
  final bool ready;
  final String? origin;
  final bool? windowVisible, windowForeground;
}

/// C1-owned policy. Callers can choose a registered target, never a UI URL.
enum ObservationSource { jw, young }

final class ObservationTarget {
  ObservationTarget._(
    this.initialUri,
    List<String> origins,
    this.isFixture,
    this.source,
  ) : allowedOrigins = List.unmodifiable(origins);
  factory ObservationTarget.jw() => ObservationTarget._(
    Uri.parse('https://jw.ustc.edu.cn/'),
    [
      'https://jw.ustc.edu.cn',
      'https://passport.ustc.edu.cn',
      'https://id.ustc.edu.cn',
      'https://analytics.ustc.edu.cn',
    ],
    false,
    ObservationSource.jw,
  );
  factory ObservationTarget.young() => ObservationTarget._(
    Uri.parse('https://young.ustc.edu.cn/login/'),
    [
      'https://young.ustc.edu.cn',
      'https://passport.ustc.edu.cn',
      'https://ucas.ustc.edu.cn',
      'https://id.ustc.edu.cn',
      'https://analytics.ustc.edu.cn',
    ],
    false,
    ObservationSource.young,
  );
  factory ObservationTarget.fixture(
    Uri uri, {
    List<Uri> additionalOrigins = const [],
  }) =>
      ObservationTarget._fixture(uri, additionalOrigins, ObservationSource.jw);
  factory ObservationTarget.youngFixture(
    Uri uri, {
    List<Uri> additionalOrigins = const [],
  }) => ObservationTarget._fixture(
    uri,
    additionalOrigins,
    ObservationSource.young,
  );
  static ObservationTarget _fixture(
    Uri uri,
    List<Uri> additionalOrigins,
    ObservationSource source,
  ) {
    bool validLoopback(Uri candidate) =>
        (candidate.scheme == 'http' || candidate.scheme == 'https') &&
        candidate.host == '127.0.0.1' &&
        candidate.hasPort &&
        candidate.port > 0 &&
        candidate.port <= 65535 &&
        candidate.userInfo.isEmpty &&
        !candidate.hasQuery &&
        !candidate.hasFragment;
    if (!validLoopback(uri) ||
        additionalOrigins.length > 3 ||
        additionalOrigins.any(
          (origin) =>
              !validLoopback(origin) ||
              (origin.path.isNotEmpty && origin.path != '/'),
        )) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final origins = [uri.origin, ...additionalOrigins.map((uri) => uri.origin)];
    if (origins.toSet().length != origins.length) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return ObservationTarget._(uri, origins, true, source);
  }

  final Uri initialUri;
  final List<String> allowedOrigins;
  final bool isFixture;
  final ObservationSource source;
}

abstract interface class ObservationBrowserPort {
  Stream<BrowserEvent> get events;
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  });
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  });
  Future<void> navigateInitial(int session);
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  });
  Future<void> close(int session);
  Future<bool> drained(int session);
}

/// Optional, value-free platform check before admitting a new source job.
/// It creates no session/profile and does not prove that old assets were cleared.
abstract interface class ObservationAvailabilityBrowserPort {
  bool get requiresAvailabilityCheck;
  Future<void> ensureAvailable();
}

/// Presentation only; the same source, profile and native request boundary
/// remain in force. Ordinary callers continue to open a visible window.
abstract interface class BackgroundObservationBrowserPort {
  Future<void> openBackground({
    required int session,
    required String profilePath,
    required ObservationTarget target,
  });
}
