#include "young_json_projection.h"
#include <vector>
#include <utility>

#include <array>
#include <cmath>
#include <string>
#include <string_view>

namespace young_probe {
namespace {

constexpr std::wstring_view kOrigin = L"https://young.ustc.edu.cn";
constexpr std::wstring_view kPrefix = L"/login/wisdom-group-learning-bg";
constexpr std::wstring_view kProfile = L"/paramdesign/scMyInfo/info";
constexpr std::wstring_view kSchedule = L"/personal/scCalendar/getPageUserList";
constexpr std::wstring_view kActivities = L"/mobile/item/enrolmentList";

std::wstring RequestAt(std::wstring_view path, std::wstring_view request_extra = L"",
                       std::wstring_view root_extra = L"") {
  return L"{\"requestId\":\"R1\",\"frameId\":\"F1\",\"loaderId\":\"L1\","
         L"\"type\":\"Fetch\",\"timestamp\":123.25,\"request\":{\"method\":\"GET\",\"url\":\"" +
         std::wstring(kOrigin) + std::wstring(kPrefix) + std::wstring(path) +
         L"?opaque=QUERY_SENTINEL\",\"headers\":{\"Cookie\":\"COOKIE_SENTINEL\\u0041\","
         L"\"Authorization\":\"HEADER_SENTINEL\"}" + std::wstring(request_extra) +
         L"},\"initiator\":{\"stack\":{\"frames\":[\"STACK_SENTINEL\"]}}" +
         std::wstring(root_extra) + L"}";
}

std::wstring ResponseAt(std::wstring_view path) {
  return L"{\"requestId\":\"R1\",\"frameId\":\"F1\",\"loaderId\":\"L1\","
         L"\"type\":\"XHR\",\"response\":{\"url\":\"" + std::wstring(kOrigin) +
         std::wstring(kPrefix) + std::wstring(path) + L"?opaque=QUERY_SENTINEL\","
         L"\"status\":200,\"mimeType\":\"application/json\",\"fromServiceWorker\":false,"
         L"\"fromDiskCache\":false,\"fromPrefetchCache\":false,\"headers\":{"
         L"\"set-cookie\":\"SET_COOKIE_SENTINEL\\u0041\",\"cookie\":\"COOKIE_SENTINEL\"}}}";
}

std::wstring Replace(std::wstring value, std::wstring_view before,
                     std::wstring_view after) {
  const size_t found = value.find(before);
  if (found != std::wstring::npos) value.replace(found, before.size(), after);
  return value;
}

std::wstring Envelope(std::wstring_view body) {
  std::wstring result = L"{\"body\":\"";
  for (wchar_t value : body) {
    switch (value) {
      case L'"': result += L"\\\""; break;
      case L'\\': result += L"\\\\"; break;
      case L'\b': result += L"\\b"; break;
      case L'\f': result += L"\\f"; break;
      case L'\n': result += L"\\n"; break;
      case L'\r': result += L"\\r"; break;
      case L'\t': result += L"\\t"; break;
      default: result += value; break;
    }
  }
  return result + L"\",\"base64Encoded\":false}";
}

ParseResult<RequestMetadata> RequestTest(const std::wstring& json, DecodeAudit* audit = nullptr) {
  return ParseRequest(json.data(), json.size(), kOrigin, kPrefix, audit);
}

ParseResult<ResponseMetadata> ResponseTest(const std::wstring& json, DecodeAudit* audit = nullptr) {
  return ParseResponse(json.data(), json.size(), kOrigin, kPrefix, audit);
}

ParseResult<BodyProjection> BodyTest(std::wstring_view body, Endpoint endpoint,
                                    DecodeAudit* audit = nullptr) {
  const auto protocol = Envelope(body);
  return ProjectResponseBody(protocol.data(), protocol.size(), endpoint, audit);
}

ParseResult<std::wstring> BusinessTest(std::wstring_view body, Endpoint endpoint,
                                      DecodeAudit* audit = nullptr) {
  const auto protocol = Envelope(body);
  return ProjectBusinessResponseBody(protocol.data(), protocol.size(), endpoint,
                                     audit);
}

std::wstring ActivityJson(std::wstring_view id = L"A1",
                          std::wstring_view title = L"Synthetic activity",
                          std::wstring_view start = L"2026-03-01 08:00:00",
                          std::wstring_view end = L"2026-03-01 09:00:00",
                          std::wstring_view extra = L"") {
  return L"{\"id\":\"" + std::wstring(id) + L"\",\"itemName\":\"" +
      std::wstring(title) + L"\",\"st\":\"" + std::wstring(start) +
      L"\",\"et\":\"" + std::wstring(end) + L"\"" +
      std::wstring(extra) + L"}";
}

std::wstring CalendarJson(std::wstring_view id = L"C1",
                          std::wstring_view title = L"Synthetic calendar",
                          std::wstring_view place = L"",
                          std::wstring_view start = L"2026-03-01 08:00:00",
                          std::wstring_view end = L"2026-03-01 09:00:00",
                          std::wstring_view extra = L"") {
  return L"{\"id\":\"" + std::wstring(id) + L"\",\"title\":\"" +
      std::wstring(title) + L"\",\"place\":\"" + std::wstring(place) +
      L"\",\"startTime\":\"" + std::wstring(start) + L"\",\"endTime\":\"" +
      std::wstring(end) + L"\"" + std::wstring(extra) + L"}";
}

template <typename T>
bool Rejected(const ParseResult<T>& result, Rejection reason) {
  return !result.value && result.rejection == reason;
}

bool FrameAndIdTests() {
  const std::wstring frame = LR"({"frameTree":{"frame":{"id":"F1","loaderId":"L1","url":"URL_SENTINEL?token=QUERY_SENTINEL"},"childFrames":[{"frame":{"id":"CHILD_SENTINEL","loaderId":"CHILD_LOADER_SENTINEL","headers":{"Cookie":"COOKIE_SENTINEL\u0041"}}}]},"unknown":"UNKNOWN_SENTINEL\u0041"})";
  DecodeAudit audit;
  auto binding = ParseFrameTree(frame.data(), frame.size(), &audit);
  if (!binding || binding.value->frame != L"F1" || binding.value->loader != L"L1" ||
      audit.identifier_values != 2 || audit.identifier_units != 4 ||
      audit.transport_body_values != 0) return false;
  const auto missing_loader = Replace(frame, L"\"loaderId\":\"L1\",", L"");
  if (!Rejected(ParseFrameTree(missing_loader.data(), missing_loader.size()), Rejection::loader))
    return false;
  const auto missing_frame = Replace(frame, L"\"id\":\"F1\",", L"");
  if (!Rejected(ParseFrameTree(missing_frame.data(), missing_frame.size()), Rejection::frame))
    return false;
  const auto escaped_key = Replace(frame, L"\"id\":\"F1\"", L"\"\\u0069d\":\"F1\"");
  if (!Rejected(ParseFrameTree(escaped_key.data(), escaped_key.size()), Rejection::transport))
    return false;
  const auto duplicate = Replace(frame, L"\"id\":\"F1\"", L"\"id\":\"F1\",\"id\":\"F2\"");
  if (!Rejected(ParseFrameTree(duplicate.data(), duplicate.size()), Rejection::transport))
    return false;
  const std::wstring request_id = LR"({"requestId":"R\u0031","headers":{"Cookie":"COOKIE_SENTINEL","set-cookie":"SET_COOKIE_SENTINEL"},"postData":"POST_SENTINEL\u0041","redirectResponse":{"url":"AUTH_SENTINEL?accessToken=QUERY_SENTINEL"}})";
  audit = {};
  const auto id = ParseRequestId(request_id.data(), request_id.size(), &audit);
  if (!id || *id.value != L"R1" || audit.identifier_values != 1 ||
      audit.identifier_units != 2 || audit.transport_body_values != 0) return false;
  const std::wstring allowed = L"{\"requestId\":\"aA09.-_:\"}";
  if (!ParseRequestId(allowed.data(), allowed.size())) return false;
  const std::wstring maximum = L"{\"requestId\":\"" + std::wstring(128, L'a') + L"\"}";
  const std::wstring too_long = L"{\"requestId\":\"" + std::wstring(129, L'a') + L"\"}";
  if (!ParseRequestId(maximum.data(), maximum.size()) ||
      ParseRequestId(too_long.data(), too_long.size())) return false;
  constexpr const wchar_t* invalid_identifiers[] = {
      L"\"\"", L"\"space here\"", L"\"slash/id\"", L"\"\\u0080\"", L"null", L"123"};
  for (const auto* value : invalid_identifiers) {
    const std::wstring json = L"{\"requestId\":" + std::wstring(value) + L"}";
    if (ParseRequestId(json.data(), json.size())) return false;
  }
  const std::wstring truncated = LR"({"requestId":"R1"})";
  if (ParseRequestId(truncated.data(), truncated.size() - 1) ||
      ParseRequestId(nullptr, 0) || ParseFrameTree(nullptr, 0)) return false;
  return true;
}

bool ContextAndScriptTests() {
  const std::wstring within = LR"({"frameId":"F1","url":"URL_SENTINEL?token=QUERY_SENTINEL","navigationType":"historyApi"})";
  DecodeAudit within_audit;
  const auto within_frame = ParseWithinDocumentFrame(within.data(), within.size(), &within_audit);
  if (!within_frame || *within_frame.value != L"F1" ||
      within_audit.identifier_values != 1 || within_audit.identifier_units != 2 ||
      within_audit.business_values != 0 || within_audit.transport_body_values != 0) return false;
  for (const std::wstring invalid : {LR"({})", LR"({"frameId":null})",
      LR"({"frameId":""})", LR"({"frameId":"F1","frameId":"F2"})"}) {
    if (ParseWithinDocumentFrame(invalid.data(), invalid.size())) return false;
  }
  for (const auto& [json, expected] : std::vector<std::pair<std::wstring,bool>>{
      {LR"({"executionContextId":7,"executionContextUniqueId":"U7"})", true},
      {LR"({"executionContextId":8,"executionContextUniqueId":"U8"})", false},
      {LR"({"executionContextId":7})", true},
      {LR"({"executionContextUniqueId":"U8"})", false}}) {
    const auto parsed = IsContextDestroyed(json.data(), json.size(), 7, L"U7");
    if (!parsed || *parsed.value != expected) return false;
  }
  for (const std::wstring json : {LR"({})", LR"({"executionContextId":7,"executionContextUniqueId":"U8"})"})
    if (IsContextDestroyed(json.data(), json.size(), 7, L"U7")) return false;
  const std::wstring context = LR"({"context":{"id":7,"uniqueId":"CTX-1","origin":"https://young.ustc.edu.cn","name":"CONTEXT_NAME_SENTINEL","auxData":{"isDefault":true,"type":"default","frameId":"F1"}}})";
  DecodeAudit audit;
  const auto accepted_context = ParseDefaultContext(
      context.data(), context.size(), L"F1", kOrigin, &audit);
  if (!accepted_context || accepted_context.value->id != 7 ||
      accepted_context.value->unique_id != L"CTX-1" ||
      audit.identifier_values != 2 || audit.identifier_units != 7 ||
      audit.business_values != 0 || audit.business_units != 0) return false;
  for (const auto& rejected_context : {
           Replace(context, L"\"frameId\":\"F1\"", L"\"frameId\":\"F2\""),
           Replace(context, kOrigin, L"https://young.ustc.edu.cn.evil"),
           Replace(context, L"\"isDefault\":true", L"\"isDefault\":false"),
           Replace(context, L"\"id\":7", L"\"id\":0"),
           Replace(context, L"\"uniqueId\":\"CTX-1\",", L"")}) {
    if (ParseDefaultContext(rejected_context.data(), rejected_context.size(),
                            L"F1", kOrigin)) return false;
  }

  constexpr std::wstring_view marker = L"native://young-step-marker";
  const std::wstring parsed = L"{\"scriptId\":\"S-11\",\"url\":\"" +
      std::wstring(marker) + L"\",\"executionContextId\":7," +
      L"\"sourceText\":\"SOURCE_SENTINEL\"}";
  audit = {};
  const auto step = ParseStepScript(parsed.data(), parsed.size(), marker, 7, &audit);
  if (!step || *step.value != L"S-11" || audit.identifier_values != 1 ||
      audit.identifier_units != 4) return false;
  const auto wrong_context = Replace(parsed, L"\"executionContextId\":7",
                                     L"\"executionContextId\":8");
  const auto marker_only_in_text = Replace(
      Replace(parsed, marker, L"native://other"), L"SOURCE_SENTINEL", marker);
  if (!Rejected(ParseStepScript(wrong_context.data(), wrong_context.size(), marker, 7),
                Rejection::target) ||
      !Rejected(ParseStepScript(marker_only_in_text.data(), marker_only_in_text.size(),
                                marker, 7), Rejection::target)) return false;
  const std::wstring maximum_script = L"{\"scriptId\":\"" + std::wstring(128, L'S') +
      L"\",\"url\":\"" + std::wstring(marker) + L"\",\"executionContextId\":7}";
  const std::wstring overlong_script = L"{\"scriptId\":\"" + std::wstring(129, L'S') +
      L"\",\"url\":\"" + std::wstring(marker) + L"\",\"executionContextId\":7}";
  if (!ParseStepScript(maximum_script.data(), maximum_script.size(), marker, 7) ||
      ParseStepScript(overlong_script.data(), overlong_script.size(), marker, 7))
    return false;

  const std::wstring compiled = LR"({"scriptId":"S-11","executionContextId":7})";
  const auto compiled_id = ParseCompiledScriptId(compiled.data(), compiled.size());
  if (!compiled_id || *compiled_id.value != L"S-11") return false;
  const std::wstring compile_error =
      LR"({"scriptId":"S-11","exceptionDetails":{"text":"EXCEPTION_SENTINEL"}})";
  audit = {};
  if (ParseCompiledScriptId(compile_error.data(), compile_error.size(), &audit) ||
      audit.identifier_values != 0) return false;
  return true;
}

std::wstring CallFrameJson(std::wstring_view script_id) {
  return L"{\"functionName\":\"FUNCTION_SENTINEL\",\"scriptId\":\"" +
      std::wstring(script_id) +
      L"\",\"url\":\"FRAME_URL_SENTINEL\",\"lineNumber\":0,\"columnNumber\":1}";
}

std::wstring ParentStackEvent(size_t parent_count,
                              std::wstring_view deepest_script_id) {
  std::wstring event = L"{\"initiator\":{\"type\":\"script\",\"stack\":{";
  for (size_t level = 0; level < parent_count; ++level) {
    event += L"\"callFrames\":[" + CallFrameJson(L"OTHER") + L"]";
    event += L",\"parent\":{";
  }
  event += L"\"callFrames\":[" + CallFrameJson(deepest_script_id) + L"]";
  event.append(parent_count, L'}');
  event += L"}}}";
  return event;
}

bool InitiatorTests() {
  const std::wstring direct = L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[" +
      CallFrameJson(L"OTHER") + L"," + CallFrameJson(L"REGISTERED") + L"]}}}";
  DecodeAudit audit;
  const auto found = HasInitiatorScript(direct.data(), direct.size(), L"REGISTERED", &audit);
  if (!found || !*found.value || audit.identifier_values != 2 ||
      audit.identifier_units != 15 || audit.business_values != 0) return false;

  const std::wstring async_parent =
      L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[" +
      CallFrameJson(L"OTHER") + L"],\"parent\":{\"callFrames\":[" +
      CallFrameJson(L"REGISTERED") + L"]}}}}";
  audit = {};
  const auto async_found = HasInitiatorScript(
      async_parent.data(), async_parent.size(), L"REGISTERED", &audit);
  if (!async_found || !*async_found.value || audit.identifier_values != 2)
    return false;

  const std::wstring pending_parent_id =
      L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[" +
      CallFrameJson(L"OTHER") + L"],\"parentId\":{\"id\":\"TRACE-ID\"}}}}";
  if (!Rejected(HasInitiatorScript(pending_parent_id.data(), pending_parent_id.size(),
                                  L"REGISTERED"), Rejection::target)) return false;
  const std::wstring found_before_parent_id =
      L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[" +
      CallFrameJson(L"REGISTERED") + L"],\"parentId\":{\"id\":\"TRACE-ID\"}}}}";
  if (!HasInitiatorScript(found_before_parent_id.data(), found_before_parent_id.size(),
                          L"REGISTERED")) return false;
  const std::wstring ambiguous_chain =
      L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[" +
      CallFrameJson(L"OTHER") + L"],\"parent\":{\"callFrames\":[" +
      CallFrameJson(L"REGISTERED") + L"]},\"parentId\":{\"id\":\"TRACE-ID\"}}}}";
  if (!Rejected(HasInitiatorScript(ambiguous_chain.data(), ambiguous_chain.size(),
                                  L"REGISTERED"), Rejection::target)) return false;

  const std::wstring wrong_kind =
      Replace(direct, L"\"type\":\"script\"", L"\"type\":\"parser\"");
  const std::wstring missing_frame_field =
      Replace(direct, L",\"columnNumber\":1", L"");
  const std::wstring no_stack = LR"({"initiator":{"type":"script"}})";
  const auto absent = HasInitiatorScript(direct.data(), direct.size(), L"ABSENT");
  if (!Rejected(absent, Rejection::target) ||
      !Rejected(HasInitiatorScript(wrong_kind.data(), wrong_kind.size(), L"REGISTERED"),
               Rejection::target) ||
      !Rejected(HasInitiatorScript(missing_frame_field.data(), missing_frame_field.size(),
                                   L"REGISTERED"), Rejection::transport) ||
      !Rejected(HasInitiatorScript(no_stack.data(), no_stack.size(), L"REGISTERED"),
               Rejection::target)) return false;

  std::wstring many_frames = L"{\"initiator\":{\"type\":\"script\",\"stack\":{\"callFrames\":[";
  for (size_t index = 0; index < 129; ++index) {
    if (index != 0) many_frames += L",";
    many_frames += CallFrameJson(L"OTHER");
  }
  many_frames += L"]}}}";
  if (!Rejected(HasInitiatorScript(many_frames.data(), many_frames.size(), L"REGISTERED"),
               Rejection::limit)) return false;

  const std::wstring deepest_valid = ParentStackEvent(31, L"REGISTERED");
  const std::wstring too_deep = ParentStackEvent(32, L"REGISTERED");
  if (!HasInitiatorScript(deepest_valid.data(), deepest_valid.size(), L"REGISTERED") ||
      !Rejected(HasInitiatorScript(too_deep.data(), too_deep.size(), L"REGISTERED"),
               Rejection::limit)) return false;
  return true;
}

bool RemoteResultTests() {
  const std::wstring object =
      LR"({"result":{"type":"object","objectId":"opaque:{id}=2","description":"DESCRIPTION_SENTINEL"}})";
  DecodeAudit audit;
  const auto object_id = ParseRemoteObjectId(object.data(), object.size(), &audit);
  if (!object_id || *object_id.value != L"opaque:{id}=2" ||
      audit.identifier_values != 1 || audit.identifier_units != 13 ||
      audit.business_values != 0) return false;
  const std::wstring exception = LR"({"result":{"type":"object","objectId":"OID"},"exceptionDetails":{"text":"EXCEPTION_SENTINEL"}})";
  audit = {};
  const std::wstring wrong_type =
      Replace(object, L"\"type\":\"object\"", L"\"type\":\"function\"");
  if (ParseRemoteObjectId(exception.data(), exception.size(), &audit) ||
      audit.identifier_values != 0 ||
      ParseRemoteObjectId(wrong_type.data(), wrong_type.size())) return false;
  const std::wstring max_object_id = L"{\"result\":{\"type\":\"object\",\"objectId\":\"" +
      std::wstring(4096, L'O') + L"\"}}";
  const std::wstring overlong_object_id = L"{\"result\":{\"type\":\"object\",\"objectId\":\"" +
      std::wstring(4097, L'O') + L"\"}}";
  if (!ParseRemoteObjectId(max_object_id.data(), max_object_id.size()) ||
      ParseRemoteObjectId(overlong_object_id.data(), overlong_object_id.size())) return false;

  const std::wstring compile_error = LR"({"scriptId":"S1","exceptionDetails":{"exception":{"description":"EXCEPTION_SENTINEL"}}})";
  if (ParseCompiledScriptId(compile_error.data(), compile_error.size())) return false;
  for (int expected = 0; expected <= 2; ++expected) {
    const std::wstring status = L"{\"result\":{\"type\":\"number\",\"value\":" +
        std::to_wstring(expected) + L"}}";
    const auto parsed = ParseRemoteStatus(status.data(), status.size());
    if (!parsed || *parsed.value != expected) return false;
  }
  const std::array<std::wstring, 4> invalid_statuses{
      LR"({"result":{"type":"number","value":3}})",
      LR"({"result":{"type":"number","value":1.5}})",
      LR"({"result":{"type":"number","value":"1"}})",
      LR"({"result":{"type":"number","value":1},"exceptionDetails":{"text":"EXCEPTION_SENTINEL"}})"};
  for (const auto& invalid : invalid_statuses) {
    if (ParseRemoteStatus(invalid.data(), invalid.size())) return false;
  }
  return true;
}

bool TargetAndRequestTests() {
  constexpr std::array<std::wstring_view, 3> paths{kProfile, kSchedule, kActivities};
  constexpr std::array<Endpoint, 3> endpoints{Endpoint::profile, Endpoint::schedule, Endpoint::activities};
  for (size_t index = 0; index < paths.size(); ++index) {
    DecodeAudit audit;
    const auto accepted = RequestTest(RequestAt(paths[index]), &audit);
    if (!accepted || accepted.value->endpoint != endpoints[index] ||
        accepted.value->request_id != L"R1" || accepted.value->frame_id != L"F1" ||
        accepted.value->loader_id != L"L1" || accepted.value->redirected ||
        accepted.value->timestamp != 123.25 || audit.identifier_values != 3 ||
        audit.identifier_units != 6 || audit.transport_body_values != 0) return false;
  }
  constexpr const wchar_t* denied_paths[] = {
      L"/login", L"/login/callback", L"/mobile/item/enrolment", L"/mobile/item/enrolmentList/",
      L"/mobile/item/enrolmentUserList", L"/personal/scCalendar/delete", L"/other",
      L"/paramdesign/scMyInfo/info#fragment", L"/paramdesign/scMyInfo/info/../info",
      L"/paramdesign/scMyInfo/%69nfo"};
  for (const auto* path : denied_paths) {
    DecodeAudit audit;
    const auto result = RequestTest(RequestAt(path), &audit);
    if (!Rejected(result, Rejection::target) || audit.identifier_values != 0) return false;
  }
  const auto unknown_post = Replace(RequestAt(L"/login", L",\"postData\":\"POST_SENTINEL\""),
                                    L"\"GET\"", L"\"POST\"");
  if (!Rejected(RequestTest(unknown_post), Rejection::target)) return false;
  const auto wrong_origin = Replace(RequestAt(kProfile), kOrigin, L"https://young.ustc.edu.cn.evil");
  const auto auth = Replace(RequestAt(kProfile), kOrigin, L"https://id.ustc.edu.cn");
  const auto escaped_url = Replace(RequestAt(kProfile), L"https", L"\\u0068ttps");
  if (!Rejected(RequestTest(wrong_origin), Rejection::target) ||
      !Rejected(RequestTest(auth), Rejection::target) ||
      !Rejected(RequestTest(escaped_url), Rejection::target)) return false;
  const auto fixture = Replace(Replace(RequestAt(kProfile), kOrigin, L"http://127.0.0.1:43210"),
                               kPrefix, L"/api");
  if (!ParseRequest(fixture.data(), fixture.size(), L"http://127.0.0.1:43210", L"/api"))
    return false;
  DecodeAudit audit;
  if (!Rejected(RequestTest(RequestAt(kProfile, L",\"postData\":\"POST_SENTINEL\\u0041\""), &audit), Rejection::method) ||
      audit.identifier_values != 0) return false;
  if (!Rejected(RequestTest(RequestAt(kProfile, L",\"postData\":null")), Rejection::method) ||
      !Rejected(RequestTest(RequestAt(kProfile, L",\"hasPostData\":true")), Rejection::method) ||
      !Rejected(RequestTest(RequestAt(kProfile, L",\"hasPostData\":\"false\"")), Rejection::method) ||
      !RequestTest(RequestAt(kProfile, L",\"hasPostData\":false"))) return false;
  audit = {};
  if (!Rejected(RequestTest(RequestAt(kProfile, L"", LR"(,"redirectResponse":{"headers":{"Cookie":"REDIRECT_SENTINEL\u0041"},"url":"AUTH_SENTINEL?token=QUERY_SENTINEL"})"), &audit), Rejection::redirect) ||
      audit.identifier_values != 0) return false;
  if (!Rejected(RequestTest(RequestAt(kProfile, L"", L",\"redirectResponse\":null")), Rejection::redirect) ||
      !Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"GET\"", L"\"POST\"")), Rejection::method) ||
      !Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"GET\"", L"\"get\"")), Rejection::method) ||
      !Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"Fetch\"", L"\"Document\"")), Rejection::worker) ||
      !Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"frameId\":\"F1\",", L"")), Rejection::frame) ||
      !Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"loaderId\":\"L1\",", L"")), Rejection::loader)) return false;
  if (!RequestTest(Replace(RequestAt(kProfile), L"123.25", L"0")) ||
      !RequestTest(Replace(RequestAt(kProfile), L"123.25", L"1.25e2"))) return false;
  constexpr const wchar_t* bad_timestamps[] = {L"-1", L"-0", L"1e400", L"1e-400", L"null", L"\"123\""};
  for (const auto* value : bad_timestamps) {
    if (!Rejected(RequestTest(Replace(RequestAt(kProfile), L"123.25", value)), Rejection::transport))
      return false;
  }
  if (!Rejected(RequestTest(Replace(RequestAt(kProfile), L"\"timestamp\":123.25,", L"")), Rejection::transport))
    return false;
  return true;
}

