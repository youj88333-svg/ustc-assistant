#ifndef USTC_NOTIFICATION_PLATFORM_H_
#define USTC_NOTIFICATION_PLATFORM_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct NotificationIdentity {
  std::wstring app_id;
  GUID activator;
  std::wstring executable;
  std::wstring server_arguments;
  std::wstring display_name;
  std::wstring shortcut_name;
  // Empty keeps the legacy COM activation route for comparison.
  std::wstring protocol_scheme;
  std::wstring protocol_arguments;
};

struct NativeReminder {
  std::wstring id;
  int64_t delivery_unix_ms = 0;
  std::wstring digest;
  std::wstring activation;
  std::wstring title;
  std::wstring detail;
  std::wstring location;
};

// Parses only this fixed reminder URI grammar. It never launches a URI or
// grants authority; the caller must still resolve current owner/reset/target.
bool ParseNativeNotificationActivation(const std::wstring& value,
    const std::wstring& scheme, NativeReminder* parsed);

// Only this application's registered identity is enumerated or changed.
// Lifetime teardown releases COM resources; it does not cancel future plans.
class WindowsNotificationPlatform {
 public:
  explicit WindowsNotificationPlatform(NotificationIdentity identity);
  ~WindowsNotificationPlatform();
  WindowsNotificationPlatform(const WindowsNotificationPlatform&) = delete;
  WindowsNotificationPlatform& operator=(const WindowsNotificationPlatform&) = delete;

  HRESULT Register(std::function<void(std::wstring)> activation);
  // Explicit opt-in initialization, also used before the first Schedule.
  HRESULT EnsureScheduledIdentityReady();
  HRESULT Schedule(const NativeReminder& reminder);
  HRESULT Pending(std::vector<NativeReminder>* reminders);
  HRESULT Cancel(const std::wstring& id);
  HRESULT CancelAll();
  HRESULT ClearHistory();
  HRESULT HistoryCount(uint32_t* count);
  HRESULT Setting(int32_t* setting);
  // Explicit probe/uninstall cleanup only, never normal app exit.
  HRESULT RemoveRegistration();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
