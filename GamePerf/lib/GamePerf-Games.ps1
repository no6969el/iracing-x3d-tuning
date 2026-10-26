<#
    GamePerf-Games.ps1  -  which game is running, and where its settings live
    ================================================================
    Three ways a config file gets into a session, most trusted first:

      1. CATALOG  - known locations for popular sims and games. Paths are
                    globs, so a renamed renderer ini or a second profile
                    folder is still picked up. A path that does not exist
                    simply contributes nothing.
      2. PINNED   - files you added by hand in the app, remembered per
                    game exe.
      3. SEARCH   - for anything else: the game's install folder and any
                    Documents / Saved Games / AppData folder whose name
                    matches the game, scanned for small config-like files
                    (ini, cfg, json, xml, lua, opt, prf) with names such as
                    graphics / video / render / settings.

    In VR mode the runtime's own settings are added too (SteamVR's
    steamvr.vrsettings, the OpenXR runtime and every implicit API layer -
    which is how a forgotten quad-views or foveated layer shows up).

    Read-only. Nothing here writes outside the session folder.
#>

$GpGameCatalog = @(
    @{ Name = 'iRacing'; Exe = @('iRacingSim64DX11.exe', 'iRacingSim64DX12.exe')
       Configs = @('{Documents}\iRacing\*.ini')
       Notes = 'Graphics live in the rendererDX11*.ini files (one per display mode: Monitor, OpenXR, OpenVR, Oculus) and app.ini. Edit them with the sim closed - it rewrites them on exit.' }
    @{ Name = 'Assetto Corsa Competizione'; Exe = @('AC2-Win64-Shipping.exe')
       Configs = @('{Documents}\Assetto Corsa Competizione\Config\*.json')
       Notes = 'Unreal Engine 4. Settings are JSON in Documents\Assetto Corsa Competizione\Config.' }
    @{ Name = 'Assetto Corsa'; Exe = @('acs.exe', 'acs_x86.exe')
       Configs = @('{Documents}\Assetto Corsa\cfg\video.ini', '{Documents}\Assetto Corsa\cfg\oculus.ini', '{Documents}\Assetto Corsa\cfg\openvr.ini',
                   '{Documents}\Assetto Corsa\cfg\extension\general.ini', '{Documents}\Assetto Corsa\cfg\extension\graphics_adjustments.ini',
                   '{Documents}\Assetto Corsa\cfg\extension\shaders_patch.ini', '{Documents}\Assetto Corsa\cfg\extension\smoke.ini')
       Notes = 'video.ini is the base game. Custom Shaders Patch settings are under cfg\extension.' }
    @{ Name = 'Assetto Corsa EVO'; Exe = @('AssettoCorsaEVO.exe'); Configs = @() }
    @{ Name = 'Automobilista 2'; Exe = @('AMS2AVX.exe', 'AMS2.exe')
       Configs = @('{Documents}\Automobilista 2\*.xml') }
    @{ Name = 'rFactor 2'; Exe = @('rFactor2.exe')
       Configs = @('{Install}\UserData\player\player.JSON', '{Install}\UserData\Config_DX11*.ini',
                   '{SteamApps:rFactor 2}\UserData\player\player.JSON', '{SteamApps:rFactor 2}\UserData\Config_DX11*.ini') }
    @{ Name = 'Le Mans Ultimate'; Exe = @('Le Mans Ultimate.exe', 'LMU.exe')
       Configs = @('{Install}\UserData\player\player.JSON', '{Install}\UserData\Config_DX11*.ini',
                   '{SteamApps:Le Mans Ultimate}\UserData\player\player.JSON', '{SteamApps:Le Mans Ultimate}\UserData\Config_DX11*.ini') }
    @{ Name = 'RaceRoom Racing Experience'; Exe = @('RRRE64.exe', 'RRRE.exe'); Configs = @() }
    @{ Name = 'EA SPORTS WRC'; Exe = @('WRC.exe')
       Configs = @('{Documents}\My Games\WRC\settings\*.xml') }
    @{ Name = 'F1 24'; Exe = @('F1_24.exe'); Configs = @('{Documents}\My Games\F1 24\hardwaresettings\*.xml') }
    @{ Name = 'F1 25'; Exe = @('F1_25.exe'); Configs = @('{Documents}\My Games\F1 25\hardwaresettings\*.xml') }
    @{ Name = 'BeamNG.drive'; Exe = @('BeamNG.drive.x64.exe', 'BeamNG.drive.exe')
       Configs = @('{LocalAppData}\BeamNG.drive\*\settings\*.json', '{LocalAppData}\BeamNG\BeamNG.drive\*\settings\*.json') }
    @{ Name = 'Microsoft Flight Simulator 2020'; Exe = @('FlightSimulator.exe')
       Configs = @('{AppData}\Microsoft Flight Simulator\UserCfg.opt',
                   '{LocalAppData}\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt') }
    @{ Name = 'Microsoft Flight Simulator 2024'; Exe = @('FlightSimulator2024.exe')
       Configs = @('{AppData}\Microsoft Flight Simulator 2024\UserCfg.opt',
                   '{LocalAppData}\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt') }
    @{ Name = 'DCS World'; Exe = @('DCS.exe')
       Configs = @('{SavedGames}\DCS\Config\options.lua', '{SavedGames}\DCS.openbeta\Config\options.lua', '{SavedGames}\DCS*\Config\autoexec.cfg') }
    @{ Name = 'X-Plane 12'; Exe = @('X-Plane.exe')
       Configs = @('{Install}\Output\preferences\X-Plane.prf', '{SteamApps:X-Plane 12}\Output\preferences\X-Plane.prf') }
    @{ Name = 'Elite Dangerous'; Exe = @('EliteDangerous64.exe')
       Configs = @('{LocalAppData}\Frontier Developments\Elite Dangerous\Options\Graphics\*.xml') }
    @{ Name = 'Star Citizen'; Exe = @('StarCitizen.exe')
       Configs = @('{Install}\user.cfg', '{Install}\USER\Client\0\Profiles\default\attributes.xml') }
    @{ Name = 'Cyberpunk 2077'; Exe = @('Cyberpunk2077.exe')
       Configs = @('{LocalAppData}\CD Projekt Red\Cyberpunk 2077\UserSettings.json') }
    @{ Name = 'Half-Life: Alyx'; Exe = @('hlvr.exe'); Configs = @() }
)

