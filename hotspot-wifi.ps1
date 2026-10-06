<#
  Mobile Hotspot (Wi-Fi) ON script
  ------------------------------------------------------------
  Turns ON the Windows Mobile Hotspot with "Share over" = Wi-Fi.
  Based on the hotspot part of setup-ntfy.ps1 (no firewall / ntfy).

  What this script does:
    - Waits for a network to share (Wi-Fi etc., up to 2 minutes)
    - Opens Settings > Network & internet > Mobile hotspot and, via UI
      Automation, selects "Share over: Wi-Fi" and turns the hotspot ON
      (if it is ON over Bluetooth, turns it OFF first to switch)
    - Disables "turn off when no devices are connected" power saving
    - Shows the hotspot's network name and password

  The WinRT API (StartTetheringAsync) could also start it over Wi-Fi, but
  the Settings page is used for consistency with setup-ntfy.ps1.

  Usage:
    .\hotspot-wifi.ps1
#>

# --- WinRT helpers (Mobile Hotspot API: state check / power saving / info) ---
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

# The hotspot needs a network to share (Wi-Fi etc.); without one the Settings
# page shows "...接続できないため、モバイル ホットスポットを設定できません"
function Test-NetworkForHotspot {
    return [bool][Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
}

function Wait-NetworkForHotspot([int]$timeoutSeconds = 120) {
    if (Test-NetworkForHotspot) { return $true }
    Write-Host "Wi-Fi などのネットワーク接続を待っています（最大 $timeoutSeconds 秒）..." -ForegroundColor Yellow
    for ($i = 0; $i -lt $timeoutSeconds; $i += 2) {
        Start-Sleep -Seconds 2
        if (Test-NetworkForHotspot) { return $true }
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

# Make sure the hotspot is ON and shared over Wi-Fi. Returns $true on success.
function Start-WifiHotspot {
    $toggleId = "SystemSettings_Connections_InternetSharingEnabled_ToggleSwitch"
    $shareOverId = "SystemSettings_Connections_InternetSharingOverPicker_ComboBox"
    $togglePattern = [System.Windows.Automation.TogglePattern]::Pattern

    # Keep the hotspot on even while no device is connected
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
    $isWifi = $selected -and $selected.Current.Name -eq "Wi-Fi"
    $isOn = $toggle.GetCurrentPattern($togglePattern).Current.ToggleState -eq "On"

    if ($isOn -and $isWifi) {
        Close-Settings
        return $true
    }

    # "Share over" can only be changed while the hotspot is off
    if ($isOn) {
        Write-Host "モバイルホットスポットが Wi-Fi 以外で共有されているため、切り替えます..." -ForegroundColor Yellow
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
    $isWifi = $selected -and $selected.Current.Name -eq "Wi-Fi"

    if (-not $isWifi) {
        $expand = $shareOver.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        Start-Sleep -Milliseconds 500
        $item = $shareOver.FindFirst($TS::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Wi-Fi")))
        if (-not $item) {
            try { $expand.Collapse() } catch {}
            Write-Host "「共有」の選択肢に Wi-Fi が見つかりませんでした（PCの Wi-Fi が OFF の可能性があります）。" -ForegroundColor Yellow
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
        Write-Host "モバイルホットスポットを Wi-Fi でONにしました。" -ForegroundColor Green
        Close-Settings
        return $true
    }
    Write-Host "モバイルホットスポットをONにできませんでした。" -ForegroundColor Yellow
    return $false
}

# The Settings page does not refresh by itself (e.g. after Wi-Fi reconnects),
# so reopen it and retry a few times
function Start-WifiHotspotWithRetry([int]$maxAttempts = 3) {
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "設定画面を開き直して再試行します（$attempt/$maxAttempts）..." -ForegroundColor Yellow
            Close-Settings
            Start-Sleep -Seconds 5
        }
        if (Start-WifiHotspot) { return $true }
    }
    return $false
}

# --- Mobile Hotspot (ON, shared over Wi-Fi) ---
if (-not (Wait-NetworkForHotspot)) {
    Write-Host "Wi-Fi などのネットワークに接続されていないため、モバイルホットスポットをONにできません。" -ForegroundColor Red
    Write-Host "ネットワークに接続してから、もう一度実行してください。" -ForegroundColor Red
    exit 1
}
if (-not (Start-WifiHotspotWithRetry)) {
    Write-Host "設定 > ネットワークとインターネット > モバイル ホットスポット で、共有を「Wi-Fi」にしてオンにしてから、もう一度実行してください。" -ForegroundColor Red
    exit 1
}
Write-Host "モバイルホットスポット（Wi-Fi）はONです。" -ForegroundColor Green

# Show the network name and password to connect other devices
try {
    $config = $TetheringManager::CreateFromConnectionProfile(
        [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()).GetCurrentAccessPointConfiguration()
    Write-Host ""
    Write-Host "  ネットワーク名: $($config.Ssid)" -ForegroundColor White
    Write-Host "  パスワード    : $($config.Passphrase)" -ForegroundColor White
} catch {}
