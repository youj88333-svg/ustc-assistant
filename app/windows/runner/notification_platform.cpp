#include "notification_platform.h"

#include <NotificationActivationCallback.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Notifications.h>

#include <algorithm>
#include <filesystem>
#include <mutex>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using winrt::Windows::Data::Xml::Dom::XmlDocument;
using winrt::Windows::UI::Notifications::ScheduledToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;
constexpr wchar_t kGroup[] = L"ustc-m6";
constexpr wchar_t kProtocolOwner[] = L"USTCNotificationOwner";

struct RegistryKey {
  HKEY value = nullptr;
  ~RegistryKey() { if (value) RegCloseKey(value); }
};

std::wstring GuidText(const GUID& id) {
  wchar_t text[40]{};
  StringFromGUID2(id, text, 40);
  return text;
}

HRESULT SetKeyText(HKEY key, const wchar_t* name, const std::wstring& value) {
  return HRESULT_FROM_WIN32(RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))));
}

HRESULT SetRegistryText(const std::wstring& path, const wchar_t* name,
                        const std::wstring& value) {
  RegistryKey key;
  const auto opened = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr,
      0, KEY_SET_VALUE, nullptr, &key.value, nullptr);
  if (opened != ERROR_SUCCESS) return HRESULT_FROM_WIN32(opened);
  return SetKeyText(key.value, name, value);
}

bool ValidScheme(const std::wstring& scheme) {
  return scheme.size() >= 3 && scheme.size() <= 64 &&
      scheme.front() >= L'a' && scheme.front() <= L'z' &&
      std::all_of(scheme.begin(), scheme.end(), [](wchar_t c) {
        return (c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'-';
      });
}

bool FixedProtocolArguments(const std::wstring& args) {
  return !args.empty() && args.size() <= 256 &&
      std::all_of(args.begin(), args.end(), [](wchar_t c) {
        return (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
            (c >= L'0' && c <= L'9') || c == L'-' || c == L'_' ||
            c == L' ' || c == L'{' || c == L'}';
      });
}

std::wstring ProtocolOwner(const NotificationIdentity& identity) {
  return identity.app_id + L"|" + GuidText(identity.activator);
}

bool OwnsProtocol(HKEY key, const NotificationIdentity& identity) {
  wchar_t owner[512]{};
  DWORD bytes = sizeof(owner);
  const auto result = RegGetValueW(key, nullptr, kProtocolOwner, RRF_RT_REG_SZ,
      nullptr, owner, &bytes);
  return result == ERROR_SUCCESS && ProtocolOwner(identity) == owner;
}

HRESULT RegisterProtocol(const NotificationIdentity& identity) {
  // Check the merged view too: do not shadow another machine/user handler.
  RegistryKey existing;
  const auto read = RegOpenKeyExW(HKEY_CLASSES_ROOT, identity.protocol_scheme.c_str(),
      0, KEY_QUERY_VALUE, &existing.value);
  if (read == ERROR_SUCCESS && !OwnsProtocol(existing.value, identity)) return E_ACCESSDENIED;
  if (read != ERROR_SUCCESS && read != ERROR_FILE_NOT_FOUND) return HRESULT_FROM_WIN32(read);
  const auto path = L"Software\\Classes\\" + identity.protocol_scheme;
  RegistryKey key;
  DWORD disposition = 0;
  const auto opened = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
      KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_CREATE_SUB_KEY, nullptr, &key.value, &disposition);
  if (opened != ERROR_SUCCESS) return HRESULT_FROM_WIN32(opened);
  if (disposition == REG_OPENED_EXISTING_KEY && !OwnsProtocol(key.value, identity))
    return E_ACCESSDENIED;
  HRESULT hr = SetKeyText(key.value, kProtocolOwner, ProtocolOwner(identity));
  if (FAILED(hr)) return hr;
  if (FAILED(hr = SetKeyText(key.value, nullptr, L"URL:USTC Assistant reminder"))) return hr;
  if (FAILED(hr = SetKeyText(key.value, L"URL Protocol", L""))) return hr;
  RegistryKey command;
  const auto created = RegCreateKeyExW(key.value, L"shell\\open\\command", 0, nullptr,
      0, KEY_SET_VALUE, nullptr, &command.value, nullptr);
  if (created != ERROR_SUCCESS) return HRESULT_FROM_WIN32(created);
  return SetKeyText(command.value, nullptr, L"\"" + identity.executable + L"\" " +
      identity.protocol_arguments + L" \"%1\"");
}

HRESULT RemoveProtocol(const NotificationIdentity& identity) {
  const auto path = L"Software\\Classes\\" + identity.protocol_scheme;
  RegistryKey key;
  const auto read = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0,
      KEY_QUERY_VALUE, &key.value);
  if (read == ERROR_FILE_NOT_FOUND) return S_OK;
  if (read != ERROR_SUCCESS) return HRESULT_FROM_WIN32(read);
  if (!OwnsProtocol(key.value, identity)) return E_ACCESSDENIED;
  const auto removed = RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str());
  return removed == ERROR_FILE_NOT_FOUND ? S_OK : HRESULT_FROM_WIN32(removed);
}

