<#
  ntfy setup script (Windows / PC's Mobile Hotspot over Bluetooth)
  ------------------------------------------------------------
  The PC shares a network over Bluetooth (Windows Mobile Hotspot) and the
  phone joins it. The PC's address on that network is fixed (192.168.138.1),
  so the phone's ntfy app only has to be configured once.

  Manual steps to do first (one-time):
    1. PC: Settings > Network & internet > Mobile hotspot >
       "Share over" = Bluetooth
    2. Pair PC and phone via Bluetooth *while the hotspot is ON*
       (otherwise the phone does not offer "Internet access" for the PC)
    3. Phone ntfy app: server URL http://192.168.138.1:8080, subscribe to the topic

  Manual step on the phone each time the hotspot starts:
    - Bluetooth > "SES" > gear icon > turn ON "インターネット アクセス"

  What this script does:
    - Checks for administrator privileges
    - Turns ON the Mobile Hotspot shared over Bluetooth, by operating the
      Settings page (UI Automation); the WinRT API can only start it over
      Wi-Fi. Also disables its "turn off when no devices are connected"
      power saving.
    - Adds a firewall rule allowing inbound TCP on the given port (if missing)
    - Saves the server IP to ntfy_ip.txt (read by notify.ps1)
    - Starts the ntfy server in the background
    - Waits for the phone to connect, then sends a "setup complete"
      notification via notify.ps1
    - Keeps running: turns the hotspot back ON if it goes off
      (Ctrl+C or closing the window stops the server)

  Usage (run PowerShell "as Administrator"):
    .\setup-ntfy.ps1
    .\setup-ntfy.ps1 -NtfyPath "C:\ntfy\ntfy.exe" -Port 8080 -Topic "mytopic"
#>

param(
    [string]$NtfyPath = "ntfy.exe",       # Use full path if ntfy.exe is not on PATH
    [int]$Port = 8080,
    [string]$Topic = "shokuba",
    [string]$ServerIp = "192.168.138.1"   # PC's address on the Bluetooth hotspot network
)

# --- Check administrator privileges ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "管理者権限が必要です。PowerShellを「管理者として実行」で開き直してください。" -ForegroundColor Red
    exit 1
}

# --- WinRT helpers (Mobile Hotspot API: state check / power saving only) ---
# Note: StartTetheringAsync() always shares over Wi-Fi, ignoring the
# "Share over: Bluetooth" choice, so the hotspot is turned on via the
# Settings page (UI Automation) instead.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
$null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
$TetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]

$asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq "IAsyncAction"
} | Select-Object -First 1

function Wait-AsyncAction($action) {
    $task = $asTaskAction.Invoke($null, @($action))
    $task.Wait(-1) | Out-Null
}

# The operational state is global, so any connection profile will do
function Test-HotspotOn {
    foreach ($p in [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()) {
        try {
            if ($TetheringManager::CreateFromConnectionProfile($p).TetheringOperationalState -eq "On") { return $true }
        } catch {}
    }
    return $false
}

# --- UI Automation helpers (Settings > Network & internet > Mobile hotspot) ---
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function Find-SettingsElement([string]$automationId) {
    $settings = $AE::RootElement.FindFirst($TS::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "設定")))
    if (-not $settings) { return $null }
    return $settings.FindFirst($TS::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $automationId)))
}

function Close-Settings {
    $settings = $AE::RootElement.FindFirst($TS::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "設定")))
    if ($settings) {
        try { $settings.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch {}
    }
}

