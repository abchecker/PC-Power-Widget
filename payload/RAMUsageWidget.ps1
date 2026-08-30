param()

$ErrorActionPreference = "SilentlyContinue"
$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppDir "config.json"

# Prevent two copies from running.
$createdNew = $false
$script:Mutex = [System.Threading.Mutex]::new($true, "Local\RAM_Usage_Widget_2026", [ref]$createdNew)
if (-not $createdNew) { exit }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# Tiny native helper: CPU load and RAM load without polling WMI / spawning tools.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NativeMetrics
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetSystemTimes(out FILETIME idleTime, out FILETIME kernelTime, out FILETIME userTime);

    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

    static ulong prevIdle = 0, prevKernel = 0, prevUser = 0;
    static bool cpuReady = false;

    static ulong ToUInt64(FILETIME ft) {
        return ((ulong)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    }

    public static double CpuLoad()
    {
        FILETIME i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) return 0;
        ulong idle = ToUInt64(i), kernel = ToUInt64(k), user = ToUInt64(u);

        if (!cpuReady) {
            prevIdle = idle; prevKernel = kernel; prevUser = user; cpuReady = true;
            return 0;
        }

        ulong idleDelta = idle - prevIdle;
        ulong kernelDelta = kernel - prevKernel;
        ulong userDelta = user - prevUser;
        ulong total = kernelDelta + userDelta;

        prevIdle = idle; prevKernel = kernel; prevUser = user;
        if (total == 0) return 0;

        double busy = (double)(total - idleDelta) / total * 100.0;
        if (busy < 0) busy = 0;
        if (busy > 100) busy = 100;
        return busy;
    }

    public static double RamLoad()
    {
        var m = new MEMORYSTATUSEX();
        return GlobalMemoryStatusEx(m) ? m.dwMemoryLoad : 0;
    }
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ClickThroughHelper
{
    const int GWL_EXSTYLE = -20;
    const long WS_EX_TRANSPARENT = 0x00000020L;
    const long WS_EX_LAYERED = 0x00080000L;

    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")]
    static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")]
    static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint="GetWindowLong")]
    static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLong")]
    static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    static long GetStyle(IntPtr hWnd)
    {
        if (IntPtr.Size == 8) return GetWindowLongPtr64(hWnd, GWL_EXSTYLE).ToInt64();
        return GetWindowLong32(hWnd, GWL_EXSTYLE);
    }

    static void SetStyle(IntPtr hWnd, long style)
    {
        if (IntPtr.Size == 8) SetWindowLongPtr64(hWnd, GWL_EXSTYLE, new IntPtr(style));
        else SetWindowLong32(hWnd, GWL_EXSTYLE, (int)style);
    }

    public static void SetClickThrough(IntPtr hWnd, bool enabled)
    {
        long style = GetStyle(hWnd);
        style |= WS_EX_LAYERED;
        if (enabled) style |= WS_EX_TRANSPARENT;
        else style &= ~WS_EX_TRANSPARENT;
        SetStyle(hWnd, style);
    }
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;

public static class FpsBridge
{
    public static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static int GetForegroundProcessId()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }

    public static void Clear()
    {
        string line;
        while (Lines.TryDequeue(out line)) { }
    }
}
"@

function Load-Config {
    try {
        return (Get-Content $script:ConfigPath -Raw | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            ratePencePerKwh = 26.11
            cpuMaxW = 125.0
            gpuMaxW = 250.0
            ramModules = 2
            ramIdleWPerModule = 2.0
            ramExtraWPerModule = 1.0
            baseSystemW = 35.0
            psuRatedW = 1000.0
            psuEfficiency = 0.88
            opacity = 0.82
            topmost = $true
            clickThrough = $true
            fpsEnabled = $true
            weatherEnabled = $false
            weatherLat = 0.0
            weatherLon = 0.0
            weatherRefreshMinutes = 10
            updateMs = 1000
            windowLeft = -1
            windowTop = -1
        }
    }
}

