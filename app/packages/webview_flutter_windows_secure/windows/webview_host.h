#pragma once

#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/com.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>

#include "graphics_context.h"
#include "webview.h"
#include "webview_platform.h"
#include "windows.ui.composition.h"

struct WebviewCreationError {
  HRESULT hr;
  std::string message;

  explicit WebviewCreationError(HRESULT hr, std::string message)
      : hr(hr), message(message) {}

  static std::unique_ptr<WebviewCreationError> create(
      HRESULT hr, const std::string message) {
    return std::make_unique<WebviewCreationError>(hr, message);
  }
};

class WebviewHost {
 public:
  using BrowserProcessExitedCallback = std::function<void(
      uint32_t, COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND)>;
  typedef std::function<void(std::unique_ptr<Webview>,
                             std::unique_ptr<WebviewCreationError>)>
      WebviewCreationCallback;
  typedef std::function<void(wil::com_ptr<ICoreWebView2CompositionController>,
                             std::unique_ptr<WebviewCreationError>)>
      CompositionControllerCreationCallback;
  typedef std::function<void(wil::com_ptr<ICoreWebView2PointerInfo>,
                             std::unique_ptr<WebviewCreationError>)>
      PointerInfoCreationCallback;

  static std::unique_ptr<WebviewHost> Create(
      WebviewPlatform* platform,
      std::optional<std::wstring> user_data_directory = std::nullopt,
      std::optional<std::wstring> browser_exe_path = std::nullopt,
      std::optional<std::string> arguments = std::nullopt,
      BrowserProcessExitedCallback browser_process_exited_callback = {});

  ~WebviewHost();

  void CreateWebview(HWND hwnd, HWND flutter_view_hwnd, bool offscreen_only,
                     bool owns_window, WebviewCreationCallback callback);

  void CreateWebViewPointerInfo(PointerInfoCreationCallback cb);

  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor()
      const {
    return compositor_;
  }

 private:
  class BrowserProcessExitedCallbackState {
   public:
    explicit BrowserProcessExitedCallbackState(
        BrowserProcessExitedCallback callback)
        : callback_(std::move(callback)) {}

    void Invoke(uint32_t browser_process_id,
                COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND exit_kind);
    void Clear();

   private:
    // WebView2 dispatches environment events on the plugin's apartment. A
    // recursive mutex also makes reentrant host destruction from the event
    // callback safe while preventing a callback from observing freed `this`.
    std::recursive_mutex mutex_;
    BrowserProcessExitedCallback callback_;
  };

  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor_;
  wil::com_ptr<ICoreWebView2Environment3> webview_env_;
  wil::com_ptr<ICoreWebView2Environment5> webview_env5_;
  std::shared_ptr<BrowserProcessExitedCallbackState>
      browser_process_exited_callback_state_;
  std::optional<EventRegistrationToken> browser_process_exited_token_;

  WebviewHost(WebviewPlatform* platform,
              wil::com_ptr<ICoreWebView2Environment3> webview_env,
              wil::com_ptr<ICoreWebView2Environment5> webview_env5);
  bool RegisterBrowserProcessExited(BrowserProcessExitedCallback callback);
  void CreateWebViewCompositionController(
      HWND hwnd, CompositionControllerCreationCallback cb);
};
