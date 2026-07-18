<#
    Steer NVIDIA GPU interrupts to a CCD1 core (default CPU 16)
    ---------------------------------------------------------------
    iRacing's sim thread favors CPU 0, and NVIDIA's GPU interrupts
    (nvlddmkm) also default toward CPU 0 - they collide and cause DPC
    spikes. This steers the GPU's interrupt handling to another core.
      * Dual-CCD: the first frequency-die core (16 or 12), off the V-Cache die.
      * Single-CCD: a high core (half the thread count), off CPU 0.
    The Tuning-Menu / Apply-Baseline pick the right target for your chip;
    standalone it falls back to half your logical processor count, which
    is always a valid, distinct core (never a nonexistent one).

    MUST run as Administrator. Reboot afterward, then verify with LatencyMon.
    Reversible with Undo-GPU-IRQ-Affinity.ps1.
#>

# First frequency-CCD core: 16 for 9950X3D/7950X3D, 12 for 9900X3D/7900X3D.
# The Tuning-Menu sets this automatically (env var or saved config).
# Standalone on a 12-core with no saved config: change the final 16 below to 12.
$TargetCore = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else {
    $cfgPath = Join-Path $env:APPDATA 'iRacingX3DTuning\config.json'
    $ff = 0
    if (Test-Path $cfgPath) { try { $ff = [int](Get-Content $cfgPath -Raw | ConvertFrom-Json).FreqFirst } catch {} }
    if ($ff -lt 1) { $ff = [int]([Environment]::ProcessorCount / 2) }   # 8-core single-CCD -> 8, never a nonexistent core
    $ff
}

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
