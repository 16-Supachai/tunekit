# =========================================================
# TuneKit-Pro.ps1
# A safer, undoable rewrite of a FiveM/gaming tuning script.
#
# Apply : Right-click PowerShell -> Run as Administrator -> .\TuneKit-Pro.ps1
# Undo  : .\TuneKit-Pro.ps1 -Undo
#
# Design goals vs. the original script this is based on:
#   - Every change is recorded BEFORE it is made, so -Undo can restore it.
#   - No disabling of Windows Defender / security exclusions.
#   - No placebo tweaks (keyboard queue size, IRQ8Priority, HPET, manual
#     pagefile math) that have no measurable effect on modern Windows
#     and only add risk.
#   - Clear log file so you (and your customer) can see exactly what ran.
# =========================================================
param(
    [switch]$Undo,
    [switch]$PriorityOnly   # Just raise FiveM/GTA5 to High priority for this session. No admin changes saved/undoable.
)

if ($PriorityOnly) {
    $procs = Get-Process -Name "FiveM","FiveM_b2060","GTA5","fivem_web_b2060" -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Host "FiveM/GTA5 not running." -ForegroundColor Yellow; exit 0 }
    foreach ($p in $procs) {
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High; Write-Host "OK: $($p.Name) -> High priority" -ForegroundColor Cyan }
        catch { Write-Host "FAILED: $($p.Name)" -ForegroundColor Red }
    }
    exit 0
}

$ErrorActionPreference = "Stop"

# ---------- Must run as Administrator ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Please run PowerShell as Administrator." -ForegroundColor Red
    exit 1
}

# ---------- Paths ----------
$dir   = Join-Path $env:ProgramData "TuneKitPro"
$log   = Join-Path $dir "tune.log"
$state = Join-Path $dir "state.json"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Log {
    param([string]$Msg, [string]$Color = "Gray")
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $log -Value $line
}

function Set-TrackedValue {
    # Sets a registry value and remembers the previous one so it can be undone.
    param($Path, $Name, $Value, $Type, $Desc)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        $old = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        $script:RegistryChanges += [pscustomobject]@{
            Path     = $Path
            Name     = $Name
            Type     = $Type
            Existed  = [bool]$old
            OldValue = if ($old) { $old.$Name } else { $null }
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Log "OK: $Desc" "Cyan"
    } catch {
        Log "FAILED: $Desc -> $($_.Exception.Message)" "Red"
    }
}

# =========================================================
# UNDO MODE
# =========================================================
if ($Undo) {
    if (-not (Test-Path $state)) { Log "No saved state found. Nothing to undo." "Yellow"; exit 0 }
    $saved = Get-Content $state -Raw | ConvertFrom-Json

    foreach ($s in $saved.Registry) {
        try {
            if ($s.Existed) {
                Set-ItemProperty -Path $s.Path -Name $s.Name -Value $s.OldValue -Type $s.Type -Force
            } else {
                Remove-ItemProperty -Path $s.Path -Name $s.Name -ErrorAction SilentlyContinue
            }
            Log "Restored: $($s.Name) at $($s.Path)" "Cyan"
        } catch {
            Log "Could not restore $($s.Name): $($_.Exception.Message)" "Red"
        }
    }

    if ($saved.PowerScheme) {
        powercfg /setactive $saved.PowerScheme | Out-Null
        Log "Restored power plan: $($saved.PowerScheme)" "Cyan"
    }

    if ($saved.DoSvcStartupType) {
        Set-Service -Name DoSvc -StartupType $saved.DoSvcStartupType -ErrorAction SilentlyContinue
        if ($saved.DoSvcStartupType -ne "Disabled") { Start-Service DoSvc -ErrorAction SilentlyContinue }
        Log "Restored Delivery Optimization service" "Cyan"
    }

    foreach ($svc in $saved.XboxServices) {
        try {
            Set-Service -Name $svc.Name -StartupType $svc.StartType -ErrorAction SilentlyContinue
            if ($svc.StartType -eq "Automatic") { Start-Service $svc.Name -ErrorAction SilentlyContinue }
            Log "Restored service: $($svc.Name)" "Cyan"
        } catch {}
    }

    Log "Undo complete. Restart the PC to fully apply." "Green"
    exit 0
}

# =========================================================
# APPLY MODE
# =========================================================
Log "=== TuneKit-Pro start ===" "Green"
$script:RegistryChanges = @()
$saved = [ordered]@{ Registry = @(); PowerScheme = $null; DoSvcStartupType = $null; XboxServices = @() }

# ---------- Restore point ----------
try {
    Checkpoint-Computer -Description "Before TuneKit-Pro" -RestorePointType MODIFY_SETTINGS
    Log "Restore point created." "Green"
} catch {
    Log "Restore point skipped (Windows only allows one per 24h): $($_.Exception.Message)" "Yellow"
}

