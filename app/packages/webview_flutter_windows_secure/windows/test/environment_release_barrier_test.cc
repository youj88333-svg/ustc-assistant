#include "../environment_release_barrier.h"

#include <gtest/gtest.h>

#include "../environment_lifecycle.h"

TEST(EnvironmentReleaseBarrier,
     WaiterCompletesOnlyAfterLogicalAndProcessRelease) {
  EnvironmentReleaseBarrier barrier;
  barrier.BrowserProcessStarted(41);

  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  EXPECT_FALSE(barrier.IsReady());
  EXPECT_EQ(completions, 0);

  barrier.SetLogicalReleaseReady(true);
  EXPECT_EQ(completions, 0);

  barrier.BrowserProcessExited(40);
  EXPECT_FALSE(barrier.IsReady());
  EXPECT_EQ(completions, 0);

  barrier.BrowserProcessExited(41);
  EXPECT_TRUE(barrier.IsReady());
  EXPECT_EQ(completions, 1);
}

TEST(EnvironmentReleaseBarrier, CompletionEventMayArriveBeforeLogicalRelease) {
  EnvironmentReleaseBarrier barrier;
  barrier.BrowserProcessStarted(41);
  barrier.SetLogicalReleaseReady(false);
  barrier.BrowserProcessExited(41);

  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  EXPECT_EQ(completions, 0);

  barrier.SetLogicalReleaseReady(true);
  EXPECT_EQ(completions, 1);
}

TEST(EnvironmentReleaseBarrier, NoControllerReleaseIsIdempotent) {
  EnvironmentReleaseBarrier barrier;
  EXPECT_TRUE(barrier.IsReady());

  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  barrier.Await([&completions] { ++completions; });
  barrier.BrowserProcessExited(41);
  EXPECT_EQ(completions, 2);
}

TEST(EnvironmentReleaseBarrier, StaleExitDoesNotReleaseNewerProcess) {
  EnvironmentReleaseBarrier barrier;
  barrier.BrowserProcessStarted(41);
  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  barrier.BrowserProcessStarted(42);
  barrier.BrowserProcessExited(41);
  EXPECT_FALSE(barrier.IsReady());
  EXPECT_EQ(completions, 0);

  barrier.BrowserProcessExited(42);
  EXPECT_TRUE(barrier.IsReady());
  EXPECT_EQ(completions, 1);
}

TEST(EnvironmentReleaseBarrier,
     FailedControllerCreationLeavesLogicalEnvironmentReconfigurable) {
  EnvironmentLifecycle lifecycle;
  EnvironmentReleaseBarrier barrier;
  // Mirror WebviewWindowsPlugin::UpdateEnvironmentReleaseState: a failed
  // CompleteCreation(false) never supplies a process PID, so clearing the
  // pending logical creation must unblock reconfiguration. The UDF store
  // still owns the fail-closed physical delete/quarantine decision.
  lifecycle.BeginCreation();
  barrier.SetLogicalReleaseReady(lifecycle.ShouldReleaseEnvironment());
  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  EXPECT_FALSE(barrier.IsReady());

  ASSERT_TRUE(lifecycle.CompleteCreation(false));
  EXPECT_TRUE(lifecycle.CanConfigure());
  barrier.SetLogicalReleaseReady(lifecycle.ShouldReleaseEnvironment());
  EXPECT_TRUE(barrier.IsReady());
  EXPECT_EQ(completions, 1);

  // A later successful controller establishes a new, trustworthy PID.
  barrier.BrowserProcessStarted(42);
  EXPECT_FALSE(barrier.IsReady());
  barrier.BrowserProcessExited(42);
  EXPECT_TRUE(barrier.IsReady());
  EXPECT_EQ(completions, 1);
}

TEST(EnvironmentReleaseBarrier, ZeroPidCannotBecomeReleaseIdentity) {
  EnvironmentReleaseBarrier barrier;
  barrier.BrowserProcessStarted(0);
  barrier.BrowserProcessExited(0);
  EXPECT_TRUE(barrier.IsReady());

  barrier.BrowserProcessStarted(42);
  barrier.BrowserProcessExited(42);
  EXPECT_TRUE(barrier.IsReady());
}

TEST(EnvironmentReleaseBarrier, EachWaiterCompletesAtMostOnce) {
  EnvironmentReleaseBarrier barrier;
  barrier.BrowserProcessStarted(41);
  int completions = 0;
  barrier.Await([&completions] { ++completions; });
  barrier.SetLogicalReleaseReady(true);
  barrier.BrowserProcessExited(41);
  barrier.BrowserProcessExited(41);
  barrier.SetLogicalReleaseReady(true);
  EXPECT_EQ(completions, 1);
}
