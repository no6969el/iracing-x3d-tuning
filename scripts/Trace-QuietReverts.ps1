<#
    Trace-QuietReverts.ps1                                    v3.1.0
    ================================================================
    READ-ONLY forensics. Answers one question:

        "Pre-Race-Quiet ran, and something turned it back on.
         WHAT did it?"

    -Verify in Pre-Race-Quiet tells you THAT something reverted. This tells
    you WHO, by pulling the Windows event logs that record the change and
    laying them out as a timeline next to what the kit did.

    Sources it reads:
      * RaceQuiet.log            - what the kit itself managed to do, and what
                                   it was refused
      * System log, event 7040   - "the start type of X was changed from
                                   disabled to auto start". This is the smoking
                                   gun: it names the service and the moment.
      * System log, event 7036   - services entering the running state
      * WaaSMedic/Operational    - Windows Update Medic remediation activity
      * TaskScheduler/Operational- which scheduled tasks fired in the window
      * WindowsUpdateClient      - update scans kicking off

    RUN THIS ELEVATED. Several of those logs are invisible otherwise, and the
    WaaSMedic tasks don't even appear to a normal user.

    USAGE
      .\Trace-QuietReverts.ps1              since the current/last quiet
      .\Trace-QuietReverts.ps1 -Hours 6     a fixed window instead
      .\Trace-QuietReverts.ps1 -Export      also write a .txt to the Desktop
#>

[CmdletBinding()]
param(
    [int]$Hours,
    [switch]$Export
)

$StateDir  = Join-Path $env:ProgramData 'RaceQuiet'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'RaceQuiet.log'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$StartName = @{ 0='Boot'; 1='System'; 2='Automatic'; 3='Manual'; 4='Disabled' }
$Watched   = @('WaaSMedicSvc','UsoSvc','wuauserv','bits','DoSvc','WSearch')

$out = New-Object System.Collections.ArrayList
function Say { param($t,$c='Gray') Write-Host $t -ForegroundColor $c; [void]$out.Add($t) }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Say ""
Say "  ==========  WHAT UNDID THE QUIET?  ==========" 'Cyan'
if (-not $admin) {
    Say ""
    Say "  ! Not elevated. Some logs and the WaaSMedic tasks are invisible" 'Yellow'
    Say "    from a normal prompt - they will look absent when they are not." 'Yellow'
    Say "    Re-run as administrator for the full picture." 'Yellow'
}

# ---- work out the window to look at ------------------------------
$since = $null
$snap  = $null
if (Test-Path $StateFile) {
    try { $snap = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { }
}
if ($Hours -gt 0) {
    $since = (Get-Date).AddHours(-$Hours)
    Say ""
    Say ("  Window: the last {0} hour(s)" -f $Hours)
} elseif ($snap -and $snap.CreatedUtc) {
    try { $since = ([datetime]$snap.CreatedUtc).ToLocalTime() } catch { }
    Say ""
    Say ("  Window: since the quiet was applied, {0}" -f $since)
}
if (-not $since) {
    $since = (Get-Date).AddHours(-6)
    Say ""
    Say "  No snapshot found - defaulting to the last 6 hours." 'Yellow'
}

# ---- 1. what the kit itself reported ------------------------------
Say ""
Say "  1. What the kit managed to do" 'White'
if (Test-Path $LogFile) {
    $refused = @(Get-Content $LogFile -ErrorAction SilentlyContinue |
                 Where-Object { $_ -match 'could NOT|protected|refused|did not report|FAIL' })
    if ($refused.Count) {
        Say "     It was REFUSED on these - this is very likely your answer:" 'Yellow'
        foreach ($l in ($refused | Select-Object -Last 12)) { Say ("       " + $l.Trim()) 'Yellow' }
    } else {
        Say "     No refusals logged - everything the kit tried, it got." 'Green'
    }
} else {
    Say "     No RaceQuiet.log found - has Pre-Race-Quiet run on this PC?" 'Yellow'
}

# ---- 2. current state vs intended --------------------------------
Say ""
Say "  2. State right now" 'White'
$reverted = @()
foreach ($n in $Watched) {
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    $st = $null
    try { $st = [int](Get-ItemProperty -Path (Join-Path $SvcRoot $n) -Name 'Start' -ErrorAction Stop).Start } catch { }
    $txt = '?'
    if ($null -ne $st -and $StartName.ContainsKey($st)) { $txt = $StartName[$st] }
    if ($st -ne 4) {
        $reverted += $n
        Say ("     REVERTED  {0,-14} {1,-10} {2}" -f $n, $txt, $svc.Status) 'Yellow'
    } else {
        Say ("     ok        {0,-14} {1,-10} {2}" -f $n, $txt, $svc.Status) 'Green'
    }
}

# ---- 3. the smoking gun: start-type changes ----------------------
Say ""
Say "  3. Service start-type changes (System log, event 7040)" 'White'
Say "     This is the definitive record of a service being re-enabled." 'DarkGray'
$found7040 = 0
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7040; StartTime=$since } -ErrorAction Stop
    foreach ($e in $ev) {
        $msg = ($e.Message -replace '\s+',' ').Trim()
        foreach ($w in $Watched) {
            if ($msg -match $w -or $e.Properties[0].Value -eq $w) {
                Say ("     {0:HH:mm:ss}  {1}" -f $e.TimeCreated, $msg) 'Yellow'
                $found7040++
                break
            }
        }
    }
} catch { }
if ($found7040 -eq 0) { Say "     none in this window" 'DarkGray' }

