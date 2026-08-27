#include "session_snapshot.h"

#include <windows.h>
#include <wincrypt.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string_view>

namespace session_snapshot {
namespace {

constexpr std::array<unsigned char, 8> kMagic = {'U', 'S', 'T', 'C',
                                                  'S', 'N', 'P', '1'};
constexpr size_t kMaxCookies = 128;
constexpr size_t kMaxFieldBytes = 64 * 1024;
constexpr size_t kMaxPlaintextBytes = 1024 * 1024;
constexpr size_t kMaxEncryptedBytes = 2 * 1024 * 1024;
constexpr std::string_view kEntropy =
    "USTC Assistant WebView2 session snapshot v1";

bool IsMissingError(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

std::string NormalizedDomain(std::string domain) {
  if (!domain.empty() && domain.front() == '.') {
    domain.erase(domain.begin());
  }
  std::transform(domain.begin(), domain.end(), domain.begin(),
                 [](unsigned char value) {
                   return static_cast<char>(std::tolower(value));
                 });
  return domain;
}

bool IsTrustedDomain(const std::string& domain) {
  const auto normalized = NormalizedDomain(domain);
  return normalized == "jw.ustc.edu.cn" ||
         normalized == "id.ustc.edu.cn" ||
         normalized == "analytics.ustc.edu.cn" ||
         normalized == "passport.ustc.edu.cn";
}

void AppendUint32(std::vector<unsigned char>* output, uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    output->push_back(static_cast<unsigned char>((value >> shift) & 0xff));
  }
}

bool AppendString(std::vector<unsigned char>* output,
                  const std::string& value) {
  if (value.size() > kMaxFieldBytes ||
      value.size() > (std::numeric_limits<uint32_t>::max)()) {
    return false;
  }
  AppendUint32(output, static_cast<uint32_t>(value.size()));
  output->insert(output->end(), value.begin(), value.end());
  return output->size() <= kMaxPlaintextBytes;
}

bool ReadUint32(std::span<const unsigned char> input, size_t* offset,
                uint32_t* value) {
  if (*offset > input.size() || input.size() - *offset < 4) {
    return false;
  }
  *value = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    *value |= static_cast<uint32_t>(input[*offset]) << shift;
    ++*offset;
  }
  return true;
}

bool ReadString(std::span<const unsigned char> input, size_t* offset,
                std::string* value) {
  uint32_t length = 0;
  if (!ReadUint32(input, offset, &length) || length > kMaxFieldBytes ||
      *offset > input.size() || input.size() - *offset < length) {
    return false;
  }
  value->assign(reinterpret_cast<const char*>(input.data() + *offset), length);
  *offset += length;
  return true;
}

void SecureClear(std::vector<unsigned char>* bytes) {
  if (!bytes->empty()) {
    SecureZeroMemory(bytes->data(), bytes->size());
  }
  bytes->clear();
}

void SecureClear(std::string* value) {
  if (!value->empty()) {
    SecureZeroMemory(value->data(), value->size());
  }
  value->clear();
}

bool DeleteSnapshotIfPresent(const std::wstring& path) {
  if (DeleteFileW(path.c_str())) return true;
  return IsMissingError(GetLastError());
}

bool WriteAtomically(const std::wstring& path,
                     std::span<const unsigned char> bytes) {
  if (bytes.empty() || bytes.size() > kMaxEncryptedBytes ||
      bytes.size() > (std::numeric_limits<DWORD>::max)()) {
    return false;
  }
  const auto temporary_path = path + L".tmp";
  HANDLE file = CreateFileW(
      temporary_path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_WRITE_THROUGH,
      nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool wrote =
      WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
                nullptr) &&
      written == bytes.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!wrote ||
      !MoveFileExW(temporary_path.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary_path.c_str());
    return false;
  }
  return true;
}

enum class ReadResult { kMissing, kSuccess, kFailed };

ReadResult ReadFileBounded(const std::wstring& path,
                           std::vector<unsigned char>* bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return IsMissingError(GetLastError()) ? ReadResult::kMissing
                                          : ReadResult::kFailed;
  }
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > static_cast<LONGLONG>(kMaxEncryptedBytes) ||
      size.QuadPart > (std::numeric_limits<DWORD>::max)()) {
    CloseHandle(file);
    return ReadResult::kFailed;
  }
  bytes->resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool succeeded =
      ReadFile(file, bytes->data(), static_cast<DWORD>(bytes->size()), &read,
               nullptr) &&
      read == bytes->size();
  CloseHandle(file);
  if (!succeeded) {
    bytes->clear();
    return ReadResult::kFailed;
  }
  return ReadResult::kSuccess;
}

DATA_BLOB EntropyBlob() {
  return DATA_BLOB{
      .cbData = static_cast<DWORD>(kEntropy.size()),
      .pbData = reinterpret_cast<BYTE*>(
          const_cast<char*>(kEntropy.data())),
  };
}

}  // namespace

bool IsTrustedSessionCookie(const WebviewCookie& cookie) {
  return cookie.is_session && cookie.expires < 0 && !cookie.name.empty() &&
         !cookie.path.empty() && cookie.same_site >= 0 &&
         cookie.same_site <= 2 && IsTrustedDomain(cookie.domain);
}

