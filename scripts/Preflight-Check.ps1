<#
    Preflight-Check.ps1
    ---------------------------------------------------------------
    Read-only. Run before a session to confirm every fix is live
    after a reboot. Prints a checklist + READY / NOT READY.
    No admin required (run as admin only if a registry line says
    "access denied").

    Core numbers come from the Tuning-Menu's saved config when
    available; otherwise they're inferred from your logical
    processor count (32 -> 16-core X3D, 24 -> 12-core X3D).
#>

function Show-OK   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Show-WARN { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Show-INFO { param($m) Write-Host "  [ .. ] $m" -ForegroundColor Gray }

$issues = 0
$ncpu = [Environment]::ProcessorCount

# --- resolve topology + the first frequency-CCD core ---
$Topology = ''
$cfgPath = Join-Path $env:APPDATA 'iRacingX3DTuning\config.json'
if (Test-Path $cfgPath) { try { $Topology = [string](Get-Content $cfgPath -Raw | ConvertFrom-Json).Topology } catch {} }
$FreqFirst = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else {
    $ff = 0
    if (Test-Path $cfgPath) { try { $ff = [int](Get-Content $cfgPath -Raw | ConvertFrom-Json).FreqFirst } catch {} }
    if ($ff -lt 1) { $ff = switch ($ncpu) { 32 {16} 24 {12} 16 {8} default {[int]($ncpu/2)} } }
    $ff
}
# infer single-CCD when we have no saved topology but the chip is an 8-core (16-thread) class
if (-not $Topology) { $Topology = if ($ncpu -le 16) { 'single' } else { 'dual' } }
$IsSingle = ($Topology -eq 'single')
$VCacheRange = "0-$($FreqFirst - 1)"

Write-Host ""
Write-Host "=================  iRACING PREFLIGHT  =================" -ForegroundColor Cyan
if ($IsSingle) {
    Write-Host ("  single-CCD: all cores V-Cache, GPU IRQ steered to CPU {0}" -f $FreqFirst) -ForegroundColor DarkGray
} else {
    Write-Host ("  dual-CCD: sim on V-Cache cores {0}, GPU IRQ on CPU {1}" -f $VCacheRange, $FreqFirst) -ForegroundColor DarkGray
}

# 1. CPU visible to Windows
Write-Host ""
Write-Host "1. CPU topology"
if ($IsSingle) {
    Show-OK "$ncpu logical processors - single-CCD (all cores share the V-Cache)"
} elseif ($ncpu -eq 2 * $FreqFirst) {
    Show-OK "$ncpu logical processors - both CCDs active"
} elseif ($ncpu -eq $FreqFirst) {
    Show-WARN "only $ncpu logical processors - msconfig may be limiting cores; CPU $FreqFirst won't exist. Uncheck 'Number of processors' in msconfig > Boot > Advanced + reboot."
    $issues++
} else {
    Show-WARN "$ncpu logical processors - unexpected for a $(2*$FreqFirst)-thread X3D (run the Tuning-Menu once to save your core profile)"
    $issues++
}

# 2. Active power plan
Write-Host ""
Write-Host "2. Power plan"
$scheme = (powercfg /getactivescheme) -join ' '
$planName = '?'
if ($scheme -match '\(([^)]+)\)') { $planName = $Matches[1] }
if ($IsSingle) {
    # single-CCD: any plan is fine; Balanced is actually AMD's recommendation
    Show-OK "active plan = $planName (single-CCD - power plan isn't critical; Balanced is fine)"
} elseif ($scheme.ToLower().Contains('a4342cf1') -or $planName -like '*Bitsum*') {
    Show-OK "active plan = $planName (all cores unparked)"
} elseif ($scheme.ToLower().Contains('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
    Show-OK "active plan = $planName (High Performance - cores unparked)"
} elseif ($scheme.ToLower().Contains('381b4222-f694-41f0-9685-ff5bb260df2e')) {
    Show-WARN "active plan = Balanced - on a dual-CCD chip its core parking can starve the VR compositor. Switch to Bitsum Highest Performance or High Performance."
    $issues++
} else {
    Show-INFO "active plan = $planName - make sure core parking is OFF (100% cores unparked)"
}

# 3. GPU interrupt affinity (registry)
Write-Host ""
Write-Host "3. GPU interrupt affinity (target CPU $FreqFirst)"
$gpus = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like '*VEN_10DE*' }
if (-not $gpus) {
    Show-WARN "no active NVIDIA display device found"
    $issues++
}
foreach ($g in $gpus) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
    try {
        if (Test-Path $key) {
            $p   = Get-ItemProperty -Path $key -ErrorAction Stop
            $pol = $p.DevicePolicy
            $ov  = $p.AssignmentSetOverride
            if ($pol -eq 4 -and $ov) {
                $mask = [uint64]0
                for ($i = 0; $i -lt $ov.Length; $i++) {
                    $mask = $mask -bor ([uint64]$ov[$i] -shl (8 * $i))
                }
                $cores = @()
                for ($b = 0; $b -lt 64; $b++) {
                    if ((($mask -shr $b) -band [uint64]1) -eq 1) { $cores += $b }
                }
                $coreList = $cores -join ','
                if ($cores -contains $FreqFirst) {
                    Show-OK "GPU interrupts steered to CPU $coreList (override active)"
                } else {
                    Show-WARN "GPU IRQ override present but targets CPU $coreList (not $FreqFirst)"
                    $issues++
                }
            } else {
                Show-WARN "policy present but not SpecifiedProcessors(4) - re-run Set-GPU-IRQ-Affinity"
                $issues++
            }
        } else {
            Show-WARN "no interrupt override on $($g.FriendlyName) - reverted (MSI quirk). Re-run Set-GPU-IRQ-Affinity as admin."
            $issues++
        }
    } catch {
        Show-WARN "could not read IRQ registry (try running as admin)"
        $issues++
    }
}

