import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/unavailable_mobile_services.dart';

void main() {
  group('UnavailableMobileNotifications', () {
    test('reports no capability and exposes no activations', () async {
      final notifications = UnavailableMobileNotifications();

      expect(await notifications.activations.toList(), isEmpty);
      expect(
        await notifications.initialize(),
        const NotificationCapability(
          available: false,
          enabledBySystem: false,
          schedulesAfterExit: false,
          activationAvailable: false,
        ),
      );
    });

    test(
      'does not fabricate an empty queue or claim schedule cleanup',
      () async {
        final notifications = UnavailableMobileNotifications();
        final unavailable = _reminderFailure(
          ReminderFailureCode.platformUnavailable,
        );

        await expectLater(notifications.pending(), unavailable);
        await expectLater(notifications.schedule(_request()), unavailable);
        await expectLater(notifications.cancel('r1'), unavailable);
        await expectLater(notifications.clearOwn(), unavailable);
      },
    );

    test(
      'close is idempotent and all operations report closed afterward',
      () async {
        final notifications = UnavailableMobileNotifications();
        await notifications.close();
        await notifications.close();
        final closed = _reminderFailure(ReminderFailureCode.closed);

        await expectLater(notifications.initialize(), closed);
        await expectLater(notifications.pending(), closed);
        await expectLater(notifications.schedule(_request()), closed);
        await expectLater(notifications.cancel('r1'), closed);
        await expectLater(notifications.clearOwn(), closed);
        expect(await notifications.activations.toList(), isEmpty);
      },
    );
  });

  group('UnavailableMobileSpeechInput', () {
    test(
      'starts idle, then reports unsupported without opening capture',
      () async {
        final input = UnavailableMobileSpeechInput();
        final delivered = <SpeechInputView>[];
        final done = Completer<void>();
        final subscription = input.changes.listen(
          delivered.add,
          onDone: done.complete,
        );

        expect(input.view.phase, SpeechInputPhase.idle);
        expect(input.view.revision, 0);
        expect(input.view.failure, isNull);
        expect(input.view.transcript, isNull);

        await input.start();
        await Future<void>.delayed(Duration.zero);

        expect(input.view.phase, SpeechInputPhase.idle);
        expect(input.view.revision, 1);
        expect(input.view.failure, SpeechInputFailureCode.unsupportedPlatform);
        expect(input.view.transcript, isNull);
        expect(delivered, hasLength(1));
        expect(
          delivered.single.failure,
          SpeechInputFailureCode.unsupportedPlatform,
        );

        final failedView = input.view;
        await input.finish();
        expect(input.view, same(failedView));

        await input.cancel();
        await Future<void>.delayed(Duration.zero);
        expect(input.view.phase, SpeechInputPhase.idle);
        expect(input.view.failure, isNull);
        expect(delivered, hasLength(2));

        await input.start();
        await Future<void>.delayed(Duration.zero);
        expect(input.view.revision, 2);
        expect(input.view.failure, SpeechInputFailureCode.unsupportedPlatform);
        expect(delivered, hasLength(3));

        await input.close();
        await input.close();
        await done.future;
        await subscription.cancel();
        expect(input.view.phase, SpeechInputPhase.closed);
        expect(delivered, hasLength(4));
        expect(delivered.last.phase, SpeechInputPhase.closed);
      },
    );

    test(
      'operations after close fail safely and cancel stays harmless',
      () async {
        final input = UnavailableMobileSpeechInput();
        await input.close();
        await input.close();

        final closed = throwsA(
          isA<SpeechInputFailure>().having(
            (failure) => failure.code,
            'code',
            SpeechInputFailureCode.closed,
          ),
        );
        await expectLater(input.start(), closed);
        await expectLater(input.finish(), closed);
        await input.cancel();
        expect(input.view.phase, SpeechInputPhase.closed);
      },
    );
  });
}

NotificationRequest _request() => NotificationRequest(
  id: 'r1',
  deliveryAtUtc: DateTime.utc(2026, 10, 16, 9),
  digest: 'a' * 64,
  token: 'b' * 64,
  title: 'Synthetic reminder',
  detail: 'Synthetic detail',
  location: 'Synthetic location',
);

Matcher _reminderFailure(ReminderFailureCode code) => throwsA(
  isA<ReminderFailure>().having((failure) => failure.code, 'code', code),
);
