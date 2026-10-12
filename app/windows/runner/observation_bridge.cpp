#include "observation_bridge.h"
#include "jw_login_script.h"
#include "jw_probe_script.h"
#include "young_read_only_observer.h"
#include "young_business_reader.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <WebView2.h>
#include <urlmon.h>
#include <shlwapi.h>
#include <wrl.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <random>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace {
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using Channel = flutter::MethodChannel<Value>;

Map YoungProfileMap(const young_probe::ObservedProfile& profile) {
  return Map{{Value("observations"), Value(profile.observations)},
    {Value("success"), Value(young_probe::SuccessKindLabel(profile.success))},
    {Value("code"), Value(young_probe::ValueKindLabel(profile.code))},
    {Value("result"), Value(young_probe::ValueKindLabel(profile.result))},
    {Value("loginCode"), Value(young_probe::ValueKindLabel(profile.loginCode))},
    {Value("username"), Value(young_probe::ValueKindLabel(profile.username))}};
}
Map YoungListMap(const young_probe::ObservedList& list) {
  return Map{{Value("observations"), Value(list.observations)},
    {Value("success"), Value(young_probe::SuccessKindLabel(list.success))},
    {Value("code"), Value(young_probe::ValueKindLabel(list.code))},
    {Value("result"), Value(young_probe::ValueKindLabel(list.result))},
    {Value("records"), Value(young_probe::ValueKindLabel(list.records))},
    {Value("count"), Value(static_cast<int64_t>(list.count))},
    {Value("total"), Value(young_probe::ValueKindLabel(list.total))},
    {Value("id"), Value(young_probe::ValueKindLabel(list.id))},
    {Value("title"), Value(young_probe::ValueKindLabel(list.title))},
    {Value("date"), Value(young_probe::ValueKindLabel(list.date))},
    {Value("startTime"), Value(young_probe::ValueKindLabel(list.startTime))},
    {Value("endTime"), Value(young_probe::ValueKindLabel(list.endTime))}};
}

constexpr wchar_t kWindowClass[] = L"UstcObservationV1";
constexpr wchar_t kWindowCaption[] = L"USTC Assistant - Observation";
constexpr wchar_t kBlockedCaption[] =
    L"\u9875\u9762\u64cd\u4f5c\u88ab\u963b\u6b62\uff0c"
    L"\u8bf7\u67e5\u770b\u4e3b\u7a97\u53e3\u539f\u56e0";
constexpr wchar_t kReadyScript[] =
    L"[document.readyState === 'complete', location.origin]";
// Only closed classifications and counts. No values, text, request or assets.
std::wstring YoungStructureScript(const std::wstring& origin);
// 256 labels of at most 120 UTF-16 units can expand during JSON escaping.
// Bound the fixed projection and the surrounding CDP string independently.
constexpr size_t kProbeProjectionChars = 256 * 1024;
constexpr size_t kProbeCdpChars = 1024 * 1024;
constexpr size_t kCollectionProjectionChars = 8 * 1024 * 1024;
constexpr size_t kCollectionCdpChars = 64 * 1024 * 1024;
constexpr size_t kLoginCdpChars = 64 * 1024;
constexpr size_t kLoginCredentialBytes = 16 * 1024;
constexpr UINT_PTR kLoginContextTimer = 0x4a574c31;

std::wstring NewProbeCapability() {
  // Kept only by the native session and its native-created isolated world.
  // Never sent to Dart/events, persisted, or exposed by a callable's source.
  std::random_device random;
  constexpr wchar_t digits[] = L"0123456789abcdef";
  std::wstring value;
  for (int i = 0; i < 8; ++i) {
    const uint32_t word = random();
    for (int shift = 28; shift >= 0; shift -= 4)
      value += digits[(word >> shift) & 0xf];
  }
  return value;
}

std::wstring ScriptString(const std::wstring& value) {
  constexpr wchar_t digits[] = L"0123456789abcdef";
  std::wstring result = L"\"";
  for (const wchar_t character : value) {
    if (character == L'\"' || character == L'\\') {
      result += L'\\';
      result += character;
    } else if (character < L' ' || character == 0x2028 || character == 0x2029) {
      result += L"\\u";
      for (int shift = 12; shift >= 0; shift -= 4)
        result += digits[(static_cast<uint16_t>(character) >> shift) & 0xf];
    } else result += character;
  }
  return result + L"\"";
}

std::wstring YoungStructureScript(const std::wstring& origin) {
  return L"(() => { const expected = " + ScriptString(origin) + LR"JS(;
    if (location.origin !== expected) return null;
    const count = selector => document.querySelectorAll(selector).length;
    const passwordInputs = count('input[type="password"]');
    const path = location.pathname;
    const hash = location.hash;
    let surface = 'unknown';
    if (path === '/nginx_auth' || path.startsWith('/nginx_auth/')) surface = 'accessGate';
    else if (passwordInputs > 0 || /^#\/(user\/)?login(?:[/?]|$)/.test(hash)) surface = 'authentication';
    else if (path === '/' || path === '/main.htm') surface = 'portal';
    else if (path === '/login' || path.startsWith('/login/')) surface = 'application';
    return {
      ready: document.readyState === 'complete', surface,
      tables: count('table,[role="table"]'),
      calendarRoots: count('.el-calendar,.ant-fullcalendar,.fc,[role="grid"]'),
      paginationControls: count('.el-pagination,.ant-pagination,[aria-label="pagination"]'),
      passwordInputs
    };
  })())JS";
}

// A bounded JSON cursor for private CDP metadata. It validates/ignores other
// fields instead of propagating frame URLs or exception payloads to Dart.
class ProbeJson {
 public:
  explicit ProbeJson(const std::wstring& input, size_t maximum = kProbeCdpChars)
      : input_(input), maximum_(maximum) {}

  std::optional<std::wstring> Field(const std::wstring& wanted) {
    if (input_.size() > maximum_) return {};
    Space();
    if (!Take(L'{')) return {};
    std::optional<std::wstring> found;
    Space();
    if (!Take(L'}')) {
      for (;;) {
        auto key = String();
        Space();
        if (!key || !Take(L':')) return {};
        Space();
        const size_t first = index_;
        if (!Skip(0)) return {};
        if (*key == wanted) {
          if (found) return {};
          found = input_.substr(first, index_ - first);
        }
        Space();
        if (Take(L'}')) break;
        if (!Take(L',')) return {};
      }
    }
    Space();
    return index_ == input_.size() ? std::move(found) : std::nullopt;
  }

  std::optional<std::wstring> Text() {
    if (input_.size() > maximum_) return {};
    Space();
    auto value = String();
    Space();
    return index_ == input_.size() ? std::move(value) : std::nullopt;
  }

  bool ExactFields(const std::set<std::wstring>& expected) {
    if (input_.size() > maximum_) return false;
    Space();
    if (!Take(L'{')) return false;
    std::set<std::wstring> actual;
    Space();
    if (!Take(L'}')) {
      for (;;) {
        auto key = String();
        Space();
        if (!key || expected.find(*key) == expected.end() ||
            !actual.insert(*key).second || !Take(L':') || !Skip(0)) return false;
        Space();
        if (Take(L'}')) break;
        if (!Take(L',')) return false;
      }
    }
    Space();
    return index_ == input_.size() && actual == expected;
  }

 private:
  void Space() {
    while (index_ < input_.size() && (input_[index_] == L' ' || input_[index_] == L'\t' ||
        input_[index_] == L'\r' || input_[index_] == L'\n')) ++index_;
  }
  bool Take(wchar_t value) {
    if (index_ == input_.size() || input_[index_] != value) return false;
    ++index_;
    return true;
  }
  std::optional<std::wstring> String() {
    Space();
    if (!Take(L'"')) return {};
    std::wstring value;
    while (index_ < input_.size()) {
      wchar_t character = input_[index_++];
      if (character == L'"') return value;
      if (character < L' ') return {};
      if (character == L'\\') {
        if (index_ == input_.size()) return {};
        character = input_[index_++];
        if (character == L'u') {
          unsigned int decoded = 0;
          for (int i = 0; i < 4; ++i) {
            if (index_ == input_.size()) return {};
            const wchar_t digit = input_[index_++];
            if (digit >= L'0' && digit <= L'9') decoded = decoded * 16 + digit - L'0';
            else if (digit >= L'a' && digit <= L'f') decoded = decoded * 16 + digit - L'a' + 10;
            else if (digit >= L'A' && digit <= L'F') decoded = decoded * 16 + digit - L'A' + 10;
            else return {};
          }
          character = static_cast<wchar_t>(decoded);
        } else if (character == L'b') character = L'\b';
        else if (character == L'f') character = L'\f';
        else if (character == L'n') character = L'\n';
        else if (character == L'r') character = L'\r';
        else if (character == L't') character = L'\t';
        else if (character != L'"' && character != L'\\' && character != L'/') return {};
      }
      value += character;
    }
    return {};
  }
  bool Skip(unsigned int depth) {
    if (depth > 64) return false;
    Space();
    if (index_ == input_.size()) return false;
    if (input_[index_] == L'"') return String().has_value();
    if (Take(L'{')) {
      Space();
      if (Take(L'}')) return true;
      for (;;) {
        if (!String()) return false;
        Space();
        if (!Take(L':') || !Skip(depth + 1)) return false;
        Space();
        if (Take(L'}')) return true;
        if (!Take(L',')) return false;
      }
    }
    if (Take(L'[')) {
      Space();
      if (Take(L']')) return true;
      for (;;) {
        if (!Skip(depth + 1)) return false;
        Space();
        if (Take(L']')) return true;
        if (!Take(L',')) return false;
      }
    }
    for (const auto* literal : {L"true", L"false", L"null"}) {
      const std::wstring word(literal);
      if (input_.compare(index_, word.size(), word) == 0) { index_ += word.size(); return true; }
    }
    Take(L'-');
    if (index_ == input_.size()) return false;
    if (!Take(L'0')) {
      if (input_[index_] < L'1' || input_[index_] > L'9') return false;
      do { ++index_; } while (index_ < input_.size() && input_[index_] >= L'0' && input_[index_] <= L'9');
    }
    if (Take(L'.')) {
      const size_t start = index_;
      while (index_ < input_.size() && input_[index_] >= L'0' && input_[index_] <= L'9') ++index_;
      if (start == index_) return false;
    }
    if (Take(L'e') || Take(L'E')) {
      if (!Take(L'+')) Take(L'-');
      const size_t start = index_;
      while (index_ < input_.size() && input_[index_] >= L'0' && input_[index_] <= L'9') ++index_;
      if (start == index_) return false;
    }
    return true;
  }
  const std::wstring& input_;
  size_t maximum_;
  size_t index_ = 0;
};

std::optional<int32_t> ProbeContextId(const std::wstring& input) {
  if (input.empty() || input.size() > 10) return {};
  int64_t value = 0;
  for (const wchar_t digit : input) {
    if (digit < L'0' || digit > L'9') return {};
    value = value * 10 + digit - L'0';
  }
  if (value <= 0 || value > 2147483647) return {};
  return static_cast<int32_t>(value);
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                     value.data(), static_cast<int>(value.size()),
                                     nullptr, 0);
  if (size <= 0) return {};
  std::wstring converted(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), converted.data(), size);
  return converted;
}

std::string Narrow(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                      value.data(), static_cast<int>(value.size()),
                                      nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string converted(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), converted.data(), size,
                      nullptr, nullptr);
  return converted;
}

void Wipe(std::wstring& value) {
  if (!value.empty()) SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
  value.clear();
}

bool ValidSecretText(const std::wstring& value, size_t maximum) {
  if (value.empty() || value.size() > maximum || value.find(L'\0') != std::wstring::npos)
    return false;
  for (size_t index = 0; index < value.size(); ++index) {
    const uint16_t unit = static_cast<uint16_t>(value[index]);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index == value.size()) return false;
      const uint16_t low = static_cast<uint16_t>(value[index]);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}

struct LoginSecrets {
  std::wstring encoded;
  std::wstring username;
  std::wstring password;
  ~LoginSecrets() { Wipe(encoded); Wipe(username); Wipe(password); }

  bool Decode(const std::vector<uint8_t>& bytes) {
    if (bytes.empty() || bytes.size() > kLoginCredentialBytes) return false;
    const int units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        reinterpret_cast<const char*>(bytes.data()), static_cast<int>(bytes.size()), nullptr, 0);
    if (units <= 0) return false;
    encoded.resize(units);
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        reinterpret_cast<const char*>(bytes.data()), static_cast<int>(bytes.size()),
        encoded.data(), units) != units ||
        !ProbeJson(encoded, kLoginCredentialBytes).ExactFields({L"username", L"password"}))
      return false;
    auto username_json = ProbeJson(encoded, kLoginCredentialBytes).Field(L"username");
    auto password_json = ProbeJson(encoded, kLoginCredentialBytes).Field(L"password");
    auto name = username_json ? ProbeJson(*username_json).Text() : std::nullopt;
    auto pass = password_json ? ProbeJson(*password_json).Text() : std::nullopt;
    if (name) username = std::move(*name);
    if (pass) password = std::move(*pass);
    if (username_json) Wipe(*username_json);
    if (password_json) Wipe(*password_json);
    Wipe(encoded);
    return ValidSecretText(username, 256) && ValidSecretText(password, 1024);
  }
};

void AppendSecretString(std::wstring& destination, const std::wstring& value) {
  constexpr wchar_t digits[] = L"0123456789abcdef";
  destination += L'"';
  for (const wchar_t character : value) {
    if (character == L'"' || character == L'\\') {
      destination += L'\\';
      destination += character;
    } else if (character < L' ' || character == 0x2028 || character == 0x2029) {
      destination += L"\\u";
      for (int shift = 12; shift >= 0; shift -= 4)
        destination += digits[(static_cast<uint16_t>(character) >> shift) & 0xf];
    } else destination += character;
  }
  destination += L'"';
}

// Use Windows' URI parser, including effective ports, rather than suffix or
// prefix matching. Return only a canonical origin and reject user information.
std::optional<std::wstring> Origin(const std::wstring& input) {
  if (input.empty() || std::any_of(input.begin(), input.end(),
        [](wchar_t c) { return c <= L' ' || c == 0x7f || c == L'\\'; })) return {};
  const auto separator = input.find(L"://");
  if (separator == std::wstring::npos) return {};
  const auto authority_end = input.find_first_of(L"/?#", separator + 3);
  const auto authority = input.substr(separator + 3, authority_end - (separator + 3));
  if (authority.empty() || authority.find(L'@') != std::wstring::npos) return {};
  const auto colon = authority.find(L':');
  if (colon != std::wstring::npos) {
    const auto port_text = authority.substr(colon + 1);
    if (port_text.empty() || port_text.size() > 5 ||
        !std::all_of(port_text.begin(), port_text.end(),
                    [](wchar_t c) { return c >= L'0' && c <= L'9'; })) return {};
  }
  ComPtr<IUri> uri;
  if (FAILED(CreateUri(input.c_str(), Uri_CREATE_CANONICALIZE, 0, &uri)))
    return {};
  BSTR scheme = nullptr;
  BSTR host = nullptr;
  BSTR user = nullptr;
  DWORD port = 0;
  const HRESULT scheme_result = uri->GetSchemeName(&scheme);
  const HRESULT host_result = uri->GetHost(&host);
  const HRESULT user_result = uri->GetUserInfo(&user);
  const HRESULT port_result = uri->GetPort(&port);
  std::wstring scheme_text = scheme ? scheme : L"";
  std::wstring host_text = host ? host : L"";
  const bool has_user = user && SysStringLen(user) > 0;
  SysFreeString(scheme);
  SysFreeString(host);
  SysFreeString(user);
  if (FAILED(scheme_result) || FAILED(host_result) || FAILED(user_result) ||
      FAILED(port_result) || has_user || host_text.empty() || port == 0 ||
      port > 65535 || (scheme_text != L"https" && scheme_text != L"http"))
    return {};
  std::wstring origin = scheme_text + L"://" + host_text;
  if (!((scheme_text == L"https" && port == 443) ||
        (scheme_text == L"http" && port == 80)))
    origin += L":" + std::to_wstring(port);
  return origin;
}