function Save-Config {
    try {
        $script:Config | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch {}
}

$script:Config = Load-Config
if ($null -eq $script:Config.PSObject.Properties["clickThrough"]) {
    $script:Config | Add-Member -NotePropertyName clickThrough -NotePropertyValue $true
}
if ($null -eq $script:Config.PSObject.Properties["detailedView"]) {
    $script:Config | Add-Member -NotePropertyName detailedView -NotePropertyValue $false
}
if ($null -eq $script:Config.PSObject.Properties["fpsEnabled"]) {
    $script:Config | Add-Member -NotePropertyName fpsEnabled -NotePropertyValue $true
}
if ($null -eq $script:Config.PSObject.Properties["weatherEnabled"]) {
    $script:Config | Add-Member -NotePropertyName weatherEnabled -NotePropertyValue $false
}
if ($null -eq $script:Config.PSObject.Properties["weatherLat"]) {
    $script:Config | Add-Member -NotePropertyName weatherLat -NotePropertyValue 0.0
}
if ($null -eq $script:Config.PSObject.Properties["weatherLon"]) {
    $script:Config | Add-Member -NotePropertyName weatherLon -NotePropertyValue 0.0
}
if ($null -eq $script:Config.PSObject.Properties["weatherRefreshMinutes"]) {
    $script:Config | Add-Member -NotePropertyName weatherRefreshMinutes -NotePropertyValue 10
}
Save-Config

# LibreHardwareMonitor (downloaded by SETUP.ps1).
$script:LhmOK = $false
$script:Computer = $null
try {
    $dll = Get-ChildItem (Join-Path $script:AppDir "lib") -Filter "LibreHardwareMonitorLib.dll" -Recurse | Select-Object -First 1
    if ($dll) {
        Add-Type -Path $dll.FullName
        $script:Computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $script:Computer.IsCpuEnabled = $true
        $script:Computer.IsGpuEnabled = $true
        $script:Computer.Open()
        $script:LhmOK = $true
    }
} catch {
    $script:LhmOK = $false
}

function Update-HwTree($hw) {
    if ($null -eq $hw) { return }
    try { $hw.Update() } catch {}
    try {
        foreach ($sub in $hw.SubHardware) { Update-HwTree $sub }
    } catch {}
}

function Get-AllHardware {
    $all = New-Object System.Collections.Generic.List[object]
    if (-not $script:LhmOK -or $null -eq $script:Computer) { return $all }
    foreach ($hw in $script:Computer.Hardware) {
        $all.Add($hw)
        foreach ($sub in $hw.SubHardware) { $all.Add($sub) }
    }
    return $all
}

function Get-SensorValue {
    param(
        [string[]]$HardwareTypes,
        [string]$SensorType,
        [string[]]$PreferredNames
    )

    if (-not $script:LhmOK) { return $null }

    $candidates = @()
    foreach ($hw in (Get-AllHardware)) {
        $ht = [string]$hw.HardwareType
        if ($HardwareTypes -notcontains $ht) { continue }

        foreach ($s in $hw.Sensors) {
            if ([string]$s.SensorType -ne $SensorType) { continue }
            if ($null -eq $s.Value) { continue }
            $candidates += $s
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    foreach ($wanted in $PreferredNames) {
        $exact = $candidates | Where-Object { ([string]$_.Name) -ieq $wanted } | Select-Object -First 1
        if ($exact) { return [double]$exact.Value }
    }

    foreach ($wanted in $PreferredNames) {
        $match = $candidates | Where-Object { ([string]$_.Name) -like "*$wanted*" } | Select-Object -First 1
        if ($match) { return [double]$match.Value }
    }

    return [double](($candidates | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1).Value)
}

# PresentMon FPS capture.
# v1.10: persistent all-process capture. Prefer foreground renderer;
# otherwise choose the busiest non-system renderer in the latest sample.
$script:PresentMonPath = $null
try {
    $script:PresentMonPath = (Get-ChildItem (Join-Path $script:AppDir "lib") -Filter "PresentMon-*-x64.exe" -File |
        Sort-Object Name -Descending | Select-Object -First 1).FullName
} catch {}

$script:PresentMonProcess = $null
$script:PresentMonEventId = "RAMUsageWidget.PresentMon"
$script:FpsHeader = $null
$script:FpsAppIndex = -1
$script:FpsPidIndex = -1
$script:FpsGapIndex = -1
$script:FpsFrameTimeIndex = -1
$script:CurrentFps = $null
$script:FpsSource = ""
$script:FpsStatus = "Starting"
$script:FpsLastFrame = [DateTime]::MinValue
$script:FpsLastStartAttempt = [DateTime]::MinValue

$script:FpsExcludedProcesses = @(
    "explorer","dwm","SearchHost","StartMenuExperienceHost","ShellExperienceHost",
    "TextInputHost","ApplicationFrameHost","RuntimeBroker","SystemSettings","Taskmgr",
    "powershell","pwsh","wscript","cscript","conhost","chrome","msedge","firefox",
    "steam","steamwebhelper","GameBar","GameBarFTServer","Widgets","WidgetService",
    "NVIDIA Overlay","NVIDIA Share","nvcontainer","PresentMon"
)

function Test-FpsAppAllowed([string]$AppName) {
    if ([string]::IsNullOrWhiteSpace($AppName)) { return $false }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($AppName)
    foreach ($x in $script:FpsExcludedProcesses) {
        if ($base -ieq $x) { return $false }
    }
    return $true
}

function Stop-FpsCapture {
    try { Unregister-Event -SourceIdentifier $script:PresentMonEventId -ErrorAction SilentlyContinue } catch {}
    try {
        if ($script:PresentMonProcess -and -not $script:PresentMonProcess.HasExited) {
            $script:PresentMonProcess.Kill()
            $script:PresentMonProcess.WaitForExit(500) | Out-Null
        }
    } catch {}
    try { if ($script:PresentMonProcess) { $script:PresentMonProcess.Dispose() } } catch {}

    $script:PresentMonProcess = $null
    $script:FpsHeader = $null
    $script:FpsAppIndex = -1
    $script:FpsPidIndex = -1
    $script:FpsGapIndex = -1
    $script:FpsFrameTimeIndex = -1
    $script:CurrentFps = $null
    $script:FpsSource = ""
    [FpsBridge]::Clear()
}

function Start-FpsCapture {
    if (-not [bool]$script:Config.fpsEnabled) { return }

    if ([string]::IsNullOrWhiteSpace($script:PresentMonPath) -or -not (Test-Path $script:PresentMonPath)) {
        $script:FpsStatus = "PresentMon missing"
        return
    }

    Stop-FpsCapture
    $script:FpsLastStartAttempt = Get-Date

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:PresentMonPath

        # No PID filter: capture all renderers continuously.
        $psi.Arguments = "--output_stdout --no_console_stats --no_track_gpu --no_track_input --no_track_display --v1_metrics --session_name RAMUsageWidget.FPS --stop_existing_session"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.EnableRaisingEvents = $true

        if (-not $p.Start()) {
            $script:FpsStatus = "Start failed"
            return
        }

        $script:PresentMonProcess = $p
        [FpsBridge]::Clear()

        Register-ObjectEvent -InputObject $p -EventName OutputDataReceived `
            -SourceIdentifier $script:PresentMonEventId -Action {
                $line = $event.SourceEventArgs.Data
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    [FpsBridge]::Lines.Enqueue($line)
                }
            } | Out-Null

        $p.BeginOutputReadLine()
        $script:FpsStatus = "Waiting for frames"
    } catch {
        $script:FpsStatus = "PresentMon error"
        Stop-FpsCapture
    }
}

function Update-FpsCapture([double]$GpuLoad) {
    if (-not [bool]$script:Config.fpsEnabled) {
        if ($script:PresentMonProcess) { Stop-FpsCapture }
        $script:FpsStatus = "Disabled"
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:PresentMonPath) -or -not (Test-Path $script:PresentMonPath)) {
        $script:CurrentFps = $null
        $script:FpsStatus = "PresentMon missing"
        return
    }

    if ($null -eq $script:PresentMonProcess -or $script:PresentMonProcess.HasExited) {
        if (((Get-Date) - $script:FpsLastStartAttempt).TotalSeconds -ge 3) {
            Start-FpsCapture
        }
    }

    $foregroundPid = 0
    try { $foregroundPid = [FpsBridge]::GetForegroundProcessId() } catch {}

    $samples = @{}
    $names = @{}

    $line = $null
    while ([FpsBridge]::Lines.TryDequeue([ref]$line)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line.TrimStart().StartsWith("Application,", [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:FpsHeader = $line -split ","
            $script:FpsAppIndex = -1
            $script:FpsPidIndex = -1
            $script:FpsGapIndex = -1
            $script:FpsFrameTimeIndex = -1

            for ($i = 0; $i -lt $script:FpsHeader.Count; $i++) {
                $h = ([string]$script:FpsHeader[$i]).Trim()

                if ($h -ieq "Application") { $script:FpsAppIndex = $i }
                if ($h -ieq "ProcessID") { $script:FpsPidIndex = $i }

                if ($h -ieq "msBetweenPresents" -or $h -ieq "MsBetweenPresents") {
                    $script:FpsGapIndex = $i
                }

                if ($h -ieq "FrameTime") {
                    $script:FpsFrameTimeIndex = $i
                }
            }

            if ($script:FpsPidIndex -ge 0 -and
                ($script:FpsGapIndex -ge 0 -or $script:FpsFrameTimeIndex -ge 0)) {
                $script:FpsStatus = "Capturing"
            } else {
                $script:FpsStatus = "CSV columns unknown"
            }
            continue
        }

        if ($script:FpsPidIndex -lt 0) { continue }
        if ($script:FpsGapIndex -lt 0 -and $script:FpsFrameTimeIndex -lt 0) { continue }
        if ($line.StartsWith("Warning") -or $line.StartsWith("Error")) { continue }

        $parts = $line -split ","
        if ($parts.Count -le $script:FpsPidIndex) { continue }

        $rowPid = 0
        if (-not [int]::TryParse($parts[$script:FpsPidIndex].Trim(), [ref]$rowPid)) { continue }

        $app = ""
        if ($script:FpsAppIndex -ge 0 -and $parts.Count -gt $script:FpsAppIndex) {
            $app = $parts[$script:FpsAppIndex].Trim()
        }

        if (-not (Test-FpsAppAllowed $app)) { continue }

        $metricIndex = -1
        if ($script:FpsGapIndex -ge 0 -and $parts.Count -gt $script:FpsGapIndex) {
            $metricIndex = $script:FpsGapIndex
        } elseif ($script:FpsFrameTimeIndex -ge 0 -and $parts.Count -gt $script:FpsFrameTimeIndex) {
            $metricIndex = $script:FpsFrameTimeIndex
        }

        if ($metricIndex -lt 0) { continue }

        $gap = 0.0
        if (-not [double]::TryParse(
            $parts[$metricIndex],
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$gap)) {
            continue
        }

        if ($gap -le 0.05 -or $gap -ge 1000) { continue }

        if (-not $samples.ContainsKey($rowPid)) {
            $samples[$rowPid] = New-Object System.Collections.Generic.List[double]
            $names[$rowPid] = $app
        }

        $samples[$rowPid].Add($gap)
    }

    $chosenPid = 0

    if ($foregroundPid -gt 0 -and $samples.ContainsKey($foregroundPid)) {
        $chosenPid = $foregroundPid
    } else {
        $bestCount = 0
        foreach ($pidKey in $samples.Keys) {
            $count = $samples[$pidKey].Count
            if ($count -gt $bestCount) {
                $bestCount = $count
                $chosenPid = [int]$pidKey
            }
        }
    }

    if ($chosenPid -gt 0 -and $samples.ContainsKey($chosenPid)) {
        $list = $samples[$chosenPid]

        if ($list.Count -ge 2) {
            $sum = 0.0
            foreach ($g in $list) { $sum += $g }

            if ($sum -gt 0) {
                $fps = 1000.0 * $list.Count / $sum
                if ($fps -gt 999) { $fps = 999 }

                $script:CurrentFps = $fps
                $script:FpsSource = [System.IO.Path]::GetFileNameWithoutExtension([string]$names[$chosenPid])
                $script:FpsLastFrame = Get-Date
                $script:FpsStatus = "OK"
            }
        }
    } else {
        if ($script:FpsLastFrame -ne [DateTime]::MinValue -and
            ((Get-Date) - $script:FpsLastFrame).TotalSeconds -gt 2) {
            $script:CurrentFps = $null
            $script:FpsSource = ""
        }

        if ($script:PresentMonProcess -and -not $script:PresentMonProcess.HasExited) {
            if ($script:FpsHeader -eq $null) {
                $script:FpsStatus = "Waiting for CSV"
            } else {
                $script:FpsStatus = "No game frames"
            }
        }
    }
}

# Persistent electricity history.
# Stored as one CSV row per calendar day.
$script:HistoryPath = Join-Path $script:AppDir "usage_history.csv"
$script:HistoryRows = @{}
$script:HistoryDirty = $false
$script:HistoryLastSave = Get-Date

function Load-UsageHistory {
    $script:HistoryRows = @{}

    if (-not (Test-Path $script:HistoryPath)) { return }

    try {
        foreach ($row in (Import-Csv -LiteralPath $script:HistoryPath)) {
            if ([string]::IsNullOrWhiteSpace([string]$row.Date)) { continue }

            $script:HistoryRows[[string]$row.Date] = [pscustomobject]@{
                Date = [string]$row.Date
                KWh = [double]$row.KWh
                CostGBP = [double]$row.CostGBP
                Seconds = [double]$row.Seconds
            }
        }
    } catch {
        $script:HistoryRows = @{}
    }
}

function Save-UsageHistory {
    if (-not $script:HistoryDirty) { return }

    try {
        $output = @()

        foreach ($key in ($script:HistoryRows.Keys | Sort-Object)) {
            $row = $script:HistoryRows[$key]

            $output += [pscustomobject]@{
                Date = [string]$row.Date
                KWh = ("{0:0.000000}" -f [double]$row.KWh)
                CostGBP = ("{0:0.000000}" -f [double]$row.CostGBP)
                Seconds = ("{0:0.0}" -f [double]$row.Seconds)
            }
        }

        $tmp = "$script:HistoryPath.tmp"
        $output | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:HistoryPath -Force

        $script:HistoryDirty = $false
        $script:HistoryLastSave = Get-Date
    } catch {}
}

function Add-UsageHistorySample {
    param(
        [DateTime]$Now,
        [double]$WallW,
        [double]$Seconds,
        [double]$RateGBP
    )

    if ($Seconds -le 0 -or $WallW -lt 0) { return }

    $key = $Now.ToString("yyyy-MM-dd")

    if (-not $script:HistoryRows.ContainsKey($key)) {
        $script:HistoryRows[$key] = [pscustomobject]@{
            Date = $key
            KWh = 0.0
            CostGBP = 0.0
            Seconds = 0.0
        }
    }

    $row = $script:HistoryRows[$key]
    $energyKWh = ($WallW / 1000.0) * ($Seconds / 3600.0)

    $row.KWh = [double]$row.KWh + $energyKWh
    $row.CostGBP = [double]$row.CostGBP + ($energyKWh * $RateGBP)
    $row.Seconds = [double]$row.Seconds + $Seconds

    $script:HistoryDirty = $true
}

function Get-HistoryTotals {
    param([string]$Prefix)

    $kwh = 0.0
    $cost = 0.0
    $seconds = 0.0

    foreach ($key in $script:HistoryRows.Keys) {
        if ([string]::IsNullOrEmpty($Prefix) -or $key.StartsWith($Prefix)) {
            $row = $script:HistoryRows[$key]
            $kwh += [double]$row.KWh
            $cost += [double]$row.CostGBP
            $seconds += [double]$row.Seconds
        }
    }

    return [pscustomobject]@{
        KWh = $kwh
        CostGBP = $cost
        Seconds = $seconds
    }
}

Load-UsageHistory

# Outside weather: async, so a slow internet request never freezes the widget.
$script:OutsideTempC = $null
$script:WeatherTask = $null
$script:WeatherLastRequest = [DateTime]::MinValue
$script:WeatherClient = [System.Net.Http.HttpClient]::new()
$script:WeatherClient.Timeout = [TimeSpan]::FromSeconds(5)

function Update-Weather {
    if (-not [bool]$script:Config.weatherEnabled) {
        $script:OutsideTempC = $null
        return
    }

    # Collect completed request.
    if ($script:WeatherTask -ne $null -and $script:WeatherTask.IsCompleted) {
        try {
            if (-not $script:WeatherTask.IsFaulted -and -not $script:WeatherTask.IsCanceled) {
                $json = $script:WeatherTask.Result
                $obj = $json | ConvertFrom-Json
                if ($obj.current -and $null -ne $obj.current.temperature_2m) {
                    $script:OutsideTempC = [double]$obj.current.temperature_2m
                }
            }
        } catch {}
        $script:WeatherTask = $null
    }

    # Refresh only every N minutes.
    $mins = [double]$script:Config.weatherRefreshMinutes
    if ($mins -lt 1) { $mins = 10 }

    if ($script:WeatherTask -eq $null -and
        ((Get-Date) - $script:WeatherLastRequest).TotalMinutes -ge $mins) {
        try {
            $lat = [double]$script:Config.weatherLat
            $lon = [double]$script:Config.weatherLon
            $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m&timezone=Europe%2FLondon"
            $script:WeatherTask = $script:WeatherClient.GetStringAsync($url)
            $script:WeatherLastRequest = Get-Date
        } catch {
            $script:WeatherTask = $null
            $script:WeatherLastRequest = Get-Date
        }
    }
}

# WPF UI
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="455" Height="48"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True">
    <Grid>
        <Border x:Name="CompactPanel" CornerRadius="12" Background="#EA111318"
                BorderBrush="#30FFFFFF" BorderThickness="1" Padding="12,1">
            <Grid Height="44" VerticalAlignment="Center">
                <Grid.RowDefinitions>
                    <RowDefinition Height="29"/>
                    <RowDefinition Height="15"/>
                </Grid.RowDefinitions>

                <!-- Main metrics: 431px usable inner width. -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="62"/>
                        <ColumnDefinition Width="72"/>
                        <ColumnDefinition Width="72"/>
                        <ColumnDefinition Width="75"/>
                        <ColumnDefinition Width="66"/>
                        <ColumnDefinition Width="84"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" BorderBrush="#2CFFFFFF" BorderThickness="0,0,1,0">
                        <TextBlock x:Name="CompactFPS" Text="FPS --" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="14"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>

                    <Border Grid.Column="1" BorderBrush="#2CFFFFFF" BorderThickness="0,0,1,0">
                        <TextBlock x:Name="CompactCPU" Text="CPU --%" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="14"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>

                    <Border Grid.Column="2" BorderBrush="#2CFFFFFF" BorderThickness="0,0,1,0">
                        <TextBlock x:Name="CompactGPU" Text="GPU --%" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="14"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>

                    <Border Grid.Column="3" BorderBrush="#2CFFFFFF" BorderThickness="0,0,1,0">
                        <TextBlock x:Name="CompactRAM" Text="RAM --%" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="14"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>

                    <Border Grid.Column="4" BorderBrush="#2CFFFFFF" BorderThickness="0,0,1,0">
                        <TextBlock x:Name="CompactPower" Text="~---W" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="14"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>

                    <Border Grid.Column="5">
                        <TextBlock x:Name="CompactCost" Text="£0.000/h" Foreground="White"
                                   FontFamily="Segoe UI" FontWeight="Bold" FontSize="13.5"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="NoWrap"/>
                    </Border>
                </Grid>

                <!-- Tiny detail footer, no extra widget height. -->
                <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Center"
                            VerticalAlignment="Center">
                    <TextBlock x:Name="CompactDate" Text="-- ---" Foreground="#8FFFFFFF"
                               FontFamily="Segoe UI" FontSize="9.0" FontWeight="SemiBold"/>
                    <TextBlock Text="  •  " Foreground="#45FFFFFF" FontSize="8.5"/>
                    <TextBlock x:Name="CompactTime" Text="--:--" Foreground="#AFFFFFFF"
                               FontFamily="Segoe UI" FontSize="9.0" FontWeight="SemiBold"/>
                    <TextBlock Text="  •  " Foreground="#45FFFFFF" FontSize="8.5"/>
                    <TextBlock x:Name="CompactTemp" Text="OUT --°C" Foreground="#AFFFFFFF"
                               FontFamily="Segoe UI" FontSize="9.0" FontWeight="SemiBold"/>
                    <TextBlock Text="  •  " Foreground="#45FFFFFF" FontSize="8.5"/>
                    <TextBlock x:Name="CompactMonthTotal" Text="AUG £0.00" Foreground="#DFFFFFFF"
                               FontFamily="Segoe UI" FontSize="9.0" FontWeight="Bold"/>
                </StackPanel>
            </Grid>
        </Border>
        <Border x:Name="DetailedPanel" Visibility="Collapsed" CornerRadius="14" Background="#EA111318" BorderBrush="#30FFFFFF" BorderThickness="1" Padding="16">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="27"/><RowDefinition Height="27"/><RowDefinition Height="27"/><RowDefinition Height="1"/><RowDefinition Height="34"/><RowDefinition Height="25"/><RowDefinition Height="20"/><RowDefinition Height="28"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="60"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="CPU" Foreground="#BFFFFFFF" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock x:Name="CpuLoad" Grid.Row="0" Grid.Column="1" Text="--%" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
                <TextBlock x:Name="CpuW" Grid.Row="0" Grid.Column="2" Text="-- W" Foreground="#DFFFFFFF" FontFamily="Consolas" FontSize="13" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="GPU" Foreground="#BFFFFFFF" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock x:Name="GpuLoad" Grid.Row="1" Grid.Column="1" Text="--%" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
                <TextBlock x:Name="GpuW" Grid.Row="1" Grid.Column="2" Text="-- W" Foreground="#DFFFFFFF" FontFamily="Consolas" FontSize="13" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="RAM" Foreground="#BFFFFFFF" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock x:Name="RamLoad" Grid.Row="2" Grid.Column="1" Text="--%" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
                <TextBlock x:Name="RamW" Grid.Row="2" Grid.Column="2" Text="~-- W" Foreground="#DFFFFFFF" FontFamily="Consolas" FontSize="13" TextAlignment="Right" VerticalAlignment="Center"/>
                <Border Grid.Row="3" Grid.ColumnSpan="3" Background="#28FFFFFF"/>
                <TextBlock Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="2" Text="POWER" Foreground="#BFFFFFFF" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="Power" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" Text="~--- W" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="22" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="2" Text="NOW" Foreground="#BFFFFFFF" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="CurrentCost" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" Text="£0.000 / h" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="Rate" Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="3" Text="RATE 26.11p/kWh" Foreground="#8FFFFFFF" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Grid.Row="7" Grid.Column="0" Text="TIME" Foreground="#8FFFFFFF" FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Bottom"/>
                <TextBlock x:Name="Duration" Grid.Row="7" Grid.Column="1" Text="00:00:00" Foreground="#CFFFFFFF" FontFamily="Consolas" FontSize="12" VerticalAlignment="Bottom"/>
                <StackPanel Grid.Row="7" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                    <TextBlock Text="TOTAL " Foreground="#8FFFFFFF" FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Center"/>
                    <TextBlock x:Name="Cost" Text="£0.000" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$compactPanel = $window.FindName("CompactPanel")
$detailedPanel = $window.FindName("DetailedPanel")
$compactFPS = $window.FindName("CompactFPS")
$compactCPU = $window.FindName("CompactCPU")
$compactGPU = $window.FindName("CompactGPU")
$compactRAM = $window.FindName("CompactRAM")
$compactPower = $window.FindName("CompactPower")
$compactCost = $window.FindName("CompactCost")
$compactDate = $window.FindName("CompactDate")
$compactTime = $window.FindName("CompactTime")
$compactTemp = $window.FindName("CompactTemp")
$compactMonthTotal = $window.FindName("CompactMonthTotal")

$cpuLoadText = $window.FindName("CpuLoad")
$cpuWText = $window.FindName("CpuW")
$gpuLoadText = $window.FindName("GpuLoad")
$gpuWText = $window.FindName("GpuW")
$ramLoadText = $window.FindName("RamLoad")
$ramWText = $window.FindName("RamW")
$powerText = $window.FindName("Power")
$currentCostText = $window.FindName("CurrentCost")
$rateText = $window.FindName("Rate")
$durationText = $window.FindName("Duration")
$costText = $window.FindName("Cost")

$brushConverter = New-Object System.Windows.Media.BrushConverter
$script:BrushGreen = $brushConverter.ConvertFromString("#71E38D")
$script:BrushAmber = $brushConverter.ConvertFromString("#FFC857")
$script:BrushRed = $brushConverter.ConvertFromString("#FF5F63")
$script:BrushWhite = $brushConverter.ConvertFromString("#F4F4F4")
$script:BrushMuted = $brushConverter.ConvertFromString("#A9A9AD")

function Get-UsageBrush([double]$Value) {
    if ($Value -ge 70) { return $script:BrushRed }
    if ($Value -ge 50) { return $script:BrushAmber }
    return $script:BrushGreen
}

$window.Topmost = [bool]$script:Config.topmost
$window.Opacity = [double]$script:Config.opacity

function Apply-ViewMode {
    if ([bool]$script:Config.detailedView) {
        $compactPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $detailedPanel.Visibility = [System.Windows.Visibility]::Visible
        $window.Width = 310
        $window.Height = 228
    } else {
        $detailedPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $compactPanel.Visibility = [System.Windows.Visibility]::Visible
        $window.Width = 455
        $window.Height = 48
    }
}
Apply-ViewMode

if ([double]$script:Config.windowLeft -ge 0 -and [double]$script:Config.windowTop -ge 0) {
    $window.Left = [double]$script:Config.windowLeft
    $window.Top = [double]$script:Config.windowTop
} else {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - $window.Width - 22
    $window.Top = $wa.Top + 22
}

# Dragging is available only when click-through is OFF.
$window.Add_MouseLeftButtonDown({
    if (-not [bool]$script:Config.clickThrough) {
        try { $window.DragMove() } catch {}
    }
})
$window.Add_MouseLeftButtonUp({
    if (-not [bool]$script:Config.clickThrough) {
        $script:Config.windowLeft = [math]::Round($window.Left)
        $script:Config.windowTop = [math]::Round($window.Top)
        Save-Config
    }
})

# Tray icon and menu.
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = "RAM Usage Widget"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$showItem = $menu.Items.Add("Hide widget")
$showItem.Add_Click({
    if ($window.IsVisible) {
        $window.Hide()
        $showItem.Text = "Show widget"
    } else {
        $window.Show()
        $window.Activate()
        $showItem.Text = "Hide widget"
    }
})

$topItem = New-Object System.Windows.Forms.ToolStripMenuItem
$topItem.Text = "Always on top"
$topItem.Checked = [bool]$script:Config.topmost
$topItem.CheckOnClick = $true
$topItem.Add_CheckedChanged({
    $window.Topmost = $topItem.Checked
    $script:Config.topmost = $topItem.Checked
    Save-Config
})
[void]$menu.Items.Add($topItem)

$clickItem = New-Object System.Windows.Forms.ToolStripMenuItem
$clickItem.Text = "Click-through"
$clickItem.Checked = [bool]$script:Config.clickThrough
$clickItem.CheckOnClick = $true
$clickItem.Add_CheckedChanged({
    $script:Config.clickThrough = $clickItem.Checked
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        [ClickThroughHelper]::SetClickThrough($hwnd, $clickItem.Checked)
    } catch {}
    Save-Config
})
[void]$menu.Items.Add($clickItem)

$fpsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$fpsItem.Text = "FPS monitoring"
$fpsItem.Checked = [bool]$script:Config.fpsEnabled
$fpsItem.CheckOnClick = $true
$fpsItem.Add_CheckedChanged({
    $script:Config.fpsEnabled = $fpsItem.Checked
    if (-not $fpsItem.Checked) { Stop-FpsCapture }
    Save-Config
})
[void]$menu.Items.Add($fpsItem)

$versionItem = New-Object System.Windows.Forms.ToolStripMenuItem
$versionItem.Text = "Widget version: 1.12.1 SHARE"
$versionItem.Enabled = $false
[void]$menu.Items.Add($versionItem)

$fpsStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$fpsStatusItem.Text = "FPS status: Starting"
$fpsStatusItem.Enabled = $false
[void]$menu.Items.Add($fpsStatusItem)

$fpsSourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$fpsSourceItem.Text = "FPS source: --"
$fpsSourceItem.Enabled = $false
[void]$menu.Items.Add($fpsSourceItem)

$weatherItem = New-Object System.Windows.Forms.ToolStripMenuItem
$weatherItem.Text = "Outside temperature"
$weatherItem.Checked = [bool]$script:Config.weatherEnabled
$weatherItem.CheckOnClick = $true
$weatherItem.Add_CheckedChanged({
    $script:Config.weatherEnabled = $weatherItem.Checked
    if ($weatherItem.Checked) {
        $script:WeatherLastRequest = [DateTime]::MinValue
    } else {
        $script:OutsideTempC = $null
    }
    Save-Config
})
[void]$menu.Items.Add($weatherItem)

$detailItem = New-Object System.Windows.Forms.ToolStripMenuItem
$detailItem.Text = "Detailed view"
$detailItem.Checked = [bool]$script:Config.detailedView
$detailItem.CheckOnClick = $true
$detailItem.Add_CheckedChanged({
    $script:Config.detailedView = $detailItem.Checked
    Apply-ViewMode
    Save-Config
})
[void]$menu.Items.Add($detailItem)

$historyItem = New-Object System.Windows.Forms.ToolStripMenuItem
$historyItem.Text = "Electricity history"
$historyItem.Add_Click({
    try {
        $historyScript = Join-Path $script:AppDir "UsageHistory.ps1"
        if (Test-Path $historyScript) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$historyScript`""
        }
    } catch {}
})
[void]$menu.Items.Add($historyItem)

$opacityMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$opacityMenu.Text = "Opacity"
foreach ($pct in @(35,50,65,82,100)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = "$pct%"
    $item.Tag = $pct
    $item.Add_Click({
        param($sender,$e)
        $v = [double]$sender.Tag / 100.0
        $window.Opacity = $v
        $script:Config.opacity = $v
        Save-Config
    })
    [void]$opacityMenu.DropDownItems.Add($item)
}
[void]$menu.Items.Add($opacityMenu)

$resetItem = $menu.Items.Add("Reset session duration + cost")
$resetItem.Add_Click({
    $script:StartTime = Get-Date
    $script:LastTick = Get-Date
    $script:EnergyKWh = 0.0
})

$configItem = $menu.Items.Add("Open config")
$configItem.Add_Click({
    Start-Process notepad.exe $script:ConfigPath
})

[void]$menu.Items.Add("-")
$exitItem = $menu.Items.Add("Exit")
$exitItem.Add_Click({
    $script:Exiting = $true
    $window.Close()
})

$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({
    if ($window.IsVisible) { $window.Hide(); $showItem.Text = "Show widget" }
    else { $window.Show(); $window.Activate(); $showItem.Text = "Hide widget" }
})

$script:StartTime = Get-Date
$script:LastTick = Get-Date
$script:EnergyKWh = 0.0
$script:Exiting = $false

