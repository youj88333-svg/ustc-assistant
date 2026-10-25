#ifndef RUNNER_YOUNG_READ_ONLY_OBSERVER_H_
#define RUNNER_YOUNG_READ_ONLY_OBSERVER_H_

#include <WebView2.h>
#include <wrl.h>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <vector>

#include "young_json_projection.h"

namespace young_probe {

struct ObservedProfile : ProfileProjection { int observations = 0; };
struct ObservedList : ListProjection { int observations = 0; };
struct Snapshot {
  bool listening = false;
  int accepted = 0;
  int rejected = 0;
  Rejection last_rejection = Rejection::none;
  ObservedProfile profile;
  ObservedList schedule;
  ObservedList activities;
};

// One current-document candidate operation. Receives SDK-owned metadata as a
// borrowed buffer; only the fixed projection module may inspect that buffer.
// No request headers, credentials, storage or raw business values are retained.
class ReadOnlyObserver final : public std::enable_shared_from_this<ReadOnlyObserver> {
 public:
  using Completion = std::function<void(const char*)>;
  ReadOnlyObserver(ICoreWebView2* core, std::wstring origin,
                   std::function<bool()> current, std::function<void(int)> pending);
  ~ReadOnlyObserver();
  void Start(Completion completion);
  void Stop(Completion completion);
  bool Invalidate();
  bool Busy() const { return pending_calls_ != 0 || starting_; }
  const Snapshot& snapshot() const { return snapshot_; }
#ifdef _DEBUG
  static bool RunAdmissionSelfTests();
#endif

 private:
  enum class Event { request, response, finished, failed, cached };
  struct Receiver {
    Microsoft::WRL::ComPtr<ICoreWebView2DevToolsProtocolEventReceiver> receiver;
    EventRegistrationToken token{};
    bool subscribed = false;
  };
  struct Request {
    Endpoint endpoint;
    bool response = false;
  };
  using RawCompletion = std::function<void(HRESULT, const wchar_t*, size_t)>;
  bool Current() const;
  bool Listening() const;
  void Call(const wchar_t* method, const std::wstring& parameters, size_t limit,
            RawCompletion completion, bool stopping = false);
  bool Subscribe();
  bool Detach();
  void OnEvent(Event event, const wchar_t* raw, size_t length);
  void Reject(Rejection reason);
  void RejectOutstanding(Rejection reason);
  void ProjectBody(const std::wstring& id, Endpoint endpoint);

  Microsoft::WRL::ComPtr<ICoreWebView2> core_;
  std::wstring origin_;
  std::function<bool()> current_;
  std::function<void(int)> pending_;
  std::vector<Receiver> receivers_;
  std::map<std::wstring, Request> requests_;
  FrameBinding frame_;
  double barrier_ = 0;
  bool invalid_ = false;
  bool starting_ = false;
  int pending_calls_ = 0;
  size_t pending_bodies_ = 0;
  Snapshot snapshot_;
};

}  // namespace young_probe
#endif  // RUNNER_YOUNG_READ_ONLY_OBSERVER_H_
