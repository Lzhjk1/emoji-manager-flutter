#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <cstdint>
#include <memory>
#include <vector>

#include "win32_window.h"

// 承载 Flutter 视图的主窗口, 同时实现所有 Windows 原生功能:
// - 托盘图标与关闭到托盘/退出
// - 全局热键注册 (显示/隐藏窗口)
// - 前台应用跟踪 (250ms 定时器), 供自动粘贴判断目标应用
// - 剪贴板写入 (CF_HDROP 文件 / CF_DIB 位图) 与模拟 Ctrl+V 粘贴
// - 在资源管理器中定位文件 (shell API)
//
// 通过两条 MethodChannel 与 Dart 层通信:
// - "emoji_manager/platform_clipboard": 复制文件/图片、资源管理器定位
// - "emoji_manager/window_control": 窗口设置、前台应用查询、热键开关
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
  void ApplyWindowSettings(const flutter::EncodableMap& arguments,
                           flutter::MethodResult<flutter::EncodableValue>* result);
  void SetAlwaysOnTop(bool enabled);
  void SetCloseToTray(bool enabled);
  void MinimizeToTray();
  void RestoreFromTray();
  void ToggleWindowVisibility();
  void EnsureTrayIcon();
  void RemoveTrayIcon();
  void ExitApplication();
  // 定时器回调: 记录最近的非本应用前台窗口及其进程名。
  void UpdateForegroundCapture();
  // 注册/注销全局热键; 与其他软件冲突时返回 false。
  bool SetHotkey(bool enabled, UINT modifiers, UINT key_code);
  // 把 RGBA 像素转成 CF_DIB 写入剪贴板, 可选自动粘贴到之前的前台窗口。
  bool CopyImageToClipboard(int width, int height,
                            const std::vector<uint8_t>& rgba, bool paste,
                            bool* pasted);
  // 隐藏本窗口, 等待焦点回到目标应用后发送 Ctrl+V。
  bool PasteToPreviousWindow();
  static std::wstring GetWindowProcessName(HWND hwnd);
  // 排除任务栏/桌面等 shell 窗口, 它们不能作为粘贴目标。
  static bool IsCapturableForegroundWindow(HWND hwnd);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // ---- 窗口/托盘状态 ----
  bool close_to_tray_ = false;      // 关闭按钮是否缩到托盘
  bool always_on_top_ = false;      // 窗口置顶
  bool force_close_ = false;        // 托盘菜单"退出"触发的真实关闭
  bool tray_icon_added_ = false;
  NOTIFYICONDATA tray_icon_data_ = {};

  // ---- 全局热键 ----
  UINT hotkey_modifiers_ = MOD_CONTROL | MOD_SHIFT;
  UINT hotkey_key_code_ = 0x56;  // 'V'
  bool hotkey_registered_ = false;

  // ---- 前台应用跟踪 ----
  HWND last_seen_foreground_ = nullptr;        // 去重用
  HWND last_external_foreground_ = nullptr;    // 最近的外部前台窗口
  std::wstring last_external_process_name_;    // 其进程名 (小写, 含 .exe)
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