# Prime CPU sampling.
[void][NativeMetrics]::CpuLoad()

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([int]$script:Config.updateMs)

$timer.Add_Tick({
    $now = Get-Date
    Update-Weather
    $dt = ($now - $script:LastTick).TotalSeconds
    $script:LastTick = $now

    # Do not count Windows sleep / long pauses as active PC energy.
    if ($dt -lt 0 -or $dt -gt 5) { $dt = 0 }

    $cpuLoad = [double][NativeMetrics]::CpuLoad()
    $ramLoad = [double][NativeMetrics]::RamLoad()

    if ($script:LhmOK) {
        foreach ($hw in $script:Computer.Hardware) { Update-HwTree $hw }
    }

    $gpuLoad = Get-SensorValue @("GpuNvidia","GpuAmd","GpuIntel") "Load" @("GPU Core","D3D 3D","Core")
    $cpuPowerActual = Get-SensorValue @("Cpu") "Power" @("CPU Package","Package")
    $gpuPowerActual = Get-SensorValue @("GpuNvidia","GpuAmd","GpuIntel") "Power" @("GPU Package","GPU Power","Board Power","Package","Power")

    # NVIDIA fallback: if LHM cannot expose GPU telemetry, use the NVIDIA driver's own nvidia-smi.
    if ($null -eq $gpuLoad -or $null -eq $gpuPowerActual) {
        try {
            $nv = (& nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if ($nv) {
                $parts = $nv -split ","
                if ($parts.Count -ge 2) {
                    if ($null -eq $gpuLoad) { $gpuLoad = [double]($parts[0].Trim()) }
                    if ($null -eq $gpuPowerActual) { $gpuPowerActual = [double]($parts[1].Trim()) }
                }
            }
        } catch {}
    }

    if ($null -eq $gpuLoad) { $gpuLoad = 0.0 }

    Update-FpsCapture ([double]$gpuLoad)

    $cpuEstimated = $false
    if ($null -eq $cpuPowerActual -or $cpuPowerActual -le 0.1) {
        $cpuEstimated = $true
        $f = [math]::Pow([math]::Max(0,[math]::Min(1,$cpuLoad/100.0)), 1.40)
        $cpuW = 8.0 + (([double]$script:Config.cpuMaxW - 8.0) * $f)
    } else {
        $cpuW = [double]$cpuPowerActual
    }

    $gpuEstimated = $false
    if ($null -eq $gpuPowerActual -or $gpuPowerActual -le 0.1) {
        $gpuEstimated = $true
        $f = [math]::Pow([math]::Max(0,[math]::Min(1,[double]$gpuLoad/100.0)), 1.15)
        $gpuW = 8.0 + (([double]$script:Config.gpuMaxW - 8.0) * $f)
    } else {
        $gpuW = [double]$gpuPowerActual
    }

    # RAM rarely exposes usable real-time watts, so estimate per DDR4 DIMM.
    $ramPer = [double]$script:Config.ramIdleWPerModule + ([double]$script:Config.ramExtraWPerModule * ($ramLoad/100.0))
    $ramW = [double]$script:Config.ramModules * $ramPer

    # Other DC load: motherboard, AIO pump/fans, SSD/NVMe etc.
    $dcW = $cpuW + $gpuW + $ramW + [double]$script:Config.baseSystemW

    $eff = [double]$script:Config.psuEfficiency
    if ($eff -lt 0.50 -or $eff -gt 1.0) { $eff = 0.85 }

    # PSU rating is an output capacity, so wall watts can be higher than its label.
    $maxWall = [double]$script:Config.psuRatedW / $eff
    $wallW = $dcW / $eff
    if ($wallW -gt $maxWall) { $wallW = $maxWall }
    if ($wallW -lt 0) { $wallW = 0 }

    if ($dt -gt 0) {
        $script:EnergyKWh += ($wallW / 1000.0) * ($dt / 3600.0)
    }

    $rateGBP = [double]$script:Config.ratePencePerKwh / 100.0

    Add-UsageHistorySample -Now $now -WallW $wallW -Seconds $dt -RateGBP $rateGBP

    if (((Get-Date) - $script:HistoryLastSave).TotalSeconds -ge 60) {
        Save-UsageHistory
    }

    $cost = $script:EnergyKWh * $rateGBP

    # Current burn rate: what one hour would cost if the PC stayed
    # at this exact current power draw.
    $currentCostPerHour = ($wallW / 1000.0) * $rateGBP

    $elapsed = $now - $script:StartTime

    $cpuPrefix = if ($cpuEstimated) { "~" } else { "" }
    $gpuPrefix = if ($gpuEstimated) { "~" } else { "" }

    $cpuLoadText.Text = ("{0,3:0}%" -f $cpuLoad)
    $gpuLoadText.Text = ("{0,3:0}%" -f [double]$gpuLoad)
    $ramLoadText.Text = ("{0,3:0}%" -f $ramLoad)
    if ($null -eq $script:CurrentFps) {
        $compactFPS.Text = "FPS --"
        $compactFPS.Foreground = $script:BrushMuted
    } else {
        $compactFPS.Text = ("FPS {0:0}" -f [double]$script:CurrentFps)
        $compactFPS.Foreground = $script:BrushWhite
    }

    $compactCPU.Text = ("CPU {0:0}%" -f $cpuLoad)
    $compactGPU.Text = ("GPU {0:0}%" -f [double]$gpuLoad)
    $compactRAM.Text = ("RAM {0:0}%" -f $ramLoad)

    $cpuBrush = Get-UsageBrush $cpuLoad
    $gpuBrush = Get-UsageBrush ([double]$gpuLoad)
    $ramBrush = Get-UsageBrush $ramLoad

    $compactCPU.Foreground = $cpuBrush
    $compactGPU.Foreground = $gpuBrush
    $compactRAM.Foreground = $ramBrush
    $cpuLoadText.Foreground = $cpuBrush
    $gpuLoadText.Foreground = $gpuBrush
    $ramLoadText.Foreground = $ramBrush

    $cpuWText.Text = ("{0}{1:0} W" -f $cpuPrefix,$cpuW)
    $gpuWText.Text = ("{0}{1:0} W" -f $gpuPrefix,$gpuW)
    $ramWText.Text = ("~{0:0} W" -f $ramW)
    $powerText.Text = ("~{0:0} W" -f $wallW)
    $currentCostText.Text = ("£{0:0.000} / h" -f $currentCostPerHour)
    $compactPower.Text = ("~{0:0}W" -f $wallW)
    $compactCost.Text = ("£{0:0.000}/h" -f $currentCostPerHour)

    $compactDate.Text = $now.ToString("ddd dd MMM", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
    $compactTime.Text = $now.ToString("HH:mm")
    if ($null -eq $script:OutsideTempC) {
        $compactTemp.Text = "OUT --°C"
    } else {
        $compactTemp.Text = ("OUT {0:0}°C" -f [double]$script:OutsideTempC)
    }

    $monthKey = $now.ToString("yyyy-MM")
    $monthTotals = Get-HistoryTotals -Prefix $monthKey
    $monthName = $now.ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
    $compactMonthTotal.Text = ("{0} £{1:0.00}" -f $monthName,[double]$monthTotals.CostGBP)

    $rateText.Text = ("RATE {0:0.00}p/kWh" -f [double]$script:Config.ratePencePerKwh)

    $hours = [math]::Floor($elapsed.TotalHours)
    $durationText.Text = ("{0:00}:{1:00}:{2:00}" -f $hours,$elapsed.Minutes,$elapsed.Seconds)

    if ($cost -lt 1) { $costText.Text = ("£{0:0.000}" -f $cost) }
    else { $costText.Text = ("£{0:0.00}" -f $cost) }

    $fpsTray = if ($null -eq $script:CurrentFps) { "--" } else { "{0:0}" -f [double]$script:CurrentFps }
    $tray.Text = ("FPS {0} | ~{1:0}W | £{2:0.000}/h" -f $fpsTray,$wallW,$currentCostPerHour)

    $fpsStatusItem.Text = ("FPS status: {0}" -f $script:FpsStatus)

    if ([string]::IsNullOrWhiteSpace($script:FpsSource)) {
        $fpsSourceItem.Text = "FPS source: --"
    } else {
        $fpsSourceItem.Text = ("FPS source: {0}" -f $script:FpsSource)
    }
})

$window.Add_Closing({
    if (-not $script:Exiting) {
        $_.Cancel = $true
        $window.Hide()
        $showItem.Text = "Show widget"
        return
    }
    try {
        $timer.Stop()
        Save-UsageHistory
        Stop-FpsCapture
        try { if ($script:WeatherClient) { $script:WeatherClient.Dispose() } } catch {}
        if ($script:LhmOK -and $script:Computer) { $script:Computer.Close() }
        $tray.Visible = $false
        $tray.Dispose()
        $script:Config.windowLeft = [math]::Round($window.Left)
        $script:Config.windowTop = [math]::Round($window.Top)
        Save-Config
        if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() }
    } catch {}
})

$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        [ClickThroughHelper]::SetClickThrough($hwnd, [bool]$script:Config.clickThrough)
    } catch {}
})

$timer.Start()
[void]$window.ShowDialog()
