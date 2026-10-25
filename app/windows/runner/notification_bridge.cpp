#include "notification_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <exception>
#include <initializer_list>
#include <utility>

#include "notification_activation.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
using Channel = flutter::MethodChannel<Value>;

bool NoArguments(const Value* arguments) {
  return !arguments || arguments->IsNull();
}

const Map* Shape(const Value* arguments,
                 std::initializer_list<const char*> fields) {
  if (!arguments) return nullptr;
  const auto* map = std::get_if<Map>(arguments);
  if (!map || map->size() != fields.size()) return nullptr;
  for (const auto* field : fields) {
    if (map->find(Value(field)) == map->end()) return nullptr;
  }
  return map;
}

bool ReadText(const Map& map, const char* key, size_t maximum,
              std::wstring* output) {
  const auto* text = std::get_if<std::string>(&map.at(Value(key)));
  if (!text || text->size() > maximum * 4 ||
      text->find('\0') != std::string::npos) return false;
  if (text->empty()) { output->clear(); return true; }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text->data(), static_cast<int>(text->size()), nullptr, 0);
  if (length <= 0 || static_cast<size_t>(length) > maximum) return false;
  output->resize(length);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
      static_cast<int>(text->size()), output->data(), length) == length;
}

bool Opaque(const std::wstring& value, size_t minimum, size_t maximum) {
  return value.size() >= minimum && value.size() <= maximum &&
      std::all_of(value.begin(), value.end(), [](wchar_t c) {
        return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') ||
            (c >= L'A' && c <= L'Z') || c == L'-' || c == L'_';
      });
}

bool DisplayText(const std::wstring& text) {
  return std::all_of(text.begin(), text.end(), [](wchar_t c) {
    return (c >= 0x20 && c != 0xFFFE && c != 0xFFFF) || c == L'\n';
  });
}

bool ParseReminder(const Value* arguments, NativeReminder* reminder) {
  const auto* map = Shape(arguments, {"id", "deliveryAtUnixMs", "digest", "token",
                                     "title", "detail", "location"});
  if (!map) return false;
  const auto& time = map->at(Value("deliveryAtUnixMs"));
  if (const auto* value64 = std::get_if<int64_t>(&time))
    reminder->delivery_unix_ms = *value64;
  else if (const auto* value32 = std::get_if<int32_t>(&time))
    reminder->delivery_unix_ms = *value32;
  else return false;
  return reminder->delivery_unix_ms > 0 &&
      reminder->delivery_unix_ms <= 32503680000000LL &&
      ReadText(*map, "id", 16, &reminder->id) &&
      Opaque(reminder->id, 1, 16) &&
      ReadText(*map, "digest", 64, &reminder->digest) &&
      Opaque(reminder->digest, 64, 64) &&
      ReadText(*map, "token", 64, &reminder->activation) &&
      Opaque(reminder->activation, 16, 64) &&
      ReadText(*map, "title", 160, &reminder->title) &&
      !reminder->title.empty() && DisplayText(reminder->title) &&
      ReadText(*map, "detail", 240, &reminder->detail) &&
      DisplayText(reminder->detail) &&
      ReadText(*map, "location", 160, &reminder->location) &&
      DisplayText(reminder->location);
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (count <= 0) throw std::exception();
  std::string result(count, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), result.data(), count, nullptr, nullptr) != count)
    throw std::exception();
  return result;
}

Map ActivationValue(const NativeReminder& reminder) {
  return {{Value("id"), Value(Utf8(reminder.id))},
          {Value("digest"), Value(Utf8(reminder.digest))},
          {Value("token"), Value(Utf8(reminder.activation))}};
}

Map PendingValue(const NativeReminder& reminder) {
  auto result = ActivationValue(reminder);
  result.emplace(Value("deliveryAtUnixMs"), Value(reminder.delivery_unix_ms));
  result.emplace(Value("title"), Value(Utf8(reminder.title)));
  result.emplace(Value("detail"), Value(Utf8(reminder.detail)));
  result.emplace(Value("location"), Value(Utf8(reminder.location)));
  return result;
}

bool SameReminder(const NativeReminder& a, const NativeReminder& b) {
  return a.id == b.id && a.delivery_unix_ms == b.delivery_unix_ms &&
      a.digest == b.digest && a.activation == b.activation &&
      a.title == b.title && a.detail == b.detail && a.location == b.location;
}

void Error(Result& result, const char* code) {
  result.Error(code, "Windows notification operation could not be completed.");
}
}  // namespace

