#ifndef RUNNER_YOUNG_JSON_PROJECTION_H_
#define RUNNER_YOUNG_JSON_PROJECTION_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

// M2.2 candidate projection only. No result from this module proves identity,
// completeness, or permission to import. Input buffers are borrowed; the SDK
// owner remains responsible for erasing and freeing its original buffers.
namespace young_probe {

inline constexpr size_t kMetadataChars = 262144;
inline constexpr size_t kBodyProtocolChars = 2 * 1024 * 1024;
inline constexpr size_t kMaximumDepth = 32;
inline constexpr size_t kMaximumNodes = 131072;
inline constexpr size_t kMaximumObjectMembers = 256;
inline constexpr size_t kMaximumArrayElements = 10000;
inline constexpr size_t kMaximumRecords = 5000;

enum class Endpoint { profile, schedule, activities };
enum class Rejection {
  none, target, method, frame, loader, redirect, worker, cache, transport,
  limit, body, stale
};
enum class ValueKind {
  absent, null_value, boolean, number, string, array, object, mixed
};
enum class SuccessKind { unobserved, true_value, false_value, other };

const char* RejectionLabel(Rejection value) noexcept;
const char* ValueKindLabel(ValueKind value) noexcept;
const char* SuccessKindLabel(SuccessKind value) noexcept;

template <typename T>
struct ParseResult {
  std::optional<T> value;
  Rejection rejection = Rejection::none;
  explicit operator bool() const noexcept { return value.has_value(); }
};

struct FrameBinding {
  std::wstring frame;
  std::wstring loader;
};

struct DefaultContext {
  int id = 0;
  std::wstring unique_id;
};

struct RequestMetadata {
  std::wstring request_id;
  std::wstring frame_id;
  std::wstring loader_id;
  Endpoint endpoint = Endpoint::profile;
  bool redirected = false;
  double timestamp = 0;
};

struct ResponseMetadata {
  std::wstring request_id;
  std::wstring frame_id;
  std::wstring loader_id;
  Endpoint endpoint = Endpoint::profile;
  unsigned int status = 200;
};

struct ResponseShape {
  SuccessKind success = SuccessKind::unobserved;
  ValueKind code = ValueKind::absent;
  ValueKind result = ValueKind::absent;
};

struct ProfileProjection : ResponseShape {
  ValueKind loginCode = ValueKind::absent;
  ValueKind username = ValueKind::absent;
};

struct ListProjection : ResponseShape {
  ValueKind records = ValueKind::absent;
  size_t count = 0;
  ValueKind total = ValueKind::absent;
  ValueKind id = ValueKind::absent;
  ValueKind title = ValueKind::absent;
  ValueKind date = ValueKind::absent;
  ValueKind startTime = ValueKind::absent;
  ValueKind endTime = ValueKind::absent;
};

struct BodyProjection {
  Endpoint endpoint = Endpoint::profile;
  ProfileProjection profile;
  ListProjection list;
};

// Counters contain no values. Platform identifiers and necessary business
// strings have separate decoder counts; transport-body counts cover the CDP
// wrapper text before its private buffer is erased.
struct DecodeAudit {
  size_t identifier_values = 0;
  size_t identifier_units = 0;
  size_t transport_body_values = 0;
  size_t transport_body_units = 0;
  size_t business_values = 0;
  size_t business_units = 0;
};

ParseResult<FrameBinding> ParseFrameTree(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
ParseResult<DefaultContext> ParseDefaultContext(
    const wchar_t* raw, size_t length, std::wstring_view frame,
    std::wstring_view origin, DecodeAudit* audit = nullptr);
ParseResult<bool> IsContextDestroyed(const wchar_t* raw, size_t length,
    int context_id, std::wstring_view unique_id);
// Project only the event's frame identity. Route URLs and payloads stay in the
// borrowed SDK buffer and are never decoded.
ParseResult<std::wstring> ParseWithinDocumentFrame(const wchar_t* raw,
    size_t length, DecodeAudit* audit = nullptr);
ParseResult<std::wstring> ParseRequestId(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
// A compiled step is the allow-listed script identity; require a matching
// scriptParsed marker in the current default context before using it.
// Callers must compare both returned IDs before issuing that script.
ParseResult<std::wstring> ParseStepScript(
    const wchar_t* raw, size_t length, std::wstring_view marker,
    int context_id, DecodeAudit* audit = nullptr);
ParseResult<std::wstring> ParseCompiledScriptId(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
// A target rejection means the request did not prove the registered script.
// An unresolved parentId never substitutes for an observed parent stack.
ParseResult<bool> HasInitiatorScript(
    const wchar_t* raw, size_t length, std::wstring_view script_id,
    DecodeAudit* audit = nullptr);
ParseResult<std::wstring> ParseRemoteObjectId(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
ParseResult<int> ParseRemoteStatus(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
ParseResult<double> ParseMonotonicBarrier(
    const wchar_t* raw, size_t length, DecodeAudit* audit = nullptr);
ParseResult<RequestMetadata> ParseRequest(
    const wchar_t* raw, size_t length, std::wstring_view business_origin,
    std::wstring_view business_prefix, DecodeAudit* audit = nullptr);
ParseResult<ResponseMetadata> ParseResponse(
    const wchar_t* raw, size_t length, std::wstring_view business_origin,
    std::wstring_view business_prefix, DecodeAudit* audit = nullptr);

// Call only for a response already associated with an accepted fixed GET and
// still-current session/document/operation. Parses exactly {body,
// base64Encoded}; decodes the protocol body into a private temporary buffer,
// projects types/counts, and erases that buffer on every exit.
ParseResult<BodyProjection> ProjectResponseBody(
    const wchar_t* raw, size_t length, Endpoint endpoint,
    DecodeAudit* audit = nullptr);

// Use only after the native coordinator has associated this body with the
// current fixed GET and still-current context/document/operation. The output
// contains only the Dart candidate's necessary business fields; callers own
// and must erase it after decoding. The temporary protocol and business body
// buffers are erased by this module on every exit.
ParseResult<std::wstring> ProjectBusinessResponseBody(
    const wchar_t* raw, size_t length, Endpoint endpoint,
    DecodeAudit* audit = nullptr);

void SecureErase(wchar_t* buffer, size_t length) noexcept;
bool RunYoungProjectionSelfTests();

}  // namespace young_probe

#endif  // RUNNER_YOUNG_JSON_PROJECTION_H_
