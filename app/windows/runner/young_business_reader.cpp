#include "young_business_reader.h"

#include <utility>
#include <string_view>

namespace young_probe {
using Microsoft::WRL::Callback;
namespace {
constexpr wchar_t kPrefix[] = L"/login/wisdom-group-learning-bg";
size_t Length(const wchar_t* raw, size_t cap) { return raw ? wcsnlen_s(raw, cap + 1) : 0; }
bool Ack(HRESULT hr, const wchar_t* raw, size_t size) {
  return SUCCEEDED(hr) && raw && std::wstring_view(raw, size) == L"{}";
}
std::wstring Quote(std::wstring_view text) {
  std::wstring value = L"\"";
  for (const auto ch : text) {
    if (ch == L'\"' || ch == L'\\') value += L'\\';
    if (ch < 32) return L"null";
    value += ch;
  }
  return value + L"\"";
}
void Wipe(std::wstring& text) { SecureErase(text.data(), text.size()); text.clear(); }
struct EventBuffer {
  LPWSTR raw = nullptr;
  ~EventBuffer() { if (raw) SecureErase(raw, wcslen(raw)); CoTaskMemFree(raw); }
};
bool ValidDay(const std::wstring& day) {
  if (day.size() != 10 || day[4] != L'-' || day[7] != L'-') return false;
  for (size_t i = 0; i < day.size(); ++i)
    if (i != 4 && i != 7 && (day[i] < L'0' || day[i] > L'9')) return false;
  const int year = std::stoi(day.substr(0, 4));
  const int month = std::stoi(day.substr(5, 2));
  const int date = std::stoi(day.substr(8, 2));
  if (year < 1 || month < 1 || month > 12 || date < 1) return false;
  constexpr int lengths[] = {31,28,31,30,31,30,31,31,30,31,30,31};
  const bool leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  return date <= lengths[month - 1] + (month == 2 && leap ? 1 : 0);
}
}  // namespace

BusinessReader::BusinessReader(ICoreWebView2* core, std::wstring origin,
    std::wstring marker_prefix, std::function<bool()> current, std::function<void(int)> pending)
    : core_(core), origin_(std::move(origin)), marker_prefix_(std::move(marker_prefix)),
      current_(std::move(current)), pending_(std::move(pending)) {}
BusinessReader::~BusinessReader() { Detach(); ClearStep(); }
bool BusinessReader::Current() const { return core_ && !invalid_ && current_(); }
void BusinessReader::Fail(const char* error, const char* reason) {
  if (!failure_) failure_ = error;
  Invalidate(reason);
}
bool BusinessReader::Detach() {
  page_enabled_ = false;
  active_ = false;
  bool done = true;
  for (auto& binding : receivers_) {
    if (!binding.subscribed) continue;
    if (FAILED(binding.receiver->remove_DevToolsProtocolEventReceived(binding.token))) done = false;
    else binding.subscribed = false;
  }
  if (done) receivers_.clear();
  return done;
}
void BusinessReader::ClearStep() {
  Wipe(projection_); object_id_.clear(); request_id_.clear(); marker_.clear();
  registered_script_.clear(); compiled_script_.clear();
  run_issued_ = false; response_seen_ = false; body_requested_ = false;
}
bool BusinessReader::Invalidate(const char* reason) {
  if (!failure_reason_) failure_reason_ = reason;
  invalid_ = true;
  ClearStep();
  const bool done = Detach();
  if (done) core_.Reset();
  if (start_completion_) {
    auto completion = std::move(start_completion_);
    starting_ = false;
    completion(failure_ ? failure_ : "staleResult");
  }
  CompleteDispatch(failure_ ? failure_ : "staleResult");
  return done;
}
void BusinessReader::Call(const wchar_t* method, const std::wstring& parameters,
    size_t cap, RawCompletion completion) {
  if (!Current()) { completion(E_ABORT, nullptr, 0); return; }
  auto self = shared_from_this();
  ++pending_calls_; pending_(1);
  const HRESULT issued = core_->CallDevToolsProtocolMethod(method, parameters.c_str(),
    Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [self, cap, completion](HRESULT hr, LPCWSTR raw) -> HRESULT {
        const size_t length = Length(raw, cap);
        if (!self->Current() || length > cap) completion(E_ABORT, nullptr, 0);
        else completion(hr, raw, length);
        --self->pending_calls_; self->pending_(-1);
        return S_OK;
      }).Get());
  if (FAILED(issued)) {
    completion(issued, nullptr, 0);
    --pending_calls_; pending_(-1);
  }
}
bool BusinessReader::Subscribe() {
  const std::pair<const wchar_t*, Event> events[] = {
    {L"Page.navigatedWithinDocument", Event::route},
    {L"Runtime.executionContextCreated", Event::context},
    {L"Runtime.executionContextDestroyed", Event::destroyed},
    {L"Runtime.executionContextsCleared", Event::cleared},
    {L"Debugger.scriptParsed", Event::script},
    {L"Network.requestWillBeSent", Event::request},
    {L"Network.responseReceived", Event::response},
    {L"Network.loadingFinished", Event::finished},
    {L"Network.loadingFailed", Event::failed},
    {L"Network.requestServedFromCache", Event::cached}
  };
  const std::weak_ptr<BusinessReader> weak = shared_from_this();
  for (const auto& [name, event] : events) {
    Receiver binding;
    if (FAILED(core_->GetDevToolsProtocolEventReceiver(name, &binding.receiver)) ||
        FAILED(binding.receiver->add_DevToolsProtocolEventReceived(
          Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
            [weak, event](ICoreWebView2*, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT {
              if (auto self = weak.lock(); self && self->Current()) {
                EventBuffer buffer;
                const auto hr = args->get_ParameterObjectAsJson(&buffer.raw);
                const auto length = Length(buffer.raw, kMetadataChars);
                if (FAILED(hr) || !buffer.raw || length > kMetadataChars) self->Fail("invalidSnapshot");
                else self->OnEvent(event, buffer.raw, length);
              }
              return S_OK;
            }).Get(), &binding.token))) { Detach(); return false; }
    binding.subscribed = true; receivers_.push_back(std::move(binding));
  }
  return true;
}
void BusinessReader::Start(Completion completion) {
  if (!Current() || starting_ || Active()) { completion("busy"); return; }
  starting_ = true;
  start_completion_ = std::move(completion);
  auto self = shared_from_this();
  auto finish = [self](const char* error) {
    if (error) { self->Fail(error); return; }
    self->start_prepared_ = true;
    self->TryStart();
  };
  Call(L"Page.getFrameTree", L"{}", kMetadataChars,
    [self, finish](HRESULT hr, const wchar_t* raw, size_t length) {
      const auto frame = SUCCEEDED(hr) ? ParseFrameTree(raw, length) : ParseResult<FrameBinding>{};
      if (!frame) { self->Fail("staleResult", "nativeContext"); return; }
      self->frame_ = *frame.value;
      if (!self->Subscribe()) { finish("sourceFailed"); return; }
      // Each ack is a short CDP call. No SDK completion waits on a page Promise.
      auto methods = std::make_shared<std::vector<std::pair<std::wstring,std::wstring>>>(
        std::initializer_list<std::pair<std::wstring,std::wstring>>{
          {L"Page.enable", L"{}"}, {L"Runtime.enable", L"{}"}, {L"Debugger.enable", L"{}"},
          {L"Debugger.setAsyncCallStackDepth", L"{\"maxDepth\":32}"},
          {L"Performance.enable", L"{\"timeDomain\":\"timeTicks\"}"},
          {L"Network.enable", L"{\"maxTotalBufferSize\":2097152,\"maxResourceBufferSize\":1048576,\"maxPostDataSize\":0}"}
        });
      auto next = std::make_shared<std::function<void(size_t)>>();
      *next = [self, methods, finish, weak_next = std::weak_ptr<std::function<void(size_t)>>(next)](size_t index) {
        if (index == methods->size()) {
          self->Call(L"Performance.getMetrics", L"{}", kMetadataChars,
            [self, finish](HRESULT metrics, const wchar_t* body, size_t size) {
              const auto barrier = SUCCEEDED(metrics) ? ParseMonotonicBarrier(body, size) : ParseResult<double>{};
              if (!barrier) { finish("invalidSnapshot"); return; }
              self->barrier_ = *barrier.value; finish(nullptr);
            });
          return;
        }
        auto keep = weak_next.lock();
        self->Call((*methods)[index].first.c_str(), (*methods)[index].second, kMetadataChars,
          [self, finish, keep, index](HRESULT enabled, const wchar_t* ack, size_t ack_size) {
            // Debugger.enable includes a debuggerId; it is not an empty ack.
            if (FAILED(enabled) || !ack || (index != 2 && !Ack(enabled, ack, ack_size))) {
              finish("sourceFailed"); return;
            }
            if (index == 0) self->page_enabled_ = true;
            (*keep)(index + 1);
          });
      };
      (*next)(0);
    });
}
void BusinessReader::TryStart() {
  if (!Current() || !start_prepared_ || !have_context_ || !start_completion_) return;
  starting_ = false; active_ = true;
  auto completion = std::move(start_completion_);
  completion(nullptr);
}
std::wstring BusinessReader::Expression(Endpoint endpoint, int page, const std::wstring& day) const {
  const wchar_t* path = endpoint == Endpoint::profile ? L"/paramdesign/scMyInfo/info" :
    endpoint == Endpoint::schedule ? L"/personal/scCalendar/getPageUserList" : L"/mobile/item/enrolmentList";
  std::wstring params = L"{}";
  if (endpoint != Endpoint::profile) {
    params = L"{field:" + Quote(endpoint == Endpoint::schedule ?
      L"id,,number,title,place,startTime,endTime" : L"id,,action") +
      L",pageNo:" + std::to_wstring(page) + L",pageSize:10";
    if (endpoint == Endpoint::schedule) params += L",now:" + Quote(day);
    params += L"}";
  }
  return L"(()=>{'use strict';if(location.origin!==" + Quote(origin_) +
    L"||!location.pathname.startsWith('/login/sc-wisdom-group-learning/'))throw 0;"
    L"const m=window.webpackJsonp.push([[],{},[['0fea']]]);const f=m&&m.e;"
    L"if(typeof f!=='function'||Function.prototype.toString.call(f)!=="
    L"'function l(e,t){return Object(r[\"b\"])({url:e,method:\"get\",params:t,timeout:36e5})}')throw 0;"
    L"let s=0;const state=Object.freeze({status:()=>s});try{const p=f(" + Quote(path) + L"," + params +
    L");if(!p||typeof p.then!=='function')s=2;else p.then(()=>{s=1},()=>{s=2})}catch(_){s=2}return state;})()";
}
void BusinessReader::Dispatch(int64_t step, Endpoint endpoint, int page, const std::wstring& day,
    Completion completion) {
  if (!Active() || !Current() || Busy() || !step_complete_ || step != step_ + 1) {
    completion(failure_ ? failure_ : "busy"); return;
  }
  if ((endpoint == Endpoint::profile && (page != 0 || !day.empty())) ||
      (endpoint != Endpoint::profile && (page < 1 || page > 1000)) ||
      (endpoint == Endpoint::schedule ? !ValidDay(day) : !day.empty())) {
    completion("invalidSnapshot"); return;
  }
  ClearStep(); step_ = step; endpoint_ = endpoint; step_complete_ = false;
  dispatch_completion_ = std::move(completion);
  marker_ = marker_prefix_ + L"-" + std::to_wstring(step) + L".js";
  auto self = shared_from_this();
  // persistScript gives an authoritative scriptId before a business action is
  // dispatched. The compiled item belongs to this exact execution context.
  const std::wstring params = L"{\"expression\":" + Quote(Expression(endpoint, page, day)) +
    L",\"sourceURL\":" + Quote(marker_) + L",\"persistScript\":true,\"executionContextId\":" +
    std::to_wstring(context_.id) + L"}";
  Call(L"Runtime.compileScript", params, kMetadataChars,
    [self](HRESULT hr, const wchar_t* raw, size_t length) {
      const auto compiled = SUCCEEDED(hr) ? ParseCompiledScriptId(raw, length) : ParseResult<std::wstring>{};
      if (!compiled) { self->Fail("staleResult", "compiledScript"); return; }
      self->compiled_script_ = *compiled.value;
      self->TryRun();
    });
}
void BusinessReader::CompleteDispatch(const char* error) {
  if (!dispatch_completion_) return;
  auto completion = std::move(dispatch_completion_);
  completion(error);
}
void BusinessReader::TryRun() {
  if (!Current() || !dispatch_completion_ || compiled_script_.empty() || registered_script_.empty()) return;
  if (compiled_script_ != registered_script_) { Fail("staleResult", "compiledScript"); return; }
  Run();
}
void BusinessReader::Run() {
  if (!Current() || run_issued_ || compiled_script_.empty()) { Fail("staleResult", "compiledScript"); return; }
  run_issued_ = true;  // No retry if the native acknowledgement is lost.
  auto self = shared_from_this();
  const auto params = L"{\"scriptId\":" + Quote(compiled_script_) +
    L",\"executionContextId\":" + std::to_wstring(context_.id) +
    L",\"objectGroup\":" + Quote(marker_prefix_) +
    L",\"includeCommandLineAPI\":false,\"silent\":true,\"returnByValue\":false,\"awaitPromise\":false,\"generatePreview\":false}";
  Call(L"Runtime.runScript", params, kMetadataChars,
    [self](HRESULT hr, const wchar_t* raw, size_t length) {
      const auto object = SUCCEEDED(hr) ? ParseRemoteObjectId(raw, length) : ParseResult<std::wstring>{};
      if (!object) { self->Fail("sourceFailed"); return; }
      self->object_id_ = *object.value;
      self->CompleteDispatch(nullptr);
    });
}
void BusinessReader::Poll(int64_t step, PollCompletion completion) {
  if (!Active() || !Current() || step != step_ || step_complete_ || polling_ || object_id_.empty()) {
    completion(failure_ ? failure_ : "staleResult", false, L""); return;
  }
  polling_ = true;
  auto self = shared_from_this();
  Call(L"Runtime.callFunctionOn", L"{\"objectId\":" + Quote(object_id_) +
    L",\"functionDeclaration\":\"function(){return this.status()}\",\"silent\":true,\"returnByValue\":true,\"awaitPromise\":false,\"generatePreview\":false}",
    kMetadataChars, [self, completion](HRESULT hr, const wchar_t* raw, size_t length) {
      const auto state = SUCCEEDED(hr) ? ParseRemoteStatus(raw, length) : ParseResult<int>{};
      if (!state || *state.value == 2) {
        self->polling_ = false; self->Fail("sourceFailed"); completion("sourceFailed", false, L""); return;
      }
      if (*state.value == 0 || self->projection_.empty()) {
        self->polling_ = false; completion(nullptr, false, L""); return;
      }
      self->Call(L"Runtime.releaseObject", L"{\"objectId\":" + Quote(self->object_id_) + L"}", kMetadataChars,
        [self, completion](HRESULT released, const wchar_t* ack, size_t size) {
          self->polling_ = false;
          if (!Ack(released, ack, size)) { self->Fail("sourceFailed"); completion("sourceFailed", false, L""); return; }
          auto projection = std::move(self->projection_);
          self->step_complete_ = true;
          self->ClearStep();
          completion(nullptr, true, projection);
          Wipe(projection);
        });
    });
}
void BusinessReader::ReadBody() {
  body_requested_ = true;
  auto self = shared_from_this();
  const auto expected_step = step_;
  Call(L"Network.getResponseBody", L"{\"requestId\":" + Quote(request_id_) + L"}", kBodyProtocolChars,
    [self, expected_step](HRESULT hr, const wchar_t* raw, size_t length) {
      if (!self->Current() || self->step_ != expected_step) return;
      auto body = SUCCEEDED(hr) ? ProjectBusinessResponseBody(raw, length, self->endpoint_) : ParseResult<std::wstring>{};
      if (!body) { self->Fail("invalidSnapshot"); return; }
      self->projection_ = std::move(*body.value);
    });
}
void BusinessReader::OnEvent(Event event, const wchar_t* raw, size_t length) {
  if (!Current()) return;
  if (event == Event::route) {
    const auto frame = ParseWithinDocumentFrame(raw, length);
    if (!frame || *frame.value == frame_.frame) Fail("staleResult", "mainRoute");
    return;
  }
  if (event == Event::context) {
    const auto parsed = ParseDefaultContext(raw, length, frame_.frame, origin_);
    if (parsed) {
      if (have_context_ && (context_.id != parsed.value->id || context_.unique_id != parsed.value->unique_id)) {
        Fail("staleResult", "contextLost"); return;
      }
      context_ = *parsed.value; have_context_ = true; TryStart();
    }
    return;
  }
  if (event == Event::destroyed) {
    const auto destroyed = IsContextDestroyed(raw, length, context_.id, context_.unique_id);
    if (!destroyed || *destroyed.value) Fail("staleResult", "contextLost");
    return;
  }
  if (event == Event::cleared) {
    // Context loss revokes both the compiled item and the private status object.
    // Conservative rejection also covers unsupported destruction payloads.
    Fail("staleResult", "contextLost"); return;
  }
  if (event == Event::script) {
    if (marker_.empty()) return;
    const auto parsed = ParseStepScript(raw, length, marker_, context_.id);
    if (!parsed) return;
    if (!registered_script_.empty()) { Fail("staleResult", "compiledScript"); return; }
    registered_script_ = *parsed.value; TryRun(); return;
  }
  if (!active_ || !run_issued_ || step_complete_) return;
  const auto id = ParseRequestId(raw, length);
  if (!id) { Fail("invalidSnapshot"); return; }
  if (event == Event::request) {
    if (!request_id_.empty() && *id.value == request_id_) { Fail("invalidSnapshot"); return; }
    const auto request = ParseRequest(raw, length, origin_, kPrefix);
    if (!request || request.value->endpoint != endpoint_ || request.value->timestamp < barrier_ ||
        request.value->frame_id != frame_.frame || request.value->loader_id != frame_.loader) return;
    const auto owned = HasInitiatorScript(raw, length, compiled_script_);
    if (!owned || !*owned.value) return;
    if (!request_id_.empty()) { Fail("invalidSnapshot"); return; }
    request_id_ = *id.value; return;
  }
  if (*id.value != request_id_ || request_id_.empty()) return;
  if (event == Event::failed || event == Event::cached) { Fail("sourceFailed"); return; }
  if (event == Event::response) {
    const auto response = ParseResponse(raw, length, origin_, kPrefix);
    if (!response || response_seen_ || response.value->endpoint != endpoint_ ||
        response.value->frame_id != frame_.frame || response.value->loader_id != frame_.loader) {
      Fail("invalidSnapshot"); return;
    }
    response_seen_ = true; return;
  }
  if (event == Event::finished) {
    if (!response_seen_ || body_requested_) { Fail("invalidSnapshot"); return; }
    ReadBody();
  }
}
void BusinessReader::Finish(Completion completion) {
  if (!Active() || !Current() || !step_complete_ || Busy()) { completion(failure_ ? failure_ : "busy"); return; }
  auto self = shared_from_this();
  auto methods = std::make_shared<std::vector<std::pair<std::wstring,std::wstring>>>(
    std::initializer_list<std::pair<std::wstring,std::wstring>>{
      {L"Debugger.setAsyncCallStackDepth", L"{\"maxDepth\":0}"}, {L"Network.disable", L"{}"},
      {L"Debugger.disable", L"{}"}, {L"Performance.disable", L"{}"},
      {L"Runtime.disable", L"{}"}, {L"Page.disable", L"{}"}
    });
  // Detach before Runtime.disable, which can send context-cleared events.
  if (!Detach()) { Fail("cleanupPending"); completion("cleanupPending"); return; }
  auto next = std::make_shared<std::function<void(size_t)>>();
  *next = [self, methods, completion, weak_next = std::weak_ptr<std::function<void(size_t)>>(next)](size_t index) {
    if (index == methods->size()) { self->Invalidate(); completion(nullptr); return; }
    auto keep = weak_next.lock();
    self->Call((*methods)[index].first.c_str(), (*methods)[index].second, kMetadataChars,
      [self, completion, keep, index](HRESULT hr, const wchar_t* raw, size_t length) {
        if (!Ack(hr, raw, length)) { self->Fail("sourceFailed"); completion("sourceFailed"); return; }
        (*keep)(index + 1);
      });
  };
  (*next)(0);
}
}  // namespace young_probe
