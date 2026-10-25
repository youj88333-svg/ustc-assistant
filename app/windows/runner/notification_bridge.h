#ifndef RUNNER_NOTIFICATION_BRIDGE_H_
#define RUNNER_NOTIFICATION_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <memory>

class NotificationActivationHub;

class NotificationBridge {
 public:
  NotificationBridge(flutter::BinaryMessenger* messenger,
                     NotificationActivationHub& activations, bool test_host);
  ~NotificationBridge();
  NotificationBridge(const NotificationBridge&) = delete;
  NotificationBridge& operator=(const NotificationBridge&) = delete;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
