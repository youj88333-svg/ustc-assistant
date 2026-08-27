#include "environment_lifecycle.h"

bool EnvironmentLifecycle::CanConfigure() const {
  return pending_creations_ == 0 && active_controllers_ == 0;
}

bool EnvironmentLifecycle::ShouldReleaseEnvironment() const {
  return CanConfigure();
}

void EnvironmentLifecycle::BeginCreation() { ++pending_creations_; }

bool EnvironmentLifecycle::CompleteCreation(bool created_controller) {
  if (pending_creations_ == 0) {
    return false;
  }
  --pending_creations_;
  if (created_controller) {
    ++active_controllers_;
  }
  return true;
}

bool EnvironmentLifecycle::DisposeController() {
  if (active_controllers_ == 0) {
    return false;
  }
  --active_controllers_;
  return true;
}