std::wstring EscapeXml(const std::wstring& value) {
  std::wstring result;
  for (const wchar_t c : value) {
    switch (c) {
      case L'&': result += L"&amp;"; break;
      case L'<': result += L"&lt;"; break;
      case L'>': result += L"&gt;"; break;
      case L'\"': result += L"&quot;"; break;
      case L'\'': result += L"&apos;"; break;
      default:
        if (c >= 0x20 || c == L'\n') result += c;
    }
  }
  return result;
}

bool Opaque(const std::wstring& value, size_t min, size_t max) {
  return value.size() >= min && value.size() <= max &&
      std::all_of(value.begin(), value.end(), [](wchar_t c) {
        return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') ||
            (c >= L'A' && c <= L'Z') || c == L'-' || c == L'_';
      });
}

std::wstring Launch(const NativeReminder& r, const std::wstring& scheme) {
  const auto prefix = scheme.empty() ? L"ustc-reminder/v1/" : scheme + L"://reminder/v1/";
  return prefix + r.id + L"/" + r.digest + L"/" + r.activation;
}

bool ParseMetadata(const std::wstring& value, const std::wstring& prefix,
                   size_t limit, NativeReminder* result) {
  if (!result || value.rfind(prefix, 0) != 0 || value.size() > limit) return false;
  const auto first = value.find(L'/', prefix.size());
  if (first == std::wstring::npos) return false;
  const auto second = value.find(L'/', first + 1);
  if (second == std::wstring::npos) return false;
  NativeReminder parsed;
  parsed.id = value.substr(prefix.size(), first - prefix.size());
  parsed.digest = value.substr(first + 1, second - first - 1);
  parsed.activation = value.substr(second + 1);
  if (!Opaque(parsed.id, 1, 16) || !Opaque(parsed.digest, 64, 64) ||
      !Opaque(parsed.activation, 16, 64)) return false;
  *result = std::move(parsed);
  return true;
}

bool ParseLaunch(const std::wstring& value, NativeReminder* result) {
  return ParseMetadata(value, L"ustc-reminder/v1/", 180, result);
}

class Activator : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                      INotificationActivationCallback> {
 public:
  Activator(std::wstring identity, std::function<void(std::wstring)> callback)
      : identity_(std::move(identity)), callback_(std::move(callback)) {}
  HRESULT STDMETHODCALLTYPE Activate(LPCWSTR identity, LPCWSTR args,
      const NOTIFICATION_USER_INPUT_DATA*, ULONG) override {
    try {
    if (!identity || identity_ != identity) return E_INVALIDARG;
    NativeReminder parsed;
    const std::wstring invocation = args ? args : L"";
    if (!ParseLaunch(invocation, &parsed)) return E_INVALIDARG;
    callback_(invocation);
    return S_OK;
    } catch (...) { return E_FAIL; }
  }
 private:
  std::wstring identity_;
  std::function<void(std::wstring)> callback_;
};

class Factory : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory> {
 public:
  Factory(std::wstring identity, std::function<void(std::wstring)> callback)
      : identity_(std::move(identity)), callback_(std::move(callback)) {}
  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid,
                                            void** object) override {
    if (outer) return CLASS_E_NOAGGREGATION;
    auto activator = Microsoft::WRL::Make<Activator>(identity_, callback_);
    return activator ? activator->QueryInterface(iid, object) : E_OUTOFMEMORY;
  }
  HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }
 private:
  std::wstring identity_;
  std::function<void(std::wstring)> callback_;
};

