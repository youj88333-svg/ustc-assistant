#include "navigation_policy.h"

#include <algorithm>
#include <cwctype>
#include <utility>

namespace {

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

bool ParsePort(const std::wstring& text, int* result) {
  if (text.empty() || result == nullptr) {
    return false;
  }
  int value = 0;
  for (const auto c : text) {
    if (c < L'0' || c > L'9') {
      return false;
    }
    const int digit = c - L'0';
    if (value > (65535 - digit) / 10) {
      return false;
    }
    value = value * 10 + digit;
  }
  if (value == 0) {
    return false;
  }
  *result = value;
  return true;
}

bool PathMatches(const std::wstring& prefix, const std::wstring& path) {
  if (prefix.empty() || path.size() < prefix.size() ||
      path.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  if (path.size() == prefix.size()) {
    return true;
  }
  const wchar_t next = path[prefix.size()];
  return next == L'/';
}

}  // namespace

NavigationPolicy::NavigationPolicy(
    std::initializer_list<NavigationPolicyEntry> entries)
    : entries_(entries) {}

NavigationPolicy::NavigationPolicy(std::vector<NavigationPolicyEntry> entries)
    : entries_(std::move(entries)) {}

bool NavigationPolicy::Allows(const wchar_t* url) const {
  return url != nullptr && Allows(std::wstring(url));
}

bool NavigationPolicy::Allows(const std::wstring& url) const {
  const auto scheme_end = url.find(L"://");
  if (scheme_end == std::wstring::npos || scheme_end == 0) {
    return false;
  }
  const auto scheme = Lower(url.substr(0, scheme_end));
  if (scheme != L"https"
#if defined(USTC_WEBVIEW_TESTING)
      && scheme != L"http"
#endif
  ) {
    return false;
  }

  const auto authority_start = scheme_end + 3;
  if (authority_start >= url.size()) {
    return false;
  }
  const auto authority_end = url.find_first_of(L"/?#", authority_start);
  const auto authority = url.substr(
      authority_start, authority_end == std::wstring::npos
                           ? std::wstring::npos
                           : authority_end - authority_start);
  if (authority.empty() || authority.find(L'@') != std::wstring::npos) {
    return false;
  }

  std::wstring host = authority;
  std::optional<int> port;
  const auto colon = authority.find(L':');
  if (colon != std::wstring::npos) {
    if (colon != authority.rfind(L':')) {
      return false;
    }
    host = authority.substr(0, colon);
    int parsed = 0;
    if (!ParsePort(authority.substr(colon + 1), &parsed)) {
      return false;
    }
    port = parsed;
  }
  host = Lower(host);
  if (host.empty()) {
    return false;
  }

  std::wstring path = L"/";
  if (authority_end != std::wstring::npos && url[authority_end] == L'/') {
    const auto path_end = url.find_first_of(L"?#", authority_end);
    path = url.substr(authority_end,
                      path_end == std::wstring::npos
                          ? std::wstring::npos
                          : path_end - authority_end);
  }

  for (const auto& entry : entries_) {
    if (Lower(entry.host) != host || entry.port != port) {
      continue;
    }
    const bool path_allowed = std::any_of(
        entry.paths.begin(), entry.paths.end(),
        [&path](const auto& prefix) { return PathMatches(prefix, path); });
    if (!path_allowed) {
      continue;
    }
    if (scheme == L"https") {
      return true;
    }
#if defined(USTC_WEBVIEW_TESTING)
    if (scheme == L"http" && entry.allow_insecure_loopback_for_testing &&
        host == L"127.0.0.1" && port.has_value()) {
      return true;
    }
#endif
  }
  return false;
}

std::optional<std::wstring>
NavigationPolicy::UpgradeInsecureToAllowedHttps(
    const std::wstring& url) const {
  constexpr wchar_t kHttpPrefix[] = L"http://";
  constexpr size_t kHttpPrefixLength =
      sizeof(kHttpPrefix) / sizeof(kHttpPrefix[0]) - 1;
  if (url.size() <= kHttpPrefixLength ||
      url.compare(0, kHttpPrefixLength, kHttpPrefix) != 0) {
    return std::nullopt;
  }
  auto upgraded = std::wstring(L"https://") + url.substr(kHttpPrefixLength);
  return Allows(upgraded)
             ? std::optional<std::wstring>(std::move(upgraded))
             : std::nullopt;
}

std::wstring NavigationPolicy::SafeDiagnosticTarget(
    const std::wstring& url) {
  const auto scheme_end = url.find(L"://");
  if (scheme_end == std::wstring::npos || scheme_end == 0) {
    return L"invalid_navigation_target";
  }
  const auto scheme = Lower(url.substr(0, scheme_end));
  if (scheme != L"http" && scheme != L"https") {
    return L"invalid_navigation_target";
  }
  const auto authority_start = scheme_end + 3;
  if (authority_start >= url.size()) {
    return L"invalid_navigation_target";
  }
  const auto authority_end = url.find_first_of(L"/?#", authority_start);
  const auto authority = url.substr(
      authority_start, authority_end == std::wstring::npos
                           ? std::wstring::npos
                           : authority_end - authority_start);
  if (authority.empty() || authority.find(L'@') != std::wstring::npos) {
    return L"invalid_navigation_target";
  }

  auto host = authority;
  const auto colon = authority.find(L':');
  if (colon != std::wstring::npos) {
    if (colon != authority.rfind(L':')) {
      return L"invalid_navigation_target";
    }
    host = authority.substr(0, colon);
  }
  host = Lower(host);
  if (host.empty()) {
    return L"invalid_navigation_target";
  }

  const auto known_host = std::any_of(
      Production().entries_.begin(), Production().entries_.end(),
      [&host](const NavigationPolicyEntry& entry) {
        return !entry.port.has_value() && Lower(entry.host) == host;
      });
  const auto origin = scheme + L"://" + Lower(authority);
  if (!known_host) {
    return origin + L"/<path-redacted>";
  }

  std::wstring path = L"/";
  if (authority_end != std::wstring::npos && url[authority_end] == L'/') {
    const auto path_end = url.find_first_of(L"?#", authority_end);
    path = url.substr(authority_end,
                      path_end == std::wstring::npos
                          ? std::wstring::npos
                          : path_end - authority_end);
  }
  return origin + path;
}

const NavigationPolicy& NavigationPolicy::Production() {
  static const NavigationPolicy policy({
      {L"jw.ustc.edu.cn",
       {L"/", L"/home", L"/login", L"/ucas-sso",
        L"/for-std/course-table", L"/for-std/exam-arrange"}},
      {L"passport.ustc.edu.cn", {L"/login"}},
      {L"analytics.ustc.edu.cn", {L"/.isg/gateway"}},
      {L"id.ustc.edu.cn", {L"/cas", L"/.isg/gateway"}},
  });
  return policy;
}

std::optional<std::wstring>
NavigationPolicy::ProductionHostForExactHttpsOrigin(
    const std::string& origin) {
  constexpr char kHttpsPrefix[] = "https://";
  constexpr size_t kHttpsPrefixLength = sizeof(kHttpsPrefix) - 1;
  if (origin.size() <= kHttpsPrefixLength ||
      origin.compare(0, kHttpsPrefixLength, kHttpsPrefix) != 0) {
    return std::nullopt;
  }
  const auto encoded_host = origin.substr(kHttpsPrefixLength);
  if (encoded_host.find_first_of("/?#@:") != std::string::npos ||
      !std::all_of(encoded_host.begin(), encoded_host.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
               (c >= '0' && c <= '9') || c == '.' || c == '-';
      })) {
    return std::nullopt;
  }
  const auto host = Lower(
      std::wstring(encoded_host.begin(), encoded_host.end()));
  const auto& production = Production();
  const auto match = std::find_if(
      production.entries_.begin(), production.entries_.end(),
      [&host](const NavigationPolicyEntry& entry) {
        return !entry.port.has_value() && Lower(entry.host) == host;
      });
  return match == production.entries_.end()
             ? std::nullopt
             : std::optional<std::wstring>(host);
}

std::optional<NavigationPolicy> NavigationPolicy::CreateRestricted(
    std::vector<NavigationPolicyEntry> entries) {
  if (entries.empty()) {
    return std::nullopt;
  }
  for (const auto& entry : entries) {
    if (entry.paths.empty()) {
      return std::nullopt;
    }

    const auto host = Lower(entry.host);
    const bool debug_loopback =
        host == L"127.0.0.1" && entry.port.has_value() &&
        entry.allow_insecure_loopback_for_testing;
#if !defined(USTC_WEBVIEW_TESTING)
    if (debug_loopback) {
      return std::nullopt;
    }
#endif
    if (!debug_loopback &&
        (entry.port.has_value() || entry.allow_insecure_loopback_for_testing)) {
      return std::nullopt;
    }

    for (const auto& path : entry.paths) {
      if (path.empty() || path.front() != L'/') {
        return std::nullopt;
      }
      if (debug_loopback) {
        continue;
      }
      if (!Production().Allows(L"https://" + host + path)) {
        return std::nullopt;
      }
    }
  }
  return NavigationPolicy(std::move(entries));
}
