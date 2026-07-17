<#
    Undo GPU interrupt steering — restores default (machine-chosen) IRQ routing.
    MUST run as Administrator. Reboot afterward.
#>
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){ Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

$gpus = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE' }
foreach($g in $gpus){
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
    if(Test-Path $key){
        Remove-Item -Path $key -Recurse -Force
        Write-Host "Removed IRQ affinity override for: $($g.FriendlyName)" -ForegroundColor Green
    } else {
        Write-Host "No override present for: $($g.FriendlyName)" -ForegroundColor DarkGray
    }
}
Write-Host "Done. Reboot to return to default interrupt routing." -ForegroundColor Yellow
