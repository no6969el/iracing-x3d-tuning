<#
    iRacing X3D Tuning - Guided Menu
    ---------------------------------------------------------------
    An interactive launcher. Pick a step; it opens in its own window
    so this menu stays your home base. Detects your system on first
    run and remembers it. No PowerShell knowledge needed.

    Just run this file (right-click > Run with PowerShell, or the
    Tuning-Menu shortcut). Nothing here changes settings by itself -
    it only launches the individual scripts, which you approve.
#>

# ---------------------------------------------------------------- setup
$ErrorActionPreference = 'SilentlyContinue'
$Root       = $PSScriptRoot
$ScriptsDir = Join-Path $Root 'scripts'
$ConfigDir  = Join-Path $env:APPDATA 'iRacingX3DTuning'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$SiteUrl    = 'https://no6969el.github.io/iracing-x3d-tuning/start-here.html'
$Accent='Cyan'; $Ok='Green'; $Warn='Yellow'; $Dim='DarkGray'; $Bad='Red'

# ---------------------------------------------------------------- helpers
function Write-C { param([string]$Text,[string]$Color='Gray',[switch]$NoNewline)
    if($NoNewline){ Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color } }

function Spin { param([string]$Text,[int]$Ms=900)
    $frames='|','/','-','\'; $end=(Get-Date).AddMilliseconds($Ms); $i=0
    while((Get-Date) -lt $end){
        Write-Host ("`r  {0} {1}" -f $frames[$i % 4], $Text) -ForegroundColor $Accent -NoNewline
        Start-Sleep -Milliseconds 90; $i++
    }
    Write-Host ("`r  " + (' ' * ($Text.Length + 4)) + "`r") -NoNewline
}

function Pause-Return { Write-Host ""; Write-C "  Press Enter to return to the menu..." $Dim; [void](Read-Host) }

function Save-Config { param($cfg)
    if(-not (Test-Path $ConfigDir)){ New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $cfg | ConvertTo-Json | Out-File -FilePath $ConfigFile -Encoding utf8 }

function Load-Config {
    if(Test-Path $ConfigFile){ try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { return $null } }
    return $null }

# ---------------------------------------------------------------- first-run setup
function Detect-System {
    $cpuName = '(CPU not detected)'; $cores = 0; $gpuName = '(GPU not detected)'
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) {
            if ($cpu.Name) { $cpuName = ([string]$cpu.Name).Trim() }
            if ($cpu.NumberOfCores) { $cores = [int]$cpu.NumberOfCores }
        }
    } catch { }
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if (-not $gpu) { $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($gpu -and $gpu.Name) { $gpuName = [string]$gpu.Name }
    } catch { }
    [pscustomobject]@{ CpuName = $cpuName; Cores = $cores; GpuName = $gpuName }
}

function Run-FirstTimeSetup {
    Clear-Host
    Draw-Banner
    Write-C "  Welcome! First-time setup - let's learn your system (only asked once)." $Accent
    Write-Host ""
    Spin "Detecting your hardware..." 1200
    $d = Detect-System
    Write-C ("  Detected CPU : {0}" -f $d.CpuName) $Ok
    Write-C ("  Detected GPU : {0}" -f $d.GpuName) $Ok
    Write-C ("  Physical cores: {0}" -f $d.Cores) $Ok
    Write-Host ""

    # core profile
    $prof = switch ($d.Cores) { 16 {'16'} 12 {'12'} default {''} }
    if($prof -eq ''){
        Write-C "  Couldn't auto-map your core layout. Which dual-CCD X3D do you have?" $Warn
    } else {
        Write-C ("  That looks like a {0}-core X3D. Is that right?" -f $prof) $Accent
    }
    Write-C "    [1] 16-core  (9950X3D / 7950X3D)  -> V-Cache 0-15, Frequency 16-31" 'Gray'
    Write-C "    [2] 12-core  (9900X3D / 7900X3D)  -> V-Cache 0-11, Frequency 12-23" 'Gray'
    do { $sel = Read-Host "  Choose 1 or 2" } while ($sel -notin '1','2')
    if($sel -eq '1'){ $cores=16; $vcache='0-15'; $freqFirst=16; $freqRange='16-31' }
    else            { $cores=12; $vcache='0-11'; $freqFirst=12; $freqRange='12-23' }

    # display
    Write-Host ""
    Write-C "  Do you race in VR or on a monitor (flatscreen)?" $Accent
    Write-C "    [1] VR    [2] Flatscreen" 'Gray'
    do { $ds = Read-Host "  Choose 1 or 2" } while ($ds -notin '1','2')
    $display = if($ds -eq '1'){'VR'}else{'Flatscreen'}

    $cfg = [pscustomobject]@{
        CpuName=$d.CpuName; GpuName=$d.GpuName; Cores=$cores; Profile="$cores-core"
        VCache=$vcache; FreqFirst=$freqFirst; FreqRange=$freqRange; Display=$display
        Launched=@(); SetupDate=(Get-Date).ToString('u')
    }
    Save-Config $cfg
    Write-Host ""
    Spin "Saving your setup..." 800
    Write-C "  Saved! You won't be asked again. (Reset it anytime with menu option R.)" $Ok
    Start-Sleep -Milliseconds 900
    return $cfg
}

