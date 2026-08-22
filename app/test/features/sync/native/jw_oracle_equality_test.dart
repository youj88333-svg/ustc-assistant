// Oracle-equality test: the Dart JW SourceBundle builder must produce a bundle
// whose canonical digest matches the Python oracle fixture, field for field.
//
// See `docs/plan-webview-minimal-m2.md` §5 (Task F5). The oracle
// `oracle-bundle.json` was produced by the Python producer with the fixed
// `bundleId`/`collectedAt`/`producer` injected below; the Dart builder is
// given the same fixed values so the canonical digest is comparable.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/native/_jw_identity.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_source_bundle_builder.dart';

const _fixturesRoot = 'test/fixtures/jw';

// Fixed identity fields matching the Python oracle fixture exactly.
const _bundleId = '00000000-0000-0000-0000-000000000000';
// 2026-08-22T12:00:00+08:00 == 2026-08-22T04:00:00Z. The builder renders the
// instant in Asia/Shanghai, so we pass the equivalent UTC instant.
final _collectedAt = DateTime.utc(2026, 8, 22, 4, 0, 0);
const _accountId = 'acct_fixture';
const _producer = <String, String>{
  'name': 'ustc_assistant_python',
  'version': '0.1.0',
  'platform': 'windows',
};

final _semester = JwSemester(
  semesterId: 461,
  semesterKey: '2026fall',
  displayName: '2026 秋季学期',
);

