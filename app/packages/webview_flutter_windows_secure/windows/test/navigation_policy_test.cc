#include "navigation_policy.h"

#include <gtest/gtest.h>

namespace {

NavigationPolicy ProductionLikePolicy() {
  return NavigationPolicy({
      {L"jw.ustc.edu.cn",
       {L"/", L"/home", L"/login", L"/ucas-sso",
        L"/for-std/course-table", L"/for-std/exam-arrange"}},
      {L"passport.ustc.edu.cn", {L"/login"}},
      {L"id.ustc.edu.cn", {L"/cas", L"/.isg/gateway"}},
      {L"analytics.ustc.edu.cn", {L"/.isg/gateway"}},
  });
}

}  // namespace

TEST(NavigationPolicy, AllowsExactHttpsHostsAndPathFamilies) {
  const auto policy = ProductionLikePolicy();
  EXPECT_TRUE(policy.Allows(L"https://jw.ustc.edu.cn/home"));
  EXPECT_TRUE(policy.Allows(
      L"https://jw.ustc.edu.cn/for-std/course-table/get-data?semester=1"));
  EXPECT_TRUE(policy.Allows(
      L"https://passport.ustc.edu.cn/login?service=registered"));
  EXPECT_TRUE(policy.Allows(L"https://id.ustc.edu.cn/cas/login#form"));
  EXPECT_TRUE(policy.Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway/sso-init?service=registered"));
  EXPECT_TRUE(policy.Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway/session-check"));
  EXPECT_TRUE(policy.Allows(L"https://id.ustc.edu.cn/cas/serviceValidate"));
  EXPECT_TRUE(policy.Allows(L"https://jw.ustc.edu.cn/ucas-sso/callback"));
  EXPECT_FALSE(policy.Allows(L"http://jw.ustc.edu.cn/home"));
  EXPECT_FALSE(policy.Allows(L"https://jw.ustc.edu.cn.evil.example/home"));
  EXPECT_FALSE(policy.Allows(L"https://evil.example/cas/login"));
  EXPECT_FALSE(policy.Allows(L"https://passport.ustc.edu.cn/login-evil"));
  EXPECT_FALSE(policy.Allows(L"https://jw.ustc.edu.cn/homepage"));
  EXPECT_FALSE(policy.Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway-evil/sso-init"));
  EXPECT_FALSE(policy.Allows(L"https://analytics.ustc.edu.cn/.isg/profile"));
  EXPECT_FALSE(policy.Allows(L"https://id.ustc.edu.cn/profile"));
}

TEST(NavigationPolicy, ProductionAllowsOnlyTheObservedAnalyticsRelayPath) {
  const auto& policy = NavigationPolicy::Production();
  EXPECT_TRUE(policy.Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway/sso-init?service=registered"));
  EXPECT_FALSE(policy.Allows(L"https://analytics.ustc.edu.cn/"));
  EXPECT_FALSE(policy.Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway-evil/sso-init"));
  EXPECT_FALSE(policy.Allows(
      L"https://analytics.ustc.edu.cn.evil.example/.isg/gateway/sso-init"));
}

TEST(NavigationPolicy, ProductionAllowsTheObservedIdVerificationRelayPath) {
  const auto& policy = NavigationPolicy::Production();
  EXPECT_TRUE(policy.Allows(
      L"https://id.ustc.edu.cn/.isg/gateway/sso-verify?ticket=registered"));
  EXPECT_EQ(policy.UpgradeInsecureToAllowedHttps(
                L"http://id.ustc.edu.cn/.isg/gateway/sso-verify?ticket=registered"),
            std::optional<std::wstring>(
                L"https://id.ustc.edu.cn/.isg/gateway/sso-verify?ticket=registered"));
  EXPECT_FALSE(policy.Allows(L"https://id.ustc.edu.cn/.isg/profile"));
  EXPECT_FALSE(policy.Allows(
      L"https://id.ustc.edu.cn/.isg/gateway-evil/sso-verify"));
}

TEST(NavigationPolicy, UpgradesOnlyAllowedHttpTargetsWithoutChangingTheRest) {
  const auto& policy = NavigationPolicy::Production();
  EXPECT_EQ(policy.UpgradeInsecureToAllowedHttps(
                L"http://analytics.ustc.edu.cn/.isg/gateway/sso-init?service=registered"),
            std::optional<std::wstring>(
                L"https://analytics.ustc.edu.cn/.isg/gateway/sso-init?service=registered"));
  EXPECT_FALSE(policy.UpgradeInsecureToAllowedHttps(
                         L"http://analytics.ustc.edu.cn/.isg/profile")
                   .has_value());
  EXPECT_FALSE(policy.UpgradeInsecureToAllowedHttps(
                         L"http://analytics.ustc.edu.cn.evil.example/.isg/gateway/sso-init")
                   .has_value());
  EXPECT_FALSE(policy.UpgradeInsecureToAllowedHttps(
                         L"http://analytics.ustc.edu.cn:80/.isg/gateway/sso-init")
                   .has_value());
  EXPECT_FALSE(policy.UpgradeInsecureToAllowedHttps(
                         L"https://analytics.ustc.edu.cn/.isg/gateway/sso-init")
                   .has_value());
}

TEST(NavigationPolicy, SafeDiagnosticTargetStripsQueriesFragmentsAndUserInfo) {
  EXPECT_EQ(NavigationPolicy::SafeDiagnosticTarget(
                L"https://id.ustc.edu.cn/cas/login?ticket=secret#fragment"),
            L"https://id.ustc.edu.cn/cas/login");
  EXPECT_EQ(NavigationPolicy::SafeDiagnosticTarget(
                L"https://next.ustc.edu.cn/auth/callback?code=secret"),
            L"https://next.ustc.edu.cn/<path-redacted>");
  EXPECT_EQ(NavigationPolicy::SafeDiagnosticTarget(
                L"https://user:secret@id.ustc.edu.cn/cas/login"),
            L"invalid_navigation_target");
  EXPECT_EQ(NavigationPolicy::SafeDiagnosticTarget(L"not-a-url"),
            L"invalid_navigation_target");
}

TEST(NavigationPolicy, MethodChannelOriginResolutionUsesTheProductionHosts) {
  EXPECT_EQ(NavigationPolicy::ProductionHostForExactHttpsOrigin(
                "https://analytics.ustc.edu.cn"),
            std::optional<std::wstring>(L"analytics.ustc.edu.cn"));
  EXPECT_EQ(NavigationPolicy::ProductionHostForExactHttpsOrigin(
                "https://id.ustc.edu.cn"),
            std::optional<std::wstring>(L"id.ustc.edu.cn"));
  EXPECT_FALSE(NavigationPolicy::ProductionHostForExactHttpsOrigin(
                   "https://analytics.ustc.edu.cn.evil.example")
                   .has_value());
  EXPECT_FALSE(NavigationPolicy::ProductionHostForExactHttpsOrigin(
                   "https://analytics.ustc.edu.cn/path")
                   .has_value());
  EXPECT_FALSE(NavigationPolicy::ProductionHostForExactHttpsOrigin(
                   "http://analytics.ustc.edu.cn")
                   .has_value());
}

TEST(NavigationPolicy, ProductionAllowsOnlyTheObservedPassportRelayPath) {
  const auto& policy = NavigationPolicy::Production();
  EXPECT_TRUE(policy.Allows(L"https://passport.ustc.edu.cn/login"));
  EXPECT_TRUE(policy.Allows(
      L"https://passport.ustc.edu.cn/login?service=https%3A%2F%2Fid.ustc.edu.cn"));
  EXPECT_FALSE(policy.Allows(L"https://passport.ustc.edu.cn/"));
  EXPECT_FALSE(policy.Allows(L"https://passport.ustc.edu.cn/profile"));
  EXPECT_FALSE(policy.Allows(L"https://passport.ustc.edu.cn.evil.example/login"));
}

TEST(NavigationPolicy, QueryAndFragmentNeverChangeAuthorityDecision) {
  const auto policy = ProductionLikePolicy();
  EXPECT_TRUE(policy.Allows(L"https://jw.ustc.edu.cn/home?next=https://evil"));
  EXPECT_TRUE(policy.Allows(L"https://jw.ustc.edu.cn/home#https://evil"));
  EXPECT_FALSE(
      policy.Allows(L"https://jw.ustc.edu.cn.evil.example/home?ok=1"));
}

TEST(NavigationPolicy, DebugLoopbackRequiresExactIpv4PortAndExplicitFlag) {
  const NavigationPolicy enabled({
      {L"127.0.0.1", {L"/fixture"}, 43123, true},
  });
  const NavigationPolicy no_flag({
      {L"127.0.0.1", {L"/fixture"}, 43123, false},
  });
#if defined(USTC_WEBVIEW_TESTING)
  EXPECT_TRUE(enabled.Allows(L"http://127.0.0.1:43123/fixture"));
#else
  EXPECT_FALSE(enabled.Allows(L"http://127.0.0.1:43123/fixture"));
#endif
  EXPECT_FALSE(no_flag.Allows(L"http://127.0.0.1:43123/fixture"));
  EXPECT_FALSE(enabled.Allows(L"http://localhost:43123/fixture"));
  EXPECT_FALSE(enabled.Allows(L"http://127.0.0.1:43124/fixture"));
  EXPECT_FALSE(enabled.Allows(L"http://127.0.0.1:43123/fixture-evil"));
  EXPECT_FALSE(enabled.UpgradeInsecureToAllowedHttps(
                           L"http://127.0.0.1:43123/fixture")
                   .has_value());
}

TEST(NavigationPolicy, ReleaseAlwaysRejectsInsecureLoopback) {
  const NavigationPolicy policy({
      {L"127.0.0.1", {L"/fixture"}, 43123, true},
  });
#if defined(USTC_WEBVIEW_TESTING)
  GTEST_SKIP() << "Release-only assertion";
#else
  EXPECT_FALSE(policy.Allows(L"http://127.0.0.1:43123/fixture"));
#endif
}

TEST(NavigationPolicy, RestrictedFactoryRejectsAnythingOutsideCompiledPolicy) {
  const auto valid = NavigationPolicy::CreateRestricted({
      {L"jw.ustc.edu.cn", {L"/home"}},
      {L"passport.ustc.edu.cn", {L"/login"}},
      {L"id.ustc.edu.cn", {L"/cas/login"}},
      {L"analytics.ustc.edu.cn", {L"/.isg/gateway/sso-init"}},
  });
  ASSERT_TRUE(valid.has_value());
  EXPECT_TRUE(valid->Allows(L"https://jw.ustc.edu.cn/home"));
  EXPECT_TRUE(valid->Allows(L"https://passport.ustc.edu.cn/login"));
  EXPECT_TRUE(valid->Allows(
      L"https://analytics.ustc.edu.cn/.isg/gateway/sso-init"));

  EXPECT_FALSE(NavigationPolicy::CreateRestricted({
                   {L"jw.ustc.edu.cn.evil.example", {L"/home"}},
               })
                   .has_value());
  EXPECT_FALSE(NavigationPolicy::CreateRestricted({
                   {L"jw.ustc.edu.cn", {L"/unregistered"}},
               })
                   .has_value());
}
