<#
    X3D-Profiles.ps1  -  shared CPU topology resolver
    ================================================================
    SINGLE SOURCE OF TRUTH. Every other script dot-sources this:

        . (Join-Path $PSScriptRoot 'X3D-Profiles.ps1')
        $P = Get-X3DProfile

    Replaces the old "guess from core count" logic that lived in six
    places and disagreed with itself. Resolves topology in four layers,
    most reliable first:

      1. CPU name  -> catalog lookup (all 18 X3D SKUs, below)
      2. L3 cache topology via GetLogicalProcessorInformationEx
         (finds real CCD boundaries + which CCDs carry V-Cache, so
         chips AMD hasn't shipped yet still resolve correctly)
      3. Total L3 size from WMI (cheap X3D / non-X3D discriminator)
      4. Core-count heuristic (last resort)

    Everything is validated against the CPUs Windows actually reports,
    so a target core can never point at a processor that doesn't exist.

    TESTING
    -------
    Set X3D_FORCE_PROFILE to any model in the catalog to make the whole
    kit behave as if it were running on that chip:

        $env:X3D_FORCE_PROFILE = '5600X3D'

    Scripts that write to the registry detect the simulated profile and
    run in DRY-RUN mode instead - nothing is changed. Unset the variable
    (or close the window) to go back to real detection.
#>

# Bump this when the shape of config.json changes. Saved configs with an
# older/absent version are discarded and re-detected rather than trusted.
$script:X3DSchemaVersion = 3

$script:X3DConfigDir  = Join-Path $env:APPDATA 'iRacingX3DTuning'
$script:X3DConfigFile = Join-Path $script:X3DConfigDir 'config.json'

# ================================================================
#  CATALOG  -  every X3D processor AMD has shipped
#  Ordered most-specific-first; Match is a regex tested against the
#  CPU name string. VCache: 'all' (single CCD), 'ccd0' (asymmetric
#  dual), 'both' (symmetric dual, 9950X3D2 only).
# ================================================================
$script:X3DCatalog = @(
    # ---- Zen 5 / AM5 ----
    @{ Match='9950X3D2';      Model='Ryzen 9 9950X3D2 Dual Edition'; Arch='Zen 5'; Platform='AM5'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='both'; Form='desktop' },
    @{ Match='9950X3D(?!2)';  Model='Ryzen 9 9950X3D';               Arch='Zen 5'; Platform='AM5'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='ccd0'; Form='desktop' },
    @{ Match='9900X3D';       Model='Ryzen 9 9900X3D';               Arch='Zen 5'; Platform='AM5'; Cores=12; CCDs=2; Ccd0Cores=6; VCache='ccd0'; Form='desktop' },
    @{ Match='9850X3D';       Model='Ryzen 7 9850X3D';               Arch='Zen 5'; Platform='AM5'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='9800X3D';       Model='Ryzen 7 9800X3D';               Arch='Zen 5'; Platform='AM5'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='9955HX3D';      Model='Ryzen 9 9955HX3D (mobile)';     Arch='Zen 5'; Platform='FL1'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='ccd0'; Form='mobile'  },

    # ---- Zen 4 / AM5 ----
    @{ Match='7950X3D';       Model='Ryzen 9 7950X3D';               Arch='Zen 4'; Platform='AM5'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='ccd0'; Form='desktop' },
    @{ Match='7900X3D';       Model='Ryzen 9 7900X3D';               Arch='Zen 4'; Platform='AM5'; Cores=12; CCDs=2; Ccd0Cores=6; VCache='ccd0'; Form='desktop' },
    @{ Match='7800X3D';       Model='Ryzen 7 7800X3D';               Arch='Zen 4'; Platform='AM5'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='7700X3D';       Model='Ryzen 7 7700X3D';               Arch='Zen 4'; Platform='AM5'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='7600X3D';       Model='Ryzen 5 7600X3D';               Arch='Zen 4'; Platform='AM5'; Cores=6;  CCDs=1; Ccd0Cores=6; VCache='all';  Form='desktop' },
    @{ Match='7500X3D';       Model='Ryzen 5 7500X3D';               Arch='Zen 4'; Platform='AM5'; Cores=6;  CCDs=1; Ccd0Cores=6; VCache='all';  Form='desktop' },
    @{ Match='7945HX3D';      Model='Ryzen 9 7945HX3D (mobile)';     Arch='Zen 4'; Platform='FL1'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='ccd0'; Form='mobile'  },

    # ---- Zen 3 / AM4 ----
    @{ Match='5800X3D';       Model='Ryzen 7 5800X3D';               Arch='Zen 3'; Platform='AM4'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='5700X3D';       Model='Ryzen 7 5700X3D';               Arch='Zen 3'; Platform='AM4'; Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop' },
    @{ Match='5600X3D';       Model='Ryzen 5 5600X3D';               Arch='Zen 3'; Platform='AM4'; Cores=6;  CCDs=1; Ccd0Cores=6; VCache='all';  Form='desktop' },
    @{ Match='5500X3D';       Model='Ryzen 5 5500X3D';               Arch='Zen 3'; Platform='AM4'; Cores=6;  CCDs=1; Ccd0Cores=6; VCache='all';  Form='desktop' }
)

function Get-X3DCatalog { return $script:X3DCatalog }

# ----------------------------------------------------------------
#  Classes offered by the manual "which chip do you have?" picker.
#  Grouped rather than 18 separate entries - everything inside a
#  group behaves identically as far as this kit is concerned.
# ----------------------------------------------------------------
$script:X3DClasses = @(
    @{ Key='1'; Label='6-core single-CCD';  Examples='5500X3D / 5600X3D / 7500X3D / 7600X3D';
       Model='6-core single-CCD X3D';  Cores=6;  CCDs=1; Ccd0Cores=6; VCache='all';  Form='desktop'; Arch=''; Platform='' },
    @{ Key='2'; Label='8-core single-CCD';  Examples='5700X3D / 5800X3D / 7700X3D / 7800X3D / 9800X3D / 9850X3D';
       Model='8-core single-CCD X3D';  Cores=8;  CCDs=1; Ccd0Cores=8; VCache='all';  Form='desktop'; Arch=''; Platform='' },
    @{ Key='3'; Label='12-core dual-CCD';   Examples='7900X3D / 9900X3D';
       Model='12-core dual-CCD X3D';   Cores=12; CCDs=2; Ccd0Cores=6; VCache='ccd0'; Form='desktop'; Arch=''; Platform='' },
    @{ Key='4'; Label='16-core dual-CCD';   Examples='7950X3D / 9950X3D / 7945HX3D / 9955HX3D';
       Model='16-core dual-CCD X3D';   Cores=16; CCDs=2; Ccd0Cores=8; VCache='ccd0'; Form='desktop'; Arch=''; Platform='' },
    @{ Key='5'; Label='16-core dual-CCD, V-Cache on BOTH CCDs'; Examples='9950X3D2 Dual Edition';
       Model='16-core dual-CCD X3D (both cached)'; Cores=16; CCDs=2; Ccd0Cores=8; VCache='both'; Form='desktop'; Arch=''; Platform='' },
    @{ Key='6'; Label='Something else / not an X3D'; Examples='general fixes only - no core pinning or interrupt steering';
       Model='';                        Cores=0;  CCDs=0; Ccd0Cores=0; VCache='none'; Form='unknown'; Arch=''; Platform='' }
)

function Get-X3DClasses { return $script:X3DClasses }

# ================================================================
#  Layer 2: real CCD boundaries from L3 cache topology
# ================================================================
function Initialize-X3DCacheProbe {
    if ('X3DCacheProbe' -as [type]) { return $true }
    $code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class X3DCacheProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformationEx(
        int RelationshipType, IntPtr Buffer, ref uint ReturnedLength);

    // Each entry: { mask, group, cacheSizeBytes }
    public static List<ulong[]> GetL3Pools()
    {
        uint len = 0;
        GetLogicalProcessorInformationEx(2, IntPtr.Zero, ref len);   // 2 = RelationCache
        if (len == 0) { return null; }

        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try
        {
            if (!GetLogicalProcessorInformationEx(2, buf, ref len)) { return null; }

            List<ulong[]> pools = new List<ulong[]>();
            long baseAddr = buf.ToInt64();
            int off = 0;
            while (off + 8 <= (int)len)
            {
                IntPtr p = new IntPtr(baseAddr + off);
                int rel  = Marshal.ReadInt32(p, 0);   // LOGICAL_PROCESSOR_RELATIONSHIP
                int size = Marshal.ReadInt32(p, 4);   // record size, used to walk
                if (size <= 0) { break; }

                if (rel == 2 && off + size <= (int)len)   // RelationCache
                {
                    // CACHE_RELATIONSHIP begins at +8:
                    //   Level(1) Assoc(1) LineSize(2) CacheSize(4) Type(4)
                    //   Reserved[18], then 8-byte-aligned GROUP_AFFINITY
                    byte level     = Marshal.ReadByte(p, 8);
                    uint cacheSize = (uint)Marshal.ReadInt32(p, 12);
                    ulong mask     = (ulong)Marshal.ReadInt64(p, 40);
                    ushort group   = (ushort)Marshal.ReadInt16(p, 48);
                    if (level == 3 && mask != 0)
                    {
                        pools.Add(new ulong[] { mask, (ulong)group, (ulong)cacheSize });
                    }
                }
                off += size;
            }
            return pools;
        }
        catch { return null; }
        finally { Marshal.FreeHGlobal(buf); }
    }
}
'@
    try { Add-Type -TypeDefinition $code -ErrorAction Stop; return $true }
    catch { return $false }
}

function Get-X3DCacheTopology {
    <#
        Returns @{ Ok=$true; Pools=@(@{ Cpus=@(0..7); SizeMB=96; HasVCache=$true }) }
        or @{ Ok=$false; Reason='...' } if anything looks off. Callers must
        treat Ok=$false as "unknown" and fall back, never as an error.
    #>
    $fail = { param($why) return @{ Ok = $false; Reason = $why; Pools = @() } }

    if (-not (Initialize-X3DCacheProbe)) { return (& $fail 'probe unavailable') }

    $raw = $null
    try { $raw = [X3DCacheProbe]::GetL3Pools() } catch { return (& $fail 'probe threw') }
    if (-not $raw -or $raw.Count -lt 1) { return (& $fail 'no L3 caches reported') }

    $pools = @()
    foreach ($r in $raw) {
        # Only processor group 0 - X3D tops out at 32 threads, so anything
        # in another group means we do not understand this machine.
        if ([uint64]$r[1] -ne [uint64]0) { return (& $fail 'multiple processor groups') }
        $mask = [uint64]$r[0]
        $cpus = @()
        for ($b = 0; $b -lt 64; $b++) {
            if (((($mask -shr $b) -band [uint64]1)) -eq 1) { $cpus += $b }
        }
        if ($cpus.Count -lt 1) { continue }
        $mb = [int]([uint64]$r[2] / 1MB)
        $pools += @{ Cpus = $cpus; SizeMB = $mb; HasVCache = ($mb -ge 64) }
    }

    if ($pools.Count -lt 1) { return (& $fail 'no usable L3 pools') }

    # Sanity: pools must not overlap, must be equal-sized, and must cover
    # exactly the CPUs Windows reports.
    $seen = @{}
    foreach ($p in $pools) {
        foreach ($c in $p.Cpus) {
            if ($seen.ContainsKey($c)) { return (& $fail 'overlapping L3 pools') }
            $seen[$c] = $true
        }
    }
    $counts = @($pools | ForEach-Object { $_.Cpus.Count } | Sort-Object -Unique)
    if ($counts.Count -ne 1) { return (& $fail 'asymmetric CCDs') }

    $actual = Get-X3DLogicalCount
    if ($seen.Keys.Count -ne $actual) { return (& $fail "L3 pools cover $($seen.Keys.Count) of $actual CPUs") }

    # Order pools by their lowest CPU index so Pools[0] is always CCD0.
    $pools = @($pools | Sort-Object { ($_.Cpus | Measure-Object -Minimum).Minimum })
    return @{ Ok = $true; Reason = ''; Pools = $pools }
}

# ================================================================
#  Basic hardware facts
# ================================================================
function Get-X3DLogicalCount {
    # Win32_Processor is preferred: [Environment]::ProcessorCount can be
    # skewed by the current process's affinity mask.
    $n = 0
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        foreach ($c in $cpus) { if ($c.NumberOfLogicalProcessors) { $n += [int]$c.NumberOfLogicalProcessors } }
    } catch { }
    if ($n -lt 1) { $n = [int][Environment]::ProcessorCount }
    if ($n -lt 1) { $n = 1 }
    return $n
}

