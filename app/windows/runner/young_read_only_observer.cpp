#include "young_read_only_observer.h"

#include <string_view>
#include <utility>

namespace young_probe {
using Microsoft::WRL::Callback;
namespace {
constexpr wchar_t kPrefix[] = L"/login/wisdom-group-learning-bg";
constexpr size_t kMaximumPendingRequests = 64;
bool CaptureSlotAvailable(size_t starts, size_t bodies, int accepted) {
  if (starts >= kMaximumPendingRequests || bodies >= kMaximumPendingRequests || accepted < 0)
    return false;
  const size_t in_flight = starts + bodies;
  return in_flight < kMaximumPendingRequests &&
      static_cast<size_t>(accepted) + in_flight < 1024;
}
size_t BoundedLength(const wchar_t* raw, size_t limit) {
  return raw ? wcsnlen_s(raw, limit + 1) : 0;
}
bool EmptyAck(HRESULT status, const wchar_t* raw, size_t length) {
  return SUCCEEDED(status) && raw && std::wstring_view(raw, length) == L"{}";
}
struct OwnedEventBuffer {
  LPWSTR raw = nullptr;
  ~OwnedEventBuffer() {
    // The SDK returns a terminated caller-owned allocation. The parse cap is
    // independent of erasing the complete allocation, including on failure.
    if (raw) SecureErase(raw, wcslen(raw));
    CoTaskMemFree(raw);
  }
};
}  // namespace

ReadOnlyObserver::ReadOnlyObserver(ICoreWebView2* core, std::wstring origin,
    std::function<bool()> current, std::function<void(int)> pending)
    : core_(core), origin_(std::move(origin)), current_(std::move(current)),
      pending_(std::move(pending)) {}
ReadOnlyObserver::~ReadOnlyObserver() { Detach(); }
#ifdef _DEBUG
bool ReadOnlyObserver::RunAdmissionSelfTests() {
  return CaptureSlotAvailable(0, 0, 0) && CaptureSlotAvailable(1, 62, 0) &&
      !CaptureSlotAvailable(0, 64, 0) && !CaptureSlotAvailable(1, 63, 0) &&
      !CaptureSlotAvailable(64, 0, 0) && !CaptureSlotAvailable(0, 1, 1023) &&
      !CaptureSlotAvailable(0, 0, 1024);
}
#endif

bool ReadOnlyObserver::Current() const {
  return core_ && !invalid_ && current_();
}
bool ReadOnlyObserver::Listening() const {
  return snapshot_.listening && Current();
}
void ReadOnlyObserver::Reject(Rejection reason) {
  if (snapshot_.rejected < 4096) ++snapshot_.rejected;
  snapshot_.last_rejection = reason;
}
void ReadOnlyObserver::RejectOutstanding(Rejection reason) {
  // An event that cannot be attributed may be a redirect of any in-flight
  // candidate. Discard all such starts; a later final response cannot reuse one.
  for (size_t index = 0; index < requests_.size(); ++index) Reject(reason);
  requests_.clear();
}

void ReadOnlyObserver::Call(const wchar_t* method, const std::wstring& parameters,
    size_t limit, RawCompletion completion, bool stopping) {
  if (!core_ || !current_() || (invalid_ && !stopping)) {
    completion(E_ABORT, nullptr, 0); return;
  }
  ++pending_calls_;
  pending_(1);
  auto self = shared_from_this();
  const HRESULT started = core_->CallDevToolsProtocolMethod(method, parameters.c_str(),
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
        [self, completion, limit, stopping](HRESULT status, LPCWSTR raw) -> HRESULT {
          --self->pending_calls_;
          // The SDK owns this borrowed completion buffer. Do not copy or
          // mutate it; app-owned decoded body temporaries are erased separately.
          if (!self->core_ || !self->current_() || (self->invalid_ && !stopping))
            completion(E_ABORT, nullptr, 0);
          else {
            const size_t length = BoundedLength(raw, limit);
            completion(length > limit ? E_BOUNDS : status, raw,
                       length > limit ? 0 : length);
          }
          self->pending_(-1);
          return S_OK;
        }).Get());
  if (FAILED(started)) {
    --pending_calls_;
    completion(started, nullptr, 0);
    pending_(-1);
  }
}

