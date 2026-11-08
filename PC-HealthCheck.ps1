#requires -Version 5.1
<#
  PC-HealthCheck.ps1
  ------------------
  A terminal-based PC health check and troubleshooting tool for Windows.
  Everything is printed directly in the console window.

  Checks:
    - System overview (motherboard, CPU, RAM, GPU, BIOS, Windows, uptime)
    - Storage: free space + SMART health + SMART details (temp, power-on hours, wear)
    - Temperatures (GPU via nvidia-smi, CPU if the firmware exposes it)
    - Current performance (CPU load, heaviest processes)
    - Windows Update
    - Program updates via winget
    - Security (Defender, real-time protection, signatures, firewall)
    - Devices with driver problems
    - Event log (last 7 days)
    - Network: MAC addresses, Ethernet configuration, internet, DNS
    - Battery health (laptops)
    - Startup programs
    - Cleanup: counts temp files/cache and can clean them after confirmation
    - History: saves every run and compares with the previous one

  PRIVACY: This script runs 100 % locally. It sends nothing anywhere.
  The only network activity is: a ping to 8.8.8.8, one DNS lookup,
  a Windows Update query and a winget query (Microsoft servers).
  See README.md for the full security and privacy explanation.
#>

param(
    [switch]$SkipCleanup   # run with -SkipCleanup to skip the cleanup section
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- helpers
$issues = New-Object System.Collections.Generic.List[object]
function Add-Issue([string]$Severity, [string]$Area, [string]$Message, [string]$Action) {
    $script:issues.Add([pscustomobject]@{
        Severity = $Severity; Area = $Area; Message = $Message; Action = $Action
    })
}

function Section([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
}

function StatusLine([string]$Status, [string]$Text) {
    switch ($Status) {
        'OK'      { Write-Host "  [ OK ]      " -ForegroundColor Green  -NoNewline }
        'Warning' { Write-Host "  [ WARNING ] " -ForegroundColor Yellow -NoNewline }
        'Problem' { Write-Host "  [ PROBLEM ] " -ForegroundColor Red    -NoNewline }
        default   { Write-Host "  [ INFO ]    " -ForegroundColor Gray   -NoNewline }
    }
    Write-Host $Text
}

function KV([string]$Label, [string]$Value) {
    Write-Host ("  {0,-30} " -f $Label) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value
}

function Get-FolderSizeMB([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [math]::Round($sum / 1MB, 0)
    } catch { return 0 }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

# Values that are saved to the history log
$wuPending      = -1
$critCount      = 0
$errCount       = 0
$cpuLoad        = $null
$diskFreeMap    = @{}
$programUpdates = 0

# ---------------------------------------------------------------- header
Clear-Host
Write-Host ""
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host "  #        PC HEALTH CHECK  -  TERMINAL        #" -ForegroundColor Cyan
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Computer: {0}   Date: {1}" -f [Environment]::MachineName, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
if ($isAdmin) { Write-Host "  Running as: administrator" -ForegroundColor DarkGray }
else          { Write-Host "  Running as: standard user (a few checks need admin rights)" -ForegroundColor DarkGray }
Write-Host "  The check normally takes 1-3 minutes..."

# ---------------------------------------------------------------- 1. System overview
Section "SYSTEM OVERVIEW"
$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpus = Get-CimInstance Win32_VideoController
$bios = Get-CimInstance Win32_BIOS
$bb   = Get-CimInstance Win32_BaseBoard

$uptime     = (Get-Date) - $os.LastBootUpTime
$uptimeStr  = "{0} days, {1} hours, {2} minutes" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
$totalRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$freeRamGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$ramPctFree = [math]::Round(100 * $freeRamGB / $totalRamGB, 0)

KV "Manufacturer / model" ("{0} {1}" -f $cs.Manufacturer, $cs.Model)
KV "Motherboard" ("{0} {1}" -f $bb.Manufacturer, $bb.Product)
KV "Operating system" ("{0} ({1})" -f $os.Caption, $os.OSArchitecture)
KV "Windows version / build" ("{0} / {1}" -f $os.Version, $os.BuildNumber)
KV "Installed" $os.InstallDate.ToString("yyyy-MM-dd")
KV "Last reboot" ($os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm") + "  (uptime: $uptimeStr)")
KV "Processor" $cpu.Name.Trim()
KV "Cores / threads" ("{0} / {1}" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
KV "RAM total / free" ("{0} GB / {1} GB free ({2} %)" -f $totalRamGB, $freeRamGB, $ramPctFree)
$ramModules = Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    "{0} GB @ {1} MHz" -f ($_.Capacity/1GB), $_.Speed
}
KV "RAM modules" ($ramModules -join "  +  ")
try {
    $memArray = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop | Select-Object -First 1
    $usedSlots = @($ramModules).Count
    if ($memArray.MemoryDevices -gt 0) {
        KV "RAM slots" ("{0} of {1} in use" -f $usedSlots, $memArray.MemoryDevices)
    }
} catch {}
foreach ($g in $gpus) {
    $drvDate = ""
    if ($g.DriverDate) { $drvDate = $g.DriverDate.ToString("yyyy-MM-dd") }
    KV "Graphics card" ("{0}  (driver: {1})" -f $g.Name, $drvDate)
    if ($g.DriverDate -and ((Get-Date) - $g.DriverDate).Days -gt 540) {
        Add-Issue 'Warning' 'Graphics' ("The graphics driver for {0} is from {1}." -f $g.Name, $drvDate) 'Update the graphics driver from the manufacturer (Nvidia/AMD/Intel).'
    }
}
KV "BIOS" ("{0} ({1})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate.ToString("yyyy-MM-dd"))

if ($uptime.TotalDays -gt 7) {
    Add-Issue 'Warning' 'System' ("The computer has been running for {0} days without a reboot." -f [math]::Round($uptime.TotalDays,1)) 'Restart the computer to clear memory and finish pending updates.'
    StatusLine 'Warning' ("Long uptime: {0} days without a reboot" -f [math]::Round($uptime.TotalDays,1))
} else {
    StatusLine 'OK' "Uptime is normal"
}
if ($ramPctFree -lt 12) {
    Add-Issue 'Warning' 'Memory' ("Only {0} GB ({1} %) of RAM is free right now." -f $freeRamGB, $ramPctFree) 'Close programs you are not using, or consider more RAM if this happens often.'
    StatusLine 'Warning' "Low free memory ($ramPctFree %)"
}

# ---------------------------------------------------------------- 2. Storage + SMART details
Section "STORAGE (free space + disk health)"
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")) {
    if (-not $d.Size -or $d.Size -eq 0) { continue }
    $sizeGB  = [math]::Round($d.Size/1GB, 1)
    $freeGB  = [math]::Round($d.FreeSpace/1GB, 1)
    $freePct = [math]::Round(100 * $d.FreeSpace / $d.Size, 0)
    $diskFreeMap[$d.DeviceID] = $freeGB
    if ($freePct -lt 8) {
        StatusLine 'Problem' ("Drive {0}: only {1} GB free of {2} GB ({3} %)" -f $d.DeviceID, $freeGB, $sizeGB, $freePct)
        Add-Issue 'Problem' 'Storage' ("Drive {0} has only {1} % free space ({2} GB)." -f $d.DeviceID, $freePct, $freeGB) 'Free up space soon: run Disk Cleanup (cleanmgr), empty the recycle bin and move large files.'
    } elseif ($freePct -lt 15) {
        StatusLine 'Warning' ("Drive {0}: {1} GB free of {2} GB ({3} %)" -f $d.DeviceID, $freeGB, $sizeGB, $freePct)
        Add-Issue 'Warning' 'Storage' ("Drive {0} is getting full ({1} % free)." -f $d.DeviceID, $freePct) 'Free up space soon so Windows and updates keep working properly.'
    } else {
        StatusLine 'OK' ("Drive {0}: {1} GB free of {2} GB ({3} %)" -f $d.DeviceID, $freeGB, $sizeGB, $freePct)
    }
}
try {
    $smartDetails = $false
    foreach ($p in (Get-PhysicalDisk -ErrorAction Stop)) {
        if ($p.HealthStatus -eq 'Healthy') {
            StatusLine 'OK' ("{0} ({1}, {2:N0} GB) - SMART: Healthy" -f $p.FriendlyName, $p.MediaType, ($p.Size/1GB))
        } else {
            StatusLine 'Problem' ("{0} - SMART: {1}" -f $p.FriendlyName, $p.HealthStatus)
            Add-Issue 'Problem' 'Storage' ("The disk '{0}' reports SMART status {1}." -f $p.FriendlyName, $p.HealthStatus) 'Back up important files immediately - the disk may be about to fail. Consider replacing it.'
        }
        # SMART details: temperature, power-on hours, wear (requires admin)
        $rc = $p | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($rc) {
            $smartDetails = $true
            $detail = @()
            if ($null -ne $rc.PowerOnHours) {
                $years = [math]::Round($rc.PowerOnHours / 24 / 365, 1)
                $detail += "power-on {0:N0} hours ({1} years)" -f $rc.PowerOnHours, $years
            }
            if ($null -ne $rc.Wear) {
                $detail += "wear {0} %" -f $rc.Wear
                if ($rc.Wear -ge 80) {
                    Add-Issue 'Warning' 'Storage' ("The disk '{0}' has used {1} % of its estimated lifespan." -f $p.FriendlyName, $rc.Wear) 'The disk is getting worn - make sure your backups work and plan for a replacement.'
                }
            }
            if ($null -ne $rc.Temperature) {
                $detail += "temp {0} C" -f $rc.Temperature
                if ($rc.Temperature -ge 70) {
                    Add-Issue 'Problem' 'Temperature' ("The disk '{0}' is {1} C hot." -f $p.FriendlyName, $rc.Temperature) 'Check the airflow in your case - the disk is running too hot.'
                }
            }
            if ($detail.Count -gt 0) {
                Write-Host ("              " + ($detail -join "  |  ")) -ForegroundColor DarkGray
            }
        }
    }
    if (-not $smartDetails) {
        if (-not $isAdmin) {
            StatusLine 'Info' "SMART details (power-on hours, wear, disk temperature) require admin rights"
            Write-Host "    Run 'Run-PC-HealthCheck-Admin.cmd' to see them." -ForegroundColor DarkGray
        } else {
            StatusLine 'Info' "SMART details are not available for this disk"
        }
    }
} catch {
    StatusLine 'Info' "Could not read SMART status"
}

# ---------------------------------------------------------------- 3. Temperatures
Section "TEMPERATURES"
$foundTemp = $false

# GPU via nvidia-smi
$nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $nvsmi -and (Test-Path "$env:SystemRoot\System32\nvidia-smi.exe")) {
    $nvsmi = "$env:SystemRoot\System32\nvidia-smi.exe"
}
if ($nvsmi) {
    try {
        $gpuData = @(& $nvsmi --query-gpu=name,temperature.gpu,fan.speed,utilization.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>$null)
        foreach ($line in $gpuData) {
            $cols = $line -split ',' | ForEach-Object { $_.Trim() }
            if ($cols.Count -ge 6 -and $cols[1] -match '^\d+$') {
                $foundTemp = $true
                $gpuName = $cols[0]; $gpuTemp = [int]$cols[1]; $gpuFan = $cols[2]
                $gpuUtil = $cols[3]; $gpuPow = $cols[4]; $gpuLimit = $cols[5]
                KV $gpuName ("{0} C  |  fan {1} %  |  load {2} %  |  {3} / {4} W" -f $gpuTemp, $gpuFan, $gpuUtil, $gpuPow, $gpuLimit)
                if ($gpuTemp -ge 90) {
                    StatusLine 'Problem' "$gpuName is $gpuTemp C - very hot!"
                    Add-Issue 'Problem' 'Temperature' "The graphics card ($gpuName) is $gpuTemp C hot." 'Close demanding programs, check that the fans spin and that the case has good airflow. Clean dust from the cooler if needed.'
                } elseif ($gpuTemp -ge 83) {
                    StatusLine 'Warning' "$gpuName is $gpuTemp C (high temp)"
                    Add-Issue 'Warning' 'Temperature' "The graphics card ($gpuName) is $gpuTemp C - high even under load." 'Keep an eye on the temperature while gaming; consider better case cooling or a custom fan curve.'
                } else {
                    StatusLine 'OK' "$gpuName has a normal temperature ($gpuTemp C)"
                }
            }
        }
    } catch {}
}

# CPU temperature (only works if the firmware exposes it to Windows)
try {
    $tz = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    foreach ($t in $tz) {
        $celsius = [math]::Round(($t.CurrentTemperature / 10) - 273.15, 0)
        if ($celsius -gt 0 -and $celsius -lt 130) {
            $foundTemp = $true
            KV ("CPU zone: " + $t.InstanceName) ("{0} C" -f $celsius)
            if ($celsius -ge 95) {
                StatusLine 'Problem' "CPU temperature $celsius C - critical!"
                Add-Issue 'Problem' 'Temperature' "The processor is $celsius C hot." 'Check the CPU cooler immediately - risk of thermal shutdown or damage.'
            } elseif ($celsius -ge 85) {
                StatusLine 'Warning' "CPU temperature $celsius C"
                Add-Issue 'Warning' 'Temperature' "The processor is $celsius C hot." 'Check thermal paste and fans; clean out dust if needed.'
            }
        }
    }
} catch {}

if (-not $foundTemp) {
    if ($nvsmi) {
        StatusLine 'Info' "nvidia-smi was found but could not read GPU data right now (NVML error)"
        Write-Host "    GPU temperature usually works when you run the tool in your own terminal window." -ForegroundColor DarkGray
    } else {
        StatusLine 'Info' "Temperatures could not be read (the firmware does not expose them to Windows)"
        Write-Host "    Tip: HWiNFO or NZXT CAM show exact temperatures." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- 4. Performance
Section "PERFORMANCE RIGHT NOW"
try {
    $cpuLoad = [math]::Round(((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average), 0)
    KV "CPU load" ("{0} %" -f $cpuLoad)
} catch {}
KV "Free memory" ("{0} GB of {1} GB" -f $freeRamGB, $totalRamGB)

Write-Host ""
Write-Host "  Most memory used (top 5):" -ForegroundColor DarkGray
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
    ForEach-Object { Write-Host ("    {0,-32} {1,8:N0} MB" -f $_.Name, ($_.WorkingSet64/1MB)) }

# ---------------------------------------------------------------- 5. Windows Update
Section "WINDOWS UPDATE"
Write-Host "  Searching for updates (may take up to a minute)..." -ForegroundColor DarkGray
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $wuPending = $result.Updates.Count
    if ($wuPending -eq 0) {
        StatusLine 'OK' "No pending updates"
    } else {
        StatusLine 'Warning' "$wuPending update(s) waiting to be installed:"
        $shown = 0
        foreach ($u in $result.Updates) {
            if ($shown -ge 10) { Write-Host ("    ... and {0} more" -f ($wuPending - 10)); break }
            Write-Host ("    - {0}" -f $u.Title)
            $shown++
        }
        Add-Issue 'Warning' 'Windows Update' "$wuPending update(s) are waiting to be installed." 'Go to Settings > Windows Update and install them, then restart the computer.'
    }
} catch {
    StatusLine 'Info' "Could not check Windows Update right now"
}

# ---------------------------------------------------------------- 6. Program updates (winget)
Section "PROGRAM UPDATES"
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd -and (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")) {
    $wingetCmd = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
}
if (-not $wingetCmd) {
    StatusLine 'Info' "winget was not found - cannot check for program updates"
} else {
    Write-Host "  Searching for program updates (may take 30-60 seconds)..." -ForegroundColor DarkGray
    try {
        $wLines = @(& $wingetCmd upgrade --disable-interactivity --accept-source-agreements 2>$null |
                    Where-Object { $_ -notmatch '^\s*$' })
        # Find the header row (above the dashed line) and read column positions from it
        $sepIdx = -1
        for ($i = 0; $i -lt $wLines.Count; $i++) {
            if ($wLines[$i] -match '^-{20,}$') { $sepIdx = $i; break }
        }
        $upgrades = @()
        if ($sepIdx -gt 0) {
            $starts = [regex]::Matches($wLines[$sepIdx - 1], '\S+') | ForEach-Object { $_.Index }
            for ($i = $sepIdx + 1; $i -lt $wLines.Count; $i++) {
                $line = $wLines[$i]
                if ($line -match 'upgrade' -and $line -match 'avail') { continue }
                $colsOut = @()
                for ($c = 0; $c -lt $starts.Count; $c++) {
                    $s = $starts[$c]
                    if ($line.Length -le $s) { $colsOut += ""; continue }
                    if ($c -eq $starts.Count - 1) {
                        $colsOut += $line.Substring($s).Trim()
                    } else {
                        $take = [math]::Min($starts[$c+1] - $s, $line.Length - $s)
                        if ($take -gt 0) { $colsOut += $line.Substring($s, $take).Trim() } else { $colsOut += "" }
                    }
                }
                if ($colsOut.Count -ge 4 -and $colsOut[0] -and $colsOut[3]) {
                    $upgrades += [pscustomobject]@{ Name=$colsOut[0]; Id=$colsOut[1]; Version=$colsOut[2]; Available=$colsOut[3] }
                }
            }
        }
        $programUpdates = $upgrades.Count
        if ($programUpdates -eq 0) {
            StatusLine 'OK' "All programs are up to date"
        } else {
            StatusLine 'Warning' "$programUpdates programs have updates available:"
            $shown = 0
            foreach ($up in $upgrades) {
                if ($shown -ge 15) { Write-Host ("    ... and {0} more" -f ($programUpdates - 15)); break }
                Write-Host ("    - {0}  ({1} -> {2})" -f $up.Name, $up.Version, $up.Available)
                $shown++
            }
            Write-Host ""
            Write-Host "    Update everything with:  winget upgrade --all" -ForegroundColor DarkGray
            Add-Issue 'Warning' 'Programs' "$programUpdates installed programs have updates available." 'Run "winget upgrade --all" in a terminal, or update the programs one at a time.'
        }
    } catch {
        StatusLine 'Info' "Could not fetch program updates"
    }
}

# ---------------------------------------------------------------- 7. Security
Section "SECURITY (antivirus + firewall)"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.RealTimeProtectionEnabled) {
        StatusLine 'OK' "Antivirus real-time protection is ON"
    } else {
        StatusLine 'Problem' "Real-time protection is TURNED OFF"
        Add-Issue 'Problem' 'Security' "Antivirus real-time protection is TURNED OFF." 'Turn on real-time protection in Windows Security (Virus & threat protection).'
    }
    $sigAge = $null
    if ($null -ne $mp.AntivirusSignatureAge) { $sigAge = $mp.AntivirusSignatureAge }
    elseif ($mp.AntivirusSignatureLastUpdated) { $sigAge = ((Get-Date) - $mp.AntivirusSignatureLastUpdated).Days }
    if ($null -ne $sigAge) {
        if ($sigAge -gt 7) {
            StatusLine 'Warning' "Virus signatures are $sigAge days old"
            Add-Issue 'Warning' 'Security' "Virus signatures are $sigAge days old." 'Open Windows Security and click "Check for updates" under Virus & threat protection.'
        } else {
            StatusLine 'OK' "Virus signatures up to date ($sigAge days old)"
        }
    }
    if ($mp.QuickScanStartTime) {
        $scanAge = ((Get-Date) - $mp.QuickScanStartTime).Days
        if ($scanAge -gt 30) {
            StatusLine 'Warning' "No virus scan in $scanAge days"
            Add-Issue 'Warning' 'Security' "No virus scan has run in $scanAge days." 'Run a quick scan in Windows Security.'
        } else {
            StatusLine 'OK' ("Last quick scan: {0:yyyy-MM-dd}" -f $mp.QuickScanStartTime)
        }
    }
} catch {
    try {
        $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
        StatusLine 'Info' ("Antivirus products: " + (($av | ForEach-Object { $_.displayName }) -join ", "))
    } catch {
        StatusLine 'Info' "Could not read antivirus status"
    }
}
try {
    $fwOff = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
    if ($fwOff.Count -eq 0) {
        StatusLine 'OK' "Firewall is on (all profiles)"
    } else {
        StatusLine 'Problem' ("Firewall is OFF for: " + (($fwOff | ForEach-Object { $_.Name }) -join ", "))
        Add-Issue 'Problem' 'Security' ("The Windows firewall is off for profile(s): " + (($fwOff | ForEach-Object { $_.Name }) -join ", ")) 'Turn on the firewall in Windows Security > Firewall & network protection.'
    }
} catch {
    StatusLine 'Info' "Could not read firewall status"
}

# ---------------------------------------------------------------- 8. Devices & drivers
Section "DEVICES & DRIVERS"
try {
    $badDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($badDevs.Count -eq 0) {
        StatusLine 'OK' "All devices are working"
    } else {
        foreach ($d in $badDevs) {
            $name = $d.Name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "(unknown device)" }
            $hint = switch ($d.ConfigManagerErrorCode) {
                28 { "driver missing" }
                22 { "device is disabled" }
                10 { "device cannot start" }
                43 { "device reported a failure" }
                default { "error code $($d.ConfigManagerErrorCode)" }
            }
            StatusLine 'Problem' ("{0} - {1}" -f $name, $hint)
            Add-Issue 'Problem' 'Drivers' ("The device '{0}' has a problem ({1})." -f $name, $hint) 'Open Device Manager, right-click the device and choose "Update driver" (or "Enable device" if it is disabled).'
        }
    }
} catch {
    StatusLine 'Info' "Could not check devices"
}

# ---------------------------------------------------------------- 9. Event log
Section "EVENT LOG (last 7 days)"
try {
    $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 1000 -ErrorAction Stop)
    $critCount = @($ev | Where-Object { $_.Level -eq 1 }).Count
    $errCount  = @($ev | Where-Object { $_.Level -eq 2 }).Count
    if ($critCount -gt 0) {
        StatusLine 'Problem' "$critCount critical errors and $errCount errors in total"
        Add-Issue 'Problem' 'Event log' "$critCount critical errors were logged in the last 7 days." 'See the list below. Recurring critical errors (e.g. Kernel-Power, disk errors) should be investigated further.'
    } elseif ($errCount -gt 50) {
        StatusLine 'Warning' "$errCount errors in total (none critical)"
        Add-Issue 'Warning' 'Event log' "$errCount errors were logged in the last 7 days." 'Many errors can indicate software or driver problems. See the most common errors below.'
    } else {
        StatusLine 'OK' "$errCount errors in total, none critical"
    }
    if ($ev.Count -gt 0) {
        Write-Host ""
        Write-Host "  Most common errors:" -ForegroundColor DarkGray
        $ev | Group-Object Id, ProviderName | Sort-Object Count -Descending | Select-Object -First 5 |
            ForEach-Object {
                $parts = $_.Name -split ', '
                Write-Host ("    {0,4} x  {1}  (ID {2})" -f $_.Count, $parts[1], $parts[0])
            }
    }
} catch {
    StatusLine 'Info' "Could not read the event log"
}

# ---------------------------------------------------------------- 10. Network (MAC + Ethernet config)
Section "NETWORK (MAC addresses & Ethernet configuration)"
$physAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Status -Descending)
foreach ($a in $physAdapters) {
    $statusTxt = if ($a.Status -eq 'Up') { "connected" } else { "not connected" }
    Write-Host ""
    Write-Host ("  {0}  ({1})" -f $a.Name, $a.InterfaceDescription) -ForegroundColor White
    KV "Status / speed" ("{0}  /  {1}" -f $statusTxt, $a.LinkSpeed)
    KV "MAC address" $a.MacAddress
    if ($a.Status -eq 'Up') {
        $ipconf = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        $ipv4 = ($ipconf.IPv4Address | Select-Object -First 1)
        if ($ipv4) {
            KV "IPv4 address" ("{0}/{1}" -f $ipv4.IPAddress, $ipv4.PrefixLength)
        }
        $gw = ($ipconf.IPv4DefaultGateway | Select-Object -First 1)
        if ($gw) { KV "Gateway (router)" $gw.NextHop }
        if ($ipconf.DNSServer) {
            $dnsList = ($ipconf.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object { $_.ServerAddresses }) -join ", "
            if ($dnsList) { KV "DNS servers" $dnsList }
        }
        $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        if ($dhcp) { KV "DHCP" $dhcp }
    }
}
Write-Host ""
$pingOk = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
$dnsOk = $false
try { Resolve-DnsName -Name "www.microsoft.com" -Type A -ErrorAction Stop | Out-Null; $dnsOk = $true } catch {}
if ($pingOk) { StatusLine 'OK' "Internet connection works" }
else {
    StatusLine 'Problem' "No internet connection"
    Add-Issue 'Problem' 'Network' "No internet connection (ping failed)." 'Restart the router, check cables/Wi-Fi and run the Windows network troubleshooter.'
}
if ($pingOk -and -not $dnsOk) {
    StatusLine 'Warning' "DNS is not working"
    Add-Issue 'Warning' 'Network' "Internet responds but DNS does not work - websites may be hard to reach." 'Try switching DNS to 1.1.1.1 or 8.8.8.8 in the network settings.'
} elseif ($dnsOk) {
    StatusLine 'OK' "DNS resolution works"
}

