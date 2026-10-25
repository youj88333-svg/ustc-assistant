#include "notification_activation.h"

#include <cstdio>
#include <string>
#include <vector>

// Synthetic, process-local contract checks only. This executable never calls
// Register/Schedule/Cancel, ShellExecute, or any notification history API.
namespace {
constexpr ULONG_PTR kCopyDataKind = 0x4D364E31;

struct Checks {
  int total = 0;
  int failed = 0;
  void Expect(bool condition, const char* name) {
    ++total;
    if (!condition) {
      ++failed;
      // Names are fixed test labels; never print activation payloads.
      std::printf("{\"failedCheck\":\"%s\"}\n", name);
    }
  }
};

std::wstring Uri(const std::wstring& id = L"fixture01",
                 const std::wstring& digest = std::wstring(64, L'a'),
                 const std::wstring& token = L"synthetic-token-0001") {
  return std::wstring(kNotificationScheme) + L"://reminder/v1/" + id + L"/" +
      digest + L"/" + token;
}

struct RegistrySnapshot {
  LSTATUS status = ERROR_INVALID_DATA;
  FILETIME last_write{};
};

RegistrySnapshot ReadRegistration(const std::wstring& path) {
  RegistrySnapshot result;
  HKEY key = nullptr;
  result.status = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0,
                               KEY_QUERY_VALUE, &key);
  if (result.status == ERROR_SUCCESS) {
    result.status = RegQueryInfoKeyW(key, nullptr, nullptr, nullptr, nullptr,
        nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, &result.last_write);
    RegCloseKey(key);
  }
  return result;
}

bool SameRegistration(const RegistrySnapshot& a, const RegistrySnapshot& b) {
  const bool readable = a.status == ERROR_SUCCESS || a.status == ERROR_FILE_NOT_FOUND;
  return readable && a.status == b.status &&
      a.last_write.dwLowDateTime == b.last_write.dwLowDateTime &&
      a.last_write.dwHighDateTime == b.last_write.dwHighDateTime;
}

void ParserChecks(Checks& check) {
  NativeReminder parsed;
  check.Expect(ParseNativeNotificationActivation(Uri(), kNotificationScheme, &parsed) &&
      parsed.id == L"fixture01" && parsed.digest == std::wstring(64, L'a') &&
      parsed.activation == L"synthetic-token-0001", "parser_valid_identity");
  check.Expect(ParseNativeNotificationActivation(Uri(L"x", std::wstring(64, L'b'),
      std::wstring(16, L'c')), kNotificationScheme, &parsed), "parser_minimum_fields");
  check.Expect(ParseNativeNotificationActivation(Uri(std::wstring(16, L'x'),
      std::wstring(64, L'b'), std::wstring(64, L'c')), kNotificationScheme, &parsed),
      "parser_maximum_fields");
  const auto valid = Uri();
  std::wstring embedded_nul = valid;
  embedded_nul.insert(embedded_nul.size() / 2, 1, L'\0');
  const std::vector<std::wstring> invalid = {
      L"", valid + L"?query=x", valid + L"#fragment", valid + L"/extra",
      valid + L" --argument", valid + L"\"", L" " + valid, valid + L"\n",
      valid + L"\r", valid + L"\t", embedded_nul,
      Uri(L""), Uri(std::wstring(17, L'x')), Uri(L".."), Uri(L"%2e%2e"),
      Uri(L"x\\y"), Uri(L"x:y"), Uri(L"x y"), Uri(L"测试"),
      Uri(L"x", std::wstring(63, L'a')), Uri(L"x", std::wstring(65, L'a')),
      Uri(L"x", std::wstring(64, L'a'), std::wstring(15, L'b')),
      Uri(L"x", std::wstring(64, L'a'), std::wstring(65, L'b')),
      L"ustc-other://reminder/v1/fixture01/" + std::wstring(64, L'a') +
          L"/synthetic-token-0001",
      std::wstring(kNotificationScheme) + L"://reminder/v2/fixture01/" +
          std::wstring(64, L'a') + L"/synthetic-token-0001",
      std::wstring(kNotificationScheme) + L"://other/v1/fixture01/" +
          std::wstring(64, L'a') + L"/synthetic-token-0001",
      std::wstring(257, L'a'), valid + std::wstring(1, L'\0')};
  for (const auto& value : invalid) {
    parsed.id = L"unchanged";
    parsed.digest = L"unchanged";
    parsed.activation = L"unchanged";
    check.Expect(!ParseNativeNotificationActivation(value, kNotificationScheme, &parsed) &&
        parsed.id == L"unchanged" && parsed.digest == L"unchanged" &&
        parsed.activation == L"unchanged", "parser_rejects_without_partial_output");
  }
  check.Expect(!ParseNativeNotificationActivation(valid, kNotificationScheme, nullptr),
               "parser_null_output");
  check.Expect(!ParseNativeNotificationActivation(valid, L"USTC-assistant-rewrite", &parsed),
               "parser_wrong_scheme");
}

