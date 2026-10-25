#include "notification_activation.h"

#include <sddl.h>

#include <algorithm>
#include <mutex>
#include <utility>

namespace {
constexpr ULONG_PTR kActivationMessage = 0x4D364E31;
constexpr wchar_t kWindowProperty[] =
    L"USTC.Assistant.DesignReset.Notification.7A716A0C";

struct ScopedHandle {
  HANDLE value = nullptr;
  ~ScopedHandle() { if (value) CloseHandle(value); }
};

struct LocalString {
  LPWSTR value = nullptr;
  ~LocalString() { if (value) LocalFree(value); }
};

std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
                                       static_cast<DWORD>(path.size()));
  if (!size || size >= path.size()) return {};
  path.resize(size);
  return path;
}

std::wstring ProcessUserSid(HANDLE process) {
  ScopedHandle token;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return {};
  DWORD bytes = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &bytes);
  if (!bytes || bytes > 65536) return {};
  std::vector<BYTE> buffer(bytes);
  if (!GetTokenInformation(token.value, TokenUser, buffer.data(), bytes, &bytes))
    return {};
  LocalString sid;
  const bool valid = ConvertSidToStringSidW(
      reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid.value) != FALSE;
  if (!valid) return {};
  return sid.value;
}

struct WindowSearch {
  std::wstring property;
  std::wstring sid;
  DWORD session = 0;
  HWND found = nullptr;
  bool failed = false;
};

BOOL CALLBACK FindNotificationWindow(HWND window, LPARAM value) {
  auto& search = *reinterpret_cast<WindowSearch*>(value);
  try {
  if (GetPropW(window, search.property.c_str()) != reinterpret_cast<HANDLE>(1))
    return TRUE;
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  DWORD session = 0;
  if (!process_id || !ProcessIdToSessionId(process_id, &session) ||
      session != search.session) return TRUE;
  ScopedHandle process;
  process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (!process.value) return TRUE;
  const auto sid = ProcessUserSid(process.value);
  if (sid != search.sid) return TRUE;
  search.found = window;
  return FALSE;
  } catch (...) {
    search.failed = true;
    return FALSE;
  }
}

void BringForward(HWND window) {
  if (IsIconic(window)) ShowWindowAsync(window, SW_RESTORE);
  else ShowWindowAsync(window, SW_SHOW);
  SetForegroundWindow(window);
}
}  // namespace

NotificationIdentity ProductionNotificationIdentity() {
  NotificationIdentity identity;
  identity.app_id = L"USTC.Assistant.DesignReset";
  identity.activator = {0x7a716a0c, 0x604e, 0x4dd8,
                        {0xa0, 0x1e, 0x5b, 0x69, 0x93, 0x51, 0x71, 0x41}};
  identity.executable = ExecutablePath();
  identity.server_arguments = L"--ustc-notification-com";
  identity.display_name = L"USTC Assistant";
  identity.shortcut_name = L"USTC Assistant (Rewrite)";
  identity.protocol_scheme = kNotificationScheme;
  identity.protocol_arguments = L"--ustc-notification";
  return identity;
}

bool NotificationTestHost() {
#ifdef _DEBUG
  wchar_t value[2]{};
  return GetEnvironmentVariableW(L"USTC_NOTIFICATION_TEST_HOST", value, 2) == 1 &&
      value[0] == L'1';
#else
  return false;
#endif
}

bool SetNotificationExecutableDirectory() {
  const auto executable = ExecutablePath();
  const auto slash = executable.find_last_of(L"\\/");
  return slash != std::wstring::npos &&
      SetCurrentDirectoryW(executable.substr(0, slash).c_str()) != FALSE;
}

struct NotificationActivationHub::Impl {
  std::mutex mutex;
  std::vector<NativeReminder> queue;
  bool closed = false;
};

NotificationActivationHub::NotificationActivationHub()
    : impl_(std::make_unique<Impl>()) {}
NotificationActivationHub::~NotificationActivationHub() = default;

bool NotificationActivationHub::Enqueue(const std::wstring& uri) noexcept {
  try {
    NativeReminder parsed;
    if (!ParseNativeNotificationActivation(uri, kNotificationScheme, &parsed))
      return false;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->closed) return false;
    for (const auto& old : impl_->queue) {
      if (old.id == parsed.id && old.digest == parsed.digest &&
          old.activation == parsed.activation) return true;
    }
    if (impl_->queue.size() >= 32) return false;
    impl_->queue.push_back(std::move(parsed));
    return true;
  } catch (...) { return false; }
}

std::vector<NativeReminder> NotificationActivationHub::Drain() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  std::vector<NativeReminder> result;
  result.swap(impl_->queue);
  return result;
}

