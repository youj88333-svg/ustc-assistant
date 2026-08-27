#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

// Coordinates the logical controller count with WebView2's asynchronous
// BrowserProcessExited signal.  A release is safe only after both boundaries
// have been observed.  This class deliberately has no Flutter or COM
// dependency so event ordering and waiter ownership remain unit-testable.
class EnvironmentReleaseBarrier {
 public:
  using Waiter = std::function<void()>;

  // Marks that a controller has caused a browser process to be expected for
  // this environment generation.  The PID is the generation identity: a
  // later generation must call this again, and an exit for an older PID is
  // ignored.
  void BrowserProcessStarted(uint32_t browser_process_id);

  // Marks the matching browser process and its associated WebView2 resources
  // as gone.  Repeated notifications and stale PID notifications are
  // harmless; an unknown PID never releases the barrier.
  void BrowserProcessExited(uint32_t browser_process_id);

  // Updates the independent logical ownership condition.  Waiters are
  // completed only when this is true and BrowserProcessExited has arrived
  // after a process was started.  A failed controller creation does not call
  // BrowserProcessStarted, so it leaves this barrier free for logical
  // reconfiguration.  Physical UDF deletion remains fail-closed in the
  // owning store when no trustworthy process PID was observed.
  void SetLogicalReleaseReady(bool ready);

  bool IsReady() const;

  // Completes immediately when already ready, otherwise queues exactly one
  // completion for this waiter.
  void Await(Waiter waiter);

 private:
  void CompleteReadyWaiters();

  bool logical_release_ready_ = true;
  bool browser_process_started_ = false;
  std::optional<uint32_t> newest_browser_process_id_;
  bool browser_process_exited_ = false;
  std::vector<Waiter> waiters_;
};
