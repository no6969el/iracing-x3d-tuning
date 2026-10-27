<#
    GamePerf-Common.ps1  -  shared helpers for the GamePerf logger, analyzer and app
    ================================================================
    Dot-source it:   . (Join-Path $PSScriptRoot 'GamePerf-Common.ps1')

    Loads nothing heavy and changes nothing on the machine. The native
    helpers (GamePerf.Native.cs) are only compiled when a caller asks
    for them with Initialize-GpNative - the app's UI never does, so it
    starts fast and stays light.

    Windows PowerShell 5.1 is the target. Nothing here may use PS 6+
    syntax (??, ?:, &&, ||, ConvertFrom-Json -AsHashtable, three-argument
    Join-Path). tests/test-gameperf.ps1 runs PSScriptAnalyzer's 5.1
    syntax check over every GamePerf script to hold that line.
#>

$GamePerfVersion = '1.0.0'

$GpLibDir     = $PSScriptRoot
$GpAppDir     = Split-Path -Parent $GpLibDir
$GpKitDir     = Split-Path -Parent $GpAppDir
$GpKitScripts = Join-Path $GpKitDir 'scripts'
$GpInv        = [Globalization.CultureInfo]::InvariantCulture

# Pinned fallback for the PresentMon download, used only if the GitHub
# "latest release" lookup fails. Verified 2026-10: Intel-signed console build.
$GpPresentMonFallbackUrl  = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'
$GpPresentMonReleasesApi  = 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest'

# ================================================================
#  PROCESS LISTS
# ================================================================
# VR runtimes and compositors. Their CPU is logged as vr_cpu, and the
# config locator adds the runtime's own settings files in VR mode.
$GpVrProcesses = @(
    'vrserver', 'vrcompositor', 'vrmonitor', 'vrdashboard', 'vrwebhelper',   # SteamVR
    'OVRServer_x64', 'OVRRedir', 'OculusDash',                              # Meta / Oculus
    'pi_server', 'PiService', 'PimaxClient', 'PiPlatformService_64',        # Pimax
    'VirtualDesktop.Server', 'VirtualDesktop.Streamer',                     # Virtual Desktop
    'varjo-compositor', 'VarjoBase',                                        # Varjo
    'MixedRealityPortal', 'Oasis'                                           # WMR / Oasis driver
)

# Never chosen as "the game" by auto-detect: shells, launchers, browsers,
# chat, overlays, our own tools. The foreground app is only a candidate
# when it is none of these.
$GpNotGames = @(
    'explorer', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost', 'SearchApp',
    'ApplicationFrameHost', 'TextInputHost', 'LockApp', 'dwm', 'Taskmgr', 'SystemSettings',
    'powershell', 'pwsh', 'powershell_ise', 'WindowsTerminal', 'OpenConsole', 'conhost', 'cmd',
    'steam', 'steamwebhelper', 'EpicGamesLauncher', 'EpicWebHelper', 'Battle.net', 'EADesktop', 'EALauncher',
    'Origin', 'GalaxyClient', 'upc', 'UbisoftConnect', 'RockstarLauncher', 'XboxPcApp', 'GamingServices',
    'iRacingUI', 'iRacingLauncher', 'iRacingService', 'iRacingService64', 'CrewChiefV4', 'SimHub', 'SimHubWPF',
    'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi', 'Discord', 'Slack', 'Teams', 'ms-teams', 'Spotify',
    'MSIAfterburner', 'RTSS', 'RTSSHooksLoader64', 'ProcessLasso', 'ProcessGovernor', 'HWiNFO64', 'CapFrameX',
    'NVIDIA app', 'NVIDIA Share', 'nvcontainer', 'NVIDIA Overlay', 'RadeonSoftware', 'AMDRSServ',
    'OBS64', 'obs64', 'Code', 'devenv', 'notepad', 'notepad++', 'GamePerf', 'PresentMon',
    'OpenKneeboardApp', 'OpenXR-Toolkit', 'XRFrameTools'
) + $GpVrProcesses

