#include "webview_host.h"

#include <wrl.h>

#include <future>
#include <iostream>

#include "util/rohelper.h"
#include "util/string_converter.h"

using namespace Microsoft::WRL;

// static
std::unique_ptr<WebviewHost> WebviewHost::Create(
    WebviewPlatform* platform, std::optional<std::wstring> user_data_directory,
    std::optional<std::wstring> browser_exe_path,
    std::optional<std::string> arguments,
    BrowserProcessExitedCallback browser_process_exited_callback) {
  wil::com_ptr<CoreWebView2EnvironmentOptions> opts;
  if (arguments.has_value()) {
    opts = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
    const std::wstring warguments = util::Utf16FromUtf8(arguments.value());
    opts->put_AdditionalBrowserArguments(warguments.c_str());
  }

  std::promise<HRESULT> result_promise;
  wil::com_ptr<ICoreWebView2Environment> env;
  auto result = CreateCoreWebView2EnvironmentWithOptions(
      browser_exe_path.has_value() ? browser_exe_path->c_str() : nullptr,
      user_data_directory.has_value() ? user_data_directory->c_str() : nullptr,
      opts.get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [&promise = result_promise, &ptr = env](
              HRESULT r, ICoreWebView2Environment* env) -> HRESULT {
            // The in-parameter is only borrowed for the duration of this
            // call, so take a real reference (AddRef) and publish it before
            // unblocking the waiting thread below.
            ptr = env;
            promise.set_value(r);
            return S_OK;
          })
          .Get());

  if (SUCCEEDED(result)) {
    // Blocks the calling thread until environment creation settles. This is
    // a one-time, fast operation and has been the field-proven behavior of
    // this plugin; the completion handler does not depend on this thread's
    // message pump being drained.
    result = result_promise.get_future().get();
    if (SUCCEEDED(result) && env) {
      auto webview_env3 = env.try_query<ICoreWebView2Environment3>();
      auto webview_env5 = env.try_query<ICoreWebView2Environment5>();
      if (webview_env3 && webview_env5) {
        auto host = std::unique_ptr<WebviewHost>(new WebviewHost(
            platform, std::move(webview_env3), std::move(webview_env5)));
        if (host->RegisterBrowserProcessExited(
                std::move(browser_process_exited_callback))) {
          return host;
        }
      }
    }
  }

  return {};
}

WebviewHost::WebviewHost(WebviewPlatform* platform,
                         wil::com_ptr<ICoreWebView2Environment3> webview_env,
                         wil::com_ptr<ICoreWebView2Environment5> webview_env5)
    : webview_env_(webview_env), webview_env5_(webview_env5) {
  compositor_ = platform->graphics_context()->CreateCompositor();
}

WebviewHost::~WebviewHost() {
  if (browser_process_exited_callback_state_) {
    browser_process_exited_callback_state_->Clear();
  }
  if (webview_env5_ && browser_process_exited_token_.has_value()) {
    webview_env5_->remove_BrowserProcessExited(
        browser_process_exited_token_.value());
    browser_process_exited_token_.reset();
  }
}

void WebviewHost::BrowserProcessExitedCallbackState::Invoke(
    uint32_t browser_process_id,
    COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND exit_kind) {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (callback_) {
    callback_(browser_process_id, exit_kind);
  }
}

void WebviewHost::BrowserProcessExitedCallbackState::Clear() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  callback_ = nullptr;
}

bool WebviewHost::RegisterBrowserProcessExited(
    BrowserProcessExitedCallback callback) {
  if (!callback) {
    return true;
  }

  auto callback_state = std::make_shared<BrowserProcessExitedCallbackState>(
      std::move(callback));
  EventRegistrationToken token{};
  auto hr = webview_env5_->add_BrowserProcessExited(
      Callback<ICoreWebView2BrowserProcessExitedEventHandler>(
          [callback_state](ICoreWebView2Environment*,
                           ICoreWebView2BrowserProcessExitedEventArgs* args)
              -> HRESULT {
            if (!args) {
              return S_OK;
            }

            UINT32 browser_process_id = 0;
            COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND exit_kind{};
            if (FAILED(args->get_BrowserProcessId(&browser_process_id)) ||
                browser_process_id == 0 ||
                FAILED(args->get_BrowserProcessExitKind(&exit_kind))) {
              // A release identity that cannot be read is never treated as
              // a match.  The barrier remains pending rather than risking a
              // user-data-folder delete against an unknown process.
              return S_OK;
            }

            callback_state->Invoke(static_cast<uint32_t>(browser_process_id),
                                   exit_kind);
            return S_OK;
          })
          .Get(),
      &token);
  if (FAILED(hr)) {
    return false;
  }

  browser_process_exited_callback_state_ = std::move(callback_state);
  browser_process_exited_token_ = token;
  return true;
}

void WebviewHost::CreateWebview(HWND hwnd, HWND flutter_view_hwnd,
                                bool offscreen_only, bool owns_window,
                                WebviewCreationCallback callback) {
  CreateWebViewCompositionController(
      hwnd, [=, self = this](
                wil::com_ptr<ICoreWebView2CompositionController> controller,
                std::unique_ptr<WebviewCreationError> error) {
        if (controller) {
          std::unique_ptr<Webview> webview(
              new Webview(std::move(controller), self, hwnd, flutter_view_hwnd,
                          owns_window, offscreen_only));
          if (webview->IsValid()) {
            callback(std::move(webview), nullptr);
          } else {
            // The composition controller was created, but the webview itself
            // failed to initialize (unsupported runtime interface or surface
            // creation failure). It would silently no-op every call, so report
            // an error instead of handing back a dead instance.
            callback(nullptr, WebviewCreationError::create(
                                  E_FAIL, "Webview initialization failed."));
          }
        } else {
          callback(nullptr, std::move(error));
        }
      });
}

void WebviewHost::CreateWebViewPointerInfo(
    PointerInfoCreationCallback callback) {
  wil::com_ptr<ICoreWebView2PointerInfo> pointer;
  auto hr = webview_env_->CreateCoreWebView2PointerInfo(pointer.put());

  if (FAILED(hr)) {
    callback(nullptr, WebviewCreationError::create(
                          hr, "CreateWebViewPointerInfo failed."));
  } else {
    callback(std::move(pointer), nullptr);
  }
}

void WebviewHost::CreateWebViewCompositionController(
    HWND hwnd, CompositionControllerCreationCallback callback) {
  auto hr = webview_env_->CreateCoreWebView2CompositionController(
      hwnd,
      Callback<
          ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
          [callback](HRESULT hr,
                     ICoreWebView2CompositionController* compositionController)
              -> HRESULT {
            if (SUCCEEDED(hr)) {
              callback(
                  wil::com_ptr<ICoreWebView2CompositionController>(
                      compositionController),
                  nullptr);
            } else {
              callback(nullptr, WebviewCreationError::create(
                                    hr,
                                    "CreateCoreWebView2CompositionController "
                                    "completion handler failed."));
            }

            return S_OK;
          })
          .Get());

  if (FAILED(hr)) {
    callback(nullptr,
             WebviewCreationError::create(
                 hr, "CreateCoreWebView2CompositionController failed."));
  }
}
