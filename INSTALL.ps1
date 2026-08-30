param()

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

$PackageDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadDir = Join-Path $PackageDir "payload"
$InstallDir = Join-Path $env:LOCALAPPDATA "PCPowerWidget"
$LibDir = Join-Path $InstallDir "lib"

Write-Host ""
Write-Host "PC POWER WIDGET - INSTALL" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Installs to: $InstallDir"
Write-Host ""

# Simple user settings.
$rateInput = Read-Host "Electricity price in p/kWh [26.11]"
$rate = 26.11
if (-not [string]::IsNullOrWhiteSpace($rateInput)) {
    $tmpRate = 0.0
    if ([double]::TryParse($rateInput, [ref]$tmpRate) -and $tmpRate -gt 0) {
        $rate = $tmpRate
    }
}

$town = Read-Host "Town/city for outside temperature [press Enter to disable weather]"

$psuInput = Read-Host "PSU watts if known, e.g. 650/750/850 [Enter = 1000 safe ceiling]"
$psuW = 1000.0
if (-not [string]::IsNullOrWhiteSpace($psuInput)) {
    $tmpPsu = 0.0
    if ([double]::TryParse($psuInput, [ref]$tmpPsu) -and $tmpPsu -ge 300) {
        $psuW = $tmpPsu
    }
}

Write-Host ""
Write-Host "[1/6] Installing widget files..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

Copy-Item -Path (Join-Path $PayloadDir "*") -Destination $InstallDir -Recurse -Force