# Make sure the hotspot is ON and shared over Bluetooth. Returns $true on success.
function Start-BluetoothHotspot {
    $toggleId = "SystemSettings_Connections_InternetSharingEnabled_ToggleSwitch"
    $shareOverId = "SystemSettings_Connections_InternetSharingOverPicker_ComboBox"
    $togglePattern = [System.Windows.Automation.TogglePattern]::Pattern

    # Keep the hotspot on even while the phone is not connected
    try {
        if ($TetheringManager::IsNoConnectionsTimeoutEnabled()) {
            Wait-AsyncAction ($TetheringManager::DisableNoConnectionsTimeoutAsync())
        }
    } catch {}

    Start-Process "ms-settings:network-mobilehotspot"
    $toggle = $null
    for ($i = 0; $i -lt 15 -and -not $toggle; $i++) {
        Start-Sleep -Seconds 1
        $toggle = Find-SettingsElement $toggleId
    }
    if (-not $toggle) {
        Write-Host "モバイル ホットスポットの設定画面を開けませんでした。" -ForegroundColor Yellow
        return $false
    }

    $shareOver = Find-SettingsElement $shareOverId
    $selected = $null
    if ($shareOver) {
        $selected = $shareOver.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() |
            Select-Object -First 1
    }
    $isBluetooth = $selected -and $selected.Current.Name -eq "Bluetooth"
    $isOn = $toggle.GetCurrentPattern($togglePattern).Current.ToggleState -eq "On"

    # 192.168.137.1 on a non-Bluetooth adapter means it is actually shared over Wi-Fi
    $wifiShared = Get-NetIPAddress -AddressFamily IPv4 -IPAddress "192.168.137.1" -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch "Bluetooth" }

    if ($isOn -and $isBluetooth -and -not $wifiShared) {
        Close-Settings
        return $true
    }

    # "Share over" can only be changed while the hotspot is off
    if ($isOn) {
        Write-Host "モバイルホットスポットが Bluetooth 以外で共有されているため、切り替えます..." -ForegroundColor Yellow
        $toggle.GetCurrentPattern($togglePattern).Toggle()
        for ($i = 0; $i -lt 10 -and (Test-HotspotOn); $i++) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 1
    }

    # The picker is disabled for a moment after turning the hotspot off
    $shareOver = $null
    for ($i = 0; $i -lt 10; $i++) {
        $shareOver = Find-SettingsElement $shareOverId
        if ($shareOver -and $shareOver.Current.IsEnabled) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $shareOver -or -not $shareOver.Current.IsEnabled) {
        Write-Host "「共有」の選択欄を操作できませんでした。" -ForegroundColor Yellow
        return $false
    }
    $selected = $shareOver.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() |
        Select-Object -First 1
    $isBluetooth = $selected -and $selected.Current.Name -eq "Bluetooth"

    if (-not $isBluetooth) {
        $expand = $shareOver.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        Start-Sleep -Milliseconds 500
        $item = $shareOver.FindFirst($TS::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Bluetooth")))
        if (-not $item) {
            try { $expand.Collapse() } catch {}
            Write-Host "「共有」の選択肢に Bluetooth が見つかりませんでした。" -ForegroundColor Yellow
            return $false
        }
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        try { $expand.Collapse() } catch {}
        Start-Sleep -Seconds 1
    }

    $toggle = Find-SettingsElement $toggleId
    if (-not $toggle.Current.IsEnabled) {
        Write-Host "モバイル ホットスポットのスイッチが無効になっています（共有できる接続がない可能性があります）。" -ForegroundColor Yellow
        return $false
    }
    $toggle.GetCurrentPattern($togglePattern).Toggle()
    for ($i = 0; $i -lt 15 -and -not (Test-HotspotOn); $i++) { Start-Sleep -Seconds 1 }

    if (Test-HotspotOn) {
        Write-Host "モバイルホットスポットを Bluetooth でONにしました。" -ForegroundColor Green
        Close-Settings
        return $true
    }
    Write-Host "モバイルホットスポットをONにできませんでした。" -ForegroundColor Yellow
    return $false
}

