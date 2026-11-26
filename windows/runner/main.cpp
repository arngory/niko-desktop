#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

#ifdef _DEBUG
constexpr const wchar_t kSingleInstanceMutex[] = L"Local\\io.niko.desktop-debug";
#else
constexpr const wchar_t kSingleInstanceMutex[] = L"Local\\io.niko.desktop";
#endif

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  bool after_install = false;
  DWORD parent_pid = 0;
  constexpr const char kAfterInstallPrefix[] = "--after-install=";
  for (const auto& arg : command_line_arguments) {
    if (arg == "--after-install") {
      after_install = true;
      break;
    }
    if (arg.rfind(kAfterInstallPrefix, 0) == 0) {
      after_install = true;
      const std::string pid_str = arg.substr(sizeof(kAfterInstallPrefix) - 1);
      if (!pid_str.empty()) {
        unsigned long parsed = 0;
        bool valid = true;
        for (char c : pid_str) {
          if (c < '0' || c > '9') {
            valid = false;
            break;
          }
          parsed = parsed * 10 + static_cast<unsigned long>(c - '0');
          if (parsed > 0xFFFFFFFFUL) {
            valid = false;
            break;
          }
        }
        if (valid && parsed > 0) {
          parent_pid = static_cast<DWORD>(parsed);
        }
      }
      break;
    }
  }

  // When launched with --after-install=<pid> from a portable copy right after
  // UAC service installation, wait directly on the portable process handle
  // before acquiring the single-instance mutex so we neither race nor focus a
  // dying portable window.
  if (parent_pid != 0 && parent_pid != ::GetCurrentProcessId()) {
    HANDLE parent = ::OpenProcess(SYNCHRONIZE, FALSE, parent_pid);
    if (parent != nullptr) {
      ::WaitForSingleObject(parent, 15000);
      ::CloseHandle(parent);
    }
  }

  // Keep a single window per user session; a second launch raises the first.
  HANDLE instance_mutex = nullptr;
  for (int attempt = 0;; ++attempt) {
    instance_mutex = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (instance_mutex == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
      break;
    }
    if (after_install) {
      ::CloseHandle(instance_mutex);
      instance_mutex = nullptr;
      if (attempt < 30) {
        ::Sleep(100);
        continue;
      }
      // Portable copy did not release the mutex in time: still open the
      // installed window rather than focusing a dying portable copy and exiting.
      break;
    }
    HWND existing = ::FindWindowW(Win32Window::kWindowClassName, nullptr);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Niko", origin, size)) {
    ::CoUninitialize();
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