# Marker keys offered in the app. Virtual-key codes. Scroll Lock is the
# default because no game binds it and it is one press - easy to find on
# a button box or by feel with a headset on.
$GpMarkerKeys = [ordered]@{
    'ScrollLock' = 0x91
    'Pause'      = 0x13
    'F8'         = 0x77
    'F9'         = 0x78
    'F10'        = 0x79
    'Insert'     = 0x2D
    'NumPad0'    = 0x60
}

# ================================================================
#  PATHS AND SETTINGS
# ================================================================
function Get-GpConfigDir {
    $base = $env:APPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('ApplicationData') }
    Join-Path $base 'GamePerf'
}

function Get-GpLocalDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    Join-Path $base 'GamePerf'
}

function Get-GpSettingsPath { Join-Path (Get-GpConfigDir) 'settings.json' }

function Get-GpDefaultGoals {
    @(
        'Perfect, stutter-free frame pacing at my target frame rate, at the highest visual quality my hardware can hold.'
        'Render at native resolution: no quad views, no foveated rendering (fixed or eye-tracked), and no upscaling'
        '(DLSS / FSR / XeSS Super Resolution). Native-resolution anti-aliasing such as MSAA or DLAA is fine.'
        'When something has to give, cut the settings that cost the most performance for the least visible difference first.'
    ) -join ' '
}

function Get-GpDefaultSettings {
    @{
        SchemaVersion        = 1
        DataRoot             = ''          # '' = Documents\GamePerf
        Game                 = 'auto'
        Mode                 = 'Monitor'   # Monitor | VR
        TargetFpsMonitor     = 0           # 0 = use the monitor refresh rate
        TargetFpsVr          = 90
        CaptureFrames        = $true       # PresentMon (flat screen; VR when allowed without admin)
        SteamVrTiming        = $true       # VR frame timing from the SteamVR compositor (the kit's reader)
        RunElevated          = $true
        StopWithGame         = $false
        MarkerKey            = 'ScrollLock'
        MarkerBeep           = $false      # the logger is silent unless you turn this on
        MinimizeWhileLogging = $true
        PresentMonPath       = ''
        Goals                = (Get-GpDefaultGoals)
        AiProvider           = 'none'
        AiModels             = @{}
        AiBaseUrl            = ''
        AiKeys               = @{}
        AiEffort             = 'high'
        IncludePrevious      = $true
        Redact               = $true
        GameConfigs          = @{}         # game exe -> @(extra config paths the user pinned)
        FirstRunDone         = $false
        PerfLogPending       = $false      # added to Performance Log Users, waiting for a sign-out
    }
}

function ConvertTo-GpHashtable {
    <#
        PSCustomObject (from ConvertFrom-Json) -> nested hashtables and
        arrays. PS 5.1 has no ConvertFrom-Json -AsHashtable.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-GpHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-GpHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void]$list.Add((ConvertTo-GpHashtable $i)) }
        return ,($list.ToArray())
    }
    return $InputObject
}

function Import-GpSettings {
    $s = Get-GpDefaultSettings
    $path = Get-GpSettingsPath
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = ConvertTo-GpHashtable (Read-GpJson $path)
            if ($saved -is [hashtable]) {
                foreach ($k in $saved.Keys) { if ($s.ContainsKey($k)) { $s[$k] = $saved[$k] } }
            }
        } catch { }
    }
    foreach ($k in 'AiModels', 'AiKeys', 'GameConfigs') {
        if (-not ($s[$k] -is [hashtable])) { $s[$k] = @{} }
    }
    if (-not $s.Goals) { $s.Goals = Get-GpDefaultGoals }
    return $s
}

function Export-GpSettings {
    param([Parameter(Mandatory)][hashtable]$Settings)
    $dir = Get-GpConfigDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Write-GpJson -Path (Get-GpSettingsPath) -Object $Settings
}

function Get-GpDataRoot {
    param($Settings)
    if ($Settings -and $Settings.DataRoot) { return [string]$Settings.DataRoot }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = $HOME }
    Join-Path $docs 'GamePerf'
}

