#pragma once

enum class SecurePermissionDecision { Default, Deny };

class SecureEventPolicy {
 public:
  void DenyDownloads() { deny_downloads_ = true; }
  void DenyNewWindows() { deny_new_windows_ = true; }
  void DenyPermissions() { deny_permissions_ = true; }

  bool ShouldCancelDownload() const { return deny_downloads_; }
  bool ShouldHandleNewWindowWithoutOpening() const {
    return deny_new_windows_;
  }
  SecurePermissionDecision PermissionDecision() const {
    return deny_permissions_ ? SecurePermissionDecision::Deny
                             : SecurePermissionDecision::Default;
  }

 private:
  bool deny_downloads_ = false;
  bool deny_new_windows_ = false;
  bool deny_permissions_ = false;
};
