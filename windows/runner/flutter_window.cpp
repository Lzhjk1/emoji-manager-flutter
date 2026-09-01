#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>

#include "resource.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kClipboardChannelName[] = "emoji_manager/platform_clipboard";
constexpr char kWindowChannelName[] = "emoji_manager/window_control";
constexpr DWORD kDropEffectCopy = 1;
constexpr wchar_t kPreferredDropEffectFormat[] = L"Preferred DropEffect";
constexpr UINT kTrayIconId = 1001;
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayMenuShowId = 40001;
constexpr UINT kTrayMenuExitId = 40002;
constexpr UINT_PTR kForegroundTimerId = 2002;
constexpr UINT kForegroundTimerIntervalMs = 250;
constexpr int kHotkeyId = 2001;
constexpr UINT kHotkeyModifierMask = MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN;

typedef struct _TRAE_DROPFILES {
  DWORD pFiles;
  POINT pt;
  BOOL fNC;
  BOOL fWide;
} TRAE_DROPFILES;

std::optional<std::string> GetStringValue(
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }

  if (const auto* value = std::get_if<std::string>(&iterator->second)) {
    return *value;
  }

  return std::nullopt;
}

std::optional<bool> GetBoolValue(const flutter::EncodableMap& arguments,
                                 const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }

  if (const auto* value = std::get_if<bool>(&iterator->second)) {
    return *value;
  }

  return std::nullopt;
}

std::optional<int32_t> GetIntValue(const flutter::EncodableMap& arguments,
                                   const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }

  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return *value;
  }

  return std::nullopt;
}

std::optional<std::vector<uint8_t>> GetBytesValue(
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }

  if (const auto* value = std::get_if<std::vector<uint8_t>>(&iterator->second)) {
    return *value;
  }

  return std::nullopt;
}

std::string WideToUtf8(const std::wstring& input) {
  if (input.empty()) {
    return std::string();
  }

  const int length =
      WideCharToMultiByte(CP_UTF8, 0, input.data(),
                          static_cast<int>(input.size()), nullptr, 0, nullptr,
                          nullptr);
  if (length <= 0) {
    return std::string();
  }

  std::string output(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, input.data(), static_cast<int>(input.size()),
                      output.data(), length, nullptr, nullptr);
  return output;
}

void SendCtrlV() {
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'V';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'V';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(static_cast<UINT>(std::size(inputs)), inputs, sizeof(INPUT));
}

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) {
    return std::wstring();
  }

  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
      static_cast<int>(input.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }

  std::wstring output(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                      static_cast<int>(input.size()), output.data(), length);
  return output;
}

HGLOBAL CreateClipboardDropfilesHandle(const std::wstring& file_path) {
  const size_t bytes =
      sizeof(TRAE_DROPFILES) + ((file_path.size() + 2) * sizeof(wchar_t));
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (handle == nullptr) {
    return nullptr;
  }

  auto* memory = static_cast<BYTE*>(GlobalLock(handle));
  if (memory == nullptr) {
    GlobalFree(handle);
    return nullptr;
  }

  auto* dropfiles = reinterpret_cast<TRAE_DROPFILES*>(memory);
  dropfiles->pFiles = sizeof(TRAE_DROPFILES);
  dropfiles->fWide = TRUE;

  auto* path_buffer =
      reinterpret_cast<wchar_t*>(memory + sizeof(TRAE_DROPFILES));
  memcpy(path_buffer, file_path.c_str(), file_path.size() * sizeof(wchar_t));
  path_buffer[file_path.size()] = L'\0';
  path_buffer[file_path.size() + 1] = L'\0';

  GlobalUnlock(handle);
  return handle;
}

HGLOBAL CreatePreferredDropEffectHandle() {
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (handle == nullptr) {
    return nullptr;
  }

  auto* effect = static_cast<DWORD*>(GlobalLock(handle));
  if (effect == nullptr) {
    GlobalFree(handle);
    return nullptr;
  }

  *effect = kDropEffectCopy;
  GlobalUnlock(handle);
  return handle;
}

