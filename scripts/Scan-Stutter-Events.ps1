<#
    Scan-Stutter-Events.ps1
    ---------------------------------------------------------------
    Hunts the cause of the periodic (~every 7 min) micro-stalls.
    1) Lists scheduled TASKS that fired during the session window
       (a ~7-min cadence there is the prime suspect).
    2) Dumps System-log Warning/Error events within +/-20s of each
       stutter timestamp.
    Read-only. Edit the window/timestamps below if you re-test.
#>

# --- EDIT THESE to match your session ---
# $Start/$End = your race window; $Incidents = the exact times a stutter hit
# (get these from the time-gaps in your FullTrace CSV). Format: 'YYYY-MM-DD HH:MM:SS' (24h).
$Start   = Get-Date '2026-01-01 12:00:00'
$End     = Get-Date '2026-01-01 12:30:00'
$Incidents = @('2026-01-01 12:06:00','2026-01-01 12:12:00')
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'stutter-events.txt'

"STUTTER EVENT SCAN"                | Out-File $out -Encoding utf8
"Window: $Start -> $End"            | Out-File $out -Append -Encoding utf8

# 1) scheduled tasks that ran in the window (look for a ~7-min cadence)
"" | Out-File $out -Append -Encoding utf8
"=== SCHEDULED TASKS THAT RAN (Id 100/200 = started/action) ===" | Out-File $out -Append -Encoding utf8
try {
    Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=100,200; StartTime=$Start; EndTime=$End } -ErrorAction Stop |
        Sort-Object TimeCreated | ForEach-Object {
            $task = ($_.Message -replace '\s+',' ')
            "{0:HH:mm:ss}  {1}" -f $_.TimeCreated, $task.Substring(0,[Math]::Min(150,$task.Length)) | Out-File $out -Append -Encoding utf8
        }
} catch {
    "(TaskScheduler Operational log empty or disabled - enable it in Event Viewer: Applications and Services Logs > Microsoft > Windows > TaskScheduler > Operational > Enable Log)" | Out-File $out -Append -Encoding utf8
}

# 2) System events around each stutter
"" | Out-File $out -Append -Encoding utf8
"=== SYSTEM EVENTS NEAR EACH STUTTER (+/-20s) ===" | Out-File $out -Append -Encoding utf8
foreach ($ts in $Incidents) {
    $c = Get-Date $ts
    "" | Out-File $out -Append -Encoding utf8
    "--- $ts ---" | Out-File $out -Append -Encoding utf8
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$c.AddSeconds(-20); EndTime=$c.AddSeconds(20); Level=1,2,3 } -ErrorAction Stop | Sort-Object TimeCreated
        if (-not $ev) { "  (no warnings/errors in window)" | Out-File $out -Append -Encoding utf8 }
        foreach ($e in $ev) {
            $m = ($e.Message -replace '\s+',' ')
            "  [{0:HH:mm:ss}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.ProviderName, $m.Substring(0,[Math]::Min(160,$m.Length)) | Out-File $out -Append -Encoding utf8
        }
    } catch {
        "  (no matching System events)" | Out-File $out -Append -Encoding utf8
    }
}

Write-Host "Done -> $out" -ForegroundColor Green
Start-Process notepad.exe $out
