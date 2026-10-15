#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <roapi.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  try {
  if (!SetNotificationExecutableDirectory()) return EXIT_FAILURE;
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  std::wstring notification_uri;
  const bool notification_arguments = std::find(command_line_arguments.begin(),
      command_line_arguments.end(), "--ustc-notification") != command_line_arguments.end();
  if (notification_arguments) {
    if (command_line_arguments.size() == 2 &&
        command_line_arguments[0] == "--ustc-notification" &&
        command_line_arguments[1].size() <= 256 &&
        std::all_of(command_line_arguments[1].begin(), command_line_arguments[1].end(),
                    [](unsigned char c) { return c < 128; })) {
      const auto& ascii_uri = command_line_arguments[1];
      std::wstring candidate(ascii_uri.begin(), ascii_uri.end());
      NativeReminder parsed;
      if (ParseNativeNotificationActivation(candidate, kNotificationScheme, &parsed))
        notification_uri = std::move(candidate);
    }
    // Opaque notification arguments never enter Dart's ordinary argument list.
    command_line_arguments.clear();
  }
  const bool test_host = NotificationTestHost();
  NotificationActivationHub activations;
  NotificationInstance notification_instance(test_host);
  const auto ownership = notification_instance.AcquireOrForward(notification_uri);
  if (ownership == NotificationInstanceResult::forwarded) return EXIT_SUCCESS;
  if (ownership != NotificationInstanceResult::primary) return EXIT_FAILURE;
  if (!notification_uri.empty() && !activations.Enqueue(notification_uri))
    return EXIT_FAILURE;

  // WinRT initialization also initializes COM for Flutter/plugins on this STA.
  const HRESULT runtime = RoInitialize(RO_INIT_SINGLETHREADED);
  if (FAILED(runtime)) return EXIT_FAILURE;
  struct RuntimeLifetime { ~RuntimeLifetime() { RoUninitialize(); } } runtime_lifetime;
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, activations, notification_instance, test_host);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"USTC Assistant", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  BOOL message_result;
  while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return message_result == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
  } catch (...) { return EXIT_FAILURE; }
}