# ---------------------------------------------------------------- 11. Battery
$batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($batt) {
    Section "BATTERY"
    KV "Charge" ("{0} %" -f $batt.EstimatedChargeRemaining)
    try {
        $full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
        $design = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop
        if ($full.FullChargedCapacity -and $design.DesignedCapacity) {
            $health = [math]::Round(100 * $full.FullChargedCapacity / $design.DesignedCapacity, 0)
            if ($health -lt 60) {
                StatusLine 'Problem' "Battery health: $health % of original capacity"
                Add-Issue 'Problem' 'Battery' "The battery only holds $health % of its original capacity." 'Consider replacing the battery. Run "powercfg /batteryreport" for details.'
            } elseif ($health -lt 80) {
                StatusLine 'Warning' "Battery health: $health % of original capacity"
                Add-Issue 'Warning' 'Battery' "The battery has worn down to $health % of original capacity." 'The battery works but holds less charge than when new.'
            } else {
                StatusLine 'OK' "Battery health: $health % of original capacity"
            }
        }
    } catch {
        StatusLine 'Info' "Battery health could not be calculated (run powercfg /batteryreport)"
    }
}

# ---------------------------------------------------------------- 12. Startup programs
Section "STARTUP PROGRAMS"
try {
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop | Where-Object { $_.User -notlike '*default*' })
    if ($startup.Count -gt 15) {
        StatusLine 'Warning' "$($startup.Count) programs start automatically with Windows"
        Add-Issue 'Warning' 'Startup' "$($startup.Count) programs start automatically with Windows - this can slow down boot." 'Open Task Manager > Startup and disable programs you do not need.'
    } else {
        StatusLine 'OK' "$($startup.Count) programs start automatically"
    }
    $shown = 0
    foreach ($s in ($startup | Sort-Object Name)) {
        if ($shown -ge 20) { Write-Host ("    ... and {0} more" -f ($startup.Count - 20)); break }
        Write-Host ("    - {0}" -f $s.Name)
        $shown++
    }
} catch {
    StatusLine 'Info' "Could not read startup programs"
}

