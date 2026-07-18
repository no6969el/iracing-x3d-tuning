<#
    Set-NIC-USB-IRQ-Affinity.ps1
    ---------------------------------------------------------------
    Same trick that worked for the GPU, applied to the next CPU-0
    offenders. LatencyMon showed CPU 0 carrying ~all DPC load while
    the sim runs there. This steers your physical NIC(s) and USB host
    controllers' interrupts onto CCD1 cores (17/18/19) - off CPU 0,
    off the GPU core (16), and off the VR block (20-27).

    MUST run as Administrator. REBOOT after. Verify with LatencyMon.
    Reversible with Undo-NIC-USB-IRQ-Affinity.ps1.
#>

# First frequency-CCD core: 16 for 9950X3D/7950X3D, 12 for 9900X3D/7900X3D.
# The Tuning-Menu sets this automatically; for standalone use, change the 16 below if you're 12-core.
$FreqFirst   = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else { 16 }
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
Write-Host "If a device reverts (MSI-mode), re-run this each session or we'll schedule it." -ForegroundColor DarkGray
