import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/public_query_contract.dart';
import 'public_source_contract.dart';

final class PublicHtmlPage {
  const PublicHtmlPage({required this.uri, required this.html});
  final Uri uri;
  final String html;
}

abstract interface class PublicHttpSession {
  Future<PublicHtmlPage> get(Uri uri);
  Future<void> close();
}

typedef PublicSessionFactory = PublicHttpSession Function(PublicSource source);

/// Fixed C1 targets; these values are never caller-selected URLs.
final class PublicHttpTargets {
  PublicHttpTargets()
    : _origins = {
        PublicProvider.icourse: Uri.parse('https://icourse.club'),
        PublicProvider.teach: Uri.parse('https://www.teach.ustc.edu.cn'),
        PublicProvider.finance: Uri.parse('https://finance.ustc.edu.cn'),
      },
      _fixture = false;

  /// Explicit test composition, limited to local isolated servers.
  PublicHttpTargets.loopback(Map<PublicProvider, Uri> origins)
    : _origins = Map.unmodifiable(origins),
      _fixture = true {
    if (origins.length != PublicProvider.values.length ||
        origins.values.any(
          (u) =>
              !['127.0.0.1', 'localhost', '[::1]'].contains(u.host) ||
              u.scheme != 'http' ||
              u.userInfo.isNotEmpty ||
              u.path.isNotEmpty && u.path != '/' ||
              u.hasQuery ||
              u.hasFragment,
        )) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
  }

  final Map<PublicProvider, Uri> _origins;
  final bool _fixture;

  Uri courseSearch(String keywords) =>
      _origins[PublicProvider.icourse]!.replace(
        path: '/search/',
        queryParameters: {'q': publicKeywords(keywords), 'noredirect': 'True'},
      );

  Uri campusColumn(CampusColumn column, String? keywords) {
    final term = keywords == null || keywords.trim().isEmpty
        ? null
        : publicKeywords(keywords);
    if (term != null && column.provider == PublicProvider.finance) {
      throw const PublicFailure(PublicFailureCode.unavailable);
    }
    final path = switch (column) {
      CampusColumn.teachNotice => '/category/notice',
      CampusColumn.teachStudentService => '/category/service/svc-student',
      CampusColumn.financeNotice => '/tzgg/list.htm',
      CampusColumn.financeBusiness => '/ywzn/list.psp',
      CampusColumn.financeProcess => '/22118/list.psp',
      CampusColumn.financeOperation => '/22119/list.psp',
      CampusColumn.financeFaq => '/22120/list.psp',
    };
    return _origins[column.provider]!.replace(
      path: path,
      queryParameters: term == null ? null : {'s': term},
    );
  }

  Uri courseRead(Uri item, String? term, CourseReviewSort sort) {
    requireAllowed(item, PublicSource.icourse);
    if (!RegExp(r'^/course/[0-9]+/$').hasMatch(item.path) ||
        term != null && !RegExp(r'^[0-9]{1,12}$').hasMatch(term)) {
      throw const PublicFailure(PublicFailureCode.invalidRequest);
    }
    return item.replace(
      queryParameters: {
        'sort_by': switch (sort) {
          CourseReviewSort.upvote => 'upvote',
          CourseReviewSort.newest => 'pubtime_desc',
          CourseReviewSort.oldest => 'pubtime',
          CourseReviewSort.scoreDescending => 'score_desc',
          CourseReviewSort.scoreAscending => 'score',
        },
        'term': ?term,
      },
    );
  }

  PublicProvider providerFor(Uri uri) {
    final matches = _origins.entries.where(
      (entry) =>
          entry.value.scheme == uri.scheme &&
          entry.value.host == uri.host &&
          entry.value.port == uri.port,
    );
    if (matches.length == 1) return matches.single.key;
    // A loopback fixture may share one origin across all three providers.
    if (_fixture && matches.isNotEmpty) {
      if (uri.path.startsWith('/course/') || uri.path == '/search/') {
        return PublicProvider.icourse;
      }
      return uri.path.startsWith('/category/') ||
              uri.path.startsWith('/service/') ||
              uri.path.startsWith('/notice/')
          ? PublicProvider.teach
          : PublicProvider.finance;
    }
    throw const PublicFailure(PublicFailureCode.unsafeTarget);
  }

  void requireAllowed(Uri uri, PublicSource source) {
    if (uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.toString().length > 2048) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    final provider = providerFor(uri);
    if (provider.source != source) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    if (uri.path.contains('login') || uri.path.contains('39151')) {
      throw const PublicFailure(PublicFailureCode.accessRestricted);
    }
    final pathAllowed = switch (provider) {
      PublicProvider.icourse =>
        uri.path == '/search/' ||
            uri.path == '/course/' ||
            isRegisteredPublicArticlePath(uri.path, provider),
      PublicProvider.teach =>
        RegExp(
              r'^/category/(?:notice|service/svc-student)(?:/page/[1-9][0-9]*)?/?$',
            ).hasMatch(uri.path) ||
            isRegisteredPublicArticlePath(uri.path, provider),
      PublicProvider.finance =>
        RegExp(
              r'^/(?:tzgg|ywzn|22118|22119|22120)/list[0-9]*\.(?:htm|psp)$',
            ).hasMatch(uri.path) ||
            isRegisteredPublicArticlePath(uri.path, provider),
    };
    final allowedKeys = provider == PublicProvider.icourse
        ? const {'q', 'page', 'term', 'sort_by', 'course_type', 'noredirect'}
        : provider == PublicProvider.teach
        ? const {'s'}
        : const <String>{};
    if (!pathAllowed ||
        uri.queryParametersAll.entries.any(
          (e) => !allowedKeys.contains(e.key) || e.value.length != 1,
        )) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    for (final entry in uri.queryParameters.entries) {
      if (entry.key == 'noredirect' && entry.value != 'True') {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
      if (entry.value.length > 160 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value)) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
      if (['page', 'term'].contains(entry.key) &&
          entry.value.isNotEmpty &&
          !RegExp(r'^[0-9]{1,12}$').hasMatch(entry.value)) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
    }
  }