function Get-GpSessionsDir {
    param($Settings)
    Join-Path (Get-GpDataRoot $Settings) 'Sessions'
}

function ConvertTo-GpSafeName {
    param([string]$Text, [int]$Max = 40)
    if (-not $Text) { return '' }
    $t = ($Text -replace '[^A-Za-z0-9 _.\-]', '' -replace '\s+', '-').Trim('-', '.')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).Trim('-', '.') }
    return $t
}

function New-GpSessionDir {
    param($Settings, [string]$Hint = '')
    $root = Get-GpSessionsDir $Settings
    $name = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', $GpInv)
    $h = ConvertTo-GpSafeName $Hint
    if ($h) { $name = "$name-$h" }
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# ================================================================
#  CSV SAFETY  (same rules as FullTrace - see its CSV SAFETY block)
# ================================================================
# A comma-decimal locale turns 12.5 into "12,5", which is two fields in
# a CSV. Every number leaves through Inv, every Windows-supplied string
# through Txt. NaN and $null become an empty cell.
function Inv($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { if ($v -eq '') { return '' }; return ($v -replace ',', '') }
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        $d = [double]$v
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return '' }
        return $d.ToString('0.##', $GpInv)
    }
    if ($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] -or $v -is [uint32] -or $v -is [uint64]) {
        return $v.ToString($GpInv)
    }
    if ($v -is [bool]) { if ($v) { return '1' } else { return '0' } }
    return ("$v" -replace ',', '')
}

function Txt($v) {
    if ($null -eq $v -or "$v" -eq '') { return '' }
    return '"' + ("$v" -replace '"', '""') + '"'
}

function Format-GpNum {
    <# Display formatting for reports: invariant, fixed decimals, '-' for missing. #>
    param($Value, [int]$Decimals = 1)
    if ($null -eq $Value -or "$Value" -eq '') { return '-' }
    $d = ConvertTo-GpDouble $Value
    if ([double]::IsNaN($d) -and ($Value -is [string])) { return $Value }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return '-' }
    return $d.ToString('F' + $Decimals, $GpInv)
}

function ConvertTo-GpDouble {
    <# Parse an invariant number; NaN for blanks and junk. #>
    param($Value)
    if ($null -eq $Value) { return [double]::NaN }
    if ($Value -is [double]) { return $Value }
    # Numbers from ConvertFrom-Json arrive as int / long / decimal: cast, never round-trip through a string.
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) { return [double]$Value }
    $d = 0.0
    if ([double]::TryParse("$Value", [Globalization.NumberStyles]::Float, $GpInv, [ref]$d)) { return $d }
    return [double]::NaN
}

# ================================================================
#  FILE IO
# ================================================================
function Write-GpTextFile {
    <# UTF-8 without BOM. #>
    param([Parameter(Mandatory)][string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, [string]$Text, (New-Object Text.UTF8Encoding $false))
}

function Read-GpTextFile {
    <#
        Read a file another process may still have open for writing
        (status.json, a game's live config). Returns $null on failure.
    #>
    param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 0)
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $len = $fs.Length
            if ($MaxBytes -gt 0 -and $len -gt $MaxBytes) { $len = $MaxBytes }
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, [int]($len - $read))
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Dispose() }
        # Honour a UTF-16 BOM (some games write their ini files that way).
        if ($read -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($buf, 2, $read - 2) }
        if ($read -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($buf, 2, $read - 2) }
        $start = 0
        if ($read -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $start = 3 }
        return [Text.Encoding]::UTF8.GetString($buf, $start, $read - $start)
    } catch { return $null }
}