bool ResponseTests() {
  for (const auto path : {kProfile, kSchedule, kActivities}) {
    DecodeAudit audit;
    const auto accepted = ResponseTest(ResponseAt(path), &audit);
    if (!accepted || accepted.value->status != 200 || audit.identifier_values != 3 ||
        audit.identifier_units != 6 || audit.transport_body_values != 0) return false;
  }
  const auto normal = ResponseAt(kProfile);
  if (!Rejected(ResponseTest(ResponseAt(L"/login")), Rejection::target)) return false;
  for (const auto* name : {L"fromServiceWorker", L"fromDiskCache", L"fromPrefetchCache"}) {
    const auto reason = std::wstring_view(name) == L"fromServiceWorker" ? Rejection::worker : Rejection::cache;
    const std::wstring field = L"\"" + std::wstring(name) + L"\":false";
    if (!Rejected(ResponseTest(Replace(normal, field, L"\"" + std::wstring(name) + L"\":true")), reason) ||
        !Rejected(ResponseTest(Replace(normal, field + L",", L"")), reason) ||
        !Rejected(ResponseTest(Replace(normal, field, L"\"" + std::wstring(name) + L"\":null")), reason) ||
        !Rejected(ResponseTest(Replace(normal, field, L"\"" + std::wstring(name) + L"\":\"false\"")), reason))
      return false;
  }
  for (const auto* status : {L"200.0", L"2e2", L"0.2e3", L"20000e-2"}) {
    if (!ResponseTest(Replace(normal, L"\"status\":200", L"\"status\":" + std::wstring(status))))
      return false;
  }
  for (const auto* status : {L"201", L"-200", L"200.00001", L"2e2000", L"\"200\"", L"null"}) {
    if (!Rejected(ResponseTest(Replace(normal, L"\"status\":200", L"\"status\":" + std::wstring(status))), Rejection::transport))
      return false;
  }
  if (!Rejected(ResponseTest(Replace(normal, L"application/json", L"text/html")), Rejection::transport) ||
      !Rejected(ResponseTest(Replace(normal, L"\"frameId\":\"F1\",", L"")), Rejection::frame) ||
      !Rejected(ResponseTest(Replace(normal, L"\"loaderId\":\"L1\",", L"")), Rejection::loader) ||
      !Rejected(ResponseTest(Replace(normal, L"\"XHR\"", L"\"Other\"")), Rejection::worker)) return false;
  return true;
}

