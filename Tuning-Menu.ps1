<#
    iRacing X3D Tuning - Guided Menu
    ---------------------------------------------------------------
    Two clear paths:
      * OPTIMIZE  - apply the proven baseline fixes, guided end-to-end
      * TROUBLESHOOT - record & pinpoint a stutter yourself (optional)
    Detects your system once, explains any step on demand (type ?),
    and never changes a setting without you choosing it.

    Run Start-Tuning-Menu.bat, or right-click this > Run with PowerShell.
#>

$ErrorActionPreference = 'SilentlyContinue'
$Root       = $PSScriptRoot
$ScriptsDir = Join-Path $Root 'scripts'
$ConfigDir  = Join-Path $env:APPDATA 'iRacingX3DTuning'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$SiteUrl    = 'https://no6969el.github.io/iracing-x3d-tuning/start-here.html'

# ---- semantic colours (high contrast on dark consoles) ----
$H='Cyan'; $T='White'; $Go='Green'; $Warn='Yellow'; $Bad='Red'; $Dim='DarkGray'

# ---------------------------------------------------------------- helpers
function Write-C { param([string]$Text,[string]$Color=$T) Write-Host $Text -ForegroundColor $Color }
function Rule { Write-Host "  ------------------------------------------------------------" -ForegroundColor $Dim }
function Bar  { Write-Host "  ============================================================" -ForegroundColor $H }

function Spin { param([string]$Text,[int]$Ms=900)
    $frames='|','/','-','\'; $end=(Get-Date).AddMilliseconds($Ms); $i=0
    while((Get-Date) -lt $end){
        Write-Host ("`r  {0} {1}" -f $frames[$i % 4], $Text) -ForegroundColor $H -NoNewline
        Start-Sleep -Milliseconds 90; $i++
    }
    Write-Host ("`r  " + (' ' * ($Text.Length + 4)) + "`r") -NoNewline
}

function Save-Config { param($cfg)
    if(-not (Test-Path $ConfigDir)){ New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $cfg | ConvertTo-Json | Out-File -FilePath $ConfigFile -Encoding utf8 }
function Load-Config {
    if(Test-Path $ConfigFile){ try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { return $null } }
    return $null }

# Backfill physical-core labels for configs saved before the core/thread split.
# The V-Cache CCD holds half of the physical cores; each core is 2 threads.
function Ensure-CoreLabels { param($cfg)
    if(-not $cfg){ return $cfg }
    if(-not $cfg.PSObject.Properties['VCacheCores'] -or -not $cfg.VCacheCores){
        $vcCores = if($cfg.Cores -eq 12){'0-5'} else {'0-7'}
        $cfg | Add-Member -NotePropertyName VCacheCores -NotePropertyValue $vcCores -Force
    }
    if(-not $cfg.PSObject.Properties['FreqCores'] -or -not $cfg.FreqCores){
        $fCores = if($cfg.Cores -eq 12){'6-11'} else {'8-15'}
        $cfg | Add-Member -NotePropertyName FreqCores -NotePropertyValue $fCores -Force
    }
    return $cfg
}

# ---------------------------------------------------------------- first run
function Detect-System {
    $cpuName='(CPU not detected)'; $cores=0; $gpuName='(GPU not detected)'
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) { if ($cpu.Name) { $cpuName = ([string]$cpu.Name).Trim() }; if ($cpu.NumberOfCores) { $cores = [int]$cpu.NumberOfCores } }
    } catch { }
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if (-not $gpu) { $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($gpu -and $gpu.Name) { $gpuName = [string]$gpu.Name }
    } catch { }
    [pscustomobject]@{ CpuName=$cpuName; Cores=$cores; GpuName=$gpuName }
}