function Get-X3DPhysicalCount {
    $n = 0
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        foreach ($c in $cpus) { if ($c.NumberOfCores) { $n += [int]$c.NumberOfCores } }
    } catch { }
    return $n
}

# ================================================================
#  MAIN ENTRY POINT
# ================================================================
function Get-X3DProfile {
    [CmdletBinding()]
    param(
        [switch]$NoCache,
        # A catalog-shaped hashtable from the manual chip picker. Unlike
        # X3D_FORCE_PROFILE this is NOT a simulation - it describes the real
        # machine, so writes stay enabled.
        [hashtable]$Assume
    )

    # ---- honour a saved config unless it is stale -----------------
    if (-not $NoCache -and -not $Assume) {
        $saved = Import-X3DConfig
        if ($saved) { return $saved }
    }

    $warnings = @()

    # ---- raw hardware --------------------------------------------
    $cpuName = '(CPU not detected)'
    $l3TotalMB = 0
    try {
        $c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($c) {
            if ($c.Name) { $cpuName = ([string]$c.Name).Trim() }
            if ($c.L3CacheSize) { $l3TotalMB = [int]([int]$c.L3CacheSize / 1024) }
        }
    } catch { }

    $gpuName = '(GPU not detected)'
    try {
        $g = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if (-not $g) { $g = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($g -and $g.Name) { $gpuName = [string]$g.Name }
    } catch { }

    $actualLogical  = Get-X3DLogicalCount
    $actualPhysical = Get-X3DPhysicalCount

    # ---- TEST OVERRIDE -------------------------------------------
    $simulated = $false
    $entry = $null
    if ($env:X3D_FORCE_PROFILE) {
        $want = ([string]$env:X3D_FORCE_PROFILE).Trim()
        foreach ($e in $script:X3DCatalog) {
            if ($want -match $e.Match) { $entry = $e; break }
        }
        if ($entry) {
            $simulated = $true
            $warnings += "SIMULATED PROFILE: pretending to be a $($entry.Model). Registry writes are disabled."
        } else {
            $warnings += "X3D_FORCE_PROFILE='$want' does not match any known chip - ignoring it."
        }
    }

    # ---- manual pick from the chip menu (beats name detection) ----
    if (-not $entry -and $Assume) {
        $entry = $Assume
        $warnings += "Using the chip class you selected rather than auto-detection."
    }

    # ---- layer 1: catalog by name --------------------------------
    if (-not $entry) {
        foreach ($e in $script:X3DCatalog) {
            if ($cpuName -match $e.Match) { $entry = $e; break }
        }
    }

    $physical = $actualPhysical
    $logical  = $actualLogical
    if ($simulated) {
        # Model the chip's real thread count so downstream maths is exercised
        # properly, but remember what the machine actually has.
        $physical = $entry.Cores
        $logical  = $entry.Cores * 2
    }
    if ($physical -lt 1) { $physical = [int][Math]::Max(1, $logical / 2) }

    $smt = 1
    if ($physical -gt 0 -and $logical -ge ($physical * 2)) { $smt = 2 }

    # ---- layer 2: real cache topology (skipped when simulating) ---
    $cache = $null
    if (-not $simulated) { $cache = Get-X3DCacheTopology }

    $ccdCount     = 0
    $ccd0Logical  = 0
    $vcacheScope  = 'unknown'
    $source       = ''

    if ($entry) {
        $ccdCount    = $entry.CCDs
        $ccd0Logical = $entry.Ccd0Cores * $smt
        $vcacheScope = $entry.VCache
        $source      = 'catalog'
        # Cross-check the catalog against the live cache probe. A mismatch
        # normally means cores were disabled in BIOS or msconfig.
        if ($cache -and $cache.Ok) {
            if ($cache.Pools.Count -ne $ccdCount -or $cache.Pools[0].Cpus.Count -ne $ccd0Logical) {
                $warnings += "This chip is a $($entry.Model) but Windows reports $($cache.Pools.Count) CCD(s) of $($cache.Pools[0].Cpus.Count) CPUs. Cores may be disabled in BIOS or msconfig; using what Windows reports."
                $ccdCount    = $cache.Pools.Count
                $ccd0Logical = $cache.Pools[0].Cpus.Count
                $source      = 'cache-probe (catalog mismatch)'
            }
        }
    }
    elseif ($cache -and $cache.Ok) {
        # Unknown chip, but the cache probe understood it - use that.
        $ccdCount    = $cache.Pools.Count
        $ccd0Logical = $cache.Pools[0].Cpus.Count
        $cached      = @($cache.Pools | Where-Object { $_.HasVCache })
        if     ($cached.Count -eq 0)                { $vcacheScope = 'none' }
        elseif ($cached.Count -eq $cache.Pools.Count) { $vcacheScope = if ($ccdCount -eq 1) { 'all' } else { 'both' } }
        else                                        { $vcacheScope = 'ccd0' }
        $source = 'cache-probe'
    }
    else {
        # ---- layers 3 + 4: WMI L3 size, then core count -----------
        $source = 'heuristic'
        if ($physical -ge 12 -and ($physical % 2) -eq 0) {
            $ccdCount = 2; $ccd0Logical = [int]($logical / 2)
        } else {
            $ccdCount = 1; $ccd0Logical = $logical
        }
        if ($l3TotalMB -ge 64) { $vcacheScope = if ($ccdCount -eq 1) { 'all' } else { 'ccd0' } }
        else                   { $vcacheScope = 'none' }
        $warnings += "Could not identify this CPU precisely. Falling back to a core-count estimate - topology-specific fixes are disabled."
    }

    $isX3D    = ($vcacheScope -in @('all','ccd0','both'))
    $topology = if ($ccdCount -ge 2) { 'dual' } else { 'single' }

    # ---- target core for interrupts / background ------------------
    if ($topology -eq 'dual') {
        $freqFirst = $ccd0Logical           # first CPU of the second CCD
    } else {
        $freqFirst = [int]($logical / 2)    # a core well away from CPU 0
    }

    # ---- HARD VALIDATION -----------------------------------------
    # Nothing downstream may ever target a CPU that does not exist.
    $limit = if ($simulated) { $logical } else { $actualLogical }
    $topologyKnown = ($source -ne 'heuristic')

    if ($freqFirst -lt 1 -or $freqFirst -ge $limit) {
        $fallback = [int]($limit / 2)
        if ($fallback -lt 1) { $fallback = 0 }
        $warnings += "Computed target CPU $freqFirst is not valid on a machine with $limit logical processors - using CPU $fallback instead."
        $freqFirst = $fallback
        $topologyKnown = $false
    }
    if ($limit -lt 2) {
        $warnings += "Only $limit logical processor visible - interrupt steering is not possible."
        $topologyKnown = $false
    }
    if ($smt -eq 1 -and $isX3D) {
        $warnings += "SMT looks disabled ($logical logical / $physical physical). That is a valid setup, but core numbers here are physical cores, not threads."
    }

    # ---- ranges + IRQ target list ---------------------------------
    $vcacheRange = if ($topology -eq 'single') { "0-$($logical - 1)" } else { "0-$($freqFirst - 1)" }
    $bgRange     = if ($freqFirst -lt ($limit - 1)) { "$freqFirst-$($limit - 1)" } else { "$freqFirst" }

    $irqTargets = @()
    if ($topologyKnown) {
        for ($i = $freqFirst + 1; $i -lt $limit -and $irqTargets.Count -lt 3; $i++) { $irqTargets += $i }
        if ($irqTargets.Count -lt 1) { $irqTargets = @($freqFirst) }
    }

    # ---- labels ---------------------------------------------------
    $model = if ($entry) { $entry.Model } else { $cpuName }
    if ($vcacheScope -eq 'both') {
        $profLabel = "$physical-core dual-CCD, V-Cache on BOTH CCDs"
    } elseif ($topology -eq 'dual') {
        $profLabel = "$physical-core dual-CCD"
    } elseif ($isX3D) {
        $profLabel = "$physical-core single-CCD"
    } else {
        $profLabel = "$physical-core ($logical threads)"
    }

    if ($entry -and $entry.Form -eq 'mobile') {
        $warnings += "Laptop chip detected. Interrupt steering and power-plan changes can be overridden by your OEM's power management, and the vendor control app may revert them. Every fix here has an Undo if behaviour gets worse."
    }
    if (-not $isX3D) {
        $warnings += "This is not an X3D processor. The general fixes (Defender, timer, Game Bar, pre-race quieting, tracing) all still apply; core pinning and interrupt steering are disabled."
    }

    # Hoisted out of the hashtable literal below - an 'if' as a hashtable
    # value parses fine, but plain variables are unambiguous on 5.1.
    $entryForm = 'unknown'; $entryArch = ''; $entryPlatform = ''
    if ($entry) {
        if ($entry.Form)     { $entryForm     = $entry.Form }
        if ($entry.Arch)     { $entryArch     = $entry.Arch }
        if ($entry.Platform) { $entryPlatform = $entry.Platform }
    }

    $obj = [pscustomobject]@{
        SchemaVersion  = $script:X3DSchemaVersion
        DetectedOn     = (Get-Date).ToString('s')

        CpuName        = $cpuName
        GpuName        = $gpuName
        Model          = $model
        Known          = [bool]$entry
        IsX3D          = $isX3D
        Form           = $entryForm
        Arch           = $entryArch
        Platform       = $entryPlatform

        Cores          = $physical
        LogicalCores   = $logical
        ActualLogical  = $actualLogical
        SmtFactor      = $smt
        CcdCount       = $ccdCount
        Ccd0Logical    = $ccd0Logical
        VCacheScope    = $vcacheScope

        Topology       = $topology
        TopologyKnown  = $topologyKnown
        DetectSource   = $source
        Simulated      = $simulated

        FreqFirst      = $freqFirst
        VCache         = $vcacheRange
        VCacheRange    = $vcacheRange
        BackgroundRange= $bgRange
        IrqTargets     = $irqTargets

        Profile        = $profLabel
        Warnings       = $warnings
        Launched       = @()
    }

    if (-not $simulated) { Export-X3DConfig $obj }
    return $obj
}

# ================================================================
#  Guidance text - one place, so the GUI and console agree
# ================================================================
function Get-X3DPinningAdvice {
    param([Parameter(Mandatory)]$Profile)

    if (-not $Profile.IsX3D) {
        return "No X3D V-Cache detected, so there is no cache-preferred CCD to pin to. Skip the Process Lasso CPU-Set step; the rest of the kit still applies."
    }
    if ($Profile.Topology -eq 'single') {
        return "Single-CCD chip: every core shares the V-Cache, so there is nothing to pin. Just set the power plan in Process Lasso (Main menu -> Power -> Bitsum Highest Performance)."
    }
    if ($Profile.VCacheScope -eq 'both') {
        return @"
Both CCDs have V-Cache on this chip, so there is no "good" and "bad" CCD - the cores are equivalent. Pinning still helps, but for a different reason: keeping the sim on ONE CCD avoids the latency cost of reaching across to the other die's cache.

1) Process Lasso -> Main menu -> Power -> Bitsum Highest Performance.
2) Right-click iRacingSim64DX11.exe -> CPU Sets -> cores $($Profile.VCacheRange).
3) Right-click it -> ProBalance -> exclude it.
"@
    }
    return @"
