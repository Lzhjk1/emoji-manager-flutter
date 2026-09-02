/// 窗口关闭按钮的行为。
enum CloseButtonBehavior {
  /// 直接退出应用。
  exitApp('exit'),

  /// 隐藏到系统托盘, 保留后台运行 (可通过托盘图标再次唤起)。
  minimizeToTray('tray');

  const CloseButtonBehavior(this.storageValue);

  /// 写入设置存储时使用的字符串值。
  final String storageValue;

  /// 从设置存储恢复枚举值, 未知值回退为直接退出。
  static CloseButtonBehavior fromStorage(String? value) {
    return CloseButtonBehavior.values.firstWhere(
      (item) => item.storageValue == value,
      orElse: () => CloseButtonBehavior.exitApp,
    );
  }
}