# ---------------------------------------------------------------- UI
function Draw-Banner {
    Write-C "  ============================================================" $Accent
    Write-C "        iRacing  X3D  Tuning        Guided Menu" $Accent
    Write-C "  ============================================================" $Accent
}

function Draw-Header { param($cfg)
    Clear-Host
    Draw-Banner
    Write-C ("   CPU : {0}  ({1})" -f $cfg.CpuName, $cfg.Profile) 'Gray'
    Write-C ("   GPU : {0}" -f $cfg.GpuName) 'Gray'
    Write-C ("   Cores: V-Cache {0}  |  Frequency {1}   |   Display: {2}" -f $cfg.VCache,$cfg.FreqRange,$cfg.Display) 'Gray'
    Write-C "  ------------------------------------------------------------" $Dim
}

function Mark { param($cfg,$file) if($cfg.Launched -contains $file){ '[done]' } else { '     ' } }

function Item { param($key,$text,$done,[switch]$Admin)
    $tag = if($Admin){ ' (admin)' } else { '' }
    $mk  = if($done -eq '[done]'){ '[done] ' } else { '       ' }
    Write-Host "   $key) " -ForegroundColor $Accent -NoNewline
    Write-Host $text -NoNewline
    if($Admin){ Write-Host $tag -ForegroundColor $Warn -NoNewline }
    if($done -eq '[done]'){ Write-Host "   [done]" -ForegroundColor $Ok } else { Write-Host "" }
}

