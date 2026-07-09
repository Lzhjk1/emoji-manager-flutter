enum CloseButtonBehavior {
  exitApp('exit'),
  minimizeToTray('tray');

  const CloseButtonBehavior(this.storageValue);

  final String storageValue;

  static CloseButtonBehavior fromStorage(String? value) {
    return CloseButtonBehavior.values.firstWhere(
      (item) => item.storageValue == value,
      orElse: () => CloseButtonBehavior.exitApp,
    );
  }
}
