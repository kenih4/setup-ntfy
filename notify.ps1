<#
  ntfy notify script
  ------------------------------------------------------------
  Run setup-ntfy.ps1 first and keep the ntfy server running.

  Usage:
    .\notify.ps1 -Message "Build finished"
    .\notify.ps1 -Message "Build finished" -Topic "shokuba" -Port 8080
#>

param(
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$Topic = "shokuba",
    [int]$Port = 8080
)

$ipFile = "$PSScriptRoot\ntfy_ip.txt"

if (Test-Path $ipFile) {
    $ip = (Get-Content $ipFile -Raw).Trim()
} else {
    # Fallback: detect the Bluetooth adapter's IP on the spot
    $btAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Bluetooth" -and $_.Status -eq "Up" }
    $ip = ($btAdapter | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
}

if (-not $ip) {
    Write-Host "Could not find the PC's (Bluetooth PAN) IP address. Run setup-ntfy.ps1 first." -ForegroundColor Red
    exit 1
}

$url = "http://${ip}:$Port/$Topic"
# Send the body as UTF-8 bytes via a temp file (passing $Message as an argument
# gets it converted to the ANSI code page, which ntfy rejects as an "attachment").
$tmp = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllBytes($tmp, [System.Text.Encoding]::UTF8.GetBytes($Message))
    curl.exe -sS -f --data-binary "@$tmp" $url
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to send -> $url (is the ntfy server running? Start setup-ntfy.ps1 and keep its window open.)" -ForegroundColor Red
    exit 1
}

Write-Host "Sent -> $url" -ForegroundColor Green