function Write-GpJson {
    <#
        Atomic-enough JSON write: temp file then replace, so a reader
        polling the file (the app reading status.json) never sees half
        a document. Retries briefly if the reader holds it open.
    #>
    param([Parameter(Mandatory)][string]$Path, $Object, [int]$Depth = 10)
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    # A sensor that returned NaN would be written as NaN / "NaN", which is not
    # JSON: Windows PowerShell 5.1's ConvertFrom-Json then rejects the whole file.
    $json = [regex]::Replace($json, '(?<=[:\[,]\s*)"?(?:NaN|-?Infinity)"?(?=\s*[,\]\}\r\n])', 'null')
    $tmp = "$Path.tmp"
    Write-GpTextFile -Path $tmp -Text $json
    for ($i = 0; $i -lt 5; $i++) {
        try {
            # Replace swaps the file in one step: a reader sees the old document
            # or the new one, never a missing or half-written file.
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) }
            else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds 20 }
    }
    try { Copy-Item -LiteralPath $tmp -Destination $Path -Force; Remove-Item -LiteralPath $tmp -Force } catch { }
}

function Read-GpJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $t = Read-GpTextFile -Path $Path
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

# ================================================================
#  NATIVE HELPERS
# ================================================================
function Initialize-GpNative {
    <#
        Compile GamePerf.Native.cs once and cache the DLL under
        %LOCALAPPDATA%\GamePerf\bin, keyed by a hash of the source, so
        later runs load it in milliseconds instead of invoking the
        compiler. Returns $true when the types are available.
    #>
    if ('GamePerf.Native.Win' -as [type]) { return $true }
    $src = Join-Path $GpLibDir 'GamePerf.Native.cs'
    $code = [IO.File]::ReadAllText($src)

    $refs = @()
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 does not reference these by default.
        $refs = @('System.Diagnostics.PerformanceCounter', 'System.Diagnostics.Process', 'System.ComponentModel.Primitives',
                  'System.ComponentModel', 'System.Collections', 'System.Collections.NonGeneric', 'System.Runtime.InteropServices')
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($code + '|' + $PSVersionTable.PSEdition + '|' + $PSVersionTable.PSVersion.Major)
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
    } finally { $sha.Dispose() }

    $binDir = Join-Path (Get-GpLocalDir) 'bin'
    $dll = Join-Path $binDir "GamePerf.Native.$hash.dll"
    if (Test-Path -LiteralPath $dll) {
        try { Add-Type -Path $dll -ErrorAction Stop; return $true } catch { }
    }
    try {
        if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }
        $p = @{ TypeDefinition = $code; OutputAssembly = $dll; OutputType = 'Library'; ErrorAction = 'Stop' }
        if ($refs.Count) { $p.ReferencedAssemblies = $refs }
        Add-Type @p
        if (-not ('GamePerf.Native.Win' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        return $true
    } catch {
        # Cache folder not writable, or a stale DLL is locked: compile in memory.
        try {
            $p = @{ TypeDefinition = $code; ErrorAction = 'Stop' }
            if ($refs.Count) { $p.ReferencedAssemblies = $refs }
            Add-Type @p
            return $true
        } catch { return [bool]('GamePerf.Native.Win' -as [type]) }
    }
}

# ================================================================
#  ELEVATION, SECRETS, PRIVACY
# ================================================================
function Test-GpAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Protect-GpSecret {
    <# DPAPI, current user. The settings file is useless on another account or PC. #>
    param([string]$Plain)
    if (-not $Plain) { return '' }
    try { return (ConvertTo-SecureString -String $Plain -AsPlainText -Force | ConvertFrom-SecureString) } catch { return '' }
}

function Unprotect-GpSecret {
    param([string]$Protected)
    if (-not $Protected) { return '' }
    try {
        $ss = ConvertTo-SecureString -String $Protected
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { return '' }
}

function Protect-GpText {
    <#
        Scrub what we send to an AI provider or put in a file meant for
        sharing: the Windows user name and profile path, the PC name, and
        the value of any key that looks like a credential. Game config
        files are mostly harmless, but the auto-locator reads files we did
        not write, so assume nothing.
    #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    $out = $Text
    $pairs = New-Object System.Collections.ArrayList
    foreach ($p in @(@($env:USERPROFILE, '%USERPROFILE%'), @($HOME, '%USERPROFILE%'))) {
        if ($p[0] -and $p[0].Length -ge 4) { [void]$pairs.Add($p) }
    }
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { [void]$pairs.Add(@($env:USERNAME, '<user>')) }
    if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Length -ge 3) { [void]$pairs.Add(@($env:COMPUTERNAME, '<pc>')) }
    foreach ($p in $pairs) {
        $out = [regex]::Replace($out, [regex]::Escape([string]$p[0]), ([string]$p[1]).Replace('$', '$$'), 'IgnoreCase')
    }
    $secret = '(?im)^(\s*["'']?[\w.\- ]*?(password|passwd|pwd|token|secret|api[_\- ]?key|auth|cookie|session[_\- ]?id|e-?mail|license[_\- ]?key|serial)[\w.\- ]*?["'']?\s*[:=]\s*)(\S.*)$'
    $out = [regex]::Replace($out, $secret, '$1<redacted>')
    return $out
}

