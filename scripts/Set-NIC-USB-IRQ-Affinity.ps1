<#
    Set-NIC-USB-IRQ-Affinity.ps1
    ---------------------------------------------------------------
    Same trick as the GPU fix, applied to the next CPU-0 offenders.
    LatencyMon typically shows CPU 0 carrying most DPC load while the
    sim runs there. This steers physical NIC(s) and USB host
    controllers' interrupts onto background cores - off CPU 0 (the sim)
    and off the core the GPU interrupts were moved to.

    The target list comes from X3D-Profiles.ps1 and is clamped to the
    CPUs Windows actually reports, so on a 6-core chip it uses 7/8/9
    rather than walking off the end of the processor list.

    MUST run as Administrator. REBOOT after. Verify with LatencyMon.
    Reversible with Undo-NIC-USB-IRQ-Affinity.ps1.
#>

# ---- resolve the target cores -----------------------------------
$mod = Join-Path $PSScriptRoot 'X3D-Profiles.ps1'
$Simulated = $false
$Valid     = $true
$TargetCores = @()

if (Test-Path $mod) {
    . $mod
    $r = Resolve-X3DTarget
    $FreqFirst = $r.FreqFirst
    $Limit     = $r.Limit
    $Simulated = $r.Simulated
    $Valid     = $r.Valid
    if ($r.Profile -and $r.Profile.IrqTargets -and $r.Profile.IrqTargets.Count -gt 0) {
        $TargetCores = @($r.Profile.IrqTargets)
    }
} else {
    Write-Host "  ! X3D-Profiles.ps1 not found next to this script - using a safe fallback." -ForegroundColor Yellow
    $Limit     = [int][Environment]::ProcessorCount
    $FreqFirst = [int]($Limit / 2)
}

# Build/clamp the list ourselves if the module did not supply one
# (e.g. the core came from X3D_FREQ_FIRST_CORE rather than detection).
if ($TargetCores.Count -lt 1) {
    for ($i = $FreqFirst + 1; $i -lt $Limit -and $TargetCores.Count -lt 3; $i++) { $TargetCores += $i }
}
$TargetCores = @($TargetCores | Where-Object { $_ -ge 1 -and $_ -lt $Limit } | Sort-Object -Unique)

if ($TargetCores.Count -lt 1) {
    Write-Host ""
    Write-Host "ABORTED: no usable background core on this machine ($Limit logical processors)." -ForegroundColor Red
    Write-Host "Nothing was changed." -ForegroundColor DarkGray
    return
}
if (-not $Valid) {
    Write-Host ""
    Write-Host "ABORTED: this CPU's topology could not be identified, so interrupt steering is disabled." -ForegroundColor Red
    Write-Host "The rest of the kit still works. Nothing was changed." -ForegroundColor DarkGray
    return
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: right-click PowerShell -> Run as Administrator, then re-run." -ForegroundColor Red; return }

function Set-IrqAffinity {
    param($InstanceId, $Core)
    $mask  = ([uint64]1) -shl $Core
    $bytes = [System.BitConverter]::GetBytes($mask)
    $key   = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters\Interrupt Management\Affinity Policy"
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DevicePolicy' -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $key -Name 'AssignmentSetOverride' -PropertyType Binary -Value $bytes -Force | Out-Null
}

# physical (PCI-backed) NICs and USB host controllers only
$nics = Get-PnpDevice -Class Net -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' }
$usb  = Get-PnpDevice -Class USB -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' }

$targets = @()
foreach ($n in $nics) { $targets += [pscustomobject]@{ Type='NIC'; Name=$n.FriendlyName; Id=$n.InstanceId } }
foreach ($u in $usb)  { $targets += [pscustomobject]@{ Type='USB'; Name=$u.FriendlyName; Id=$u.InstanceId } }

if (-not $targets) { Write-Host "No PCI NIC or USB controllers found." -ForegroundColor Yellow; return }

Write-Host ""
if ($Simulated) {
    Write-Host "  DRY RUN - X3D_FORCE_PROFILE is set, so nothing will be written." -ForegroundColor Magenta
}
Write-Host "Steering interrupts off CPU 0 -> background CPUs $($TargetCores -join ',')" -ForegroundColor Cyan
$i = 0
foreach ($t in $targets) {
    $core = $TargetCores[$i % $TargetCores.Count]
    if ($Simulated) {
        Write-Host ("  [{0}] {1}" -f $t.Type, $t.Name) -ForegroundColor Magenta
        Write-Host ("        -> WOULD use CPU {0}" -f $core) -ForegroundColor DarkGray
        $i++
        continue
    }
    try {
        Set-IrqAffinity -InstanceId $t.Id -Core $core
        Write-Host ("  [{0}] {1}" -f $t.Type, $t.Name) -ForegroundColor Green
        Write-Host ("        -> CPU {0}" -f $core) -ForegroundColor DarkGray
    } catch {
        Write-Host ("  [{0}] {1} - FAILED ({2})" -f $t.Type, $t.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
    $i++
}

Write-Host ""
if ($Simulated) {
    Write-Host "Dry run complete - no changes were made." -ForegroundColor Magenta
} else {
    Write-Host "Done. REBOOT, then run LatencyMon - CPU 0 DPC total should drop sharply." -ForegroundColor Yellow
    Write-Host "If a device reverts (MSI-mode), re-run this before each session." -ForegroundColor DarkGray
}