bool MonotonicTests() {
  const std::wstring metrics = LR"({"metrics":[{"name":"UNKNOWN_SENTINEL\u0041","value":{"Cookie":"COOKIE_SENTINEL"}},{"name":"Timestamp","value":123.25},{"name":"Other","value":"VALUE_SENTINEL\u0041"}],"unknown":"UNKNOWN_SENTINEL"})";
  DecodeAudit audit;
  const auto accepted = ParseMonotonicBarrier(metrics.data(), metrics.size(), &audit);
  if (!accepted || *accepted.value != 123.25 || audit.identifier_values != 0 ||
      audit.identifier_units != 0 || audit.transport_body_values != 0) return false;
  if (ParseMonotonicBarrier(nullptr, 0)) return false;
  const auto duplicate = Replace(metrics, L"{\"name\":\"Other\",\"value\":\"VALUE_SENTINEL\\u0041\"}",
                                 L"{\"name\":\"Timestamp\",\"value\":123.25}");
  if (!Rejected(ParseMonotonicBarrier(duplicate.data(), duplicate.size()), Rejection::transport))
    return false;
  const auto missing = Replace(metrics, L"\"Timestamp\"", L"\"OtherTimestamp\"");
  if (!Rejected(ParseMonotonicBarrier(missing.data(), missing.size()), Rejection::transport))
    return false;
  for (const auto* value : {L"0", L"-1", L"1e400", L"1e-400", L"null", L"\"123\""}) {
    const auto invalid = Replace(metrics, L"123.25", value);
    if (!Rejected(ParseMonotonicBarrier(invalid.data(), invalid.size()), Rejection::transport))
      return false;
  }
  const auto exponential = Replace(metrics, L"123.25", L"1.25e2");
  const auto number = ParseMonotonicBarrier(exponential.data(), exponential.size());
  return number && *number.value == 125;
}

