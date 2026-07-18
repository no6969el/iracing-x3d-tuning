<#
    Set-NIC-USB-IRQ-Affinity.ps1
    ---------------------------------------------------------------
    Same trick as the GPU fix, applied to the next CPU-0 offenders.
    LatencyMon typically shows CPU 0 carrying most DPC load while the
    sim runs there. This steers physical NIC(s) and USB host
    controllers' interrupts onto the 2nd-4th frequency-die (CCD1)
    cores - off CPU 0 (the sim) and off the first CCD1 core (GPU IRQ).

    MUST run as Administrator. REBOOT after. Verify with LatencyMon.
    Reversible with Undo-NIC-USB-IRQ-Affinity.ps1.
#>

# First frequency-CCD core: 16 for 9950X3D/7950X3D, 12 for 9900X3D/7900X3D.
# The Tuning-Menu sets this automatically (env var or saved config).
# Standalone on a 12-core with no saved config: change the final 16 below to 12.
$FreqFirst = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else {
    $cfgPath = Join-Path $env:APPDATA 'iRacingX3DTuning\config.json'
    $ff = 0
    if (Test-Path $cfgPath) { try { $ff = [int](Get-Content $cfgPath -Raw | ConvertFrom-Json).FreqFirst } catch {} }
    if ($ff -lt 1) { $ff = 16 }
    $ff
}
$TargetCores = @($FreqFirst + 1, $FreqFirst + 2, $FreqFirst + 3)   # off CPU0(sim), off the GPU core, off VR

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
Write-Host "Steering interrupts off CPU 0 -> CCD1 cores $($TargetCores -join ',')" -ForegroundColor Cyan
$i = 0
foreach ($t in $targets) {
    $core = $TargetCores[$i % $TargetCores.Count]
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
Write-Host "Done. REBOOT, then run LatencyMon - CPU 0 DPC total should drop sharply." -ForegroundColor Yellow
Write-Host "If a device reverts (MSI-mode), re-run this before each session." -ForegroundColor DarkGray