std::optional<std::wstring> LoginPath(const std::wstring& uri_text) {
  if (!Origin(uri_text)) return {};
  ComPtr<IUri> uri;
  BSTR path = nullptr;
  if (FAILED(CreateUri(uri_text.c_str(), Uri_CREATE_CANONICALIZE, 0, &uri)) ||
      FAILED(uri->GetPath(&path))) return {};
  const std::wstring value = path ? path : L"";
  SysFreeString(path);
  return value;
}

bool LoginBusinessPath(const std::wstring& path) {
  if (path == L"/home") return true;
  for (const auto* prefix : {L"/for-std/course-table/info/", L"/for-std/exam-arrange/info/"}) {
    const std::wstring root(prefix);
    if (path.compare(0, root.size(), root) != 0) continue;
    auto suffix = path.substr(root.size());
    if (!suffix.empty() && suffix.back() == L'/') suffix.pop_back();
    return !suffix.empty() && suffix.size() <= 12 &&
        std::all_of(suffix.begin(), suffix.end(), [](wchar_t unit) {
          return unit >= L'0' && unit <= L'9';
        });
  }
  return false;
}

const Value* Field(const Map* map, const char* key) {
  if (!map) return nullptr;
  auto it = map->find(Value(key));
  return it == map->end() ? nullptr : &it->second;
}

std::optional<int64_t> Integer(const Value* value) {
  if (!value) return {};
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return *number;
  return {};
}

const std::string* Text(const Value* value) {
  return value ? std::get_if<std::string>(value) : nullptr;
}

void Error(const std::shared_ptr<Result>& result, const char* reason) {
  if (result) result->Error("app_failure", "app_failure", Value(reason));
}

void YoungError(const std::shared_ptr<Result>& result, const char* code, const char* reason) {
  if (result) result->Error("app_failure", "app_failure",
      Value(Map{{Value("code"), Value(code)}, {Value("reason"), Value(reason)}}));
}

struct Delivery {
  std::unique_ptr<Channel> channel;
  bool alive = true;
};

struct FrameBinding {
  UINT64 epoch = 0;
  bool destroyed = false;
  std::shared_ptr<FrameBinding> parent;
};

struct LoginRequest {
  std::shared_ptr<Result> result;
  int64_t document = 0;
  int64_t operation = 0;
  uint64_t serial = 0;
  std::wstring source;
  bool completed = false;
};

struct LoginRuntimeReceiver {
  ComPtr<ICoreWebView2DevToolsProtocolEventReceiver> receiver;
  EventRegistrationToken token{};
  bool subscribed = false;
};

#ifdef _DEBUG
std::wstring NormalizePem(const std::wstring& pem) {
  std::wstring normalized;
  for (size_t i = 0; i < pem.size(); ++i) {
    if (pem[i] == L'\r') {
      normalized += L'\n';
      if (i + 1 < pem.size() && pem[i + 1] == L'\n') ++i;
    } else normalized += pem[i];
  }
  return normalized;
}

bool CertificateFailure(COREWEBVIEW2_WEB_ERROR_STATUS status) {
  return status == COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT ||
      status == COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED ||
      status == COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS ||
      status == COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED ||
      status == COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID;
}
#endif

struct State : std::enable_shared_from_this<State> {
  explicit State(std::weak_ptr<Delivery> destination)
      : delivery(std::move(destination)) {}
  ~State() {
    for (const auto& process : processes) {
      if (process.second) CloseHandle(process.second);
    }
  }

  std::weak_ptr<Delivery> delivery;
  int64_t session = 0;
  int64_t document = 0;
  UINT64 navigation = 0;
  UINT64 visible_navigation = 0;
  UINT64 visible_epoch = 0;
  bool visible_completed = false;
  bool visible_dom_loaded = false;
  bool pending_navigation = false;
  std::set<UINT64> suppressed_navigations;
  std::set<UINT64> rejected_top_navigations;
  bool closing = false;
  bool failed = false;
  bool configured = false;
  bool document_filter_installed = false;
  bool test_mode = false;
  bool young_source = false;
  bool recovery_only = false;
  bool completed = false;
  bool dom_loaded = false;
  bool ready = false;
  bool user_closed = false;
  bool tracking_failed = false;
  bool exit_event_failed = false;
  bool browser_exit_subscribed = false;
  bool process_infos_subscribed = false;
  EventRegistrationToken browser_exit_token{};
  EventRegistrationToken process_infos_token{};
  int pending_open = 0;
  int pending_scripts = 0;
  int pending_operations = 0;
  int64_t young_read_document = -1;
  int64_t young_read_operation = 0;
  std::shared_ptr<young_probe::ReadOnlyObserver> young_observer;
  int64_t young_business_document = -1;
  int64_t young_business_operation = 0;
  std::shared_ptr<young_probe::BusinessReader> young_reader;
  uint64_t login_serial = 0;
  int64_t login_operation = 0;
  int64_t login_prepared_document = -1;
  int64_t login_prepared_operation = 0;
  int64_t login_consumed_document = -1;
  int64_t login_portal_document = -1;
  int64_t login_world_attempt_document = -1;
  unsigned int login_world_attempts = 0;
  bool login_runtime_enabled = false;
  bool login_runtime_failed = false;
  bool login_world_invalidated = false;
  int32_t login_created_context = 0;
  int32_t login_expected_context = 0;
  std::wstring login_unique_context;
  std::wstring login_world_name;
  std::wstring login_frame_id;
  std::wstring login_object_id;
  std::wstring login_prepared_source;
  std::shared_ptr<LoginRequest> login_request;
  std::shared_ptr<LoginRequest> login_context_wait;
  std::vector<LoginRuntimeReceiver> login_runtime_receivers;
  bool probe_installed = false;
  int32_t probe_context_id = 0;
  int64_t probe_world_document = 0;
  bool probe_invalidated = false;
  int64_t probe_operation = 0;
  int64_t probe_document = 0;
  uint64_t probe_serial = 0;
  std::wstring probe_origin;
  std::wstring probe_capability;
  std::wstring probe_reply_capability;
  bool probe_data = false;
  bool probe_collect = false;
  int64_t probe_semester = 0;
  std::wstring launcher_url;
  UINT64 launcher_navigation = 0;
  bool launcher_redirected = false;
  std::wstring self_route_id;
  std::wstring self_route_uri;
  int64_t self_route_document = 0;
  HWND window = nullptr;
  std::wstring initial_url;
  std::wstring fixture_denied_url = L"https://example.invalid/denied";
#ifdef _DEBUG
  std::wstring fixture_upgrade_from;
  std::wstring fixture_upgrade_to;
  std::wstring fixture_certificate_pem;
  bool navigation_targets_fixture_tls = false;
  std::optional<UINT64> waiting_fixture_certificate;
  bool fixture_certificate_cache_dirty = false;
  bool fixture_certificate_clear_pending = false;
#endif
  std::vector<std::wstring> origins;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Environment8> environment8;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> core;
  std::map<DWORD, HANDLE> processes;
  std::set<DWORD> associated_browser_pids;
  std::set<DWORD> exited_browser_groups;
  std::shared_ptr<Result> open_result;

  bool Alive() const {
    auto target = delivery.lock();
    return target && target->alive;
  }

  void Emit(const char* kind, const std::optional<std::wstring>& origin = {},
            const std::optional<Map>& diagnostic = {}) {
    auto target = delivery.lock();
    if (!target || !target->alive || !target->channel) return;
    Map event{{Value("session"), Value(session)},
              {Value("document"), Value(document)},
              {Value("kind"), Value(kind)}};
    if (origin && Allowed(*origin)) event[Value("origin")] = Value(Narrow(*origin));
    if (diagnostic) event[Value("diagnostic")] = Value(*diagnostic);
    target->channel->InvokeMethod("event", std::make_unique<Value>(event));
  }

  bool Allowed(const std::wstring& origin) const {
    return std::find(origins.begin(), origins.end(), origin) != origins.end();
  }

  Map Diagnostic(const char* code, const std::wstring& uri = L"") const {
    const auto origin = Origin(uri);
    const char* scheme = "other";
    const char* site = "unknown";
    if (origin) {
      scheme = origin->compare(0, 8, L"https://") == 0 ? "https" : "http";
      const auto host = origin->substr(origin->find(L"://") + 3);
      if (host == L"jw.ustc.edu.cn") site = "jw";
      else if (host == L"young.ustc.edu.cn") site = "young";
      else if (host == L"passport.ustc.edu.cn") site = "passport";
      else if (host == L"id.ustc.edu.cn") site = "identity";
      else if (host == L"ucas.ustc.edu.cn") site = "ucas";
      else if (host == L"analytics.ustc.edu.cn") site = "gateway";
#ifdef _DEBUG
      else if (test_mode && host.compare(0, 10, L"127.0.0.1:") == 0) site = "fixture";
#endif
    }
    return Map{{Value("code"), Value(code)}, {Value("site"), Value(site)},
               {Value("scheme"), Value(scheme)}};
  }

  std::optional<std::wstring> UpgradeTarget(const std::wstring& uri) const {
    if (!document_filter_installed) return {};
    const auto origin = Origin(uri);
    if (!origin || origin->compare(0, 7, L"http://") != 0) return {};
    std::wstring target_origin;
#ifdef _DEBUG
    if (test_mode) {
      if (*origin != fixture_upgrade_from || fixture_upgrade_to.empty()) return {};
      target_origin = fixture_upgrade_to;
    } else
#endif
    {
      if (test_mode) return {};
      target_origin = L"https://" + origin->substr(7);
      if (!Allowed(target_origin)) return {};
    }
    const auto suffix = uri.find_first_of(L"/?#", uri.find(L"://") + 3);
    const auto target = target_origin + (suffix == std::wstring::npos ? L"/" : uri.substr(suffix));
    const auto verified = Origin(target);
    return verified && *verified == target_origin ? std::optional<std::wstring>(target) : std::nullopt;
  }

  std::optional<std::wstring> CurrentOrigin() const {
    if (!core) return {};
    LPWSTR source = nullptr;
    const HRESULT hr = core->get_Source(&source);
    auto origin = SUCCEEDED(hr) && source ? Origin(source) : std::nullopt;
    CoTaskMemFree(source);
    return origin && Allowed(*origin) ? origin : std::nullopt;
  }

  void ClearSelfRoute() {
    self_route_id.clear();
    self_route_uri.clear();
    self_route_document = 0;
  }

  void ClearLauncher() {
    launcher_url.clear();
    launcher_navigation = 0;
    launcher_redirected = false;
  }

  void PrepareLauncher(const std::wstring& destination) {
    ClearLauncher();
    ClearSelfRoute();
    if (destination == probe_origin + L"/for-std/course-table" ||
        destination == probe_origin + L"/for-std/exam-arrange")
      launcher_url = destination;
  }

  void ObserveLauncher(ICoreWebView2NavigationStartingEventArgs* args,
                       UINT64 id, const std::wstring& uri, bool allowed) {
    if (launcher_url.empty()) return;
    BOOL redirected = FALSE;
    if (!allowed || FAILED(args->get_IsRedirected(&redirected))) {
      ClearLauncher();
      return;
    }
    if (launcher_navigation == 0) {
      if (redirected || uri != launcher_url) ClearLauncher();
      else launcher_navigation = id;
    } else if (id == launcher_navigation && redirected &&
               Origin(uri) == std::optional<std::wstring>(probe_origin)) {
      launcher_redirected = true;
    } else ClearLauncher();
  }

  void FinishLauncher(UINT64 id, bool success) {
    if (launcher_url.empty()) return;
    if (id != launcher_navigation || !success || !launcher_redirected) {
      ClearLauncher();
      return;
    }
    LPWSTR raw = nullptr;
    const HRESULT status = core->get_Source(&raw);
    const std::wstring uri = raw ? raw : L"";
    CoTaskMemFree(raw);
    const auto prefix = launcher_url + L"/info/";
    if (SUCCEEDED(status) && uri.compare(0, prefix.size(), prefix) == 0) {
      auto id_text = uri.substr(prefix.size());
      if (!id_text.empty() && id_text.back() == L'/') id_text.pop_back();
      const bool valid = !id_text.empty() && id_text.size() <= 12 &&
          std::all_of(id_text.begin(), id_text.end(), [](wchar_t value) {
            return value >= L'0' && value <= L'9';
          });
      if (valid) {
        self_route_id = id_text;
        self_route_uri = uri;
        self_route_document = document;
      }
    }
    ClearLauncher();
  }

  std::wstring BoundSelfRoute() const {
    if (self_route_id.empty() || self_route_document != document || !core) return L"";
    LPWSTR raw = nullptr;
    const HRESULT status = core->get_Source(&raw);
    const bool matches = SUCCEEDED(status) && raw && self_route_uri == raw;
    CoTaskMemFree(raw);
    return matches ? self_route_id : L"";
  }

  void ShowVisibleOrigin() const {
    const auto origin = CurrentOrigin();
    if (window && origin) {
      const auto caption = std::wstring(kWindowCaption) + L" - " + *origin;
      SetWindowText(window, caption.c_str());
    }
  }

#ifdef _DEBUG
  void ClearFixtureCertificateCache() {
    if (!test_mode || fixture_certificate_pem.empty() || !core || closing ||
        !fixture_certificate_cache_dirty || fixture_certificate_clear_pending) return;
    ComPtr<ICoreWebView2_14> certificates;
    if (FAILED(core.As(&certificates))) { Fail(); return; }
    fixture_certificate_clear_pending = true;
    fixture_certificate_cache_dirty = false;
    ++pending_scripts;
    auto self = shared_from_this();
    const HRESULT started = certificates->ClearServerCertificateErrorActions(
        Callback<ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler>(
          [self](HRESULT status) -> HRESULT {
            --self->pending_scripts;
            self->fixture_certificate_clear_pending = false;
            if (FAILED(status) && !self->closing) self->Fail();
            else if (self->closing) self->ReleaseExitedEnvironment();
            else self->ClearFixtureCertificateCache();
            return S_OK;
          }).Get());
    if (FAILED(started)) {
      --pending_scripts;
      fixture_certificate_clear_pending = false;
      Fail();
    }
  }
#endif

  void Invalidate() {
    if (young_observer) young_observer->Invalidate();
    if (young_reader) young_reader->Invalidate("mainRoute");
    ++document;
    ready = false;
    ClearSelfRoute();
    if (login_context_wait) FinishLogin(login_context_wait, "manualRequired", "staleResult");
    ClearLoginCapability();
    // Navigation may destroy the JS context before it can confirm abort. Do
    // not turn invalidation into proof that its fetch has stopped. This slot
    // is retained until normal settlement or whole browser-group exit.
    if (probe_operation != 0) probe_invalidated = true;
    probe_installed = false;
    probe_context_id = 0;
    probe_world_document = 0;
  }

  bool Track(DWORD pid) {
    if (pid == 0) return false;
    associated_browser_pids.insert(pid);
    const auto existing = processes.find(pid);
    if (existing != processes.end() && existing->second) return true;
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (process) {
      processes[pid] = process;
      return true;
    }
    if (GetLastError() == ERROR_INVALID_PARAMETER) {
      // The process vanished before OpenProcess. Its whole runtime group still
      // requires the official BrowserProcessExited event before profile release.
      if (existing != processes.end()) processes.erase(existing);
      return true;
    } else {
      // Access denied is not evidence of exit. Never permit profile deletion.
      processes[pid] = nullptr;
      return false;
    }
  }

  bool TrackProcesses() {
    if (!environment8) return false;
    ComPtr<ICoreWebView2ProcessInfoCollection> collection;
    UINT count = 0;
    if (FAILED(environment8->GetProcessInfos(&collection)) || !collection ||
        FAILED(collection->get_Count(&count))) {
      tracking_failed = true;
      return false;
    }
    tracking_failed = false;
    bool tracked = true;
    for (UINT i = 0; i < count; ++i) {
      ComPtr<ICoreWebView2ProcessInfo> info;
      COREWEBVIEW2_PROCESS_KIND kind = COREWEBVIEW2_PROCESS_KIND_BROWSER;
      INT32 pid = 0;
      if (FAILED(collection->GetValueAtIndex(i, &info)) || !info ||
          FAILED(info->get_Kind(&kind)) || FAILED(info->get_ProcessId(&pid))) {
        tracking_failed = true;
        return false;
      }
      if (kind == COREWEBVIEW2_PROCESS_KIND_BROWSER && !Track(static_cast<DWORD>(pid)))
        tracked = false;
    }
    std::vector<DWORD> unresolved;
    for (const auto& process : processes) {
      if (!process.second) unresolved.push_back(process.first);
    }
    for (const DWORD pid : unresolved) {
      if (!Track(pid)) tracked = false;
    }
    return tracked;
  }