# Added in VR mode. Missing ones are skipped.
$GpVrConfigPatterns = @(
    '{Steam}\config\steamvr.vrsettings'
    '{LocalAppData}\Quad-Views-Foveated\*.cfg'
)

# Config-like files the search step will consider.
$GpConfigExtensions = @('.ini', '.cfg', '.json', '.xml', '.lua', '.opt', '.prf', '.yaml', '.yml', '.conf', '.vrsettings')
$GpConfigNameScore = @(
    @{ Pattern = 'graphic|video|render|display|gfx|quality|scalability'; Score = 4 }
    @{ Pattern = 'gameusersettings|usercfg|options|setting|config|prefs|preferences|engine'; Score = 2 }
    @{ Pattern = 'vr|openxr|openvr|oculus|hmd'; Score = 2 }
)
# Folders the search never descends into: huge, or never hold settings.
$GpSearchSkipDirs = '^(cache|shadercache|shaders?|logs?|crash(es|dumps)?|screenshots?|replays?|telemetry|locale|locali[sz]ation|lang(uages)?|movies|music|sounds?|audio|textures?|cars|tracks|models|content|paks?|redist|_commonredist|directx|dotnet|vcredist|\.git|node_modules|__pycache__|temp|tmp|backup)$'

# ================================================================
#  LOCATIONS
# ================================================================
function Get-GpSteamRoot {
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            foreach ($n in 'SteamPath', 'InstallPath') {
                $v = $p.$n
                if ($v -and (Test-Path -LiteralPath $v)) { return ($v -replace '/', '\') }
            }
        } catch { }
    }
    return $null
}

function Get-GpSteamLibraries {
    <#
        Every Steam library folder, from steamapps\libraryfolders.vdf.
        The VDF is a simple nested key/value text format; only the "path"
        entries matter here.
    #>
    param([string]$SteamRoot = (Get-GpSteamRoot), [string]$VdfText)
    $libs = New-Object System.Collections.ArrayList
    if ($SteamRoot) { [void]$libs.Add($SteamRoot) }
    if (-not $VdfText -and $SteamRoot) {
        $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) { $VdfText = Read-GpTextFile -Path $vdf }
    }
    if ($VdfText) {
        foreach ($m in [regex]::Matches($VdfText, '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if ($libs -notcontains $p) { [void]$libs.Add($p) }
        }
    }
    return $libs.ToArray()
}