std::vector<unsigned char> EncodePlaintext(
    const std::vector<WebviewCookie>& cookies) {
  if (cookies.size() > kMaxCookies) return {};
  std::vector<unsigned char> output(kMagic.begin(), kMagic.end());
  AppendUint32(&output, static_cast<uint32_t>(cookies.size()));
  for (const auto& cookie : cookies) {
    if (!IsTrustedSessionCookie(cookie) ||
        !AppendString(&output, cookie.name) ||
        !AppendString(&output, cookie.value) ||
        !AppendString(&output, cookie.domain) ||
        !AppendString(&output, cookie.path)) {
      SecureClear(&output);
      return {};
    }
    uint32_t flags = static_cast<uint32_t>(cookie.same_site) << 2;
    if (cookie.is_secure) flags |= 1;
    if (cookie.is_http_only) flags |= 2;
    AppendUint32(&output, flags);
    if (output.size() > kMaxPlaintextBytes) {
      SecureClear(&output);
      return {};
    }
  }
  return output;
}

bool DecodePlaintext(std::span<const unsigned char> plaintext,
                     std::vector<WebviewCookie>* cookies) {
  if (!cookies || plaintext.size() < kMagic.size() + 4 ||
      plaintext.size() > kMaxPlaintextBytes ||
      !std::equal(kMagic.begin(), kMagic.end(), plaintext.begin())) {
    return false;
  }
  std::vector<WebviewCookie> decoded;
  size_t offset = kMagic.size();
  uint32_t count = 0;
  if (!ReadUint32(plaintext, &offset, &count) || count > kMaxCookies) {
    return false;
  }
  decoded.reserve(count);
  for (uint32_t index = 0; index < count; ++index) {
    WebviewCookie cookie;
    uint32_t flags = 0;
    if (!ReadString(plaintext, &offset, &cookie.name) ||
        !ReadString(plaintext, &offset, &cookie.value) ||
        !ReadString(plaintext, &offset, &cookie.domain) ||
        !ReadString(plaintext, &offset, &cookie.path) ||
        !ReadUint32(plaintext, &offset, &flags) || (flags & ~0x0fU) != 0) {
      ClearSensitiveCookies(&decoded);
      return false;
    }
    cookie.expires = -1.0;
    cookie.is_session = true;
    cookie.is_secure = (flags & 1) != 0;
    cookie.is_http_only = (flags & 2) != 0;
    cookie.same_site = static_cast<int>((flags >> 2) & 0x03);
    if (!IsTrustedSessionCookie(cookie)) {
      SecureClear(&cookie.value);
      ClearSensitiveCookies(&decoded);
      return false;
    }
    decoded.push_back(std::move(cookie));
  }
  if (offset != plaintext.size()) {
    ClearSensitiveCookies(&decoded);
    return false;
  }
  ClearSensitiveCookies(cookies);
  *cookies = std::move(decoded);
  return true;
}

bool Persist(const std::wstring& path,
             const std::vector<WebviewCookie>& cookies) {
  std::vector<WebviewCookie> trusted;
  trusted.reserve((std::min)(cookies.size(), kMaxCookies));
  for (const auto& cookie : cookies) {
    if (IsTrustedSessionCookie(cookie)) trusted.push_back(cookie);
  }
  if (trusted.empty()) {
    return DeleteSnapshotIfPresent(path);
  }
  auto plaintext = EncodePlaintext(trusted);
  ClearSensitiveCookies(&trusted);
  if (plaintext.empty()) return false;

  DATA_BLOB input = {
      .cbData = static_cast<DWORD>(plaintext.size()),
      .pbData = plaintext.data(),
  };
  auto entropy = EntropyBlob();
  DATA_BLOB encrypted = {};
  const bool protected_ok =
      CryptProtectData(&input, L"USTC Assistant WebView2 session snapshot",
                       &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                       &encrypted) == TRUE;
  SecureClear(&plaintext);
  if (!protected_ok || !encrypted.pbData || encrypted.cbData == 0) {
    if (encrypted.pbData) LocalFree(encrypted.pbData);
    return false;
  }
  const bool written = WriteAtomically(
      path, std::span<const unsigned char>(encrypted.pbData, encrypted.cbData));
  SecureZeroMemory(encrypted.pbData, encrypted.cbData);
  LocalFree(encrypted.pbData);
  return written;
}

RestoreResult Restore(const std::wstring& path,
                      std::vector<WebviewCookie>* cookies) {
  if (!cookies) return RestoreResult::kFailed;
  std::vector<unsigned char> encrypted;
  const auto read_result = ReadFileBounded(path, &encrypted);
  if (read_result == ReadResult::kMissing) return RestoreResult::kMissing;
  if (read_result != ReadResult::kSuccess) return RestoreResult::kFailed;

  DATA_BLOB input = {
      .cbData = static_cast<DWORD>(encrypted.size()),
      .pbData = encrypted.data(),
  };
  auto entropy = EntropyBlob();
  DATA_BLOB plaintext = {};
  const bool unprotected =
      CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &plaintext) == TRUE;
  encrypted.clear();
  if (!unprotected || !plaintext.pbData || plaintext.cbData == 0 ||
      plaintext.cbData > kMaxPlaintextBytes) {
    if (plaintext.pbData) {
      SecureZeroMemory(plaintext.pbData, plaintext.cbData);
      LocalFree(plaintext.pbData);
    }
    return RestoreResult::kFailed;
  }
  const bool decoded = DecodePlaintext(
      std::span<const unsigned char>(plaintext.pbData, plaintext.cbData),
      cookies);
  SecureZeroMemory(plaintext.pbData, plaintext.cbData);
  LocalFree(plaintext.pbData);
  return decoded ? RestoreResult::kRestored : RestoreResult::kFailed;
}

void ClearSensitiveCookies(std::vector<WebviewCookie>* cookies) {
  if (!cookies) return;
  for (auto& cookie : *cookies) {
    SecureClear(&cookie.name);
    SecureClear(&cookie.value);
    SecureClear(&cookie.domain);
    SecureClear(&cookie.path);
  }
  cookies->clear();
}

}  // namespace session_snapshot
