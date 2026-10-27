# FirefoxProcTray をインストールする。
#   1. Firefox のインストール先に autoconfig（mozilla.cfg / autoconfig.js）を置く（管理者権限が必要。必要なら UAC で昇格する）
#   2. スタートアップにショートカットを登録する
#   3. トレイアプリを起動する
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-FirefoxDir <dir>] [-SkipAutoconfig] [-SkipStartup]
param(
    [string]$FirefoxDir,
    [switch]$SkipAutoconfig,
    [switch]$SkipStartup,
    [switch]$AutoconfigOnly   # 内部用: 昇格したプロセスで autoconfig の配置だけを行う
)

$ErrorActionPreference = 'Stop'
$Marker = 'FirefoxProcTray'
$TrayScript = Join-Path $PSScriptRoot 'FirefoxProcTray.ps1'
$Sources = @(
    @{ From = Join-Path $PSScriptRoot 'firefox-autoconfig\mozilla.cfg';                 To = 'mozilla.cfg' }
    @{ From = Join-Path $PSScriptRoot 'firefox-autoconfig\defaults\pref\autoconfig.js'; To = 'defaults\pref\autoconfig.js' }
)

function Find-FirefoxDir {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe') {
        $exe = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
        if ($exe -and (Test-Path -LiteralPath $exe)) { return Split-Path -Parent $exe.Trim('"') }
    }
    $fallback = Join-Path $env:ProgramFiles 'Mozilla Firefox'
    if (Test-Path -LiteralPath (Join-Path $fallback 'firefox.exe')) { return $fallback }
    $null
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 戻り値: 'copy'（配置が必要）/ 'same'（配置済み）。他人の autoconfig があれば上書きせず停止する
function Get-AutoconfigPlan([string]$dir) {
    $plan = 'same'
    foreach ($s in $Sources) {
        $dest = Join-Path $dir $s.To
        if (-not (Test-Path -LiteralPath $dest)) { $plan = 'copy'; continue }
        $current = [IO.File]::ReadAllText($dest)
        if ($current -eq [IO.File]::ReadAllText($s.From)) { continue }
        if ($current -notmatch $Marker) {
            throw "$dest に別の autoconfig が既にあります。上書きしないので、内容を確認して手動で統合してください。"
        }
        $plan = 'copy'
    }
    $plan
}

function Install-Autoconfig([string]$dir) {
    foreach ($s in $Sources) {
        $dest = Join-Path $dir $s.To
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $s.From -Destination $dest -Force
    }
}

if (-not $FirefoxDir) { $FirefoxDir = Find-FirefoxDir }

if ($AutoconfigOnly) {
    try { Install-Autoconfig $FirefoxDir; exit 0 } catch { Write-Error $_; exit 1 }
}

if (-not $SkipAutoconfig) {
    if (-not $FirefoxDir) { throw 'Firefox のインストール先が見つかりません。-FirefoxDir で指定してください。' }
    Write-Host "Firefox: $FirefoxDir"
    if ((Get-AutoconfigPlan $FirefoxDir) -eq 'same') {
        Write-Host 'autoconfig: 配置済みのためスキップしました'
    } elseif (Test-Admin) {
        Install-Autoconfig $FirefoxDir
        Write-Host 'autoconfig: 配置しました'
    } else {
        Write-Host 'autoconfig: 管理者権限で配置します（UAC の確認が出ます）'
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AutoconfigOnly', '-FirefoxDir', "`"$FirefoxDir`"")
        if ($p.ExitCode -ne 0) { throw "autoconfig の配置に失敗しました（終了コード $($p.ExitCode)）" }
        Write-Host 'autoconfig: 配置しました'
    }
}

$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScript`""
if (-not $SkipStartup) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'FirefoxProcTray.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    # PowerShell 7 から実行されても、トレイアプリは Windows PowerShell 5.1 で動かす
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = $psArgs
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.WindowStyle = 7   # 最小化。-WindowStyle Hidden が効くまでの一瞬の表示を目立たなくする
    $sc.Description = 'Firefox process monitor (tray)'
    $sc.Save()
    Write-Host "スタートアップ: 登録しました ($lnk)"
}

# 二重起動はトレイアプリ側の Mutex で防いでいるので、起動済みでもそのまま実行してよい
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $psArgs
Write-Host 'トレイアプリを起動しました。'
if (-not $SkipAutoconfig) { Write-Host 'タブ名を表示するには Firefox を完全に終了してから起動し直してください。' }