# ---------------------------------------------------------------- launcher
function Launch-Script { param($cfg,[string]$FileName,[switch]$Admin)
    $path = Join-Path $ScriptsDir $FileName
    if(-not (Test-Path $path)){
        Write-Host ""; Write-C "  Can't find $FileName in the scripts folder." $Bad
        Write-C "  Make sure this menu sits next to the 'scripts' folder." $Dim
        Start-Sleep -Milliseconds 2800; return $cfg
    }
    # pass the frequency-CCD first core to scripts that need it
    $env:X3D_FREQ_FIRST_CORE = "$($cfg.FreqFirst)"

    Write-Host ""
    Write-C ("  Launching {0}{1} in a new window..." -f $FileName, $(if($Admin){' (will ask for admin)'}else{''})) $Accent
    Spin "Opening..." 900
    $argStr = "-NoExit -ExecutionPolicy Bypass -File `"$path`""
    try {
        if($Admin){ Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argStr | Out-Null }
        else      { Start-Process -FilePath 'powershell.exe'           -ArgumentList $argStr | Out-Null }
        Write-C "  [OK] Launched in a new window." $Ok
        if($cfg.Launched -notcontains $FileName){ $cfg.Launched += $FileName; Save-Config $cfg }
        Start-Sleep -Milliseconds 1000
    } catch {
        Write-C "  Couldn't launch (did you cancel the admin prompt?): $($_.Exception.Message)" $Warn
        Start-Sleep -Milliseconds 2500
    }
    return $cfg
}

# ---------------------------------------------------------------- submenus
function Setup-FoundationMenu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   SET UP - FOUNDATION  (do these in order, reboot when told)" $Accent
        Write-Host ""
        Item '1' 'Create-Launchers  - make double-click shortcuts (run once)' (Mark $cfg 'Create-Launchers.ps1')
        Item '2' 'Repair-PerfCounters  - only if FullTrace showed blank data' (Mark $cfg 'Repair-PerfCounters.ps1') -Admin
        Item '3' 'Set-GPU-IRQ-Affinity  - steer GPU interrupts off the sim'   (Mark $cfg 'Set-GPU-IRQ-Affinity.ps1') -Admin
        Item '4' 'Set-NIC-USB-IRQ-Affinity  - optional, only if a hitch remains' (Mark $cfg 'Set-NIC-USB-IRQ-Affinity.ps1') -Admin
        Item '5' 'Enable-DiagnosticLogs  - for the stutter-event scanner'      (Mark $cfg 'Enable-DiagnosticLogs.ps1') -Admin
        Write-Host ""
        Write-C "   0) <- Return to main menu" $Warn
        Write-C "  ------------------------------------------------------------" $Dim
        switch (Read-Host "  Select") {
            '1' { $cfg = Launch-Script $cfg 'Create-Launchers.ps1' }
            '2' { $cfg = Launch-Script $cfg 'Repair-PerfCounters.ps1' -Admin }
            '3' { $cfg = Launch-Script $cfg 'Set-GPU-IRQ-Affinity.ps1' -Admin }
            '4' { $cfg = Launch-Script $cfg 'Set-NIC-USB-IRQ-Affinity.ps1' -Admin }
            '5' { $cfg = Launch-Script $cfg 'Enable-DiagnosticLogs.ps1' -Admin }
            '0' { return $cfg }
            default { }
        }
    }
}

function Setup-QuietMenu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   SET UP - QUIET & EXTRAS  (each once)" $Accent
        Write-Host ""
        Item '1' 'Add-Defender-Exclusions  - stop Defender scanning iRacing'  (Mark $cfg 'Add-Defender-Exclusions.ps1') -Admin
        Item '2' 'Apply-Guide-Extras  - USB Selective Suspend + Game Bar off' (Mark $cfg 'Apply-Guide-Extras.ps1') -Admin
        Write-Host ""
        Write-C "   0) <- Return to main menu" $Warn
        Write-C "  ------------------------------------------------------------" $Dim
        switch (Read-Host "  Select") {
            '1' { $cfg = Launch-Script $cfg 'Add-Defender-Exclusions.ps1' -Admin }
            '2' { $cfg = Launch-Script $cfg 'Apply-Guide-Extras.ps1' -Admin }
            '0' { return $cfg }
            default { }
        }
    }
}

function Reset-Menu { param($cfg)
    Draw-Header $cfg
    Write-C "   RESET SAVED SYSTEM INFO" $Warn
    Write-Host ""
    Write-C "  This clears your saved CPU/GPU/core setup and the 'done' marks." 'Gray'
    Write-C "  You'll be asked about your system again next time." 'Gray'
    Write-Host ""
    if((Read-Host "  Type YES to confirm (or anything else to cancel)") -eq 'YES'){
        Spin "Clearing saved setup..." 800
        if(Test-Path $ConfigFile){ Remove-Item $ConfigFile -Force }
        Write-C "  [OK] Cleared. Re-running setup..." $Ok
        Start-Sleep -Milliseconds 900
        return (Run-FirstTimeSetup)
    }
    return $cfg
}

# ---------------------------------------------------------------- main
function Main-Menu { param($cfg)
    while($true){
        Draw-Header $cfg
        Write-C "   MEASURE" $Accent
        Item '1' 'FullTrace  - log a race (Ctrl+C to stop; CSV to Desktop)' (Mark $cfg 'FullTrace.ps1')
        Item '2' 'Preflight-Check  - confirm everything is set'            (Mark $cfg 'Preflight-Check.ps1')
        Item '3' 'Scan-Stutter-Events  - find what caused a stutter'       (Mark $cfg 'Scan-Stutter-Events.ps1')
        Write-Host ""
        Write-C "   SET UP THE FIXES (one-time)" $Accent
        Write-C "   4) Foundation fixes ->" $Accent
        Write-C "   5) Quiet & extras   ->" $Accent
        Write-Host ""
        Write-C "   PER-RACE" $Accent
        Item '6' 'Pre-Race-Quiet  - run BEFORE you race'  (Mark $cfg 'Pre-Race-Quiet.ps1') -Admin
        Item '7' 'Post-Race-Restore  - run AFTER (important)' (Mark $cfg 'Post-Race-Restore.ps1') -Admin
        Write-Host ""
        Write-C "   HELP & SETTINGS" $Accent
        Write-C "   G) Open the guided walkthrough (web)" 'Gray'
        Write-C "   R) Reset saved system info" 'Gray'
        Write-C "   Q) Quit" 'Gray'
        Write-C "  ============================================================" $Accent
        switch ((Read-Host "  Select an option").ToUpper()) {
            '1' { $cfg = Launch-Script $cfg 'FullTrace.ps1' }
            '2' { $cfg = Launch-Script $cfg 'Preflight-Check.ps1' }
            '3' { $cfg = Launch-Script $cfg 'Scan-Stutter-Events.ps1' }
            '4' { $cfg = Setup-FoundationMenu $cfg }
            '5' { $cfg = Setup-QuietMenu $cfg }
            '6' { $cfg = Launch-Script $cfg 'Pre-Race-Quiet.ps1' -Admin }
            '7' { $cfg = Launch-Script $cfg 'Post-Race-Restore.ps1' -Admin }
            'G' { Spin "Opening the guide..." 700; Start-Process $SiteUrl }
            'R' { $cfg = Reset-Menu $cfg }
            'Q' { Clear-Host; Write-C "  Smooth laps." $Ok; Write-Host ""; return }
            default { }
        }
    }
}

# ---------------------------------------------------------------- go
try {
    if(-not (Test-Path $ScriptsDir)){
        Clear-Host; Draw-Banner
        Write-C "  Couldn't find the 'scripts' folder next to this menu." $Bad
        Write-C "  Keep Tuning-Menu.ps1 in the same folder as the 'scripts' folder." $Dim
        Write-Host ""; [void](Read-Host "  Press Enter to exit"); return
    }
    $cfg = Load-Config
    if(-not $cfg){ $cfg = Run-FirstTimeSetup }
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