function Get-GpKnownFolders {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $saved = $null
    try {
        # Saved Games has no SpecialFolder value; the shell folder registry key has it.
        $sg = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'
        if ($sg) { $saved = [Environment]::ExpandEnvironmentVariables($sg) }
    } catch { }
    if (-not $saved -and $env:USERPROFILE) { $saved = Join-Path $env:USERPROFILE 'Saved Games' }
    @{
        Documents    = $docs
        SavedGames   = $saved
        LocalAppData = $env:LOCALAPPDATA
        AppData      = $env:APPDATA
        Steam        = (Get-GpSteamRoot)
    }
}

function Get-GpInstallRoot {
    <# The game's root folder: the exe's folder, climbing out of Bin64 / Binaries\Win64 style subfolders. #>
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    $dir = Split-Path -Parent $ExePath
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
        $leaf = Split-Path -Leaf $dir
        if ($leaf -match '^(bin|bin64|bin32|binaries|win64|win32|x64|x86|windows|wingdk|retail)$') { $dir = Split-Path -Parent $dir }
        else { break }
    }
    return $dir
}

function Expand-GpPattern {
    <# Replace {Documents}, {Install}, {SteamApps:<folder>} ... Returns zero or more concrete patterns. #>
    param([string]$Pattern, [hashtable]$Folders, [string]$InstallRoot, [string[]]$SteamLibraries)
    $out = New-Object System.Collections.ArrayList
    if ($Pattern -match '\{SteamApps:([^}]+)\}') {
        $token = $Matches[0]; $folder = $Matches[1]
        foreach ($lib in $SteamLibraries) {
            if ($lib) { [void]$out.Add($Pattern.Replace($token, ($lib.TrimEnd('\') + "\steamapps\common\$folder"))) }
        }
        return $out.ToArray()
    }
    $p = $Pattern
    foreach ($m in [regex]::Matches($Pattern, '\{(\w+)\}')) {
        $key = $m.Groups[1].Value
        $val = $null
        if ($key -eq 'Install') { $val = $InstallRoot } elseif ($Folders.ContainsKey($key)) { $val = $Folders[$key] }
        if (-not $val) { return @() }
        $p = $p.Replace($m.Value, $val)
    }
    [void]$out.Add($p)
    return $out.ToArray()
}

function Resolve-GpFiles {
    <# Concrete files matching a (possibly wildcarded) path. Small files only. #>
    param([string]$Pattern, [long]$MaxBytes = 1MB)
    $res = New-Object System.Collections.ArrayList
    # Catalog patterns are written with '\'. Only matters off Windows (the tests).
    if ([IO.Path]::DirectorySeparatorChar -ne '\') { $Pattern = $Pattern.Replace('\', '/') }
    try {
        foreach ($i in @(Get-Item -Path $Pattern -Force -ErrorAction SilentlyContinue)) {
            if ($i.PSIsContainer) { continue }
            if ($i.Length -gt $MaxBytes -or $i.Length -eq 0) { continue }
            [void]$res.Add($i.FullName)
        }
    } catch { }
    return $res.ToArray()
}

# ================================================================
#  GAMES
# ================================================================
function Find-GpGameEntry {
    param([string]$Exe)
    if (-not $Exe) { return $null }
    $n = Split-Path -Leaf $Exe
    if ($n -notmatch '\.exe$') { $n = "$n.exe" }
    foreach ($g in $GpGameCatalog) {
        foreach ($e in $g.Exe) { if ($e -ieq $n) { return $g } }
    }
    return $null
}

function Get-GpRunningGames {
    <#
        Windowed processes that could be the game, known titles first.
        Feeds the app's game picker. One process snapshot - cheap.
    #>
    $list = New-Object System.Collections.ArrayList
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($p.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            if ($GpNotGames -contains $p.ProcessName) { continue }
            $exe = "$($p.ProcessName).exe"
            $entry = Find-GpGameEntry $exe
            $name = $p.ProcessName
            if ($entry) { $name = $entry.Name } elseif ($p.MainWindowTitle) { $name = $p.MainWindowTitle }
            [void]$list.Add([pscustomobject]@{
                Exe = $exe; Name = $name; Pid = $p.Id; Known = [bool]$entry
                WorkingSetMb = [math]::Round($p.WorkingSet64 / 1MB)
            })
        } catch { }
    }
    return @($list | Sort-Object @{ Expression = 'Known'; Descending = $true }, @{ Expression = 'WorkingSetMb'; Descending = $true })
}

function ConvertTo-GpNameKey {
    <# 'AC2-Win64-Shipping' -> 'ac2', 'iRacingSim64DX11' -> 'iracingsim64dx11' #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.ToLowerInvariant() -replace '\.exe$', '' -replace '-win64-shipping$|-wingdk-shipping$|-shipping$', ''
    return ($t -replace '[^a-z0-9]', '')
}

function Search-GpConfigCandidates {
    <#
        Breadth-first scan of the given folders for small config-like
        files, scored by name. Bounded in depth and in entries visited so
        it stays well under a second even on a big install.
    #>
    param([string[]]$Roots, [int]$MaxDepth = 3, [int]$Max = 15, [int]$MaxVisited = 20000)
    $found = @{}
    $visited = 0
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        while ($queue.Count -gt 0 -and $visited -lt $MaxVisited) {
            $item = $queue.Dequeue()
            $dir = $item[0]; $depth = $item[1]
            $entries = @()
            try { $entries = [IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
            foreach ($e in $entries) {
                $visited++
                $leaf = [IO.Path]::GetFileName($e)
                $isDir = $false
                try { $isDir = [IO.Directory]::Exists($e) } catch { }
                if ($isDir) {
                    if ($depth -lt $MaxDepth -and $leaf -notmatch $GpSearchSkipDirs) { $queue.Enqueue(@($e, $depth + 1)) }
                    continue
                }
                $ext = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
                if ($GpConfigExtensions -notcontains $ext) { continue }
                $score = 0
                foreach ($r in $GpConfigNameScore) { if ($leaf -match $r.Pattern) { $score += $r.Score } }
                if ($dir -match '\\(config|settings|preferences|options|profiles?|player|userdata|saved)(\\|$)') { $score += 2 }
                if ($score -le 0) { continue }
                try {
                    $fi = New-Object IO.FileInfo($e)
                    if ($fi.Length -lt 20 -or $fi.Length -gt 512KB) { continue }
                    if ($fi.LastWriteTime -gt (Get-Date).AddDays(-60)) { $score += 1 }
                } catch { continue }
                if (-not $found.ContainsKey($e) -or $found[$e] -lt $score) { $found[$e] = $score }
            }
        }
    }
    return @($found.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Max | ForEach-Object { $_.Key })
}

function Get-GpUserFolderMatches {
    <# Documents / Saved Games / AppData folders whose name matches the game. #>
    param([string[]]$Hints, [hashtable]$Folders)
    $keys = @($Hints | ForEach-Object { ConvertTo-GpNameKey $_ } | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    if (-not $keys.Count) { return @() }
    $bases = @()
    foreach ($k in 'Documents', 'SavedGames', 'LocalAppData', 'AppData') { if ($Folders[$k]) { $bases += $Folders[$k] } }
    if ($Folders.Documents) { $bases += (Join-Path $Folders.Documents 'My Games') }
    $out = New-Object System.Collections.ArrayList
    foreach ($b in $bases) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue)) {
            $fk = ConvertTo-GpNameKey $d.Name
            if ($fk.Length -lt 3) { continue }
            foreach ($k in $keys) {
                if ($k -eq $fk -or ($fk.Length -ge 4 -and $k.StartsWith($fk)) -or ($k.Length -ge 4 -and $fk.StartsWith($k))) {
                    [void]$out.Add($d.FullName); break
                }
            }
        }
    }
    return $out.ToArray()
}

function Find-GpGameConfigFiles {
    <#
        Every config file worth sending to the analyst for this game.
        Returns objects: Path, Source (catalog | pinned | search | vr), Note.
    #>
    param(
        [string]$Exe,
        [string]$ExePath,
        [switch]$Vr,
        $Settings,
        [switch]$NoSearch,
        [hashtable]$Folders = (Get-GpKnownFolders),
        [string[]]$SteamLibraries = (Get-GpSteamLibraries)
    )
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param($path, $source, $note)
        $k = $path.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        [void]$out.Add([pscustomobject]@{ Path = $path; Source = $source; Note = $note })
    }
    $install = Get-GpInstallRoot $ExePath
    $entry = Find-GpGameEntry $Exe

    if ($entry) {
        foreach ($pat in $entry.Configs) {
            foreach ($p in (Expand-GpPattern -Pattern $pat -Folders $Folders -InstallRoot $install -SteamLibraries $SteamLibraries)) {
                foreach ($f in (Resolve-GpFiles $p)) { & $add $f 'catalog' $entry.Name }
            }
        }
    }

    $exeKey = ''
    if ($Exe) { $exeKey = (Split-Path -Leaf $Exe) }
    if ($Settings -and $Settings.GameConfigs -and $exeKey -and $Settings.GameConfigs.ContainsKey($exeKey)) {
        foreach ($f in @($Settings.GameConfigs[$exeKey])) {
            if ($f -and (Test-Path -LiteralPath $f)) { & $add ([string]$f) 'pinned' 'added by you' }
        }
    }

    if ($Vr) {
        foreach ($pat in $GpVrConfigPatterns) {
            foreach ($p in (Expand-GpPattern -Pattern $pat -Folders $Folders -InstallRoot $install -SteamLibraries $SteamLibraries)) {
                foreach ($f in (Resolve-GpFiles $p)) { & $add $f 'vr' 'VR runtime' }
            }
        }
    }

    # Search when the catalog had nothing, or the game is not in it.
    $catalogHits = @($out | Where-Object { $_.Source -eq 'catalog' }).Count
    if (-not $NoSearch -and $catalogHits -eq 0) {
        $hints = New-Object System.Collections.ArrayList
        if ($Exe) { [void]$hints.Add([IO.Path]::GetFileNameWithoutExtension($Exe)) }
        if ($entry) { [void]$hints.Add($entry.Name) }
        if ($install) { [void]$hints.Add((Split-Path -Leaf $install)) }
        if ($ExePath) {
            try {
                $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
                if ($vi.ProductName) { [void]$hints.Add($vi.ProductName) }
            } catch { }
        }
        $roots = @()
        if ($install) { $roots += $install }
        $roots += @(Get-GpUserFolderMatches -Hints $hints.ToArray() -Folders $Folders)
        foreach ($f in (Search-GpConfigCandidates -Roots $roots)) { & $add $f 'search' 'found by name' }
    }
    return $out.ToArray()
}

# ================================================================
#  VR RUNTIME CONTEXT
# ================================================================
function Export-GpRegistryText {
    <# A registry key (and its subkeys, to a depth) as readable text. #>
    param([string]$Path, [int]$Depth = 2)
    $sb = New-Object Text.StringBuilder
    $walk = $null
    $walk = {
        param($p, $d)
        $k = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $k) { return }
        [void]$sb.AppendLine("[$($k.Name)]")
        foreach ($n in $k.GetValueNames()) {
            $v = $k.GetValue($n)
            if ($v -is [array]) { $v = ($v -join ', ') }
            $label = $n
            if (-not $label) { $label = '(default)' }
            [void]$sb.AppendLine("$label = $v")
        }
        if ($d -gt 0) { foreach ($c in @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) { & $walk $c.PSPath ($d - 1) } }
    }
    & $walk $Path $Depth
    return $sb.ToString()
}

function Get-GpOpenXrInfo {
    <#
        Active OpenXR runtime and every implicit API layer, with whether it
        is enabled. Implicit layers load into every OpenXR game - an old
        quad-views, foveated-rendering or overlay layer costs frame time
        even when you think you turned it off.
    #>
    $info = [ordered]@{ ActiveRuntime = ''; Layers = @() }
    try {
        $r = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Khronos\OpenXR\1' -ErrorAction Stop).ActiveRuntime
        if ($r) { $info.ActiveRuntime = [string]$r }
    } catch { }
    $layers = New-Object System.Collections.ArrayList
    foreach ($k in 'HKLM:\SOFTWARE\Khronos\OpenXR\1\ApiLayers\Implicit', 'HKCU:\SOFTWARE\Khronos\OpenXR\1\ApiLayers\Implicit') {
        $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) {
            # Loader convention: DWORD 0 = enabled, anything else = disabled.
            [void]$layers.Add([ordered]@{ Manifest = $n; Enabled = ($item.GetValue($n) -eq 0); Scope = ($k -split ':')[0] })
        }
    }
    $info.Layers = $layers.ToArray()
    return $info
}