struct NotificationBridge::Impl {
  Impl(flutter::BinaryMessenger* messenger, NotificationActivationHub& hub,
       bool synthetic_host)
      : activations(hub), test_host(synthetic_host),
        channel(std::make_unique<Channel>(messenger, "ustc_assistant/notifications",
                                         &flutter::StandardMethodCodec::GetInstance())) {
    channel->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                                        std::unique_ptr<Result> result) {
      try { Handle(call, *result); }
      catch (...) { Error(*result, "platformUnavailable"); }
    });
  }

  ~Impl() {
    channel->SetMethodCallHandler(nullptr);
    platform.reset();
  }

  void Handle(const flutter::MethodCall<Value>& call, Result& result) {
    const auto& method = call.method_name();
    const auto* args = call.arguments();
    if (method != "schedule" && method != "cancel" && !NoArguments(args)) {
      Error(result, "invalidInput"); return;
    }
    if (method == "close") {
      platform.reset();
      activations.Close();
      closed = true;
      result.Success();
      return;
    }
    if (closed) { Error(result, "closed"); return; }
    if (method == "initialize") {
      if (test_host) {
        result.Success(Value(Map{{Value("available"), Value(false)},
          {Value("enabledBySystem"), Value(false)},
          {Value("schedulesAfterExit"), Value(false)},
          {Value("activationAvailable"), Value(false)}}));
        return;
      }
      if (!platform) {
        auto candidate = std::make_unique<WindowsNotificationPlatform>(
            ProductionNotificationIdentity());
        if (FAILED(candidate->Register([](std::wstring) {})) ||
            FAILED(candidate->EnsureScheduledIdentityReady())) {
          Error(result, "platformUnavailable"); return;
        }
        platform = std::move(candidate);
      }
      int32_t setting = -1;
      if (FAILED(platform->Setting(&setting))) {
        Error(result, "platformUnavailable"); return;
      }
      result.Success(Value(Map{{Value("available"), Value(true)},
        {Value("enabledBySystem"), Value(setting == 0)},
        {Value("schedulesAfterExit"), Value(true)},
        {Value("activationAvailable"), Value(true)}}));
      return;
    }
    if (method == "activations") {
      List values;
      for (const auto& item : activations.Drain()) values.emplace_back(ActivationValue(item));
      result.Success(Value(std::move(values)));
      return;
    }
    if (method != "pending" && method != "schedule" && method != "cancel" &&
        method != "clear") { result.NotImplemented(); return; }
    if (!platform) { Error(result, "platformUnavailable"); return; }
    if (method == "pending") {
      std::vector<NativeReminder> pending;
      if (FAILED(platform->Pending(&pending))) {
        Error(result, "platformUnavailable"); return;
      }
      List values;
      for (const auto& item : pending) values.emplace_back(PendingValue(item));
      result.Success(Value(std::move(values)));
      return;
    }
    if (method == "schedule") {
      NativeReminder reminder;
      if (!ParseReminder(args, &reminder)) { Error(result, "invalidInput"); return; }
      int32_t setting = -1;
      if (FAILED(platform->Setting(&setting))) {
        Error(result, "platformUnavailable"); return;
      }
      if (setting != 0) { Error(result, "disabledBySystem"); return; }
      std::vector<NativeReminder> pending;
      if (FAILED(platform->Schedule(reminder)) || FAILED(platform->Pending(&pending)) ||
          std::count_if(pending.begin(), pending.end(), [&](const auto& item) {
            return item.id == reminder.id;
          }) != 1 ||
          std::none_of(pending.begin(), pending.end(), [&](const auto& item) {
            return SameReminder(item, reminder);
          })) {
        Error(result, "publishFailed"); return;
      }
      result.Success();
      return;
    }
    if (method == "cancel") {
      const auto* map = Shape(args, {"id"});
      std::wstring id;
      if (!map || !ReadText(*map, "id", 16, &id) || !Opaque(id, 1, 16)) {
        Error(result, "invalidInput"); return;
      }
      if (FAILED(platform->Cancel(id))) { Error(result, "cancelFailed"); return; }
      result.Success();
      return;
    }
    std::vector<NativeReminder> pending;
    uint32_t history = 0;
    if (FAILED(platform->CancelAll()) || FAILED(platform->ClearHistory()) ||
        FAILED(platform->Pending(&pending)) || !pending.empty() ||
        FAILED(platform->HistoryCount(&history)) || history != 0) {
      Error(result, "cleanupPending"); return;
    }
    result.Success();
  }

  NotificationActivationHub& activations;
  bool test_host;
  bool closed = false;
  std::unique_ptr<Channel> channel;
  std::unique_ptr<WindowsNotificationPlatform> platform;
};

NotificationBridge::NotificationBridge(flutter::BinaryMessenger* messenger,
    NotificationActivationHub& activations, bool test_host)
    : impl_(std::make_unique<Impl>(messenger, activations, test_host)) {}
NotificationBridge::~NotificationBridge() = default;
