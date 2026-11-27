#include "flutter_window.h"

#include <commdlg.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <thread>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Minimum client area in logical pixels (matches the B-Compact narrow layout).
constexpr int kMinClientWidth = 420;
constexpr int kMinClientHeight = 600;
constexpr UINT kTrayIconId = 1001;
constexpr UINT_PTR kMenuToggle = 2001;
constexpr UINT_PTR kMenuOpen = 2002;
constexpr UINT_PTR kMenuQuit = 2003;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return L"";
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) return L"";
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  int len = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
  if (len <= 0) return "";
  std::string out(static_cast<size_t>(len), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), out.data(), len, nullptr, nullptr);
  return out;
}

std::string MapGetString(const flutter::EncodableMap* map, const char* key, const char* fallback) {
  if (map == nullptr) return fallback;
  auto it = map->find(flutter::EncodableValue(key));
  if (it != map->end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  }
  return fallback;
}

std::optional<std::string> PickPathDialog(HWND owner, bool folder_only, const std::wstring& title,
                                          const std::vector<std::wstring>& extensions) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL,
                                  IID_IFileOpenDialog, reinterpret_cast<void**>(&dialog));
  if (FAILED(hr) || dialog == nullptr) return std::nullopt;
  DWORD opts = 0;
  if (SUCCEEDED(dialog->GetOptions(&opts))) {
    opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
    if (folder_only) opts |= FOS_PICKFOLDERS;
    dialog->SetOptions(opts);
  }
  if (!title.empty()) dialog->SetTitle(title.c_str());

  std::wstring spec;
  if (!folder_only && !extensions.empty()) {
    for (size_t i = 0; i < extensions.size(); ++i) {
      if (i > 0) spec += L";";
      spec += L"*.";
      spec += extensions[i];
    }
    COMDLG_FILTERSPEC filters[2] = {
        {L"Supported files", spec.c_str()},
        {L"All files", L"*.*"},
    };
    dialog->SetFileTypes(2, filters);
  }

  std::optional<std::string> chosen;
  if (SUCCEEDED(dialog->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr) {
      PWSTR path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path != nullptr) {
        chosen = WideToUtf8(path);
        ::CoTaskMemFree(path);
      }
      item->Release();
    }
  }
  dialog->Release();
  return chosen;
}

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