HRESULT Shortcut(const NotificationIdentity& identity, std::wstring* path) {
  PWSTR programs = nullptr;
  HRESULT hr = SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE,
                                   nullptr, &programs);
  if (FAILED(hr)) return hr;
  *path = std::wstring(programs) + L"\\" + identity.shortcut_name + L".lnk";
  CoTaskMemFree(programs);
  ComPtr<IShellLinkW> link;
  hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&link));
  if (FAILED(hr)) return hr;
  if (FAILED(hr = link->SetPath(identity.executable.c_str()))) return hr;
  const auto directory = identity.executable.substr(0, identity.executable.find_last_of(L"\\/"));
  if (FAILED(hr = link->SetWorkingDirectory(directory.c_str()))) return hr;
  link->SetDescription(identity.display_name.c_str());
  link->SetIconLocation(identity.executable.c_str(), 0);
  ComPtr<IPropertyStore> properties;
  if (FAILED(hr = link.As(&properties))) return hr;
  PROPVARIANT app_id;
  hr = InitPropVariantFromString(identity.app_id.c_str(), &app_id);
  if (FAILED(hr)) return hr;
  hr = properties->SetValue(PKEY_AppUserModel_ID, app_id);
  PropVariantClear(&app_id);
  if (FAILED(hr)) return hr;
  PROPVARIANT clsid;
  hr = InitPropVariantFromCLSID(identity.activator, &clsid);
  if (FAILED(hr)) return hr;
  hr = properties->SetValue(PKEY_AppUserModel_ToastActivatorCLSID, clsid);
  PropVariantClear(&clsid);
  if (FAILED(hr) || FAILED(hr = properties->Commit())) return hr;
  ComPtr<IPersistFile> file;
  if (FAILED(hr = link.As(&file))) return hr;
  return file->Save(path->c_str(), TRUE);
}
}  // namespace

bool ParseNativeNotificationActivation(const std::wstring& value,
    const std::wstring& scheme, NativeReminder* parsed) {
  return ValidScheme(scheme) && ParseMetadata(value,
      scheme + L"://reminder/v1/", 256, parsed);
}

struct WindowsNotificationPlatform::Impl {
  explicit Impl(NotificationIdentity value) : identity(std::move(value)) {}
  NotificationIdentity identity;
  std::wstring shortcut;
  DWORD class_cookie = 0;
  ComPtr<IClassFactory> factory;
  bool bootstrap_checked = false;
  bool registered = false;
};

WindowsNotificationPlatform::WindowsNotificationPlatform(NotificationIdentity i)
    : impl_(std::make_unique<Impl>(std::move(i))) {}
WindowsNotificationPlatform::~WindowsNotificationPlatform() {
  if (impl_->class_cookie) CoRevokeClassObject(impl_->class_cookie);
}

HRESULT WindowsNotificationPlatform::Register(
    std::function<void(std::wstring)> callback) {
  if (impl_->registered) return S_OK;
  const auto& i = impl_->identity;
  if (i.app_id.empty() || i.app_id.size() > 128 || i.executable.empty() ||
      i.executable.find_first_of(L"\"\r\n") != std::wstring::npos ||
      i.executable.find(L'\0') != std::wstring::npos ||
      !std::filesystem::path(i.executable).is_absolute() ||
      i.shortcut_name.find_first_of(L"\\/:*") != std::wstring::npos)
    return E_INVALIDARG;
  if (!i.protocol_scheme.empty() &&
      (!ValidScheme(i.protocol_scheme) || i.protocol_scheme.rfind(L"ustc-", 0) != 0 ||
       !FixedProtocolArguments(i.protocol_arguments))) return E_INVALIDARG;
  const auto clsid = GuidText(i.activator);
  HRESULT hr = S_OK;
  if (!i.protocol_scheme.empty() && FAILED(hr = RegisterProtocol(i))) return hr;
  hr = SetCurrentProcessExplicitAppUserModelID(i.app_id.c_str());
  if (FAILED(hr)) return hr;
  const auto identity_path = L"Software\\Classes\\AppUserModelId\\" + i.app_id;
  hr = SetRegistryText(identity_path, L"DisplayName", i.display_name);
  if (FAILED(hr)) return hr;
  if (FAILED(hr = SetRegistryText(identity_path, L"CustomActivator", clsid))) return hr;
  if (FAILED(hr = SetRegistryText(identity_path, L"IconUri", i.executable))) return hr;
  if (i.protocol_scheme.empty()) {
    const auto server = L"\"" + i.executable + L"\" " + i.server_arguments;
    const auto server_path = L"Software\\Classes\\CLSID\\" + clsid + L"\\LocalServer32";
    if (FAILED(hr = SetRegistryText(server_path, nullptr, server))) return hr;
    if (FAILED(hr = SetRegistryText(server_path, L"ServerExecutable", i.executable))) return hr;
  }
  if (FAILED(hr = Shortcut(i, &impl_->shortcut))) return hr;
  if (!i.protocol_scheme.empty()) {
    impl_->registered = true;
    return S_OK;
  }
  auto factory = Microsoft::WRL::Make<Factory>(i.app_id, std::move(callback));
  if (!factory) return E_OUTOFMEMORY;
  impl_->factory = factory;
  hr = CoRegisterClassObject(i.activator, impl_->factory.Get(),
      CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &impl_->class_cookie);
  impl_->registered = SUCCEEDED(hr);
  return hr;
}

