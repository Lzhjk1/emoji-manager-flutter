# Emoji Manager (emoji_manager_flutter)

一款面向 Windows 桌面的表情包管理器，使用 Flutter 构建。以常驻小窗口为主要形态，
专注于**快速找到、复制并粘贴表情**：全局热键随时唤起，选中即复制，并可自动粘贴到
QQ 等聊天窗口，保留 GIF 动画与原图压缩格式。

## 功能特性

### 浏览与管理
- 分类管理：目录即分类，支持网格视图浏览、搜索、分类封面
- 一图多分类：混合索引架构，文件按主分类目录存放，附加分类以链接形式记录在中央索引 `library.json`
- 导入自动去重：文件大小预筛 + SHA-256 精确校验，重复图片只写链接不复制文件
- 链接自愈：图片被改名/移动后按大小 + 哈希自动找回，结果通过应用内浮动卡片提示
- 缩略图缓存：统一生成 256px 缩略图，GIF 直接播放动图不生成静态缩略图
- 网格拖拽重排序（顺序持久化），长按放大预览（悬停可切换图片）
- 右键菜单：复制到剪贴板、预览与备注、刷新缩略图、在资源管理器中显示、设置备注
- 使用记录（最近使用分类），按使用频次排序

### 快速发送
- 全局唤起热键（默认 `Ctrl+Shift+V`，可在设置中修改/禁用）
- 自动粘贴：唤起时检测当前前台应用，若在设置的应用列表内（如 QQ），图片以**原文件形式**（CF_HDROP）复制并自动粘贴到聊天窗口，保留 GIF 动画与 JPEG/WebP 压缩，避免被重新编码放大体积

### 其他
- 拖入图片/文件夹快速导入当前分类
- 系统托盘常驻，窗口隐藏前先最小化以暂停引擎渲染、降低常驻内存
- 图片统一按实际显示尺寸（× devicePixelRatio）解码，严格控制内存占用
- 应用日志：`<表情包根目录>/logs/` 每次启动一份，自动保留最近 30 份

## 环境要求

- Windows 10/11 x64
- Flutter SDK（Windows desktop 支持）
- Visual Studio（含 C++ 桌面开发工作负载，供 Flutter Windows 构建使用）
- 可选：Inno Setup 6（仅打包安装包时需要，默认安装路径 `C:\Program Files (x86)\Inno Setup 6`）

## 构建与打包

```powershell
# 调试运行
flutter run -d windows

# 一键构建 Release 并打包安装包（输出到 installer/output/）
powershell -ExecutionPolicy Bypass -File build-and-pack.ps1
```

也可分步执行：

```powershell
flutter build windows --release
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" installer\emoji_manager.iss
```

安装包输出文件名由 `installer/emoji_manager.iss` 中的 `MyAppVersion` 决定，
发布时需与 `lib/app_version.dart` 中的版本号保持一致。

## 项目结构

```
lib/
  main.dart                 # 入口, 全局图片缓存上限配置
  app.dart                  # 应用根 Widget
  app_version.dart          # 版本号单一来源
  models/                   # 数据模型 (EmojiItem 等)
  services/                 # 服务层 (索引/仓库/缩略图/剪贴板/热键/设置/日志等)
  controllers/              # 状态管理 (EmojiManagerController)
  pages/                    # 页面 (emoji_home_page)
  widgets/                  # 组件 (预览弹窗等)
windows/runner/             # C++ 层: 剪贴板原文件复制、前台窗口检测、
                            #   输入模拟、全局热键、资源管理器定位 (Shell API)
installer/                  # Inno Setup 安装脚本
docs/                       # 方案文档与更新日志
```

## 相关文档

- [更新日志](docs/CHANGELOG.md)
- [混合索引重构方案](docs/重构方案-混合索引.md)

## License

[MIT](LICENSE)
