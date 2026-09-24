<#
  ntfy setup script (Windows / via Bluetooth PAN)
  ------------------------------------------------------------
  Manual steps to do first (one-time):
    1. Pair PC and phone via Bluetooth
    2. Turn ON Bluetooth tethering on the phone

  What this script does:
    - Checks for administrator privileges
    - Detects whether the phone is already connected via Bluetooth PAN
      -> if detected: proceeds automatically
      -> if not detected: opens Settings > Bluetooth & devices > Devices and
         presses PAN "参加する" and then "接続" automatically (UI Automation)
      -> if that also fails: asks the user (Y/N) whether it is connected
    - Adds a firewall rule allowing inbound TCP on the given port (if missing)
    - Saves the detected IP to ntfy_ip.txt (read by notify.ps1)
    - Starts the ntfy server in the background
    - Sends a "setup complete" notification via notify.ps1
    - Waits (Ctrl+C to stop the server)

  Usage (run PowerShell "as Administrator"):
    .\setup-ntfy.ps1
    .\setup-ntfy.ps1 -NtfyPath "C:\ntfy\ntfy.exe" -Port 8080 -Topic "mytopic"

  Note: this script uses Read-Host to ask Y/N when auto-detection fails.
  If you run it via Task Scheduler with a hidden window, it cannot be
  answered and will appear to hang. Run it visibly (not hidden) if you
  plan to automate it at logon.
#>

param(
    [string]$NtfyPath = "ntfy.exe",   # Use full path if ntfy.exe is not on PATH
    [int]$Port = 8080,
    [string]$Topic = "shokuba"
)

# --- Check administrator privileges ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "管理者権限が必要です。PowerShellを「管理者として実行」で開き直してください。" -ForegroundColor Red
    exit 1
}

function Get-BluetoothPanInfo {
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Bluetooth" -and $_.Status -eq "Up" }
    if (-not $adapter) { return $null }
    # Ignore APIPA (169.254.x.x): it means DHCP from the phone failed and is unreachable
    $ip = ($adapter | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
    if (-not $ip) { return $null }
    return [PSCustomObject]@{ Adapter = $adapter; IP = $ip }
}

# Open Settings > Bluetooth & devices > Devices and press the PAN "参加する" (Join)
# button, then "接続" (Connect) in the confirmation dialog, via UI Automation.
# Returns the PAN info on success, $null otherwise.
function Connect-BluetoothPan {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]
    $findSettings = {
        $AE::RootElement.FindFirst($TS::Children,
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "設定")))
    }
    $findButton = {
        param($root, $property, $value)
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
            (New-Object System.Windows.Automation.PropertyCondition($property, $value)))
        $root.FindFirst($TS::Descendants, $cond)
    }

    Start-Process "ms-settings:connecteddevices"

    # Wait for the "参加する" button; expand collapsed device entries if it is hidden
    $joinBtn = $null
    for ($i = 0; $i -lt 15 -and -not $joinBtn; $i++) {
        Start-Sleep -Seconds 1
        $settings = & $findSettings
        if (-not $settings) { continue }
        $joinBtn = & $findButton $settings $AE::NameProperty "参加する"
        if (-not $joinBtn) {
            $expanders = $settings.FindAll($TS::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, "EntityItemButton")))
            foreach ($ex in $expanders) {
                # Some devices (e.g. USB drives) have no expander pattern
                $pattern = $null
                if ($ex.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern) -and
                    $pattern.Current.ExpandCollapseState -eq "Collapsed") { $pattern.Expand() }
            }
        }
    }
    if (-not $joinBtn) {
        Write-Host "設定画面に「参加する」ボタンが見つかりませんでした。" -ForegroundColor Yellow
        return $null
    }
    $joinBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    # Confirmation dialog: primary button "接続"
    $connectBtn = $null
    for ($i = 0; $i -lt 10 -and -not $connectBtn; $i++) {
        Start-Sleep -Seconds 1
        $connectBtn = & $findButton (& $findSettings) $AE::AutomationIdProperty "PrimaryButton"
    }
    if (-not $connectBtn) {
        Write-Host "確認ダイアログの「接続」ボタンが見つかりませんでした。" -ForegroundColor Yellow
        return $null
    }
    $connectBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    # Wait for the adapter to come up and get an IP from the phone
    $info = $null
    for ($i = 0; $i -lt 20 -and -not $info; $i++) {
        Start-Sleep -Seconds 1
        $info = Get-BluetoothPanInfo
    }

    if ($info) {
        # Close the Settings window we opened
        $settings = & $findSettings
        if ($settings) {
            try { $settings.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch {}
        }
    }
    return $info
}