function Run-FirstTimeSetup {
    Clear-Host; Bar; Write-C "        iRacing  X3D  Tuning        Guided Menu" $H; Bar
    Write-C "  Welcome! Let's learn your system - this happens only once." $H
    Write-Host ""
    Spin "Detecting your hardware..." 1200
    $d = Detect-System
    Write-C ("  Detected CPU  : {0}" -f $d.CpuName) $Go
    Write-C ("  Detected GPU  : {0}" -f $d.GpuName) $Go
    Write-C ("  Physical cores: {0}" -f $d.Cores) $Go
    Write-Host ""
    $prof = switch ($d.Cores) { 16 {'16'} 12 {'12'} default {''} }
    if($prof -eq ''){ Write-C "  Which dual-CCD X3D do you have?" $Warn }
    else { Write-C ("  That looks like a {0}-core X3D - confirm below:" -f $prof) $H }
    Write-C "    [1] 16-core (9950X3D / 7950X3D)  ->  V-Cache cores 0-7 (CPUs 0-15) | Standard cores 8-15 (CPUs 16-31)" $T
    Write-C "    [2] 12-core (9900X3D / 7900X3D)  ->  V-Cache cores 0-5 (CPUs 0-11) | Standard cores 6-11 (CPUs 12-23)" $T
    do { $sel = Read-Host "  Choose 1 or 2" } while ($sel -notin '1','2')
    if($sel -eq '1'){ $cores=16; $vcache='0-15'; $freqFirst=16; $freqRange='16-31'; $vcacheCores='0-7'; $freqCores='8-15' }
    else            { $cores=12; $vcache='0-11'; $freqFirst=12; $freqRange='12-23'; $vcacheCores='0-5'; $freqCores='6-11' }
    Write-Host ""
    Write-C "  Do you race in VR or on a monitor (flatscreen)?" $H
    Write-C "    [1] VR    [2] Flatscreen" $T
    do { $ds = Read-Host "  Choose 1 or 2" } while ($ds -notin '1','2')
    $display = if($ds -eq '1'){'VR'}else{'Flatscreen'}
    $cfg = [pscustomobject]@{
        CpuName=$d.CpuName; GpuName=$d.GpuName; Cores=$cores; Profile="$cores-core"
        VCache=$vcache; FreqFirst=$freqFirst; FreqRange=$freqRange
        VCacheCores=$vcacheCores; FreqCores=$freqCores; Display=$display
        Launched=@(); SetupDate=(Get-Date).ToString('u') }
    Save-Config $cfg
    Write-Host ""; Spin "Saving your setup..." 800
    Write-C "  Saved! You won't be asked again. (Reset anytime: R on the main menu.)" $Go
    Start-Sleep -Milliseconds 900
    return $cfg
}

# ---------------------------------------------------------------- UI bits
function Draw-Header { param($cfg)
    Clear-Host; Bar; Write-C "        iRacing  X3D  Tuning        Guided Menu" $H; Bar
    Write-C ("   CPU: {0} ({1})  |  GPU: {2}  |  Mode: {3}" -f $cfg.CpuName,$cfg.Profile,$cfg.GpuName,$cfg.Display) $Dim
    Write-C ("   Sim  -> V-Cache cores {0} (CPUs {1})" -f $cfg.VCacheCores,$cfg.VCache) $Dim
    Write-C ("   Back -> Standard cores {0} (CPUs {1})" -f $cfg.FreqCores,$cfg.FreqRange) $Dim
    Rule
}
function Mark { param($cfg,$file) if($cfg.Launched -contains $file){ '[done]' } else { '' } }
function Item { param($key,$text,$done,[switch]$Admin)
    Write-Host "   $key) " -ForegroundColor $H -NoNewline
    Write-Host $text -ForegroundColor $T -NoNewline
    if($Admin){ Write-Host " (admin)" -ForegroundColor $Warn -NoNewline }
    if($done -eq '[done]'){ Write-Host "   [done]" -ForegroundColor $Go } else { Write-Host "" }
}
function Tip { Write-C "   Not sure what something does? Type ? then its number (e.g. ?1)" $H }

