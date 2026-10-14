#ifndef RUNNER_DEFAULT_AUDIO_INPUT_H_
#define RUNNER_DEFAULT_AUDIO_INPUT_H_

#include <flutter/binary_messenger.h>

#include <memory>

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
