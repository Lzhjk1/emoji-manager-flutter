# 一键构建打包: 以 lib/app_version.dart 为版本号唯一来源,
# 先同步到 Inno Setup 脚本, 再执行 Release 构建与安装包打包。
# 用法: powershell -ExecutionPolicy Bypass -File build-and-pack.ps1 (在项目根目录执行)

$ErrorActionPreference = "Stop"

$dartFile = "lib\app_version.dart"
$issFile = "installer\emoji_manager.iss"

# 从 Dart 源码解析版本号
$dart = [System.IO.File]::ReadAllText($dartFile)
if ($dart -notmatch "appVersion\s*=\s*'([^']+)'") {
    throw "无法从 $dartFile 解析 appVersion"
}
$version = $Matches[1]

# 同步到安装脚本 (保持原 UTF-8 无 BOM 编码; 用整行替换避免捕获组引用歧义)
$iss = [System.IO.File]::ReadAllText($issFile)
$iss = $iss -replace '#define MyAppVersion "[^"]*"', "#define MyAppVersion `"$version`""
[System.IO.File]::WriteAllText($issFile, $iss, [System.Text.UTF8Encoding]::new($false))
Write-Host "已同步版本号 $version -> $issFile"

flutter build windows --release
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" $issFile
