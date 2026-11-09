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
japanese.TaskAutoconfig=タブ名を表示する（Firefox に autoconfig を配置します）
english.TaskAutoconfig=Show tab names (installs a Firefox autoconfig)
japanese.TaskStartup=Windows へのサインイン時に起動する
english.TaskStartup=Start when signing in to Windows
japanese.SetupFailed=設定の一部に失敗しました（終了コード %1）。%n詳細は PowerShell で次を実行して確認してください:%n%n%2
english.SetupFailed=Part of the setup failed (exit code %1).%nRun the following in PowerShell to see details:%n%n%2
japanese.RestartFirefox=タブ名を表示するには、Firefox を完全に終了してから起動し直してください。
english.RestartFirefox=To show tab names, quit Firefox completely and start it again.

[Tasks]
Name: "autoconfig"; Description: "{cm:TaskAutoconfig}"
Name: "startup"; Description: "{cm:TaskStartup}"

[InstallDelete]
; Inno Setup は再インストール時にタスクを外しても前回のショートカットを消さないため、明示的に削除する
Type: files; Name: "{userstartup}\FirefoxProcTray.lnk"; Tasks: not startup

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
const
  BCM_SETSHIELD = $160C;
  LB_GETITEMHEIGHT = $01A1;
  IDI_SHIELD = 32518;
  DI_NORMAL = 3;

var
  ShieldShown: Boolean;
  TaskShield: TPanel;

function LoadIconWithScaleDown(Inst, Name: THandle; cx, cy: Integer; var Icon: THandle): Integer;
  external 'LoadIconWithScaleDown@comctl32.dll stdcall';
function DrawIconEx(DC: THandle; X, Y: Integer; Icon: THandle; cx, cy: Integer; Step: Cardinal; Brush: THandle; Flags: Cardinal): Integer;
  external 'DrawIconEx@user32.dll stdcall';
function DestroyIcon(Icon: THandle): Integer;
  external 'DestroyIcon@user32.dll stdcall';

{ タスク一覧の項目には画像を付けられないため、見出しの先頭に空白を足し、そこへ盾の画像を重ねる }
procedure AddTaskShield;
var
  List: TNewCheckListBox;
  Probe: TNewStaticText;
  Image: TBitmapImage;
  Icon: THandle;
  Index, I, Size, Border, ItemTop, ItemHeight: Integer;
  Pad: String;
begin
  if TaskShield <> nil then Exit;
  List := WizardForm.TasksList;
  Index := List.Items.IndexOf(CustomMessage('TaskAutoconfig'));
  if Index < 0 then Exit;
  Size := ScaleX(16);
  if LoadIconWithScaleDown(0, IDI_SHIELD, Size, Size, Icon) <> 0 then Exit;
  try
    Probe := TNewStaticText.Create(WizardForm);
    try
      Probe.Parent := List.Parent;
      Probe.Font := List.Font;
      Pad := '';
      for I := 1 to 20 do begin
        Pad := Pad + ' ';
        Probe.Caption := Pad;
        if Probe.Width >= Size + ScaleX(4) then Break;
      end;
    finally
      Probe.Free;
    end;
    List.ItemCaption[Index] := Pad + List.ItemCaption[Index];

    ItemTop := 0;
    for I := 0 to Index - 1 do
      ItemTop := ItemTop + SendMessage(List.Handle, LB_GETITEMHEIGHT, I, 0);
    ItemHeight := SendMessage(List.Handle, LB_GETITEMHEIGHT, Index, 0);
    Border := (List.Width - List.ClientWidth) div 2;
    { 一覧の前面に置くため、子ではなく兄弟のウィンドウにする。文字の開始位置はチェックボックス幅（13px）+ 余白（4px × 2）+ 2px }
    TaskShield := TPanel.Create(WizardForm);
    TaskShield.Parent := List.Parent;
    TaskShield.BevelOuter := bvNone;
    TaskShield.Color := List.Color;
    TaskShield.SetBounds(List.Left + Border + ScaleX(13) + ScaleX(8) + 2,
                         List.Top + Border + ItemTop + (ItemHeight - Size) div 2, Size, Size);
    Image := TBitmapImage.Create(WizardForm);
    Image.Parent := TaskShield;
    Image.Align := alClient;
    Image.Bitmap.Width := Size;
    Image.Bitmap.Height := Size;
    Image.Bitmap.Canvas.Brush.Color := List.Color;
    Image.Bitmap.Canvas.Pen.Color := List.Color;
    Image.Bitmap.Canvas.Rectangle(0, 0, Size, Size);
    DrawIconEx(Image.Bitmap.Canvas.Handle, 0, 0, Icon, Size, Size, 0, 0, DI_NORMAL);
    TaskShield.BringToFront;
  finally
    DestroyIcon(Icon);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Show: Boolean;
  Extra: Integer;
begin
  if CurPageID = wpSelectTasks then AddTaskShield;
  Show := (CurPageID = wpReady) and WizardIsTaskSelected('autoconfig');
  if Show = ShieldShown then Exit;
  ShieldShown := Show;
  { 昇格するのは Inno Setup ではなくインストール後の install.ps1 なので、Inno Setup は盾を自動では付けない }
  SendMessage(WizardForm.NextButton.Handle, BCM_SETSHIELD, 0, Ord(Show));
  { 盾の分だけボタンを左に広げる。位置は相対的に動かし、ウィザードのリサイズによる移動を壊さない }
  Extra := ScaleX(24);
  if not Show then Extra := -Extra;
  WizardForm.NextButton.Width := WizardForm.NextButton.Width + Extra;
  WizardForm.NextButton.Left := WizardForm.NextButton.Left - Extra;
  WizardForm.BackButton.Left := WizardForm.BackButton.Left - Extra;
end;

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
