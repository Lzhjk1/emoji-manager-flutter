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
  void UpdateForegroundCapture();
  bool SetHotkey(bool enabled, UINT modifiers, UINT key_code);
  bool CopyImageToClipboard(int width, int height,
                            const std::vector<uint8_t>& rgba, bool paste,
                            bool* pasted);
  bool PasteToPreviousWindow();
  static std::wstring GetWindowProcessName(HWND hwnd);
  static bool IsCapturableForegroundWindow(HWND hwnd);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  bool close_to_tray_ = false;
  bool always_on_top_ = false;
  bool force_close_ = false;
  bool tray_icon_added_ = false;
  NOTIFYICONDATA tray_icon_data_ = {};

  UINT hotkey_modifiers_ = MOD_CONTROL | MOD_SHIFT;
  UINT hotkey_key_code_ = 0x56;  // 'V'
  bool hotkey_registered_ = false;
  HWND last_seen_foreground_ = nullptr;
  HWND last_external_foreground_ = nullptr;
  std::wstring last_external_process_name_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