1) Process Lasso -> Main menu -> Power -> Bitsum Highest Performance (all cores unparked).
2) Right-click iRacingSim64DX11.exe -> CPU Sets -> cores $($Profile.VCacheRange) (the V-Cache CCD).
3) Right-click it -> ProBalance -> exclude it.
"@
}

function Get-X3DTopologySummary {
    param([Parameter(Mandatory)]$Profile)

    if (-not $Profile.IsX3D) {
        return "$($Profile.LogicalCores) logical processors, no 3D V-Cache detected - general fixes only."
    }
    if ($Profile.Topology -eq 'single') {
        return "Single-CCD: all $($Profile.LogicalCores) CPUs share the V-Cache - no core pinning needed. Interrupts -> CPU $($Profile.FreqFirst)."
    }
    if ($Profile.VCacheScope -eq 'both') {
        return "Dual-CCD, V-Cache on both: sim -> CPU $($Profile.VCacheRange) (one die, avoids cross-CCD latency)  |  background -> CPU $($Profile.BackgroundRange)"
    }
    return "Sim -> V-Cache CPUs $($Profile.VCacheRange)   |   Background -> CPUs $($Profile.BackgroundRange)"
}

function Write-X3DWarnings {
    param($Profile, [string]$Indent = '  ')
    if (-not $Profile -or -not $Profile.Warnings) { return }
    foreach ($w in $Profile.Warnings) {
        Write-Host ("{0}! {1}" -f $Indent, $w) -ForegroundColor Yellow
    }
}

