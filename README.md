# 山間部（電波・Wi-Fiなし）でPC→スマホに通知を送る手順

PCの「モバイルホットスポット」をBluetoothで共有し、スマホがそこに参加することで
PCとスマホの間にネットワークを作ります。PC上のntfyサーバーに向けて
curlで通知を送る仕組みです。

PCがアドレスを割り振る側になるため、PCのアドレスは常に **`192.168.138.1`** で固定されます
（スマホ側のアドレスは接続のたびに変わりますが、使わないので問題ありません）。
そのため、スマホのntfyアプリの設定は1回で済みます。

## 前提

- PC: Windows 11（モバイルホットスポットが使えること）
- スマホ: Android
- Wi-Fiやインターネットがない状態でホットスポットをONにできるかは未確認（出発前に要テスト）

## 初回だけ行う手順

1. **PC: モバイルホットスポットの共有方法を「Bluetooth」にする**
   設定 → ネットワークとインターネット → モバイル ホットスポット →
   「共有方法」を **Bluetooth** にし、ホットスポットを **オン** にする

2. **PCとスマホをBluetoothでペアリングする（ホットスポットがONの状態で）**
   ホットスポットがOFFのときにペアリングすると、スマホ側に「インターネット アクセス」の
   項目が出ません。その場合は両方でペアリングを解除し、ホットスポットをONにしてから
   ペアリングし直してください。

3. **スマホのntfyアプリで、サーバー `http://192.168.138.1:8080` を指定してトピックを購読する**

## 毎回行う手順

1. PCで `setup-ntfy.ps1` を実行する（管理者として。タスクスケジューラで自動起動も可）
2. **スマホ**: 設定 → Bluetooth → PC名（例: SES）の ⚙ → **「インターネット アクセス」をON**
   （ホットスポットが起動し直すと切れるので、そのたびにONにする）

## スクリプト

### `setup-ntfy.ps1`（PCの準備・ntfy起動）

「管理者として実行」した PowerShell で実行します。

```powershell
.\setup-ntfy.ps1
```

このスクリプトが行うこと:
- PCのBluetoothがOFFならONにする
- 設定画面を自動操作して、モバイルホットスポットを「共有: Bluetooth」でONにする
  - 「共有」の選択肢に Bluetooth が出ないときは、Bluetoothを1回 OFF→ON してから再試行する
    （その間、Bluetoothのマウス・キーボード等も一時的に切れる）。それでもだめなら再起動を案内する
  （Wi-Fiで共有されていたらBluetoothに切り替える。スマホ未接続でも自動でOFFにならないよう省電力も無効化）
  - APIからONにすると必ずWi-Fiでの共有になってしまうため、設定画面を操作している
  - 設定画面の表示名・構成が変わる（Windowsの更新や表示言語の変更）と動かなくなる可能性がある
- ファイアウォールで8080番ポートの受信を許可（未登録なら追加）
- サーバーのIP（192.168.138.1）を `ntfy_ip.txt` に保存（`notify.ps1` が読み取る）
- ntfyサーバーを起動
- スマホの接続を待ち、つながったら「設定完了」を通知
- 動いている間、ホットスポットがOFFになったら自動でONにし直す
- `Ctrl+C` またはウィンドウを閉じると終了（サーバーも止まる）

`ntfy.exe` にPATHが通っていない場合:
```powershell
.\setup-ntfy.ps1 -NtfyPath "C:\ntfy\ntfy.exe"
```

### `hotspot-wifi.ps1`（モバイルホットスポットを Wi-Fi でONにするだけ）

ntfyとは関係なく、モバイルホットスポットを「共有: Wi-Fi」でONにするだけのスクリプトです
（ファイアウォール設定・ntfyサーバー起動はしません。管理者権限も不要）。

```powershell
.\hotspot-wifi.ps1
```

- ネットワーク（Wi-Fi等）がつながるまで最大2分待つ
- 設定画面を自動操作して「共有: Wi-Fi」でONにする（Bluetoothで共有中なら切り替える）
- ONにした後、ホットスポットのネットワーク名とパスワードを表示する
- 実行すると Bluetooth での共有は止まるので、ntfy用に戻すときは `setup-ntfy.ps1` を実行する

### `notify.ps1`（通知送信）

`setup-ntfy.ps1` でサーバーを起動した状態で、別のPowerShellから実行します。

```powershell
.\notify.ps1 -Message "ビルド完了"
```

トピック名やポートを変える場合:
```powershell
.\notify.ps1 -Message "ビルド完了" -Topic "mytopic" -Port 8080
```

## ログオン時に自動起動する（タスクスケジューラ）

`setup-ntfy.ps1` をタスク「ntfy-autostart」としてタスクスケジューラに登録し、ログオン時に自動で実行します。
コマンドはすべて **管理者として開いた PowerShell** で実行します。

### 新しく登録する

```powershell
$scriptPath = "C:\Users\kenic\Dropbox\gitdir\setup-ntfy\setup-ntfy.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "ntfy-autostart" -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

設定の意味:
- `-NoExit`: エラーで止まってもウィンドウを残す（`-WindowStyle Hidden` は付けない＝ウィンドウを表示する）
- `-LogonType Interactive`: ログオン中のユーザーとして実行する（設定画面の自動操作に必要）
- `-RunLevel Highest`: 管理者権限で実行する（ファイアウォール設定に必要）
- `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`: バッテリー駆動中でも開始・継続する
- `-ExecutionTimeLimit ([TimeSpan]::Zero)`: 実行時間の上限（既定72時間）をなくす

### 登録済みのタスクの設定を変える

① 実行中のタスクを止める（入力待ちで止まっている場合など）:
```powershell
Stop-ScheduledTask -TaskName "ntfy-autostart"
```

② 設定を変える（ウィンドウを表示、エラー時もウィンドウを残す、バッテリー駆動中でも動かす、時間制限なし）:
```powershell
$scriptPath = "C:\Users\kenic\Dropbox\gitdir\setup-ntfy\setup-ntfy.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -File `"$scriptPath`""
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Set-ScheduledTask -TaskName "ntfy-autostart" -Action $action -Settings $settings
```

③ すぐに試す（ログオンし直さなくても実行できる）:
```powershell
Start-ScheduledTask -TaskName "ntfy-autostart"
```

### 確認・削除

```powershell
# 登録内容を確認する
(Get-ScheduledTask -TaskName "ntfy-autostart").Actions.Arguments
(Get-ScheduledTask -TaskName "ntfy-autostart").Settings | Format-List DisallowStartIfOnBatteries, StopIfGoingOnBatteries, ExecutionTimeLimit

# 削除する
Unregister-ScheduledTask -TaskName "ntfy-autostart" -Confirm:$false
```

注意:
- `setup-ntfy.ps1` はホットスポットをONにした後、**Enterキーを押すまで止まります**。
  自動起動したときも、表示されたウィンドウでEnterを押すとntfyサーバーが起動します。
- ウィンドウを閉じるとntfyサーバーも止まるので、邪魔なときは最小化してください。

## 注意点

- **出発前に必ず一度、Wi-Fiを切った状態で一連の流れを通しでテストする**
  （現地ではアプリのインストールやダウンロードができないため）
- スマホ側は、ntfyアプリをバッテリー最適化の対象外にしておくと、
  画面オフ時も通知を受信しやすい
- 職場のWi-Fiにつながっている場所では、スマホがPC経由で職場のネットワークにつながる形になるので、
  規程上問題がないか確認しておく