# ---------------------------------------------------------------- welcome / help / requirements
function Show-Welcome {
    Clear-Host; Bar; Write-C "        iRacing  X3D  Tuning        Guided Menu" $H; Bar
    Write-Host ""
    Write-C "   Let's make iRacing stutter-free on your dual-CCD X3D." $T
    Write-Host ""
    Write-C "     *  Every change is reversible." $Go
    Write-Host ""
    Write-C "   >> Type  ?  then its number to see more information." $H
    Write-C "      e.g.  ?1  explains step 1: what it does, when/why and" $H
    Write-C "      what comes next." $H
    Write-Host ""
    Write-C "   1) OPTIMIZE MY iRACING  - it walks you" $Go
    Write-C "   through the proven fixes." $Go
    Write-Host ""
    Rule
    [void](Read-Host "   Press Enter to open the menu")
}
function Show-Help { param($cfg)
    Clear-Host; Bar; Write-C "   HELP - How all this works" $H; Bar
    Write-C "   To Learn about any step type ? then a number (e.g. ?2). You'll see" $T
    Write-C "   what it does and why along with what should be next" $T
    Write-Host ""
    Write-C "   TWO PATHS:" $H
    Write-C "     1) OPTIMIZE    - apply the proven baseline (most people)" $T
    Write-C "     2) TROUBLESHOOT- record & pinpoint your own stutter" $T
    Write-C "     3) DO EACH-RACE   - quick before/after routine" $T
    Write-Host ""
    Write-C "   FREE APP YOU'LL NEED (press W for details):" $Warn
    Write-C "     Process Lasso  (free, from bitsum.com)" $T
    Write-Host ""
    Write-C "   You can't break anything - nothing runs unless you choose" $Go
    Write-C "   it, and every change has an Undo (Advanced menu)." $Go
    Bar
    [void](Read-Host "   Press Enter to go back")
}
function Show-Requirements { param($cfg)
    Clear-Host; Bar; Write-C "   WHAT YOU NEED FIRST   (all free)" $H; Bar
    Write-C "   ONE free app does everything - install it before OPTIMIZE:" $T
    Write-Host ""
    Write-C "   Process Lasso     (free, from bitsum.com)" $H
    Write-C "        - Pins iRacing to your V-Cache cores (CPU Sets)" $T
    Write-C "        - Excludes it from ProBalance" $T
    Write-C "        - Activates the 'Bitsum Highest Performance' power plan" $T
    Write-C "          (all cores unparked)  via  Main menu -> Power" $T
    Write-C "        - The free version does all of this." $Go
    Write-Host ""
    Write-C ("   For your {0}, the sim goes on V-Cache cores {1} (CPUs {2})." -f $cfg.Profile,$cfg.VCacheCores,$cfg.VCache) $T
    Write-C "   The web guide (main menu -> G) shows the exact clicks." $T
    Bar
    [void](Read-Host "   Press Enter to go back")
}