void FlutterWindow::EnsureTrayIcon(const std::wstring& tooltip) {
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = tray_callback_message_;
  nid.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101));
  if (nid.hIcon == nullptr) {
    nid.hIcon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  wcsncpy_s(nid.szTip, tooltip.c_str(), _TRUNCATE);
  if (!tray_added_) {
    if (::Shell_NotifyIconW(NIM_ADD, &nid)) {
      tray_added_ = true;
    }
  } else {
    ::Shell_NotifyIconW(NIM_MODIFY, &nid);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_added_ = false;
}

void FlutterWindow::ShowTrayMenu(HWND hwnd) {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) return;
  ::AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, tray_status_.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuToggle, tray_toggle_label_.c_str());
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, tray_open_label_.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuQuit, tray_quit_label_.c_str());

  POINT pt;
  ::GetCursorPos(&pt);
  ::SetForegroundWindow(hwnd);
  UINT cmd = ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr);
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (cmd == kMenuToggle && window_channel_) {
    window_channel_->InvokeMethod("trayAction", std::make_unique<flutter::EncodableValue>("toggle"));
  } else if (cmd == kMenuOpen) {
    ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
    if (window_channel_) {
      window_channel_->InvokeMethod("trayAction", std::make_unique<flutter::EncodableValue>("show"));
    }
  } else if (cmd == kMenuQuit) {
    quitting_ = true;
    if (window_channel_) {
      window_channel_->InvokeMethod("trayAction", std::make_unique<flutter::EncodableValue>("quit"));
    }
    ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  install_complete_message_ =
      ::RegisterWindowMessageW(L"io.niko.installComplete");
  tray_callback_message_ =
      ::RegisterWindowMessageW(L"io.niko.trayCallback");
  taskbar_created_message_ =
      ::RegisterWindowMessageW(L"TaskbarCreated");
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
        if (call.method_name() == "setCloseToTray") {
          if (const auto* enabled = std::get_if<bool>(call.arguments())) {
            close_to_tray_ = *enabled;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "showWindow") {
          ::ShowWindow(GetHandle(), SW_RESTORE);
          ::SetForegroundWindow(GetHandle());
          result->Success();
          return;
        }
        if (call.method_name() == "hideWindow") {
          ::ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
          return;
        }
        if (call.method_name() == "closeWindow") {
          quitting_ = true;
          ::PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "updateTray") {
          const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string status = MapGetString(map, "status", "Niko");
          std::string profile = MapGetString(map, "profile", "");
          std::string label = profile.empty() ? status : (status + " - " + profile);
          tray_status_ = Utf8ToWide(label);
          tray_toggle_label_ = Utf8ToWide(MapGetString(map, "toggleLabel", "Connect"));
          tray_open_label_ = Utf8ToWide(MapGetString(map, "openLabel", "Open Niko"));
          tray_quit_label_ = Utf8ToWide(MapGetString(map, "quitLabel", "Quit"));
          EnsureTrayIcon(tray_status_);
          result->Success();
          return;
        }
        if (call.method_name() == "notify") {
          const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring title = Utf8ToWide(MapGetString(map, "title", "Niko"));
          std::wstring body = Utf8ToWide(MapGetString(map, "body", ""));
          EnsureTrayIcon(tray_status_);
          NOTIFYICONDATAW nid = {};
          nid.cbSize = sizeof(nid);
          nid.hWnd = GetHandle();
          nid.uID = kTrayIconId;
          nid.uFlags = NIF_INFO;
          nid.dwInfoFlags = NIIF_INFO;
          wcsncpy_s(nid.szInfoTitle, title.c_str(), _TRUNCATE);
          wcsncpy_s(nid.szInfo, body.c_str(), _TRUNCATE);
          ::Shell_NotifyIconW(NIM_MODIFY, &nid);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "pickFile") {
          const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring title = Utf8ToWide(MapGetString(map, "title", "Open file"));
          std::vector<std::wstring> extensions;
          if (map != nullptr) {
            auto it = map->find(flutter::EncodableValue("extensions"));
            if (it != map->end()) {
              if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
                for (const auto& item : *list) {
                  if (const auto* s = std::get_if<std::string>(&item); s != nullptr && !s->empty()) {
                    extensions.push_back(Utf8ToWide(*s));
                  }
                }
              }
            }
          }
          auto chosen = PickPathDialog(GetHandle(), false, title, extensions);
          if (chosen.has_value()) {
            result->Success(flutter::EncodableValue(*chosen));
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() == "pickDirectory") {
          const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring title = Utf8ToWide(MapGetString(map, "title", "Choose folder"));
          auto chosen = PickPathDialog(GetHandle(), true, title, {});
          if (chosen.has_value()) {
            result->Success(flutter::EncodableValue(*chosen));
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() == "installService" ||
            call.method_name() == "uninstallService") {
          const bool uninstall = call.method_name() == "uninstallService";
          if (pending_install_result_ != nullptr) {
            result->Error("busy", "service operation already in progress");
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
          sei.lpParameters =
              uninstall ? L"service uninstall" : L"service install";
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

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
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

  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (tray_added_) {
      tray_added_ = false;
      EnsureTrayIcon(tray_status_);
    }
    return 0;
  }

  if (tray_callback_message_ != 0 && message == tray_callback_message_) {
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      ShowTrayMenu(hwnd);
      return 0;
    }
    if (lparam == WM_LBUTTONDBLCLK || lparam == WM_LBUTTONUP) {
      ::ShowWindow(hwnd, SW_RESTORE);
      ::SetForegroundWindow(hwnd);
      return 0;
    }
  }

  if (message == WM_COPYDATA && lparam != 0) {
    const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (cds->dwData == 0x4E494B4F && cds->lpData != nullptr &&
        cds->cbData > 0 && cds->cbData <= 32768 && window_channel_) {
      std::string link(reinterpret_cast<const char*>(cds->lpData), cds->cbData);
      window_channel_->InvokeMethod(
          "deepLink", std::make_unique<flutter::EncodableValue>(link));
      return TRUE;
    }
  }

  if (message == WM_CLOSE && close_to_tray_ && !quitting_ && tray_added_) {
    ::ShowWindow(hwnd, SW_HIDE);
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