# ---------------------------------------------------------------- 13. Cleanup
$cleanedMB = 0
if (-not $SkipCleanup) {
    Section "CLEANUP (temp files & cache)"
    Write-Host "  Calculating space that can be freed..." -ForegroundColor DarkGray

    $cleanTargets = @()
    $cleanTargets += [pscustomobject]@{ Name="Your temp files";          Path=$env:TEMP;                                  NeedsAdmin=$false }
    $cleanTargets += [pscustomobject]@{ Name="Windows temp files";       Path="$env:SystemRoot\Temp";                     NeedsAdmin=$true }
    $cleanTargets += [pscustomobject]@{ Name="Windows Update cache";     Path="$env:SystemRoot\SoftwareDistribution\Download"; NeedsAdmin=$true }
    $cleanTargets += [pscustomobject]@{ Name="Memory dump files";        Path="$env:SystemRoot\Minidump";                 NeedsAdmin=$true }
    $cleanTargets += [pscustomobject]@{ Name="Windows log files (CBS)";  Path="$env:SystemRoot\Logs\CBS";                 NeedsAdmin=$true }

    $totalMB = 0
    foreach ($t in $cleanTargets) {
        $mb = Get-FolderSizeMB $t.Path
        $t | Add-Member -NotePropertyName MB -NotePropertyValue $mb -Force
        $totalMB += $mb
        $adminMark = ""
        if ($t.NeedsAdmin -and -not $isAdmin) { $adminMark = "  (requires admin)" }
        KV $t.Name ("{0:N0} MB{1}" -f $mb, $adminMark)
    }
    # Recycle bin
    $rbMB = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $rbItems = $shell.Namespace(0xA).Items()
        foreach ($item in $rbItems) { $rbMB += $item.Size }
        $rbMB = [math]::Round($rbMB / 1MB, 0)
    } catch {}
    $totalMB += $rbMB
    KV "Recycle bin" ("{0:N0} MB" -f $rbMB)

    Write-Host ""
    if ($totalMB -lt 100) {
        StatusLine 'OK' ("Only {0:N0} MB of junk files - nothing to clean" -f $totalMB)
    } else {
        StatusLine 'Info' ("About {0:N1} GB can be freed in total" -f ($totalMB / 1024))
        if ($totalMB -gt 2048) {
            Add-Issue 'Warning' 'Cleanup' ("There is about {0:N1} GB of temp files and junk on the disk." -f ($totalMB / 1024)) 'Clean via this tool (answer Y below) or run Windows Disk Cleanup.'
        }
        Write-Host ""
        $answer = Read-Host "  Clean now? Files in use are skipped. Only the folders listed above are touched. (Y/N)"
        if ($answer -match '^[YyJj]') {
            foreach ($t in $cleanTargets) {
                if ($t.NeedsAdmin -and -not $isAdmin) {
                    Write-Host ("    Skipping {0} (requires admin)" -f $t.Name) -ForegroundColor DarkGray
                    continue
                }
                if (Test-Path $t.Path) {
                    $before = $t.MB
                    Get-ChildItem $t.Path -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    $after = Get-FolderSizeMB $t.Path
                    $freed = $before - $after
                    $cleanedMB += $freed
                    Write-Host ("    {0}: {1:N0} MB cleaned" -f $t.Name, $freed) -ForegroundColor Green
                }
            }
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                $cleanedMB += $rbMB
                Write-Host ("    Recycle bin: {0:N0} MB emptied" -f $rbMB) -ForegroundColor Green
            } catch {
                Write-Host "    Recycle bin could not be emptied" -ForegroundColor DarkGray
            }
            Write-Host ""
            StatusLine 'OK' ("Total cleaned: {0:N0} MB" -f $cleanedMB)
        } else {
            Write-Host "  OK, nothing was cleaned." -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------- 14. History & comparison
Section "HISTORY & COMPARISON"
$probCount = @($issues | Where-Object Severity -eq 'Problem').Count
$warnCount = @($issues | Where-Object Severity -eq 'Warning').Count

$histDir  = Join-Path $scriptDir "history"
$histFile = Join-Path $histDir "history.jsonl"
$prev = $null
if (Test-Path $histFile) {
    $lastLine = (Get-Content $histFile -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
    if ($lastLine) { try { $prev = $lastLine | ConvertFrom-Json } catch {} }
}

if ($prev) {
    KV "Previous run" $prev.Date
    function Show-Delta([string]$Label, [double]$Now, [double]$Before, [string]$Unit, [bool]$LowerIsBetter) {
        $diff = [math]::Round($Now - $Before, 1)
        $arrow = "="
        $col = 'Gray'
        if ($diff -gt 0) { $arrow = "+$diff"; $col = if ($LowerIsBetter) {'Yellow'} else {'Green'} }
        if ($diff -lt 0) { $arrow = "$diff"; $col = if ($LowerIsBetter) {'Green'} else {'Yellow'} }
        Write-Host ("  {0,-30} " -f $Label) -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0} {1}  (" -f $Now, $Unit) -NoNewline
        Write-Host $arrow -ForegroundColor $col -NoNewline
        Write-Host " since then)"
    }
    foreach ($key in $diskFreeMap.Keys) {
        $beforeVal = $null
        try { $beforeVal = [double]($prev.DiskFree.$key) } catch {}
        if ($null -ne $beforeVal) {
            Show-Delta ("Free on $key") $diskFreeMap[$key] $beforeVal "GB" $false
        }
    }
    if ($null -ne $prev.FreeRAM_GB)      { Show-Delta "Free RAM" $freeRamGB ([double]$prev.FreeRAM_GB) "GB" $false }
    if ($null -ne $prev.Problems)        { Show-Delta "Problems" $probCount ([double]$prev.Problems) "" $true }
    if ($null -ne $prev.Warnings)        { Show-Delta "Warnings" $warnCount ([double]$prev.Warnings) "" $true }
    if ($null -ne $prev.CriticalEvents)  { Show-Delta "Critical errors (7 days)" $critCount ([double]$prev.CriticalEvents) "" $true }
} else {
    StatusLine 'Info' "This is the first run - history is saved from now on"
}

# Save this run
try {
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    $entry = [ordered]@{
        Date                  = (Get-Date -Format "yyyy-MM-dd HH:mm")
        DiskFree              = $diskFreeMap
        FreeRAM_GB            = $freeRamGB
        CPU_Load_Percent      = $cpuLoad
        PendingWindowsUpdates = $wuPending
        ProgramUpdates        = $programUpdates
        CriticalEvents        = $critCount
        ErrorEvents           = $errCount
        Problems              = $probCount
        Warnings              = $warnCount
        CleanedMB             = $cleanedMB
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $histFile -Encoding UTF8
    Write-Host ""
    Write-Host ("  Run saved to: history\history.jsonl") -ForegroundColor DarkGray
} catch {}

# ---------------------------------------------------------------- Summary + action list
Section "SUMMARY"

if ($probCount -gt 0) {
    Write-Host ""
    Write-Host "  *** PROBLEMS FOUND ***" -ForegroundColor Red
    Write-Host "  $probCount problem(s) and $warnCount warning(s) should be fixed." -ForegroundColor Red
} elseif ($warnCount -gt 0) {
    Write-Host ""
    Write-Host "  *** A FEW WARNINGS ***" -ForegroundColor Yellow
    Write-Host "  The computer is fine overall, but there are $warnCount things worth looking at." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  *** EVERYTHING LOOKS GOOD - no problems found! ***" -ForegroundColor Green
}

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  ACTION LIST:" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62))
    $nr = 0
    foreach ($i in ($issues | Sort-Object @{Expression={ switch ($_.Severity) { 'Problem' {0} 'Warning' {1} default {2} } }})) {
        $nr++
        $col = 'Yellow'
        if ($i.Severity -eq 'Problem') { $col = 'Red' }
        Write-Host ("  {0}. [{1}] {2}" -f $nr, $i.Area, $i.Message) -ForegroundColor $col
        Write-Host ("     -> {0}" -f $i.Action) -ForegroundColor Gray
        Write-Host ""
    }
}
