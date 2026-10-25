import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_authentication_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fixed CAS remote object submits once and follows school handlers',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in [
          JwAuthenticationFixtureMode.normal,
          JwAuthenticationFixtureMode.portal,
          JwAuthenticationFixtureMode.deferred,
          JwAuthenticationFixtureMode.publicShape,
          JwAuthenticationFixtureMode.publicShapeDeferred,
        ]) {
          final fixture = await JwAuthenticationFixture.start(mode);
          _BrowserHarness? harness;
          try {
            final active = await _BrowserHarness.start(fixture);
            harness = active;
            if (mode == JwAuthenticationFixtureMode.deferred ||
                mode == JwAuthenticationFixtureMode.publicShapeDeferred) {
              expect(await active.advance(), JwLoginState.waiting);
              await active.action('jwRenderForm');
            }
            final prepared = await active.prepare();

            // Strict RPC vocabulary, typed secret bytes and session association.
            for (final args in [
              {...prepared.arguments, 'script': 'ignored'},
              {
                ...prepared.arguments,
                'credentialBytes': <int>[1, 2, 3],
              },
              {
                ...prepared.arguments,
                'credentialBytes': _secretBytes(),
                'url': '${fixture.origin.origin}/cas/login',
              },
            ]) {
              await expectLater(
                _channel.invokeMethod<Object>(
                  args.containsKey('credentialBytes')
                      ? 'submitJwLogin'
                      : 'advanceJwLogin',
                  args,
                ),
                throwsA(
                  isA<PlatformException>().having(
                    (error) => error.details,
                    'reason',
                    'invalidSnapshot',
                  ),
                ),
              );
            }
            final revoked = JwSecretLease(_secretBytes())..revoke();
            await expectLater(
              active.browser.submitJwLogin(
                session: prepared.event.session,
                document: prepared.event.document,
                operation: prepared.operation,
                credentials: revoked,
              ),
              throwsA(isA<JwCredentialException>()),
            );
            expect(fixture.submitCount, 0);
            final bytes = _secretBytes();
            final state = await _submitAllowStale(
              active,
              prepared,
              JwSecretLease(bytes),
            );
            expect(state, anyOf(JwLoginState.submitted, isNull));
            expect(bytes.every((value) => value == 0), isTrue);
            await expectLater(
              active.browser.submitJwLogin(
                session: prepared.event.session,
                document: prepared.event.document,
                operation: prepared.operation,
                credentials: JwSecretLease(_secretBytes()),
              ),
              throwsA(_failure(FailureCode.staleResult)),
            );
            await active.waitFor(
              () => fixture.businessPageCount == 1 && fixture.submitCount == 1,
              'synthetic school redirect did not finish',
            );
            await active.waitReady(newerThan: prepared.event.document);
            expect(
              await active.advanceUntilSettled(),
              JwLoginState.businessReady,
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(fixture.credentialsMatched, isTrue);
            expect(fixture.passwordEventMatched, isTrue);
            expect(fixture.passwordEventCount, 1);
            expect(fixture.buttonClickCount, 1);
            expect(fixture.auxiliaryPasswordChanged, isFalse);
            expect(fixture.unexpectedOriginSubmitCount, 0);
            expect(fixture.redirectCount, 3);
            expect(fixture.submitCount, 1);
          } finally {
            await harness?.close();
            await fixture.close();
          }
        }
      });
    },
  );

  testWidgets(
    'only the mapped exact CAS document and unambiguous form accept a lease',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in [
          JwAuthenticationFixtureMode.wrongOrigin,
          JwAuthenticationFixtureMode.wrongPath,
          JwAuthenticationFixtureMode.multipleForms,
          JwAuthenticationFixtureMode.hiddenPassword,
          JwAuthenticationFixtureMode.disabledSubmit,
          JwAuthenticationFixtureMode.challenge,
          JwAuthenticationFixtureMode.ambiguousSubmit,
          JwAuthenticationFixtureMode.publicShapeChallenge,
          JwAuthenticationFixtureMode.publicShapeActivePasskey,
          JwAuthenticationFixtureMode.publicShapeVisibleDuplicate,
          JwAuthenticationFixtureMode.publicShapeUnknownInput,
        ]) {
          final fixture = await JwAuthenticationFixture.start(mode);
          _BrowserHarness? harness;
          try {
            final active = await _BrowserHarness.start(fixture);
            harness = active;
            expect(await active.advanceUntilSettled(), switch (mode) {
              JwAuthenticationFixtureMode.wrongOrigin ||
              JwAuthenticationFixtureMode.wrongPath =>
                JwLoginState.manualRequired,
              JwAuthenticationFixtureMode.challenge ||
              JwAuthenticationFixtureMode.publicShapeChallenge ||
              JwAuthenticationFixtureMode.publicShapeActivePasskey =>
                JwLoginState.challengeRequired,
              _ => JwLoginState.pageStructureChanged,
            });
            final current = active.current;
            await expectLater(
              active.browser.submitJwLogin(
                session: current.session,
                document: current.document,
                operation: active.operation,
                credentials: JwSecretLease(_secretBytes()),
              ),
              throwsA(_failure(FailureCode.staleResult)),
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(fixture.submitCount, 0);
            expect(fixture.passwordEventCount, 0);
            expect(fixture.buttonClickCount, 0);
            if (mode == JwAuthenticationFixtureMode.challenge) {
              final original = active.current;
              await active.action('jwManualContinue');
              await active.waitReady(newerThan: original.document);
              expect(
                await active.advanceUntilSettled(),
                JwLoginState.businessReady,
              );
            }
          } finally {
            await harness?.close();
            await fixture.close();
          }
        }
      });
    },
  );

  testWidgets(
    'refresh, route, other origin, node changes and close revoke prepared objects',
    (tester) async {
      await tester.runAsync(() async {
        for (final action in [
          'jwRefresh',
          'jwRouteChange',
          'jwSameUrlHistory',
          'jwCrossOrigin',
          'jwReplacePassword',
          'jwHidePassword',
          'userClose',
          'close',
        ]) {
          final fixture = await JwAuthenticationFixture.start(
            JwAuthenticationFixtureMode.normal,
          );
          _BrowserHarness? harness;
          try {
            final active = await _BrowserHarness.start(fixture);
            harness = active;
            final prepared = await active.prepare();
            if (action == 'close') {
              await active.closeNative();
            } else if (action == 'userClose') {
              await active.action(action);
              await active.waitFor(
                () => active.events.any(
                  (event) => event.kind == BrowserEventKind.userClosed,
                ),
                'synthetic visible close was not delivered',
              );
            } else {
              await active.action(action);
              if (action != 'jwReplacePassword' && action != 'jwHidePassword') {
                await active.waitReady(newerThan: prepared.event.document);
              }
            }
            if (action == 'jwReplacePassword' || action == 'jwHidePassword') {
              expect(
                await _submitAllowStale(
                  active,
                  prepared,
                  JwSecretLease(_secretBytes()),
                ),
                JwLoginState.pageStructureChanged,
              );
              expect(await active.advance(), JwLoginState.manualRequired);
            } else {
              await expectLater(
                active.browser.submitJwLogin(
                  session: prepared.event.session,
                  document: prepared.event.document,
                  operation: prepared.operation,
                  credentials: JwSecretLease(_secretBytes()),
                ),
                throwsA(
                  _failure(
                    action == 'close' || action == 'userClose'
                        ? FailureCode.closed
                        : FailureCode.staleResult,
                  ),
                ),
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(fixture.submitCount, 0);
            expect(fixture.passwordEventCount, 0);
            expect(fixture.buttonClickCount, 0);
          } finally {
            await harness?.close();
            await fixture.close();
          }
        }
      });
    },
  );

  testWidgets(
    'synchronous username handlers stop password delivery after a mutation',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in [
          JwAuthenticationFixtureMode.replaceOnUsername,
          JwAuthenticationFixtureMode.hideOnUsername,
          JwAuthenticationFixtureMode.routeOnUsername,
          JwAuthenticationFixtureMode.sameUrlOnUsername,
          JwAuthenticationFixtureMode.publicShapePasskeyOnUsername,
          JwAuthenticationFixtureMode.publicShapeRevealMirrorOnUsername,
        ]) {
          final fixture = await JwAuthenticationFixture.start(mode);
          _BrowserHarness? harness;
          try {
            final active = await _BrowserHarness.start(fixture);
            harness = active;
            final prepared = await active.prepare();
            final state = await _submitAllowStale(
              active,
              prepared,
              JwSecretLease(_secretBytes()),
            );
            expect(
              state,
              anyOf(switch (mode) {
                JwAuthenticationFixtureMode.replaceOnUsername ||
                JwAuthenticationFixtureMode.hideOnUsername ||
                JwAuthenticationFixtureMode.publicShapeRevealMirrorOnUsername =>
                  JwLoginState.pageStructureChanged,
                JwAuthenticationFixtureMode.publicShapePasskeyOnUsername =>
                  JwLoginState.challengeRequired,
                _ => JwLoginState.manualRequired,
              }, isNull),
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(fixture.submitCount, 0);
            expect(fixture.passwordEventCount, 0);
            expect(fixture.buttonClickCount, 0);
          } finally {
            await harness?.close();
            await fixture.close();
          }
        }
      });
    },
  );
}

