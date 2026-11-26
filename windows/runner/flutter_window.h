#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Channel for window-level requests from Dart (such as dark titlebar mode
  // and elevated service installation).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Registered Win32 message posted from the waiter thread when elevated
  // `niko-daemon.exe service install` finishes.
  UINT install_complete_message_ = 0;

  // Pending MethodResult for an in-flight UAC service install; completed on the
  // UI thread when install_complete_message_ arrives.
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_install_result_;

  // Native Windows system tray (Shell_NotifyIconW) state.
  UINT tray_callback_message_ = 0;
  UINT taskbar_created_message_ = 0;
  bool tray_added_ = false;
  bool close_to_tray_ = false;
  bool quitting_ = false;
  std::wstring tray_status_ = L"Niko";
  std::wstring tray_toggle_label_ = L"Connect";
  std::wstring tray_open_label_ = L"Open Niko";
  std::wstring tray_quit_label_ = L"Quit";

  void EnsureTrayIcon(const std::wstring& tooltip);
  void RemoveTrayIcon();
  void ShowTrayMenu(HWND hwnd);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
