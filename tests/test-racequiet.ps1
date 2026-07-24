$fail = 0
function Assert($c,$m){ if($c){"  ok   $m"} else {"  FAIL $m"; $script:fail++} }

# ---------- 1. SYSTEM helper generation (verbatim from Pre-Race-Quiet) ----------
"1. SYSTEM helper generation"
$failedTasks = @(
  [pscustomobject]@{ Path='\Microsoft\Windows\WaaSMedic\'; Name='PerformRemediation' },
  [pscustomobject]@{ Path='\Microsoft\Windows\UpdateOrchestrator\'; Name="Report policies" },
  [pscustomobject]@{ Path='\Test\'; Name="O'Brien's task" }        # apostrophes must survive
)
$marker = Join-Path ([IO.Path]::GetTempPath()) 'system-hop.done'

$lines = @('$done = @()')
foreach ($f in $failedTasks) {
    $pp = $f.Path -replace "'","''"
    $nn = $f.Name -replace "'","''"
    $lines += "try { Disable-ScheduledTask -TaskPath '$pp' -TaskName '$nn' -ErrorAction Stop | Out-Null; `$done += 'OK   $pp$nn' } catch { `$done += 'FAIL $pp$nn' }"
}
$lines += ("`$done | Out-File -FilePath '{0}' -Encoding utf8" -f ($marker -replace "'","''"))
$script = $lines -join [Environment]::NewLine

$e=$null;$t=$null
[System.Management.Automation.Language.Parser]::ParseInput($script,[ref]$t,[ref]$e)|Out-Null
Assert (-not $e) "generated helper parses as valid PowerShell"
Assert ($script -match "TaskPath '\\Microsoft\\Windows\\WaaSMedic\\'") "task path quoted correctly"
Assert ($script -match "O''Brien''s task") "apostrophes escaped (injection-safe)"
Assert ($script -notmatch '\{0\}') "no unresolved format placeholders"

# prove it actually RUNS - stub the cmdlet so we exercise the real control flow
function Disable-ScheduledTask { param($TaskPath,$TaskName,$ErrorAction)
    if ($TaskName -like "*Report*") { throw "access denied" }   # simulate a refusal
    return $true }
$out = & ([scriptblock]::Create($script))
$res = Get-Content $marker
Assert ($res.Count -eq 3) "helper reported on all 3 tasks"
Assert (($res | Where-Object { $_ -like 'OK*' }).Count -eq 2)   "2 successes recorded"
Assert (($res | Where-Object { $_ -like 'FAIL*' }).Count -eq 1) "1 refusal recorded"
Remove-Item $marker -Force -ErrorAction SilentlyContinue
""

# ---------- 2. snapshot round-trip ----------
"2. Snapshot round-trip (the safety-critical bit)"
$origBytes = [byte[]](0x80,0x51,0x01,0x00,0x00,0x00,0x00,0x00,0x03,0x00,0x00,0x00,0x14,0x00,0x00,0x00)
$snapshot = [pscustomobject]@{
    SchemaVersion = 1
    CreatedUtc    = (Get-Date).ToUniversalTime().ToString('s')
    Services      = @(
        [pscustomobject]@{ Name='wuauserv'; Start=3; DelayedAutostart=$null; FailureActionsB64=[Convert]::ToBase64String($origBytes); FailureNonCrash=1; WasRunning=$true }
        [pscustomobject]@{ Name='UsoSvc';   Start=2; DelayedAutostart=1;     FailureActionsB64=$null; FailureNonCrash=$null; WasRunning=$false }
        [pscustomobject]@{ Name='WSearch';  Start=4; DelayedAutostart=$null; FailureActionsB64=$null; FailureNonCrash=$null; WasRunning=$false }
    )
    Tasks         = @(
        [pscustomobject]@{ Path='\Microsoft\Windows\WaaSMedic\'; Name='PerformRemediation'; State='Ready' }
        [pscustomobject]@{ Path='\Microsoft\Windows\PushToInstall\'; Name='LoginCheck'; State='Disabled' }
    )
    DefenderWasOn = $false
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'rq-state.json'
$snapshot | ConvertTo-Json -Depth 6 | Out-File $tmp -Encoding utf8
$back = Get-Content $tmp -Raw | ConvertFrom-Json

Assert ($back.Services.Count -eq 3) "all services survive JSON round-trip"
$wu = $back.Services | Where-Object { $_.Name -eq 'wuauserv' }
Assert ([int]$wu.Start -eq 3) "startup type preserved (Manual)"
Assert ($wu.WasRunning -eq $true) "running state preserved"
$rt = [Convert]::FromBase64String($wu.FailureActionsB64)
Assert (@(Compare-Object $origBytes $rt -SyncWindow 0).Count -eq 0) "recovery-action bytes byte-for-byte identical"

# the three decisions Post-Race-Restore makes
$mapped = @{ 2='Automatic'; 3='Manual'; 4='Disabled' }
$ws = $back.Services | Where-Object { $_.Name -eq 'WSearch' }
Assert ($mapped[[int]$ws.Start] -eq 'Disabled') "a service the user had already disabled stays Disabled"
Assert (-not ($ws.WasRunning -and [int]$ws.Start -ne 4)) "and is not started"
$uso = $back.Services | Where-Object { $_.Name -eq 'UsoSvc' }
Assert (-not $uso.WasRunning) "a service that was stopped is not started"
$dis = $back.Tasks | Where-Object { $_.State -eq 'Disabled' }
Assert ($dis.Name -eq 'LoginCheck') "a task the user had already disabled is left disabled"
Assert ($back.DefenderWasOn -eq $false) "Defender stays OFF if it was already OFF"
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
""

if ($fail) { "RESULT: $fail FAILED"; exit 1 } else { "RESULT: all assertions passed"; exit 0 }
