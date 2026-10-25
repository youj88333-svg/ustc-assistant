// Manual public-source diagnosis only, never part of automated checks.
// No formal database, user records, credentials, model or browser session.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/morning_brief_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/morning_notice_query.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';

final class _EphemeralOwner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || arguments.single != '--public-notices-only') {
    stderr.writeln('需显式指定 --public-notices-only；仅匿名诊断两个通知栏目。');
    exitCode = 2;
    return;
  }
  const clock = SystemClock();
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _EphemeralOwner(),
    clock: clock,
  );
  final budget = MorningHttpBudget()..reset();
  final targets = PublicHttpTargets();
  final queries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
    clock: clock,
    targets: targets,
    sessionFactory: (source) => IoPublicHttpSession(
      targets: targets,
      source: source,
      beforeRequest: budget.consume,
    ),
  );
  try {
    await store.initialize();
    final day = beijingDay(clock.nowUtc).subtract(const Duration(days: 1));
    final result = await MorningNoticeQuery(
      source: queries,
      clock: clock,
    ).collect(day);
    stdout.writeln(
      jsonEncode({
        'kind': 'morning-public-diagnosis-v1',
        'httpAttempts': budget.requests,
        'operations': result.operations,
        'matchingNotices': result.notices.length,
        'coverage': [
          for (final c in result.coverage)
            {
              'provider': c.provider.name,
              'pages': c.pages,
              'matched': c.matched,
              'unknownDates': c.unknownDates,
              'complete': c.complete,
              'failure': c.failure?.name,
            },
        ],
      }),
    );
  } on PublicFailure catch (error) {
    stdout.writeln(
      jsonEncode({
        'kind': 'morning-public-diagnosis-v1',
        'failure': error.code.name,
        'httpAttempts': budget.requests,
      }),
    );
    exitCode = 1;
  } finally {
    await queries.close();
    await store.close();
  }
}