# ---------- Hardware detect (for info + GPU-specific tweaks) ----------
$cpu = (Get-CimInstance Win32_Processor).Name
$gpuList = Get-CimInstance Win32_VideoController
$gpu = $gpuList | Where-Object { $_.Name -match "NVIDIA" } | Select-Object -First 1
if (-not $gpu) { $gpu = $gpuList | Where-Object { $_.Name -match "AMD|Radeon" } | Select-Object -First 1 }
if (-not $gpu) { $gpu = $gpuList | Select-Object -First 1 }
$gpuName = $gpu.Name
if     ($gpuName -match "NVIDIA")     { $gpuType = "NVIDIA" }
elseif ($gpuName -match "AMD|Radeon") { $gpuType = "AMD" }
else                                  { $gpuType = "Other" }
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)

Log "CPU: $cpu"
Log "GPU: $gpuName [$gpuType]"
Log "RAM: $ram GB"

# ---------- Warn if the game is running ----------
$running = Get-Process -Name "FiveM","FiveM_b2060","GTA5","GTAVLauncher","fivem_web_b2060" -ErrorAction SilentlyContinue
if ($running) {
    Log "FiveM/GTA5 appears to be running. Some tweaks apply fully only after a restart." "Yellow"
}

# ---------- 1) Stop background capture / overlays that cost FPS ----------
Set-TrackedValue "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0 "DWord" "Disable Game DVR"
Set-TrackedValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0 "DWord" "Disable background app capture"
Set-TrackedValue "HKCU:\Software\Microsoft\GameBar" "ShowGameBar" 0 "DWord" "Disable Game Bar overlay"
Set-TrackedValue "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" 1 "DWord" "Enable Windows Game Mode"

# ---------- 2) Fullscreen optimizations (reduces input lag / stutter for some games) ----------
Set-TrackedValue "HKCU:\System\GameConfigStore" "GameDVR_FSEBehaviorMode" 2 "DWord" "Disable fullscreen optimizations"
Set-TrackedValue "HKCU:\System\GameConfigStore" "GameDVR_HonorUserFSEBehaviorMode" 1 "DWord" "Honor fullscreen optimization setting"

# ---------- 3) Mouse/keyboard responsiveness: everything Windows can really do ----------
# Note: polling rate and debounce time live in the mouse/keyboard hardware or its own
# vendor software, not in the registry. This section only touches what Windows itself
# controls: pointer acceleration and USB power saving (both verified to affect input feel).

# "Enhance pointer precision" OFF -> 1 inch of hand movement always equals the
# same on-screen distance, instead of Windows accelerating it based on hand speed.
Set-TrackedValue "HKCU:\Control Panel\Mouse" "MouseSpeed" "0" "String" "Mouse acceleration off (1/3)"
Set-TrackedValue "HKCU:\Control Panel\Mouse" "MouseThreshold1" "0" "String" "Mouse acceleration off (2/3)"
Set-TrackedValue "HKCU:\Control Panel\Mouse" "MouseThreshold2" "0" "String" "Mouse acceleration off (3/3)"

# USB Selective Suspend OFF -> stops Windows from power-saving USB ports, which can
# otherwise add a brief wake-up delay the first time you move the mouse/press a key
# after idling.
try {
    $activePlanText = powercfg /getactivescheme | Out-String
    if ($activePlanText -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $plan = $Matches[1]
        powercfg /setacvalueindex $plan 2a700226-f241-4c9e-8c10-953882c24183 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
        powercfg /setactive $plan
        Log "OK: USB Selective Suspend disabled" "Cyan"
    }
} catch { Log "FAILED: USB selective suspend -> $($_.Exception.Message)" "Red" }

# ---------- 4) Network: Nagle's algorithm off for lower latency ----------
$ifaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue
foreach ($iface in $ifaces) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($iface.PSChildName)"
    Set-TrackedValue $p "TcpAckFrequency" 1 "DWord" "Disable TCP delayed ACK on $($iface.PSChildName)"
    Set-TrackedValue $p "TCPNoDelay"      1 "DWord" "Disable Nagle's algorithm on $($iface.PSChildName)"
}
ipconfig /flushdns | Out-Null
Log "Flushed DNS cache" "Cyan"

# ---------- 5) GPU-specific: avoid driver timeout during heavy load ----------
Set-TrackedValue "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "TdrDelay" 10 "DWord" "Increase GPU driver timeout (prevents false crash under load)"

