<#
    Steer NVIDIA GPU interrupts to a CCD1 core (default CPU 16)
    ---------------------------------------------------------------
    On your 9950X3D, iRacing's sim thread lives on CCD0 (V-cache, cores
    0-15). GPU interrupts (nvlddmkm) default toward CPU 0 and collide
    with it. This moves the GPU's interrupt handling onto CPU 16 (the
    first CCD1 / frequency-die core), off the V-cache die entirely.

    MUST run as Administrator. Reboot afterward, then verify with LatencyMon.
    Reversible with Undo-GPU-IRQ-Affinity.ps1.
#>

# First frequency-CCD core: 16 for 9950X3D/7950X3D, 12 for 9900X3D/7900X3D.
# The Tuning-Menu sets this automatically; for standalone use, change the 16 below if you're 12-core.
$TargetCore = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else { 16 }

# --- require admin ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){ Write-Host "ERROR: right-click PowerShell and Run as Administrator, then re-run." -ForegroundColor Red; return }

# --- build the processor affinity mask (little-endian 8 bytes) ---
$mask  = ([uint64]1) -shl $TargetCore
$bytes = [System.BitConverter]::GetBytes($mask)      # KAFFINITY, group 0

# --- find NVIDIA display device(s) ---
$gpus = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE' }
if(-not $gpus){ Write-Host "ERROR: no active NVIDIA display device found." -ForegroundColor Red; return }

foreach($g in $gpus){
    Write-Host ""
    Write-Host "GPU : $($g.FriendlyName)" -ForegroundColor Cyan
    Write-Host "  Instance: $($g.InstanceId)"
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
    try {
        New-Item -Path $key -Force | Out-Null
        # DevicePolicy = 4  (IrqPolicySpecifiedProcessors)
        New-ItemProperty -Path $key -Name 'DevicePolicy' -PropertyType DWord -Value 4 -Force | Out-Null
        # AssignmentSetOverride = processor mask
        New-ItemProperty -Path $key -Name 'AssignmentSetOverride' -PropertyType Binary -Value $bytes -Force | Out-Null
        Write-Host ("  -> GPU interrupts pinned to CPU {0} (mask 0x{1:X})" -f $TargetCore,$mask) -ForegroundColor Green
    } catch {
        Write-Host "  ERROR writing registry (permissions?): $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. REBOOT for it to take effect, then run LatencyMon and confirm" -ForegroundColor Yellow
Write-Host "nvlddmkm ISRs/DPCs now land on CPU $TargetCore instead of CPU 0." -ForegroundColor Yellow
Write-Host "If it reverts after reboot (MSI-mode quirk), re-run this each session." -ForegroundColor DarkGray