bool CopyFilePathToClipboard(HWND owner, const std::string& file_path_utf8) {
  const std::wstring file_path = Utf8ToWide(file_path_utf8);
  if (file_path.empty()) {
    return false;
  }

  HGLOBAL dropfiles_handle = CreateClipboardDropfilesHandle(file_path);
  if (dropfiles_handle == nullptr) {
    return false;
  }

  HGLOBAL drop_effect_handle = CreatePreferredDropEffectHandle();
  const UINT drop_effect_format =
      RegisterClipboardFormat(kPreferredDropEffectFormat);

  if (!OpenClipboard(owner)) {
    GlobalFree(dropfiles_handle);
    if (drop_effect_handle != nullptr) {
      GlobalFree(drop_effect_handle);
    }
    return false;
  }

  EmptyClipboard();
  const HANDLE clipboard_files = SetClipboardData(CF_HDROP, dropfiles_handle);
  HANDLE clipboard_effect = nullptr;
  if (drop_effect_handle != nullptr && drop_effect_format != 0) {
    clipboard_effect =
        SetClipboardData(drop_effect_format, drop_effect_handle);
  }
  CloseClipboard();

  if (clipboard_files == nullptr) {
    GlobalFree(dropfiles_handle);
    if (drop_effect_handle != nullptr && clipboard_effect == nullptr) {
      GlobalFree(drop_effect_handle);
    }
    return false;
  }

  if (drop_effect_handle != nullptr && clipboard_effect == nullptr) {
    GlobalFree(drop_effect_handle);
  }

  return true;
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  EnsureTrayIcon();
  SetTimer(GetHandle(), kForegroundTimerId, kForegroundTimerIntervalMs,
           nullptr);

  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kClipboardChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "copyFileToClipboard") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Arguments must be a map.");
            return;
          }

          const auto path = GetStringValue(*arguments, "path");
          if (!path.has_value() || path->empty()) {
            result->Error("invalid_arguments", "path is required.");
            return;
          }

          const bool copied =
              CopyFilePathToClipboard(GetHandle(), *path);
          result->Success(flutter::EncodableValue(copied));
          return;
        }

        if (call.method_name() == "copyImageToClipboard") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Arguments must be a map.");
            return;
          }

          const auto width = GetIntValue(*arguments, "width");
          const auto height = GetIntValue(*arguments, "height");
          const auto bytes = GetBytesValue(*arguments, "bytes");
          const auto paste = GetBoolValue(*arguments, "paste");
          if (!width.has_value() || !height.has_value() || !bytes.has_value() ||
              !paste.has_value()) {
            result->Error(
                "invalid_arguments",
                "width, height, bytes and paste are required.");
            return;
          }

          bool pasted = false;
          const bool copied = CopyImageToClipboard(
              width.value(), height.value(), bytes.value(), paste.value(),
              &pasted);
          flutter::EncodableMap response;
          response[flutter::EncodableValue("clipboard")] =
              flutter::EncodableValue(copied);
          response[flutter::EncodableValue("pasted")] =
              flutter::EncodableValue(pasted);
          result->Success(flutter::EncodableValue(response));
          return;
        }

        result->NotImplemented();
      });
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "applyWindowSettings") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Arguments must be a map.");
            return;
          }

          ApplyWindowSettings(*arguments, result.get());
          return;
        }

        if (call.method_name() == "getPreviousForegroundApp") {
          flutter::EncodableMap response;
          response[flutter::EncodableValue("processName")] =
              flutter::EncodableValue(WideToUtf8(last_external_process_name_));
          result->Success(flutter::EncodableValue(response));
          return;
        }

        if (call.method_name() == "setHotkeyEnabled") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Arguments must be a map.");
            return;
          }

          const auto enabled = GetBoolValue(*arguments, "enabled");
          const auto modifiers = GetIntValue(*arguments, "modifiers");
          const auto key_code = GetIntValue(*arguments, "keyCode");
          if (!enabled.has_value() || !modifiers.has_value() ||
              !key_code.has_value()) {
            result->Error("invalid_arguments",
                          "enabled, modifiers and keyCode are required.");
            return;
          }

          const bool registered =
              SetHotkey(enabled.value(), static_cast<UINT>(modifiers.value()),
                        static_cast<UINT>(key_code.value()));
          result->Success(flutter::EncodableValue(registered));
          return;
        }

        result->NotImplemented();
      });

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
  KillTimer(GetHandle(), kForegroundTimerId);
  if (hotkey_registered_ && GetHandle() != nullptr) {
    UnregisterHotKey(GetHandle(), kHotkeyId);
    hotkey_registered_ = false;
  }
  RemoveTrayIcon();
  window_channel_.reset();
  clipboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE && close_to_tray_ && !force_close_) {
    MinimizeToTray();
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
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayMenuShowId:
          RestoreFromTray();
          return 0;
        case kTrayMenuExitId:
          ExitApplication();
          return 0;
      }
      break;

    case WM_TIMER:
      if (wparam == kForegroundTimerId) {
        UpdateForegroundCapture();
        return 0;
      }
      break;

    case WM_HOTKEY:
      if (wparam == kHotkeyId) {
        ToggleWindowVisibility();
        return 0;
      }
      break;

    case kTrayCallbackMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          ToggleWindowVisibility();
          return 0;
        case WM_RBUTTONUP: {
          HMENU menu = CreatePopupMenu();
          if (menu == nullptr) {
            return 0;
          }
          AppendMenu(menu, MF_STRING, kTrayMenuShowId, L"Show Window");
          AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
          AppendMenu(menu, MF_STRING, kTrayMenuExitId, L"Exit");
          POINT cursor_position;
          GetCursorPos(&cursor_position);
          SetForegroundWindow(hwnd);
          TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                         cursor_position.x, cursor_position.y, 0, hwnd, nullptr);
          DestroyMenu(menu);
          return 0;
        }
      }
      break;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ApplyWindowSettings(
    const flutter::EncodableMap& arguments,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  const auto close_behavior = GetStringValue(arguments, "closeBehavior");
  const auto always_on_top = GetBoolValue(arguments, "alwaysOnTop");
  if (!close_behavior.has_value() || !always_on_top.has_value()) {
    result->Error("invalid_arguments",
                  "closeBehavior and alwaysOnTop are required.");
    return;
  }

  SetCloseToTray(*close_behavior == "tray");
  SetAlwaysOnTop(*always_on_top);
  result->Success();
}

