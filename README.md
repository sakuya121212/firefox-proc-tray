# FirefoxProcTray

Firefox のプロセスごとの CPU・メモリ使用量と、そのプロセスに載っているタブ名をタスクトレイで確認できる Windows 用ツールです。about:processes を開かなくても、どのタブが重いかをすぐに確認できます。

- トレイアイコンに Firefox 全体の CPU 使用率（%）を表示（緑 → オレンジ → 赤）
- アイコンにマウスを乗せると、CPU 使用率の高い順に上位 10 プロセスとタブ名をポップアップ表示
- 左クリックで全プロセスの一覧ウィンドウを表示
- CPU 高負荷が続いたとき、または 1 プロセスのメモリが大きくなったときに通知

## 動作環境

- Windows 10 / 11
- Windows PowerShell 5.1（Windows に標準搭載）
- Firefox（158.0.1 で動作確認）

追加でインストールするソフトウェアはありません。

## インストール

1. このリポジトリを clone するか、ZIP でダウンロードして任意の場所に展開します。インストール後はこのフォルダーから実行されるので、消さない場所に置いてください。
2. `install.cmd` をダブルクリックします。
   - Firefox のインストール先に autoconfig ファイルを配置するため、UAC の確認が出ます。
   - スタートアップに登録され、トレイアプリが起動します。
3. Firefox を完全に終了してから起動し直します（タブ名の表示に必要です）。

オプションを付けて実行する場合は、PowerShell から `install.ps1` を直接実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 [-FirefoxDir <dir>] [-SkipAutoconfig] [-SkipStartup]
```

| オプション | 内容 |
|---|---|
| `-FirefoxDir` | Firefox のインストール先を指定する（既定はレジストリから自動検出） |
| `-SkipAutoconfig` | autoconfig を配置しない。管理者権限は不要になるが、タブ名は表示されない |
| `-SkipStartup` | スタートアップに登録しない |

## 使い方

| 操作 | 動作 |
|---|---|
| アイコンにマウスを乗せる | 上位 10 プロセス（PID・種類・CPU%・専用メモリ・タブ名）をポップアップ表示 |
| 左クリック | 全プロセスの一覧ウィンドウを表示 |
| 右クリック | 一覧の表示、通知の ON/OFF、終了 |

「専用メモリ」はプロセスが専有しているメモリ（Private Bytes）で、タスクマネージャーの「コミット サイズ」に相当します。about:processes とは計算方法が異なるため、数値は一致しないことがあります。

通知のしきい値などは `FirefoxProcTray.ps1` 冒頭の変数で変更できます。

| 変数 | 既定値 | 内容 |
|---|---|---|
| `$IntervalSec` | 2 | 更新間隔（秒） |
| `$CpuAlertPercent` / `$CpuAlertSamples` | 50 / 5 | Firefox 全体の CPU 使用率がこの値以上の状態が、この回数続いたら通知する |
| `$ProcMemAlertMB` | 2048 | 1 プロセスの専用メモリがこの値以上になったら通知する |
| `$AlertCooldownSec` | 300 | 同じ内容の通知を繰り返さない間隔（秒） |
| `$PopupTopN` | 10 | ポップアップに表示するプロセス数 |

## 仕組み

- CPU・メモリは Windows 側から `firefox.exe` の各プロセスを監視して取得します。
- タブ名は Windows 側からは取得できないため、Firefox の [autoconfig](https://support.mozilla.org/kb/customizing-firefox-using-autoconfig) を使います。`firefox-autoconfig/mozilla.cfg` が Firefox 内で 2 秒ごとに `ChromeUtils.requestProcInfo()`（about:processes と同じ内部 API）を呼び、PID とタブ名の対応を `%LOCALAPPDATA%\FirefoxProcTray\procinfo.json` に書き出します。トレイアプリはこのファイルを読みます。
- `procinfo.json` が無い、または 10 秒以上更新されていない場合、タブ名は表示されず、プロセス単位の表示になります。

## 注意事項

- **特権スクリプト**: `mozilla.cfg` は Firefox 内でフル権限で動作します。処理内容はタブ名を読み取ってファイルに書き出すだけですが、導入前に内容を確認してください。
- **Firefox の更新**: 内部 API を使っているため、Firefox の更新で動かなくなる可能性があります。その場合はポップアップに「タブ名を取得できていません」と表示されます。
- **タブ名の保存**: タブ名がローカルの `procinfo.json` に書き出されます。URL は書き出しません。プライベートウィンドウのタブは `(private)` と記録します。
- **既存の autoconfig**: 既に別の autoconfig（`mozilla.cfg` など）が配置されている場合、インストーラーは上書きせずに停止します。
- **読み込まれていないタブ**: 起動直後などで未読み込みのタブにはプロセスが割り当てられないため、一覧には表示されません。

## アンインストール

`uninstall.cmd` をダブルクリックします。トレイアプリの終了、スタートアップ登録と autoconfig の削除、`%LOCALAPPDATA%\FirefoxProcTray` の削除を行います。autoconfig の削除には UAC の確認が出ます。最後に Firefox を再起動してください。

## ライセンス

[MIT License](LICENSE)