bool ProfileAndListTests() {
  const std::wstring profile = LR"({"success":true,"code":200,"result":{"loginCode":"LOGIN_SENTINEL\u0041","username":"NAME_SENTINEL","unknown":{"deep":["UNKNOWN_SENTINEL\u0041"]}}})";
  DecodeAudit audit;
  const auto observed = BodyTest(profile, Endpoint::profile, &audit);
  if (!observed || observed.value->profile.success != SuccessKind::true_value ||
      observed.value->profile.code != ValueKind::number ||
      observed.value->profile.result != ValueKind::object ||
      observed.value->profile.loginCode != ValueKind::string ||
      observed.value->profile.username != ValueKind::string ||
      audit.identifier_values != 0 || audit.identifier_units != 0 ||
      audit.transport_body_values != 1 || audit.transport_body_units != profile.size()) return false;
  constexpr std::array<const wchar_t*, 7> values{L"", L"null", L"true", L"23.4e2", L"\"VALUE_SENTINEL\\u0041\"", L"[]", L"{}"};
  constexpr std::array<ValueKind, 7> kinds{ValueKind::absent, ValueKind::null_value, ValueKind::boolean,
      ValueKind::number, ValueKind::string, ValueKind::array, ValueKind::object};
  for (size_t index = 0; index < values.size(); ++index) {
    const std::wstring body = L"{\"success\":false,\"code\":null,\"result\":{" +
        (index == 0 ? std::wstring() : L"\"loginCode\":" + std::wstring(values[index])) + L"}}";
    const auto result = BodyTest(body, Endpoint::profile);
    if (!result || result.value->profile.success != SuccessKind::false_value ||
        result.value->profile.code != ValueKind::null_value ||
        result.value->profile.loginCode != kinds[index] ||
        result.value->profile.username != ValueKind::absent) return false;
  }
  const auto empty = BodyTest(LR"({"success":true,"code":"CODE_SENTINEL","result":{"records":[],"total":0}})", Endpoint::schedule);
  if (!empty || empty.value->list.records != ValueKind::array || empty.value->list.count != 0 ||
      empty.value->list.total != ValueKind::number || empty.value->list.id != ValueKind::absent ||
      empty.value->list.date != ValueKind::absent) return false;
  const auto nonempty = BodyTest(LR"({"success":true,"result":{"records":[{"id":3,"title":"TITLE_SENTINEL","date":null,"startTime":[],"endTime":{"opaque":"UNKNOWN_SENTINEL"}},{"id":"ID_SENTINEL","title":null,"date":"DATE_SENTINEL","startTime":[],"endTime":false}],"total":"TOTAL_SENTINEL"}})", Endpoint::activities);
  if (!nonempty || nonempty.value->endpoint != Endpoint::activities || nonempty.value->list.count != 2 ||
      nonempty.value->list.id != ValueKind::mixed || nonempty.value->list.title != ValueKind::mixed ||
      nonempty.value->list.date != ValueKind::mixed || nonempty.value->list.startTime != ValueKind::array ||
      nonempty.value->list.endTime != ValueKind::mixed || nonempty.value->list.total != ValueKind::string)
    return false;
  const auto absent_mixed = BodyTest(LR"({"result":{"records":[{}, {"id":1}]}})", Endpoint::schedule);
  if (!absent_mixed || absent_mixed.value->list.id != ValueKind::mixed ||
      absent_mixed.value->list.title != ValueKind::absent ||
      absent_mixed.value->list.success != SuccessKind::other) return false;
  const auto null_records = BodyTest(LR"({"success":1,"result":{"records":null,"total":{}}})", Endpoint::activities);
  if (!null_records || null_records.value->list.records != ValueKind::null_value ||
      null_records.value->list.total != ValueKind::object || null_records.value->list.count != 0 ||
      null_records.value->list.success != SuccessKind::other) return false;
  const auto null_result = BodyTest(LR"({"success":false,"result":null})", Endpoint::schedule);
  if (!null_result || null_result.value->list.result != ValueKind::null_value ||
      null_result.value->list.records != ValueKind::absent) return false;
  if (!Rejected(BodyTest(LR"({"result":{"records":[null]}})", Endpoint::schedule), Rejection::body) ||
      !Rejected(BodyTest(L"[]", Endpoint::profile), Rejection::body)) return false;
  return true;
}

