#pragma once

#include <span>
#include <string>
#include <vector>

#include "webview.h"

namespace session_snapshot {

enum class RestoreResult { kMissing, kRestored, kFailed };

bool IsTrustedSessionCookie(const WebviewCookie& cookie);

std::vector<unsigned char> EncodePlaintext(
    const std::vector<WebviewCookie>& cookies);

bool DecodePlaintext(std::span<const unsigned char> plaintext,
                     std::vector<WebviewCookie>* cookies);

bool Persist(const std::wstring& path,
             const std::vector<WebviewCookie>& cookies);

RestoreResult Restore(const std::wstring& path,
                      std::vector<WebviewCookie>* cookies);

void ClearSensitiveCookies(std::vector<WebviewCookie>* cookies);

}  // namespace session_snapshot