# ---------------------------------------------------------------- step info
$Info = @{
 'Optimize'=[pscustomobject]@{ Title='Optimize my iRacing - the proven baseline'
   What='Walks you through every known-good fix in order. Some run automatically (a window opens, works, and closes itself); a couple you do in Process Lasso with exact instructions.'
   Why='The path for almost everyone. No log-reading needed - just follow along and you end up optimized.'
   After='Install the free apps first (press W).'; Next='Reboot once, then use the Each-Race routine. Still stutter? Troubleshoot.' }
 'Troubleshoot'=[pscustomobject]@{ Title='Troubleshoot a stutter - the diagnostic tools'
   What='Record a race, then let the tools find what caused a hitch (a background task, a driver, etc.).'
   Why='For if you STILL stutter after optimizing, or you like to pinpoint your own issue without changing settings blindly.'
   After='Usually after Optimize.'; Next='Apply whatever it points to (often already handled by the Each-Race routine).' }
 'EachRace'=[pscustomobject]@{ Title='Each-race routine - before & after every session'
   What='Before: pauses Windows Update/Search scans (and optionally Defender) so nothing stutters you mid-race. After: turns it all back on.'
   Why='Run it around every session once you are optimized.'
   After='Your one-time Optimize is done.'; Next='Just race.' }
 'Requirements'=[pscustomobject]@{ Title='What you need first - one free app'
   What='Process Lasso (free, bitsum.com). It pins iRacing to your V-Cache cores AND activates the Bitsum Highest Performance power plan (all cores unparked). One app does both.'
   Why='Two of the fixes are done inside it, so install it before Optimize.'
   After='Nothing.'; Next='Run Optimize.' }
 'FullTrace'=[pscustomobject]@{ Title='Record a race (FullTrace)'
   What='Logs your PC ~once a second while you race and saves a CSV to your Desktop. You race, then press Ctrl+C to stop it.'
   Why='It captures your stutters so the other tools can analyze them. Purely for measuring - it changes nothing.'
   After='Turn on the task log first if you plan to scan.'; Next='Find the cause (Scan-Stutter-Events).' }
 'EnableLogs'=[pscustomobject]@{ Title='Turn on the task log (Enable-DiagnosticLogs)  (admin)'
   What='Switches on the Windows TaskScheduler log.'
   Why='So the scanner can later see which task fired. Turn it on BEFORE the race you want to analyze - it only records afterward.'
   After='Before a diagnostic race.'; Next='Record a race, then Find the cause.' }
 'Scan'=[pscustomobject]@{ Title='Find the cause (Scan-Stutter-Events)'
   What='Auto-reads your newest FullTrace CSV, finds the exact stutter moments, and lists the tasks/events around each. No editing needed.'
   Why='Turns a mystery hitch into a named culprit.'
   After='A FullTrace race, with the task log turned on beforehand.'; Next='Handle what it names (often silenced by the Each-Race routine).' }
 'Preflight'=[pscustomobject]@{ Title='Confirm your setup is live (Preflight-Check)'
   What='A quick read-out that verifies the key fixes are active now: power plan, GPU interrupt steering, Process Lasso, cores.'
   Why='Settings can revert after a reboot/update. A green READY means you are good.'
   After='After Optimize.'; Next='Race.' }
 'PreRace'=[pscustomobject]@{ Title='Before I race (Pre-Race-Quiet)  (admin)'
   What='Pauses Windows Update / Search scans (and optionally Defender) for the session.'
   Why='Those scans fire every few minutes and cause periodic stalls. Run EVERY time before you drive.'
   After='You are optimized.'; Next='Race, then After I race.' }
 'PostRace'=[pscustomobject]@{ Title='After I race (Post-Race-Restore)  (admin)'
   What='Turns everything the before-step paused back on (Update, Search, Defender).'
   Why='Run EVERY time after a session - do not skip, or Windows stops updating / scanning.'
   After='Pre-Race-Quiet + your race.'; Next='Done until next time.' }
 'CreateLaunchers'=[pscustomobject]@{ Title='Create-Launchers - double-click shortcuts'
   What='Puts a clickable shortcut next to every script.'; Why='Convenience for running scripts directly.'
   After='Optional.'; Next='Anything.' }
 'Repair'=[pscustomobject]@{ Title='Repair-PerfCounters  (admin, reboot)'
   What='Rebuilds Windows performance counters so logging can read per-core data.'
   Why='ONLY if a FullTrace came back with blank per-core columns.'
   After='A blank trace.'; Next='Reboot, then re-record.' }
 'GpuIrq'=[pscustomobject]@{ Title='Set-GPU-IRQ-Affinity  (admin, reboot)'
   What='Steers GPU interrupts to a frequency-die core, off CPU 0 where the sim runs.'
   Why='A core fix - GPU interrupts on the sim core cause micro-stutters.'
   After='Power plan + CPU Set done.'; Next='Reboot.' }
 'NicUsb'=[pscustomobject]@{ Title='Set-NIC-USB-IRQ-Affinity  (admin, reboot, optional)'
   What='Same as the GPU fix, for network + USB interrupts.'
   Why='Optional - only if a hitch remains after everything else.'
   After='GPU fix tested.'; Next='Reboot, re-test.' }
 'Defender'=[pscustomobject]@{ Title='Add-Defender-Exclusions  (admin)'
   What='Tells Defender to skip iRacing''s folders.'; Why='Stops mid-race file-scan stalls; still protects everything else.'
   After='Any time in setup.'; Next='Apply-Guide-Extras.' }
 'Extras'=[pscustomobject]@{ Title='Apply-Guide-Extras  (admin)'
   What='USB Selective Suspend off + Game Bar/Mode off.'; Why='Stops USB power-cycling hitches.'
   After='Defender exclusions.'; Next='GPU fix.' }
}
function Show-Info { param($key)
    $i = $Info[$key]
    Clear-Host; Bar
    if(-not $i){ Write-C "  (No details for that option.)" $Warn; Start-Sleep -Milliseconds 1200; return }
    Write-Host ""
    Write-C ("   " + $i.Title) $H
    Rule
    Write-C "   WHAT IT DOES" $H;  Write-C ("     " + $i.What)  $T; Write-Host ""
    Write-C "   WHEN & WHY" $H;    Write-C ("     " + $i.Why)   $T; Write-Host ""
    Write-C "   COMES AFTER" $H;   Write-C ("     " + $i.After) $T; Write-Host ""
    Write-C "   NORMALLY NEXT" $H; Write-C ("     " + $i.Next)  $T
    Rule; Write-Host ""
    [void](Read-Host "  Press Enter to go back")
}