const _channel = MethodChannel('ustc_assistant/observation_v1');

Uint8List _secretBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'username': JwAuthenticationFixture.syntheticUsername,
      'password': JwAuthenticationFixture.syntheticPassword,
    }),
  ),
);

Matcher _failure(FailureCode code) =>
    isA<AppFailure>().having((failure) => failure.code, 'code', code);

Future<JwLoginState?> _submitAllowStale(
  _BrowserHarness harness,
  _PreparedLogin prepared,
  JwSecretLease credentials,
) async {
  try {
    return await harness.browser.submitJwLogin(
      session: prepared.event.session,
      document: prepared.event.document,
      operation: prepared.operation,
      credentials: credentials,
    );
  } on AppFailure catch (failure) {
    // A school handler may navigate before CDP's completion is delivered.
    // The capability has already been consumed; never retry that submission.
    if (failure.code != FailureCode.staleResult) rethrow;
    return null;
  }
}

final class _PreparedLogin {
  const _PreparedLogin(this.event, this.operation);
  final BrowserEvent event;
  final int operation;
  Map<String, Object> get arguments => {
    'session': event.session,
    'document': event.document,
    'operation': operation,
  };
}

final class _BrowserHarness {
  _BrowserHarness(this.browser, this.root, this.events, this.subscription);
  final NativeObservationBrowser browser;
  final Directory root;
  final List<BrowserEvent> events;
  final StreamSubscription<BrowserEvent> subscription;
  int operation = 0;
  bool _nativeClosed = false;
  bool _disposed = false;

