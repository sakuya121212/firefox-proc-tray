# Firefox のプロセス単位の CPU・メモリをタスクトレイに表示し、高負荷時に通知する。
# 起動例: powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File FirefoxProcTray.ps1

$IntervalSec      = 2
$CpuAlertPercent  = 50    # Firefox 全体の CPU 使用率。タスクマネージャーと同じく全論理コア合計を 100% とする
$CpuAlertSamples  = 5     # 連続でこの回数超えたら通知（既定 2 秒 x 5 = 10 秒）
$ProcMemAlertMB   = 2048  # 単一プロセスのプライベートメモリ
$AlertCooldownSec = 300   # 同じ内容の通知を繰り返さない間隔
$PopupTopN        = 10    # ホバー時のポップアップに出すプロセス数
$PopupTabWidth    = 44    # ポップアップのタブ名の最大幅（半角換算）# Firefox 側の mozilla.cfg が書き出す PID -> タブ名。これより古ければ Firefox 側が止まっているとみなす
$ProcInfoPath     = Join-Path $env:LOCALAPPDATA 'FirefoxProcTray\procinfo.json'
$ProcInfoMaxAgeSec = 10
# requestProcInfo の type と、タブ名が取れないときに使うコマンドラインの種類（main / tab）を表示名に変換する
$TypeLabels = @{
    browser = 'Firefox 本体'; main = 'Firefox 本体'
    web = 'Web ページ'; webIsolated = 'Web ページ'; withCoopCoep = 'Web ページ'; tab = 'Web ページ'
    webServiceWorker = 'サイトの裏処理'; extension = '拡張機能'; gpu = '画面描画'; rdd = '動画・音声'
    socket = '通信'; utility = '補助処理'; privilegedabout = 'Firefox 内部ページ'
    privilegedmozilla = 'Mozilla サイト'; file = 'ローカルファイル'; preallocated = '待機中'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# 既定の MS UI Gothic や Yu Gothic UI は GDI 描画の小さいサイズでギザつくため Meiryo UI を使う
$UiFont = [System.Drawing.Font]::new('Meiryo UI', 9)
# トレイアイコンの配色（オレンジ → 赤 → 赤紫。未起動時は灰色）
$IconColors = @{
    On  = @([System.Drawing.Color]::FromArgb(255, 149, 0), [System.Drawing.Color]::FromArgb(255, 48, 72), [System.Drawing.Color]::FromArgb(205, 30, 120))
    Off = @([System.Drawing.Color]::FromArgb(150, 150, 150), [System.Drawing.Color]::FromArgb(125, 125, 125), [System.Drawing.Color]::FromArgb(100, 100, 100))
}
Add-Type -Namespace FxTray -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
# ホバー用ポップアップ。表示してもフォーカスを奪わず、タスクバー/Alt+Tab にも出さない
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
namespace FxTray {
    public static class Shell {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct POINT { public int X, Y; }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr WindowFromPoint(POINT p);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowRect(System.IntPtr hWnd, out RECT r);

        // 指定位置にあるトップレベルウィンドウ（タスクバーや隠れたアイコンの領域）の枠
        public static System.Drawing.Rectangle RootWindowRectAt(int x, int y) {
            POINT p; p.X = x; p.Y = y;
            System.IntPtr root = GetAncestor(WindowFromPoint(p), 2); // GA_ROOT
            RECT r;
            if (root == System.IntPtr.Zero || !GetWindowRect(root, out r)) return System.Drawing.Rectangle.Empty;
            return System.Drawing.Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }
    }
    public class Popup : System.Windows.Forms.Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override System.Windows.Forms.CreateParams CreateParams {
            get {
                System.Windows.Forms.CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST
                return cp;
            }
        }
    }
    // Label 既定の GDI 描画はヒンティングが強く暗い背景でカクついて見えるため、GDI+ のグレースケール AA で描く
    public class SmoothLabel : System.Windows.Forms.Label {
        public SmoothLabel() { UseCompatibleTextRendering = true; }
        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            base.OnPaint(e);
        }
    }
}
'@

$Mutex = [System.Threading.Mutex]::new($false, 'Local\FirefoxProcTray')
if (-not $Mutex.WaitOne(0)) { exit }

