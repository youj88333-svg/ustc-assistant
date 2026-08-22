// M5: locks in the cross-platform "all-params" notification contract without
// a real platform. The existing `foreground_notification_test.dart` tests the
// reconciler through a `FakeNotifications` (a `ForegroundNotificationPort`
// fake) that bypasses `ForegroundNotificationAdapter` entirely, so the changed
// `initialize()`/`deliver()` code paths had zero coverage. This file injects a
// fake `FlutterLocalNotificationsPlugin` into the real adapter and asserts the
// `InitializationSettings` / `NotificationDetails` carry non-null Android and
// iOS params (the M5 contract). It does NOT test real notification delivery.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:ustc_assistant_app/features/reminders/data/foreground_notification_adapter.dart';

/// Fake [FlutterLocalNotificationsPlugin] that records the settings/details
/// passed to `initialize()` / `show()` instead of touching a platform channel.
class _RecordingNotificationsPlugin implements FlutterLocalNotificationsPlugin {
  InitializationSettings? initializeSettings;
  NotificationDetails? showNotificationDetails;
  bool initializeAvailable = true;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initializeSettings = settings;
    return initializeAvailable;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    showNotificationDetails = notificationDetails;
  }

  // --- The following members are unused by the adapter; no-op stubs. --------

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() =>
      null;

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      null;

  @override
  Future<void> cancel({required int id, String? tag}) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> cancelAllPendingNotifications() async {}

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {}

  @override
  Future<void> periodicallyShow({
    required int id,
    required RepeatInterval repeatInterval,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
  }) async {}

  @override
  Future<void> periodicallyShowWithDuration({
    required int id,
    required Duration repeatDurationInterval,
    required NotificationDetails notificationDetails,
    String? title,
    String? body,
    AndroidScheduleMode androidScheduleMode = AndroidScheduleMode.exact,
    String? payload,
  }) async {}

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async =>
      const <PendingNotificationRequest>[];

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async =>
      const <ActiveNotification>[];
}

void main() {
  test(
    'initialize() builds InitializationSettings with non-null Android and iOS params',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final adapter = ForegroundNotificationAdapter(plugin: plugin);

      await adapter.initialize();

      final settings = plugin.initializeSettings;
      expect(settings, isNotNull);
      expect(settings!.android, isNotNull);
      expect(settings.android, isA<AndroidInitializationSettings>());
      expect(settings.iOS, isNotNull);
      expect(settings.iOS, isA<DarwinInitializationSettings>());
    },
  );

  test(
    'deliver() builds NotificationDetails with non-null Android and iOS params',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final adapter = ForegroundNotificationAdapter(plugin: plugin);

      await adapter.deliver(
        const ReminderNotification(
          reminderId: 'r1',
          title: 't',
          body: 'b',
        ),
      );

      final details = plugin.showNotificationDetails;
      expect(details, isNotNull);
      expect(details!.android, isNotNull);
      expect(details.android, isA<AndroidNotificationDetails>());
      expect(details.iOS, isNotNull);
      expect(details.iOS, isA<DarwinNotificationDetails>());
    },
  );
}
