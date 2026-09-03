/// 应用当前版本号 (唯一来源)。
///
/// 发布安装包时无需手动同步: build-and-pack.ps1 会把这里的版本号
/// 自动写入 installer/emoji_manager.iss 的 `#define MyAppVersion`。
const String appVersion = '0.0.3-rc5';
