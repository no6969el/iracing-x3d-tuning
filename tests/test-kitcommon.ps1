# Guards the drift that shipped as the v3.2.5 bug: the quiet list gained
# services, the status screen did not, and it reported "race ready" while
# they were still running. Since v3.3.0 there is one list. This test fails
# if anyone re-introduces a private copy of it.

$scripts = "$PSScriptRoot/../scripts"
. "$scripts/Kit-Common.ps1"

$fail = 0
function Check($ok, $msg) {
    if ($ok) { "    ok   $msg" }
    else     { "    FAIL $msg"; $script:fail++ }
}

"--- Kit-Common exposes what the scripts expect ---"
foreach ($v in 'KitVersion','ServicesToQuiet','TasksToDisable','ServiceDefaults') {
    Check ($null -ne (Get-Variable -Name $v -ErrorAction SilentlyContinue)) "`$$v is defined"
}
Check ($KitVersion -match '^\d+\.\d+\.\d+$') "KitVersion looks like a version ($KitVersion)"
Check ($ServicesToQuiet.Count -gt 0) "$($ServicesToQuiet.Count) services listed"
Check ($TasksToDisable.Count -gt 0)  "$($TasksToDisable.Count) tasks listed"

"--- every quieted service can be restored ---"
# Post-Race-Restore falls back to $ServiceDefaults when there is no snapshot.
# A service with no entry here would be left disabled after a fallback restore,
# which on wuauserv/BITS means no Windows Update and no Defender definitions.
$noDefault = @($ServicesToQuiet | Where-Object { -not $ServiceDefaults.ContainsKey($_) })
Check ($noDefault.Count -eq 0) ("every service has a restore default" + $(if ($noDefault.Count) { " (missing: " + ($noDefault -join ', ') + ")" }))

$orphan = @($ServiceDefaults.Keys | Where-Object { $ServicesToQuiet -notcontains $_ })
Check ($orphan.Count -eq 0) ("no default for a service we never quiet" + $(if ($orphan.Count) { " (orphaned: " + ($orphan -join ', ') + ")" }))

"--- no duplicates ---"
$dupSvc  = @($ServicesToQuiet | Group-Object | Where-Object Count -gt 1)
Check ($dupSvc.Count -eq 0) "no duplicate service entries"
$dupTask = @($TasksToDisable | ForEach-Object { $_.Path + $_.Name } | Group-Object | Where-Object Count -gt 1)
Check ($dupTask.Count -eq 0) "no duplicate task entries"

"--- task entries are well formed ---"
$badPath = @($TasksToDisable | Where-Object { $_.Path -notmatch '^\\.*\\$' })
Check ($badPath.Count -eq 0) "every task Path is \-delimited and \-terminated"
$badName = @($TasksToDisable | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) })
Check ($badName.Count -eq 0) "every task has a Name"

"--- the derived trace filter covers the whole task list ---"
# Trace-QuietReverts used to filter the TaskScheduler log with a hand-typed
# six-folder regex while the list had grown to 22 folders, so most of what
# the kit disables was invisible to it.
$pat = Get-QuietTaskPathPattern
$unmatched = @($TasksToDisable | Where-Object { $_.Path -notmatch $pat })
Check ($unmatched.Count -eq 0) ("regex matches all $($TasksToDisable.Count) task paths" + $(if ($unmatched.Count) { " (missed: " + (($unmatched.Path | Sort-Object -Unique) -join ', ') + ")" }))

"--- Kit-Common is the only place the lists are declared ---"
$leaked = @()
foreach ($f in (Get-ChildItem -Path $scripts -Filter *.ps1 | Where-Object { $_.Name -ne 'Kit-Common.ps1' })) {
    $c = Get-Content $f.FullName -Raw
    # A literal re-declaration is "= @(" then a newline then quoted entries.
    # Filtering the shared list (-KeepSearch, -KeepTouchKeyboard) is fine.
    if ($c -match "\`$ServicesToQuiet\s*=\s*@\(\s*\r?\n\s*'" -or
        $c -match "\`$TasksToDisable\s*=\s*@\(\s*\r?\n\s*@\{") { $leaked += $f.Name }
}
Check ($leaked.Count -eq 0) ("no script keeps its own copy" + $(if ($leaked.Count) { " (found in: " + ($leaked -join ', ') + ")" }))

"--- the four consumers actually load it ---"
foreach ($n in 'Pre-Race-Quiet.ps1','Post-Race-Restore.ps1','Check-Quiet-Status.ps1','Trace-QuietReverts.ps1') {
    $c = Get-Content (Join-Path $scripts $n) -Raw
    Check ($c -match "Kit-Common\.ps1") "$n loads Kit-Common.ps1"
}

""
if ($fail) { "RESULT: $fail assertion(s) failed"; exit 1 }
"RESULT: all assertions passed"