# --- Bluetooth PAN connection check ---
$btInfo = Get-BluetoothPanInfo

if (-not $btInfo) {
    Write-Host "Bluetooth PAN未接続のため、自動で接続を試みます..." -ForegroundColor Yellow
    try {
        $btInfo = Connect-BluetoothPan
    } catch {
        Write-Host "自動接続中にエラーが発生しました: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($btInfo) {
    Write-Host "Bluetooth PAN接続を検出しました（アダプタ: $($btInfo.Adapter.Name)）。自動で続行します。" -ForegroundColor Green
} else {
    Write-Host "Bluetooth PAN接続を自動検出できませんでした。" -ForegroundColor Yellow

    do {
        $answer = Read-Host "Bluetooth PANでスマホと接続済みですか？ (Y/N)"
    } while ($answer -notmatch '^[YyNn]$')

    if ($answer -match '^[Nn]$') {
        Write-Host "先にBluetoothペアリング、テザリングON、アクセスポイントとしての接続を行ってから、もう一度実行してください。" -ForegroundColor Red
        exit 1
    }

    Write-Host "再確認しています..." -ForegroundColor Yellow
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Seconds 2
        $btInfo = Get-BluetoothPanInfo
        if ($btInfo) { break }
    }

    if (-not $btInfo) {
        $btAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Bluetooth" }
        if (-not $btAdapter) {
            Write-Host "Bluetoothネットワークアダプタが見つかりませんでした。" -ForegroundColor Red
        } elseif ($btAdapter.Status -ne "Up") {
            Write-Host "Bluetoothネットワークアダプタ（$($btAdapter.Name)）は存在しますが、状態が「$($btAdapter.Status)」です。" -ForegroundColor Red
            Write-Host "スマホのBluetoothテザリングをONにし、デバイスとプリンターでスマホを右クリック >「接続方法」>「アクセスポイント」を実行してください。" -ForegroundColor Red
        } else {
            Write-Host "Bluetoothネットワークアダプタは接続中ですが、有効なIPアドレスを取得できていません（169.254.x.x）。" -ForegroundColor Red
            Write-Host "スマホのBluetoothテザリングがONになっているか確認してください。" -ForegroundColor Red
        }
        Write-Host "コントロールパネル > デバイスとプリンター で接続状態を確認してから、もう一度実行してください。" -ForegroundColor Red
        exit 1
    }

    Write-Host "Bluetooth PAN接続を検出しました（アダプタ: $($btInfo.Adapter.Name)）。" -ForegroundColor Green
}

$btIp = $btInfo.IP

# --- Firewall rule (add if missing) ---
$ruleName = "ntfy $Port"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    Write-Host "ファイアウォール規則を追加しました: $ruleName" -ForegroundColor Green
} else {
    Write-Host "ファイアウォール規則は既に存在します: $ruleName" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " スマホのntfyアプリで、このサーバーを指定してください（初回のみ）:" -ForegroundColor Cyan
Write-Host "   http://${btIp}:$Port" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Save IP so notify.ps1 can read it
$btIp | Out-File -FilePath "$PSScriptRoot\ntfy_ip.txt" -Encoding ascii -NoNewline

# --- Start ntfy server (background, so this script can continue) ---
Write-Host "ntfyサーバーを起動します..." -ForegroundColor Green
$ntfyProcess = Start-Process -FilePath $NtfyPath -ArgumentList @("serve", "--listen-http", ":$Port") -NoNewWindow -PassThru

# Give the server a moment to bind the port before sending a test notification
Start-Sleep -Seconds 2

if ($ntfyProcess.HasExited) {
    Write-Host "ntfyサーバーの起動に失敗しました（ポート $Port が既に使用中の可能性があります）。" -ForegroundColor Red
    exit 1
}

# --- Send "setup complete" notification ---
$notifyScript = Join-Path $PSScriptRoot "notify.ps1"
if (Test-Path $notifyScript) {
    Write-Host "設定完了の通知を送信します..." -ForegroundColor Green
    & $notifyScript -Message "設定完了" -Topic $Topic -Port $Port
} else {
    Write-Host "notify.ps1 が見つからないため、完了通知は送信できませんでした。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "ntfyサーバーが稼働中です（終了するには Ctrl+C）..." -ForegroundColor Green
Wait-Process -Id $ntfyProcess.Id