void HubChecks(Checks& check) {
  NotificationActivationHub hub;
  check.Expect(hub.Drain().empty(), "hub_initially_empty");
  check.Expect(!hub.Enqueue(Uri() + L"?bad=1") && hub.Drain().empty(),
               "hub_invalid_not_queued");
  for (int i = 0; i < 32; ++i)
    check.Expect(hub.Enqueue(Uri(L"fixture" + std::to_wstring(i))), "hub_accepts_within_bound");
  check.Expect(hub.Enqueue(Uri(L"fixture0")), "hub_duplicate_acknowledged_at_capacity");
  check.Expect(!hub.Enqueue(Uri(L"overflow")), "hub_rejects_over_capacity");
  auto entries = hub.Drain();
  check.Expect(entries.size() == 32, "hub_exact_capacity");
  if (entries.size() == 32) {
    for (int i = 0; i < 32; ++i)
      check.Expect(entries[i].id == L"fixture" + std::to_wstring(i), "hub_preserves_order");
  }
  check.Expect(hub.Drain().empty(), "hub_drain_consumes");
  check.Expect(hub.Enqueue(Uri(L"fixture0")), "hub_accepts_after_drain");
  check.Expect(hub.Enqueue(Uri(L"fixture0", std::wstring(64, L'b'))),
               "hub_changed_digest_is_distinct");
  check.Expect(hub.Enqueue(Uri(L"fixture0", std::wstring(64, L'a'),
      L"synthetic-token-0002")), "hub_changed_token_is_distinct");
  check.Expect(hub.Drain().size() == 3, "hub_dedup_uses_complete_identity");
  check.Expect(hub.Enqueue(Uri()), "hub_accepts_before_close");
  hub.Close();
  check.Expect(hub.Drain().empty() && !hub.Enqueue(Uri()), "hub_close_clears_and_rejects");
  hub.Close();
  check.Expect(hub.Drain().empty(), "hub_close_idempotent");
}

COPYDATASTRUCT CopyData(std::wstring& value) {
  COPYDATASTRUCT data{};
  data.dwData = kCopyDataKind;
  data.cbData = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  data.lpData = value.data();
  return data;
}

void CopyDataChecks(Checks& check, NotificationInstance& instance) {
  NotificationActivationHub hub;
  auto valid = Uri();
  auto data = CopyData(valid);
  check.Expect(instance.Receive(nullptr, hub) == FALSE, "copydata_null_struct");
  auto bad = data;
  bad.dwData = 0;
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_wrong_kind");
  bad = data;
  bad.lpData = nullptr;
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_null_data");
  for (const DWORD bytes : {DWORD{0}, DWORD{1}, DWORD{2}, DWORD{3}, DWORD{515}, DWORD{516}}) {
    bad = data;
    bad.cbData = bytes;
    check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_invalid_byte_count");
  }
  bad = data;
  --bad.cbData;
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_odd_byte_count");
  bad = data;
  bad.cbData -= sizeof(wchar_t);
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_missing_terminator");
  auto embedded = valid;
  embedded[embedded.size() / 2] = L'\0';
  bad = CopyData(embedded);
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_embedded_nul");
  auto extra = valid + std::wstring(1, L'\0');
  bad = CopyData(extra);
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_extra_nul");
  auto invalid_uri = valid + L"?outside=1";
  bad = CopyData(invalid_uri);
  check.Expect(instance.Receive(&bad, hub) == FALSE, "copydata_revalidates_uri");
  check.Expect(hub.Drain().empty(), "copydata_rejections_have_no_delivery");
  check.Expect(instance.Receive(&data, hub) == TRUE, "copydata_valid_delivery");
  check.Expect(instance.Receive(&data, hub) == TRUE, "copydata_duplicate_ack");
  const auto delivered = hub.Drain();
  check.Expect(delivered.size() == 1 && delivered.front().id == L"fixture01",
               "copydata_delivered_once");
  for (int i = 0; i < 32; ++i) hub.Enqueue(Uri(L"bound" + std::to_wstring(i)));
  check.Expect(instance.Receive(&data, hub) == FALSE, "copydata_full_queue_rejected");
  hub.Close();
  check.Expect(instance.Receive(&data, hub) == FALSE, "copydata_closed_queue_rejected");
}