$LogPath   = Join-Path $PSScriptRoot 'FirefoxProcTray.log'
$Cores     = [Environment]::ProcessorCount
$PrevCpu   = @{}   # PID -> 前回の TotalProcessorTime (ticks)
$TypeCache = @{}   # PID -> プロセス種類
$LastAlert = @{}   # 通知キー -> 最終通知時刻
$TabInfoMissingText = 'タブ名を取得できていません（mozilla.cfg 未導入、または Firefox 側でエラー）'
$State     = @{ TabInfoOk = $false; PrevTime = $null; HighCount = 0; IconHandle = [IntPtr]::Zero; IconKey = ''; AlertsOn = $true; Rows = @(); HoverAnchor = [System.Drawing.Point]::Empty; HoverRect = [System.Drawing.Rectangle]::Empty; SortCol = 2; SortDesc = $true }
# 一覧ウィンドウの列。Desc は最初にクリックしたときの並び順（数値は大きい順、文字は昇順）
$ListColumns = @(
    @{ Title = 'PID';                  Width = 80;  Align = 'Left';  Key = 'Id';        Desc = $false }
    @{ Title = '種類';                 Width = 140; Align = 'Left';  Key = 'Type';      Desc = $false }
    @{ Title = 'CPU %';                Width = 80;  Align = 'Right'; Key = 'Cpu';       Desc = $true }
    @{ Title = '専用メモリ (MB)';      Width = 120; Align = 'Right'; Key = 'PrivateMB'; Desc = $true }
    @{ Title = 'ワーキングセット (MB)'; Width = 140; Align = 'Right'; Key = 'WorkingMB'; Desc = $true }
    @{ Title = 'タブ';                 Width = 420; Align = 'Left';  Key = { $_.Tabs -join ' / ' }; Desc = $false; EmptyLast = $true }
)
# ポップアップの列。Width は半角換算の桁数（▲▼ 込み）、ListCol は対応する $ListColumns の添字
$PopupColumns = @(
    @{ Title = 'PID';            Width = 7;  Right = $false; ListCol = 0 }
    @{ Title = '種類';           Width = 18; Right = $false; ListCol = 1 }
    @{ Title = 'CPU%';           Width = 7;  Right = $true;  ListCol = 2 }
    @{ Title = '専用メモリ(MB)'; Width = 16; Right = $true;  ListCol = 3 }
    @{ Title = 'タブ';           Width = 0;  Right = $false; ListCol = 5 }
)

function Read-ProcInfo {
    try {
        $item = Get-Item -LiteralPath $ProcInfoPath -ErrorAction Stop
        if (([DateTime]::Now - $item.LastWriteTime).TotalSeconds -gt $ProcInfoMaxAgeSec) { return $null }
        $json = [IO.File]::ReadAllText($ProcInfoPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $map = @{}
        foreach ($p in $json.processes) { $map[[int]$p.pid] = $p }
        $map
    } catch { $null }
}

function Get-FirefoxSample {
    $now = [DateTime]::UtcNow
    $procs = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
    $procInfo = Read-ProcInfo
    $State.TabInfoOk = $null -ne $procInfo

    if (@($procs | Where-Object { -not $TypeCache.ContainsKey($_.Id) }).Count -gt 0) {
        foreach ($p in Get-CimInstance Win32_Process -Filter "Name='firefox.exe'") {
            $cl = $p.CommandLine
            # 子プロセスのコマンドライン末尾は "... - <番号> <種類>"（tab / gpu / rdd / socket / utility など）
            $TypeCache[[int]$p.ProcessId] =
                if (-not $cl) { '?' }
                elseif ($cl -notmatch '\s-contentproc\s') { 'main' }
                else { ($cl.Trim() -split '\s+')[-1] }
        }
    }

    $elapsed = if ($State.PrevTime) { ($now - $State.PrevTime).TotalSeconds } else { 0 }
    $alive = @{}
    $rows = foreach ($p in $procs) {
        $alive[$p.Id] = $true
        try { $ticks = $p.TotalProcessorTime.Ticks } catch { continue }
        $cpu = 0.0
        if ($elapsed -gt 0 -and $PrevCpu.ContainsKey($p.Id)) {
            # 0 と書くと整数版の Max が選ばれて小数が丸められるため 0.0 にする
            $cpu = [Math]::Max(0.0, ($ticks - $PrevCpu[$p.Id]) / 1e7 / $elapsed / $Cores * 100)
        }
        $PrevCpu[$p.Id] = $ticks
        $info = if ($procInfo) { $procInfo[$p.Id] } else { $null }
        $type = if ($info -and $info.type) { $info.type } elseif ($TypeCache.ContainsKey($p.Id)) { $TypeCache[$p.Id] } else { '?' }
        if ($TypeLabels.ContainsKey($type)) { $type = $TypeLabels[$type] }
        [pscustomobject]@{
            Id        = $p.Id
            Type      = $type
            Cpu       = $cpu
            PrivateMB = $p.PrivateMemorySize64 / 1MB
            WorkingMB = $p.WorkingSet64 / 1MB
            # if 式の結果は 1 要素だと文字列に展開されるため、外側で配列に包む
            Tabs      = @(if ($info) { $info.tabs | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } })
            Frames    = if ($info) { [int]$info.frames } else { 0 }
        }
    }
    foreach ($k in @($PrevCpu.Keys))   { if (-not $alive.ContainsKey($k)) { $PrevCpu.Remove($k) } }
    foreach ($k in @($TypeCache.Keys)) { if (-not $alive.ContainsKey($k)) { $TypeCache.Remove($k) } }
    $State.PrevTime = $now
    @($rows | Sort-Object Cpu, PrivateMB -Descending)
}

