#ifndef RUNNER_DEFAULT_AUDIO_INPUT_H_
#define RUNNER_DEFAULT_AUDIO_INPUT_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>

#include <memory>

namespace default_audio_input_internal {

constexpr char kMethodName[] = "getDefaultInputId";

enum class CallDisposition {
  kGetDefaultInputId,
  kInvalidArguments,
  kUnknownMethod,
};

// StandardMethodCodec decodes a wire-level null argument into a non-null
// EncodableValue holding std::monostate. Directly constructed MethodCalls may
// still have a null arguments pointer, so both forms represent no arguments.
inline CallDisposition ClassifyCall(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  if (call.method_name() != kMethodName) {
    return CallDisposition::kUnknownMethod;
  }
  const auto* arguments = call.arguments();
  return arguments == nullptr || arguments->IsNull()
             ? CallDisposition::kGetDefaultInputId
             : CallDisposition::kInvalidArguments;
}

}  // namespace default_audio_input_internal

class DefaultAudioInputBridge {
 public:
  explicit DefaultAudioInputBridge(flutter::BinaryMessenger* messenger);
  ~DefaultAudioInputBridge();

  DefaultAudioInputBridge(const DefaultAudioInputBridge&) = delete;
  DefaultAudioInputBridge& operator=(const DefaultAudioInputBridge&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DEFAULT_AUDIO_INPUT_H_
