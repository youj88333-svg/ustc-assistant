#ifndef RUNNER_YOUNG_BUSINESS_READER_H_
#define RUNNER_YOUNG_BUSINESS_READER_H_

#include <WebView2.h>
#include <wrl.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "young_json_projection.h"

namespace young_probe {

// Executes only fixed, page-owned GET actions. Page Promise values are ignored;
// business evidence comes from the associated native network body projection.
class BusinessReader final : public std::enable_shared_from_this<BusinessReader> {
 public:
  using Completion = std::function<void(const char*)>;
  using PollCompletion = std::function<void(const char*, bool, const std::wstring&)>;
  BusinessReader(ICoreWebView2* core, std::wstring origin, std::wstring marker_prefix,
      std::function<bool()> current, std::function<void(int)> pending);
  ~BusinessReader();
  void Start(Completion completion);
  void Dispatch(int64_t step, Endpoint endpoint, int page, const std::wstring& day,
      Completion completion);
  void Poll(int64_t step, PollCompletion completion);
  void Finish(Completion completion);
  bool Invalidate(const char* reason = "nativeContext");
  bool Busy() const { return pending_calls_ != 0; }
  bool Active() const { return active_ && !invalid_; }
  bool RouteGuardReady() const {
    // Main-frame Page events are already bound after Page.enable's ack,
    // including while the Runtime/context setup is still starting.
    return Current() && page_enabled_ && !frame_.frame.empty();
  }
  const char* failure() const { return failure_; }
  const char* failure_reason() const { return failure_reason_ ? failure_reason_ : "nativeContext"; }

 private:
  enum class Event { route, context, destroyed, cleared, script, request, response, finished, failed, cached };
  struct Receiver {
    Microsoft::WRL::ComPtr<ICoreWebView2DevToolsProtocolEventReceiver> receiver;
    EventRegistrationToken token{};
    bool subscribed = false;
  };
  using RawCompletion = std::function<void(HRESULT, const wchar_t*, size_t)>;
  bool Current() const;
  void Call(const wchar_t*, const std::wstring&, size_t, RawCompletion);
  bool Subscribe();
  bool Detach();
  void Fail(const char* error, const char* reason = "sourceFailure");
  void OnEvent(Event, const wchar_t*, size_t);
  void ClearStep();
  void TryStart();
  void TryRun();
  void CompleteDispatch(const char* error);
  void Run();
  void ReadBody();
  std::wstring Expression(Endpoint, int page, const std::wstring& day) const;

  Microsoft::WRL::ComPtr<ICoreWebView2> core_;
  std::wstring origin_;
  std::wstring marker_prefix_;
  std::function<bool()> current_;
  std::function<void(int)> pending_;
  std::vector<Receiver> receivers_;
  FrameBinding frame_;
  DefaultContext context_{};
  bool have_context_ = false;
  double barrier_ = 0;
  bool active_ = false;
  bool page_enabled_ = false;
  bool invalid_ = false;
  bool starting_ = false;
  bool start_prepared_ = false;
  Completion start_completion_;
  Completion dispatch_completion_;
  bool polling_ = false;
  int pending_calls_ = 0;
  const char* failure_ = nullptr;
  const char* failure_reason_ = nullptr;
  int64_t step_ = 0;
  Endpoint endpoint_ = Endpoint::profile;
  std::wstring marker_;
  std::wstring registered_script_;
  std::wstring compiled_script_;
  std::wstring object_id_;
  std::wstring request_id_;
  std::wstring projection_;
  bool run_issued_ = false;
  bool response_seen_ = false;
  bool body_requested_ = false;
  bool step_complete_ = true;
};
}  // namespace young_probe
#endif
