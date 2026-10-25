#ifndef RUNNER_OBSERVATION_BRIDGE_H_
#define RUNNER_OBSERVATION_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <memory>
#include <windows.h>

// Owns only native observation resources. Profile ownership and deletion belong
// to Dart; this bridge never reads or deletes browser session files.
// The JW candidate probe is a closed native operation with private projection
// results, separate from browser events and from a verified source contract.
class ObservationBridge {
 public:
  ObservationBridge(flutter::BinaryMessenger* messenger, HWND owner);
  ~ObservationBridge();
  ObservationBridge(const ObservationBridge&) = delete;
  ObservationBridge& operator=(const ObservationBridge&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_OBSERVATION_BRIDGE_H_
