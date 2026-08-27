#include "environment_lifecycle.h"

#include <gtest/gtest.h>

TEST(EnvironmentLifecycle, ReleasesOnlyAfterControllersAndCreationsReachZero) {
  EnvironmentLifecycle lifecycle;
  EXPECT_TRUE(lifecycle.CanConfigure());
  lifecycle.BeginCreation();
  EXPECT_FALSE(lifecycle.CanConfigure());
  EXPECT_FALSE(lifecycle.ShouldReleaseEnvironment());
  lifecycle.CompleteCreation(true);
  EXPECT_EQ(lifecycle.active_controllers(), 1);
  EXPECT_FALSE(lifecycle.ShouldReleaseEnvironment());
  lifecycle.DisposeController();
  EXPECT_TRUE(lifecycle.ShouldReleaseEnvironment());
  EXPECT_TRUE(lifecycle.CanConfigure());
}

TEST(EnvironmentLifecycle, FailedCreationBecomesReleasable) {
  EnvironmentLifecycle lifecycle;
  lifecycle.BeginCreation();
  lifecycle.CompleteCreation(false);
  EXPECT_EQ(lifecycle.pending_creations(), 0);
  EXPECT_EQ(lifecycle.active_controllers(), 0);
  EXPECT_TRUE(lifecycle.ShouldReleaseEnvironment());
}

TEST(EnvironmentLifecycle, RejectsUnderflowAndKeepsStateStable) {
  EnvironmentLifecycle lifecycle;
  EXPECT_FALSE(lifecycle.DisposeController());
  EXPECT_FALSE(lifecycle.CompleteCreation(false));
  EXPECT_EQ(lifecycle.pending_creations(), 0);
  EXPECT_EQ(lifecycle.active_controllers(), 0);
}
