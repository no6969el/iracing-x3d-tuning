<#
    Undo GPU interrupt steering  (NVIDIA + AMD + Intel)
    ---------------------------------------------------------------
    Reverts Set-GPU-IRQ-Affinity.ps1 by removing the interrupt-affinity
    policy from the display adapter, so its interrupts return to Windows'
    default placement. Vendor-neutral, same as the Set script:
        NVIDIA = VEN_10DE   AMD = VEN_1002   Intel = VEN_8086

    Removes DevicePolicy + AssignmentSetOverride (and the now-empty
    Affinity Policy key) under each recognized GPU. Safe to run even if
    the policy was never applied - it just reports "nothing to undo."

    MUST run as Administrator. Reboot afterward for it to take effect.
#>

# --- require admin ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: right-click PowerShell and Run as Administrator, then re-run." -ForegroundColor Red; return }

$Vendors = @{
    'VEN_10DE' = 'NVIDIA'
    'VEN_1002' = 'AMD'
    'VEN_8086' = 'Intel'
}

$all  = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue
$gpus = $all | Where-Object { $id = $_.InstanceId; ($Vendors.Keys | Where-Object { $id -match $_ }) }

if (-not $gpus) {
    Write-Host "ERROR: no active display adapter with a recognized vendor ID (NVIDIA/AMD/Intel) was found." -ForegroundColor Red
    return
}

$changed = 0
foreach ($g in $gpus) {
    $venKey = ($Vendors.Keys | Where-Object { $g.InstanceId -match $_ } | Select-Object -First 1)
    Write-Host ""
    Write-Host ("GPU : {0}  ({1})" -f $g.FriendlyName, $Vendors[$venKey]) -ForegroundColor Cyan
    Write-Host "  Instance: $($g.InstanceId)"
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"

    if (-not (Test-Path $key)) {
        Write-Host "  -> no affinity policy set (nothing to undo)" -ForegroundColor DarkGray
        continue
    }
    try {
        Remove-ItemProperty -Path $key -Name 'DevicePolicy'          -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $key -Name 'AssignmentSetOverride' -ErrorAction SilentlyContinue
        # if the key is now empty, remove it so the device reads as pristine
        $left = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }
        if (-not $left) { Remove-Item -Path $key -Force -ErrorAction SilentlyContinue }
        Write-Host "  -> interrupt steering removed (back to Windows default)" -ForegroundColor Green
        $changed++
    } catch {
        Write-Host "  ERROR writing registry (permissions?): $_" -ForegroundColor Red
    }
}

Write-Host ""
if ($changed -gt 0) {
    Write-Host "Done. REBOOT for GPU interrupts to return to their default placement." -ForegroundColor Yellow
} else {
    Write-Host "No changes were needed." -ForegroundColor DarkGray
}