# ================================================================
#  Config persistence
# ================================================================
function Import-X3DConfig {
    if (-not (Test-Path $script:X3DConfigFile)) { return $null }
    try {
        $c = Get-Content $script:X3DConfigFile -Raw | ConvertFrom-Json
        if (-not $c.SchemaVersion -or [int]$c.SchemaVersion -lt $script:X3DSchemaVersion) { return $null }
        if (-not $c.PSObject.Properties['FreqFirst']) { return $null }
        # Re-validate against the machine we are on right now - a saved
        # config from a previous CPU must not survive a hardware swap.
        $live = Get-X3DLogicalCount
        if ([int]$c.ActualLogical -ne $live) { return $null }
        if ([int]$c.FreqFirst -lt 0 -or [int]$c.FreqFirst -ge $live) { return $null }
        return $c
    } catch { return $null }
}

function Export-X3DConfig {
    param($Profile)
    try {
        if (-not (Test-Path $script:X3DConfigDir)) {
            New-Item -ItemType Directory -Path $script:X3DConfigDir -Force | Out-Null
        }
        $Profile | ConvertTo-Json -Depth 4 | Out-File -FilePath $script:X3DConfigFile -Encoding utf8
    } catch { }
}

function Clear-X3DConfig {
    try { if (Test-Path $script:X3DConfigFile) { Remove-Item $script:X3DConfigFile -Force } } catch { }
}

