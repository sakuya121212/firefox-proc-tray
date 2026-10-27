# FirefoxProcTray をアンインストールする（install.ps1 の逆）。
#   1. トレイアプリを終了し、スタートアップのショートカットを削除する
#   2. Firefox のインストール先から autoconfig を削除する（管理者権限が必要。必要なら UAC で昇格する）
#   3. %LOCALAPPDATA%\FirefoxProcTray（タブ名の出力先）を削除する
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-FirefoxDir <dir>]
param(
    [string]$FirefoxDir,
    [switch]$AutoconfigOnly   # 内部用: 昇格したプロセスで autoconfig の削除だけを行う
)

$ErrorActionPreference = 'Stop'
$Marker = 'FirefoxProcTray'
$Targets = 'mozilla.cfg', 'defaults\pref\autoconfig.js'

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

# 自分が置いたもの（マーカー入り）だけを対象にし、他人の autoconfig は消さない
function Get-OwnAutoconfig([string]$dir) {
    foreach ($t in $Targets) {
        $path = Join-Path $dir $t
        if ((Test-Path -LiteralPath $path) -and ([IO.File]::ReadAllText($path) -match $Marker)) { $path }
    }
}

if (-not $FirefoxDir) { $FirefoxDir = Find-FirefoxDir }

if ($AutoconfigOnly) {
    try { Get-OwnAutoconfig $FirefoxDir | Remove-Item -Force; exit 0 } catch { Write-Error $_; exit 1 }
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'FirefoxProcTray\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "トレイアプリを終了しました (PID $($_.ProcessId))" }

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'FirefoxProcTray.lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host 'スタートアップ: 削除しました' }

if ($FirefoxDir -and @(Get-OwnAutoconfig $FirefoxDir).Count -gt 0) {
    if (Test-Admin) {
        Get-OwnAutoconfig $FirefoxDir | Remove-Item -Force
    } else {
        Write-Host 'autoconfig: 管理者権限で削除します（UAC の確認が出ます）'
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AutoconfigOnly', '-FirefoxDir', "`"$FirefoxDir`"")
        if ($p.ExitCode -ne 0) { throw "autoconfig の削除に失敗しました（終了コード $($p.ExitCode)）" }
    }
    Write-Host 'autoconfig: 削除しました。Firefox を再起動すると反映されます'
}

$data = Join-Path $env:LOCALAPPDATA 'FirefoxProcTray'
if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force; Write-Host "削除しました: $data" }
Write-Host 'アンインストールが完了しました。'
