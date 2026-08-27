#pragma once

#include <cstddef>

class EnvironmentLifecycle {
 public:
  bool CanConfigure() const;
  bool ShouldReleaseEnvironment() const;

  void BeginCreation();
  bool CompleteCreation(bool created_controller);
  bool DisposeController();

  std::size_t pending_creations() const { return pending_creations_; }
  std::size_t active_controllers() const { return active_controllers_; }

 private:
  std::size_t pending_creations_ = 0;
  std::size_t active_controllers_ = 0;
};