# 8 倍で描いて縮小し、16px でも輪郭を保つ。Firefox を連想させる配色の角丸に白いキツネの顔（ロゴではない独自の図形）を描く
function New-TrayBitmap([int]$size, [string]$status) {
    $s = $size * 8
    $big = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $colors = if ($status -eq 'off') { $IconColors.Off } else { $IconColors.On }
    $d = $s * 0.48
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
    $path.AddArc(0, $s - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $back = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.PointF]::new(0, 0), [System.Drawing.PointF]::new($s, $s), $colors[0], $colors[2])
    $blend = [System.Drawing.Drawing2D.ColorBlend]::new(3)
    $blend.Colors = [System.Drawing.Color[]]$colors
    $blend.Positions = [single[]]@(0, 0.55, 1)
    $back.InterpolationColors = $blend
    $g.FillPath($back, $path)

    # キツネの顔。座標は幅 1 の枠内の値で、枠の外周に 14% の余白を取る
    $fox = 0.08, 0.06, 0.34, 0.30, 0.66, 0.30, 0.92, 0.06, 0.96, 0.52, 0.50, 0.96, 0.04, 0.52
    $points = for ($i = 0; $i -lt $fox.Count; $i += 2) {
        [System.Drawing.PointF]::new([float]((0.14 + $fox[$i] * 0.72) * $s), [float]((0.14 + $fox[$i + 1] * 0.72) * $s))
    }
    $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]$points)
    $eye = [System.Drawing.SolidBrush]::new($colors[1])
    foreach ($x in 0.37, 0.63) {
        $g.FillEllipse($eye, [float](($x - 0.055) * $s), [float](0.47 * $s), [float](0.11 * $s), [float](0.11 * $s))
    }

    if ($status -eq 'alert') {
        # 高負荷の印。赤い点の周囲を透明に抜いて、背景のグラデーションと区別しやすくする
        $dot = $s * 0.35
        $x = $s - $dot
        $edge = $s * 0.06
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $clear = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Transparent)
        $g.FillEllipse($clear, [float]($x - $edge), [float]($x - $edge), [float]($dot + 2 * $edge), [float]($dot + 2 * $edge))
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $red = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(220, 20, 40))
        $g.FillEllipse($red, [float]$x, [float]$x, [float]$dot, [float]$dot)
        $clear.Dispose(); $red.Dispose()
    }
    $eye.Dispose(); $back.Dispose(); $path.Dispose(); $g.Dispose()

    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $h = [System.Drawing.Graphics]::FromImage($bmp)
    $h.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $h.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $h.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $h.DrawImage($big, [System.Drawing.Rectangle]::new(0, 0, $size, $size))
    $h.Dispose(); $big.Dispose()
    $bmp
}

# $status: off（Firefox 未起動）/ normal / alert（合計 CPU がしきい値以上）
function Set-TrayIcon([string]$status) {
    if ($status -eq $State.IconKey) { return }
    $bmp = New-TrayBitmap ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width) $status
    $handle = $bmp.GetHicon()
    $bmp.Dispose()
    $Notify.Icon = [System.Drawing.Icon]::FromHandle($handle)
    # Icon.FromHandle はハンドルを所有しないため、差し替えた古いハンドルは自前で解放する
    if ($State.IconHandle -ne [IntPtr]::Zero) { [void][FxTray.Native]::DestroyIcon($State.IconHandle) }
    $State.IconHandle = $handle
    $State.IconKey = $status
}