bool SecretAndSyntaxTests() {
  for (const auto* key : {L"Token", L"aCcEsStOkEn", L"REFRESHTOKEN", L"Password", L"COOKIE", L"Session", L"Authentication"}) {
    const std::wstring body = L"{\"success\":true,\"result\":{\"loginCode\":\"LOGIN_SENTINEL\",\"unknown\":[{\"" +
        std::wstring(key) + L"\":\"SECRET_SENTINEL\\u0041\"}]}}";
    DecodeAudit audit;
    if (!Rejected(BodyTest(body, Endpoint::profile, &audit), Rejection::body) ||
        audit.identifier_values != 0 || audit.identifier_units != 0 ||
        audit.transport_body_values != 1 || audit.transport_body_units != body.size()) return false;
  }
  constexpr const wchar_t* invalid_bodies[] = {
      LR"({"success":true,"success":false})", LR"({"result":{"loginCode":1,"loginCode":2}})",
      LR"({"result":{"records":[{"id":1,"id":2}]}})", LR"({"\u0073uccess":true})",
      LR"({"unknown":{"\u0074oken":"SECRET_SENTINEL"}})",
      LR"({"unknown":"\q"})", LR"({"unknown":"\uD800"})", LR"({"unknown":"\uDC00"})",
      LR"({"unknown":"\uD800\u0041"})", LR"({"result":{},})"};
  for (const auto* body : invalid_bodies) {
    if (!Rejected(BodyTest(body, Endpoint::schedule), Rejection::body)) return false;
  }
  if (!BodyTest(LR"({"unknown":"\uD83D\uDE00","result":{"records":[]}})", Endpoint::schedule))
    return false;
  for (const auto* number : {L"01", L"-01", L"1.", L"1e", L"1e+", L"--1", L"+1", L"NaN", L"Infinity", L".1", L"0x12", L"1 2"}) {
    const std::wstring json = L"{\"requestId\":\"R1\",\"unknown\":" + std::wstring(number) + L"}";
    DecodeAudit audit;
    if (!Rejected(ParseRequestId(json.data(), json.size(), &audit), Rejection::transport) ||
        audit.identifier_values != 0) return false;
  }
  const auto escaped_unknown_key = Replace(RequestAt(kProfile), L"\"Cookie\"", L"\"\\u0043ookie\"");
  const auto duplicate_unknown_key = Replace(RequestAt(kProfile), L"\"Cookie\":\"COOKIE_SENTINEL\\u0041\"",
      L"\"Cookie\":\"COOKIE_SENTINEL\\u0041\",\"Cookie\":\"OTHER_SENTINEL\"");
  if (!Rejected(RequestTest(escaped_unknown_key), Rejection::transport) ||
      !Rejected(RequestTest(duplicate_unknown_key), Rejection::transport)) return false;
  const auto legal = Envelope(LR"({"result":{}})");
  for (const auto protocol : {
      Replace(legal, L"\"base64Encoded\":false", L"\"base64Encoded\":true"),
      Replace(legal, L"\"base64Encoded\":false", L"\"base64Encoded\":null"),
      Replace(legal, L",\"base64Encoded\":false", L""),
      Replace(legal, L"\"base64Encoded\":false", L"\"base64Encoded\":false,\"extra\":\"EXTRA_SENTINEL\""),
      Replace(legal, L"\"base64Encoded\":false", L"\"base64Encoded\":false,\"base64Encoded\":false")}) {
    DecodeAudit audit;
    if (!Rejected(ProjectResponseBody(protocol.data(), protocol.size(), Endpoint::profile, &audit), Rejection::body) ||
        audit.transport_body_values != 0 || audit.identifier_values != 0) return false;
  }
  return true;
}

