; FirefoxProcTray のインストーラー定義（Inno Setup）
; ビルド: ISCC.exe /DAppVersion=0.1.0 installer\FirefoxProcTray.iss  → installer\Output\FirefoxProcTray-Setup-0.1.0.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{5EC65DEF-CD39-45E8-82C9-015BE0850079}
AppName=FirefoxProcTray
AppVersion={#AppVersion}
AppPublisher=sakuya121212
AppPublisherURL=https://github.com/sakuya121212/firefox-proc-tray
DefaultDirName={autopf}\FirefoxProcTray
DisableProgramGroupPage=yes
; 本体はユーザー領域（%LOCALAPPDATA%\Programs）に置く。autoconfig の配置だけ install.ps1 が UAC で昇格する
PrivilegesRequired=lowest
; 32 ビットで動くと {sys} が SysWOW64 になり、32 ビット PowerShell では Firefox の App Paths（64 ビット側レジストリ）が読めない
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=FirefoxProcTray-Setup-{#AppVersion}
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=FirefoxProcTray
SetupLogging=yes

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
japanese.TaskAutoconfig=タブ名を表示する（Firefox に autoconfig を配置します。管理者権限の確認が出ます）
english.TaskAutoconfig=Show tab names (installs a Firefox autoconfig; requires administrator approval)
japanese.TaskStartup=Windows へのサインイン時に起動する
english.TaskStartup=Start when signing in to Windows
japanese.SetupFailed=設定の一部に失敗しました（終了コード %1）。%n詳細は PowerShell で次を実行して確認してください:%n%n%2
english.SetupFailed=Part of the setup failed (exit code %1).%nRun the following in PowerShell to see details:%n%n%2
japanese.RestartFirefox=タブ名を表示するには、Firefox を完全に終了してから起動し直してください。
english.RestartFirefox=To show tab names, quit Firefox completely and start it again.

[Tasks]
Name: "autoconfig"; Description: "{cm:TaskAutoconfig}"
Name: "startup"; Description: "{cm:TaskStartup}"

[Files]
Source: "..\FirefoxProcTray.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\firefox-autoconfig\*"; DestDir: "{app}\firefox-autoconfig"; Flags: ignoreversion recursesubdirs

[Icons]
; ショートカット名は uninstall.ps1 が削除する FirefoxProcTray.lnk と揃える
Name: "{autoprograms}\FirefoxProcTray"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\FirefoxProcTray.ps1"""; WorkingDir: "{app}"; Flags: runminimized
Name: "{userstartup}\FirefoxProcTray"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\FirefoxProcTray.ps1"""; WorkingDir: "{app}"; Flags: runminimized; Tasks: startup

[UninstallRun]
; ファイル削除より先に実行される。トレイアプリの終了と autoconfig・出力ファイルの削除を行う
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "UninstallScript"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Command, Params: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  { スタートアップ登録は [Icons] で行うので -SkipStartup。install.ps1 はトレイアプリの起動も行う }
  Command := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install.ps1') + '" -SkipStartup';
  Params := Command;
  if not WizardIsTaskSelected('autoconfig') then
    Params := Params + ' -SkipAutoconfig';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, ExpandConstant('{app}'),
              SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    MsgBox(FmtMessage(CustomMessage('SetupFailed'), [IntToStr(ResultCode), 'powershell ' + Params]), mbError, MB_OK)
  else if WizardIsTaskSelected('autoconfig') and not WizardSilent then
    MsgBox(CustomMessage('RestartFirefox'), mbInformation, MB_OK);
end;
