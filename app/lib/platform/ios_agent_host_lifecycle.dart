import 'package:flutter/services.dart';

/// UIKit application activity is independent of Flutter surface visibility.
/// A full-screen school/Photos/Files controller may hide Flutter while the
/// application is still active, so it must not be mistaken for backgrounding.
enum IOSAgentHostState { active, inactive, revoked }

final class IOSAgentHostLifecycle {
  const IOSAgentHostLifecycle({
    this.channel = const EventChannel('ustc_assistant/ios_host_lifecycle_v1'),
  });

  final EventChannel channel;

  Stream<IOSAgentHostState> get changes =>
      channel.receiveBroadcastStream().map((value) {
        if (value == 'active') return IOSAgentHostState.active;
        if (value == 'inactive') return IOSAgentHostState.inactive;
        if (value == 'revoked') return IOSAgentHostState.revoked;
        throw const FormatException('invalid_ios_host_state');
      });
}
