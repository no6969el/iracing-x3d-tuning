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

    ---------------------------------------------------------------
    v3.3.0 - IT NOW READS THE FAULT COLUMNS
    ---------------------------------------------------------------
    If the trace came from an elevated FullTrace run with the Windows
    Performance Toolkit present, the CSV carries three extra columns:
    sim_hardfaults_s, top_fault_proc and top_fault_file. This script
    uses them for two things.

    First, attribution: every incident now names the process and file
    that faulted at that second, instead of leaving you to guess from a
    list of scheduled tasks.

    Second - and this is the part that finds stutters the old version
    could not - a fault burst is now an incident in its own right. The
    old logic triggered only on a gap in the timestamps, but a burst of
    hard faults can stall a frame without the logger ever missing a
    second. Those stutters were invisible here.

    A reminder the report repeats, because it is the mistake this whole
    release exists to prevent: hardfaults_s is SYSTEM-WIDE. On a traced
    session the sim caused 14 of 4,712 faults. Judge the sim by
    sim_hardfaults_s, never by hardfaults_s.
#>

$desktop = [Environment]::GetFolderPath('Desktop')

# Kit-Common owns the filename patterns and the fault-column names (data only), so
# this script cannot disagree with FullTrace about what was written.
$KitCommon = Join-Path $PSScriptRoot 'Kit-Common.ps1'
if (Test-Path -LiteralPath $KitCommon) { . $KitCommon }
if (-not $FullTraceCsvPattern) { $FullTraceCsvPattern = 'iRacing-FullTrace-*.csv' }
if (-not $HardFaultColumns)    { $HardFaultColumns = @('sim_hardfaults_s','top_fault_proc','top_fault_file') }

# --- find the newest FullTrace CSV on the Desktop ---
$csv = Get-ChildItem -Path $desktop -Filter $FullTraceCsvPattern -ErrorAction SilentlyContinue |
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

# --- parse the CSV properly (Import-Csv, not index-0 splitting) ------
# The old code took field [0] of a raw split. That worked, but it could
# not see any other column, and the v3 fault columns are quoted - which
# a naive split would mangle anyway.
$rows = @()
try { $rows = @(Import-Csv -LiteralPath $csv.FullName) } catch { }
if ($rows.Count -lt 2) {
    Write-Host "  That trace has no usable rows." -ForegroundColor Yellow
    Read-Host "  Press Enter to close" | Out-Null; return
}

$cols     = $rows[0].PSObject.Properties.Name
$HasFault = @($HardFaultColumns | Where-Object { $_ -in $cols }).Count -eq $HardFaultColumns.Count

$times = @($rows | ForEach-Object { $_.timestamp } | Where-Object { $_ -match '^\d{1,2}:\d{2}:\d{2}$' })
if ($times.Count -lt 2) {
    Write-Host "  That trace has no usable timestamps." -ForegroundColor Yellow
    Read-Host "  Press Enter to close" | Out-Null; return
}

function DT([string]$hms) { $day + [TimeSpan]::Parse($hms, [Globalization.CultureInfo]::InvariantCulture) }
function AsInt($v) { $n = 0; [void][int]::TryParse(("$v").Trim(), [ref]$n); $n }

# --- incident detection --------------------------------------------
# Two independent triggers, tagged so the report can say which fired.
#   GAP   - a second missing from the log. A lead, not a verdict (v3.2.0).
#   FAULT - a burst of hard faults attributed to the SIM. This one can
#           stall a frame without ever producing a gap, so before v3.3.0
#           it was invisible here.
$FAULT_BURST = 50     # sim_hardfaults_s in one second. The sim's median
                      # on a healthy machine is 0; a traced 25-minute
                      # session produced 14 sim faults in total.

$incidents = @{}      # timestamp -> list of reasons
function Add-Incident([string]$ts, [string]$why) {
    if (-not $incidents.ContainsKey($ts)) { $incidents[$ts] = @() }
    if ($why -notin $incidents[$ts]) { $incidents[$ts] += $why }
}

$prev = $null
foreach ($t in $times) {
    $cur = [TimeSpan]::Parse($t, [Globalization.CultureInfo]::InvariantCulture).TotalSeconds
    if ($null -ne $prev -and ($cur - $prev) -gt 1) { Add-Incident $t 'GAP' }
    $prev = $cur
}

$simTotal = 0; $simPeak = 0; $procTally = @{}
if ($HasFault) {
    foreach ($r in $rows) {
        $sim = AsInt $r.sim_hardfaults_s
        $simTotal += $sim
        if ($sim -gt $simPeak) { $simPeak = $sim }
        if ($sim -ge $FAULT_BURST) { Add-Incident $r.timestamp 'FAULT' }
        $p = ("$($r.top_fault_proc)").Trim()
        if ($p) { if (-not $procTally.ContainsKey($p)) { $procTally[$p] = 0 }; $procTally[$p]++ }
    }
}