  void FinishOpen(const char* reason = nullptr) {
    auto result = std::move(open_result);
    if (!Alive() || !result) return;
    if (reason) Error(result, reason);
    else result->Success();
  }

  bool BrowserGroupsExited() const {
    if (exit_event_failed) return false;
    for (const DWORD pid : associated_browser_pids) {
      if (exited_browser_groups.find(pid) == exited_browser_groups.end()) return false;
    }
    for (const auto& process : processes) {
      if (!process.second || WaitForSingleObject(process.second, 0) != WAIT_OBJECT_0)
        return false;
    }
    return true;
  }

  // Keep the environment alive to receive the official whole-process-group
  // exit proof. A browser process handle alone cannot prove renderer/utility or
  // user-data-folder release. Never wait synchronously inside a COM callback.
  bool ReleaseExitedEnvironment() {
    if (closing && pending_open == 0 && pending_scripts == 0 &&
        !controller && !core && !tracking_failed && BrowserGroupsExited() &&
        (pending_operations == 0 || (!associated_browser_pids.empty() &&
          browser_exit_subscribed && environment8))) {
      // The official process-group exit plus native callback completion proves
      // an invalidated/cancelled helper can no longer own a pending request.
      pending_operations = 0;
      probe_capability.clear();
      probe_reply_capability.clear();
    }
    if (!closing || pending_open != 0 || pending_scripts != 0 || pending_operations != 0 || controller ||
        core || tracking_failed || !BrowserGroupsExited()) return false;
    if (environment && (!environment8 || !browser_exit_subscribed)) return false;
    if (environment8) {
      if (process_infos_subscribed) {
        if (FAILED(environment8->remove_ProcessInfosChanged(process_infos_token)))
          return false;
        process_infos_subscribed = false;
      }
      if (browser_exit_subscribed) {
        if (FAILED(environment8->remove_BrowserProcessExited(browser_exit_token)))
          return false;
        browser_exit_subscribed = false;
      }
    }
    environment8.Reset();
    environment.Reset();
    return true;
  }

  // Controller::Close failure keeps ownership for an explicit retry. A late
  // environment/controller callback must finish before the window is destroyed.
  bool Close() {
    if (!closing) {
      closing = true;
      Invalidate();
    }
    configured = false;
    if (environment8 && (controller || pending_open != 0 || tracking_failed ||
          associated_browser_pids.empty() || !BrowserGroupsExited()) &&
        !TrackProcesses())
      return false;
    if (tracking_failed || exit_event_failed ||
        (environment && !browser_exit_subscribed)) return false;
    if (!StopLoginRuntimeReceivers()) return false;
    if (young_observer && !young_observer->Invalidate()) return false;
    if (young_reader && !young_reader->Invalidate()) return false;
    // A short Young CDP call may still be awaiting its native acknowledgement.
    // Closing its controller first can suppress that completion in WebView2.
    // The action is already revoked and receivers detached: keep the controller
    // until this bounded call really finishes, then continue normal group drain.
    if (young_reader && young_reader->Busy()) return true;
    if (controller) {
      if (core) core->Stop();
      if (FAILED(controller->Close())) return false;
      core.Reset();
      controller.Reset();
    }
    if (pending_open == 0) {
      if (window) {
        const HWND previous = window;
        if (!DestroyWindow(previous)) return false;
        window = nullptr;
      }
    }
    ReleaseExitedEnvironment();
    return true;
  }

  bool Drained() {
    // Progress an accepted Young close only outside its CDP completion. This
    // avoids reentering Controller.Close while the SDK callback is unwinding.
    if (closing && controller && young_reader && !young_reader->Busy() && !Close())
      return false;
    ReleaseExitedEnvironment();
    if (!closing || pending_open != 0 || pending_scripts != 0 || pending_operations != 0 || controller ||
        core || environment || environment8 || window || tracking_failed ||
        !BrowserGroupsExited())
      return false;
    return true;
  }

  void Fail() {
    if (!failed && !closing) {
      failed = true;
      Emit("failed");
    }
    FinishOpen("sourceFailed");
    Close();
  }

  void Block(const char* code, const std::wstring& uri = L"") {
    if (!closing) {
      if (window) SetWindowText(window, kBlockedCaption);
      Emit("blocked", {}, Diagnostic(code, uri));
    }
  }

  void CancelNavigation(ICoreWebView2NavigationStartingEventArgs* args,
                        bool frame, bool frame_associated = true,
                        bool report = true) {
    LPWSTR raw = nullptr;
    const HRESULT uri_result = args->get_Uri(&raw);
    const std::wstring uri = raw ? raw : L"";
    CoTaskMemFree(raw);
    const auto origin = SUCCEEDED(uri_result) ? Origin(uri) : std::nullopt;
    const auto upgraded = UpgradeTarget(uri);
    bool allowed = !closing && !user_closed && !failed && configured &&
        ((origin && Allowed(*origin)) || upgraded);
    if (frame) {
      const bool associated = frame_associated && visible_epoch != 0 && CurrentOrigin();
      allowed = associated && (allowed || (!closing && !user_closed && !failed && configured &&
                   (uri == L"about:blank" || uri == L"about:srcdoc")));
    } else {
      Invalidate();
      UINT64 requested_navigation = 0;
      if (FAILED(args->get_NavigationId(&requested_navigation))) {
        ClearLauncher();
        args->put_Cancel(TRUE);
        Fail();
        return;
      }
      ObserveLauncher(args, requested_navigation, uri, allowed);
      if (allowed) {
        navigation = requested_navigation;
#ifdef _DEBUG
        const auto target_origin = upgraded ? Origin(*upgraded) : origin;
        navigation_targets_fixture_tls = test_mode && !fixture_certificate_pem.empty() &&
            target_origin && *target_origin == fixture_upgrade_to;
        waiting_fixture_certificate.reset();
#endif
        pending_navigation = true;
        completed = false;
        dom_loaded = false;
        if (window) SetWindowText(window, kWindowCaption);
      } else {
        // Cancellation does not replace the visible document. Keep its
        // completed/DOM facts, but every previous inspection token is stale.
        suppressed_navigations.insert(requested_navigation);
        rejected_top_navigations.insert(requested_navigation);
      }
      Emit("navigating", allowed ? origin : std::nullopt);
    }
    if (!allowed) {
      if (FAILED(args->put_Cancel(TRUE))) Fail();
      else {
        if (report) Block(frame ? "frameNavigationBlocked" : "topNavigationBlocked", uri);
      }
    }
  }

  HRESULT FilterDocumentRequest(ICoreWebView2* sender,
                                ICoreWebView2WebResourceRequestedEventArgs* args) {
    ComPtr<ICoreWebView2WebResourceRequest> request;
    LPWSTR raw = nullptr;
    const HRESULT request_result = args->get_Request(&request);
    const HRESULT uri_result = SUCCEEDED(request_result) && request
        ? request->get_Uri(&raw) : E_FAIL;
    const std::wstring uri = raw ? raw : L"";
    CoTaskMemFree(raw);
    const auto origin = SUCCEEDED(uri_result) ? Origin(uri) : std::nullopt;
    const bool active = configured && !closing && !user_closed && !failed;
    const bool associated_blank = navigation != 0 && CurrentOrigin() &&
        (uri == L"about:blank" || uri == L"about:srcdoc");
    if (active && ((origin && Allowed(*origin)) || associated_blank)) return S_OK;
    const auto upgraded = active ? UpgradeTarget(uri) : std::nullopt;

    // Only DOCUMENT resources from DOCUMENT sources reach this handler. Supply
    // an empty local response while the request is synchronously held; never
    // examine request headers/content or read any upstream response.
    ComPtr<ICoreWebView2Environment> response_environment = environment;
    if (!response_environment) {
      ComPtr<ICoreWebView2_2> core2;
      if (FAILED(sender->QueryInterface(IID_PPV_ARGS(&core2))) ||
          FAILED(core2->get_Environment(&response_environment))) {
        Fail();
        return E_ABORT;
      }
    }
    ComPtr<ICoreWebView2WebResourceResponse> response;
    if (upgraded) {
      // A request-only URI rewrite can leave the document's original HTTP
      // identity in place when the server returns 200 directly. Let the
      // browser commit the HTTPS document while preserving the request method.
      const auto headers = L"Location: " + *upgraded +
          L"\r\nContent-Length: 0\r\nCache-Control: no-store\r\n";
      if (SUCCEEDED(response_environment->CreateWebResourceResponse(
            nullptr, 307, L"Temporary Redirect", headers.c_str(), &response)) &&
          SUCCEEDED(args->put_Response(response.Get()))) {
        Emit("diagnostic", {}, Diagnostic("insecureDocumentUpgraded", uri));
        return S_OK;
      }
      // A failed upgrade must never fall through to the original HTTP request.
      response.Reset();
    }
    if (FAILED(response_environment->CreateWebResourceResponse(
          nullptr, 403, L"Forbidden",
          L"Content-Length: 0\r\nCache-Control: no-store\r\n", &response)) ||
        FAILED(args->put_Response(response.Get()))) {
      Fail();
      return E_ABORT;
    }
    if (FAILED(uri_result)) Fail();
    else if (upgraded) Fail();
    else Block("documentRequestBlocked", uri);
    return S_OK;
  }