void main() {
  group('JW oracle equality', () {
    late Map<String, dynamic> courseDatum;
    late String examHtml;
    late Map<String, dynamic> dartBundle;
    late Map<String, dynamic> oracleBundle;

    setUpAll(() {
      courseDatum = jsonDecode(
        File('$_fixturesRoot/course-datum.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      examHtml = File('$_fixturesRoot/exam-page.html').readAsStringSync();
      oracleBundle = jsonDecode(
        File('$_fixturesRoot/oracle-bundle.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      dartBundle = buildJwSourceBundle(
        courseDatum: courseDatum,
        examHtml: examHtml,
        accountId: _accountId,
        semester: _semester,
        bundleId: _bundleId,
        collectedAt: _collectedAt,
        producer: _producer,
      );
    });

    test('canonical digest matches the Python oracle', () {
      final dartDigest = _canonicalDigest(dartBundle);
      final oracleDigest = _canonicalDigest(oracleBundle);
      // Helpful diagnostic when the gate fails: print both canonical forms so
      // the differing field can be located by diffing.
      if (dartDigest != oracleDigest) {
        final dartCanonical = canonicalJsonEncode(dartBundle);
        final oracleCanonical = canonicalJsonEncode(oracleBundle);
        final dartPath = '${Directory.systemTemp.path}/dart-bundle.json';
        final oraclePath = '${Directory.systemTemp.path}/oracle-bundle.json';
        File(dartPath).writeAsStringSync(_pretty(dartCanonical));
        File(oraclePath).writeAsStringSync(_pretty(oracleCanonical));
        fail('Digest mismatch.\n'
            '  dart:   $dartDigest\n'
            '  oracle: $oracleDigest\n'
            'Canonical JSON written to:\n'
            '  $dartPath\n'
            '  $oraclePath\n'
            'Diff them to find the differing field.');
      }
      expect(dartDigest, equals(oracleDigest));
    });

    test('collection lengths match the oracle', () {
      final dartData = dartBundle['data'] as Map<String, dynamic>;
      final oracleData = oracleBundle['data'] as Map<String, dynamic>;
      expect(
        (dartData['sourceRecords'] as List).length,
        equals((oracleData['sourceRecords'] as List).length),
      );
      expect(
        (dartData['calendarEvents'] as List).length,
        equals((oracleData['calendarEvents'] as List).length),
      );
      expect(
        (dartData['courseSeries'] as List).length,
        equals((oracleData['courseSeries'] as List).length),
      );
      expect(
        (dartData['scheduleRelations'] as List).length,
        equals((oracleData['scheduleRelations'] as List).length),
      );
    });

    test('manifest counts match the oracle', () {
      expect(dartBundle['manifest'], equals(oracleBundle['manifest']));
    });

    test('externalId sets match the oracle (order-independent)', () {
      final dartData = dartBundle['data'] as Map<String, dynamic>;
      final oracleData = oracleBundle['data'] as Map<String, dynamic>;
      for (final collection in [
        'sourceRecords',
        'calendarEvents',
        'courseSeries',
        'scheduleRelations',
      ]) {
        final dartIds = _externalIds(dartData[collection] as List);
        final oracleIds = _externalIds(oracleData[collection] as List);
        expect(
          dartIds,
          equals(oracleIds),
          reason: 'externalId sets differ for $collection',
        );
      }
    });

    test('first course event is field-for-field equal to the oracle', () {
      final dartEvent = _firstEvent(dartBundle, 'course');
      final oracleEvent = _firstEvent(oracleBundle, 'course');
      expect(canonicalJsonEncode(dartEvent), canonicalJsonEncode(oracleEvent));
    });

    test('first exam event is field-for-field equal to the oracle', () {
      final dartEvent = _firstEvent(dartBundle, 'exam');
      final oracleEvent = _firstEvent(oracleBundle, 'exam');
      expect(canonicalJsonEncode(dartEvent), canonicalJsonEncode(oracleEvent));
    });

    test('first course series is field-for-field equal to the oracle', () {
      final dartSeries = _firstSeries(dartBundle);
      final oracleSeries = _firstSeries(oracleBundle);
      expect(canonicalJsonEncode(dartSeries), canonicalJsonEncode(oracleSeries));
    });

    test('first source record is field-for-field equal to the oracle', () {
      final dartRecord = _firstRecord(dartBundle);
      final oracleRecord = _firstRecord(oracleBundle);
      expect(canonicalJsonEncode(dartRecord), canonicalJsonEncode(oracleRecord));
    });

    test('top-level envelope fields match the oracle', () {
      expect(dartBundle['schemaVersion'], equals('1.0'));
      expect(dartBundle['source'], equals('ustc_jw'));
      expect(dartBundle['subject'], equals({'accountId': _accountId}));
      expect(dartBundle['bundleId'], equals(_bundleId));
      expect(dartBundle['collectedAt'], equals('2026-08-22T12:00:00+08:00'));
      expect(dartBundle['producer'], equals(_producer));
    });
  });

  group('empty exam path', () {
    test('produces zero exam events and passes semantics', () {
      final courseDatum = jsonDecode(
        File('$_fixturesRoot/jw-empty-exam-input.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      const emptyExamHtml = '<table id="exams">\n'
          '  <tr>\n'
          '    <th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>\n'
          '    <th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>\n'
          '  </tr>\n'
          '</table>\n';
      final bundle = buildJwSourceBundle(
        courseDatum: courseDatum,
        examHtml: emptyExamHtml,
        accountId: _accountId,
        semester: _semester,
        bundleId: _bundleId,
        collectedAt: _collectedAt,
        producer: _producer,
      );
      final data = bundle['data'] as Map<String, dynamic>;
      final examEvents = (data['calendarEvents'] as List)
          .where((e) => (e as Map<String, dynamic>)['eventType'] == 'exam');
      expect(examEvents, isEmpty);
      expect((data['sourceRecords'] as List).length, equals(2));
      expect((data['calendarEvents'] as List).length, equals(1));
      expect((data['courseSeries'] as List).length, equals(1));
      // The builder calls validateSourceBundleSemantics internally; reaching
      // here means it passed.
    });
  });
}

String _canonicalDigest(Map<String, dynamic> bundle) {
  return sha256.convert(utf8.encode(canonicalJsonEncode(bundle))).toString();
}

Set<String> _externalIds(List<dynamic> items) {
  return items
      .map((item) => (item as Map<String, dynamic>)['externalId'] as String)
      .toSet();
}

Map<String, dynamic> _firstEvent(Map<String, dynamic> bundle, String eventType) {
  final events = bundle['data']['calendarEvents'] as List;
  return events.firstWhere(
    (e) => (e as Map<String, dynamic>)['eventType'] == eventType,
  ) as Map<String, dynamic>;
}

Map<String, dynamic> _firstSeries(Map<String, dynamic> bundle) {
  final series = bundle['data']['courseSeries'] as List;
  return series.first as Map<String, dynamic>;
}

Map<String, dynamic> _firstRecord(Map<String, dynamic> bundle) {
  final records = bundle['data']['sourceRecords'] as List;
  return records.first as Map<String, dynamic>;
}

/// Pretty-print a canonical-JSON string for human-readable diffing by
/// re-encoding with indentation.
String _pretty(String canonical) {
  final decoded = jsonDecode(canonical);
  return const JsonEncoder.withIndent('  ').convert(decoded);
}