  Uri redirect(Uri current, String location, PublicSource source) {
    var target = current.resolve(location);
    if (target.scheme == 'http' &&
        current.scheme == 'https' &&
        current.host == 'finance.ustc.edu.cn' &&
        target.host == current.host &&
        current.path.endsWith('.htm') &&
        target.path == current.path.replaceFirst(RegExp(r'\.htm$'), '.psp') &&
        target.port == 80 &&
        !target.hasQuery &&
        !target.hasFragment &&
        target.userInfo.isEmpty) {
      target = target.replace(scheme: 'https', port: 443);
    }
    if (['id.ustc.edu.cn', 'passport.ustc.edu.cn'].contains(target.host)) {
      throw const PublicFailure(PublicFailureCode.accessRestricted);
    }
    requireAllowed(target, source);
    if (providerFor(target) != providerFor(current)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return target;
  }
}

/// One anonymous client implementation per job; no cookie jar or browser assets.
final class IoPublicHttpSession implements PublicHttpSession {
  IoPublicHttpSession({required this.targets, required this.source}) {
    _proxied.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
    _direct.findProxy = (_) => 'DIRECT';
  }
  final PublicHttpTargets targets;
  final PublicSource source;
  final HttpClient _proxied = HttpClient();
  final HttpClient _direct = HttpClient();
  final Stopwatch _elapsed = Stopwatch()..start();
  bool _closed = false;
  bool _campusDirectRetried = false;
  bool get campusDirectRetried => _campusDirectRetried;
  int _redirects = 0;
  static const maximumBytes = 2 * 1024 * 1024;

  Duration get _remaining {
    final left = const Duration(seconds: 60) - _elapsed.elapsed;
    if (left <= Duration.zero) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    return left;
  }

  @override
  Future<PublicHtmlPage> get(Uri uri) async {
    try {
      // Anonymous GETs are read-only. Retry one broken connection within the
      // same deadline/redirect budget; refusals and schema errors never retry.
      for (var attempt = 0; ; attempt++) {
        try {
          final remaining = _remaining;
          return await _get(
            uri,
            direct: _campusDirectRetried,
          ).timeout(remaining);
        } on Object catch (error) {
          final transportFailure =
              error is SocketException ||
              error is HandshakeException ||
              error is HttpException;
          if (_closed || !transportFailure || attempt > 0) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    } on PublicFailure {
      rethrow;
    } on TimeoutException {
      await close();
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    } on Object {
      throw PublicFailure(
        _closed ? PublicFailureCode.cancelled : PublicFailureCode.networkFailed,
      );
    }
  }

  Future<PublicHtmlPage> _get(Uri initial, {required bool direct}) async {
    var uri = initial;
    var directRoute = direct;
    var retriedDirect = direct;
    while (true) {
      if (_closed) throw const PublicFailure(PublicFailureCode.cancelled);
      targets.requireAllowed(uri, source);
      final client = directRoute ? _direct : _proxied;
      client.connectionTimeout = _remaining;
      final request = await client.getUrl(uri).timeout(_remaining);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      request.headers.set(HttpHeaders.userAgentHeader, 'USTCAssistant/0.0.1');
      final response = await request.close().timeout(_remaining);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || ++_redirects > 8) {
          throw const PublicFailure(PublicFailureCode.resourceLimit);
        }
        final next = targets.redirect(uri, location, source);
        await _readLimited(response).timeout(_remaining);
        uri = next;
        continue;
      }
      final html = utf8.decode(
        await _readLimited(response).timeout(_remaining),
      );
      final lower = html.toLowerCase();
      final campusRestricted =
          source == PublicSource.campus &&
          lower.length < 16384 &&
          (lower.contains('当前ip并非校内') || lower.contains('当前 ip 并非校内')) &&
          lower.contains('仅允许校内');
      if (campusRestricted) {
        if (retriedDirect) {
          throw const PublicFailure(PublicFailureCode.campusOnly);
        }
        retriedDirect = true;
        _campusDirectRetried = true;
        directRoute = true;
        continue;
      }
      if ([401, 403].contains(response.statusCode)) {
        throw const PublicFailure(PublicFailureCode.accessRestricted);
      }
      if (response.statusCode == 404) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      if (response.statusCode != 200) {
        throw const PublicFailure(PublicFailureCode.networkFailed);
      }
      final type = response.headers.contentType;
      if (type == null ||
          !['text/html', 'application/xhtml+xml'].contains(type.mimeType) ||
          type.charset != null &&
              !['utf-8', 'utf8'].contains(type.charset!.toLowerCase())) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      return PublicHtmlPage(uri: uri, html: html);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _proxied.close(force: true);
    _direct.close(force: true);
    _elapsed.stop();
  }

  Future<Uint8List> _readLimited(HttpClientResponse response) async {
    if (response.contentLength > maximumBytes) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (_closed) throw const PublicFailure(PublicFailureCode.cancelled);
      if (bytes.length + chunk.length > maximumBytes) {
        throw const PublicFailure(PublicFailureCode.resourceLimit);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