# ================================================================
#  PRESENTMON  (per-frame capture)
# ================================================================
function Find-GpPresentMon {
    param($Settings)
    $cands = New-Object System.Collections.ArrayList
    if ($Settings -and $Settings.PresentMonPath) { [void]$cands.Add([string]$Settings.PresentMonPath) }
    foreach ($dir in @((Join-Path $GpAppDir 'tools'), (Join-Path (Get-GpLocalDir) 'tools'))) {
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | ForEach-Object { [void]$cands.Add($_.FullName) }
        }
    }
    foreach ($n in 'PresentMon.exe', 'PresentMon-x64.exe') {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { [void]$cands.Add($c.Source) }
    }
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Install-GpPresentMon {
    <#
        Download Intel's PresentMon console build into GamePerf\tools (or
        %LOCALAPPDATA%\GamePerf\tools when the app folder is read-only),
        and refuse it unless it carries a valid Intel Authenticode
        signature. Returns the path. Throws on failure.
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $hdr = @{ 'User-Agent' = "GamePerf/$GamePerfVersion" }
    $url = $null; $name = $null
    try {
        $rel = Invoke-RestMethod -Uri $GpPresentMonReleasesApi -Headers $hdr -UseBasicParsing -TimeoutSec 20
        $asset = @($rel.assets | Where-Object { $_.name -match '^PresentMon-[\d.]+-x64\.exe$' }) | Select-Object -First 1
        if ($asset) { $url = [string]$asset.browser_download_url; $name = [string]$asset.name }
    } catch { }
    if (-not $url) { $url = $GpPresentMonFallbackUrl; $name = Split-Path -Leaf $url }

    $dest = Join-Path $GpAppDir 'tools'
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest -ErrorAction Stop | Out-Null }
        $probe = Join-Path $dest '.write-test'
        [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
    } catch {
        $dest = Join-Path (Get-GpLocalDir) 'tools'
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    }
    $out = Join-Path $dest $name
    $tmp = "$out.download"
    Invoke-WebRequest -Uri $url -OutFile $tmp -Headers $hdr -UseBasicParsing -TimeoutSec 120
    $sig = Get-AuthenticodeSignature -FilePath $tmp
    $signer = ''
    if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
    if ($sig.Status -ne 'Valid' -or $signer -notmatch 'Intel Corporation') {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "The downloaded PresentMon is not validly signed by Intel (status: $($sig.Status); signer: $signer). It was deleted."
    }
    Move-Item -LiteralPath $tmp -Destination $out -Force
    return $out
}

# ================================================================
#  LAUNCHER (GamePerf.exe)
# ================================================================
function Get-GpLauncherPath {
    <# GamePerf.exe: the one that started us, else the one in the app folder. $null when running as plain scripts. #>
    if ($env:GAMEPERF_LAUNCHER -and (Test-Path -LiteralPath $env:GAMEPERF_LAUNCHER)) { return $env:GAMEPERF_LAUNCHER }
    $p = Join-Path $GpAppDir 'GamePerf.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-GpLauncherInformationalVersion {
    <#
        "<version>+src.<hash>" for GamePerfLauncher.cs. Build-Launcher.ps1
        stamps it into GamePerf.exe; the tests recompute it from the source,
        so a committed exe that was not rebuilt after an edit is caught.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $norm = ($Source -replace "`r`n", "`n") -replace 'AssemblyInformationalVersion\("[^"]*"\)', 'AssemblyInformationalVersion("")'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hex = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').Substring(0, 12).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return "$GamePerfVersion+src.$hex"
}