bool BusinessProjectionTests() {
  const std::wstring profile =
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC_USER_01","loginCode":"LOGIN_SENTINEL\u0041","unknown":{"deep":"UNKNOWN_SENTINEL\u0041"}}})";
  DecodeAudit audit;
  const auto profile_result = BusinessTest(profile, Endpoint::profile, &audit);
  const std::wstring expected_profile =
      L"{\"success\":true,\"code\":200,\"result\":{\"username\":\"SYNTHETIC_USER_01\"}}";
  if (!profile_result || *profile_result.value != expected_profile ||
      profile_result.value->find(L"LOGIN_SENTINEL") != std::wstring::npos ||
      profile_result.value->find(L"UNKNOWN_SENTINEL") != std::wstring::npos ||
      audit.transport_body_values != 1 || audit.transport_body_units != profile.size() ||
      audit.business_values != 1 || audit.business_units != 17 ||
      audit.identifier_values != 0) return false;

  const std::wstring activity = ActivityJson(
      L"A1", L"Synthetic \\u0041", L"2026-03-01 08:00:00",
      L"2026-03-01 09:00:00",
      LR"(,"applySt":null,"applyEt":"2026-02-28 07:00:00","placeInfo":"Hall \"A\"","opaque":"UNKNOWN_SENTINEL\u0041")");
  const std::wstring activity_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      activity + L"],\"total\":1}}";
  audit = {};
  const auto activity_result = BusinessTest(activity_body, Endpoint::activities, &audit);
  const std::wstring expected_activity =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[{\"id\":\"A1\",\"itemName\":\"Synthetic A\",\"st\":\"2026-03-01 08:00:00\",\"et\":\"2026-03-01 09:00:00\",\"applySt\":null,\"applyEt\":\"2026-02-28 07:00:00\",\"placeInfo\":\"Hall \\\"A\\\"\"}],\"total\":1}}";
  if (!activity_result || *activity_result.value != expected_activity ||
      activity_result.value->find(L"UNKNOWN_SENTINEL") != std::wstring::npos ||
      audit.business_values != 6 || audit.business_units != 78 ||
      audit.identifier_values != 0) return false;

  const std::wstring calendar = CalendarJson(
      L"C1", L"Synthetic calendar", L"", L"2026-03-01 08:00:00",
      L"2026-03-01 09:00:00", LR"(,"itemId":"","userId":"USER_SENTINEL")");
  const std::wstring calendar_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      calendar + L"],\"total\":1}}";
  const auto calendar_result = BusinessTest(calendar_body, Endpoint::schedule);
  if (!calendar_result ||
      calendar_result.value->find(L"\"itemId\":\"\"") == std::wstring::npos ||
      calendar_result.value->find(L"userId") != std::wstring::npos ||
      calendar_result.value->find(L"USER_SENTINEL") != std::wstring::npos) return false;
  const std::wstring missing_item_id = CalendarJson();
  const std::wstring missing_item_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      missing_item_id + L"],\"total\":1}}";
  const auto no_link = BusinessTest(missing_item_body, Endpoint::schedule);
  if (!no_link || no_link.value->find(L"itemId") != std::wstring::npos) return false;
  if (!BusinessTest(
          LR"({"success":true,"code":200,"result":{"records":[],"total":0}})",
          Endpoint::schedule) ||
      !BusinessTest(
          LR"({"success":true,"code":200,"result":{"records":[],"total":10000}})",
          Endpoint::activities)) return false;

  const std::wstring calendar_date_shape = CalendarJson(
      L"C1", L"Synthetic calendar", L"", L"2026-02-31 08:00:00",
      L"2026-02-31 09:00:00");
  const std::wstring calendar_date_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      calendar_date_shape + L"],\"total\":1}}";
  if (!BusinessTest(calendar_date_body, Endpoint::schedule)) return false;

  constexpr const wchar_t* invalid_profile_bodies[] = {
      LR"({"success":false,"code":200,"result":{"username":"SYNTHETIC_USER_01"}})",
      LR"({"success":true,"code":"200","result":{"username":"SYNTHETIC_USER_01"}})",
      LR"({"success":true,"code":200,"result":{}})",
      LR"({"success":true,"code":200,"result":{"username":1}})",
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC\u0000USER"}})",
      LR"({"success":true,"code":200,"result":{"username":"\u2003"}})"};
  for (const auto* body : invalid_profile_bodies) {
    if (BusinessTest(body, Endpoint::profile)) return false;
  }
  const auto maximum_username = BusinessTest(
      L"{\"success\":true,\"code\":200,\"result\":{\"username\":\"" +
          std::wstring(64, L'U') + L"\"}}", Endpoint::profile);
  if (!maximum_username || BusinessTest(
          L"{\"success\":true,\"code\":200,\"result\":{\"username\":\"" +
              std::wstring(65, L'U') + L"\"}}", Endpoint::profile)) return false;

  const std::wstring max_activity = ActivityJson(
      std::wstring(256, L'I'), std::wstring(2048, L'T'),
      L"2026-03-01 08:00:00", L"2026-03-01 09:00:00",
      L",\"placeInfo\":\"" + std::wstring(2048, L'P') + L"\"");
  const std::wstring max_activity_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      max_activity + L"],\"total\":1}}";
  if (!BusinessTest(max_activity_body, Endpoint::activities)) return false;
  const std::wstring overlong_activity_id = ActivityJson(std::wstring(257, L'I'));
  const std::wstring overlong_activity_title = ActivityJson(L"A1", std::wstring(2049, L'T'));
  const std::wstring overlong_place_info = ActivityJson(
      L"A1", L"Synthetic activity", L"2026-03-01 08:00:00",
      L"2026-03-01 09:00:00", L",\"placeInfo\":\"" + std::wstring(2049, L'P') + L"\"");
  for (const auto& record : {overlong_activity_id, overlong_activity_title,
                             overlong_place_info}) {
    const std::wstring body =
        L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
        record + L"],\"total\":1}}";
    if (!Rejected(BusinessTest(body, Endpoint::activities), Rejection::body)) return false;
  }

  const std::wstring max_calendar = CalendarJson(
      std::wstring(256, L'I'), std::wstring(2048, L'T'), std::wstring(2048, L'P'),
      L"2026-03-01 08:00:00", L"2026-03-01 09:00:00",
      L",\"itemId\":\"" + std::wstring(256, L'R') + L"\"");
  const std::wstring max_calendar_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      max_calendar + L"],\"total\":1}}";
  if (!BusinessTest(max_calendar_body, Endpoint::schedule)) return false;
  const std::wstring overlong_calendar_id = CalendarJson(std::wstring(257, L'I'));
  const std::wstring overlong_calendar_title =
      CalendarJson(L"C1", std::wstring(2049, L'T'));
  const std::wstring overlong_calendar_place =
      CalendarJson(L"C1", L"Synthetic calendar", std::wstring(2049, L'P'));
  const std::wstring overlong_calendar_item = CalendarJson(
      L"C1", L"Synthetic calendar", L"", L"2026-03-01 08:00:00",
      L"2026-03-01 09:00:00", L",\"itemId\":\"" +
          std::wstring(257, L'R') + L"\"");
  for (const auto& record : {overlong_calendar_id, overlong_calendar_title,
                             overlong_calendar_place, overlong_calendar_item}) {
    const std::wstring body =
        L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
        record + L"],\"total\":1}}";
    if (!Rejected(BusinessTest(body, Endpoint::schedule), Rejection::body)) return false;
  }
  const std::wstring valid_calendar = CalendarJson();
  const std::array<std::wstring, 7> invalid_calendar{
      Replace(valid_calendar, L"\"id\":\"C1\"", L"\"id\":1"),
      Replace(valid_calendar, L"\"title\":\"Synthetic calendar\"", L"\"title\":null"),
      Replace(valid_calendar, L"\"place\":\"\"", L"\"place\":false"),
      Replace(valid_calendar, L"\"startTime\":\"2026-03-01 08:00:00\"", L"\"startTime\":\"2026/03/01 08:00:00\""),
      Replace(valid_calendar, L"\"endTime\":\"2026-03-01 09:00:00\"", L"\"endTime\":\"\""),
      Replace(valid_calendar, L"\"endTime\":\"2026-03-01 09:00:00\"", L"\"endTime\":\"2026-03-01 09:00:00\",\"itemId\":1"),
      Replace(valid_calendar, L"\"endTime\":\"2026-03-01 09:00:00\"", L"\"endTime\":\"2026-03-01 09:00:00\",\"itemId\":\"   \"")};
  for (const auto& record : invalid_calendar) {
    const std::wstring body =
        L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
        record + L"],\"total\":1}}";
    if (BusinessTest(body, Endpoint::schedule)) return false;
  }
  const std::wstring null_item = CalendarJson(
      L"C1", L"Synthetic calendar", L"", L"2026-03-01 08:00:00",
      L"2026-03-01 09:00:00", L",\"itemId\":null");
  const std::wstring null_item_body =
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[" +
      null_item + L"],\"total\":1}}";
  if (!BusinessTest(null_item_body, Endpoint::schedule)) return false;

  const std::wstring valid_activity = ActivityJson();
  const std::wstring valid_activity_prefix = L"{\"success\":true,\"code\":200,\"result\":{\"records\":[";
  const std::wstring valid_activity_suffix = L"],\"total\":1}}";
  const std::array<std::wstring, 8> malformed_business{
      valid_activity_prefix + Replace(valid_activity, L"\"id\":\"A1\"", L"\"id\":1") + valid_activity_suffix,
      valid_activity_prefix + Replace(valid_activity, L"\"itemName\":\"Synthetic activity\"", L"\"itemName\":null") + valid_activity_suffix,
      valid_activity_prefix + Replace(valid_activity, L"\"st\":\"2026-03-01 08:00:00\"", L"\"st\":\"2026-03-01 8:00:00\"") + valid_activity_suffix,
      valid_activity_prefix + Replace(valid_activity, L"\"et\":\"2026-03-01 09:00:00\"", L"\"et\":\"2026-03-01T09:00:00\"") + valid_activity_suffix,
      valid_activity_prefix + Replace(valid_activity, L"\"et\":\"2026-03-01 09:00:00\"", L"\"et\":\"2026-03-01 09:00:00\",\"applySt\":1") + valid_activity_suffix,
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[],\"total\":10001}}",
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":[],\"total\":1.0}}",
      L"{\"success\":true,\"code\":200,\"result\":{\"records\":null,\"total\":0}}"};
  for (const auto& body : malformed_business) {
    const auto endpoint = body.find(L"username") == std::wstring::npos
        ? Endpoint::activities : Endpoint::profile;
    if (BusinessTest(body, endpoint)) return false;
  }

  std::wstring eleven_records = L"{\"success\":true,\"code\":200,\"result\":{\"records\":[";
  for (size_t index = 0; index < 10; ++index) {
    if (index != 0) eleven_records += L",";
    eleven_records += ActivityJson(L"A" + std::to_wstring(index));
  }
  eleven_records += L"],\"total\":10}}";
  if (!BusinessTest(eleven_records, Endpoint::activities)) return false;
  eleven_records.replace(eleven_records.find(L"\"total\":10"), 10,
                         L"\"total\":11");
  const size_t records_end = eleven_records.find(L"],\"total\":11");
  eleven_records.insert(records_end, L"," + ActivityJson(L"A10"));
  if (!Rejected(BusinessTest(eleven_records, Endpoint::activities), Rejection::limit))
    return false;

  const std::wstring secret_key =
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC_USER_01","unknown":{"aCcEsStOkEn":"SECRET_SENTINEL"}}})";
  const std::wstring escaped_key =
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC_USER_01","unknown":{"\u0074oken":"SECRET_SENTINEL"}}})";
  const std::wstring bad_unicode =
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC_USER_01","unknown":"\uD800"}})";
  if (!Rejected(BusinessTest(secret_key, Endpoint::profile), Rejection::body) ||
      !Rejected(BusinessTest(escaped_key, Endpoint::profile), Rejection::body) ||
      !Rejected(BusinessTest(bad_unicode, Endpoint::profile), Rejection::body)) return false;
  const std::wstring unicode_unknown =
      LR"({"success":true,"code":200,"result":{"username":"SYNTHETIC_USER_01","unknown":"\uD83D\uDE00_UNKNOWN_SENTINEL"}})";
  const auto unicode_result = BusinessTest(unicode_unknown, Endpoint::profile);
  if (!unicode_result || unicode_result.value->find(L"UNKNOWN_SENTINEL") != std::wstring::npos)
    return false;
  return true;
}

bool LimitAndLabelTests() {
  const std::wstring metadata(kMetadataChars + 1, L' ');
  const std::wstring protocol(kBodyProtocolChars + 1, L' ');
  if (!Rejected(ParseRequestId(metadata.data(), metadata.size()), Rejection::limit) ||
      !Rejected(ProjectResponseBody(protocol.data(), protocol.size(), Endpoint::profile), Rejection::limit) ||
      !Rejected(ProjectBusinessResponseBody(protocol.data(), protocol.size(), Endpoint::profile),
                Rejection::limit))
    return false;
  for (size_t depth : {size_t{31}, size_t{32}}) {
    const std::wstring json = L"{\"requestId\":\"R1\",\"unknown\":" + std::wstring(depth, L'[') +
                              L"0" + std::wstring(depth, L']') + L"}";
    const auto parsed = ParseRequestId(json.data(), json.size());
    if ((depth == 31 && !parsed) || (depth == 32 && !Rejected(parsed, Rejection::limit)))
      return false;
  }
  std::wstring members = L"{";
  for (size_t index = 0; index <= kMaximumObjectMembers; ++index) {
    if (index != 0) members += L",";
    members += L"\"key" + std::to_wstring(index) + L"\":0";
  }
  members += L"}";
  if (!Rejected(ParseRequestId(members.data(), members.size()), Rejection::limit)) return false;
  const std::wstring giant_key = L"{\"" + std::wstring(257, L'k') + L"\":0}";
  if (!Rejected(ParseRequestId(giant_key.data(), giant_key.size()), Rejection::limit)) return false;
  const std::wstring giant_number = L"{\"unknown\":" + std::wstring(129, L'1') + L"}";
  if (!Rejected(ParseRequestId(giant_number.data(), giant_number.size()), Rejection::limit)) return false;
  std::wstring records = L"{\"result\":{\"records\":[";
  for (size_t index = 0; index < kMaximumRecords; ++index) {
    if (index != 0) records += L",";
    records += L"{\"id\":\"ID_SENTINEL\"}";
  }
  const auto maximum = BodyTest(records + L"]}}", Endpoint::schedule);
  if (!maximum || maximum.value->list.count != kMaximumRecords || maximum.value->list.id != ValueKind::string)
    return false;
  if (!Rejected(BodyTest(records + L",{}]}}", Endpoint::schedule), Rejection::limit)) return false;
  std::wstring array = L"{\"unknown\":[";
  for (size_t index = 0; index <= kMaximumArrayElements; ++index) {
    if (index != 0) array += L",";
    array += L"0";
  }
  if (!Rejected(BodyTest(array + L"]}", Endpoint::profile), Rejection::limit)) return false;
  std::wstring nodes = L"{\"unknown\":[";
  for (size_t index = 0; index < 10000; ++index) {
    if (index != 0) nodes += L",";
    nodes += L"[0,0,0,0,0,0,0,0,0,0,0,0,0,0]";
  }
  if (!Rejected(BodyTest(nodes + L"]}", Endpoint::profile), Rejection::limit)) return false;
  std::array<wchar_t, 4> erase{L'a', L'b', L'c', L'd'};
  SecureErase(erase.data(), erase.size());
  for (const auto value : erase) if (value != L'\0') return false;
  SecureErase(nullptr, 0);
  return std::string_view(RejectionLabel(Rejection::stale)) == "stale" &&
         std::string_view(RejectionLabel(Rejection::body)) == "body" &&
         std::string_view(ValueKindLabel(ValueKind::null_value)) == "null" &&
         std::string_view(ValueKindLabel(ValueKind::mixed)) == "mixed" &&
         std::string_view(SuccessKindLabel(SuccessKind::unobserved)) == "unobserved" &&
         std::string_view(SuccessKindLabel(SuccessKind::true_value)) == "true" &&
         std::string_view(SuccessKindLabel(SuccessKind::false_value)) == "false" &&
         std::string_view(SuccessKindLabel(SuccessKind::other)) == "other";
}

}  // namespace

bool RunYoungProjectionSelfTests() {
  try {
    return FrameAndIdTests() && ContextAndScriptTests() && InitiatorTests() &&
           RemoteResultTests() && TargetAndRequestTests() && ResponseTests() &&
           MonotonicTests() && ProfileAndListTests() && SecretAndSyntaxTests() &&
           BusinessProjectionTests() && LimitAndLabelTests();
  } catch (...) {
    return false;
  }
}

}  // namespace young_probe

#ifdef YOUNG_PROJECTION_TEST_MAIN
int main() { return young_probe::RunYoungProjectionSelfTests() ? 0 : 1; }
#endif
