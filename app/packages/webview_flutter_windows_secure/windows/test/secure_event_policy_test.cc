#include "secure_event_policy.h"

#include <gtest/gtest.h>

TEST(SecureEventPolicy, PreservesUpstreamBehaviorUntilExplicitlyHardened) {
  SecureEventPolicy policy;
  EXPECT_FALSE(policy.ShouldCancelDownload());
  EXPECT_FALSE(policy.ShouldHandleNewWindowWithoutOpening());
  EXPECT_EQ(policy.PermissionDecision(), SecurePermissionDecision::Default);
}

TEST(SecureEventPolicy, ExplicitMethodsDenyEveryBrowserEscapeCapability) {
  SecureEventPolicy policy;
  policy.DenyDownloads();
  policy.DenyNewWindows();
  policy.DenyPermissions();
  EXPECT_TRUE(policy.ShouldCancelDownload());
  EXPECT_TRUE(policy.ShouldHandleNewWindowWithoutOpening());
  EXPECT_EQ(policy.PermissionDecision(), SecurePermissionDecision::Deny);
}
