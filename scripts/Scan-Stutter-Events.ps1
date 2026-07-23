<#
    Scan-Stutter-Events.ps1
    ---------------------------------------------------------------
    Finds the cause of stutters - with ZERO manual editing.
    It automatically reads your most recent FullTrace CSV from the
    Desktop, finds the moments you stuttered (gaps in the timestamps),
    then lists the scheduled tasks and Windows events around each one.

    Prereqs: run a FullTrace race first (so there's a CSV to read), and
    run Enable-DiagnosticLogs BEFORE that race (so the task log has data).
    Read-only. Writes stutter-events.txt to your Desktop.
#>

$desktop = [Environment]::GetFolderPath('Desktop')

# --- find the newest FullTrace CSV on the Desktop ---
$csv = Get-ChildItem -Path $desktop -Filter 'iRacing-FullTrace-*.csv' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $csv) {
    Write-Host ""
    Write-Host "  No FullTrace CSV found on your Desktop." -ForegroundColor Yellow
    Write-Host "  Run 'Log a race (FullTrace)' first, then run this again." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close" | Out-Null
    return
}

Write-Host ""
Write-Host "  Using latest trace: $($csv.Name)" -ForegroundColor Cyan
$day = $csv.LastWriteTime.Date

# --- parse timestamps, find gaps (>1s between rows = a stall) ---
$times = @()
foreach ($line in (Get-Content $csv.FullName | Select-Object -Skip 1)) {
    $t = ($line -split ',')[0].Trim()
    if ($t -match '^\d{1,2}:\d{2}:\d{2}$') { $times += $t }
}
if ($times.Count -lt 2) {
    Write-Host "  That trace has no usable timestamps." -ForegroundColor Yellow
    Read-Host "  Press Enter to close" | Out-Null; return
}

function DT([string]$hms) { $day + [TimeSpan]::Parse($hms) }

$incidents = @()
$prev = $null
foreach ($t in $times) {
    $cur = [TimeSpan]::Parse($t).TotalSeconds
    if ($prev -ne $null -and ($cur - $prev) -gt 1) { $incidents += $t }
    $prev = $cur
}
$Start = DT $times[0]
$End   = DT $times[-1]

Write-Host ("  Session {0} -> {1}   |   auto-detected {2} stutter(s)" -f $Start.ToString('HH:mm:ss'), $End.ToString('HH:mm:ss'), $incidents.Count) -ForegroundColor Cyan

# --- write report ---
$out = Join-Path $desktop 'stutter-events.txt'
"STUTTER EVENT SCAN"                                   | Out-File $out -Encoding utf8
"Trace  : $($csv.Name)"                                | Out-File $out -Append -Encoding utf8
"Window : $Start  ->  $End"                            | Out-File $out -Append -Encoding utf8
"Auto-detected stutters (timestamp gaps): $($incidents.Count)" | Out-File $out -Append -Encoding utf8
if ($incidents.Count) { "  at: $($incidents -join ', ')" | Out-File $out -Append -Encoding utf8 }

# 1) scheduled tasks that fired during the whole session (a repeating cadence is the prime suspect)
"" | Out-File $out -Append -Encoding utf8
"=== SCHEDULED TASKS THAT RAN THIS SESSION (Id 100/200) ===" | Out-File $out -Append -Encoding utf8
try {
    $t = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=100,200; StartTime=$Start; EndTime=$End } -ErrorAction Stop | Sort-Object TimeCreated
    if (-not $t) { "(none)" | Out-File $out -Append -Encoding utf8 }
    foreach ($e in $t) { $m=($e.Message -replace '\s+',' '); "{0:HH:mm:ss}  {1}" -f $e.TimeCreated, $m.Substring(0,[Math]::Min(150,$m.Length)) | Out-File $out -Append -Encoding utf8 }
} catch {
    "(TaskScheduler Operational log is off - run Enable-DiagnosticLogs BEFORE your next race to capture this.)" | Out-File $out -Append -Encoding utf8
}

# 2) System events within +/-20s of each detected stutter
"" | Out-File $out -Append -Encoding utf8
"=== SYSTEM EVENTS NEAR EACH STUTTER (+/-20s) ===" | Out-File $out -Append -Encoding utf8
if (-not $incidents.Count) {
    "(No stutters detected in this trace - nice and smooth!)" | Out-File $out -Append -Encoding utf8
}
foreach ($ts in $incidents) {
    $c = DT $ts
    "" | Out-File $out -Append -Encoding utf8
    "--- $ts ---" | Out-File $out -Append -Encoding utf8
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$c.AddSeconds(-20); EndTime=$c.AddSeconds(20); Level=1,2,3 } -ErrorAction Stop | Sort-Object TimeCreated
        if (-not $ev) { "  (no warnings/errors logged - typical for a pure DPC/scheduler blip)" | Out-File $out -Append -Encoding utf8 }
        foreach ($e in $ev) { $m=($e.Message -replace '\s+',' '); "  [{0:HH:mm:ss}] Id={1} {2}: {3}" -f $e.TimeCreated,$e.Id,$e.ProviderName,$m.Substring(0,[Math]::Min(150,$m.Length)) | Out-File $out -Append -Encoding utf8 }
    } catch {
        "  (no matching System events)" | Out-File $out -Append -Encoding utf8
    }
}

Write-Host "  Done -> $out" -ForegroundColor Green
Start-Process notepad.exe $out
