import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/import/domain/source_bundle_error.dart';

const positiveRoot = 'test/fixtures/source_bundle/positive';
const negativeRoot = 'test/fixtures/source_bundle/negative';

Uint8List fixtureBytes(String root, String name) =>
    File('$root/$name').readAsBytesSync();

SourceBundleDecoder decoder() {
  final schema = jsonDecode(
    File(
      'assets/schemas/source-bundle-1.0.draft7.schema.json',
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  return SourceBundleDecoder(schema);
}

void main() {
  for (final name in [
    'jw-with-exam.json',
    'jw-empty-exam.json',
    'young-with-schedule.json',
    'young-empty-window.json',
  ]) {
    test('$name decodes into immutable typed values', () {
      final bundle = decoder().decode(fixtureBytes(positiveRoot, name));
      expect(bundle.schemaVersion, '1.0');
      expect(bundle.subject.accountId, 'acct_fixture');
      expect(bundle.data.calendarEvents.length, bundle.manifest.calendarEventCount);
    });
  }

  test('shared negative fixtures retain stable safe categories', () {
    final expected = {
      'count-mismatch.json': 'count_mismatch',
      'incomplete-snapshot.json': 'incomplete_snapshot',
      'unknown-field.json': 'invalid_envelope',
    };
    for (final entry in expected.entries) {
      expect(
        () => decoder().decode(fixtureBytes(negativeRoot, entry.key)),
        throwsA(
          isA<SourceBundleError>()
              .having((error) => error.code, 'code', entry.value)
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                isNot(contains('acct_fixture')),
              ),
        ),
      );
    }
  });

  test('duplicate identity does not echo the external identity', () {
    final json =
        jsonDecode(
              utf8.decode(
                fixtureBytes(positiveRoot, 'jw-with-exam.json'),
              ),
            )
            as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>;
    final events = data['calendarEvents'] as List<dynamic>;
    events.add(jsonDecode(jsonEncode(events.first)));
    final identity =
        (events.first as Map<String, dynamic>)['externalId'] as String;

    expect(
      () => decoder().decode(Uint8List.fromList(utf8.encode(jsonEncode(json)))),
      throwsA(
        isA<SourceBundleError>()
            .having((error) => error.code, 'code', 'duplicate_identity')
            .having(
              (error) => error.safeMessage,
              'safeMessage',
              isNot(contains(identity)),
            ),
      ),
    );
  });

  test('subject validation is explicit and redacted', () {
    final bundle = decoder().decode(
      fixtureBytes(positiveRoot, 'young-empty-window.json'),
    );
    expect(
      () => bundle.requireSubject('private-expected-account'),
      throwsA(
        isA<SourceBundleError>()
            .having((error) => error.code, 'code', 'subject_mismatch')
            .having(
              (error) => error.safeMessage,
              'safeMessage',
              isNot(contains('private-expected-account')),
            ),
      ),
    );
  });

  test('payload is rejected before JSON parsing above 16 MiB', () {
    final oversized = Uint8List(SourceBundleDecoder.maxBundleBytes + 1);
    expect(
      () => decoder().decode(oversized),
      throwsA(
        isA<SourceBundleError>().having(
          (error) => error.code,
          'code',
          'limit_exceeded',
        ),
      ),
    );
  });

  test('sensitive keys and invalid Beijing ranges are rejected', () {
    final original =
        jsonDecode(
              utf8.decode(
                fixtureBytes(positiveRoot, 'young-with-schedule.json'),
              ),
            )
            as Map<String, dynamic>;
    final withToken = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    (withToken['producer'] as Map<String, dynamic>)['token'] =
        'private-token-value';
    expect(
      () => decoder().decode(
        Uint8List.fromList(utf8.encode(jsonEncode(withToken))),
      ),
      throwsA(
        isA<SourceBundleError>().having(
          (error) => error.code,
          'code',
          'invalid_envelope',
        ),
      ),
    );

    final invalidTime = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    final event =
        ((invalidTime['data'] as Map<String, dynamic>)['calendarEvents']
                as List<dynamic>)
            .first
            as Map<String, dynamic>;
    (event['time'] as Map<String, dynamic>)['endAt'] =
        '2026-07-22T18:00:00+08:00';
    expect(
      () => decoder().decode(
        Uint8List.fromList(utf8.encode(jsonEncode(invalidTime))),
      ),
      throwsA(
        isA<SourceBundleError>().having(
          (error) => error.code,
          'code',
          'invalid_time',
        ),
      ),
    );
  });
}
