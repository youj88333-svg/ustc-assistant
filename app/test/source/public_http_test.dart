import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';

typedef _RequestHandler = FutureOr<void> Function(HttpRequest request);

final class _Fixture {
  _Fixture({
    required this.server,
    required this.subscription,
    required this.session,
    required this.targets,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final IoPublicHttpSession session;
  final PublicHttpTargets targets;

  Uri get courseSearch => targets.courseSearch('synthetic-query');
  Uri get campusNotice => targets.campusColumn(CampusColumn.teachNotice, null);

  Future<void> close() async {
    await session.close();
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<_Fixture> _startFixture(
  _RequestHandler handler, {
  PublicSource source = PublicSource.icourse,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) {
    unawaited(Future<void>.sync(() => handler(request)));
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
    targets: targets,
    session: IoPublicHttpSession(targets: targets, source: source),
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

void _expectTargetFailure(
  PublicHttpTargets targets,
  Uri uri,
  PublicFailureCode code,
) {
  expect(
    () => targets.requireAllowed(uri, PublicSource.icourse),
    throwsA(
      isA<PublicFailure>().having((failure) => failure.code, 'code', code),
    ),
  );
}

Future<void> _expectRequestFailure(
  Future<PublicHtmlPage> request,
  PublicFailureCode code,
) => expectLater(
  request,
  throwsA(isA<PublicFailure>().having((failure) => failure.code, 'code', code)),
);

void main() {
  test('registered finance aliases are upgraded before any HTTP request', () {
    final targets = PublicHttpTargets();
    for (final path in [
      '/ywzn/list2.htm',
      '/22118/list2.htm',
      '/2021/0128/c22118a470108/page.htm',
    ]) {
      final expectedPath = path.replaceFirst(RegExp(r'\.htm$'), '.psp');
      final result = targets.redirect(
        Uri.parse('https://finance.ustc.edu.cn$path'),
        'http://finance.ustc.edu.cn$expectedPath',
        PublicSource.campus,
      );
      expect(result.scheme, 'https');
      expect(result.port, 443);
      expect(result.path, expectedPath);
    }
    expect(
      () => targets.redirect(
        Uri.parse('https://finance.ustc.edu.cn/ywzn/list2.htm'),
        'http://finance.ustc.edu.cn/22118/list2.psp',
        PublicSource.campus,
      ),
      throwsA(isA<PublicFailure>()),
    );
    expect(
      () => targets.redirect(
        Uri.parse('https://finance.ustc.edu.cn/ywzn/list2.htm'),
        'http://finance.ustc.edu.cn/ywzn/list2.htm',
        PublicSource.campus,
      ),
      throwsA(isA<PublicFailure>()),
    );
  });
  group('IoPublicHttpSession', () {
    test(
      'allows only fixed public targets and controlled query parameters',
      () {
        final targets = PublicHttpTargets();
        targets.requireAllowed(
          targets.courseSearch('synthetic-query'),
          PublicSource.icourse,
        );

        _expectTargetFailure(
          targets,
          Uri.parse('https://outside.example/search/?q=synthetic'),
          PublicFailureCode.unsafeTarget,
        );
        _expectTargetFailure(
          targets,
          Uri.parse('https://synthetic-user@icourse.club/search/?q=synthetic'),
          PublicFailureCode.unsafeTarget,
        );
        _expectTargetFailure(
          targets,
          Uri.parse('https://icourse.club/search/?q=synthetic&token=synthetic'),
          PublicFailureCode.unsafeTarget,
        );
        _expectTargetFailure(
          targets,
          Uri.parse('https://icourse.club/search/?q=first&q=second'),
          PublicFailureCode.unsafeTarget,
        );
        _expectTargetFailure(
          targets,
          Uri.parse('https://icourse.club/login/'),
          PublicFailureCode.accessRestricted,
        );
      },
    );

    test(
      'follows a legal redirect and rejects a cross-provider redirect',
      () async {
        final fixture = await _startFixture((request) async {
          if (request.uri.path == '/search/') {
            await _reply(
              request,
              status: HttpStatus.found,
              headers: {HttpHeaders.locationHeader: '/course/123/'},
            );
            return;
          }
          await _reply(
            request,
            body: utf8.encode('<html>synthetic page</html>'),
          );
        });
        try {
          final page = await fixture.session.get(fixture.courseSearch);
          expect(page.uri.path, '/course/123/');
          expect(page.html, contains('synthetic page'));
        } finally {
          await fixture.close();
        }

        final crossProvider = await _startFixture((request) async {
          await _reply(
            request,
            status: HttpStatus.found,
            headers: {HttpHeaders.locationHeader: '/category/notice'},
          );
        });
        try {
          await _expectRequestFailure(
            crossProvider.session.get(crossProvider.courseSearch),
            PublicFailureCode.unsafeTarget,
          );
        } finally {
          await crossProvider.close();
        }
      },
    );

    test('caps a redirect chain at eight hops', () async {
      var requests = 0;
      final fixture = await _startFixture((request) async {
        requests++;
        await _reply(
          request,
          status: HttpStatus.found,
          headers: {HttpHeaders.locationHeader: '/search/?q=synthetic-query'},
        );
      });
      try {
        await _expectRequestFailure(
          fixture.session.get(fixture.courseSearch),
          PublicFailureCode.resourceLimit,
        );
        expect(requests, 9);
      } finally {
        await fixture.close();
      }
    });

    test('limits chunked response bytes after streaming', () async {
      final fixture = await _startFixture((request) async {
        final response = request.response
          ..headers.set(
            HttpHeaders.contentTypeHeader,
            'text/html; charset=utf-8',
          )
          ..headers.chunkedTransferEncoding = true;
        final chunk = List<int>.filled(64 * 1024, 120);
        for (var index = 0; index < 33; index++) {
          response.add(chunk);
        }
        await response.close();
      });
      try {
        await _expectRequestFailure(
          fixture.session.get(fixture.courseSearch),
          PublicFailureCode.resourceLimit,
        );
      } finally {
        await fixture.close();
      }
    });

    test('limits gzip data after decompression', () async {
      final decompressed = utf8.encode(
        'x' * (IoPublicHttpSession.maximumBytes + 1),
      );
      final compressed = gzip.encode(decompressed);
      expect(compressed.length, lessThan(IoPublicHttpSession.maximumBytes));
      final fixture = await _startFixture((request) async {
        await _reply(
          request,
          headers: {HttpHeaders.contentEncodingHeader: 'gzip'},
          body: compressed,
        );
      });
      try {
        await _expectRequestFailure(
          fixture.session.get(fixture.courseSearch),
          PublicFailureCode.resourceLimit,
        );
      } finally {
        await fixture.close();
      }
    });

    test(
      'rejects an oversized body on a valid redirect before following it',
      () async {
        var requests = 0;
        final fixture = await _startFixture((request) async {
          requests++;
          final response = request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.contentTypeHeader,
              'text/html; charset=utf-8',
            )
            ..headers.set(HttpHeaders.locationHeader, '/course/123/')
            ..headers.chunkedTransferEncoding = true;
          final chunk = List<int>.filled(64 * 1024, 120);
          for (var index = 0; index < 33; index++) {
            response.add(chunk);
          }
          await response.close();
        });
        try {
          await _expectRequestFailure(
            fixture.session.get(fixture.courseSearch),
            PublicFailureCode.resourceLimit,
          );
          expect(requests, 1);
        } finally {
          await fixture.close();
        }
      },
    );

    test(
      'rejects non-HTML, malformed UTF-8, and forbidden responses',
      () async {
        final contentType = await _startFixture((request) async {
          await _reply(request, contentType: 'application/json');
        });
        try {
          await _expectRequestFailure(
            contentType.session.get(contentType.courseSearch),
            PublicFailureCode.sourceSchema,
          );
        } finally {
          await contentType.close();
        }

        final malformedUtf8 = await _startFixture((request) async {
          await _reply(request, body: const <int>[0xff, 0xfe]);
        });
        try {
          await expectLater(
            malformedUtf8.session.get(malformedUtf8.courseSearch),
            throwsA(isA<PublicFailure>()),
          );
        } finally {
          await malformedUtf8.close();
        }

        final forbidden = await _startFixture((request) async {
          await _reply(request, status: HttpStatus.forbidden);
        });
        try {
          await _expectRequestFailure(
            forbidden.session.get(forbidden.courseSearch),
            PublicFailureCode.accessRestricted,
          );
        } finally {
          await forbidden.close();
        }
      },
    );

    test('does not retain Set-Cookie or send authentication headers', () async {
      final observed = <({String? authorization, String? cookie})>[];
      final fixture = await _startFixture((request) async {
        observed.add((
          authorization: request.headers.value(HttpHeaders.authorizationHeader),
          cookie: request.headers.value(HttpHeaders.cookieHeader),
        ));
        await _reply(
          request,
          headers: {
            HttpHeaders.setCookieHeader: 'fixture-session=synthetic; Path=/',
          },
          body: utf8.encode('<html>synthetic page</html>'),
        );
      });
      try {
        await fixture.session.get(fixture.courseSearch);
        await fixture.session.get(fixture.courseSearch);
        expect(observed, hasLength(2));
        expect(
          observed.every((headers) => headers.authorization == null),
          isTrue,
        );
        expect(observed.every((headers) => headers.cookie == null), isTrue);
      } finally {
        await fixture.close();
      }
    });

    test(
      'retries direct only for the explicit campus restriction response',
      () async {
        var campusRequests = 0;
        final campus = await _startFixture((request) async {
          campusRequests++;
          if (campusRequests == 1) {
            await _reply(
              request,
              status: HttpStatus.forbidden,
              body: utf8.encode('当前 IP 并非校内，仅允许校内访问。'),
            );
          } else {
            await _reply(request, body: utf8.encode('<html>synthetic</html>'));
          }
        }, source: PublicSource.campus);
        try {
          await campus.session.get(campus.campusNotice);
          expect(campusRequests, 2);
        } finally {
          await campus.close();
        }

        var ordinaryForbiddenRequests = 0;
        final ordinaryForbidden = await _startFixture((request) async {
          ordinaryForbiddenRequests++;
          await _reply(
            request,
            status: HttpStatus.forbidden,
            body: utf8.encode('Forbidden'),
          );
        }, source: PublicSource.campus);
        try {
          await _expectRequestFailure(
            ordinaryForbidden.session.get(ordinaryForbidden.campusNotice),
            PublicFailureCode.accessRestricted,
          );
          expect(ordinaryForbiddenRequests, 1);
        } finally {
          await ordinaryForbidden.close();
        }

        var courseRequests = 0;
        final course = await _startFixture((request) async {
          courseRequests++;
          await _reply(request, body: utf8.encode('当前 IP 并非校内，仅允许校内访问。'));
        });
        try {
          await course.session.get(course.courseSearch);
          expect(courseRequests, 1);
        } finally {
          await course.close();
        }
      },
    );

    test(
      'one interrupted anonymous GET recovers, repeated interruption stops',
      () async {
        var requests = 0;
        final recovering = await _startFixture((request) async {
          requests++;
          expect(request.method, 'GET');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            isNull,
          );
          expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
          if (requests == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
            return;
          }
          await _reply(request, body: utf8.encode('<html>recovered</html>'));
        });
        try {
          final response = await recovering.session.get(
            recovering.courseSearch,
          );
          expect(response.html, '<html>recovered</html>');
          expect(requests, 2);
        } finally {
          await recovering.close();
        }
        var failedRequests = 0;
        final interrupted = await _startFixture((request) async {
          failedRequests++;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
        });
        try {
          await _expectRequestFailure(
            interrupted.session.get(interrupted.courseSearch),
            PublicFailureCode.networkFailed,
          );
          expect(failedRequests, 2);
        } finally {
          await interrupted.close();
        }
      },
    );

    test(
      'an HTTP error response is not retried as a broken connection',
      () async {
        var requests = 0;
        final fixture = await _startFixture((request) async {
          requests++;
          await _reply(request, status: HttpStatus.serviceUnavailable);
        });
        try {
          await _expectRequestFailure(
            fixture.session.get(fixture.courseSearch),
            PublicFailureCode.networkFailed,
          );
          expect(requests, 1);
        } finally {
          await fixture.close();
        }
      },
    );

    test(
      'close cancels an active response read and releases the request',
      () async {
        final receivedRequest = Completer<void>();
        final bodyCanFinish = Completer<void>();
        final fixture = await _startFixture((request) async {
          request.response
            ..headers.set(
              HttpHeaders.contentTypeHeader,
              'text/html; charset=utf-8',
            )
            ..write('<html>');
          await request.response.flush();
          receivedRequest.complete();
          await bodyCanFinish.future;
          try {
            await request.response.close();
          } on HttpException {
            // The client was deliberately force-closed during the active read.
          }
        });
        try {
          final pending = fixture.session.get(fixture.courseSearch);
          await receivedRequest.future.timeout(const Duration(seconds: 2));
          final cancelled = _expectRequestFailure(
            pending.timeout(const Duration(seconds: 2)),
            PublicFailureCode.cancelled,
          );
          await fixture.session.close();
          await cancelled;
          bodyCanFinish.complete();
        } finally {
          if (!bodyCanFinish.isCompleted) bodyCanFinish.complete();
          await fixture.close();
        }
      },
    );
  });
}