void FlutterWindow::SetAlwaysOnTop(bool enabled) {
  always_on_top_ = enabled;
  if (GetHandle() == nullptr) {
    return;
  }

  SetWindowPos(GetHandle(), enabled ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void FlutterWindow::SetCloseToTray(bool enabled) {
  close_to_tray_ = enabled;
}

void FlutterWindow::MinimizeToTray() {
  if (GetHandle() == nullptr) {
    return;
  }

  EnsureTrayIcon();
  ShowWindow(GetHandle(), SW_HIDE);
}

void FlutterWindow::RestoreFromTray() {
  if (GetHandle() == nullptr) {
    return;
  }

  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ToggleWindowVisibility() {
  if (GetHandle() == nullptr) {
    return;
  }

  if (IsWindowVisible(GetHandle())) {
    ShowWindow(GetHandle(), SW_HIDE);
    return;
  }

  RestoreFromTray();
}

void FlutterWindow::EnsureTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return;
  }

  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(NOTIFYICONDATA);
  tray_icon_data_.hWnd = GetHandle();
  tray_icon_data_.uID = kTrayIconId;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_data_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_data_.szTip, L"Emoji Manager");

  if (Shell_NotifyIcon(NIM_ADD, &tray_icon_data_)) {
    tray_icon_added_ = true;
    tray_icon_data_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &tray_icon_data_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_data_);
  tray_icon_added_ = false;
  tray_icon_data_ = {};
}

void FlutterWindow::ExitApplication() {
  force_close_ = true;
  RemoveTrayIcon();
  if (GetHandle() != nullptr) {
    DestroyWindow(GetHandle());
  }
}

void FlutterWindow::UpdateForegroundCapture() {
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr || foreground == GetHandle()) {
    return;
  }
  if (foreground == last_seen_foreground_) {
    return;
  }
  last_seen_foreground_ = foreground;
  if (!IsCapturableForegroundWindow(foreground)) {
    return;
  }
  last_external_foreground_ = foreground;
  last_external_process_name_ = GetWindowProcessName(foreground);
}

bool FlutterWindow::IsCapturableForegroundWindow(HWND hwnd) {
  wchar_t class_name[64] = {};
  if (GetClassNameW(hwnd, class_name, 64) == 0) {
    return false;
  }
  const std::wstring class_name_string(class_name);
  return class_name_string != L"Shell_TrayWnd" &&
         class_name_string != L"Shell_SecondaryTrayWnd" &&
         class_name_string != L"Progman" && class_name_string != L"WorkerW";
}

