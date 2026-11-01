import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/ios_i2_http.dart';

void main() {
  test(
    'I2 HTTP fence creates a client without recursion and blocks outside',
    () async {
      final local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deny = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var localRequests = 0;
      var deniedRequests = 0;
      local.listen((request) async {
        localRequests++;
        request.response.write('synthetic');
        await request.response.close();
      });
      deny.listen((request) async {
        deniedRequests++;
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      });
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          try {
            for (final entry in {
              'http://127.0.0.1:${local.port}/i2': HttpStatus.ok,
              'http://example.invalid/i2': HttpStatus.badGateway,
            }.entries) {
              final request = await client.getUrl(Uri.parse(entry.key));
              final response = await request.close();
              expect(response.statusCode, entry.value);
              await response.drain<void>();
            }
          } finally {
            client.close(force: true);
          }
        }, IOSI2LoopbackHttpOverrides(denyProxyPort: deny.port));
        expect(localRequests, 1);
        expect(deniedRequests, 1);
      } finally {
        await local.close(force: true);
        await deny.close(force: true);
      }
    },
  );
}
