<#
    Add-Defender-Exclusions.ps1
    ---------------------------------------------------------------
    Stops Windows Defender from scanning iRacing's files, which was
    causing continuous hard-pagefault micro-stalls mid-race (Defender
    scanning every texture/asset read). Auto-detects your iRacing
    install + Documents folder and excludes them, plus the sim
    processes. Keeps Defender fully active everywhere else.

    RUN AS ADMINISTRATOR. No reboot needed. Persists.
    (To undo later: Remove-MpPreference -ExclusionPath "<path>")
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: right-click PowerShell -> Run as Administrator, then re-run." -ForegroundColor Red; return }

if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Windows Defender cmdlets not available (third-party AV?). Add exclusions in that product instead." -ForegroundColor Red; return
}

Write-Host ""
Write-Host "Locating iRacing folders..." -ForegroundColor Cyan

$paths = New-Object System.Collections.Generic.List[string]

# 1) Documents\iRacing (setups, replays, telemetry, caches) - almost always exists
$docs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing'
if (Test-Path $docs) { $paths.Add($docs) }

# 2) install dir from a running iRacing process, if any
$proc = Get-Process iRacingSim64DX11, iRacingUI, iRacingService64 -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
if ($proc) { $paths.Add((Split-Path $proc.Path)) }

# 3) scan drives for common install locations
$subs = @(
    'SteamLibrary\steamapps\common\iRacing',
    'Steam\steamapps\common\iRacing',
    'Program Files (x86)\Steam\steamapps\common\iRacing',
    'Program Files (x86)\iRacing',
    'Program Files\iRacing'
)
foreach ($root in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) {
    foreach ($sub in $subs) {
        $c = Join-Path $root $sub
        if (Test-Path $c) { $paths.Add($c) }
    }
}

$paths = $paths | Sort-Object -Unique

if (-not $paths) {
    Write-Host "Could not auto-find the iRacing install folder." -ForegroundColor Yellow
    Write-Host "Edit this script and add your install path manually, or tell Claude the path." -ForegroundColor Yellow
}

# --- add folder exclusions ---
Write-Host ""
Write-Host "Adding folder exclusions:" -ForegroundColor Cyan
foreach ($p in $paths) {
    try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; Write-Host "  + $p" -ForegroundColor Green }
    catch { Write-Host "  ! failed: $p ($($_.Exception.Message))" -ForegroundColor Yellow }
}

# --- add process exclusions ---
Write-Host ""
Write-Host "Adding process exclusions:" -ForegroundColor Cyan
foreach ($ex in 'iRacingSim64DX11.exe','iRacingUI.exe','iRacingService64.exe') {
    try { Add-MpPreference -ExclusionProcess $ex -ErrorAction Stop; Write-Host "  + $ex" -ForegroundColor Green }
    catch { Write-Host "  ! failed: $ex" -ForegroundColor Yellow }
}

# --- confirm ---
Write-Host ""
Write-Host "Current Defender exclusions now set:" -ForegroundColor Cyan
$prefs = Get-MpPreference
Write-Host "  Paths:" -ForegroundColor Gray
$prefs.ExclusionPath | ForEach-Object { Write-Host "    $_" }
Write-Host "  Processes:" -ForegroundColor Gray
$prefs.ExclusionProcess | ForEach-Object { Write-Host "    $_" }

Write-Host ""
Write-Host "Done. Defender still protects everything else - it just won't scan iRacing's files now." -ForegroundColor Green
