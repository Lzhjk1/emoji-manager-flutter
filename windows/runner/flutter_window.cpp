#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <optional>
#include <shlobj.h>
#include <shellapi.h>
#include <string>
#include <vector>

#include "resource.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// MethodChannel 名称, 与 Dart 层 PlatformEmojiClipboardService /
// WindowControlService 保持一致。
constexpr char kClipboardChannelName[] = "emoji_manager/platform_clipboard";
constexpr char kWindowChannelName[] = "emoji_manager/window_control";
constexpr DWORD kDropEffectCopy = 1;  // "Preferred DropEffect": 复制语义
constexpr wchar_t kPreferredDropEffectFormat[] = L"Preferred DropEffect";
constexpr UINT kTrayIconId = 1001;
// 托盘图标回调消息 (WM_APP 段, 避免与系统消息冲突)。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayMenuShowId = 40001;
constexpr UINT kTrayMenuExitId = 40002;
// 前台应用跟踪定时器: 每 250ms 采样一次前台窗口。
constexpr UINT_PTR kForegroundTimerId = 2002;
constexpr UINT kForegroundTimerIntervalMs = 250;
constexpr int kHotkeyId = 2001;
constexpr UINT kHotkeyModifierMask = MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN;

// 与 DROPFILES 结构等价的内部定义 (避免直接依赖 shellapi 布局差异)。
typedef struct _TRAE_DROPFILES {
  DWORD pFiles;
  POINT pt;
  BOOL fNC;
  BOOL fWide;
} TRAE_DROPFILES;

// ---- MethodChannel 参数解码辅助 ----

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

// 用 SendInput 模拟一次 Ctrl+V 按键序列 (按下/抬起)。
// 注意: 若目标应用以管理员运行而本程序没有, SendInput 会被 UIPI 拦截。
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

// 构造 CF_HDROP 剪贴板数据: 单个文件路径, 以双 NUL 结尾。
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

// 构造 "Preferred DropEffect" 附加数据 (标记为复制而非移动)。
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

// 把文件以 CF_HDROP 写入剪贴板 (供聊天软件直接粘贴文件)。
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
  // 创建托盘图标, 并启动前台应用跟踪定时器。
  EnsureTrayIcon();
  SetTimer(GetHandle(), kForegroundTimerId, kForegroundTimerIntervalMs,
           nullptr);

  // ---- 剪贴板通道: 复制文件/图片、资源管理器定位 ----
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

          const auto paste = GetBoolValue(*arguments, "paste");
          const bool copied =
              CopyFilePathToClipboard(GetHandle(), *path);
          bool pasted = false;
          if (copied && paste.has_value() && paste.value()) {
            pasted = PasteToPreviousWindow();
          }

          flutter::EncodableMap response;
          response[flutter::EncodableValue("clipboard")] =
              flutter::EncodableValue(copied);
          response[flutter::EncodableValue("pasted")] =
              flutter::EncodableValue(pasted);
          result->Success(flutter::EncodableValue(response));
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

        if (call.method_name() == "revealInExplorer") {
          // 用 shell API (SHParseDisplayName + SHOpenFolderAndSelectItems)
          // 打开资源管理器并选中文件; 相比 explorer /select 命令行
          // 对含逗号/空格的路径解析可靠。
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

          const std::wstring file_path = Utf8ToWide(*path);
          if (file_path.empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }

          PIDLIST_ABSOLUTE pidl = nullptr;
          if (SHParseDisplayName(file_path.c_str(), nullptr, &pidl, 0,
                                 nullptr) == S_OK &&
              pidl != nullptr) {
            SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
            CoTaskMemFree(pidl);
            result->Success(flutter::EncodableValue(true));
            return;
          }
          result->Success(flutter::EncodableValue(false));
          return;
        }

        result->NotImplemented();
      });
  // ---- 窗口控制通道: 窗口设置、前台应用查询、热键 ----
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
  // 释放定时器、热键与托盘图标, 再销毁 Flutter 引擎。
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
  // "关闭到托盘"模式: 拦截 WM_CLOSE, 隐藏窗口而不是退出。
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
      // 托盘右键菜单项。
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
      // 前台应用跟踪: 每 250ms 采样一次。
      if (wparam == kForegroundTimerId) {
        UpdateForegroundCapture();
        return 0;
      }
      break;

    case WM_HOTKEY:
      // 全局热键触发: 切换窗口显示/隐藏。
      if (wparam == kHotkeyId) {
        ToggleWindowVisibility();
        return 0;
      }
      break;

    case kTrayCallbackMessage:
      // 托盘图标交互: 左键/双击切换显示, 右键弹出菜单。
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

void FlutterWindow::HideWindow() {
  if (GetHandle() == nullptr) {
    return;
  }

  // 先最小化再隐藏: 引擎收到 WM_SIZE(SIZE_MINIMIZED) 才会暂停渲染与动画,
  // 仅 SW_HIDE 时引擎保持 vsync 循环, GIF 等动图持续解码导致 CPU 占用偏高。
  ShowWindow(GetHandle(), SW_MINIMIZE);
  ShowWindow(GetHandle(), SW_HIDE);
}

