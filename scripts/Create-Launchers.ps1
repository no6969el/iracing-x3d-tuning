<#
    Create-Launchers.ps1
    ---------------------------------------------------------------
    Makes a double-click .lnk shortcut next to every .ps1 in this
    folder tree. Loggers open with -NoExit (window stays up to read
    results). Every script that changes a setting is flagged
    "Run as administrator" so its shortcut elevates automatically.
    Safe to re-run any time; it just refreshes the shortcuts.
#>

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$adminScripts = @(
    'Set-GPU-IRQ-Affinity.ps1','Undo-GPU-IRQ-Affinity.ps1',
    'Set-NIC-USB-IRQ-Affinity.ps1','Undo-NIC-USB-IRQ-Affinity.ps1',
    'Pre-Race-Quiet.ps1','Post-Race-Restore.ps1',
    'Add-Defender-Exclusions.ps1','Apply-Guide-Extras.ps1','Undo-Guide-Extras.ps1',
    'Repair-PerfCounters.ps1','Enable-DiagnosticLogs.ps1',
    'Enable-GlobalTimerResolution.ps1','Undo-GlobalTimerResolution.ps1'
)
$wsh = New-Object -ComObject WScript.Shell
$made = 0

Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Where-Object { $_.Name -ne 'Create-Launchers.ps1' } | ForEach-Object {
    $ps1  = $_.FullName
    $dir  = $_.DirectoryName
    $lnk  = Join-Path $dir ($_.BaseName + '.lnk')

    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath       = 'powershell.exe'
    $s.Arguments        = '-NoExit -ExecutionPolicy Bypass -File "' + $ps1 + '"'
    $s.WorkingDirectory = $dir
    $s.IconLocation     = 'powershell.exe,0'
    $s.Description      = 'Launch ' + $_.Name
    $s.Save()

    # set "Run as administrator" bit for the scripts that need it
    if($adminScripts -contains $_.Name){
        $b = [System.IO.File]::ReadAllBytes($lnk)
        $b[0x15] = $b[0x15] -bor 0x20      # flag: run as admin
        [System.IO.File]::WriteAllBytes($lnk, $b)
    }

    Write-Host ("shortcut -> {0}" -f $lnk) -ForegroundColor Green
    $made++
}

Write-Host ""
Write-Host ("Done. Created/refreshed $made shortcut(s), one next to each script.") -ForegroundColor Cyan
