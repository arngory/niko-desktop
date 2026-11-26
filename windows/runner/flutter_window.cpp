#include "flutter_window.h"

#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <thread>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Minimum client area in logical pixels (matches the B-Compact narrow layout).
constexpr int kMinClientWidth = 420;
constexpr int kMinClientHeight = 600;

flutter::EncodableValue MakeInstallResult(const char* kind, int code) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("kind"), flutter::EncodableValue(kind)},
      {flutter::EncodableValue("code"), flutter::EncodableValue(code)},
  });
}

std::wstring GetBundledDaemonPath() {
  std::wstring exe_path(MAX_PATH, L'\0');
  for (;;) {
    DWORD copied = ::GetModuleFileNameW(
        nullptr, exe_path.data(), static_cast<DWORD>(exe_path.size()));
    if (copied == 0) {
      return L"";
    }
    if (copied < exe_path.size()) {
      exe_path.resize(copied);
      break;
    }
    if (exe_path.size() >= 32768) {
      return L"";
    }
    exe_path.resize(exe_path.size() * 2);
  }
  const size_t slash = exe_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"";
  }
  return exe_path.substr(0, slash) + L"\\resources\\daemon\\niko-daemon.exe";
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  install_complete_message_ =
      ::RegisterWindowMessageW(L"io.niko.installComplete");
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "niko/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setDark") {
          const auto* dark = std::get_if<bool>(call.arguments());
          if (dark == nullptr) {
            result->Error("invalid_args", "expected bool");
            return;
          }
          SetDarkTheme(*dark);
          result->Success();
          return;
        }
        if (call.method_name() == "closeWindow") {
          ::PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "installService") {
          if (pending_install_result_ != nullptr) {
            result->Error("busy", "service installation already in progress");
            return;
          }
          if (install_complete_message_ == 0) {
            result->Success(MakeInstallResult("shell", -1));
            return;
          }
          const std::wstring daemon_path = GetBundledDaemonPath();
          if (daemon_path.empty() ||
              ::GetFileAttributesW(daemon_path.c_str()) ==
                  INVALID_FILE_ATTRIBUTES) {
            result->Success(MakeInstallResult("exit", 11));  // invalid layout
            return;
          }
          SHELLEXECUTEINFOW sei = {};
          sei.cbSize = sizeof(sei);
          sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
          sei.hwnd = GetHandle();
          sei.lpVerb = L"runas";
          sei.lpFile = daemon_path.c_str();
          sei.lpParameters = L"service install";
          sei.nShow = SW_HIDE;
          if (!::ShellExecuteExW(&sei)) {
            const DWORD err = ::GetLastError();
            result->Success(MakeInstallResult("shell", static_cast<int>(err)));
            return;
          }
          if (sei.hProcess == nullptr) {
            result->Success(MakeInstallResult("shell", -1));
            return;
          }
          HANDLE process = sei.hProcess;
          HWND hwnd = GetHandle();
          UINT complete_msg = install_complete_message_;
          try {
            std::thread waiter([process, hwnd, complete_msg]() {
              ::WaitForSingleObject(process, INFINITE);
              DWORD exit_code = 1;
              ::GetExitCodeProcess(process, &exit_code);
              ::CloseHandle(process);
              ::PostMessageW(hwnd, complete_msg,
                             static_cast<WPARAM>(exit_code), 0);
            });
            pending_install_result_ = std::move(result);
            waiter.detach();
          } catch (...) {
            ::CloseHandle(process);
            result->Success(MakeInstallResult("shell", -1));
          }
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  pending_install_result_ = nullptr;
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (install_complete_message_ != 0 && message == install_complete_message_) {
    if (pending_install_result_ != nullptr) {
      auto result = std::move(pending_install_result_);
      result->Success(MakeInstallResult("exit", static_cast<int>(wparam)));
    }
    return 0;
  }

  if (message == WM_GETMINMAXINFO && lparam != 0) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    UINT dpi = ::GetDpiForWindow(hwnd);
    if (dpi == 0) {
      dpi = 96;
    }
    const double scale = dpi / 96.0;
    RECT rect = {0, 0, static_cast<LONG>(kMinClientWidth * scale + 0.5),
                 static_cast<LONG>(kMinClientHeight * scale + 0.5)};
    const DWORD style =
        static_cast<DWORD>(::GetWindowLongPtr(hwnd, GWL_STYLE));
    const DWORD ex_style =
        static_cast<DWORD>(::GetWindowLongPtr(hwnd, GWL_EXSTYLE));
    ::AdjustWindowRectExForDpi(&rect, style, FALSE, ex_style, dpi);
    info->ptMinTrackSize.x = rect.right - rect.left;
    info->ptMinTrackSize.y = rect.bottom - rect.top;
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