function Update-Tray($rows, [double]$cpu) {
    $status = if ($rows.Count -eq 0) { 'off' } elseif ($cpu -ge $CpuAlertPercent) { 'alert' } else { 'normal' }
    Set-TrayIcon $status
}

function Send-Alert([string]$key, [string]$title, [string]$text) {
    $now = Get-Date
    if ($LastAlert.ContainsKey($key) -and ($now - $LastAlert[$key]).TotalSeconds -lt $AlertCooldownSec) { return }
    $LastAlert[$key] = $now
    $Notify.ShowBalloonTip(5000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Test-Alerts($rows, [double]$cpu) {
    if (-not $State.AlertsOn -or $rows.Count -eq 0) { $State.HighCount = 0; return }
    if ($cpu -ge $CpuAlertPercent) { $State.HighCount++ } else { $State.HighCount = 0 }
    if ($State.HighCount -ge $CpuAlertSamples) {
        $top = $rows[0]
        Send-Alert 'cpu' 'Firefox の CPU 使用率が高い状態です' (
            "合計 {0:N0}%（{1} 秒以上継続）`n最大: PID {2}（{3}）{4:N0}%" -f $cpu, ($CpuAlertSamples * $IntervalSec), $top.Id, $top.Type, $top.Cpu)
    }
    foreach ($r in $rows) {
        if ($r.PrivateMB -ge $ProcMemAlertMB) {
            Send-Alert "mem:$($r.Id)" 'Firefox のメモリ使用量が大きいプロセスがあります' (
                'PID {0}（{1}）: {2:N0} MB' -f $r.Id, $r.Type, $r.PrivateMB)
        }
    }
}

function Get-SortedRows($rows) {
    # 同じ値どうしは PID 順にして、更新のたびに行が入れ替わらないようにする
    $col = $ListColumns[$State.SortCol]
    $keys = @(@{ Expression = $col.Key; Descending = $State.SortDesc }, 'Id')
    # タブのないプロセス（GPU など）は昇順・降順どちらでも末尾に回す
    if ($col.EmptyLast) { $keys = @(@{ Expression = { $_.Tabs.Count -gt 0 }; Descending = $true }) + $keys }
    @($rows | Sort-Object $keys)
}

# 並び順は一覧ウィンドウとポップアップで共有する。$listCol は $ListColumns の添字
function Set-Sort([int]$listCol) {
    if ($listCol -eq $State.SortCol) { $State.SortDesc = -not $State.SortDesc }
    else { $State.SortCol = $listCol; $State.SortDesc = $ListColumns[$listCol].Desc }
    if ($Form.Visible) { Update-List $State.Rows }
    if ($Popup.Visible) { Update-Popup $State.Rows; Move-Popup }
}

function Update-List($rows) {
    $cpu = if ($rows.Count) { ($rows | Measure-Object Cpu -Sum).Sum } else { 0 }
    $mem = if ($rows.Count) { ($rows | Measure-Object PrivateMB -Sum).Sum } else { 0 }
    $Summary.Text = '合計 CPU {0:N3}%    専用メモリ {1:N0} MB    {2} プロセス    {3} 秒ごとに更新' -f $cpu, $mem, $rows.Count, $IntervalSec
    if (-not $State.TabInfoOk) { $Summary.Text += '    ※ ' + $TabInfoMissingText }
    for ($i = 0; $i -lt $ListColumns.Count; $i++) {
        $mark = if ($i -ne $State.SortCol) { '' } elseif ($State.SortDesc) { ' ▼' } else { ' ▲' }
        $text = $ListColumns[$i].Title + $mark
        if ($List.Columns[$i].Text -ne $text) { $List.Columns[$i].Text = $text }
    }
    $sorted = Get-SortedRows $rows
    $List.BeginUpdate()
    $List.Items.Clear()
    foreach ($r in $sorted) {
        $item = [System.Windows.Forms.ListViewItem]::new([string]$r.Id)
        [void]$item.SubItems.Add($r.Type)
        [void]$item.SubItems.Add(('{0:N3}' -f $r.Cpu))
        [void]$item.SubItems.Add(('{0:N0}' -f $r.PrivateMB))
        [void]$item.SubItems.Add(('{0:N0}' -f $r.WorkingMB))
        [void]$item.SubItems.Add($(if ($r.Tabs.Count) { $r.Tabs -join ' / ' } elseif ($r.Frames) { '(iframe {0})' -f $r.Frames } else { '' }))
        [void]$List.Items.Add($item)
    }
    $List.EndUpdate()
}

function Show-List {
    if (-not $Form.Visible) {
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $Form.Location = [System.Drawing.Point]::new($area.Right - $Form.Width - 8, $area.Bottom - $Form.Height - 8)
        $Form.Show()
    }
    Update-List $State.Rows
    $Form.Activate()
}

function Format-Cell([string]$s, [int]$width, [switch]$Right) {
    # 等幅フォントでは全角が半角 2 文字分の幅になるので、その幅で数えて埋める
    $w = 0
    foreach ($c in $s.ToCharArray()) { $w += if ([int]$c -gt 0xFF) { 2 } else { 1 } }
    $pad = ' ' * [Math]::Max(0, $width - $w)
    if ($Right) { $pad + $s } else { $s + $pad }
}

function Limit-Width([string]$s, [int]$max) {
    $w = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $w += if ([int]$s[$i] -gt 0xFF) { 2 } else { 1 }
        if ($w -gt $max - 1) { return $s.Substring(0, $i) + '…' }
    }
    $s
}

function Get-TabCell($r) {
    if ($r.Tabs.Count -eq 0) { return $(if ($r.Frames) { '(iframe {0})' -f $r.Frames } else { '' }) }
    $more = if ($r.Tabs.Count -gt 1) { ' 他 {0}' -f ($r.Tabs.Count - 1) } else { '' }
    (Limit-Width $r.Tabs[0] ($PopupTabWidth - $more.Length * 2)) + $more
}

function Format-PopupLine([string[]]$cells) {
    $parts = for ($i = 0; $i -lt $PopupColumns.Count; $i++) {
        Format-Cell $cells[$i] $PopupColumns[$i].Width -Right:$PopupColumns[$i].Right
    }
    $parts -join ' '
}

# 見出し行のクリック位置 (x) を列の添字に変換する。等幅フォントの 1 桁の幅と描画の左余白を実測して桁位置を求める
function Get-PopupColumnAt([int]$x) {
    $g = $PopupCols.CreateGraphics()
    try {
        $w10 = $g.MeasureString('0' * 10, $PopupCols.Font).Width
        $w20 = $g.MeasureString('0' * 20, $PopupCols.Font).Width
    } finally { $g.Dispose() }
    $cw = ($w20 - $w10) / 10
    $pos = ($x - ($w10 - $cw * 10) / 2) / $cw
    $edge = 0
    for ($i = 0; $i -lt $PopupColumns.Count - 1; $i++) {
        $edge += $PopupColumns[$i].Width + 1   # 列の後ろの区切り空白は左の列に含める
        if ($pos -lt $edge) { return $i }
    }
    $PopupColumns.Count - 1
}

function Update-Popup($rows) {
    if ($rows.Count -eq 0) {
        $PopupHead.Text = 'Firefox は起動していません'
        $PopupCols.Visible = $false
        $PopupBody.Visible = $false
        $PopupFoot.Visible = $false
        return
    }
    $cpu = ($rows | Measure-Object Cpu -Sum).Sum
    $mem = ($rows | Measure-Object PrivateMB -Sum).Sum
    $PopupHead.Text = 'Firefox   CPU {0:N3}%   メモリ {1:N0} MB   {2} プロセス' -f $cpu, $mem, $rows.Count
    $PopupCols.Text = Format-PopupLine @($PopupColumns | ForEach-Object {
        $_.Title + $(if ($_.ListCol -ne $State.SortCol) { '' } elseif ($State.SortDesc) { '▼' } else { '▲' })
    })
    $PopupCols.Visible = $true
    $lines = foreach ($r in @(Get-SortedRows $rows | Select-Object -First $PopupTopN)) {
        Format-PopupLine @([string]$r.Id, $r.Type, ('{0:N3}' -f $r.Cpu), ('{0:N0}' -f $r.PrivateMB), (Get-TabCell $r))
    }
    $PopupBody.Text = @($lines) -join "`r`n"
    $PopupBody.Visible = $true
    $foot = @()
    if ($rows.Count -gt $PopupTopN) { $foot += 'ほか {0} プロセス' -f ($rows.Count - $PopupTopN) }
    if (-not $State.TabInfoOk) { $foot += $TabInfoMissingText }
    $PopupFoot.Text = $foot -join "`r`n"
    $PopupFoot.Visible = $foot.Count -gt 0
}

function Move-Popup {
    $Popup.PerformLayout()
    $anchor = $State.HoverAnchor
    $screen = [System.Windows.Forms.Screen]::FromPoint($anchor).Bounds
    $area = [System.Windows.Forms.Screen]::FromPoint($anchor).WorkingArea
    $w = $Popup.Width
    $h = $Popup.Height
    $gap = 8
    # アイコンを含む枠（タスクバー / 隠れたアイコンの領域）の外側に出す。取れなければカーソル周辺を避ける
    $avoid = $State.HoverRect
    if ($avoid.IsEmpty -or ($avoid.Width -gt $screen.Width * 0.9 -and $avoid.Height -gt $screen.Height * 0.9)) {
        $avoid = [System.Drawing.Rectangle]::new($anchor.X - 12, $anchor.Y - 12, 24, 24)
    }
    if ($avoid.Height -gt $avoid.Width) {
        # 縦置きのタスクバー: 左右に出す
        $y = [Math]::Min([Math]::Max($anchor.Y - $h / 2, $area.Top + 4), $area.Bottom - $h - 4)
        $x = if ($avoid.Right + $gap + $w -le $screen.Right) { $avoid.Right + $gap } else { $avoid.Left - $gap - $w }
    } else {
        $x = [Math]::Min([Math]::Max($anchor.X - $w / 2, $area.Left + 4), $area.Right - $w - 4)
        $y = if ($avoid.Top - $gap - $h -ge $area.Top) { $avoid.Top - $gap - $h } else { $avoid.Bottom + $gap }
    }
    $Popup.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
}

function Show-Popup {
    Update-Popup $State.Rows
    Move-Popup
    if (-not $Popup.Visible) { $Popup.Show() }
    $HoverTimer.Start()
}

# --- 一覧ウィンドウ ---
$Form = [System.Windows.Forms.Form]::new()
$Form.Text = 'Firefox プロセス'
$Form.Size = [System.Drawing.Size]::new(1030, 520)
$Form.StartPosition = 'Manual'
$Form.Font = $UiFont
$Summary = [System.Windows.Forms.Label]::new()
$Summary.Dock = 'Top'
$Summary.Height = 28
$Summary.TextAlign = 'MiddleLeft'
$Summary.Padding = [System.Windows.Forms.Padding]::new(6, 0, 0, 0)
$List = [System.Windows.Forms.ListView]::new()
$List.Dock = 'Fill'
$List.View = 'Details'
$List.FullRowSelect = $true
$List.GridLines = $true
foreach ($c in $ListColumns) { [void]$List.Columns.Add($c.Title, $c.Width, $c.Align) }
$List.Add_ColumnClick({
    param($s, $e)
    Set-Sort $e.Column
})
$Form.Controls.Add($List)
$Form.Controls.Add($Summary)
$Form.Add_FormClosing({
    param($s, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $e.Cancel = $true; $Form.Hide() }
})

# --- ホバー時のポップアップ ---
$Popup = [FxTray.Popup]::new()
$Popup.FormBorderStyle = 'None'
$Popup.ShowInTaskbar = $false
$Popup.StartPosition = 'Manual'
$Popup.AutoSize = $true
$Popup.AutoSizeMode = 'GrowAndShrink'
$Popup.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$Popup.ForeColor = [System.Drawing.Color]::White
$Popup.Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 8)
$PopupPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$PopupPanel.FlowDirection = 'TopDown'
$PopupPanel.WrapContents = $false
$PopupPanel.AutoSize = $true
$PopupPanel.AutoSizeMode = 'GrowAndShrink'
$PopupHead = [FxTray.SmoothLabel]::new()
$PopupHead.AutoSize = $true
$PopupHead.Font = [System.Drawing.Font]::new($UiFont, [System.Drawing.FontStyle]::Bold)
$PopupHead.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 6)
# 表は空白で列を揃えるため、日本語も含む等幅フォントを使う。見出し行はクリックで並べ替えるので別ラベルにする
$PopupCols = [FxTray.SmoothLabel]::new()
$PopupCols.AutoSize = $true
$PopupCols.Font = [System.Drawing.Font]::new('BIZ UDGothic', 10)
$PopupCols.Margin = [System.Windows.Forms.Padding]::new(3, 0, 3, 0)
$PopupCols.Cursor = [System.Windows.Forms.Cursors]::Hand
$PopupCols.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Set-Sort $PopupColumns[(Get-PopupColumnAt $e.X)].ListCol }
})
$PopupBody = [FxTray.SmoothLabel]::new()
$PopupBody.AutoSize = $true
$PopupBody.Font = $PopupCols.Font
$PopupBody.Margin = [System.Windows.Forms.Padding]::new(3, 0, 3, 0)
$PopupFoot = [FxTray.SmoothLabel]::new()
$PopupFoot.AutoSize = $true
$PopupFoot.Font = $UiFont
$PopupFoot.ForeColor = [System.Drawing.Color]::Silver
$PopupFoot.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
$PopupPanel.Controls.Add($PopupHead)
$PopupPanel.Controls.Add($PopupCols)
$PopupPanel.Controls.Add($PopupBody)
$PopupPanel.Controls.Add($PopupFoot)
$Popup.Controls.Add($PopupPanel)