std::wstring FlutterWindow::GetWindowProcessName(HWND hwnd) {
  DWORD process_id = 0;
  GetWindowThreadProcessId(hwnd, &process_id);
  if (process_id == 0) {
    return std::wstring();
  }

  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return std::wstring();
  }

  wchar_t path[MAX_PATH] = {};
  DWORD path_length = MAX_PATH;
  std::wstring name;
  if (QueryFullProcessImageNameW(process, 0, path, &path_length) &&
      path_length > 0) {
    name.assign(path, path_length);
    const size_t separator = name.find_last_of(L'\\');
    if (separator != std::wstring::npos) {
      name.erase(0, separator + 1);
    }
    CharLowerBuffW(name.data(), static_cast<DWORD>(name.size()));
  }
  CloseHandle(process);
  return name;
}

bool FlutterWindow::SetHotkey(bool enabled, UINT modifiers, UINT key_code) {
  if ((modifiers & kHotkeyModifierMask) == 0 || key_code < 0x08 ||
      key_code > 0xFE) {
    return false;
  }

  if (hotkey_registered_ && GetHandle() != nullptr) {
    UnregisterHotKey(GetHandle(), kHotkeyId);
    hotkey_registered_ = false;
  }
  hotkey_modifiers_ = modifiers & kHotkeyModifierMask;
  hotkey_key_code_ = key_code;
  if (!enabled) {
    return true;
  }
  if (GetHandle() == nullptr) {
    return false;
  }
  hotkey_registered_ =
      RegisterHotKey(GetHandle(), kHotkeyId,
                     hotkey_modifiers_ | MOD_NOREPEAT, hotkey_key_code_);
  return hotkey_registered_;
}

bool FlutterWindow::CopyImageToClipboard(int width, int height,
                                         const std::vector<uint8_t>& rgba,
                                         bool paste, bool* pasted) {
  *pasted = false;
  if (width <= 0 || height <= 0) {
    return false;
  }
  const size_t pixel_bytes = static_cast<size_t>(width) * height * 4;
  if (rgba.size() < pixel_bytes) {
    return false;
  }

  const size_t total_size = sizeof(BITMAPINFOHEADER) + pixel_bytes;
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, total_size);
  if (handle == nullptr) {
    return false;
  }

  auto* memory = static_cast<BYTE*>(GlobalLock(handle));
  if (memory == nullptr) {
    GlobalFree(handle);
    return false;
  }

  auto* header = reinterpret_cast<BITMAPINFOHEADER*>(memory);
  ZeroMemory(header, sizeof(BITMAPINFOHEADER));
  header->biSize = sizeof(BITMAPINFOHEADER);
  header->biWidth = width;
  header->biHeight = height;  // Positive: bottom-up rows.
  header->biPlanes = 1;
  header->biBitCount = 32;
  header->biCompression = BI_RGB;
  header->biSizeImage = static_cast<DWORD>(pixel_bytes);

  BYTE* pixels = memory + sizeof(BITMAPINFOHEADER);
  for (int y = 0; y < height; ++y) {
    const BYTE* source =
        rgba.data() + static_cast<size_t>(height - 1 - y) * width * 4;
    BYTE* destination = pixels + static_cast<size_t>(y) * width * 4;
    for (int x = 0; x < width; ++x) {
      // RGBA -> BGRA.
      destination[0] = source[2];
      destination[1] = source[1];
      destination[2] = source[0];
      destination[3] = source[3];
      source += 4;
      destination += 4;
    }
  }
  GlobalUnlock(handle);

  if (!OpenClipboard(GetHandle())) {
    GlobalFree(handle);
    return false;
  }
  EmptyClipboard();
  const HANDLE placed = SetClipboardData(CF_DIB, handle);
  CloseClipboard();
  if (placed == nullptr) {
    GlobalFree(handle);
    return false;
  }

  if (paste) {
    *pasted = PasteToPreviousWindow();
  }
  return true;
}

bool FlutterWindow::PasteToPreviousWindow() {
  const std::wstring expected_process = last_external_process_name_;
  ShowWindow(GetHandle(), SW_HIDE);

  HWND target = nullptr;
  for (int attempt = 0; attempt < 25; ++attempt) {
    Sleep(20);
    target = GetForegroundWindow();
    if (target != nullptr && target != GetHandle()) {
      break;
    }
  }

  if (target == nullptr || target == GetHandle()) {
    if (last_external_foreground_ != nullptr &&
        IsWindow(last_external_foreground_)) {
      SetForegroundWindow(last_external_foreground_);
      Sleep(80);
      target = GetForegroundWindow();
    }
  }

  if (target == nullptr || target == GetHandle()) {
    return false;
  }
  if (!expected_process.empty() &&
      GetWindowProcessName(target) != expected_process) {
    return false;
  }

  SendCtrlV();
  return true;
}