# 4. Global timer resolution (the VR focus/timer fix)
Write-Host ""
Write-Host "4. Global timer resolution"
$tk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
$tv = (Get-ItemProperty -Path $tk -Name 'GlobalTimerResolutionRequests' -ErrorAction SilentlyContinue).GlobalTimerResolutionRequests
if ($tv -eq 1) {
    Show-OK "GlobalTimerResolutionRequests = 1 - high-res timer honored even when the sim loses focus"
} else {
    Show-INFO "not set - if you get hitches that stop when you CLICK the sim window (common in VR), run Enable-GlobalTimerResolution (admin) + reboot"
}

# 5. Process Lasso config + engine (dual-CCD only - single-CCD has nothing to pin)
Write-Host ""
Write-Host "5. Process Lasso (core pinning)"
if ($IsSingle) {
    Show-OK "single-CCD - no core pinning needed (all cores are V-Cache)"
} else {
    if (Get-Process ProcessGovernor -ErrorAction SilentlyContinue) {
        Show-OK "governor running (ProcessGovernor.exe)"
    } else {
        Show-WARN "ProcessGovernor.exe not running - Process Lasso rules won't apply"
        $issues++
    }
    $cfg = 'C:\ProgramData\ProcessLasso\config\prolasso.ini'
    if (Test-Path $cfg) {
        try {
            $t = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::Unicode).ToLower()
            if ($t.Contains("iracingsim64dx11.exe,($VCacheRange)")) { Show-OK "iRacing soft CPU Set $VCacheRange present" }
            else { Show-WARN "iRacing CPU Set $VCacheRange missing - add it (CPU Sets, not affinity)"; $issues++ }
            if (-not $t.Contains("iracingsim64dx11.exe,0,$VCacheRange")) { Show-OK "no hard-affinity rule (EAC would reject it)" }
            else { Show-WARN "hard-affinity rule still present - remove it (EAC reverts it and it fights the CPU Set)"; $issues++ }
        } catch {
            Show-WARN "could not parse prolasso.ini"
        }
    } else {
        Show-INFO "prolasso.ini not found at default path (check your install location)"
    }
}

# 6. ParkControl (Dynamic Boost can't be read programmatically - remind)
Write-Host ""
Write-Host "6. ParkControl"
if (Get-Process ParkControl -ErrorAction SilentlyContinue) {
    Show-INFO "ParkControl running - confirm 'Bitsum Dynamic Boost' is UNCHECKED (it can flip the power plan mid-race)"
} else {
    Show-OK "ParkControl not running (can't flip the plan)"
}

# 7. NVIDIA driver
Write-Host ""
Write-Host "7. GPU driver"
$vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*NVIDIA*' } | Select-Object -First 1
if ($vc) { Show-INFO "$($vc.Name)  driver $($vc.DriverVersion)  ($($vc.DriverDate))" }

# verdict
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
if ($issues -eq 0) {
    Write-Host "  READY - all checks passed. Launch FullTrace, then race." -ForegroundColor Green
} else {
    Write-Host "  NOT READY - $issues item(s) need attention above." -ForegroundColor Yellow
}
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