HRESULT WindowsNotificationPlatform::EnsureScheduledIdentityReady() {
  if (!impl_->registered) return E_INVALIDARG;
  if (impl_->bootstrap_checked) return S_OK;
  try {
    const auto notifier = ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id);
    if (!impl_->bootstrap_checked) {
      const auto identity_path = L"Software\\Classes\\AppUserModelId\\" +
          impl_->identity.app_id;
      DWORD ready = 0;
      DWORD bytes = sizeof(ready);
      const auto read = RegGetValueW(HKEY_CURRENT_USER, identity_path.c_str(),
          L"ScheduledIdentityReady", RRF_RT_REG_DWORD, nullptr, &ready, &bytes);
      if (read != ERROR_SUCCESS || ready != 1) {
        // Unpackaged first schedule needs OS identity registration. This is a
        // silent, suppressed, short-lived bootstrap, never a manual preheat.
        XmlDocument bootstrap_xml;
        bootstrap_xml.LoadXml(L"<toast><visual><binding template=\"ToastGeneric\">"
            L"<text>USTC Assistant</text></binding></visual><audio silent=\"true\"/></toast>");
        auto bootstrap = winrt::Windows::UI::Notifications::ToastNotification(bootstrap_xml);
        bootstrap.Tag(L"bootstrap");
        bootstrap.Group(kGroup);
        bootstrap.SuppressPopup(true);
        bootstrap.ExpirationTime(winrt::clock::now() + std::chrono::seconds(15));
        notifier.Show(bootstrap);
        ToastNotificationManager::History().Remove(L"bootstrap", kGroup,
                                                   impl_->identity.app_id);
        HKEY key = nullptr;
        const auto opened = RegOpenKeyExW(HKEY_CURRENT_USER, identity_path.c_str(),
            0, KEY_SET_VALUE, &key);
        if (opened != ERROR_SUCCESS) return HRESULT_FROM_WIN32(opened);
        ready = 1;
        const auto written = RegSetValueExW(key, L"ScheduledIdentityReady", 0,
            REG_DWORD, reinterpret_cast<const BYTE*>(&ready), sizeof(ready));
        RegCloseKey(key);
        if (written != ERROR_SUCCESS) return HRESULT_FROM_WIN32(written);
      }
      impl_->bootstrap_checked = true;
    }
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::Schedule(const NativeReminder& r) {
  if (!impl_->registered || !Opaque(r.id, 1, 16) ||
      !Opaque(r.digest, 64, 64) || !Opaque(r.activation, 16, 64) ||
      r.title.empty() || r.title.size() > 160 || r.detail.size() > 240 ||
      r.location.size() > 160 || r.delivery_unix_ms <= 0 ||
      r.delivery_unix_ms > 32503680000000LL) return E_INVALIDARG;
  try {
    const HRESULT ready = EnsureScheduledIdentityReady();
    if (FAILED(ready)) return ready;
    XmlDocument xml;
    const auto& scheme = impl_->identity.protocol_scheme;
    const auto activation_type = scheme.empty() ? L"" : L" activationType=\"protocol\"";
    xml.LoadXml(L"<toast" + std::wstring(activation_type) + L" launch=\"" + EscapeXml(Launch(r, scheme)) +
        L"\"><visual><binding template=\"ToastGeneric\"><text>" +
        EscapeXml(r.title) + L"</text><text>" + EscapeXml(r.detail) +
        L"</text><text>" + EscapeXml(r.location) +
        L"</text></binding></visual></toast>");
    const winrt::Windows::Foundation::DateTime delivery(
        winrt::Windows::Foundation::TimeSpan((r.delivery_unix_ms +
                                             11644473600000LL) * 10000));
    auto toast = ScheduledToastNotification(xml, delivery);
    toast.Id(r.id);
    toast.Tag(r.id);
    toast.Group(kGroup);
    const auto notifier = ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id);
    // Replacement is deliberate: all old matching entries, not only the first.
    for (const auto& old : notifier.GetScheduledToastNotifications()) {
      if (old.Id() == r.id) notifier.RemoveFromSchedule(old);
    }
    notifier.AddToSchedule(toast);
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::Pending(std::vector<NativeReminder>* rows) {
  if (!rows || !impl_->registered) return E_INVALIDARG;
  rows->clear();
  try {
    const auto notifier = ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id);
    for (const auto& item : notifier.GetScheduledToastNotifications()) {
      NativeReminder r;
      const auto toast = item.Content().DocumentElement();
      const auto& scheme = impl_->identity.protocol_scheme;
      const std::wstring launch(toast.GetAttribute(L"launch"));
      const bool parsed = scheme.empty() ? ParseLaunch(launch, &r) :
          (toast.GetAttribute(L"activationType") == L"protocol" &&
           ParseNativeNotificationActivation(launch, scheme, &r));
      if (!parsed ||
          r.id != item.Id() || item.Tag() != r.id || item.Group() != kGroup) return E_UNEXPECTED;
      const auto text = item.Content().SelectNodes(
          L"/toast/visual/binding[@template='ToastGeneric']/text");
      if (text.Size() != 3) return E_UNEXPECTED;
      r.title = text.GetAt(0).InnerText();
      r.detail = text.GetAt(1).InnerText();
      r.location = text.GetAt(2).InnerText();
      if (r.title.empty() || r.title.size() > 160 || r.detail.size() > 240 ||
          r.location.size() > 160) return E_UNEXPECTED;
      r.delivery_unix_ms = item.DeliveryTime().time_since_epoch().count() / 10000 -
          11644473600000LL;
      rows->push_back(std::move(r));
      if (rows->size() > 1024) return E_BOUNDS;
    }
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::Cancel(const std::wstring& id) {
  if (!Opaque(id, 1, 16) || !impl_->registered) return E_INVALIDARG;
  try {
    const auto notifier = ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id);
    for (const auto& item : notifier.GetScheduledToastNotifications()) {
      if (item.Id() == id) notifier.RemoveFromSchedule(item);
    }
    const auto history = ToastNotificationManager::History();
    history.Remove(id, kGroup, impl_->identity.app_id);
    for (const auto& item : notifier.GetScheduledToastNotifications()) {
      if (item.Id() == id) return E_UNEXPECTED;
    }
    for (const auto& item : history.GetHistory(impl_->identity.app_id)) {
      if (item.Tag() == id && item.Group() == kGroup) return E_UNEXPECTED;
    }
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::CancelAll() {
  if (!impl_->registered) return E_INVALIDARG;
  try {
    const auto notifier = ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id);
    for (const auto& item : notifier.GetScheduledToastNotifications())
      notifier.RemoveFromSchedule(item);
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::ClearHistory() {
  try { ToastNotificationManager::History().Clear(impl_->identity.app_id); return S_OK; }
  catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::HistoryCount(uint32_t* count) {
  if (!count) return E_INVALIDARG;
  try {
    *count = ToastNotificationManager::History().GetHistory(
        impl_->identity.app_id).Size();
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::Setting(int32_t* setting) {
  if (!setting) return E_INVALIDARG;
  try {
    *setting = static_cast<int32_t>(ToastNotificationManager::CreateToastNotifier(
        impl_->identity.app_id).Setting());
    return S_OK;
  } catch (const winrt::hresult_error& error) { return error.code(); }
  catch (...) { return E_FAIL; }
}

HRESULT WindowsNotificationPlatform::RemoveRegistration() {
  HRESULT hr = CancelAll();
  if (FAILED(hr)) return hr;
  if (FAILED(hr = ClearHistory())) return hr;
  if (!impl_->identity.protocol_scheme.empty() &&
      FAILED(hr = RemoveProtocol(impl_->identity))) return hr;
  if (impl_->class_cookie) {
    CoRevokeClassObject(impl_->class_cookie);
    impl_->class_cookie = 0;
  }
  if (!impl_->shortcut.empty() && !DeleteFileW(impl_->shortcut.c_str()) &&
      GetLastError() != ERROR_FILE_NOT_FOUND) return HRESULT_FROM_WIN32(GetLastError());
  const auto clsid = L"Software\\Classes\\CLSID\\" + GuidText(impl_->identity.activator);
  const auto app = L"Software\\Classes\\AppUserModelId\\" + impl_->identity.app_id;
  const auto first = impl_->identity.protocol_scheme.empty() ?
      RegDeleteTreeW(HKEY_CURRENT_USER, clsid.c_str()) : ERROR_SUCCESS;
  const auto second = RegDeleteTreeW(HKEY_CURRENT_USER, app.c_str());
  if (first != ERROR_SUCCESS && first != ERROR_FILE_NOT_FOUND) return HRESULT_FROM_WIN32(first);
  if (second != ERROR_SUCCESS && second != ERROR_FILE_NOT_FOUND) return HRESULT_FROM_WIN32(second);
  impl_->registered = false;
  return S_OK;
}