# Bootstrap source packages may contain RAMUsageWidget.ps1 split into numbered parts.
# Normal release packages contain the assembled RAMUsageWidget.ps1 already.
$mainScript = Join-Path $InstallDir "RAMUsageWidget.ps1"
if (-not (Test-Path $mainScript)) {
    $parts = @(Get-ChildItem -LiteralPath $InstallDir -Filter "RAMUsageWidget.ps1.part*" -File | Sort-Object Name)
    if ($parts.Count -gt 0) {
        $builder = New-Object System.Text.StringBuilder
        foreach ($part in $parts) {
            [void]$builder.Append((Get-Content -LiteralPath $part.FullName -Raw))
        }
        [System.IO.File]::WriteAllText($mainScript, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        $parts | Remove-Item -Force
    }
}
if (-not (Test-Path $mainScript)) {
    throw "RAMUsageWidget.ps1 is missing from the package."
}

# Detect RAM DIMM count.
$ramModules = 2
try {
    $ramCount = @(Get-CimInstance Win32_PhysicalMemory).Count
    if ($ramCount -ge 1) { $ramModules = $ramCount }
} catch {}

# Detect NVIDIA board power limit for a much better fallback if available.
$gpuMaxW = 250.0
try {
    $nv = (& nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($nv) {
        $v = 0.0
        if ([double]::TryParse($nv.Trim(), [ref]$v) -and $v -gt 20) {
            $gpuMaxW = $v
        }
    }
} catch {}

# Weather geocoding.
$weatherEnabled = $false
$weatherLat = 0.0
$weatherLon = 0.0
$weatherName = ""

if (-not [string]::IsNullOrWhiteSpace($town)) {
    Write-Host "[2/6] Finding weather location..."
    try {
        $encoded = [Uri]::EscapeDataString($town)
        $geo = Invoke-RestMethod -UseBasicParsing -Uri "https://geocoding-api.open-meteo.com/v1/search?name=$encoded&count=1&language=en&format=json" -TimeoutSec 8
        if ($geo.results -and $geo.results.Count -gt 0) {
            $weatherEnabled = $true
            $weatherLat = [double]$geo.results[0].latitude
            $weatherLon = [double]$geo.results[0].longitude
            $weatherName = [string]$geo.results[0].name
            Write-Host "      Weather location: $weatherName"
        } else {
            Write-Host "      Location not found. Weather will be disabled." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "      Weather lookup failed. Weather will be disabled." -ForegroundColor Yellow
    }
} else {
    Write-Host "[2/6] Weather disabled."
}

# Fresh user config. History is deliberately not created here.
$config = [ordered]@{
    ratePencePerKwh = [double]$rate
    cpuMaxW = 125.0
    gpuMaxW = [double]$gpuMaxW
    ramModules = [int]$ramModules
    ramIdleWPerModule = 2.0
    ramExtraWPerModule = 1.0
    baseSystemW = 35.0
    psuRatedW = [double]$psuW
    psuEfficiency = 0.88
    opacity = 0.82
    topmost = $true
    clickThrough = $true
    detailedView = $false
    fpsEnabled = $true
    weatherEnabled = [bool]$weatherEnabled
    weatherLat = [double]$weatherLat
    weatherLon = [double]$weatherLon
    weatherRefreshMinutes = 10
    updateMs = 1000
    windowLeft = -1
    windowTop = -1
}

$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir "config.json") -Encoding UTF8

Write-Host "[3/6] Downloading LibreHardwareMonitor v0.9.6..."
$LhmZip = Join-Path $LibDir "LibreHardwareMonitor.zip"
$LhmExtract = Join-Path $LibDir "LibreHardwareMonitor"
$LhmDll = Join-Path $LhmExtract "LibreHardwareMonitorLib.dll"

if (-not (Test-Path $LhmDll)) {
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip" `
        -OutFile $LhmZip

    if (Test-Path $LhmExtract) { Remove-Item $LhmExtract -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $LhmExtract | Out-Null
    Expand-Archive -Path $LhmZip -DestinationPath $LhmExtract -Force
    Remove-Item $LhmZip -Force
}

Write-Host "[4/6] Downloading Intel PresentMon v2.5.1..."
$PresentMon = Join-Path $LibDir "PresentMon-2.5.1-x64.exe"
$PresentMonUrl = "https://github.com/GameTechDev/PresentMon/releases/download/v2.5.1/PresentMon-2.5.1-x64.exe"
$PresentMonSha256 = "9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191"

$needPm = $true
if (Test-Path $PresentMon) {
    try {
        $hash = (Get-FileHash $PresentMon -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -eq $PresentMonSha256) { $needPm = $false }
    } catch {}
}

if ($needPm) {
    Invoke-WebRequest -UseBasicParsing -Uri $PresentMonUrl -OutFile $PresentMon
    $hash = (Get-FileHash $PresentMon -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($hash -ne $PresentMonSha256) {
        Remove-Item $PresentMon -Force -ErrorAction SilentlyContinue
        throw "PresentMon verification failed."
    }
}

Write-Host "[5/6] Enabling Windows autostart..."
$taskName = "PC Power Widget"
$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
$vbs = Join-Path $InstallDir "launch.vbs"

$action = New-ScheduledTaskAction -Execute $wscript -Argument "`"$vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

# Install an uninstaller beside the widget.
$uninstall = @'
$ErrorActionPreference = "SilentlyContinue"

Unregister-ScheduledTask -TaskName "PC Power Widget" -Confirm:$false

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
    if ($_.CommandLine -like "*PCPowerWidget*RAMUsageWidget.ps1*") {
        Stop-Process -Id $_.ProcessId -Force
    }
}

Get-CimInstance Win32_Process | Where-Object {
    $_.Name -like "PresentMon*.exe" -and $_.CommandLine -like "*RAMUsageWidget.FPS*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}

[System.Windows.Forms.MessageBox]::Show(
    "Autostart and running widget were removed.`n`nYou can now delete this folder:`n$env:LOCALAPPDATA\PCPowerWidget",
    "PC Power Widget",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
'@

$uninstall = "Add-Type -AssemblyName System.Windows.Forms`r`n" + $uninstall
$uninstall | Set-Content -LiteralPath (Join-Path $InstallDir "UNINSTALL.ps1") -Encoding UTF8

$uninstallBat = @'
@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0UNINSTALL.ps1"
'@
$uninstallBat | Set-Content -LiteralPath (Join-Path $InstallDir "UNINSTALL.bat") -Encoding ASCII

Write-Host "[6/6] Starting widget..."
Start-Process -FilePath $wscript -ArgumentList "`"$vbs`""

Write-Host ""
Write-Host "INSTALLED." -ForegroundColor Green
Write-Host "The widget will start automatically with Windows."
Write-Host "Installed folder: $InstallDir"
Write-Host ""
Write-Host "Close this window when ready."
Start-Sleep -Seconds 4
