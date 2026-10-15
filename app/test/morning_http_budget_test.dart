import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/jobs/morning_brief_coordinator.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';

typedef _Handler = Future<void> Function(HttpRequest request);

final class _Fixture {
  _Fixture({
    required this.server,
    required this.subscription,
    required this.session,
    required this.targets,
    required this.paths,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final IoPublicHttpSession session;
  final PublicHttpTargets targets;
  final List<String> paths;

  Uri get campusNotice => targets.campusColumn(CampusColumn.teachNotice, null);

  Future<void> close() async {
    await session.close();
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<_Fixture> _startFixture({
  required _Handler handler,
  required PublicSource source,
  void Function()? beforeRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  final subscription = server.listen((request) {
    paths.add(request.uri.path);
    unawaited(handler(request));
  });
  final origin = Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
  );
  final targets = PublicHttpTargets.loopback({
    for (final provider in PublicProvider.values) provider: origin,
  });
  return _Fixture(
    server: server,
    subscription: subscription,
    session: IoPublicHttpSession(
      targets: targets,
      source: source,
      beforeRequest: beforeRequest,
    ),
    targets: targets,
    paths: paths,
  );
}

Future<void> _reply(
  HttpRequest request, {
  int status = HttpStatus.ok,
  String? contentType = 'text/html; charset=utf-8',
  List<int> body = const <int>[],
  Map<String, String> headers = const <String, String>{},
}) async {
  final response = request.response..statusCode = status;
  if (contentType != null) {
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  }
  for (final entry in headers.entries) {
    response.headers.set(entry.key, entry.value);
  }
  response.add(body);
  await response.close();
}

Matcher _resourceLimit() => isA<PublicFailure>().having(
  (failure) => failure.code,
  'code',
  PublicFailureCode.resourceLimit,
);

void main() {
  test('the shared network window rejects exactly at 60 seconds', () {
    var elapsed = Duration.zero;
    final budget = MorningHttpBudget(elapsedForTesting: () => elapsed)..reset();
    elapsed = const Duration(milliseconds: 59999);
    budget.consume();
    elapsed = const Duration(seconds: 60);
    expect(budget.consume, throwsA(isA<PublicFailure>()));
    expect(budget.requests, 1);
  });
  test('requires reset and refuses attempt 21 without spending it', () {
    final budget = MorningHttpBudget();
    expect(budget.consume, throwsA(_resourceLimit()));
    expect(budget.requests, 0);

    budget.reset();
    for (var index = 0; index < 20; index++) {
      budget.consume();
    }
    expect(budget.requests, 20);
    expect(budget.consume, throwsA(_resourceLimit()));
    expect(budget.requests, 20);

    budget.reset();
    expect(budget.requests, 0);
    budget.consume();
    expect(budget.requests, 1);
  });

  test('charges a redirect as a second actual request', () async {
    final budget = MorningHttpBudget()..reset();
    final fixture = await _startFixture(
      source: PublicSource.campus,
      beforeRequest: budget.consume,
      handler: (request) async {
        if (request.uri.path == '/category/notice') {
          await _reply(
            request,
            status: HttpStatus.found,
            headers: {HttpHeaders.locationHeader: '/category/notice/page/2'},
          );
        } else {
          await _reply(request, body: utf8.encode('<html>synthetic</html>'));
        }
      },
    );
    try {
      final result = await fixture.session.get(fixture.campusNotice);
      expect(result.uri.path, '/category/notice/page/2');
      expect(fixture.paths, ['/category/notice', '/category/notice/page/2']);
      expect(budget.requests, 2);
    } finally {
      await fixture.close();
    }
  });

  test('charges the registered campus direct retry', () async {
    final budget = MorningHttpBudget()..reset();
    var received = 0;
    final fixture = await _startFixture(
      source: PublicSource.campus,
      beforeRequest: budget.consume,
      handler: (request) async {
        received++;
        if (received == 1) {
          await _reply(
            request,
            status: HttpStatus.forbidden,
            body: utf8.encode('当前 IP 并非校内，仅允许校内访问。'),
          );
        } else {
          await _reply(request, body: utf8.encode('<html>synthetic</html>'));
        }
      },
    );
    try {
      await fixture.session.get(fixture.campusNotice);
      expect(fixture.session.campusDirectRetried, isTrue);
      expect(received, 2);
      expect(fixture.paths, ['/category/notice', '/category/notice']);
      expect(budget.requests, 2);
    } finally {
      await fixture.close();
    }
  });

  test('charges a broken-connection retry as another request', () async {
    final budget = MorningHttpBudget()..reset();
    var received = 0;
    final fixture = await _startFixture(
      source: PublicSource.campus,
      beforeRequest: budget.consume,
      handler: (request) async {
        received++;
        if (received == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        await _reply(request, body: utf8.encode('<html>recovered</html>'));
      },
    );
    try {
      final result = await fixture.session.get(fixture.campusNotice);
      expect(result.html, '<html>recovered</html>');
      expect(received, 2);
      expect(budget.requests, 2);
    } finally {
      await fixture.close();
    }
  });

  test(
    'zero available budget refuses before any loopback request is sent',
    () async {
      var received = 0;
      final budget = MorningHttpBudget();
      final fixture = await _startFixture(
        source: PublicSource.campus,
        beforeRequest: budget.consume,
        handler: (request) async {
          received++;
          await _reply(request, body: utf8.encode('<html>unexpected</html>'));
        },
      );
      try {
        await expectLater(
          fixture.session.get(fixture.campusNotice),
          throwsA(_resourceLimit()),
        );
        expect(received, 0);
        expect(fixture.paths, isEmpty);
        expect(budget.requests, 0);
      } finally {
        await fixture.close();
      }
    },
  );
}
