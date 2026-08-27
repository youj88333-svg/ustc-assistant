#include "session_snapshot.h"

#include <gtest/gtest.h>
#include <windows.h>

#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

WebviewCookie SessionCookie(std::string domain, std::string value) {
  WebviewCookie cookie;
  cookie.name = "SESSION";
  cookie.value = std::move(value);
  cookie.domain = std::move(domain);
  cookie.path = "/";
  cookie.expires = -1.0;
  cookie.is_secure = true;
  cookie.is_http_only = true;
  cookie.is_session = true;
  cookie.same_site = 1;
  return cookie;
}

std::wstring TemporarySnapshotPath() {
  wchar_t directory[MAX_PATH] = {};
  EXPECT_GT(GetTempPathW(MAX_PATH, directory), 0u);
  wchar_t path[MAX_PATH] = {};
  EXPECT_NE(GetTempFileNameW(directory, L"uas", 0, path), 0u);
  DeleteFileW(path);
  return std::wstring(path) + L".dpapi";
}

}  // namespace

TEST(SessionSnapshot, AcceptsOnlyExactTrustedSessionCookieDomains) {
  EXPECT_TRUE(session_snapshot::IsTrustedSessionCookie(
      SessionCookie("jw.ustc.edu.cn", "secret")));
  EXPECT_TRUE(session_snapshot::IsTrustedSessionCookie(
      SessionCookie(".id.ustc.edu.cn", "secret")));
  EXPECT_TRUE(session_snapshot::IsTrustedSessionCookie(
      SessionCookie("ANALYTICS.USTC.EDU.CN", "secret")));
  EXPECT_FALSE(session_snapshot::IsTrustedSessionCookie(
      SessionCookie("ustc.edu.cn", "secret")));
  EXPECT_FALSE(session_snapshot::IsTrustedSessionCookie(
      SessionCookie("jw.ustc.edu.cn.evil.example", "secret")));
  auto persistent = SessionCookie("jw.ustc.edu.cn", "secret");
  persistent.is_session = false;
  persistent.expires = 1900000000.0;
  EXPECT_FALSE(session_snapshot::IsTrustedSessionCookie(persistent));
}

TEST(SessionSnapshot, PlaintextCodecRejectsCorruptionAndRoundTripsFlags) {
  auto first = SessionCookie("jw.ustc.edu.cn", "alpha");
  auto second = SessionCookie("id.ustc.edu.cn", "beta");
  second.same_site = 2;
  second.is_http_only = false;
  const auto encoded =
      session_snapshot::EncodePlaintext({first, second});
  std::vector<WebviewCookie> decoded;
  ASSERT_TRUE(session_snapshot::DecodePlaintext(encoded, &decoded));
  ASSERT_EQ(decoded.size(), 2u);
  EXPECT_EQ(decoded[0].value, "alpha");
  EXPECT_EQ(decoded[1].domain, "id.ustc.edu.cn");
  EXPECT_EQ(decoded[1].same_site, 2);
  EXPECT_FALSE(decoded[1].is_http_only);
  EXPECT_TRUE(decoded[1].is_session);

  auto truncated = encoded;
  truncated.pop_back();
  EXPECT_FALSE(session_snapshot::DecodePlaintext(truncated, &decoded));
  auto wrong_magic = encoded;
  wrong_magic[0] ^= 0xff;
  EXPECT_FALSE(session_snapshot::DecodePlaintext(wrong_magic, &decoded));
}

TEST(SessionSnapshot, DpapiFileDoesNotContainPlaintextAndRestores) {
  const auto path = TemporarySnapshotPath();
  const std::string secret = "never-cross-the-dart-channel";
  ASSERT_TRUE(session_snapshot::Persist(
      path, {SessionCookie("jw.ustc.edu.cn", secret)}));

  std::ifstream file(path, std::ios::binary);
  const std::string encrypted((std::istreambuf_iterator<char>(file)),
                              std::istreambuf_iterator<char>());
  EXPECT_EQ(encrypted.find(secret), std::string::npos);

  std::vector<WebviewCookie> restored;
  EXPECT_EQ(session_snapshot::Restore(path, &restored),
            session_snapshot::RestoreResult::kRestored);
  ASSERT_EQ(restored.size(), 1u);
  EXPECT_EQ(restored[0].value, secret);
  session_snapshot::ClearSensitiveCookies(&restored);
  DeleteFileW(path.c_str());
}

TEST(SessionSnapshot, EmptyTrustedSetRemovesAStaleSnapshot) {
  const auto path = TemporarySnapshotPath();
  ASSERT_TRUE(session_snapshot::Persist(
      path, {SessionCookie("jw.ustc.edu.cn", "secret")}));
  ASSERT_NE(GetFileAttributesW(path.c_str()), INVALID_FILE_ATTRIBUTES);

  EXPECT_TRUE(session_snapshot::Persist(
      path, {SessionCookie("evil.example", "secret")}));
  EXPECT_EQ(GetFileAttributesW(path.c_str()), INVALID_FILE_ATTRIBUTES);
}