$ordered = @($incidents.Keys | Sort-Object { [TimeSpan]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
$Start = DT $times[0]
$End   = DT $times[-1]

$gapN   = @($incidents.Values | Where-Object { $_ -contains 'GAP' }).Count
$faultN = @($incidents.Values | Where-Object { $_ -contains 'FAULT' }).Count

Write-Host ("  Session {0} -> {1}   |   {2} incident(s): {3} gap, {4} fault burst" -f `
    $Start.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $End.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $ordered.Count, $gapN, $faultN) -ForegroundColor Cyan
if ($HasFault) {
    Write-Host ("  Per-process fault data present - sim faulted {0} time(s), peak {1}/sec" -f $simTotal, $simPeak) -ForegroundColor Green
} else {
    Write-Host "  No per-process fault data in this trace." -ForegroundColor DarkGray
    Write-Host "  Re-run FullTrace via the menu's 'Hard faults (Admin)' button to get it." -ForegroundColor DarkGray
}

# --- write report ---
$out = Join-Path $desktop 'stutter-events.txt'
"STUTTER EVENT SCAN"                                   | Out-File $out -Encoding utf8
"Trace  : $($csv.Name)"                                | Out-File $out -Append -Encoding utf8
"Window : $Start  ->  $End"                            | Out-File $out -Append -Encoding utf8
"Incidents: $($ordered.Count)   ($gapN timestamp gap, $faultN sim fault burst)" | Out-File $out -Append -Encoding utf8
if ($ordered.Count) {
    foreach ($ts in $ordered) { "  $ts  [$($incidents[$ts] -join '+')]" | Out-File $out -Append -Encoding utf8 }
}

# --- per-process fault attribution ---------------------------------
"" | Out-File $out -Append -Encoding utf8
"=== WHO WAS FAULTING ===" | Out-File $out -Append -Encoding utf8
if (-not $HasFault) {
@"
This trace has no per-process fault data, so the question "which process
caused it" cannot be answered from it.

To get it: menu -> Troubleshoot -> 1) Record a race -> "Hard faults (Admin)".
That runs the same trace with a kernel HARD_FAULTS capture attached and
adds sim_hardfaults_s / top_fault_proc / top_fault_file to the CSV.
Needs the Windows Performance Toolkit (Windows ADK) installed.
"@ | Out-File $out -Append -Encoding utf8
} else {
@"
READ THIS BEFORE BLAMING YOUR STORAGE
-------------------------------------
The hardfaults_s column in the CSV is SYSTEM-WIDE. It is not the sim, and
it is the single most misleading number in the trace. On a reference
25-minute session it recorded 4,712 faults, of which iRacing caused 14 -
0.3%. The rest were NTFS metadata, the Microsoft Store updating apps,
Edge Update, Windows Search and the touch keyboard.

Judge the sim by sim_hardfaults_s below. Judge everything else by which
process keeps appearing in top_fault_proc.
"@ | Out-File $out -Append -Encoding utf8
    "" | Out-File $out -Append -Encoding utf8
    "iRacing's own faults this session : $simTotal   (peak $simPeak/sec)" | Out-File $out -Append -Encoding utf8
    "" | Out-File $out -Append -Encoding utf8
    "Seconds in which each process was the top faulter:" | Out-File $out -Append -Encoding utf8
    $procTally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object {
        $mark = if ($_.Key -match '^iRacingSim64') { '  <-- the sim' } else { '' }
        "  {0,6} sec   {1}{2}" -f $_.Value, $_.Key, $mark | Out-File $out -Append -Encoding utf8
    }
    if ($simTotal -eq 0) {
        "" | Out-File $out -Append -Encoding utf8
        "iRacing did not hard-fault once. Whatever is stuttering, it is not the sim waiting on disk." | Out-File $out -Append -Encoding utf8
    }
}

# Safe Get-WinEvent: FilterHashtable throws "No events were found..." when the
# result set is empty (ErrorAction Stop turns that into a terminating error).
# Callers were treating that as "log off / query failed", which made every
# quiet System window print "(no matching System events)" even when the query
# worked - see GitHub issue #2.
function Get-WinEventsSafe {
    param([hashtable]$Filter, [int]$MaxEvents = 0)
    # Unary comma keeps an empty Object[] from collapsing to $null on return
    # (PowerShell enumerates return values; zero items => assignment becomes $null).
    try {
        if ($MaxEvents -gt 0) {
            return ,@(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop)
        }
        return ,@(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    } catch {
        $msg = "$_"
        if ($msg -match 'No events were found|No matching events were found|NoMatchingEventsFound') {
            return ,@()
        }
        # Log disabled / access denied / bad name - surface as $null so caller can explain.
        return $null
    }
}

function Format-EventLine {
    param($e, [int]$MaxLen = 150)
    $m = (($e.Message) -replace '\s+', ' ').Trim()
    if ($m.Length -gt $MaxLen) { $m = $m.Substring(0, $MaxLen) }
    return ("[{0:HH:mm:ss}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.ProviderName, $m)
}

# 1) scheduled tasks that fired during the whole session (a repeating cadence is the prime suspect)
"" | Out-File $out -Append -Encoding utf8
"=== SCHEDULED TASKS THAT RAN THIS SESSION (Id 100/200) ===" | Out-File $out -Append -Encoding utf8
$t = Get-WinEventsSafe @{ LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=100,200; StartTime=$Start; EndTime=$End }
if ($null -eq $t) {
    "(TaskScheduler Operational log is off or unreadable - run Enable-DiagnosticLogs BEFORE your next race to capture this.)" | Out-File $out -Append -Encoding utf8
} elseif (-not $t.Count) {
    "(none in this window)" | Out-File $out -Append -Encoding utf8
} else {
    foreach ($e in ($t | Sort-Object TimeCreated)) {
        $m = (($e.Message) -replace '\s+', ' ')
        "{0:HH:mm:ss}  {1}" -f $e.TimeCreated, $m.Substring(0, [Math]::Min(150, $m.Length)) | Out-File $out -Append -Encoding utf8
    }
}

# 2) Events near each incident - System is rarely where scheduler/DPC blips live.
# Enable-DiagnosticLogs turns on TaskScheduler/Operational and
# Kernel-Processor-Power/Diagnostic; query those too, plus Application.
"" | Out-File $out -Append -Encoding utf8
"=== EACH INCIDENT: WHAT FAULTED, AND WHAT WINDOWS LOGGED (+/-20s) ===" | Out-File $out -Append -Encoding utf8
if (-not $ordered.Count) {
    "(No incidents detected in this trace - nice and smooth!)" | Out-File $out -Append -Encoding utf8
}

# index rows by timestamp so each incident can report its own fault data
$byTime = @{}
foreach ($r in $rows) { if ($r.timestamp) { $byTime[$r.timestamp] = $r } }

$nearSources = @(
    @{ Name = 'System';                          FilterExtra = @{ Level = 1,2,3 } },
    @{ Name = 'Application';                     FilterExtra = @{ Level = 1,2,3 } },
    @{ Name = 'Microsoft-Windows-TaskScheduler/Operational'; FilterExtra = @{} },
    @{ Name = 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic'; FilterExtra = @{} }
)

foreach ($ts in $ordered) {
    $c = DT $ts
    $winStart = $c.AddSeconds(-20)
    $winEnd   = $c.AddSeconds(20)
    "" | Out-File $out -Append -Encoding utf8
    "--- $ts   [$($incidents[$ts] -join '+')] ---" | Out-File $out -Append -Encoding utf8

    if ($HasFault -and $byTime.ContainsKey($ts)) {
        $r    = $byTime[$ts]
        $sim  = AsInt $r.sim_hardfaults_s
        $proc = ("$($r.top_fault_proc)").Trim()
        $file = ("$($r.top_fault_file)").Trim()
        if ($proc) {
            "  top faulter : $proc" | Out-File $out -Append -Encoding utf8
            if ($file) { "  reading     : $file" | Out-File $out -Append -Encoding utf8 }
        }
        "  sim faults  : $sim   (system-wide that second: $($r.hardfaults_s))" | Out-File $out -Append -Encoding utf8
        if ($sim -eq 0 -and $proc -and $proc -notmatch '^iRacingSim64') {
            "  -> the sim faulted zero times here. This was $proc, not iRacing." | Out-File $out -Append -Encoding utf8
        }
    }

    $anyNear = $false
    $disabledHints = @()
    foreach ($src in $nearSources) {
        $fh = @{ LogName = $src.Name; StartTime = $winStart; EndTime = $winEnd }
        foreach ($k in $src.FilterExtra.Keys) { $fh[$k] = $src.FilterExtra[$k] }
        $ev = Get-WinEventsSafe $fh
        if ($null -eq $ev) {
            $disabledHints += $src.Name
            continue
        }
        if (-not $ev.Count) { continue }
        $anyNear = $true
        "  -- $($src.Name) --" | Out-File $out -Append -Encoding utf8
        foreach ($e in ($ev | Sort-Object TimeCreated | Select-Object -First 25)) {
            "  $(Format-EventLine $e)" | Out-File $out -Append -Encoding utf8
        }
    }

    if (-not $anyNear) {
@"
  (nothing logged in System/Application warnings+errors, TaskScheduler, or
   Kernel-Processor-Power within +/-20s)

  That is normal for a pure DPC / scheduler blip - Windows often writes no
  System warning for those. Look at:
    - SCHEDULED TASKS above (session-wide cadence is the usual culprit)
    - WHO WAS FAULTING (if this trace has per-process columns)
    - a LATENCY / ISR-DPC capture if gaps keep appearing with empty logs

  If TaskScheduler above said the log is off, run Enable-DiagnosticLogs
  (menu: Troubleshoot -> Turn on task log) BEFORE the next traced race.
"@ | Out-File $out -Append -Encoding utf8
    } elseif ($disabledHints.Count) {
        "  (skipped unreadable logs: $($disabledHints -join ', '))" | Out-File $out -Append -Encoding utf8
        if ($disabledHints -match 'TaskScheduler|Kernel-Processor-Power') {
            "  Tip: run Enable-DiagnosticLogs before the next race to capture those." | Out-File $out -Append -Encoding utf8
        }
    }
}
Write-Host "  Done -> $out" -ForegroundColor Green
Start-Process notepad.exe $out
