#ifndef RUNNER_NOTIFICATION_ACTIVATION_H_
#define RUNNER_NOTIFICATION_ACTIVATION_H_

#include "notification_platform.h"

inline constexpr wchar_t kNotificationScheme[] = L"ustc-assistant-rewrite";

NotificationIdentity ProductionNotificationIdentity();
// The opt-in synthetic host is compiled out of Release/Profile builds.
bool NotificationTestHost();
bool SetNotificationExecutableDirectory();

class NotificationActivationHub {
 public:
  NotificationActivationHub();
  ~NotificationActivationHub();
  bool Enqueue(const std::wstring& uri) noexcept;
  std::vector<NativeReminder> Drain();
  void Close();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

enum class NotificationInstanceResult { primary, forwarded, blocked };

// Keeps the per-user/session mutex until the Flutter engine has been destroyed.
// No registration, database access, or business interpretation happens here.
class NotificationInstance {
 public:
  explicit NotificationInstance(bool test_host);
  ~NotificationInstance();
  NotificationInstanceResult AcquireOrForward(const std::wstring& uri);
  bool AttachWindow(HWND window);
  void DetachWindow();
  LRESULT Receive(const COPYDATASTRUCT* data,
                  NotificationActivationHub& activations) noexcept;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
