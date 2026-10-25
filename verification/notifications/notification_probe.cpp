#include "notification_platform.h"
#include <NotificationActivationCallback.h>
#include <appmodel.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <wrl.h>
#include <winrt/base.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <filesystem>
#include <string>

namespace {
std::wstring ProbeUri(const NotificationIdentity& identity) {
  return identity.protocol_scheme + L"://reminder/v1/m6test01/" +
      std::wstring(64, L'a') + L"/synthetic-token-0001";
}

bool ParserChecks(const NotificationIdentity& identity) {
  const auto valid = ProbeUri(identity);
  NativeReminder parsed;
  bool ok = ParseNativeNotificationActivation(valid, identity.protocol_scheme, &parsed) &&
      parsed.id == L"m6test01" && parsed.digest == std::wstring(64, L'a') &&
      parsed.activation == L"synthetic-token-0001";
  const auto prefix = identity.protocol_scheme + L"://reminder/v1/";
  const std::vector<std::wstring> invalid = {
      valid + L"?target=other", valid + L"#fragment", valid + L"/extra",
      valid + L" --server", valid + L"\"", L" " + valid, valid + L"\n",
      prefix + L"../" + std::wstring(64, L'a') + L"/synthetic-token-0001",
      prefix + L"m6test01/" + std::wstring(63, L'a') + L"/synthetic-token-0001",
      prefix + L"m6test01/" + std::wstring(64, L'a') + L"/short",
      prefix + L"m6test01/" + std::wstring(64, L'a') + L"/" + std::wstring(65, L'a'),
      prefix + L"%2e%2e/" + std::wstring(64, L'a') + L"/synthetic-token-0001",
      identity.protocol_scheme + L"://reminder/v2/m6test01/" +
          std::wstring(64, L'a') + L"/synthetic-token-0001",
      std::wstring(257, L'a'), valid + std::wstring(1, L'\0')};
  for (const auto& value : invalid) {
    parsed.id = L"unchanged";
    ok = !ParseNativeNotificationActivation(value, identity.protocol_scheme, &parsed) &&
        parsed.id == L"unchanged" && ok;
  }
  ok = !ParseNativeNotificationActivation(valid, L"ustc-other", &parsed) &&
      !ParseNativeNotificationActivation(valid, identity.protocol_scheme, nullptr) && ok;
  const auto largest = std::wstring(64, L'a') + L"://reminder/v1/" +
      std::wstring(16, L'b') + L"/" + std::wstring(64, L'c') + L"/" + std::wstring(64, L'd');
  ok = ParseNativeNotificationActivation(largest, std::wstring(64, L'a'), &parsed) && ok;
  printf("{\"stage\":\"protocolParser\",\"passed\":%s}\n", ok ? "true" : "false");
  return ok;
}

bool ProbeProtocolRegistrationMatches(const NotificationIdentity& identity) {
  const auto path = L"Software\\Classes\\" + identity.protocol_scheme;
  wchar_t owner[512]{};
  wchar_t command[32768]{};
  DWORD bytes = sizeof(owner);
  if (RegGetValueW(HKEY_CURRENT_USER, path.c_str(), L"USTCNotificationOwner",
      RRF_RT_REG_SZ, nullptr, owner, &bytes) != ERROR_SUCCESS) return false;
  wchar_t clsid[40]{};
  StringFromGUID2(identity.activator, clsid, 40);
  if (owner != identity.app_id + L"|" + clsid) return false;
  bytes = sizeof(command);
  if (RegGetValueW(HKEY_CURRENT_USER, (path + L"\\shell\\open\\command").c_str(),
      nullptr, RRF_RT_REG_SZ, nullptr, command, &bytes) != ERROR_SUCCESS) return false;
  return command == L"\"" + identity.executable + L"\" " + identity.protocol_arguments + L" \"%1\"";
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 4) return 2;
  const std::wstring requested_action(argv[3]);
  const bool protocol = requested_action.rfind(L"protocol-", 0) == 0;
  const auto action = protocol ? requested_action.substr(9) : requested_action;
  const bool activating = !protocol && (action == L"activate" || action == L"activate-default" ||
      action == L"activate-mta" || action == L"activate-com" || action == L"activate-shell");
  GUID guid{};
  if (FAILED(CLSIDFromString(argv[2], &guid))) return 2;
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, 32768);
  const std::wstring suffix(argv[1]);
  if (suffix.size() != 32 || suffix.find_first_not_of(L"0123456789abcdef") != std::wstring::npos)
    return 2;
  NotificationIdentity identity{L"USTC.Assistant.M6Probe." + suffix, guid, executable,
      suffix + L" " + argv[2] + L" server", L"USTC M6 合成通知验证",
      L"USTC M6 Probe " + suffix};
  if (protocol) {
    identity.protocol_scheme = L"ustc-m6-probe-" + suffix;
    identity.protocol_arguments = suffix + L" " + argv[2] + L" protocol-receive";
  }
  const auto marker = std::filesystem::path(executable).parent_path() /
      (L"m6probe-" + suffix + (protocol ? L".protocol-activated" : L".activated"));
  if (protocol && action == L"parser") return ParserChecks(identity) ? 0 : 1;
  if (protocol && action == L"receive") {
    NativeReminder parsed;
    const bool accepted = argc == 5 &&
        ParseNativeNotificationActivation(argv[4], identity.protocol_scheme, &parsed) &&
        parsed.id == L"m6test01" && parsed.digest == std::wstring(64, L'a') &&
        parsed.activation == L"synthetic-token-0001";
    if (!accepted) return 1;
    std::ofstream file(marker);
    file << "{\"stage\":\"protocolReceive\",\"accepted\":true}\n";
    return file ? 0 : 1;
  }
  if (action == L"activate-shell") {
    FILE* output = nullptr;
    const auto result_path = std::filesystem::path(executable).parent_path() /
        (L"m6probe-" + suffix + L".cold-result.json");
    if (_wfreopen_s(&output, result_path.c_str(), L"w", stdout) != 0) return 1;
  }
  if (action == L"server") {
    std::ofstream file(std::filesystem::path(executable).parent_path() /
        (L"m6probe-" + suffix + L".server-started"));
    file << "synthetic server entered before COM initialization\n";
  }
  if (action == L"activate-com") {
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
  } else winrt::init_apartment((activating && action != L"activate-mta") ||
      (protocol && action == L"activate")
      ? winrt::apartment_type::single_threaded
      : winrt::apartment_type::multi_threaded);
  if (protocol && action == L"activate") {
    if (!ProbeProtocolRegistrationMatches(identity)) return 2;
    DeleteFileW(marker.c_str());
    const auto uri = ProbeUri(identity);
    SHELLEXECUTEINFOW invocation{};
    invocation.cbSize = sizeof(invocation);
    invocation.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    invocation.lpVerb = L"open";
    invocation.lpFile = uri.c_str();
    invocation.nShow = SW_HIDE;
    const bool launched = ShellExecuteExW(&invocation) != FALSE;
    const DWORD error = launched ? ERROR_SUCCESS : GetLastError();
    DWORD exit_code = 0;
    if (invocation.hProcess) {
      WaitForSingleObject(invocation.hProcess, 5000);
      GetExitCodeProcess(invocation.hProcess, &exit_code);
      CloseHandle(invocation.hProcess);
    }
    for (int tick = 0; launched && tick < 100 &&
         GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES; ++tick) Sleep(20);
    const bool received = GetFileAttributesW(marker.c_str()) != INVALID_FILE_ATTRIBUTES;
    printf("{\"stage\":\"protocolColdLaunch\",\"shellAccepted\":%s,\"error\":%lu,\"processExit\":%lu,\"received\":%s}\n",
        launched ? "true" : "false", error, exit_code, received ? "true" : "false");
    return launched && received && exit_code == 0 ? 0 : 1;
  }
  if (action == L"diagnose") {
    UINT32 package_length = 0;
    const LONG package_status = GetCurrentPackageFullName(&package_length, nullptr);
    UINT32 aumid_length = 0;
    const LONG aumid_status = GetCurrentApplicationUserModelId(&aumid_length, nullptr);
    printf("{\"stage\":\"processIdentity\",\"packageStatus\":%ld,\"packageLength\":%u,\"applicationIdStatus\":%ld,\"applicationIdLength\":%u}\n",
        package_status, package_length, aumid_status, aumid_length);
    wchar_t clsid[40]{};
    StringFromGUID2(guid, clsid, 40);
    const auto key_path = std::wstring(L"CLSID\\") + clsid + L"\\LocalServer32";
    for (const REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
      HKEY key = nullptr;
      const LONG status = RegOpenKeyExW(HKEY_CLASSES_ROOT, key_path.c_str(), 0,
                                       KEY_QUERY_VALUE | view, &key);
      DWORD type = 0;
      wchar_t command[32768]{};
      DWORD bytes = sizeof(command);
      const LONG read = key ? RegQueryValueExW(key, nullptr, nullptr, &type,
          reinterpret_cast<BYTE*>(command), &bytes) : status;
      if (key) RegCloseKey(key);
      printf("{\"stage\":\"classRegistration\",\"view\":%lu,\"open\":%ld,\"read\":%ld,\"type\":%lu,\"commandChars\":%zu,\"matchesExpected\":%s}\n",
          static_cast<unsigned long>(view), status, read, type,
          wcslen(command), command == (L"\"" + identity.executable + L"\" " + identity.server_arguments) ? "true" : "false");
    }
    HANDLE token = nullptr;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
      TOKEN_ELEVATION elevation{};
      TOKEN_ELEVATION_TYPE elevation_type{};
      DWORD bytes = 0;
      GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &bytes);
      GetTokenInformation(token, TokenElevationType, &elevation_type, sizeof(elevation_type), &bytes);
      DWORD ui_access = 0;
      GetTokenInformation(token, TokenUIAccess, &ui_access, sizeof(ui_access), &bytes);
      alignas(TOKEN_MANDATORY_LABEL) BYTE integrity_buffer[256]{};
      DWORD integrity = 0;
      if (GetTokenInformation(token, TokenIntegrityLevel, integrity_buffer,
                              sizeof(integrity_buffer), &bytes)) {
        const auto sid = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(integrity_buffer)->Label.Sid;
        integrity = *GetSidSubAuthority(sid, *GetSidSubAuthorityCount(sid) - 1);
      }
      printf("{\"stage\":\"elevation\",\"elevated\":%lu,\"type\":%u,\"uiAccess\":%lu}\n",
          elevation.TokenIsElevated, static_cast<unsigned>(elevation_type), ui_access);
      TOKEN_STATISTICS current_stats{};
      const bool current_stats_read = GetTokenInformation(token, TokenStatistics,
          &current_stats, sizeof(current_stats), &bytes) != FALSE;
      DWORD current_session = 0;
      ProcessIdToSessionId(GetCurrentProcessId(), &current_session);
      const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
      PROCESSENTRY32W entry{};
      entry.dwSize = sizeof(entry);
      if (snapshot != INVALID_HANDLE_VALUE && Process32FirstW(snapshot, &entry)) {
        do {
          DWORD session = 0;
          if (_wcsicmp(entry.szExeFile, L"explorer.exe") != 0 ||
              !ProcessIdToSessionId(entry.th32ProcessID, &session) ||
              session != current_session) continue;
          HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
          HANDLE shell_token = nullptr;
          TOKEN_STATISTICS shell_stats{};
          const bool read_shell = process && OpenProcessToken(process, TOKEN_QUERY, &shell_token) &&
              GetTokenInformation(shell_token, TokenStatistics, &shell_stats, sizeof(shell_stats), &bytes);
          const bool same_logon = current_stats_read && read_shell &&
              current_stats.AuthenticationId.HighPart == shell_stats.AuthenticationId.HighPart &&
              current_stats.AuthenticationId.LowPart == shell_stats.AuthenticationId.LowPart;
          printf("{\"stage\":\"desktopContext\",\"integrity\":%lu,\"shellTokenRead\":%s,\"sameLogon\":%s}\n",
              integrity, read_shell ? "true" : "false", same_logon ? "true" : "false");
          if (shell_token) CloseHandle(shell_token);
          if (process) CloseHandle(process);
        } while (Process32NextW(snapshot, &entry));
      }
      if (snapshot != INVALID_HANDLE_VALUE) CloseHandle(snapshot);
      HKEY user_classes = nullptr;
      HKEY server_key = nullptr;
      const LONG classes_status = RegOpenUserClassesRoot(token, 0, KEY_READ, &user_classes);
      const LONG server_status = user_classes ? RegOpenKeyExW(user_classes,
          key_path.c_str(), 0, KEY_READ, &server_key) : classes_status;
      printf("{\"stage\":\"tokenUserClasses\",\"classes\":%ld,\"server\":%ld}\n",
          classes_status, server_status);
      if (server_key) RegCloseKey(server_key);
      if (user_classes) RegCloseKey(user_classes);
      CloseHandle(token);
    }
    return 0;
  }
  if (activating) {
    DeleteFileW(marker.c_str());
    Microsoft::WRL::ComPtr<IClassFactory> factory;
    const DWORD context = CLSCTX_LOCAL_SERVER |
        (action == L"activate" ? CLSCTX_ACTIVATE_64_BIT_SERVER : 0);
    const HRESULT factory_hr = CoGetClassObject(guid, context,
                                               nullptr, IID_PPV_ARGS(&factory));
    Microsoft::WRL::ComPtr<IUnknown> object;
    HRESULT object_hr = factory_hr;
    if (SUCCEEDED(factory_hr)) object_hr = factory->CreateInstance(nullptr, IID_PPV_ARGS(&object));
    Microsoft::WRL::ComPtr<INotificationActivationCallback> callback;
    HRESULT activation_hr = object_hr;
    if (SUCCEEDED(object_hr)) activation_hr = object.As(&callback);
    if (SUCCEEDED(activation_hr)) {
      const auto payload = L"ustc-reminder/v1/m6test01/" + std::wstring(64, L'a') +
          L"/synthetic-token-0001";
      activation_hr = callback->Activate(identity.app_id.c_str(), payload.c_str(), nullptr, 0);
    }
    const bool received = GetFileAttributesW(marker.c_str()) != INVALID_FILE_ATTRIBUTES;
    printf("{\"stage\":\"coldComActivation\",\"factory\":\"%08lx\",\"object\":\"%08lx\",\"hresult\":\"%08lx\",\"received\":%s}\n",
        static_cast<unsigned long>(factory_hr), static_cast<unsigned long>(object_hr),
        static_cast<unsigned long>(activation_hr), received ? "true" : "false");
    return SUCCEEDED(activation_hr) && received ? 0 : 1;
  }
  WindowsNotificationPlatform platform(identity);
  std::atomic<bool> activated{false};
  HRESULT hr = platform.Register([&](std::wstring) {
    std::ofstream file(marker);
    file << "synthetic activation received\n";
    file.close();
    activated = true;
  });
  if (FAILED(hr)) {
    printf("{\"stage\":\"register\",\"hresult\":\"%08lx\"}\n", static_cast<unsigned long>(hr));
    return 1;
  }
  uint32_t count = 0;
  bool metadata = false;
  if (action == L"schedule" || action == L"replace") {
    if (argc < 5) return 2;
    const auto unix_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    NativeReminder r{L"m6test01", unix_ms + std::stoll(argv[4]) * 1000,
        std::wstring(64, action == L"schedule" ? L'a' : L'b'),
        L"synthetic-token-0001", L"M6 合成提醒验证", L"应用已退出后的系统计划", L"测试日程"};
    hr = platform.Schedule(r);
    std::vector<NativeReminder> pending;
    if (SUCCEEDED(hr)) hr = platform.Pending(&pending);
    count = static_cast<uint32_t>(pending.size());
    metadata = count == 1 && pending.front().id == r.id &&
        pending.front().delivery_unix_ms == r.delivery_unix_ms &&
        pending.front().digest == r.digest && pending.front().activation == r.activation &&
        pending.front().title == r.title && pending.front().detail == r.detail &&
        pending.front().location == r.location;
  } else if (action == L"pending") {
    std::vector<NativeReminder> pending;
    hr = platform.Pending(&pending);
    count = static_cast<uint32_t>(pending.size());
    metadata = count == 1 && pending.front().activation == L"synthetic-token-0001";
  } else if (action == L"cancel") {
    hr = platform.Cancel(L"m6test01");
    std::vector<NativeReminder> pending;
    if (SUCCEEDED(hr)) hr = platform.Pending(&pending);
    count = static_cast<uint32_t>(pending.size());
  } else if (action == L"history") {
    hr = platform.HistoryCount(&count);
  } else if (action == L"initialize") {
    hr = platform.EnsureScheduledIdentityReady();
    int32_t setting = -1;
    if (SUCCEEDED(hr)) hr = platform.Setting(&setting);
    count = static_cast<uint32_t>(setting);
    metadata = SUCCEEDED(hr) && setting == 0;
  } else if (action == L"setting") {
    int32_t setting = -1;
    hr = platform.Setting(&setting);
    count = static_cast<uint32_t>(setting);
  } else if (action == L"cleanup") {
    hr = platform.RemoveRegistration();
  } else if (protocol && action == L"cleanup-owner-conflict") {
    const auto path = L"Software\\Classes\\" + identity.protocol_scheme;
    wchar_t owner[512]{};
    DWORD bytes = sizeof(owner);
    const auto saved = RegGetValueW(HKEY_CURRENT_USER, path.c_str(), L"USTCNotificationOwner",
        RRF_RT_REG_SZ, nullptr, owner, &bytes);
    if (saved != ERROR_SUCCESS) return 1;
    constexpr wchar_t conflict[] = L"synthetic-conflicting-owner";
    const auto changed = RegSetKeyValueW(HKEY_CURRENT_USER, path.c_str(),
        L"USTCNotificationOwner", REG_SZ, conflict, sizeof(conflict));
    if (changed != ERROR_SUCCESS) return 1;
    const auto rejected = platform.RemoveRegistration();
    wchar_t after[512]{};
    DWORD after_bytes = sizeof(after);
    const auto read = RegGetValueW(HKEY_CURRENT_USER, path.c_str(), L"USTCNotificationOwner",
        RRF_RT_REG_SZ, nullptr, after, &after_bytes);
    metadata = rejected == E_ACCESSDENIED && read == ERROR_SUCCESS &&
        std::wstring(after) == conflict;
    const auto restored = RegSetKeyValueW(HKEY_CURRENT_USER, path.c_str(),
        L"USTCNotificationOwner", REG_SZ, owner, bytes);
    hr = HRESULT_FROM_WIN32(restored);
    if (SUCCEEDED(hr)) hr = platform.RemoveRegistration();
    if (SUCCEEDED(hr) && !metadata) hr = E_FAIL;
  } else if (action == L"server") {
    for (int ticks = 0; ticks < 200 && !activated; ++ticks) Sleep(100);
    printf("{\"stage\":\"activation\",\"activated\":%s}\n", activated ? "true" : "false");
    return activated ? 0 : 1;
  } else return 2;
  printf("{\"stage\":\"%ls\",\"hresult\":\"%08lx\",\"count\":%u,\"metadata\":%s}\n",
      requested_action.c_str(), static_cast<unsigned long>(hr), count, metadata ? "true" : "false");
  const bool assertions = (action != L"schedule" && action != L"replace" || metadata) &&
      (action != L"cancel" || count == 0);
  return SUCCEEDED(hr) && assertions ? 0 : 1;
}
