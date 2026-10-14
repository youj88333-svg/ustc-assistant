#include "default_audio_input.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <cstddef>
#include <memory>
#include <string>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
using Channel = flutter::MethodChannel<Value>;

constexpr char kChannelName[] = "ustc_assistant/default_audio_input";
constexpr char kMethodName[] = "getDefaultInputId";
constexpr char kFailureCode[] = "microphoneUnavailable";
constexpr char kFailureMessage[] = "Microphone unavailable.";
constexpr std::size_t kMaximumEndpointIdLength = 1024;

struct CoTaskMemDeleter {
  void operator()(wchar_t* value) const noexcept {
    if (value) ::CoTaskMemFree(value);
  }
};

bool ReadDefaultAudioInputId(std::string* endpoint_id) {
  endpoint_id->clear();

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(enumerator.GetAddressOf()));
  if (FAILED(hr)) return false;

  ComPtr<IMMDevice> endpoint;
  hr = enumerator->GetDefaultAudioEndpoint(
      eCapture, eMultimedia, endpoint.GetAddressOf());
  if (FAILED(hr)) return false;

  LPWSTR raw_id = nullptr;
  hr = endpoint->GetId(&raw_id);
  const std::unique_ptr<wchar_t, CoTaskMemDeleter> owned_id(raw_id);
  if (FAILED(hr) || !owned_id) return false;

  std::size_t length = 0;
  while (length <= kMaximumEndpointIdLength &&
         owned_id.get()[length] != L'\0') {
    ++length;
  }
  if (length == 0 || length > kMaximumEndpointIdLength) return false;

  std::string ascii_id;
  ascii_id.reserve(length);
  for (std::size_t index = 0; index < length; ++index) {
    const auto character = static_cast<unsigned int>(owned_id.get()[index]);
    // Require printable non-space ASCII. This also rejects controls, whitespace,
    // DEL, and IDs the pinned plugin cannot round-trip through its UTF-8 path.
    if (character <= 0x20 || character > 0x7e) return false;
    ascii_id.push_back(static_cast<char>(character));
  }

  *endpoint_id = std::move(ascii_id);
  return true;
}

void ReturnUnavailable(std::unique_ptr<Result> result) {
  result->Error(kFailureCode, kFailureMessage);
}
}  // namespace

struct DefaultAudioInputBridge::Impl {
  explicit Impl(flutter::BinaryMessenger* messenger)
      : channel(std::make_unique<Channel>(
            messenger, kChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel->SetMethodCallHandler(
        [](const flutter::MethodCall<Value>& call,
           std::unique_ptr<Result> result) {
          if (call.method_name() != kMethodName) {
            result->NotImplemented();
            return;
          }
          if (call.arguments() != nullptr) {
            ReturnUnavailable(std::move(result));
            return;
          }

          std::string endpoint_id;
          if (!ReadDefaultAudioInputId(&endpoint_id)) {
            ReturnUnavailable(std::move(result));
            return;
          }
          result->Success(Value(std::move(endpoint_id)));
        });
  }

  ~Impl() {
    channel->SetMethodCallHandler(nullptr);
    channel.reset();
  }

  std::unique_ptr<Channel> channel;
};

DefaultAudioInputBridge::DefaultAudioInputBridge(
    flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}

DefaultAudioInputBridge::~DefaultAudioInputBridge() = default;