void FlutterWindow::MinimizeToTray() {
  if (GetHandle() == nullptr) {
    return;
  }

  EnsureTrayIcon();
  HideWindow();
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
    HideWindow();
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
  // 记录最近的外部前台窗口及其进程名。
  // 跳过: 本窗口自身、以及与上次相同的窗口 (避免重复查询)。
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

// 任务栏 (Shell_TrayWnd / Shell_SecondaryTrayWnd) 与桌面 (Progman / WorkerW)
// 不作为粘贴目标 —— 通过任务栏按钮唤起窗口时焦点会短暂落到 shell 上。
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

// 取窗口所属进程的可执行文件名 (小写, 含 .exe 后缀)。
// 用 PROCESS_QUERY_LIMITED_INFORMATION, 对更高权限的进程也能查询。
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

// 注册/注销全局热键。modifiers 必须包含至少一个修饰键,
// key_code 限定在 0x08~0xFE; 注册失败 (如热键被其他软件占用) 返回 false。
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

// 把 RGBA 像素数据封装为 CF_DIB (32bpp, 自底向上, BGRA) 写入剪贴板。
// 使用 CF_DIB 而非 PNG, 因为 QQ 等聊天软件粘贴截图时读取的就是该格式,
// 文件体积也更小; paste 为 true 时随后向之前的前台窗口发送 Ctrl+V。
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
  header->biHeight = height;  // Positive: bottom-up rows. 正值 = 行序自底向上。
  header->biPlanes = 1;
  header->biBitCount = 32;
  header->biCompression = BI_RGB;
  header->biSizeImage = static_cast<DWORD>(pixel_bytes);

  // DIB 要求自底向上 + BGRA, 因此逐行倒序并把 RGBA 转成 BGRA。
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

// 强制把 hwnd 激活为前台窗口。
// 附加线程输入队列绕过前台锁定限制:
// 当焦点在 shell (任务栏) 上时, 直接调用 SetForegroundWindow 会失败。
bool ForceActivateWindow(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return false;
  }
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }

  // Attaching the input queues bypasses the foreground lock so that
  // SetForegroundWindow succeeds when the shell (taskbar) owns the
  // foreground instead of the target application.
  const DWORD current_thread = GetCurrentThreadId();
  const DWORD foreground_thread =
      GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  const DWORD target_thread = GetWindowThreadProcessId(hwnd, nullptr);
  bool attached_foreground = false;
  bool attached_target = false;
  if (foreground_thread != 0 && foreground_thread != current_thread) {
    attached_foreground =
        AttachThreadInput(current_thread, foreground_thread, TRUE) != FALSE;
  }
  if (target_thread != 0 && target_thread != current_thread &&
      target_thread != foreground_thread) {
    attached_target =
        AttachThreadInput(current_thread, target_thread, TRUE) != FALSE;
  }

  SetForegroundWindow(hwnd);
  BringWindowToTop(hwnd);

  if (attached_foreground) {
    AttachThreadInput(current_thread, foreground_thread, FALSE);
  }
  if (attached_target) {
    AttachThreadInput(current_thread, target_thread, FALSE);
  }
  return GetForegroundWindow() == hwnd;
}

// 自动粘贴核心流程:
// 1. 隐藏本窗口, 让系统自然把焦点交还给上一个应用;
// 2. 轮询等待前台窗口出现, 且进程名与记录的目标一致 (防止粘错窗口);
// 3. 若焦点迟迟不回来 (例如从任务栏唤起), 用 ForceActivateWindow 拉起记住的目标窗口;
// 4. 确认目标后发送 Ctrl+V。
// 找不到匹配目标时返回 false, 不发送任何按键。
bool FlutterWindow::PasteToPreviousWindow() {
  const std::wstring expected_process = last_external_process_name_;
  HWND preferred = last_external_foreground_;
  if (preferred != nullptr && !IsWindow(preferred)) {
    preferred = nullptr;
  }

  // 隐藏本窗口让焦点交还上一个应用; 同时暂停渲染 (见 HideWindow 注释)。
  HideWindow();

  // Wait for the system to activate a window on its own. Shell windows
  // (taskbar/desktop) are ignored: they take focus when this window was
  // shown via its taskbar button and will never be the paste target.
  HWND target = nullptr;
  for (int attempt = 0; attempt < 25; ++attempt) {
    Sleep(20);
    const HWND foreground = GetForegroundWindow();
    if (foreground == nullptr || foreground == GetHandle()) {
      continue;
    }
    if (!IsCapturableForegroundWindow(foreground)) {
      continue;
    }
    if (!expected_process.empty() &&
        GetWindowProcessName(foreground) != expected_process) {
      break;
    }
    target = foreground;
    break;
  }

  // Focus did not return to the expected app (e.g. the window was shown
  // via its taskbar button): force-activate the remembered target window.
  if (target == nullptr && preferred != nullptr &&
      ForceActivateWindow(preferred)) {
    for (int attempt = 0; attempt < 10; ++attempt) {
      Sleep(20);
      if (GetForegroundWindow() == preferred) {
        target = preferred;
        break;
      }
    }
    if (target == nullptr) {
      const HWND foreground = GetForegroundWindow();
      if (foreground != nullptr && foreground != GetHandle() &&
          IsCapturableForegroundWindow(foreground) &&
          (expected_process.empty() ||
           GetWindowProcessName(foreground) == expected_process)) {
        target = foreground;
      }
    }
  }

  if (target == nullptr) {
    return false;
  }
  if (!expected_process.empty() &&
      GetWindowProcessName(target) != expected_process) {
    return false;
  }

  SendCtrlV();
  return true;
}