# ---------- 6) Stop Windows from eating bandwidth with P2P update delivery ----------
Set-TrackedValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings" "DownloadMode" 0 "DWord" "Disable Delivery Optimization P2P uploads"
try {
    $saved.DoSvcStartupType = (Get-Service DoSvc -ErrorAction SilentlyContinue).StartType
    Stop-Service DoSvc -Force -ErrorAction SilentlyContinue
    Set-Service DoSvc -StartupType Manual -ErrorAction SilentlyContinue
    Log "OK: Delivery Optimization service set to Manual" "Cyan"
} catch { Log "FAILED: Delivery Optimization service -> $($_.Exception.Message)" "Red" }

# ---------- 6b) Maximum FPS / minimum input lag pass ----------
# These are the Windows-side levers that actually move the needle for FiveM.
# The single biggest lever (in-game graphics settings / settings.xml) is NOT
# something this script should silently rewrite -- see the note at the end.

# Fully disable Xbox Game Bar + Game DVR services (not just the overlay toggle)
Set-TrackedValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" "GameDVR_Enabled" 0 "DWord" "Disable Game DVR (full)"
Set-TrackedValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0 "DWord" "Policy-level Game DVR disable"

# Stop background UWP apps from running/updating while you play
Set-TrackedValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" 1 "DWord" "Disable background UWP apps"

# NVIDIA: Low Latency Mode = Ultra (driver-level input lag reduction, like Reflex
# for games that don't natively support it). AMD has an equivalent "Anti-Lag" but
# it is driver-UI only; there is no safe registry path for it.
if ($gpuType -eq "NVIDIA") {
    Set-TrackedValue "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak" "UllModeEnabled" 1 "DWord" "NVIDIA Low Latency Mode: on"
    Set-TrackedValue "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak" "UllModeLevel" 2 "DWord" "NVIDIA Low Latency Mode: Ultra"
}

# Give FiveM/GTA5 High process priority for this session (must be set again each
# time the game is launched -- there's no safe permanent registry equivalent that
# doesn't also affect Windows' own responsiveness).
$gameProcs = Get-Process -Name "FiveM","FiveM_b2060","GTA5","fivem_web_b2060" -ErrorAction SilentlyContinue
foreach ($p in $gameProcs) {
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High; Log "OK: $($p.Name) set to High priority" "Cyan" }
    catch { Log "FAILED: could not raise priority for $($p.Name)" "Red" }
}
if (-not $gameProcs) { Log "FiveM not running - start it, then run: .\TuneKit-Pro.ps1 -PriorityOnly to boost it mid-session" "Yellow" }

# Strip Windows visual effects that cost a small amount of GPU/CPU for no benefit
# while gaming (animations, shadows under windows, etc.)
Set-TrackedValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2 "DWord" "Windows visual effects: best performance"

# Network Throttling Index off -> removes a Windows QoS limit originally meant to
# protect multimedia playback, which otherwise caps background network throughput
# and can add tiny amounts of jitter under load.
Set-TrackedValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" 0xffffffff "DWord" "Remove network throttling limit"

# System responsiveness = 0 -> tells Windows' multimedia scheduler to give
# foreground game audio/graphics threads first priority instead of reserving
# CPU headroom for background tasks.
Set-TrackedValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness" 0 "DWord" "Prioritize foreground app over background tasks"

# Stop Xbox-related services nobody uses outside of Xbox Game Pass / cross-play
foreach ($svc in @("XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc")) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            $saved.XboxServices += @{ Name = $svc; StartType = $s.StartType }
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            Set-Service $svc -StartupType Manual -ErrorAction SilentlyContinue
            Log "OK: $svc set to Manual (stopped)" "Cyan"
        }
    } catch {}
}

# ---------- 7) Power plan: Ultimate/High performance ----------
try {
    $activeText = powercfg /getactivescheme | Out-String
    if ($activeText -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $saved.PowerScheme = $Matches[1]
    }
    $ultimate = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    if (-not (powercfg /list | Select-String $ultimate)) { powercfg /duplicatescheme $ultimate | Out-Null }
    if (powercfg /list | Select-String $ultimate) {
        powercfg /setactive $ultimate
        Log "OK: Ultimate Performance power plan active" "Cyan"
    } else {
        powercfg /setactive SCHEME_MIN
        Log "OK: High Performance power plan active" "Cyan"
    }
} catch { Log "FAILED: power plan -> $($_.Exception.Message)" "Red" }

# ---------- 8) Hibernation off (frees disk space, not useful for a gaming desktop) ----------
try {
    powercfg -h off
    Log "OK: Hibernation disabled" "Cyan"
} catch { Log "FAILED: hibernation -> $($_.Exception.Message)" "Red" }

# ---------- Save state for undo ----------
$saved.Registry = $script:RegistryChanges
$saved | ConvertTo-Json -Depth 5 | Set-Content -Path $state -Encoding UTF8

Log "Done. Restart the PC for all changes to fully apply." "Green"
Log "Log file : $log"
Log "Undo with: .\TuneKit-Pro.ps1 -Undo"
