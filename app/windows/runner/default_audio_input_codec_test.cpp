#include "default_audio_input.h"

#include <flutter/standard_method_codec.h>

#include <iostream>
#include <memory>
#include <string>
#include <utility>

namespace {
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::StandardMethodCodec;
using default_audio_input_internal::CallDisposition;

bool RoundTrip(const MethodCall<EncodableValue>& input,
               std::unique_ptr<MethodCall<EncodableValue>>* output) {
  const auto& codec = StandardMethodCodec::GetInstance();
  const auto encoded = codec.EncodeMethodCall(input);
  if (!encoded) return false;
  *output = codec.DecodeMethodCall(*encoded);
  return *output != nullptr;
}

bool Check(bool condition) {
  if (!condition) std::cerr << "default audio input codec regression failed\n";
  return condition;
}

bool TestNullArgumentWireSemantics() {
  MethodCall<EncodableValue> call(
      default_audio_input_internal::kMethodName, nullptr);
  std::unique_ptr<MethodCall<EncodableValue>> decoded;
  if (!Check(RoundTrip(call, &decoded))) return false;

  const auto* arguments = decoded->arguments();
  return Check(arguments != nullptr) && Check(arguments->IsNull()) &&
         Check(default_audio_input_internal::ClassifyCall(*decoded) ==
               CallDisposition::kGetDefaultInputId);
}

bool TestDirectNullPointerIsAccepted() {
  MethodCall<EncodableValue> call(
      default_audio_input_internal::kMethodName, nullptr);
  return Check(default_audio_input_internal::ClassifyCall(call) ==
               CallDisposition::kGetDefaultInputId);
}

bool TestNonNullArgumentIsRejected() {
  auto argument = std::make_unique<EncodableValue>(std::string("unexpected"));
  MethodCall<EncodableValue> call(
      default_audio_input_internal::kMethodName, std::move(argument));
  std::unique_ptr<MethodCall<EncodableValue>> decoded;
  if (!Check(RoundTrip(call, &decoded))) return false;

  return Check(decoded->arguments() != nullptr) &&
         Check(!decoded->arguments()->IsNull()) &&
         Check(default_audio_input_internal::ClassifyCall(*decoded) ==
               CallDisposition::kInvalidArguments);
}

bool TestUnknownMethodRemainsUnknown() {
  MethodCall<EncodableValue> call("unexpectedMethod", nullptr);
  std::unique_ptr<MethodCall<EncodableValue>> decoded;
  if (!Check(RoundTrip(call, &decoded))) return false;

  return Check(default_audio_input_internal::ClassifyCall(*decoded) ==
               CallDisposition::kUnknownMethod);
}
}  // namespace

int main() {
  return TestNullArgumentWireSemantics() && TestDirectNullPointerIsAccepted() &&
                 TestNonNullArgumentIsRejected() &&
                 TestUnknownMethodRemainsUnknown()
             ? 0
             : 1;
}
