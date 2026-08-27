#pragma once

#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

struct NavigationPolicyEntry {
  std::wstring host;
  std::vector<std::wstring> paths;
  std::optional<int> port;
  bool allow_insecure_loopback_for_testing = false;
};

class NavigationPolicy {
 public:
  NavigationPolicy(std::initializer_list<NavigationPolicyEntry> entries);
  explicit NavigationPolicy(std::vector<NavigationPolicyEntry> entries);

  bool Allows(const wchar_t* url) const;
  bool Allows(const std::wstring& url) const;

  // Returns the HTTPS form only when the input is plain HTTP and that exact
  // host, port, path, query, and fragment would otherwise be allowed by this
  // policy after changing only the scheme. This lets the host cancel the
  // insecure navigation before it is sent and navigate directly to HTTPS.
  std::optional<std::wstring> UpgradeInsecureToAllowedHttps(
      const std::wstring& url) const;

  // Produces a credential-free diagnostic target. Query and fragment are
  // always removed. Full paths are retained only for compiled production
  // hosts; unknown-host paths are redacted.
  static std::wstring SafeDiagnosticTarget(const std::wstring& url);

  static const NavigationPolicy& Production();
  // Resolves only an exact HTTPS origin whose host is already present in the
  // compiled production policy. Method-channel parsing uses this instead of
  // maintaining a second host allowlist.
  static std::optional<std::wstring> ProductionHostForExactHttpsOrigin(
      const std::string& origin);
  static std::optional<NavigationPolicy> CreateRestricted(
      std::vector<NavigationPolicyEntry> entries);

 private:
  std::vector<NavigationPolicyEntry> entries_;
};