  void CheckReady(std::shared_ptr<Result> result = nullptr,
                  std::optional<int64_t> requested_document = {}) {
    const int64_t expected_document = requested_document.value_or(document);
    const auto origin = CurrentOrigin();
    if (closing || user_closed || failed || !configured || !core) {
      if (Alive()) Error(result, closing || user_closed ? "closed" : "sourceFailed");
      return;
    }
    if (expected_document != document) {
      if (Alive()) Error(result, "staleResult");
      return;
    }
    if (!origin || pending_navigation || !completed || !dom_loaded ||
        !rejected_top_navigations.empty()) {
      if (Alive() && result) {
        Map snapshot{{Value("session"), Value(session)},
                     {Value("document"), Value(document)},
                     {Value("ready"), Value(false)}};
        if (origin) snapshot[Value("origin")] = Value(Narrow(*origin));
        result->Success(Value(snapshot));
      }
      return;
    }
    ++pending_scripts;
    auto self = shared_from_this();
    auto completion = Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
        [self, result, expected_document, origin](HRESULT hr, LPCWSTR json) -> HRESULT {
      --self->pending_scripts;
      if (!self->Alive()) return S_OK;
      if (self->closing || self->user_closed || self->document != expected_document ||
          self->CurrentOrigin() != origin) {
        Error(result, "staleResult");
        return S_OK;
      }
      if (FAILED(hr) || !json) {
        Error(result, "sourceFailed");
        self->Fail();
        return S_OK;
      }
      const std::wstring expected_true = L"[true,\"" + *origin + L"\"]";
      const std::wstring expected_false = L"[false,\"" + *origin + L"\"]";
      const std::wstring actual = json;
      if (actual != expected_true && actual != expected_false) {
        Error(result, "staleResult");
        return S_OK;
      }
      const bool is_ready = actual == expected_true && !self->pending_navigation &&
          self->completed && self->dom_loaded;
      const bool changed = is_ready && !self->ready;
      self->ready = is_ready;
      if (is_ready) self->ShowVisibleOrigin();
      if (changed) self->Emit("ready", origin);
      if (result) {
        Map snapshot{{Value("session"), Value(self->session)},
                     {Value("document"), Value(expected_document)},
                     {Value("ready"), Value(is_ready)},
                     {Value("origin"), Value(Narrow(*origin))}};
        result->Success(Value(snapshot));
      }
      return S_OK;
    });
    if (FAILED(core->ExecuteScript(kReadyScript, completion.Get()))) {
      --pending_scripts;
      if (Alive()) Error(result, "sourceFailed");
      Fail();
    }
  }

  bool YoungReadContext(int64_t requested_document) const {
    return young_source && !closing && !user_closed && !failed && configured &&
        core && ready && requested_document == document && !pending_navigation &&
        completed && dom_loaded && CurrentOrigin() == probe_origin;
  }

  void PrepareYoungBusiness(std::shared_ptr<Result> result, int64_t requested_document,
      const std::wstring& path) {
    if (!YoungReadContext(requested_document)) { result->Success(Value(false)); return; }
    if (pending_operations != 0 || (young_observer &&
        (young_observer->Busy() || young_observer->snapshot().listening)) ||
        (young_reader && young_reader->Busy())) { Error(result, "busy"); return; }
    const std::wstring script = L"(()=>{'use strict';try{if(location.origin!==" +
        ScriptString(probe_origin) + L"||location.pathname!==" + ScriptString(path) +
        L"||document.readyState!=='complete'||!window.webpackJsonp)return false;"
        L"const m=window.webpackJsonp.push([[],{},[['0fea']]]);const f=m&&m.e;"
        L"return typeof f==='function'&&Function.prototype.toString.call(f)==="
        L"'function l(e,t){return Object(r[\"b\"])({url:e,method:\"get\",params:t,timeout:36e5})}'"
        L"}catch(_){return false}})()";
    ++pending_scripts;
    auto self = shared_from_this();
    const auto callback = Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
      [self, result, requested_document](HRESULT hr, LPCWSTR raw) -> HRESULT {
        --self->pending_scripts;
        if (self->Alive()) {
          if (!self->YoungReadContext(requested_document))
            YoungError(result, "staleResult", "nativeContext");
          else if (FAILED(hr) || !raw || (wcscmp(raw, L"true") != 0 && wcscmp(raw, L"false") != 0))
            YoungError(result, "sourceFailed", "sourceFailure");
          else result->Success(Value(wcscmp(raw, L"true") == 0));
        }
        if (self->closing) self->ReleaseExitedEnvironment();
        return S_OK;
      });
    if (FAILED(core->ExecuteScript(script.c_str(), callback.Get()))) {
      --pending_scripts;
      YoungError(result, "sourceFailed", "sourceFailure");
      if (closing) ReleaseExitedEnvironment();
    }
  }

  Map YoungReadSnapshot() const {
    const auto& snapshot = young_observer->snapshot();
    return Map{{Value("session"), Value(session)},
      {Value("document"), Value(young_read_document)},
      {Value("operation"), Value(young_read_operation)},
      {Value("listening"), Value(snapshot.listening)},
      {Value("accepted"), Value(snapshot.accepted)},
      {Value("rejected"), Value(snapshot.rejected)},
      {Value("lastRejection"), Value(young_probe::RejectionLabel(snapshot.last_rejection))},
      {Value("profile"), Value(YoungProfileMap(snapshot.profile))},
      {Value("schedule"), Value(YoungListMap(snapshot.schedule))},
      {Value("activities"), Value(YoungListMap(snapshot.activities))}};
  }

  void YoungRead(std::shared_ptr<Result> result, const std::string& method,
                 int64_t requested_document, int64_t operation) {
    if (!YoungReadContext(requested_document)) { Error(result, "busy"); return; }
    if (method == "startYoungReadOnly") {
      if (pending_operations != 0) { Error(result, "busy"); return; }
      if (young_observer && (young_observer->Busy() || young_observer->snapshot().listening)) {
        Error(result, "busy"); return;
      }
      if (young_observer && !young_observer->Invalidate()) {
        Error(result, "cleanupPending"); return;
      }
      young_read_document = requested_document;
      young_read_operation = operation;
      const std::weak_ptr<State> weak = shared_from_this();
      young_observer = std::make_shared<young_probe::ReadOnlyObserver>(core.Get(), probe_origin,
        [weak, requested_document, operation]() {
          const auto current = weak.lock();
          return current && current->Alive() && current->YoungReadContext(requested_document) &&
              current->young_read_operation == operation;
        }, [weak](int change) {
          if (const auto current = weak.lock()) {
            current->pending_scripts += change;
            if (change < 0 && current->closing) current->ReleaseExitedEnvironment();
          }
        });
      auto self = shared_from_this();
      young_observer->Start([self, result, requested_document, operation](const char* error) {
        if (!self->Alive()) return;
        if (!self->YoungReadContext(requested_document) || self->young_read_operation != operation)
          Error(result, "staleResult");
        else if (error) Error(result, error);
        else result->Success(Value(self->YoungReadSnapshot()));
      });
      return;
    }
    if (!young_observer || young_read_document != requested_document ||
        young_read_operation != operation || !young_observer->snapshot().listening) {
      Error(result, "staleResult"); return;
    }
    if (method == "readYoungReadOnly") {
      result->Success(Value(YoungReadSnapshot())); return;
    }
    auto self = shared_from_this();
    young_observer->Stop([self, result, requested_document, operation](const char* error) {
      if (!self->Alive()) return;
      if (!self->YoungReadContext(requested_document) || self->young_read_operation != operation)
        Error(result, "staleResult");
      else if (error) Error(result, error);
      else result->Success();
    });
  }

  void YoungBusiness(std::shared_ptr<Result> result, const std::string& method,
      int64_t requested_document, int64_t operation, int64_t step = 0,
      young_probe::Endpoint endpoint = young_probe::Endpoint::profile,
      int page = 0, const std::wstring& day = L"") {
    if (!YoungReadContext(requested_document)) { YoungError(result, "staleResult", "nativeContext"); return; }
    if (method == "startYoungBusiness") {
      if (pending_operations != 0 || (young_observer &&
          (young_observer->Busy() || young_observer->snapshot().listening))) {
        Error(result, "busy"); return;
      }
      if (young_reader && !young_reader->Invalidate()) { Error(result, "cleanupPending"); return; }
      ClearLoginCapability();
      if (!StopLoginRuntimeReceivers()) { Error(result, "cleanupPending"); return; }
      young_business_document = requested_document;
      young_business_operation = operation;
      ++pending_operations;  // Remains occupied through native failure until group exit.
      auto self = shared_from_this();
      auto start = [self, result, requested_document, operation]() {
        if (!self->YoungReadContext(requested_document) || self->young_business_operation != operation) {
          YoungError(result, "staleResult", "nativeContext"); return;
        }
        const std::weak_ptr<State> weak = self;
        self->young_reader = std::make_shared<young_probe::BusinessReader>(self->core.Get(), self->probe_origin,
          L"ustc-young-" + std::to_wstring(self->session) + L"-" + std::to_wstring(operation),
          [weak, requested_document, operation]() {
            const auto state = weak.lock();
            return state && state->Alive() && state->YoungReadContext(requested_document) &&
                state->young_business_operation == operation;
          }, [weak](int delta) {
            if (const auto state = weak.lock()) {
              state->pending_scripts += delta;
              if (delta < 0 && state->closing) state->ReleaseExitedEnvironment();
            }
          });
        self->young_reader->Start([self, result, requested_document, operation](const char* error) {
          if (!self->Alive()) return;
          if (!self->YoungReadContext(requested_document) || self->young_business_operation != operation)
            YoungError(result, "staleResult", self->young_reader->failure_reason());
          else if (error) YoungError(result, error, self->young_reader->failure_reason());
          else result->Success();
        });
      };
      if (login_runtime_enabled) {
        // Runtime.enable is idempotent and cannot replay existing contexts.
        // Detach the authentication observer before handing the domain to C1.
        login_runtime_enabled = false;
        ++pending_scripts;
        const auto callback = Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [self, result, start](HRESULT hr, LPCWSTR raw) -> HRESULT {
            --self->pending_scripts;
            if (self->Alive()) {
              if (FAILED(hr) || !raw || wcscmp(raw, L"{}") != 0)
                YoungError(result, "sourceFailed", "contextLost");
              else start();
            }
            if (self->closing) self->ReleaseExitedEnvironment();
            return S_OK;
          });
        if (FAILED(core->CallDevToolsProtocolMethod(L"Runtime.disable", L"{}", callback.Get()))) {
          --pending_scripts;
          YoungError(result, "sourceFailed", "contextLost");
        }
      } else start();
      return;
    }
    if (!young_reader || young_business_document != requested_document ||
        young_business_operation != operation) { YoungError(result, "staleResult", "nativeContext"); return; }
    auto self = shared_from_this();
    auto complete = [self, result, requested_document, operation](const char* error) {
      if (!self->Alive()) return;
      if (!self->YoungReadContext(requested_document) || self->young_business_operation != operation)
        YoungError(result, "staleResult", self->young_reader->failure_reason());
      else if (error) YoungError(result, error, self->young_reader->failure_reason());
      else result->Success();
    };
    if (method == "dispatchYoungBusinessStep") {
      young_reader->Dispatch(step, endpoint, page, day, complete); return;
    }
    if (method == "pollYoungBusinessStep") {
      young_reader->Poll(step, [self, result, requested_document, operation, step](
          const char* error, bool complete, const std::wstring& projection) {
        if (!self->Alive()) return;
        if (!self->YoungReadContext(requested_document) || self->young_business_operation != operation)
          YoungError(result, "staleResult", self->young_reader->failure_reason());
        else if (error) YoungError(result, error, self->young_reader->failure_reason());
        else {
          Map value{{Value("session"), Value(self->session)}, {Value("document"), Value(requested_document)},
            {Value("operation"), Value(operation)}, {Value("step"), Value(step)}, {Value("complete"), Value(complete)}};
          if (complete) value[Value("projectedJson")] = Value(Narrow(projection));
          result->Success(Value(value));
        }
      });
      return;
    }
    young_reader->Finish([self, complete](const char* error) {
      if (!error && self->pending_operations > 0) --self->pending_operations;
      complete(error);
    });
  }

  void InspectYoung(std::shared_ptr<Result> result, int64_t requested_document) {
    const auto origin = CurrentOrigin();
    if (!young_source || !origin || !Allowed(*origin)) {
      Error(result, "invalidSnapshot"); return;
    }
    const bool document_ready = ready && !pending_navigation && completed && dom_loaded;
    auto snapshot = [this, requested_document](const char* surface, bool complete) {
      return Map{{Value("session"), Value(session)},
                 {Value("document"), Value(requested_document)},
                 {Value("ready"), Value(complete)},
                 {Value("surface"), Value(surface)},
                 {Value("tables"), Value(int64_t{0})},
                 {Value("calendarRoots"), Value(int64_t{0})},
                 {Value("paginationControls"), Value(int64_t{0})},
                 {Value("passwordInputs"), Value(int64_t{0})}};
    };
    if (!document_ready || *origin != probe_origin) {
      result->Success(Value(snapshot(*origin == probe_origin ? "unknown" : "authentication",
                                     document_ready)));
      return;
    }
    ++pending_scripts;
    auto self = shared_from_this();
    auto completion = Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
        [self, result, requested_document, origin](HRESULT hr, LPCWSTR raw) -> HRESULT {
      --self->pending_scripts;
      if (!self->Alive()) return S_OK;
      if (self->closing || self->user_closed || self->failed ||
          self->document != requested_document ||
          self->CurrentOrigin() != origin || self->pending_navigation) {
        Error(result, "staleResult"); return S_OK;
      }
      if (FAILED(hr) || !raw) { Error(result, "sourceFailed"); return S_OK; }
      const std::wstring json(raw);
      const std::set<std::wstring> fields{
        L"ready", L"surface", L"tables", L"calendarRoots",
        L"paginationControls", L"passwordInputs"};
      if (!ProbeJson(json, 1024).ExactFields(fields)) {
        Error(result, "invalidSnapshot"); return S_OK;
      }
      auto field = [&](const wchar_t* key) { return ProbeJson(json, 1024).Field(key); };
      const auto surface_json = field(L"surface");
      const auto surface = surface_json ? ProbeJson(*surface_json, 1024).Text() : std::nullopt;
      const std::set<std::wstring> surfaces{
        L"unknown", L"portal", L"accessGate", L"authentication", L"application"};
      const auto ready_json = field(L"ready");
      if (!surface || surfaces.find(*surface) == surfaces.end() || !ready_json ||
          (*ready_json != L"true" && *ready_json != L"false")) {
        Error(result, "invalidSnapshot"); return S_OK;
      }
      Map value{{Value("session"), Value(self->session)},
                {Value("document"), Value(requested_document)},
                {Value("ready"), Value(*ready_json == L"true")},
                {Value("surface"), Value(Narrow(*surface))}};
      for (const wchar_t* key : {L"tables", L"calendarRoots", L"paginationControls", L"passwordInputs"}) {
        const auto number = field(key);
        int64_t count = 0;
        if (!number || number->empty() || number->size() > 4 ||
            (number->size() > 1 && number->front() == L'0')) {
          Error(result, "invalidSnapshot"); return S_OK;
        }
        for (const wchar_t digit : *number) {
          if (digit < L'0' || digit > L'9') { Error(result, "invalidSnapshot"); return S_OK; }
          count = count * 10 + digit - L'0';
        }
        if (count > 4096) { Error(result, "invalidSnapshot"); return S_OK; }
        value[Value(Narrow(key))] = Value(count);
      }
      result->Success(Value(value));
      return S_OK;
    });
    const auto script = YoungStructureScript(*origin);
    if (FAILED(core->ExecuteScript(script.c_str(), completion.Get()))) {
      --pending_scripts;
      Error(result, "sourceFailed");
    }
  }

  std::optional<std::wstring> LoginSource() const {
    if (!core) return {};
    LPWSTR raw = nullptr;
    const HRESULT status = core->get_Source(&raw);
    std::wstring source = raw ? raw : L"";
    CoTaskMemFree(raw);
    const auto origin = Origin(source);
    return SUCCEEDED(status) && source.size() <= 32768 && origin && Allowed(*origin)
        ? std::optional<std::wstring>(std::move(source)) : std::nullopt;
  }

  std::wstring LoginCasOrigin() const {
#ifdef _DEBUG
    if (test_mode) return probe_origin;
#endif
    return L"https://id.ustc.edu.cn";
  }

  bool LoginBaseContext(int64_t requested_document) const {
    return !closing && !user_closed && !failed && !recovery_only && configured && core &&
        requested_document == document && !pending_navigation && completed && dom_loaded &&
        visible_epoch != 0 && visible_completed && visible_dom_loaded &&
        rejected_top_navigations.empty() && LoginSource();
  }

  bool LoginAssociationCurrent(const std::shared_ptr<LoginRequest>& request) const {
    return request && !request->completed && login_request == request &&
        request->serial == login_serial && request->operation == login_operation &&
        LoginBaseContext(request->document) &&
        LoginSource() == std::optional<std::wstring>(request->source);
  }

  bool LoginCurrent(const std::shared_ptr<LoginRequest>& request) const {
    return !login_world_invalidated && LoginAssociationCurrent(request);
  }

  void RejectLoginCurrent(std::shared_ptr<LoginRequest> request) {
    FinishLogin(request, "contextUnavailable",
        login_world_invalidated && LoginAssociationCurrent(request) ? nullptr : "staleResult");
  }

  void ReleaseLoginObject(std::wstring object) {
    // Close invalidates local ownership first and immediately tears down the
    // controller. Starting a new CDP release there can lose its completion and
    // leave an unprovable pending slot. Controller teardown plus the existing
    // official process-group exit proof destroys those remote objects instead.
    // Releases already in flight retain their original count and callback.
    if (object.empty() || !core || closing || user_closed) return;
    // Releasing this private remote ID carries no credential and never selects
    // a replacement document. Its completion participates in the normal drain.
    const std::wstring parameters = L"{\"objectId\":" + ScriptString(object) + L"}";
    ++pending_scripts;
    auto self = shared_from_this();
    const HRESULT started = core->CallDevToolsProtocolMethod(L"Runtime.releaseObject", parameters.c_str(),
        Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [self](HRESULT, LPCWSTR) -> HRESULT {
            --self->pending_scripts;
            if (self->closing) self->ReleaseExitedEnvironment();
            return S_OK;
          }).Get());
    if (FAILED(started)) --pending_scripts;
  }

  void ClearLoginCapability() {
    auto object = std::move(login_object_id);
    login_object_id.clear();
    login_prepared_document = -1;
    login_prepared_operation = 0;
    login_prepared_source.clear();
    login_created_context = 0;
    login_expected_context = 0;
    login_unique_context.clear();
    login_world_name.clear();
    login_frame_id.clear();
    ReleaseLoginObject(std::move(object));
  }

  void StopLoginContextWait() {
    if (!login_context_wait) return;
    if (window) KillTimer(window, kLoginContextTimer);
    login_context_wait.reset();
    --pending_scripts;
  }

  void FinishLogin(std::shared_ptr<LoginRequest> request, const char* state,
                   const char* reason = nullptr, bool preserve = false) {
    if (!request || request->completed) return;
    request->completed = true;
    if (login_context_wait == request) StopLoginContextWait();
    if (login_request == request) {
      login_request.reset();
      if (pending_operations != 0) --pending_operations;
      if (!preserve) ClearLoginCapability();
    }
    if (Alive()) {
      if (reason) Error(request->result, reason);
      else request->result->Success(Value(state));
    }
    request->result.reset();
    if (closing) ReleaseExitedEnvironment();
  }

  void LoginCdp(const wchar_t* method, const std::wstring& parameters,
                std::shared_ptr<LoginRequest> request,
                std::function<void(const std::wstring&)> completion) {
    if (!LoginCurrent(request)) { RejectLoginCurrent(request); return; }
    ++pending_scripts;
    auto self = shared_from_this();
    const HRESULT started = core->CallDevToolsProtocolMethod(method, parameters.c_str(),
        Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [self, request, completion](HRESULT status, LPCWSTR json) -> HRESULT {
            --self->pending_scripts;
            if (!self->Alive() || !self->LoginCurrent(request)) {
              self->RejectLoginCurrent(request);
            } else if (FAILED(status) || !json || !*json ||
                wcslen(json) > kLoginCdpChars || ProbeJson(json, kLoginCdpChars).Field(L"error") ||
                ProbeJson(json, kLoginCdpChars).Field(L"exceptionDetails")) {
              // Failed context/runtime proof is a closed manual fallback. Raw CDP
              // exceptions, page text and URLs never cross this result boundary.
              self->FinishLogin(request, "contextUnavailable");
            } else completion(std::wstring(json));
            if (self->closing) self->ReleaseExitedEnvironment();
            return S_OK;
          }).Get());
    if (FAILED(started)) {
      --pending_scripts;
      FinishLogin(request, "contextUnavailable");
    }
  }

  bool StopLoginRuntimeReceivers() {
    for (auto& binding : login_runtime_receivers) {
      if (!binding.subscribed) continue;
      if (FAILED(binding.receiver->remove_DevToolsProtocolEventReceived(binding.token))) return false;
      binding.subscribed = false;
    }
    login_runtime_receivers.clear();
    return true;
  }

  void LoginRuntimeEvent(const std::wstring& event, const std::wstring& payload) {
    if (closing || user_closed || login_world_name.empty()) return;
    if (payload.size() > kLoginCdpChars) {
      login_world_invalidated = true;
    } else if (event == L"Runtime.executionContextCreated") {
      const auto context = ProbeJson(payload, kLoginCdpChars).Field(L"context");
      if (!context) return;
      const auto name_json = ProbeJson(*context).Field(L"name");
      const auto name = name_json ? ProbeJson(*name_json).Text() : std::nullopt;
      const auto auxiliary = ProbeJson(*context).Field(L"auxData");
      const auto frame_json = auxiliary ? ProbeJson(*auxiliary).Field(L"frameId") : std::nullopt;
      const auto frame = frame_json ? ProbeJson(*frame_json).Text() : std::nullopt;
      if (!name || !frame || *name != login_world_name || *frame != login_frame_id) return;
      const auto default_flag = ProbeJson(*auxiliary).Field(L"isDefault");
      const auto type_json = ProbeJson(*auxiliary).Field(L"type");
      const auto type = type_json ? ProbeJson(*type_json).Text() : std::nullopt;
      const auto id_json = ProbeJson(*context).Field(L"id");
      const auto id = id_json ? ProbeContextId(*id_json) : std::nullopt;
      const auto unique_json = ProbeJson(*context).Field(L"uniqueId");
      const auto unique = unique_json ? ProbeJson(*unique_json).Text() : std::nullopt;
      if (!default_flag || *default_flag != L"false" || !type || *type != L"isolated" ||
          !id || !unique || unique->empty() || unique->size() > 256 ||
          (login_created_context != 0 && (login_created_context != *id || login_unique_context != *unique))) {
        login_world_invalidated = true;
      } else {
        login_created_context = *id;
        login_unique_context = *unique;
        if (login_context_wait && login_expected_context == login_created_context) {
          auto request = login_context_wait;
          StopLoginContextWait();
          EstablishLoginObject(request);
        }
        return;
      }
    } else if (event == L"Runtime.executionContextDestroyed") {
      const auto id_json = ProbeJson(payload).Field(L"executionContextId");
      const auto id = id_json ? ProbeContextId(*id_json) : std::nullopt;
      if (!id || (*id != login_created_context && *id != login_expected_context)) return;
      login_world_invalidated = true;
    } else if (event == L"Runtime.executionContextsCleared") {
      login_world_invalidated = true;
    } else return;
    if (login_context_wait) FinishLogin(login_context_wait, "contextUnavailable");
    ClearLoginCapability();
  }

  bool EnsureLoginRuntimeReceivers() {
    if (login_runtime_failed) return false;
    if (!login_runtime_receivers.empty()) return true;
    const std::weak_ptr<State> weak = shared_from_this();
    for (const auto* event : {L"Runtime.executionContextCreated", L"Runtime.executionContextDestroyed",
                            L"Runtime.executionContextsCleared"}) {
      LoginRuntimeReceiver binding;
      const std::wstring event_name(event);
      if (FAILED(core->GetDevToolsProtocolEventReceiver(event, &binding.receiver)) ||
          !binding.receiver || FAILED(binding.receiver->add_DevToolsProtocolEventReceived(
          Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
            [weak, event_name](ICoreWebView2*, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT {
              if (auto self = weak.lock()) {
                LPWSTR raw = nullptr;
                if (SUCCEEDED(args->get_ParameterObjectAsJson(&raw)) && raw)
                  self->LoginRuntimeEvent(event_name, std::wstring(raw));
                else {
                  self->login_world_invalidated = true;
                  self->ClearLoginCapability();
                }
                CoTaskMemFree(raw);
              }
              return S_OK;
            }).Get(), &binding.token))) {
        login_runtime_failed = true;
        return false;
      }
      binding.subscribed = true;
      login_runtime_receivers.push_back(std::move(binding));
    }
    return true;
  }

  void CallLoginObject(std::shared_ptr<LoginRequest> request, bool submitting,
                       LoginSecrets* secrets = nullptr) {
    if (login_object_id.empty() || login_unique_context.empty() ||
        login_created_context != login_expected_context) {
      FinishLogin(request, "contextUnavailable"); return;
    }
    std::wstring parameters = L"{\"objectId\":" + ScriptString(login_object_id) +
        L",\"functionDeclaration\":" + ScriptString(submitting ? kJwLoginSubmit : kJwLoginAdvance) +
        L",\"returnByValue\":true,\"awaitPromise\":false,\"silent\":true";
    if (submitting) {
      if (!secrets) { FinishLogin(request, "manualRequired"); return; }
      parameters.reserve(kLoginCdpChars);
      parameters += L",\"arguments\":[{\"value\":";
      AppendSecretString(parameters, secrets->username);
      parameters += L"},{\"value\":";
      AppendSecretString(parameters, secrets->password);
      parameters += L"}]";
    }
    parameters += L'}';
    auto self = shared_from_this();
    LoginCdp(L"Runtime.callFunctionOn", parameters, request,
        [self, request, submitting](const std::wstring& payload) {
          const auto remote = ProbeJson(payload, kLoginCdpChars).Field(L"result");
          const auto type_json = remote ? ProbeJson(*remote).Field(L"type") : std::nullopt;
          const auto type = type_json ? ProbeJson(*type_json).Text() : std::nullopt;
          const auto state_json = remote ? ProbeJson(*remote).Field(L"value") : std::nullopt;
          const auto state = state_json ? ProbeJson(*state_json).Text() : std::nullopt;
          const bool manual = state && (*state == L"manualRequired" ||
              *state == L"pageStructureChanged" || *state == L"challengeRequired");
          const bool valid = type && *type == L"string" && state &&
              (submitting ? (*state == L"submitted" || manual) :
                (*state == L"formReady" || *state == L"portalActivated" ||
                 *state == L"waiting" || manual));
          if (!valid) { self->FinishLogin(request, "contextUnavailable"); return; }
          const bool prepared = !submitting && *state == L"formReady" &&
              Origin(request->source) == std::optional<std::wstring>(self->LoginCasOrigin()) &&
              LoginPath(request->source) == std::optional<std::wstring>(L"/cas/login");
          if (prepared) {
            self->login_prepared_document = request->document;
            self->login_prepared_operation = request->operation;
            self->login_prepared_source = request->source;
          }
          if (*state == L"portalActivated") self->login_portal_document = request->document;
          const auto wire = Narrow(*state);
          self->FinishLogin(request, wire.c_str(), nullptr, prepared);
        });
    // WebView2 has copied its protocol parameters when the call returns. Never
    // retain a secret in a native completion, retry closure or remote expression.
    if (submitting) Wipe(parameters);
  }

  void EstablishLoginObject(std::shared_ptr<LoginRequest> request) {
    if (!LoginCurrent(request) || login_expected_context == 0 ||
        login_created_context != login_expected_context || login_unique_context.empty()) {
      FinishLogin(request, "contextUnavailable"); return;
    }
    const std::wstring expression = std::wstring(kJwLoginFactory) + L"(" +
        ScriptString(request->source) + L"," + ScriptString(LoginCasOrigin()) + L"," +
        ScriptString(probe_origin) + L")";
    const std::wstring parameters = L"{\"expression\":" + ScriptString(expression) +
        L",\"uniqueContextId\":" + ScriptString(login_unique_context) +
        L",\"returnByValue\":false,\"awaitPromise\":false,"
        L"\"allowUnsafeEvalBlockedByCSP\":false,\"silent\":true}";
    auto self = shared_from_this();
    LoginCdp(L"Runtime.evaluate", parameters, request, [self, request](const std::wstring& payload) {
      const auto remote = ProbeJson(payload, kLoginCdpChars).Field(L"result");
      const auto type_json = remote ? ProbeJson(*remote).Field(L"type") : std::nullopt;
      const auto type = type_json ? ProbeJson(*type_json).Text() : std::nullopt;
      const auto id_json = remote ? ProbeJson(*remote).Field(L"objectId") : std::nullopt;
      const auto id = id_json ? ProbeJson(*id_json).Text() : std::nullopt;
      if (!type || *type != L"object" || !id || id->empty() || id->size() > 2048) {
        self->FinishLogin(request, "contextUnavailable"); return;
      }
      self->login_object_id = *id;
      self->CallLoginObject(request, false);
    });
  }

  void LoginContextTimeout() {
    if (login_context_wait) FinishLogin(login_context_wait, "contextUnavailable");
  }

  void EstablishLoginWorld(std::shared_ptr<LoginRequest> request) {
    if (login_world_attempt_document != request->document) {
      login_world_attempt_document = request->document;
      login_world_attempts = 0;
    }
    if (++login_world_attempts > 32) { FinishLogin(request, "contextUnavailable"); return; }
    auto self = shared_from_this();
    LoginCdp(L"Page.getFrameTree", L"{}", request, [self, request](const std::wstring& payload) {
      const auto tree = ProbeJson(payload).Field(L"frameTree");
      const auto frame = tree ? ProbeJson(*tree).Field(L"frame") : std::nullopt;
      const auto id_json = frame ? ProbeJson(*frame).Field(L"id") : std::nullopt;
      const auto id = id_json ? ProbeJson(*id_json).Text() : std::nullopt;
      const auto url_json = frame ? ProbeJson(*frame).Field(L"url") : std::nullopt;
      const auto url = url_json ? ProbeJson(*url_json).Text() : std::nullopt;
      if (!id || id->empty() || id->size() > 256 || !url || *url != request->source) {
        self->FinishLogin(request, "contextUnavailable"); return;
      }
      self->login_frame_id = *id;
      try { self->login_world_name = L"ustc_jw_login_v1_" + NewProbeCapability(); }
      catch (...) { self->FinishLogin(request, "contextUnavailable"); return; }
      const std::wstring parameters = L"{\"frameId\":" + ScriptString(*id) +
          L",\"worldName\":" + ScriptString(self->login_world_name) + L",\"grantUniveralAccess\":false}";
      self->LoginCdp(L"Page.createIsolatedWorld", parameters, request,
          [self, request](const std::wstring& created) {
            const auto id_json = ProbeJson(created).Field(L"executionContextId");
            const auto id = id_json ? ProbeContextId(*id_json) : std::nullopt;
            if (!id) { self->FinishLogin(request, "contextUnavailable"); return; }
            self->login_expected_context = *id;
            if (self->login_created_context == *id && !self->login_unique_context.empty()) {
              self->EstablishLoginObject(request);
            } else if (self->login_created_context != 0) {
              self->FinishLogin(request, "contextUnavailable");
            } else {
              // The host may dispatch the create response before the Runtime
              // event. Wait briefly for proof, holding the operation/drain slot.
              self->login_context_wait = request;
              ++self->pending_scripts;
              if (!self->window || !SetTimer(self->window, kLoginContextTimer, 2000, nullptr)) {
                self->FinishLogin(request, "contextUnavailable");
              }
            }
          });
    });
  }

  std::shared_ptr<LoginRequest> BeginLoginRequest(std::shared_ptr<Result> result,
      int64_t requested_document, int64_t operation, const std::wstring& source) {
    auto request = std::make_shared<LoginRequest>();
    request->result = std::move(result);
    request->document = requested_document;
    request->operation = operation;
    request->serial = ++login_serial;
    request->source = source;
    login_request = request;
    ++pending_operations;
    return request;
  }

  void AdvanceLogin(std::shared_ptr<Result> result, int64_t requested_document, int64_t operation) {
    if (pending_operations != 0 || login_request) { Error(result, "busy"); return; }
    if (operation <= login_operation) { Error(result, "staleResult"); return; }
    ClearLoginCapability();
    login_operation = operation;
    login_world_invalidated = false;
    if (!LoginBaseContext(requested_document)) { result->Success(Value("waiting")); return; }
    const auto source = LoginSource();
    const auto origin = source ? Origin(*source) : std::nullopt;
    const auto path = source ? LoginPath(*source) : std::nullopt;
    if (!source || !origin || !path) { result->Success(Value("manualRequired")); return; }
    const std::wstring young_root = L"/login/sc-wisdom-group-learning/";
    // Young's /login/ launches SSO, and its namespace root consumes the CAS
    // callback before moving to a SPA child route. Let those page-owned hops
    // finish; navigating a business deep link here can interrupt bootstrap.
    // The child route only admits fixed preparation, never identity or reads.
    const bool young_business = young_source && path->size() > young_root.size() &&
        path->compare(0, young_root.size(), young_root) == 0;
    if (*origin == probe_origin && (young_source ? young_business : LoginBusinessPath(*path))) {
      // Readiness of a registered business page grants no identity/import right.
      result->Success(Value("businessReady")); return;
    }
    if (*origin == probe_origin && (*path == L"/" || path->empty())) {
      const std::wstring destination = probe_origin + (young_source ? L"/login/" : L"/login");
      ClearLauncher();
      ClearSelfRoute();
      if (FAILED(core->Navigate(destination.c_str()))) Error(result, "sourceFailed");
      else result->Success(Value("portalActivated"));
      return;
    }
    const bool portal = !young_source && *origin == probe_origin && *path == L"/login";
    const bool form = *origin == LoginCasOrigin() && *path == L"/cas/login";
    if (young_source && !form && !portal) {
      result->Success(Value("waiting")); return;
    }
    if ((!portal && !form) || (form && login_consumed_document == requested_document)) {
      result->Success(Value("manualRequired")); return;
    }
    if (portal && login_portal_document == requested_document) {
      result->Success(Value("waiting")); return;
    }
    if (!EnsureLoginRuntimeReceivers()) { result->Success(Value("contextUnavailable")); return; }
    auto request = BeginLoginRequest(result, requested_document, operation, *source);
    if (login_runtime_enabled) EstablishLoginWorld(request);
    else {
      auto self = shared_from_this();
      LoginCdp(L"Runtime.enable", L"{}", request, [self, request](const std::wstring&) {
        self->login_runtime_enabled = true;
        self->EstablishLoginWorld(request);
      });
    }
  }

  void SubmitLogin(std::shared_ptr<Result> result, int64_t requested_document,
                    int64_t operation, const std::vector<uint8_t>& bytes) {
    if (pending_operations != 0 || login_request) { Error(result, "busy"); return; }
    if (!LoginBaseContext(requested_document) || operation != login_prepared_operation ||
        requested_document != login_prepared_document || login_object_id.empty() ||
        login_world_invalidated || login_consumed_document == requested_document ||
        LoginSource() != std::optional<std::wstring>(login_prepared_source) ||
        Origin(login_prepared_source) != std::optional<std::wstring>(LoginCasOrigin()) ||
        LoginPath(login_prepared_source) != std::optional<std::wstring>(L"/cas/login")) {
      ClearLoginCapability();
      Error(result, "staleResult"); return;
    }
    // Consume natively before decoding/dispatch as well as in the remote
    // closure. Neither a failed decode nor a callback can retry this document.
    login_consumed_document = requested_document;
    login_prepared_document = -1;
    login_prepared_operation = 0;
    LoginSecrets secrets;
    if (!secrets.Decode(bytes)) { ClearLoginCapability(); Error(result, "invalidSnapshot"); return; }
    auto request = BeginLoginRequest(result, requested_document, operation, login_prepared_source);
    CallLoginObject(request, true, &secrets);
  }

  bool ProbeContext(int64_t requested_document) const {
    return !closing && !user_closed && !failed &&
        !recovery_only && configured && core && requested_document == document &&
        !pending_navigation && completed && dom_loaded &&
        visible_epoch != 0 && visible_completed && visible_dom_loaded &&
        rejected_top_navigations.empty() && CurrentOrigin() == probe_origin;
  }

  bool ProbeCurrent(int64_t requested_document, uint64_t serial,
                    int64_t operation) const {
    return probe_serial == serial && probe_operation == operation &&
        probe_document == requested_document && !probe_invalidated &&
        ProbeContext(requested_document);
  }

  void ProbeCdp(const wchar_t* method, const std::wstring& parameters,
                std::shared_ptr<Result> result, int64_t requested_document,
                uint64_t serial, int64_t operation,
                std::function<void(const std::wstring&)> completion) {
    if (!ProbeCurrent(requested_document, serial, operation)) {
      Error(result, "staleResult");
      return;
    }
    ++pending_scripts;
    auto self = shared_from_this();
    const HRESULT started = core->CallDevToolsProtocolMethod(method, parameters.c_str(),
        Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [self, result, requested_document, serial, operation, completion](
              HRESULT hr, LPCWSTR payload) -> HRESULT {
            --self->pending_scripts;
            if (!self->Alive()) {
              if (self->closing) self->ReleaseExitedEnvironment();
              return S_OK;
            }
            if (!self->ProbeCurrent(requested_document, serial, operation)) {
              Error(result, "staleResult");
            } else if (FAILED(hr) || !payload || !*payload) {
              Error(result, "sourceFailed");
              self->Fail();
            } else completion(std::wstring(payload));
            if (self->closing) self->ReleaseExitedEnvironment();
            return S_OK;
          }).Get());
    if (FAILED(started)) {
      --pending_scripts;
      Error(result, "sourceFailed");
      Fail();
    }
  }

  std::wstring ProbeEvaluation(const std::wstring& expression) const {
    return L"{\"expression\":" + ScriptString(expression) +
        L",\"contextId\":" + std::to_wstring(probe_context_id) +
        L",\"returnByValue\":true,\"awaitPromise\":false,"
        L"\"allowUnsafeEvalBlockedByCSP\":false,\"silent\":true}";
  }

  void DeliverProbe(std::shared_ptr<Result> result, int64_t operation,
                    uint64_t serial, const std::wstring& payload) {
    const size_t maximum = probe_collect ? kCollectionCdpChars : kProbeCdpChars;
    if (payload.size() > maximum || ProbeJson(payload, maximum).Field(L"exceptionDetails") ||
        ProbeJson(payload, maximum).Field(L"error")) {
      Error(result, "sourceFailed"); Fail(); return;
    }
    const auto remote = ProbeJson(payload, maximum).Field(L"result");
    const auto projected = remote ? ProbeJson(*remote, maximum).Field(L"value") : std::nullopt;
    const auto decoded = projected ? ProbeJson(*projected, maximum).Text() : std::nullopt;
    const std::wstring raw = decoded.value_or(L"");
    const std::wstring settled_prefix = L"[true," + ScriptString(probe_reply_capability) + L",";
    const std::wstring running_prefix = L"[false," + ScriptString(probe_reply_capability) + L",";
    const bool settled = raw.compare(0, settled_prefix.size(), settled_prefix) == 0;
    const bool running = raw.compare(0, running_prefix.size(), running_prefix) == 0;
    const size_t offset = settled ? settled_prefix.size() : running_prefix.size();
    const bool valid = (settled || running) && raw.size() > offset + 2 &&
        raw.size() <= (probe_collect ? kCollectionProjectionChars : kProbeProjectionChars) && raw[offset] == L'{' &&
        raw[raw.size() - 2] == L'}' && raw.back() == L']';
    if (!valid) {
      // Never consume raw CDP errors, remote objects or exception text.
      Error(result, "sourceFailed"); Fail(); return;
    }
    if (settled && probe_serial == serial && probe_operation == operation &&
        pending_operations != 0) --pending_operations;
    result->Success(Value(Narrow(raw.substr(offset, raw.size() - offset - 1))));
  }

  void EvaluateProbe(std::shared_ptr<Result> result, const std::string& action,
                     int64_t requested_document, int64_t operation,
                     uint64_t serial) {
    if (!probe_installed || probe_context_id == 0 ||
        probe_world_document != requested_document) {
      Error(result, "sourceFailed"); Fail(); return;
    }
    // This fixed expression runs only in our document-bound isolated world.
    // There is no main-world, caller-script, URL or generic CDP fallback.
    const std::wstring script =
        L"(()=>{const a=this.__ustcJwProbeV1;return JSON.stringify(a." + Wide(action) +
        L"(" + ScriptString(probe_capability) + L"," + std::to_wstring(operation) +
        (action == "data" || action == "collect" ? L"," + std::to_wstring(probe_semester) : L"") + L"));})()";
    auto self = shared_from_this();
    ProbeCdp(L"Runtime.evaluate", ProbeEvaluation(script), result, requested_document,
        serial, operation, [self, result, serial, operation](const std::wstring& payload) {
          self->DeliverProbe(result, operation, serial, payload);
        });
  }

  void EstablishProbe(std::shared_ptr<Result> result, int64_t requested_document,
                      int64_t operation, uint64_t serial) {
    auto self = shared_from_this();
    ProbeCdp(L"Page.getFrameTree", L"{}", result, requested_document, serial, operation,
        [self, result, requested_document, operation, serial](const std::wstring& payload) {
          const auto tree = ProbeJson(payload).Field(L"frameTree");
          const auto frame = tree ? ProbeJson(*tree).Field(L"frame") : std::nullopt;
          const auto encoded_id = frame ? ProbeJson(*frame).Field(L"id") : std::nullopt;
          const auto id = encoded_id ? ProbeJson(*encoded_id).Text() : std::nullopt;
          if (!id || id->empty() || id->size() > 256) {
            Error(result, "sourceFailed"); self->Fail(); return;
          }
          // Page frame IDs and all other metadata stay private to this call.
          const std::wstring world_name = L"ustc_jw_probe_v1_" +
              self->probe_reply_capability + L"_" + std::to_wstring(requested_document);
          const std::wstring parameters = L"{\"frameId\":" + ScriptString(*id) +
              L",\"worldName\":" + ScriptString(world_name) +
              L",\"grantUniveralAccess\":false}";
          self->ProbeCdp(L"Page.createIsolatedWorld", parameters, result, requested_document,
              serial, operation,
              [self, result, requested_document, operation, serial](const std::wstring& created) {
                const auto encoded = ProbeJson(created).Field(L"executionContextId");
                const auto context = encoded ? ProbeContextId(*encoded) : std::nullopt;
                if (!context) { Error(result, "sourceFailed"); self->Fail(); return; }
                self->probe_context_id = *context;
                self->probe_world_document = requested_document;
                const std::wstring installer = std::wstring(kJwProbeInstaller) +
                    L".call(this," + ScriptString(self->probe_origin) + L"," +
                    ScriptString(self->probe_capability) + L"," +
                    ScriptString(self->probe_reply_capability) + L"," +
                    ScriptString(self->BoundSelfRoute()) + L");";
                self->ProbeCdp(L"Runtime.evaluate", self->ProbeEvaluation(installer), result,
                    requested_document, serial, operation,
                    [self, result, requested_document, operation, serial](const std::wstring& installed) {
                      const auto remote = ProbeJson(installed).Field(L"result");
                      const auto encoded_type = remote ? ProbeJson(*remote).Field(L"type") : std::nullopt;
                      const auto type = encoded_type ? ProbeJson(*encoded_type).Text() : std::nullopt;
                      if (ProbeJson(installed).Field(L"exceptionDetails") ||
                          ProbeJson(installed).Field(L"error") || !type || *type != L"undefined") {
                        Error(result, "sourceFailed"); self->Fail(); return;
                      }
                      self->probe_installed = true;
                      self->EvaluateProbe(result, self->probe_collect ? "collect" : self->probe_data ? "data" : "start",
                          requested_document, operation, serial);
                    });
              });
        });
  }

  void Probe(std::shared_ptr<Result> result, const std::string& action,
             int64_t requested_document, int64_t operation, int64_t semester = 0) {
    if (login_request) { Error(result, "busy"); return; }
    if (!ProbeContext(requested_document)) {
      Error(result, requested_document != document ? "staleResult" : "busy");
      return;
    }
    const bool starting = action == "start" || action == "data" || action == "collect";
    if (starting) {
      if (pending_operations != 0) { Error(result, "busy"); return; }
      if (operation <= probe_operation) { Error(result, "staleResult"); return; }
      if (probe_capability.empty()) {
        try {
          probe_capability = NewProbeCapability();
          probe_reply_capability = NewProbeCapability();
        } catch (...) { Error(result, "sourceFailed"); Fail(); return; }
      }
      probe_operation = operation;
      probe_document = requested_document;
      probe_invalidated = false;
      probe_data = action == "data" || action == "collect";
      probe_collect = action == "collect";
      probe_semester = semester;
      ++probe_serial;
      ++pending_operations;
    } else if (operation != probe_operation || requested_document != probe_document ||
               probe_invalidated) {
      Error(result, "staleResult");
      return;
    }
    if (starting && (!probe_installed || probe_context_id == 0 ||
        probe_world_document != requested_document))
      EstablishProbe(result, requested_document, operation, probe_serial);
    else EvaluateProbe(result, action, requested_document, operation, probe_serial);
  }

  bool FrameCurrent(std::shared_ptr<FrameBinding> binding) const {
    for (; binding; binding = binding->parent) {
      if (binding->destroyed || binding->epoch != visible_epoch) return false;
    }
    return true;
  }

  bool AttachFrame(ICoreWebView2Frame* frame,
                   std::shared_ptr<FrameBinding> parent = nullptr) {
    ComPtr<ICoreWebView2Frame7> frame7;
    if (!frame || FAILED(frame->QueryInterface(IID_PPV_ARGS(&frame7)))) return false;
    BOOL initially_destroyed = TRUE;
    if (FAILED(frame->IsDestroyed(&initially_destroyed))) return false;
    if (initially_destroyed || (parent && !FrameCurrent(parent)))
      return true;
    const std::weak_ptr<State> weak = shared_from_this();
    auto binding = std::make_shared<FrameBinding>();
    binding->epoch = parent ? parent->epoch : visible_epoch;
    binding->parent = parent;
    EventRegistrationToken token{};
    if (FAILED(frame7->add_Destroyed(
        Callback<ICoreWebView2FrameDestroyedEventHandler>(
          [binding](ICoreWebView2Frame*, IUnknown*) -> HRESULT {
            binding->destroyed = true;
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(frame7->add_NavigationStarting(
        Callback<ICoreWebView2FrameNavigationStartingEventHandler>(
          [weak, binding](ICoreWebView2Frame* sender,
                 ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            BOOL destroyed = TRUE;
            const HRESULT status = sender->IsDestroyed(&destroyed);
            if (auto self = weak.lock()) {
              const bool belongs = self->FrameCurrent(binding);
              if (FAILED(status)) {
                args->put_Cancel(TRUE);
                if (belongs) self->Fail();
              } else self->CancelNavigation(args, true, belongs && !destroyed,
                                             belongs && !destroyed);
            } else args->put_Cancel(TRUE);
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(frame7->add_PermissionRequested(
        Callback<ICoreWebView2FramePermissionRequestedEventHandler>(
          [weak, binding](ICoreWebView2Frame* sender, ICoreWebView2PermissionRequestedEventArgs2* args) -> HRESULT {
            const HRESULT denied = args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            const HRESULT handled = args->put_Handled(TRUE);
            if (auto self = weak.lock()) {
              BOOL destroyed = TRUE;
              const bool current = self->FrameCurrent(binding);
              if (current && (FAILED(sender->IsDestroyed(&destroyed)) ||
                  FAILED(denied) || FAILED(handled))) self->Fail();
              else if (current && !destroyed) self->Block("permissionBlocked");
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(frame7->add_FrameCreated(
        Callback<ICoreWebView2FrameChildFrameCreatedEventHandler>(
          [weak, binding](ICoreWebView2Frame* sender, ICoreWebView2FrameCreatedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              if (!self->FrameCurrent(binding)) return S_OK;
              BOOL destroyed = TRUE;
              if (FAILED(sender->IsDestroyed(&destroyed))) { self->Fail(); return S_OK; }
              if (destroyed) return S_OK;
              ComPtr<ICoreWebView2Frame> child;
              if (FAILED(args->get_Frame(&child)) || !self->AttachFrame(child.Get(), binding)) self->Fail();
            }
            return S_OK;
          }).Get(), &token))) return false;
#ifdef _DEBUG
    if (!fixture_certificate_pem.empty() && FAILED(frame7->add_NavigationCompleted(
        Callback<ICoreWebView2FrameNavigationCompletedEventHandler>(
          [weak](ICoreWebView2Frame*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              BOOL success = FALSE;
              if (SUCCEEDED(args->get_IsSuccess(&success)) && success)
                self->ClearFixtureCertificateCache();
            }
            return S_OK;
          }).Get(), &token))) return false;
#endif
    return true;
  }

  bool Configure() {
    ComPtr<ICoreWebView2_22> advanced;
    ComPtr<ICoreWebView2Settings> settings;
    ComPtr<ICoreWebView2Settings4> settings4;
    if (FAILED(core.As(&advanced)) || FAILED(core->get_Settings(&settings)) ||
        FAILED(settings.As(&settings4))) return false;
    if (FAILED(settings->put_AreDefaultContextMenusEnabled(FALSE)) ||
        FAILED(settings->put_AreDevToolsEnabled(FALSE)) ||
        FAILED(settings->put_IsWebMessageEnabled(FALSE)) ||
        FAILED(settings4->put_IsPasswordAutosaveEnabled(FALSE)) ||
        FAILED(settings4->put_IsGeneralAutofillEnabled(FALSE))) return false;
    const std::weak_ptr<State> weak = shared_from_this();
    EventRegistrationToken token{};
    if (FAILED(core->add_WebResourceRequested(
        Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [weak](ICoreWebView2* sender, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) return self->FilterDocumentRequest(sender, args);
            // No native owner remains: the controller has already been closed.
            return E_ABORT;
          }).Get(), &token))) return false;
    if (FAILED(advanced->AddWebResourceRequestedFilterWithRequestSourceKinds(
          L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT,
          COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_DOCUMENT))) return false;
    document_filter_installed = true;
    if (FAILED(core->add_NavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) self->CancelNavigation(args, false);
            else args->put_Cancel(TRUE);
            return S_OK;
          }).Get(), &token))) return false;
    // Root event covers frames before their FrameCreated registration is ready.
    if (FAILED(core->add_FrameNavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            // This core event has no frame identity. Enforce the URI policy
            // here; attached live-frame handlers own document-bound reporting.
            if (auto self = weak.lock()) self->CancelNavigation(args, true, true, false);
            else args->put_Cancel(TRUE);
            return S_OK;
          }).Get(), &token))) return false;
    auto navigation_completed_handler = Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              UINT64 id = 0;
              BOOL success = FALSE;
              if (FAILED(args->get_NavigationId(&id)) || FAILED(args->get_IsSuccess(&success))) {
                self->Fail();
              } else {
                // The visible document may finish while a different attempt is
                // pending. Preserve that fact for a later canceled redirect.
                if (id == self->visible_navigation &&
                    self->suppressed_navigations.find(id) == self->suppressed_navigations.end())
                  self->visible_completed = success == TRUE;
                if (self->suppressed_navigations.erase(id) != 0) {
                  // A host rejection is an expected outcome, never source failure.
                  self->rejected_top_navigations.erase(id);
                  if (id == self->navigation) {
                    self->navigation = self->visible_navigation;
                    self->completed = self->visible_completed;
                    self->dom_loaded = self->visible_dom_loaded;
                    self->pending_navigation = false;
#ifdef _DEBUG
                    self->navigation_targets_fixture_tls = false;
                    self->waiting_fixture_certificate.reset();
#endif
                  }
                  if (!self->closing && !self->user_closed) self->CheckReady();
                } else if (id == self->navigation && !self->closing && !self->user_closed) {
                  self->pending_navigation = false;
                  self->completed = success == TRUE;
                  self->FinishLauncher(id, success == TRUE);
                  if (success) {
#ifdef _DEBUG
                    self->waiting_fixture_certificate.reset();
                    self->ClearFixtureCertificateCache();
#endif
                    self->CheckReady();
                  } else {
                    COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                    if (FAILED(args->get_WebErrorStatus(&status))) self->Fail();
#ifdef _DEBUG
                    else if (self->navigation_targets_fixture_tls && CertificateFailure(status)) {
                      // WebView2 reports the certificate navigation failure first.
                      // Remain unready until the following exact-origin PEM pin
                      // decision; a later successful completion owns readiness.
                      self->pending_navigation = true;
                      self->waiting_fixture_certificate = id;
                    }
#endif
                    else if (status != COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED)
                      self->Emit("failed");
                    // A canceled download can complete before DownloadStarting,
                    // which has no navigation ID. Aborted navigation stays unready
                    // until the user returns to the fixed initial entry.
                  }
                }
              }
            }
            return S_OK;
          });
    if (FAILED(core->add_NavigationCompleted(navigation_completed_handler.Get(), &token)))
      return false;
    if (FAILED(advanced->add_DOMContentLoaded(
        Callback<ICoreWebView2DOMContentLoadedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2DOMContentLoadedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              UINT64 id = 0;
              if (FAILED(args->get_NavigationId(&id))) self->Fail();
              else if (!self->closing && !self->user_closed) {
                if (id == self->visible_navigation) self->visible_dom_loaded = true;
                if (id == self->navigation) {
                  self->dom_loaded = true;
                  self->CheckReady();
                }
              }
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(core->add_SourceChanged(
        Callback<ICoreWebView2SourceChangedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2SourceChangedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              BOOL new_document = TRUE;
              if (FAILED(args->get_IsNewDocument(&new_document))) self->Fail();
              else if (!self->closing && !self->user_closed) {
                self->ShowVisibleOrigin();
                if (new_document) {
                  ++self->visible_epoch;
                  self->visible_navigation = self->navigation;
                  self->visible_completed = false;
                  self->visible_dom_loaded = false;
                } else {
                  self->ClearLauncher();
                  self->Invalidate();
                  self->Emit("navigating", self->CurrentOrigin());
                  self->CheckReady();
                }
              }
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(core->add_HistoryChanged(
        Callback<ICoreWebView2HistoryChangedEventHandler>(
          [weak](ICoreWebView2*, IUnknown*) -> HRESULT {
            if (auto self = weak.lock()) {
              // During fixed Young reads, Page events bind same-document
              // changes to the main frame. WebView history also changes when
              // an unrelated iframe navigates, so it cannot identify a main
              // document change. Skip only after that precise guard is ready.
              if (self->young_reader && self->young_reader->RouteGuardReady()) return S_OK;
              // SourceChanged is not guaranteed for pushState with the same
              // URL. Invalidate any prepared authentication object on that
              // document change as well; full navigations already own a gate.
              if (!self->closing && !self->user_closed && self->configured &&
                  !self->pending_navigation && self->completed && self->dom_loaded &&
                  self->visible_completed && self->visible_dom_loaded) {
                self->Invalidate();
                self->Emit("navigating", self->CurrentOrigin());
                self->CheckReady();
              }
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(core->add_NewWindowRequested(
        Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            const HRESULT hr = args->put_Handled(TRUE);
            if (auto self = weak.lock()) {
              if (FAILED(hr)) self->Fail(); else self->Block("popupBlocked");
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(advanced->add_DownloadStarting(
        Callback<ICoreWebView2DownloadStartingEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
            const HRESULT canceled = args->put_Cancel(TRUE);
            const HRESULT handled = args->put_Handled(TRUE);
            if (auto self = weak.lock()) {
              if (FAILED(canceled) || FAILED(handled)) self->Fail();
              else {
                if (!self->completed) self->suppressed_navigations.insert(self->navigation);
                self->Block("downloadBlocked");
              }
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(core->add_PermissionRequested(
        Callback<ICoreWebView2PermissionRequestedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
            const HRESULT denied = args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            ComPtr<ICoreWebView2PermissionRequestedEventArgs2> args2;
            const HRESULT qi = args->QueryInterface(IID_PPV_ARGS(&args2));
            const HRESULT handled = SUCCEEDED(qi) ? args2->put_Handled(TRUE) : qi;
            if (auto self = weak.lock()) {
              if (FAILED(denied) || FAILED(handled)) self->Fail(); else self->Block("permissionBlocked");
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(advanced->add_LaunchingExternalUriScheme(
        Callback<ICoreWebView2LaunchingExternalUriSchemeEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2LaunchingExternalUriSchemeEventArgs* args) -> HRESULT {
            const HRESULT hr = args->put_Cancel(TRUE);
            if (auto self = weak.lock()) {
              if (FAILED(hr)) self->Fail(); else self->Block("externalProtocolBlocked");
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(advanced->add_FrameCreated(
        Callback<ICoreWebView2FrameCreatedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2FrameCreatedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) {
              ComPtr<ICoreWebView2Frame> frame;
              if (FAILED(args->get_Frame(&frame)) || !self->AttachFrame(frame.Get())) self->Fail();
            }
            return S_OK;
          }).Get(), &token))) return false;
    if (FAILED(core->add_ProcessFailed(
        Callback<ICoreWebView2ProcessFailedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) -> HRESULT {
            if (auto self = weak.lock()) self->Fail();
            return S_OK;
          }).Get(), &token))) return false;
#ifdef _DEBUG
    if (!fixture_certificate_pem.empty()) {
      if (FAILED(advanced->add_ServerCertificateErrorDetected(
          Callback<ICoreWebView2ServerCertificateErrorDetectedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2ServerCertificateErrorDetectedEventArgs* args) -> HRESULT {
              bool allow = false;
              if (auto self = weak.lock()) {
                LPWSTR raw = nullptr;
                const HRESULT uri_result = args->get_RequestUri(&raw);
                const auto origin = SUCCEEDED(uri_result) && raw ? Origin(raw) : std::nullopt;
                CoTaskMemFree(raw);
                if (!self->closing && !self->user_closed && !self->failed && self->test_mode &&
                    origin && *origin == self->fixture_upgrade_to) {
                  ComPtr<ICoreWebView2Certificate> certificate;
                  LPWSTR pem = nullptr;
                  const HRESULT cert_result = args->get_ServerCertificate(&certificate);
                  const HRESULT pem_result = SUCCEEDED(cert_result) && certificate
                      ? certificate->ToPemEncoding(&pem) : E_FAIL;
                  allow = SUCCEEDED(pem_result) && pem &&
                      NormalizePem(pem) == self->fixture_certificate_pem;
                  CoTaskMemFree(pem);
                }
                if (FAILED(args->put_Action(allow
                    ? COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW
                    : COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_CANCEL))) self->Fail();
                else if (!allow) self->Fail();
                else {
                  self->fixture_certificate_cache_dirty = true;
                  if (self->waiting_fixture_certificate == self->navigation)
                    self->waiting_fixture_certificate.reset();
                  // ALWAYS_ALLOW is cached by host+certificate, not port.
                  // Clear after a successful top/frame completion, when the
                  // accepted event has returned and its decision is committed.
                  // This limits lifetime; it cannot isolate concurrent resources
                  // or already-established TLS connections by port.
                }
              } else args->put_Action(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_CANCEL);
              return S_OK;
            }).Get(), &token))) return false;
    }
#endif
    configured = true;
    return true;
  }
};

struct WindowBinding {
  std::weak_ptr<State> state;
  bool window_owned = false;
};

LRESULT CALLBACK ObservationWindowProc(HWND window, UINT message,
                                      WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto binding = reinterpret_cast<WindowBinding*>(GetWindowLongPtr(window, GWLP_USERDATA));
  auto state = binding ? binding->state.lock() : nullptr;
  if (message == WM_CLOSE && state) {
    if (!state->closing && !state->user_closed) {
      state->user_closed = true;
      state->Invalidate();
      state->Emit("userClosed");
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == kLoginContextTimer && state) {
    state->LoginContextTimeout();
    return 0;
  }
  if (message == WM_SIZE && state && state->controller) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    if (FAILED(state->controller->put_Bounds(bounds))) state->Fail();
  }
  if (message == WM_SETFOCUS && state && state->controller)
    state->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
  if (message == WM_NCDESTROY) {
    SetWindowLongPtr(window, GWLP_USERDATA, 0);
    if (state) state->window = nullptr;
    if (binding && binding->window_owned) delete binding;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

bool CreateObservationWindow(const std::shared_ptr<State>& state, HWND owner) {
  WNDCLASS window_class{};
  window_class.lpfnWndProc = ObservationWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kWindowClass;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  if (!RegisterClass(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return false;
  auto binding = std::make_unique<WindowBinding>();
  binding->state = state;
  state->window = CreateWindowEx(0, kWindowClass, kWindowCaption,
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1050, 780,
      owner, nullptr, GetModuleHandle(nullptr), binding.get());
  if (!state->window) return false;
  binding->window_owned = true;
  binding.release();
  if (!state->recovery_only) ShowWindow(state->window, SW_SHOW);
  return true;
}

#ifdef _DEBUG
bool FixtureOrigin(const std::wstring& value) {
  const std::wstring prefix = value.compare(0, 8, L"https://") == 0
      ? L"https://127.0.0.1:" : L"http://127.0.0.1:";
  const size_t prefix_length = prefix.size();
  const auto parsed = Origin(value);
  return parsed && *parsed == value && value.compare(0, prefix_length, prefix) == 0 &&
      value.size() > prefix_length &&
      std::all_of(value.begin() + prefix_length, value.end(),
                  [](wchar_t digit) { return digit >= L'0' && digit <= L'9'; });
}
#endif

bool ValidTarget(const Map* args, State* state) {
  const auto* initial = Text(Field(args, "initialUrl"));
  const auto* raw_origins = Field(args, "allowedOrigins");
  const auto* list = raw_origins ? std::get_if<flutter::EncodableList>(raw_origins) : nullptr;
  const auto* raw_mode = Field(args, "testMode");
  const auto* mode = raw_mode ? std::get_if<bool>(raw_mode) : nullptr;
  if (!initial || !list || !mode) return false;
  if (const auto* recovery = Field(args, "recoveryOnly")) {
    const auto* value = std::get_if<bool>(recovery);
    if (!value) return false;
    state->recovery_only = *value;
  }
  state->initial_url = Wide(*initial);
  state->test_mode = *mode;
  const auto* source_field = Field(args, "source");
  const auto* source = Text(source_field);
  if (source_field && (!source || (*source != "jw" && *source != "young"))) return false;
  state->young_source = source && *source == "young";
  state->probe_origin = state->young_source ? L"https://young.ustc.edu.cn" : L"https://jw.ustc.edu.cn";
  const auto* upgrade_from_field = Field(args, "fixtureUpgradeFromOrigin");
  const auto* upgrade_to_field = Field(args, "fixtureUpgradeToOrigin");
  const auto* certificate_field = Field(args, "fixtureCertificatePem");
  const bool has_upgrade = upgrade_from_field || upgrade_to_field || certificate_field;
  if (!state->test_mode && (has_upgrade || Field(args, "fixtureDeniedUrl"))) return false;
  for (const auto& item : *list) {
    const auto* text = Text(&item);
    if (!text) return false;
    const auto wide = Wide(*text);
    const auto parsed = Origin(wide);
    if (!parsed || *parsed != wide ||
        std::find(state->origins.begin(), state->origins.end(), wide) != state->origins.end())
      return false;
    state->origins.push_back(wide);
  }
  if (!state->test_mode) {
    auto origins = state->origins;
    std::sort(origins.begin(), origins.end());
    if (state->young_source) {
      return state->initial_url == L"https://young.ustc.edu.cn/login/" &&
          origins == std::vector<std::wstring>{
            L"https://analytics.ustc.edu.cn", L"https://id.ustc.edu.cn",
            L"https://passport.ustc.edu.cn", L"https://ucas.ustc.edu.cn",
            L"https://young.ustc.edu.cn"};
    }
    return state->initial_url == L"https://jw.ustc.edu.cn/" &&
        origins == std::vector<std::wstring>{
          L"https://analytics.ustc.edu.cn", L"https://id.ustc.edu.cn",
          L"https://jw.ustc.edu.cn", L"https://passport.ustc.edu.cn"};
  }
#ifdef _DEBUG
  const auto origin = Origin(state->initial_url);
  if (!origin || state->origins.empty() || state->origins.size() > 4 ||
      !state->Allowed(*origin) ||
      !std::all_of(state->origins.begin(), state->origins.end(), FixtureOrigin))
    return false;
  state->probe_origin = *origin;
  if (has_upgrade) {
    const auto* from = Text(upgrade_from_field);
    const auto* to = Text(upgrade_to_field);
    const auto* certificate = Text(certificate_field);
    if (!from || !to || !certificate || certificate->empty() || certificate->size() > 8192)
      return false;
    state->fixture_upgrade_from = Wide(*from);
    state->fixture_upgrade_to = Wide(*to);
    state->fixture_certificate_pem = NormalizePem(Wide(*certificate));
    if (!FixtureOrigin(state->fixture_upgrade_from) ||
        state->fixture_upgrade_from.compare(0, 7, L"http://") != 0 ||
        state->Allowed(state->fixture_upgrade_from) ||
        !FixtureOrigin(state->fixture_upgrade_to) ||
        state->fixture_upgrade_to.compare(0, 8, L"https://") != 0 ||
        !state->Allowed(state->fixture_upgrade_to) ||
        state->fixture_certificate_pem.find(L'\0') != std::wstring::npos ||
        state->fixture_certificate_pem.compare(0, 28, L"-----BEGIN CERTIFICATE-----\n") != 0 ||
        state->fixture_certificate_pem.find(L"\n-----END CERTIFICATE-----") == std::wstring::npos)
      return false;
  }
  const auto* denied_value = Field(args, "fixtureDeniedUrl");
  const auto* denied = Text(denied_value);
  if (denied_value && !denied) return false;
  if (denied) {
    const auto denied_url = Wide(*denied);
    const auto denied_origin = Origin(denied_url);
    if (!denied_origin || state->Allowed(*denied_origin) || !FixtureOrigin(*denied_origin) ||
        denied_url != *denied_origin + L"/denied") return false;
    state->fixture_denied_url = denied_url;
  }
  ComPtr<IUri> uri;
  BSTR query = nullptr;
  BSTR fragment = nullptr;
  if (FAILED(CreateUri(state->initial_url.c_str(), Uri_CREATE_CANONICALIZE, 0, &uri))) return false;
  const HRESULT query_result = uri->GetQuery(&query);
  const HRESULT fragment_result = uri->GetFragment(&fragment);
  const bool clean = SUCCEEDED(query_result) && SUCCEEDED(fragment_result) &&
      (!query || SysStringLen(query) == 0) && (!fragment || SysStringLen(fragment) == 0);
  SysFreeString(query);
  SysFreeString(fragment);
  return clean;
#else
  return false;
#endif
}

void StartOpen(const std::shared_ptr<State>& state, const std::wstring& profile) {
  ++state->pending_open;
  const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, profile.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [state](HRESULT hr, ICoreWebView2Environment* environment) -> HRESULT {
          --state->pending_open;
          if (FAILED(hr) || !environment) {
            state->Fail();
            return S_OK;
          }
          state->environment = environment;
          if (FAILED(environment->QueryInterface(IID_PPV_ARGS(&state->environment8)))) {
            state->tracking_failed = true;
            state->Fail();
            return S_OK;
          }
          const std::weak_ptr<State> weak = state;
          if (FAILED(state->environment8->add_BrowserProcessExited(
              Callback<ICoreWebView2BrowserProcessExitedEventHandler>(
                [weak](ICoreWebView2Environment*, ICoreWebView2BrowserProcessExitedEventArgs* args) -> HRESULT {
                  if (auto self = weak.lock()) {
                    UINT32 pid = 0;
                    if (FAILED(args->get_BrowserProcessId(&pid)) || pid == 0) {
                      self->exit_event_failed = true;
                      self->Fail();
                    } else {
                      // The event belongs to this exact environment. Retain even
                      // an early event until a controller/process-info callback
                      // associates that PID, and keep all browser generations.
                      self->exited_browser_groups.insert(pid);
                      self->ReleaseExitedEnvironment();
                    }
                  }
                  return S_OK;
                }).Get(), &state->browser_exit_token))) {
            state->exit_event_failed = true;
            state->Fail();
            return S_OK;
          }
          state->browser_exit_subscribed = true;
          if (FAILED(state->environment8->add_ProcessInfosChanged(
              Callback<ICoreWebView2ProcessInfosChangedEventHandler>(
                [weak](ICoreWebView2Environment*, IUnknown*) -> HRESULT {
                  if (auto self = weak.lock()) {
                    // Ignore an already queued callback after proof-based release.
                    if (self->environment8 && !self->TrackProcesses()) self->Fail();
                  }
                  return S_OK;
                }).Get(), &state->process_infos_token))) {
            state->Fail();
            return S_OK;
          }
          state->process_infos_subscribed = true;
          if (!state->TrackProcesses()) {
            state->Fail();
            return S_OK;
          }
          if (state->closing) {
            state->FinishOpen("closed");
            state->Close();
            return S_OK;
          }
          ++state->pending_open;
          const HRESULT controller_started = environment->CreateCoreWebView2Controller(
              state->window,
              Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [state](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                  --state->pending_open;
                  state->TrackProcesses();
                  if (controller) {
                    state->controller = controller;
                    if (FAILED(controller->get_CoreWebView2(&state->core)) || !state->core) {
                      state->Fail();
                      return S_OK;
                    }
                    UINT32 pid = 0;
                    if (FAILED(state->core->get_BrowserProcessId(&pid)) || pid == 0) {
                      state->tracking_failed = true;
                      state->Fail();
                      return S_OK;
                    }
                    if (!state->Track(pid)) {
                      state->Fail();
                      return S_OK;
                    }
                  }
                  if (state->closing) {
                    state->FinishOpen("closed");
                    state->Close();
                    return S_OK;
                  }
                  RECT bounds{};
                  GetClientRect(state->window, &bounds);
                  if (FAILED(result) || !controller || state->tracking_failed ||
                      !state->Configure() || FAILED(controller->put_Bounds(bounds)) ||
                      FAILED(controller->put_IsVisible(!state->recovery_only))) {
                    state->Fail();
                    return S_OK;
                  }
                  // Retained browser controls precede the first URL. The
                  // private isolated probe world is created only on user read.
                  if (!state->recovery_only) state->PrepareLauncher(state->initial_url);
                  if (!state->recovery_only &&
                      FAILED(state->core->Navigate(state->initial_url.c_str()))) {
                    state->Fail();
                    return S_OK;
                  }
                  state->FinishOpen();
                  return S_OK;
                }).Get());
          if (FAILED(controller_started)) {
            --state->pending_open;
            state->Fail();
          }
          return S_OK;
        }).Get());
  if (FAILED(started)) {
    --state->pending_open;
    state->Fail();
  }
}

#ifdef _DEBUG
std::wstring FixtureScript(const std::string& action, const std::wstring& denied,
                           const std::wstring& initial_origin) {
  if (action == "topDenied") return L"location.href='" + denied + L"'";
  if (action == "frameDenied") return L"(()=>{const f=document.createElement('iframe');f.src='" + denied + L"';document.body.appendChild(f)})()";
  if (action == "popup") return L"window.open('" + denied + L"')";
  if (action == "download") return L"(()=>{const a=document.createElement('a');a.href='/download';a.download='fixture.txt';document.body.appendChild(a);a.click()})()";
  if (action == "permission") return L"navigator.geolocation.getCurrentPosition(()=>{},()=>{})";
  if (action == "external") return L"(()=>{const a=document.createElement('a');a.href='ustc-test:fixture';document.body.appendChild(a);a.click()})()";
  if (action == "sameDocument") return L"history.pushState(null,'','#fixture')";
  if (action == "youngSameUrlPush") return L"history.pushState(null,'',location.href)";
  if (action == "youngSameUrlReplace") return L"history.replaceState(null,'',location.href)";
  if (action == "youngHistoryBack") return L"history.back()";
  if (action == "youngHistoryForward") return L"history.forward()";
  if (action == "youngRouteAfterBody") return L"window.__youngRouteAfterBody=true";
  if (action == "youngReadProfile" || action == "youngReadSchedule" ||
      action == "youngReadActivities" || action == "youngConcurrent" ||
      action == "youngRedirect" || action == "youngWrongMethod" ||
      action == "youngFrame" || action == "youngWorker" || action == "youngLate" ||
      action == "youngMalformed" || action == "youngSecret" || action == "youngCache" ||
      action == "youngServiceWorker" || action == "youngOversizedRedirect")
    return L"void window.__youngFixture(" + ScriptString(Wide(action)) + L")";
  if (action == "nextDocument") return L"location.href='/next'";
  if (action == "authentication") return L"document.querySelector('#auth-link').click()";
  if (action == "submitAuthForm") return L"document.querySelector('#auth-form').requestSubmit()";
  if (action == "submitFrameAuthForm") return L"document.querySelector('#fixture-frame').contentDocument.querySelector('#auth-form').requestSubmit()";
  if (action == "frameNext") return L"document.querySelector('#fixture-frame').src='/frame-next'";
  if (action == "frameSecure") return L"(()=>{const f=document.querySelector('#fixture-frame');return !!f&&!!f.contentDocument&&f.contentWindow.location.origin===location.origin})()";
  if (action == "frameLate") return L"(()=>{const f=document.createElement('iframe');f.src='/frame-late';document.body.appendChild(f);const p=document.querySelector('#fixture-frame');const n=p.contentDocument.createElement('iframe');n.src='/frame-next';p.contentDocument.body.appendChild(n)})()";
  if (action == "redirectDenied") return L"location.href='" + initial_origin + L"/redirect-denied'";
  for (const auto* fixture_action : {"jwRefresh", "jwRouteChange", "jwSameUrlHistory", "jwCrossOrigin",
                                   "jwReplacePassword", "jwHidePassword", "jwManualContinue", "jwRenderForm"}) {
    if (action == fixture_action)
      return L"document.querySelector('#jw-fixture-" + Wide(action) + L"').click()";
  }
  return {};
}
#endif
}  // namespace

struct ObservationBridge::Impl {
  std::shared_ptr<Delivery> delivery = std::make_shared<Delivery>();
  std::shared_ptr<State> state;
  HWND owner;

  Impl(flutter::BinaryMessenger* messenger, HWND owner_window) : owner(owner_window) {
    delivery->channel = std::make_unique<Channel>(messenger,
        "ustc_assistant/observation_v1", &flutter::StandardMethodCodec::GetInstance());
    delivery->channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> raw_result) {
        Handle(call, std::shared_ptr<Result>(std::move(raw_result)));
      });
  }

  ~Impl() {
    delivery->alive = false;
    delivery->channel->SetMethodCallHandler(nullptr);
    if (state) {
      state->open_result.reset();
      state->Close();
    }
    delivery->channel.reset();
  }

  void Handle(const flutter::MethodCall<Value>& call, std::shared_ptr<Result> result) {
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto session = Integer(Field(args, "session"));
    if (!session || *session <= 0) { Error(result, "invalidSnapshot"); return; }
    const auto& method = call.method_name();
    const bool is_probe = method == "readJwProbe" || method == "pollJwProbe" ||
        method == "cancelJwProbe";
    const bool is_data_probe = method == "readJwDataProbe" || method == "pollJwDataProbe" ||
        method == "cancelJwDataProbe";
    const bool is_collection = method == "readJwCollection" || method == "pollJwCollection" ||
        method == "cancelJwCollection";
    const bool start_data = method == "readJwDataProbe" || method == "readJwCollection";
    const bool is_young_login = method == "advanceYoungLogin" || method == "submitYoungLogin";
    const bool is_login = is_young_login || method == "advanceJwLogin" || method == "submitJwLogin";
    const bool submit_login = method == "submitJwLogin" || method == "submitYoungLogin";
    const bool is_young_read = method == "startYoungReadOnly" ||
        method == "readYoungReadOnly" || method == "stopYoungReadOnly";
    const bool is_young_business = method == "startYoungBusiness" || method == "dispatchYoungBusinessStep" ||
        method == "pollYoungBusinessStep" || method == "finishYoungBusiness";
    const bool dispatch_young = method == "dispatchYoungBusinessStep";
    if (is_young_business) {
      const size_t expected = dispatch_young ? (Field(args, "day") ? 7 : 6) :
          method == "pollYoungBusinessStep" ? 4 : 3;
      if (!args || args->size() != expected || !Field(args, "document") || !Field(args, "operation") ||
          ((dispatch_young || method == "pollYoungBusinessStep") && !Field(args, "step")) ||
          (dispatch_young && (!Field(args, "endpoint") || !Field(args, "page")))) {
        Error(result, "invalidSnapshot"); return;
      }
    }
    if (is_young_read && (!args || args->size() != 3 || !Field(args, "session") ||
        !Field(args, "document") || !Field(args, "operation"))) {
      Error(result, "invalidSnapshot"); return;
    }
    if (is_login && (!args || args->size() != (submit_login ? 4 : 3) ||
        !Field(args, "session") || !Field(args, "document") || !Field(args, "operation") ||
        (submit_login && !Field(args, "credentialBytes")))) {
      Error(result, "invalidSnapshot"); return;
    }
    if ((is_probe || is_data_probe || is_collection) && (!args || args->size() != (start_data ? 4 : 3) ||
        !Field(args, "session") || !Field(args, "document") || !Field(args, "operation") ||
        (start_data && !Field(args, "semesterId")))) {
      Error(result, "invalidSnapshot"); return;
    }
    if ((method == "navigateJwPage" || method == "navigateYoungBusinessPage" ||
        method == "prepareYoungBusinessPage") && (!args || args->size() != 3 ||
        !Field(args, "session") || !Field(args, "document") || !Field(args, "page"))) {
      Error(result, "invalidSnapshot"); return;
    }
    if (method == "open") {
      if (state && !state->Drained()) { Error(result, "busy"); return; }
      const auto* profile = Text(Field(args, "profilePath"));
      auto next = std::make_shared<State>(delivery);
      next->session = *session;
      if (!profile || Wide(*profile).empty() || PathIsRelativeW(Wide(*profile).c_str()) ||
          profile->find('\0') != std::string::npos ||
          !ValidTarget(args, next.get())) { Error(result, "invalidSnapshot"); return; }
      state = next;
      state->open_result = result;
      if (!CreateObservationWindow(state, owner)) { state->Fail(); return; }
      StartOpen(state, Wide(*profile));
      return;
    }
    if (!state || state->session != *session) { Error(result, "staleResult"); return; }
    if (is_young_read && !state->young_source) { Error(result, "invalidSnapshot"); return; }
    if ((is_young_business || method == "navigateYoungBusinessPage" ||
        method == "prepareYoungBusinessPage" || is_young_login) && !state->young_source) {
      Error(result, "invalidSnapshot"); return;
    }
    if (state->young_source && ((is_login && !is_young_login) || is_probe || is_data_probe || is_collection ||
        method == "navigateJwPage")) {
      Error(result, "invalidSnapshot"); return;
    }
    if (method == "close") {
      if (state->Close()) result->Success(); else Error(result, "cleanupPending");
      return;
    }
    if (method == "drained") { result->Success(Value(state->Drained())); return; }
    if (state->closing || state->user_closed) { Error(result, "closed"); return; }
    if (state->recovery_only) { Error(result, "invalidSnapshot"); return; }
    if (!state->configured || !state->core) { Error(result, "busy"); return; }
    if (method == "navigateInitial") {
      if (state->pending_operations != 0) { Error(result, "busy"); return; }
      state->ClearLoginCapability();
      state->PrepareLauncher(state->initial_url);
      if (FAILED(state->core->Navigate(state->initial_url.c_str()))) {
        Error(result, "sourceFailed"); state->Fail();
      } else result->Success();
      return;
    }
    const auto document = Integer(Field(args, "document"));
    if (!document || *document != state->document) { Error(result, "staleResult"); return; }
    if (method == "inspectYoungPage") {
      if (!args || args->size() != 2) { Error(result, "invalidSnapshot"); return; }
      state->InspectYoung(result, *document); return;
    }
    if (method == "checkYoungProjectionFixture") {
#ifdef _DEBUG
      if (!state->test_mode || !state->young_source || !args || args->size() != 2 ||
          !state->YoungReadContext(*document)) { Error(result, "invalidSnapshot"); return; }
      result->Success(Value(young_probe::RunYoungProjectionSelfTests() &&
          young_probe::ReadOnlyObserver::RunAdmissionSelfTests()));
#else
      Error(result, "unsupportedPlatform");
#endif
      return;
    }
    if (is_young_read) {
      const auto operation = Integer(Field(args, "operation"));
      if (!operation || *operation <= 0 || *operation > 9007199254740991LL) {
        Error(result, "invalidSnapshot"); return;
      }
      state->YoungRead(result, method, *document, *operation); return;
    }
    if (is_young_business) {
      const auto operation = Integer(Field(args, "operation"));
      const auto step = Integer(Field(args, "step"));
      if (!operation || *operation <= 0 || *operation > 9007199254740991LL ||
          ((dispatch_young || method == "pollYoungBusinessStep") && (!step || *step <= 0 || *step > 64000))) {
        Error(result, "invalidSnapshot"); return;
      }
      young_probe::Endpoint endpoint = young_probe::Endpoint::profile;
      int page = 0;
      std::wstring day;
      if (dispatch_young) {
        const auto* label = Text(Field(args, "endpoint"));
        const auto requested_page = Integer(Field(args, "page"));
        const auto* requested_day = Text(Field(args, "day"));
        if (!label || (*label != "profile" && *label != "schedule" && *label != "activities") ||
            !requested_page || *requested_page < 0 || *requested_page > 1000 ||
            (Field(args, "day") && !requested_day)) { Error(result, "invalidSnapshot"); return; }
        endpoint = *label == "profile" ? young_probe::Endpoint::profile :
            *label == "schedule" ? young_probe::Endpoint::schedule : young_probe::Endpoint::activities;
        page = static_cast<int>(*requested_page);
        day = requested_day ? Wide(*requested_day) : L"";
      }
      state->YoungBusiness(result, method, *document, *operation, step.value_or(0), endpoint, page, day); return;
    }
    if (method == "navigateYoungBusinessPage" || method == "prepareYoungBusinessPage") {
      const auto* page = Text(Field(args, "page"));
      const wchar_t* path = page && *page == "activities" ? L"/login/sc-wisdom-group-learning/myproject/SignUp" :
          page && *page == "calendar" ? L"/login/sc-wisdom-group-learning/personalInformation/mySchedule" : nullptr;
      if (!path) { Error(result, "invalidSnapshot"); return; }
      if (method == "prepareYoungBusinessPage") {
        state->PrepareYoungBusiness(result, *document, path); return;
      }
      if (!state->YoungReadContext(*document) || state->pending_operations != 0 ||
          (state->young_observer && state->young_observer->Busy())) { Error(result, "busy"); return; }
      if (state->young_observer && !state->young_observer->Invalidate()) { Error(result, "cleanupPending"); return; }
      const auto destination = state->probe_origin + path;
      if (FAILED(state->core->Navigate(destination.c_str()))) { Error(result, "sourceFailed"); state->Fail(); }
      else result->Success();
      return;
    }
    if (method == "navigateJwPage") {
      const auto* page = Text(Field(args, "page"));
      const wchar_t* path = page && *page == "courseTable" ? L"/for-std/course-table" :
          page && *page == "examArrange" ? L"/for-std/exam-arrange" : nullptr;
      if (!path) { Error(result, "invalidSnapshot"); return; }
      if (!state->ProbeContext(*document) || state->pending_operations != 0) {
        Error(result, "busy"); return;
      }
      // Same WebView/profile, fixed source origin and launchers. The school
      // resolves its own detail ID through the existing per-hop navigation gate.
      const std::wstring destination = state->probe_origin + path;
      state->ClearLoginCapability();
      state->PrepareLauncher(destination);
      if (FAILED(state->core->Navigate(destination.c_str()))) {
        Error(result, "sourceFailed"); state->Fail();
      } else result->Success();
      return;
    }
    if (method == "inspect") { state->CheckReady(result, document); return; }
    if (is_login) {
      const auto operation = Integer(Field(args, "operation"));
      if (!operation || *operation <= 0 || *operation > 9007199254740991LL) {
        Error(result, "invalidSnapshot"); return;
      }
      if (submit_login) {
        const auto* raw = Field(args, "credentialBytes");
        const auto* bytes = raw ? std::get_if<std::vector<uint8_t>>(raw) : nullptr;
        if (!bytes) { Error(result, "invalidSnapshot"); return; }
        state->SubmitLogin(result, *document, *operation, *bytes);
      } else state->AdvanceLogin(result, *document, *operation);
      return;
    }
    if (is_probe || is_data_probe || is_collection) {
      const auto operation = Integer(Field(args, "operation"));
      if (!operation || *operation <= 0 || *operation > 9007199254740991LL) {
        Error(result, "invalidSnapshot"); return;
      }
      int64_t semester = 0;
      if (start_data) {
        const auto value = Integer(Field(args, "semesterId"));
        if (!value || *value <= 0 || *value > 2147483647) {
          Error(result, "invalidSnapshot"); return;
        }
        semester = *value;
      }
      const bool starting = method == "readJwProbe" || start_data;
      if (!starting && (state->probe_data != (is_data_probe || is_collection) ||
          state->probe_collect != is_collection)) {
        Error(result, "invalidSnapshot"); return;
      }
      state->Probe(result, method == "readJwCollection" ? "collect" :
          start_data ? "data" : method == "readJwProbe" ? "start" :
          method == "pollJwProbe" || method == "pollJwDataProbe" || method == "pollJwCollection" ? "poll" : "cancel",
          *document, *operation, semester);
      return;
    }
    if (method == "exerciseFixture") {
#ifdef _DEBUG
      const auto* action = Text(Field(args, "action"));
      const auto initial_origin = Origin(state->initial_url);
      const auto script = action && initial_origin
          ? FixtureScript(*action, state->fixture_denied_url, *initial_origin) : L"";
      const auto origin = state->CurrentOrigin();
      const bool user_close = action && *action == "userClose";
      if (!state->test_mode || !origin || !state->ready || (script.empty() && !user_close)) {
        Error(result, "invalidSnapshot"); return;
      }
      if (user_close) {
        if (state->window && PostMessage(state->window, WM_CLOSE, 0, 0)) result->Success();
        else Error(result, "sourceFailed");
        return;
      }
      ++state->pending_scripts;
      auto current = state;
      const bool verify_frame = action && *action == "frameSecure";
      const HRESULT hr = current->core->ExecuteScript(script.c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [current, result, verify_frame](HRESULT completion, LPCWSTR json) -> HRESULT {
            --current->pending_scripts;
            if (!current->Alive()) return S_OK;
            if (current->closing) Error(result, "staleResult");
            else if (FAILED(completion)) Error(result, "sourceFailed");
            else if (verify_frame && (!json || std::wstring(json) != L"true")) Error(result, "invalidSnapshot");
            else result->Success();
            return S_OK;
          }).Get());
      if (FAILED(hr)) {
        --current->pending_scripts;
        Error(result, "sourceFailed");
      }
#else
      Error(result, "unsupportedPlatform");
#endif
      return;
    }
    Error(result, "invalidSnapshot");
  }
};

ObservationBridge::ObservationBridge(flutter::BinaryMessenger* messenger, HWND owner)
    : impl_(std::make_unique<Impl>(messenger, owner)) {}
ObservationBridge::~ObservationBridge() = default;