# ---- 4. Windows Update Medic activity ----------------------------
Say ""
Say "  4. Windows Update Medic remediation" 'White'
$medic = 0
foreach ($ln in @('Microsoft-Windows-WaaSMedic/Operational')) {
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName=$ln; StartTime=$since } -ErrorAction Stop
        foreach ($e in ($ev | Select-Object -First 15)) {
            Say ("     {0:HH:mm:ss}  [{1}] {2}" -f $e.TimeCreated, $e.Id, (($e.Message -replace '\s+',' ').Trim() -replace '^(.{150}).*','$1...')) 'Yellow'
            $medic++
        }
    } catch { }
}
if ($medic -eq 0) {
    Say "     nothing logged (the log may be disabled, or Medic stayed down)" 'DarkGray'
} else {
    Say ""
    Say "     ^ Medic ran. If services reverted, this is almost certainly why." 'Yellow'
}

# ---- 5. scheduled tasks that fired -------------------------------
Say ""
Say "  5. Update-related scheduled tasks that fired" 'White'
$tasks = 0
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=200; StartTime=$since } -ErrorAction Stop
    foreach ($e in $ev) {
        $p = ''
        try { $p = [string]$e.Properties[0].Value } catch { }
        if ($p -match 'UpdateOrchestrator|WaaSMedic|InstallService|PushToInstall|WindowsUpdate|Search') {
            Say ("     {0:HH:mm:ss}  {1}" -f $e.TimeCreated, $p) 'Yellow'
            $tasks++
        }
    }
} catch { }
if ($tasks -eq 0) { Say "     none - or the TaskScheduler operational log is off" 'DarkGray' }
if ($tasks -eq 0 -and -not $admin) { Say "     (you are not elevated, so this may be a false negative)" 'Yellow' }

# ---- 6. verdict ---------------------------------------------------
Say ""
Say "  ==========  READ THIS  ==========" 'Cyan'
if ($reverted.Count -eq 0) {
    Say "  Nothing has reverted. The quiet is holding." 'Green'
} else {
    Say ("  Reverted: {0}" -f ($reverted -join ', ')) 'Yellow'
    Say ""
    if ($reverted -contains 'WaaSMedicSvc') {
        Say "  WaaSMedicSvc itself is back. It is the repair service - while it" 'Yellow'
        Say "  runs, it will keep undoing this. On some builds its registry key" 'Yellow'
        Say "  is TrustedInstaller-owned and refuses to disable even as SYSTEM." 'Yellow'
        Say "  Check section 1: if the kit logged 'could NOT disable' for it," 'Yellow'
        Say "  that is your root cause." 'Yellow'
    } elseif ($medic -gt 0) {
        Say "  Medic activity lines up with the reversions - it repaired the" 'Yellow'
        Say "  update stack. Section 1 will show whether the kit was refused" 'Yellow'
        Say "  when it tried to disable the Medic task." 'Yellow'
    } elseif ($found7040 -gt 0) {
        Say "  Something explicitly changed the start types (section 3) but it" 'Yellow'
        Say "  was not Medic. Group Policy or an MDM/Intune profile will do" 'Yellow'
        Say "  this on a managed or work machine, and will win every time." 'Yellow'
        Say "  Check:  gpresult /h `$env:USERPROFILE\Desktop\gp.html" 'Yellow'
    } else {
        Say "  Services are back but nothing logged the change. That usually" 'Yellow'
        Say "  means a reboot happened, or the relevant logs are disabled." 'Yellow'
    }
}
Say ""

if ($Export) {
    $f = Join-Path ([Environment]::GetFolderPath('Desktop')) ("QuietReverts-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $out | Out-File -FilePath $f -Encoding utf8
    Write-Host ("  Saved: {0}" -f $f) -ForegroundColor Green
    Write-Host ""
}
Read-Host "  Press Enter to close" | Out-Null