# ---------------------------------------------------------------- launcher
function Launch-Script { param($cfg,[string]$FileName,[switch]$Admin,[switch]$AutoClose)
    $path = Join-Path $ScriptsDir $FileName
    if(-not (Test-Path $path)){
        Write-Host ""; Write-C "  Can't find $FileName in the scripts folder." $Bad
        Write-C "  Keep Tuning-Menu.ps1 next to the 'scripts' folder." $Dim
        Start-Sleep -Milliseconds 2800; return $cfg
    }
    $env:X3D_FREQ_FIRST_CORE = "$($cfg.FreqFirst)"
    $noexit = if($AutoClose){''}else{'-NoExit '}
    $argStr = ($noexit + "-ExecutionPolicy Bypass -File `"$path`"")
    Write-Host ""
    Write-C ("  Launching {0}{1}..." -f $FileName, $(if($Admin){' (approve the admin prompt)'}else{''})) $H
    Spin "Opening..." 900
    try {
        if($Admin){ Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argStr | Out-Null }
        else      { Start-Process -FilePath 'powershell.exe'           -ArgumentList $argStr | Out-Null }
        Write-C ("  [OK] Launched" + $(if($AutoClose){' (its window closes itself when done).'}else{' in a new window.'})) $Go
        if($cfg.Launched -notcontains $FileName){ $cfg.Launched += $FileName; Save-Config $cfg }
        Start-Sleep -Milliseconds 1000
    } catch {
        Write-C "  Couldn't launch (did you cancel the admin prompt?): $($_.Exception.Message)" $Warn
        Start-Sleep -Milliseconds 2500
    }
    return $cfg
}

# ---------------------------------------------------------------- OPTIMIZE wizard
function Optimize-Wizard { param($cfg)
    Clear-Host; Bar; Write-C "   OPTIMIZE MY iRACING - guided, end to end" $H; Bar
    Write-C "   I'll walk you through the whole thing, one step at a time." $T
    Write-C "   Auto steps: a window opens, does its job, and closes itself." $T
    Write-C "   Hand steps: you click a few things in Process Lasso, and I" $T
    Write-C "   tell you exactly what." $T
    Write-Host ""
    Write-C "   At any step:  [Enter] do it    [S] skip    [Q] stop" $Warn
    Write-Host ""
    Write-C "   Don't have the free apps yet? Press Q, then W on the menu." $Go
    Write-Host ""
    if((Read-Host "   Press Enter to begin (or Q to quit)") -match '^[Qq]'){ return $cfg }

    $steps = @(
        @{ type='manual'; title='Power plan  (in Process Lasso)'; lines=@(
            'Open Process Lasso.',
            'Main menu -> Power -> activate  Bitsum Highest Performance.',
            'This keeps all cores unparked - what the sim needs.') },
        @{ type='manual'; title='Pin the sim  (in Process Lasso)'; lines=@(
            'Run iRacing once so iRacingSim64DX11.exe shows in the list.',
            ("Right-click it  ->  CPU Sets  ->  tick CPUs {0} (V-Cache cores {1})." -f $cfg.VCache,$cfg.VCacheCores),
            'Right-click it  ->  ProBalance  ->  exclude it.') },
        @{ type='auto'; title='Defender exclusions'; script='Add-Defender-Exclusions.ps1' },
        @{ type='auto'; title='USB Suspend + Game Bar off'; script='Apply-Guide-Extras.ps1' },
        @{ type='auto'; title='Turn on the diagnostic log'; script='Enable-DiagnosticLogs.ps1' },
        @{ type='auto'; title='GPU interrupts off the sim core'; script='Set-GPU-IRQ-Affinity.ps1' },
        @{ type='manual'; title='iRacing + NVIDIA settings'; lines=@(
            'These have no script - set them yourself:',
            'Open the web guide (main menu -> G) and apply the iRacing',
            'in-game options and the NVIDIA Control Panel values it lists.') }
    )
    $total=$steps.Count; $n=0; $stopped=$false
    foreach($s in $steps){
        $n++
        Clear-Host; Bar
        $kind = if($s.type -eq 'auto'){'runs automatically'}else{'you do this by hand'}
        Write-C ("   Step {0} of {1}   ({2})" -f $n,$total,$kind) $H
        Write-C ("   " + $s.title) $H
        Rule
        if($s.type -eq 'manual'){ foreach($l in $s.lines){ Write-C ("   " + $l) $T } }
        else { Write-C "   A window will open, ask for admin, do its job, and close." $T }
        Write-Host ""
        $prompt = if($s.type -eq 'auto'){'run it'}else{"I've done it"}
        $a = Read-Host "   [Enter] $prompt    [S] skip    [Q] stop"
        if($a -match '^[Qq]'){ $stopped=$true; break }
        if($a -match '^[Ss]'){ continue }
        if($s.type -eq 'auto'){ $cfg = Launch-Script $cfg $s.script -Admin -AutoClose }
    }
    Clear-Host; Bar
    if($stopped){ Write-C "   Stopped - resume anytime from Optimize." $Warn }
    else { Write-C "   ALL DONE - your baseline is applied." $Go }
    Write-Host ""
    Write-C "   Two last things:" $H
    Write-C "     1) REBOOT once - the GPU interrupt change needs it." $T
    Write-C "     2) Each session: run the Each-Race routine (before / after)." $T
    Write-Host ""
    Write-C "   Still feel a stutter after this? Use Troubleshoot to pinpoint it." $T
    Bar
    [void](Read-Host "   Press Enter to return to the menu")
    return $cfg
}

# ---------------------------------------------------------------- submenus
function Troubleshoot-Menu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   TROUBLESHOOT A STUTTER" $H
        Write-C "   Record a race, then pinpoint what caused a hitch." $T
        Write-Host ""
        Item '1' 'Record a race (FullTrace)  - race, then press Ctrl+C' (Mark $cfg 'FullTrace.ps1')
        Item '2' 'Turn on the task log  (do this BEFORE the race)'       (Mark $cfg 'Enable-DiagnosticLogs.ps1') -Admin
        Item '3' 'Find the cause (Scan-Stutter-Events)'                  (Mark $cfg 'Scan-Stutter-Events.ps1')
        Item '4' 'Confirm your setup is live (Preflight-Check)'          (Mark $cfg 'Preflight-Check.ps1')
        Write-Host ""
        Write-C "   0) <- Back to main menu" $Warn
        Tip; Rule
        $raw = ([string](Read-Host "  Select")).Trim()
        if($raw -match '^\?\s*(.+)$'){ $mp=@{'1'='FullTrace';'2'='EnableLogs';'3'='Scan';'4'='Preflight'}; $k=$mp[$Matches[1].Trim()]; if($k){Show-Info $k}else{Write-C "  (no info)" $Warn; Start-Sleep -Milliseconds 800}; continue }
        switch ($raw) {
            '1' { $cfg = Launch-Script $cfg 'FullTrace.ps1' }
            '2' { $cfg = Launch-Script $cfg 'Enable-DiagnosticLogs.ps1' -Admin }
            '3' { $cfg = Launch-Script $cfg 'Scan-Stutter-Events.ps1' }
            '4' { $cfg = Launch-Script $cfg 'Preflight-Check.ps1' }
            '0' { return $cfg }
            default { }
        }
    }
}
function EachRace-Menu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   EACH-RACE ROUTINE" $H
        Write-C "   Quiet the PC before you drive, put it all back after." $T
        Write-Host ""
        Item '1' 'Before I race  (Pre-Race-Quiet)'   (Mark $cfg 'Pre-Race-Quiet.ps1') -Admin
        Item '2' 'After I race   (Post-Race-Restore)' (Mark $cfg 'Post-Race-Restore.ps1') -Admin
        Write-Host ""
        Write-C "   0) <- Back to main menu" $Warn
        Tip; Rule
        $raw = ([string](Read-Host "  Select")).Trim()
        if($raw -match '^\?\s*(.+)$'){ $mp=@{'1'='PreRace';'2'='PostRace'}; $k=$mp[$Matches[1].Trim()]; if($k){Show-Info $k}else{Write-C "  (no info)" $Warn; Start-Sleep -Milliseconds 800}; continue }
        switch ($raw) {
            '1' { $cfg = Launch-Script $cfg 'Pre-Race-Quiet.ps1' -Admin }
            '2' { $cfg = Launch-Script $cfg 'Post-Race-Restore.ps1' -Admin }
            '0' { return $cfg }
            default { }
        }
    }
}
function Advanced-Menu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   ADVANCED - run or undo individual fixes" $H
        Write-C "   Most people don't need this - use Optimize instead." $Dim
        Write-Host ""
        Write-C "   RUN INDIVIDUALLY" $H
        Item '1' 'Create-Launchers'            (Mark $cfg 'Create-Launchers.ps1')
        Item '2' 'Repair-PerfCounters'         (Mark $cfg 'Repair-PerfCounters.ps1') -Admin
        Item '3' 'Set-GPU-IRQ-Affinity'        (Mark $cfg 'Set-GPU-IRQ-Affinity.ps1') -Admin
        Item '4' 'Set-NIC-USB-IRQ-Affinity'    (Mark $cfg 'Set-NIC-USB-IRQ-Affinity.ps1') -Admin
        Item '5' 'Add-Defender-Exclusions'     (Mark $cfg 'Add-Defender-Exclusions.ps1') -Admin
        Item '6' 'Apply-Guide-Extras'          (Mark $cfg 'Apply-Guide-Extras.ps1') -Admin
        Write-Host ""
        Write-C "   UNDO" $H
        Item '7' 'Undo-GPU-IRQ-Affinity'       '' -Admin
        Item '8' 'Undo-NIC-USB-IRQ-Affinity'   '' -Admin
        Item '9' 'Undo-Guide-Extras'           '' -Admin
        Write-Host ""
        Write-C "   0) <- Back to main menu" $Warn
        Tip; Rule
        $raw = ([string](Read-Host "  Select")).Trim()
        if($raw -match '^\?\s*(.+)$'){ $mp=@{'1'='CreateLaunchers';'2'='Repair';'3'='GpuIrq';'4'='NicUsb';'5'='Defender';'6'='Extras'}; $k=$mp[$Matches[1].Trim()]; if($k){Show-Info $k}else{Write-C "  (no info for that)" $Warn; Start-Sleep -Milliseconds 800}; continue }
        switch ($raw) {
            '1' { $cfg = Launch-Script $cfg 'Create-Launchers.ps1' }
            '2' { $cfg = Launch-Script $cfg 'Repair-PerfCounters.ps1' -Admin }
            '3' { $cfg = Launch-Script $cfg 'Set-GPU-IRQ-Affinity.ps1' -Admin }
            '4' { $cfg = Launch-Script $cfg 'Set-NIC-USB-IRQ-Affinity.ps1' -Admin }
            '5' { $cfg = Launch-Script $cfg 'Add-Defender-Exclusions.ps1' -Admin }
            '6' { $cfg = Launch-Script $cfg 'Apply-Guide-Extras.ps1' -Admin }
            '7' { $cfg = Launch-Script $cfg 'Undo-GPU-IRQ-Affinity.ps1' -Admin }
            '8' { $cfg = Launch-Script $cfg 'Undo-NIC-USB-IRQ-Affinity.ps1' -Admin }
            '9' { $cfg = Launch-Script $cfg 'Undo-Guide-Extras.ps1' -Admin }
            '0' { return $cfg }
            default { }
        }
    }
}
function Reset-Menu { param($cfg)
    Draw-Header $cfg
    Write-C "   RESET SAVED SYSTEM INFO" $Warn
    Write-Host ""
    Write-C "  Clears your saved CPU/GPU/core setup and the 'done' marks." $T
    Write-C "  You'll be asked about your system again next time." $T
    Write-Host ""
    if((Read-Host "  Type YES to confirm (anything else cancels)") -eq 'YES'){
        Spin "Clearing saved setup..." 800
        if(Test-Path $ConfigFile){ Remove-Item $ConfigFile -Force }
        Write-C "  [OK] Cleared. Re-running setup..." $Go; Start-Sleep -Milliseconds 900
        return (Run-FirstTimeSetup)
    }
    return $cfg
}

# ---------------------------------------------------------------- main menu
function Main-Menu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   What would you like to do?" $T
        Write-Host ""
        Write-Host "   1) " -ForegroundColor $H -NoNewline; Write-Host "OPTIMIZE MY iRACING" -ForegroundColor $Go -NoNewline; Write-Host "   (recommended)" -ForegroundColor $Go
        Write-C "        Apply the proven baseline fixes, guided. Good starting point." $T
        Write-Host ""
        Write-Host "   2) " -ForegroundColor $H -NoNewline; Write-Host "TROUBLESHOOT A STUTTER" -ForegroundColor $T
        Write-C "        Record & pinpoint a specific issue with guided tools." $T
        Write-Host ""
        Write-Host "   3) " -ForegroundColor $H -NoNewline; Write-Host "EACH-RACE ROUTINE" -ForegroundColor $T
        Write-C "        Run before and after every session." $T
        Write-Host ""
        Rule
        Write-C "   [W] What do I need? (free apps)    [A] Advanced tools     [R] Reset layout" $H
        Write-C "   [H] Help / Info                    [G] Web guide          [Q] Quit" $H
        Write-Host ""
        Tip; Bar
        $raw = ([string](Read-Host "   Select an option")).Trim()
        if($raw -match '^\?\s*(.+)$'){
            $mp=@{'1'='Optimize';'2'='Troubleshoot';'3'='EachRace';'W'='Requirements'}
            $k=$mp[$Matches[1].Trim()]
            if($k){ Show-Info $k } else { Write-C "  (no info for that)" $Warn; Start-Sleep -Milliseconds 900 }
            continue
        }
        switch ($raw.ToUpper()) {
            '1' { $cfg = Optimize-Wizard $cfg }
            '2' { $cfg = Troubleshoot-Menu $cfg }
            '3' { $cfg = EachRace-Menu $cfg }
            'W' { Show-Requirements $cfg }
            'A' { $cfg = Advanced-Menu $cfg }
            'H' { Show-Help $cfg }
            'G' { Spin "Opening the web guide..." 700; Start-Process $SiteUrl }
            'R' { $cfg = Reset-Menu $cfg }
            'Q' { Clear-Host; Write-C "  Smooth laps." $Go; Write-Host ""; return }
            default { }
        }
    }
}

# ---------------------------------------------------------------- go
try {
    if(-not (Test-Path $ScriptsDir)){
        Clear-Host; Bar
        Write-C "  Couldn't find the 'scripts' folder next to this menu." $Bad
        Write-C "  Keep Tuning-Menu.ps1 in the same folder as the 'scripts' folder." $Dim
        Write-Host ""; [void](Read-Host "  Press Enter to exit"); return
    }
    $cfg = Load-Config
    if(-not $cfg){ $cfg = Run-FirstTimeSetup } else { $cfg = Ensure-CoreLabels $cfg }
    Main-Menu $cfg
} catch {
    Write-Host ""
    Write-Host "  Something went wrong:" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (Line $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Please screenshot this and send it over." -ForegroundColor Yellow
    [void](Read-Host "  Press Enter to close")
}