bool ReadOnlyObserver::Subscribe() {
  const std::weak_ptr<ReadOnlyObserver> weak = shared_from_this();
  const std::pair<const wchar_t*, Event> events[] = {
    {L"Network.requestWillBeSent", Event::request},
    {L"Network.responseReceived", Event::response},
    {L"Network.loadingFinished", Event::finished},
    {L"Network.loadingFailed", Event::failed},
    {L"Network.requestServedFromCache", Event::cached},
  };
  for (const auto& entry : events) {
    Receiver binding;
    const Event event = entry.second;
    if (FAILED(core_->GetDevToolsProtocolEventReceiver(entry.first, &binding.receiver)) ||
        !binding.receiver || FAILED(binding.receiver->add_DevToolsProtocolEventReceived(
          Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
            [weak, event](ICoreWebView2*, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT {
              if (auto self = weak.lock(); self && self->Listening()) {
                OwnedEventBuffer buffer;
                // Check the operation before asking the SDK for a composite
                // network event, including when a stale callback was queued.
                const HRESULT received = args->get_ParameterObjectAsJson(&buffer.raw);
                const size_t length = BoundedLength(buffer.raw, kMetadataChars);
                if (SUCCEEDED(received) && buffer.raw && length <= kMetadataChars && self->Listening())
                  self->OnEvent(event, buffer.raw, length);
                else if (self->Listening())
                  self->RejectOutstanding(length > kMetadataChars ? Rejection::limit : Rejection::transport);
              }
              return S_OK;
            }).Get(), &binding.token))) {
      Detach(); return false;
    }
    binding.subscribed = true;
    receivers_.push_back(std::move(binding));
  }
  return true;
}

bool ReadOnlyObserver::Detach() {
  snapshot_.listening = false;
  requests_.clear();
  bool complete = true;
  for (auto& binding : receivers_) {
    if (binding.subscribed) {
      if (FAILED(binding.receiver->remove_DevToolsProtocolEventReceived(binding.token)))
        complete = false;
      else binding.subscribed = false;
    }
  }
  if (complete) receivers_.clear();
  return complete;
}
bool ReadOnlyObserver::Invalidate() {
  invalid_ = true;
  const bool complete = Detach();
  if (complete) core_.Reset();
  return complete;
}

void ReadOnlyObserver::Start(Completion completion) {
  if (!Current() || Busy() || snapshot_.listening) { completion("busy"); return; }
  starting_ = true;
  auto self = shared_from_this();
  auto finish = [self, completion](const char* error) {
    self->starting_ = false;
    if (error) self->Invalidate();
    completion(error);
  };
  Call(L"Page.getFrameTree", L"{}", kMetadataChars,
    [self, finish](HRESULT status, const wchar_t* raw, size_t length) {
      const auto frame = SUCCEEDED(status) ? ParseFrameTree(raw, length) : ParseResult<FrameBinding>{};
      if (!frame || !self->Current()) { finish("staleResult"); return; }
      self->frame_ = *frame.value;
      if (!self->Subscribe()) { finish("sourceFailed"); return; }
      self->Call(L"Performance.enable", L"{\"timeDomain\":\"timeTicks\"}", kMetadataChars,
        [self, finish](HRESULT enabled, const wchar_t* ack, size_t ack_length) {
          if (!EmptyAck(enabled, ack, ack_length)) { finish("sourceFailed"); return; }
          self->Call(L"Network.enable",
            L"{\"maxTotalBufferSize\":2097152,\"maxResourceBufferSize\":1048576,\"maxPostDataSize\":0}",
            kMetadataChars, [self, finish](HRESULT network, const wchar_t* ack2, size_t ack2_length) {
              if (!EmptyAck(network, ack2, ack2_length)) { finish("sourceFailed"); return; }
              self->Call(L"Performance.getMetrics", L"{}", kMetadataChars,
                [self, finish](HRESULT metrics, const wchar_t* raw_metrics, size_t metrics_length) {
                  const auto stamp = SUCCEEDED(metrics) ? ParseMonotonicBarrier(raw_metrics, metrics_length)
                      : ParseResult<double>{};
                  if (!stamp || !self->Current()) { finish("staleResult"); return; }
                  self->barrier_ = *stamp.value;
                  self->snapshot_.listening = true;
                  finish(nullptr);
                });
            });
        });
    });
}

void ReadOnlyObserver::Stop(Completion completion) {
  if (!Listening() || starting_) { completion("staleResult"); return; }
  invalid_ = true;
  if (!Detach()) { completion("cleanupPending"); return; }
  auto self = shared_from_this();
  Call(L"Network.disable", L"{}", kMetadataChars,
    [self, completion](HRESULT network, const wchar_t* raw, size_t length) {
      if (!EmptyAck(network, raw, length)) { completion("sourceFailed"); return; }
      self->Call(L"Performance.disable", L"{}", kMetadataChars,
        [self, completion](HRESULT metrics, const wchar_t* ack, size_t ack_length) {
          const bool success = EmptyAck(metrics, ack, ack_length);
          self->core_.Reset();
          completion(success ? nullptr : "sourceFailed");
        }, true);
    }, true);
}