void InstanceChecks(Checks& check) {
  const auto module = GetModuleHandleW(nullptr);
  const auto class_name = L"USTC.M6.ActivationProbe." + std::to_wstring(GetCurrentProcessId());
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = DefWindowProcW;
  window_class.hInstance = module;
  window_class.lpszClassName = class_name.c_str();
  const ATOM registered = RegisterClassW(&window_class);
  check.Expect(registered != 0, "instance_test_window_class");
  if (!registered) return;
  // HWND_MESSAGE never creates a visible desktop window and is not a
  // cross-process handoff test. The production namespace is never acquired.
  const HWND window = CreateWindowExW(0, class_name.c_str(), L"", 0, 0, 0, 0, 0,
                                      HWND_MESSAGE, nullptr, module, nullptr);
  check.Expect(window != nullptr, "instance_message_only_window");
  if (window) {
    {
      NotificationInstance instance(true);
      check.Expect(!instance.AttachWindow(window), "instance_rejects_without_ownership");
      check.Expect(instance.AcquireOrForward(Uri() + L"#bad") ==
          NotificationInstanceResult::blocked, "instance_rejects_invalid_uri");
      check.Expect(instance.AcquireOrForward(L"") == NotificationInstanceResult::primary,
                   "instance_synthetic_mutex_acquired");
      check.Expect(instance.AcquireOrForward(L"") == NotificationInstanceResult::blocked,
                   "instance_rejects_repeated_acquire");
      check.Expect(!instance.AttachWindow(nullptr), "instance_rejects_null_window");
      check.Expect(instance.AttachWindow(window), "instance_attaches_own_window");
      check.Expect(!instance.AttachWindow(window), "instance_rejects_second_attach");
      const auto property = L"USTC.Assistant.DesignReset.Notification.7A716A0C.TestHost." +
          std::to_wstring(GetCurrentProcessId());
      check.Expect(GetPropW(window, property.c_str()) == reinterpret_cast<HANDLE>(1),
                   "instance_has_test_only_property");
      check.Expect(GetPropW(window,
          L"USTC.Assistant.DesignReset.Notification.7A716A0C") == nullptr,
          "instance_has_no_production_window_property");
      CopyDataChecks(check, instance);
      instance.DetachWindow();
      check.Expect(GetPropW(window, property.c_str()) == nullptr,
                   "instance_detach_removes_property");
    }
    {
      NotificationInstance replacement(true);
      check.Expect(replacement.AcquireOrForward(L"") == NotificationInstanceResult::primary,
                   "instance_destructor_releases_test_mutex");
    }
    DestroyWindow(window);
  }
  UnregisterClassW(class_name.c_str(), module);
}
}  // namespace

int wmain() {
  Checks check;
  try {
    // Read only existence/timestamps of our exact production keys. Identity
    // construction must not register anything, even when these already exist.
    const std::vector<std::wstring> paths = {
        L"Software\\Classes\\AppUserModelId\\USTC.Assistant.DesignReset",
        L"Software\\Classes\\ustc-assistant-rewrite",
        L"Software\\Classes\\CLSID\\{7A716A0C-604E-4DD8-A01E-5B6993517141}"};
    std::vector<RegistrySnapshot> before;
    for (const auto& path : paths) before.push_back(ReadRegistration(path));
    const auto identity = ProductionNotificationIdentity();
    constexpr GUID expected_activator = {0x7a716a0c, 0x604e, 0x4dd8,
        {0xa0, 0x1e, 0x5b, 0x69, 0x93, 0x51, 0x71, 0x41}};
    check.Expect(identity.app_id == L"USTC.Assistant.DesignReset" &&
        identity.protocol_scheme == kNotificationScheme &&
        identity.protocol_arguments == L"--ustc-notification" &&
        identity.shortcut_name == L"USTC Assistant (Rewrite)" &&
        IsEqualGUID(identity.activator, expected_activator),
        "production_identity_fixed");
    ParserChecks(check);
    HubChecks(check);
    InstanceChecks(check);
    // Read again only after process-local API exercises; no Registry writes.
    for (size_t i = 0; i < paths.size(); ++i)
      check.Expect(SameRegistration(before[i], ReadRegistration(paths[i])),
                   "production_registration_unchanged");
  } catch (...) {
    check.Expect(false, "unexpected_exception");
  }
  std::printf("{\"stage\":\"activationContract\",\"checks\":%d,\"passed\":%s,"
              "\"syntheticProcessOnly\":true,\"multiProcessHandoffVerified\":false}\n",
              check.total, check.failed == 0 ? "true" : "false");
  return check.failed == 0 ? 0 : 1;
}
