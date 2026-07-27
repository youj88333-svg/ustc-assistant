import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class ReminderNotification {
  const ReminderNotification({
    required this.reminderId,
    required this.title,
    required this.body,
  });

  final String reminderId;
  final String title;
  final String body;
}

class NotificationDeliveryError implements Exception {
  const NotificationDeliveryError(this.code);

  final String code;
}

abstract interface class ForegroundNotificationPort {
  Future<void> deliver(ReminderNotification notification);
}

class ForegroundNotificationAdapter implements ForegroundNotificationPort {
  ForegroundNotificationAdapter({FlutterLocalNotificationsPlugin? plugin})
    : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final available = await plugin.initialize(
        settings: const InitializationSettings(
          windows: WindowsInitializationSettings(
            appName: 'USTC Assistant',
            appUserModelId: 'Ustc.Assistant.Development',
            guid: '66bcb098-3b43-4f4d-aebb-22ea2c112c5d',
          ),
        ),
      );
      if (available == false) {
        throw const NotificationDeliveryError('unavailable');
      }
      _initialized = true;
    } on NotificationDeliveryError {
      rethrow;
    } on Object {
      throw const NotificationDeliveryError('unavailable');
    }
  }

  @override
  Future<void> deliver(ReminderNotification notification) async {
    await initialize();
    try {
      await plugin.show(
        id: notification.reminderId.hashCode & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: const NotificationDetails(
          windows: WindowsNotificationDetails(),
        ),
        payload: notification.reminderId,
      );
    } on Object {
      throw const NotificationDeliveryError('unavailable');
    }
  }
}
