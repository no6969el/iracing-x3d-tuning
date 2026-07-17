<#
    Preflight-Check.ps1
    ---------------------------------------------------------------
    Read-only. Run before a test session to confirm every fix is
    live after reboot. Prints a checklist + READY / NOT READY.
    No admin required (run as admin only if a registry line says
    "access denied").
#>

function Show-OK   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Show-WARN  { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Show-INFO  { param($m) Write-Host "  [ .. ] $m" -ForegroundColor Gray }

$issues = 0
Write-Host ""
Write-Host "=================  iRACING PREFLIGHT  =================" -ForegroundColor Cyan

# 1. Both CCDs active (CPU 16 must exist for the IRQ target)
Write-Host ""
Write-Host "1. CPU topology"
$lp = [Environment]::ProcessorCount
if ($lp -eq 32) {
    Show-OK "32 logical processors - both CCDs active (CCD1 present)"
} elseif ($lp -eq 16) {
    Show-WARN "only 16 logical processors - msconfig still limiting cores; CPU 16 won't exist. Uncheck 'Number of processors' + reboot."
    $issues++
} else {
    Show-WARN "$lp logical processors - unexpected"
    $issues++
}

# 2. Active power plan
Write-Host ""
Write-Host "2. Power plan"
$scheme = (powercfg /getactivescheme) -join ' '
$planName = '?'
if ($scheme -match '\(([^)]+)\)') { $planName = $Matches[1] }
# NOTE: On THIS dual-CCD VR rig, Bitsum Highest Performance (all cores unparked)
# is CORRECT. Balanced was tested and made it unplayable - core parking starves
# the VR compositor pinned to CCD1. So Bitsum = OK, Balanced = WARN here.
if ($scheme.ToLower().Contains('a4342cf1')) {
    Show-OK "active plan = Bitsum Highest Performance - correct for this rig (all cores unparked)"
} elseif ($scheme.ToLower().Contains('381b4222-f694-41f0-9685-ff5bb260df2e')) {
    Show-WARN "active plan = Balanced - core parking starves your VR compositor (unplayable last test). Switch to Bitsum Highest Performance."
    $issues++
} elseif ($planName -like '*Bitsum*') {
    Show-OK "active plan = $planName"
} else {
    Show-WARN "active plan = $planName - expected Bitsum Highest Performance. Balanced/High-Perf hurt this VR rig."
    $issues++
}

# 3. GPU interrupt affinity (registry)
Write-Host ""
Write-Host "3. GPU interrupt affinity (target CPU 16)"
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
                if ($cores -contains 16) {
                    Show-OK "GPU interrupts steered to CPU $coreList (override active)"
                } else {
                    Show-WARN "GPU IRQ override present but targets CPU $coreList (not 16)"
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

# 4. Process Lasso config + engine
Write-Host ""
Write-Host "4. Process Lasso"
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
        if ($t.Contains('iracingsim64dx11.exe,(0-15)')) { Show-OK "iRacing soft CPU Set 0-15 present" }
        else { Show-WARN "iRacing CPU Set 0-15 missing"; $issues++ }
        if (-not $t.Contains('iracingsim64dx11.exe,0,0-15')) { Show-OK "no hard-affinity rule (EAC would reject it)" }
        else { Show-WARN "hard-affinity rule still present"; $issues++ }
        if (-not $t.Contains('iracingsim64dx11.exe;bitsum')) { Show-OK "not forcing Bitsum on iRacing" }
        else { Show-WARN "still forcing Bitsum on iRacing - will override Balanced"; $issues++ }
    } catch {
        Show-WARN "could not parse prolasso.ini"
    }
} else {
    Show-INFO "prolasso.ini not found at default path (check your install location)"
}

# 5. ParkControl (Dynamic Boost can't be read programmatically - remind)
Write-Host ""
Write-Host "5. ParkControl"
if (Get-Process ParkControl -ErrorAction SilentlyContinue) {
    Show-INFO "ParkControl running - confirm 'Bitsum Dynamic Boost' is UNCHECKED (it was flipping your power plan)"
} else {
    Show-OK "ParkControl not running (can't flip the plan)"
}

# 6. NVIDIA driver
Write-Host ""
Write-Host "6. GPU driver"
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