function Get-X3DConfigPath { return $script:X3DConfigFile }

# ================================================================
#  Consumer helper: resolve a target core in standalone scripts
# ================================================================
function Resolve-X3DTarget {
    <#
        Used by the individual fix scripts. Honours X3D_FREQ_FIRST_CORE
        (set by the menu / baseline runner) first so a launcher can pin
        the whole run to one profile, then falls back to full detection.
        The returned value is always a real, usable CPU index.
    #>
    param([switch]$Quiet)

    $limit = Get-X3DLogicalCount

    if ($env:X3D_FREQ_FIRST_CORE) {
        $v = 0
        try { $v = [int]$env:X3D_FREQ_FIRST_CORE } catch { $v = -1 }
        if ($v -ge 0 -and $v -lt $limit) {
            return [pscustomobject]@{
                FreqFirst = $v
                Limit     = $limit
                Profile   = $null
                Simulated = ($env:X3D_SIMULATED -eq '1')
                Valid     = $true
            }
        }
        if (-not $Quiet) {
            Write-Host "  ! X3D_FREQ_FIRST_CORE=$env:X3D_FREQ_FIRST_CORE is not a valid CPU on this machine ($limit logical). Re-detecting." -ForegroundColor Yellow
        }
    }

    $p = Get-X3DProfile
    if (-not $Quiet) { Write-X3DWarnings $p }
    $effLimit = $p.ActualLogical
    if ($p.Simulated) { $effLimit = $p.LogicalCores }
    return [pscustomobject]@{
        FreqFirst = $p.FreqFirst
        Limit     = $effLimit
        Profile   = $p
        Simulated = $p.Simulated
        Valid     = $p.TopologyKnown
    }
}