# NotifyIcon にはマウスが離れたイベントがないため、カーソル位置を監視して閉じる
$HoverTimer = [System.Windows.Forms.Timer]::new()
$HoverTimer.Interval = 150
$HoverTimer.Add_Tick({
    $pos = [System.Windows.Forms.Cursor]::Position
    $tol = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $iconRect = [System.Drawing.Rectangle]::new($State.HoverAnchor.X - $tol, $State.HoverAnchor.Y - $tol, $tol * 2, $tol * 2)
    # アイコンからポップアップへ移動する途中で消えないよう、両者を囲む範囲にいる間は表示し続ける
    if (-not [System.Drawing.Rectangle]::Union($iconRect, $Popup.Bounds).Contains($pos)) {
        $Popup.Hide()
        $HoverTimer.Stop()
    }
})

# --- トレイアイコン ---
$Notify = [System.Windows.Forms.NotifyIcon]::new()
$Menu = [System.Windows.Forms.ContextMenuStrip]::new()
$MenuShow = $Menu.Items.Add('一覧を表示')
$MenuAlert = [System.Windows.Forms.ToolStripMenuItem]::new('高負荷時に通知')
$MenuAlert.CheckOnClick = $true
$MenuAlert.Checked = $true
[void]$Menu.Items.Add($MenuAlert)
[void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$MenuExit = $Menu.Items.Add('終了')
$Notify.ContextMenuStrip = $Menu

$MenuShow.Add_Click({ Show-List })
$MenuAlert.Add_CheckedChanged({ $State.AlertsOn = $MenuAlert.Checked })
$Notify.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-List }
})
$Notify.Add_BalloonTipClicked({ Show-List })
$Notify.Add_MouseMove({
    $State.HoverAnchor = [System.Windows.Forms.Cursor]::Position
    if (-not $Popup.Visible -and -not $Menu.Visible) {
        $State.HoverRect = [FxTray.Shell]::RootWindowRectAt($State.HoverAnchor.X, $State.HoverAnchor.Y)
        Show-Popup
    }
})
$Menu.Add_Opening({ $Popup.Hide(); $HoverTimer.Stop() })

$Timer = [System.Windows.Forms.Timer]::new()
$Timer.Interval = $IntervalSec * 1000
$Timer.Add_Tick({
    try {
        $rows = @(Get-FirefoxSample)
        $cpu = if ($rows.Count) { ($rows | Measure-Object Cpu -Sum).Sum } else { 0 }
        $State.Rows = $rows
        Update-Tray $rows $cpu
        Test-Alerts $rows $cpu
        if ($Form.Visible) { Update-List $rows }
        if ($Popup.Visible) { Update-Popup $rows; Move-Popup }
    } catch {
        Add-Content -Path $LogPath -Value ('{0:s} {1}' -f (Get-Date), $_) -Encoding UTF8
    }
})

$MenuExit.Add_Click({
    $Timer.Stop()
    $HoverTimer.Stop()
    $Notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

Set-TrayIcon 'off'
$Notify.Visible = $true
$Timer.Start()
[System.Windows.Forms.Application]::Run([System.Windows.Forms.ApplicationContext]::new())

$Notify.Dispose()
if ($State.IconHandle -ne [IntPtr]::Zero) { [void][FxTray.Native]::DestroyIcon($State.IconHandle) }
$Mutex.ReleaseMutex()
