import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/runtime/jw_job_arbiter.dart';

void main() {
  test('acquire is synchronous and a second job fails with bridge_busy', () {
    final arbiter = JwJobArbiter();
    final first = arbiter.acquire(jobId: 'job-1', kind: JwJobKind.sync);
    expect(
      () => arbiter.acquire(jobId: 'job-2', kind: JwJobKind.firstLogin),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'bridge_busy',
        ),
      ),
    );
    arbiter.release(first);
  });

  test('foreign release cannot free the held lease', () {
    final arbiter = JwJobArbiter();
    final held = arbiter.acquire(jobId: 'held', kind: JwJobKind.sync);
    final other = JwJobArbiter();
    final foreign = other.acquire(jobId: 'foreign', kind: JwJobKind.sync);
    expect(() => arbiter.release(foreign), throwsStateError);
    expect(arbiter.isBusy, isTrue);
    arbiter.release(held);
    other.release(foreign);
  });
}
