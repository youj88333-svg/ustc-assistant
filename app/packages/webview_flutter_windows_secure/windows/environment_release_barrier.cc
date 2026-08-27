#include "environment_release_barrier.h"

#include <utility>

void EnvironmentReleaseBarrier::BrowserProcessStarted(
    uint32_t browser_process_id) {
  if (browser_process_id == 0) {
    // A zero PID is not a release identity.  Creation must fail before this
    // method is called when WebView2 cannot provide a trustworthy PID.
    return;
  }
  browser_process_started_ = true;
  newest_browser_process_id_ = browser_process_id;
  browser_process_exited_ = false;
}

void EnvironmentReleaseBarrier::BrowserProcessExited(
    uint32_t browser_process_id) {
  if (!browser_process_started_ || !newest_browser_process_id_.has_value() ||
      *newest_browser_process_id_ != browser_process_id) {
    return;
  }
  browser_process_exited_ = true;
  CompleteReadyWaiters();
}

void EnvironmentReleaseBarrier::SetLogicalReleaseReady(bool ready) {
  logical_release_ready_ = ready;
  CompleteReadyWaiters();
}

bool EnvironmentReleaseBarrier::IsReady() const {
  return logical_release_ready_ &&
         (!browser_process_started_ ||
          (newest_browser_process_id_.has_value() && browser_process_exited_));
}

void EnvironmentReleaseBarrier::Await(Waiter waiter) {
  if (IsReady()) {
    waiter();
    return;
  }
  waiters_.push_back(std::move(waiter));
}

void EnvironmentReleaseBarrier::CompleteReadyWaiters() {
  if (!IsReady() || waiters_.empty()) {
    return;
  }
  auto waiters = std::move(waiters_);
  waiters_.clear();
  for (auto& waiter : waiters) {
    waiter();
  }
}