void NotificationActivationHub::Close() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->closed = true;
  impl_->queue.clear();
}

struct NotificationInstance::Impl {
  HANDLE mutex = nullptr;
  bool owns_mutex = false;
  HWND window = nullptr;
  bool test_host = false;
  std::wstring property = kWindowProperty;
};

NotificationInstance::NotificationInstance(bool test_host)
    : impl_(std::make_unique<Impl>()) {
  impl_->test_host = test_host;
  if (test_host) impl_->property += L".TestHost." + std::to_wstring(GetCurrentProcessId());
}

NotificationInstance::~NotificationInstance() {
  DetachWindow();
  if (impl_->owns_mutex) ReleaseMutex(impl_->mutex);
  if (impl_->mutex) CloseHandle(impl_->mutex);
}

NotificationInstanceResult NotificationInstance::AcquireOrForward(
    const std::wstring& uri) {
  if (impl_->mutex) return NotificationInstanceResult::blocked;
  if (!uri.empty()) {
    NativeReminder parsed;
    if (!ParseNativeNotificationActivation(uri, kNotificationScheme, &parsed))
      return NotificationInstanceResult::blocked;
  }
  WindowSearch search;
  search.property = impl_->property;
  search.sid = ProcessUserSid(GetCurrentProcess());
  if (search.sid.empty() ||
      !ProcessIdToSessionId(GetCurrentProcessId(), &search.session))
    return NotificationInstanceResult::blocked;
  std::wstring name = L"Local\\USTC.Assistant.DesignReset." + search.sid +
      L"." + std::to_wstring(search.session);
  if (impl_->test_host) name += L".TestHost." + std::to_wstring(GetCurrentProcessId());
  impl_->mutex = CreateMutexW(nullptr, FALSE, name.c_str());
  if (!impl_->mutex) return NotificationInstanceResult::blocked;
  const auto deadline = GetTickCount64() + 5000;
  do {
    const DWORD acquired = WaitForSingleObject(impl_->mutex, 0);
    if (acquired == WAIT_OBJECT_0 || acquired == WAIT_ABANDONED) {
      impl_->owns_mutex = true;
      return NotificationInstanceResult::primary;
    }
    if (acquired != WAIT_TIMEOUT) return NotificationInstanceResult::blocked;
    EnumWindows(FindNotificationWindow, reinterpret_cast<LPARAM>(&search));
    if (search.failed) return NotificationInstanceResult::blocked;
    if (search.found) {
      if (!uri.empty()) {
        COPYDATASTRUCT data{};
        data.dwData = kActivationMessage;
        data.cbData = static_cast<DWORD>((uri.size() + 1) * sizeof(wchar_t));
        data.lpData = const_cast<wchar_t*>(uri.c_str());
        DWORD_PTR accepted = 0;
        if (!SendMessageTimeoutW(search.found, WM_COPYDATA, 0,
              reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK,
              2000, &accepted) || accepted != TRUE)
          return NotificationInstanceResult::blocked;
      }
      BringForward(search.found);
      return NotificationInstanceResult::forwarded;
    }
    Sleep(50);
  } while (GetTickCount64() < deadline);
  return NotificationInstanceResult::blocked;
}

bool NotificationInstance::AttachWindow(HWND window) {
  if (!impl_->owns_mutex || !window || impl_->window) return false;
  if (!SetPropW(window, impl_->property.c_str(), reinterpret_cast<HANDLE>(1)))
    return false;
  impl_->window = window;
  return true;
}

void NotificationInstance::DetachWindow() {
  if (impl_->window) RemovePropW(impl_->window, impl_->property.c_str());
  impl_->window = nullptr;
}

LRESULT NotificationInstance::Receive(const COPYDATASTRUCT* data,
    NotificationActivationHub& activations) noexcept {
  try {
    if (!data || data->dwData != kActivationMessage || !data->lpData ||
        data->cbData < 2 * sizeof(wchar_t) ||
        data->cbData > 257 * sizeof(wchar_t) ||
        data->cbData % sizeof(wchar_t) != 0) return FALSE;
    const size_t length = data->cbData / sizeof(wchar_t);
    const auto* characters = static_cast<const wchar_t*>(data->lpData);
    if (characters[length - 1] != L'\0' ||
        std::find(characters, characters + length - 1, L'\0') !=
            characters + length - 1) return FALSE;
    if (!activations.Enqueue(std::wstring(characters, length - 1))) return FALSE;
    if (impl_->window) BringForward(impl_->window);
    return TRUE;
  } catch (...) { return FALSE; }
}
