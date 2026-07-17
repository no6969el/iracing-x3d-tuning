<#
    Undo-NIC-USB-IRQ-Affinity.ps1
    ---------------------------------------------------------------
    Removes the interrupt-affinity overrides set by
    Set-NIC-USB-IRQ-Affinity.ps1, restoring default routing for the
    physical NIC(s) and USB host controllers.
    MUST run as Administrator. REBOOT after.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

$nics = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' }
$usb  = Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' }

$all = @()
foreach ($d in @($nics) + @($usb)) { $all += $d }

foreach ($d in $all) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-Host ("  reverted: {0}" -f $d.FriendlyName) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done. Reboot to return to default interrupt routing." -ForegroundColor Yellow
