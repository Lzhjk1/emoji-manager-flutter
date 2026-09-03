; Emoji Manager 表情包工具 - Inno Setup 安装包脚本
; 编译方式: ISCC.exe installer\emoji_manager.iss (在项目根目录执行)

#define MyAppName "Emoji Manager"
#define MyAppVersion "0.0.3-rc2"
#define MyAppPublisher "Roasal"
#define MyAppExeName "emoji_manager_flutter.exe"
#define MyReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{8F4E2C7A-1B3D-4E5F-9A6C-7D8E9F0A1B2C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\EmojiManager
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=EmojiManager-Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 仅当前用户安装，无需管理员权限
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"

[Files]
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
// 安装前结束正在运行的旧版本进程，避免自动卸载旧版时失败或要求重启。
// 同 AppId 的情况下，Inno Setup 会在“准备安装”阶段自动静默卸载旧版本。
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'),
    '/C taskkill /IM "{#MyAppExeName}" /F /T',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

; 卸载时默认保留用户数据（表情包、使用记录）。
; 如需卸载时一并清理，取消下面两行注释：
; [UninstallDelete]
; Type: filesandordirs; Name: "{localappdata}\emoji_manager_flutter"