void ReadOnlyObserver::OnEvent(Event event, const wchar_t* raw, size_t length) {
  if (!Listening()) return;
  if (event == Event::request) {
    const auto existing_id = ParseRequestId(raw, length);
    if (!existing_id) {
      RejectOutstanding(existing_id.rejection); return;
    }
    if (existing_id && requests_.erase(*existing_id.value) != 0) {
      // Redirects reuse the request ID, including redirects to a noncandidate
      // path. The original accepted start can never authorize its final body.
      Reject(Rejection::redirect); return;
    }
    const auto parsed = ParseRequest(raw, length, origin_, kPrefix);
    if (!parsed) {
      if (parsed.rejection != Rejection::target && parsed.rejection != Rejection::limit)
        Reject(parsed.rejection);
      return;
    }
    const auto& request = *parsed.value;
    if (request.frame_id != frame_.frame) { Reject(Rejection::frame); return; }
    if (request.loader_id != frame_.loader) { Reject(Rejection::loader); return; }
    if (request.timestamp < barrier_) { Reject(Rejection::stale); return; }
    if (!CaptureSlotAvailable(requests_.size(), pending_bodies_, snapshot_.accepted)) {
      Reject(Rejection::limit); return;
    }
    requests_.emplace(request.request_id, Request{request.endpoint});
    return;
  }
  const auto id = ParseRequestId(raw, length);
  if (!id) { RejectOutstanding(id.rejection); return; }
  const auto found = requests_.find(*id.value);
  if (found == requests_.end()) return;
  if (event == Event::response) {
    const auto parsed = ParseResponse(raw, length, origin_, kPrefix);
    Rejection reason = parsed.rejection;
    if (parsed) {
      const auto& response = *parsed.value;
      reason = response.frame_id != frame_.frame ? Rejection::frame :
          response.loader_id != frame_.loader ? Rejection::loader :
          response.endpoint != found->second.endpoint ? Rejection::target :
          found->second.response ? Rejection::transport : Rejection::none;
    }
    if (reason != Rejection::none || !parsed) {
      Reject(reason == Rejection::none ? Rejection::transport : reason);
      requests_.erase(found);
    } else found->second.response = true;
    return;
  }
  const auto endpoint = found->second.endpoint;
  const bool response_seen = found->second.response;
  requests_.erase(found);
  if (event == Event::cached) { Reject(Rejection::cache); return; }
  if (event == Event::failed || !response_seen) { Reject(Rejection::transport); return; }
  ProjectBody(*id.value, endpoint);
}

void ReadOnlyObserver::ProjectBody(const std::wstring& id, Endpoint endpoint) {
  if (!Listening()) return;
  // IDs have already passed the private ASCII identifier grammar; no page
  // supplied parameter or arbitrary URL enters this fixed protocol command.
  const auto parameters = L"{\"requestId\":\"" + id + L"\"}";
  auto self = shared_from_this();
  ++pending_bodies_;
  Call(L"Network.getResponseBody", parameters, kBodyProtocolChars,
    [self, endpoint](HRESULT status, const wchar_t* raw, size_t length) {
      --self->pending_bodies_;
      if (!self->Listening()) return;
      const auto body = SUCCEEDED(status) ? ProjectResponseBody(raw, length, endpoint)
          : ParseResult<BodyProjection>{};
      if (!body) {
        self->Reject(body.rejection == Rejection::none ? Rejection::body : body.rejection);
        return;
      }
      if (self->snapshot_.accepted >= 1024) { self->Reject(Rejection::limit); return; }
      ++self->snapshot_.accepted;
      if (endpoint == Endpoint::profile) {
        auto& output = self->snapshot_.profile;
        const int observations = output.observations + 1;
        static_cast<ProfileProjection&>(output) = body.value->profile;
        output.observations = observations;
      } else {
        auto& output = endpoint == Endpoint::schedule ? self->snapshot_.schedule : self->snapshot_.activities;
        const int observations = output.observations + 1;
        static_cast<ListProjection&>(output) = body.value->list;
        output.observations = observations;
      }
    });
}
}  // namespace young_probe