function Test-GpPerfLogUser {
    <# True when this account's token carries Performance Log Users - per-frame timing then needs no admin prompt. #>
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-559')))
    } catch { return $false }
}

function Start-GpHidden {
    <#
        Start a GamePerf worker with no window: through GamePerf.exe when it is
        there (the process is then "GamePerf" everywhere, and a UAC prompt names
        it), otherwise a hidden Windows PowerShell. -Elevated asks for admin.
        Returns the Process. Throws if the user cancels the UAC prompt.
    #>
    param([Parameter(Mandatory)][ValidateSet('--logger', '--analyze', '--grant-perflog')][string]$Mode,
          [Parameter(Mandatory)][string]$Argument, [switch]$Elevated)
    $launcher = Get-GpLauncherPath
    if ($launcher) {
        $file = $launcher
        $argLine = "$Mode `"$Argument`""
    } else {
        $file = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = switch ($Mode) { '--logger' { 'GamePerf-Logger.ps1' } '--analyze' { 'GamePerf-Analyze.ps1' } default { $null } }
        if (-not $script) { throw 'This option needs GamePerf.exe.' }
        $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $GpLibDir $script)`" -SessionDir `"$Argument`" -Quiet"
    }
    $psi = New-Object Diagnostics.ProcessStartInfo($file, $argLine)
    if ($Elevated) { $psi.UseShellExecute = $true; $psi.Verb = 'runas'; $psi.WindowStyle = 'Hidden' }
    else { $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true }
    return [Diagnostics.Process]::Start($psi)
}

function New-GpShortcut {
    <# A .lnk to GamePerf.exe (with its icon) on the desktop or in the Start menu. Returns the path. #>
    param([Parameter(Mandatory)][ValidateSet('Desktop', 'StartMenu')][string]$Where)
    $target = Get-GpLauncherPath
    if (-not $target) { throw 'GamePerf.exe was not found next to the app.' }
    $dir = $(if ($Where -eq 'Desktop') { [Environment]::GetFolderPath('Desktop') } else { [Environment]::GetFolderPath('Programs') })
    $lnk = Join-Path $dir 'GamePerf.lnk'
    $sh = New-Object -ComObject WScript.Shell
    try {
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = $target
        $s.WorkingDirectory = Split-Path -Parent $target
        $s.IconLocation = "$target,0"
        $s.Description = 'GamePerf - frame-time logger and AI analyst'
        $s.Save()
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    return $lnk
}

# ================================================================
#  SESSIONS
# ================================================================
function Get-GpSessions {
    <#
        Every recorded session, newest first, with the headline numbers
        the app's list shows. Reads only small JSON files.
    #>
    param($Settings)
    $root = Get-GpSessionsDir $Settings
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $meta = Read-GpJson (Join-Path $d.FullName 'session.json')
        if (-not $meta) { continue }
        # card.json is the analyzer's few-hundred-byte digest; summary.json (with chart data) only as a fallback.
        $sum = Read-GpJson (Join-Path $d.FullName 'card.json')
        if (-not $sum) { $sum = Read-GpJson (Join-Path $d.FullName 'summary.json') }
        [void]$out.Add([pscustomobject]@{
            Dir      = $d.FullName
            Name     = $d.Name
            Started  = [string]$meta.started
            Game     = [string]$meta.game_name
            GameExe  = [string]$meta.game_exe
            Label    = [string]$meta.label
            Mode     = [string]$meta.mode
            Duration = $meta.duration_s
            Summary  = $sum
        })
    }
    return $out.ToArray()
}

function Format-GpDuration {
    param($Seconds)
    $s = ConvertTo-GpDouble $Seconds
    if ([double]::IsNaN($s)) { return '-' }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($ts.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes) }
    return ('{0}m {1:00}s' -f $ts.Minutes, $ts.Seconds)
}