# PC's IPv4 address on the Bluetooth network (only present while the phone is connected)
function Get-BluetoothIp {
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Bluetooth" -and $_.Status -eq "Up" }
    if (-not $adapter) { return $null }
    return ($adapter | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}

# --- Mobile Hotspot (ON, shared over Bluetooth) ---
if (-not (Start-BluetoothHotspot)) {
    Write-Host "設定 > ネットワークとインターネット > モバイル ホットスポット で、共有を「Bluetooth」にしてオンにしてから、もう一度実行してください。" -ForegroundColor Red
    exit 1
}
Write-Host "モバイルホットスポット（Bluetooth）はONです。" -ForegroundColor Green

Write-Host ""
Write-Host "ここまで完了しました（モバイルホットスポットを Bluetooth でON）。" -ForegroundColor Cyan
Read-Host "Enterキーを押すと次の処理（ファイアウォール設定・ntfyサーバー起動）に進みます" | Out-Null

# --- Firewall rule (add if missing) ---
$ruleName = "ntfy $Port"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    Write-Host "ファイアウォール規則を追加しました: $ruleName" -ForegroundColor Green
} else {
    Write-Host "ファイアウォール規則は既に存在します: $ruleName" -ForegroundColor Yellow
}

# Save IP so notify.ps1 can read it
$ServerIp | Out-File -FilePath "$PSScriptRoot\ntfy_ip.txt" -Encoding ascii -NoNewline

# --- Start ntfy server (background, so this script can continue) ---
# Reuse an ntfy server that is already listening (e.g. started by hand or by an earlier run)
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$ntfyProcess = $null
if ($listener) {
    $existing = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($existing -and $existing.ProcessName -eq "ntfy") {
        Write-Host "ntfyサーバーは既に起動しています（PID $($existing.Id)）。これを使って続行します。" -ForegroundColor Yellow
        $ntfyProcess = $existing
    } else {
        Write-Host "ポート $Port は別のプログラム（$($existing.ProcessName), PID $($listener.OwningProcess)）が使用中です。" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "ntfyサーバーを起動します..." -ForegroundColor Green
    $ntfyProcess = Start-Process -FilePath $NtfyPath -ArgumentList @("serve", "--listen-http", ":$Port") -NoNewWindow -PassThru

    Start-Sleep -Seconds 2
    if ($ntfyProcess.HasExited) {
        Write-Host "ntfyサーバーの起動に失敗しました。" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " スマホのntfyアプリのサーバーURL（初回のみ設定）:" -ForegroundColor Cyan
Write-Host "   http://${ServerIp}:$Port" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Wait for the phone, then send "setup complete" ---
$notifyScript = Join-Path $PSScriptRoot "notify.ps1"
$phoneConnected = $false
$reminded = $false

Write-Host "ntfyサーバーが稼働中です（終了するには Ctrl+C。ウィンドウを閉じるとサーバーも止まります）..." -ForegroundColor Green

while (-not $ntfyProcess.HasExited) {
    $btIp = Get-BluetoothIp

    if ($btIp -and -not $phoneConnected) {
        $phoneConnected = $true
        $reminded = $false
        if ($btIp -ne $ServerIp) {
            Write-Host "注意: PCのBluetooth側のIPが想定（$ServerIp）と異なります: $btIp" -ForegroundColor Yellow
            Write-Host "スマホのntfyアプリのサーバーURLを http://${btIp}:$Port に変更してください。" -ForegroundColor Yellow
            $btIp | Out-File -FilePath "$PSScriptRoot\ntfy_ip.txt" -Encoding ascii -NoNewline
        }
        Write-Host "スマホが接続しました。" -ForegroundColor Green
        if (Test-Path $notifyScript) {
            & $notifyScript -Message "設定完了" -Topic $Topic -Port $Port
        }
    } elseif (-not $btIp) {
        if ($phoneConnected) {
            Write-Host "スマホとの接続が切れました。" -ForegroundColor Yellow
            $phoneConnected = $false
        }
        if (-not $reminded) {
            Write-Host "スマホで Bluetooth >「$env:COMPUTERNAME」の設定 >「インターネット アクセス」をONにしてください。接続を待っています..." -ForegroundColor Yellow
            $reminded = $true
        }
    }

    # The hotspot can go off (e.g. Wi-Fi reconnect); turn it back on
    if (-not (Test-HotspotOn)) {
        Write-Host "モバイルホットスポットがOFFになっていたため、ONにし直します..." -ForegroundColor Yellow
        Start-BluetoothHotspot | Out-Null
    }

    Start-Sleep -Seconds 10
}

Write-Host "ntfyサーバーが終了しました。" -ForegroundColor Red