  BrowserEvent get current =>
      events.lastWhere((event) => event.kind == BrowserEventKind.ready);

  static Future<_BrowserHarness> start(JwAuthenticationFixture fixture) async {
    final root = await Directory.systemTemp.createTemp('ustc_jw_auth_native_');
    final browser = NativeObservationBrowser();
    final events = <BrowserEvent>[];
    final subscription = browser.events.listen(events.add);
    final harness = _BrowserHarness(browser, root, events, subscription);
    try {
      await browser.open(
        session: 1,
        profilePath: p.join(root.path, 'profile'),
        target: ObservationTarget.fixture(
          fixture.initialUri,
          additionalOrigins: [fixture.relayOrigin],
        ),
      );
      await harness.waitReady();
      return harness;
    } catch (_) {
      await harness.close();
      rethrow;
    }
  }

  Future<void> waitFor(bool Function() condition, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> waitReady({int newerThan = -1}) => waitFor(
    () => events.any(
      (event) =>
          event.kind == BrowserEventKind.ready && event.document > newerThan,
    ),
    'synthetic document did not become ready',
  );

  Future<JwLoginState> advance() async {
    final event = current;
    return browser.advanceJwLogin(
      session: event.session,
      document: event.document,
      operation: ++operation,
    );
  }

  Future<JwLoginState> advanceUntilSettled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final event = current;
      try {
        final state = await advance();
        if (state == JwLoginState.portalActivated) {
          await waitReady(newerThan: event.document);
        } else if (state != JwLoginState.waiting) {
          return state;
        }
      } on AppFailure catch (failure) {
        if (failure.code != FailureCode.staleResult &&
            failure.code != FailureCode.busy) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('synthetic authentication action did not settle');
  }

  Future<_PreparedLogin> prepare() async {
    expect(await advanceUntilSettled(), JwLoginState.formReady);
    return _PreparedLogin(current, operation);
  }

  Future<void> action(String action) async {
    final event = current;
    await _channel.invokeMethod<void>('exerciseFixture', {
      'session': event.session,
      'document': event.document,
      'action': action,
    });
  }

  Future<void> closeNative() async {
    if (_nativeClosed) return;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!_nativeClosed) {
      try {
        await browser.close(1);
        _nativeClosed = true;
      } on AppFailure catch (failure) {
        if (failure.code != FailureCode.cleanupPending) rethrow;
        if (DateTime.now().isAfter(deadline)) {
          fail('synthetic native controller did not close');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    while (!await browser.drained(1)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('synthetic native close did not drain');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    await closeNative();
    await subscription.cancel();
    await browser.dispose();
    _disposed = true;
    final resolved = await root.resolveSymbolicLinks();
    if (!p.equals(resolved, root.path) ||
        !p.isWithin(Directory.systemTemp.path, resolved) ||
        !p.basename(resolved).startsWith('ustc_jw_auth_native_')) {
      fail('synthetic cleanup root was redirected');
    }
    await root.delete(recursive: true);
  }
}
