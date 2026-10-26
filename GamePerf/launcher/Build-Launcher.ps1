<#
    Build-Launcher.ps1  -  build GamePerf.exe from GamePerfLauncher.cs
    ================================================================
    You do not need this to use GamePerf: GamePerf.exe ships ready-built.
    Run it to rebuild after editing the launcher, or to build your own copy
    on your own PC (a locally built exe is never "downloaded from the
    internet", so SmartScreen has nothing to say about it):

        powershell -ExecutionPolicy Bypass -File GamePerf\launcher\Build-Launcher.ps1

    Windows: uses the C# compiler that ships with the .NET Framework in
    every Windows 10/11 - no SDK or Visual Studio needed.
    Linux (maintainers / CI): mono's mcs plus mingw's windres.

    The source hash is stamped into the exe's product version, and
    tests\test-gameperf.ps1 fails if the committed exe does not match the
    committed source.
#>
[CmdletBinding()]
param([string]$OutFile)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$App = Split-Path -Parent $Here
. (Join-Path (Join-Path $App 'lib') 'GamePerf-Common.ps1')
if (-not $OutFile) { $OutFile = Join-Path $App 'GamePerf.exe' }

$src = Join-Path $Here 'GamePerfLauncher.cs'
$ico = Join-Path $Here 'GamePerf.ico'
$man = Join-Path $Here 'GamePerf.exe.manifest'
$code = [IO.File]::ReadAllText($src)
$info = Get-GpLauncherInformationalVersion $code
$fileVer = "$GamePerfVersion.0"
if ($code -notmatch [regex]::Escape("AssemblyFileVersion(`"$fileVer`")")) { throw "GamePerfLauncher.cs AssemblyFileVersion must be $fileVer (GamePerf-Common.ps1 says $GamePerfVersion)." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('gameperf-launcher-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $cs = Join-Path $tmp 'GamePerfLauncher.cs'
    [IO.File]::WriteAllText($cs, ($code -replace 'AssemblyInformationalVersion\("[^"]*"\)', "AssemblyInformationalVersion(`"$info`")"))

    $csc = $null
    $win = [Environment]::GetFolderPath('Windows')
    if ($win) {
        foreach ($fw in 'Framework64', 'Framework') {
            $c = Join-Path $win "Microsoft.NET\$fw\v4.0.30319\csc.exe"
            if (Test-Path -LiteralPath $c) { $csc = $c; break }
        }
    }
    if ($csc) {
        & $csc /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$ico" "/win32manifest:$man" "/out:$OutFile" $cs
        if ($LASTEXITCODE) { throw "csc failed ($LASTEXITCODE)" }
    } else {
        $mcs = Get-Command mcs -ErrorAction SilentlyContinue
        $windres = Get-Command x86_64-w64-mingw32-windres, windres -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $mcs -or -not $windres) { throw 'No compiler: on Windows the .NET Framework csc.exe is used; elsewhere install mono-mcs and binutils-mingw-w64.' }
        # mcs cannot take a manifest, so icon + manifest + version info go in one .res.
        $v4 = $fileVer.Replace('.', ',')
        $rc = @"
1 ICON "$($ico -replace '\\', '/')"
1 24 "$($man -replace '\\', '/')"
1 VERSIONINFO
FILEVERSION $v4
PRODUCTVERSION $v4
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "000004b0"
    BEGIN
      VALUE "CompanyName", "iRacing X3D Tuning kit"
      VALUE "FileDescription", "GamePerf"
      VALUE "FileVersion", "$fileVer"
      VALUE "InternalName", "GamePerf.exe"
      VALUE "LegalCopyright", "MIT licence"
      VALUE "OriginalFilename", "GamePerf.exe"
      VALUE "ProductName", "GamePerf"
      VALUE "ProductVersion", "$info"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0, 1200
  END
END
"@
        $rcPath = Join-Path $tmp 'GamePerf.rc'
        $resPath = Join-Path $tmp 'GamePerf.res'
        [IO.File]::WriteAllText($rcPath, $rc)
        & $windres.Source -O res -i $rcPath -o $resPath
        if ($LASTEXITCODE) { throw "windres failed ($LASTEXITCODE)" }
        & $mcs.Source -target:winexe -platform:anycpu -optimize+ "-win32res:$resPath" "-out:$OutFile" -r:System.dll $cs
        if ($LASTEXITCODE) { throw "mcs failed ($LASTEXITCODE)" }
    }
    Write-Host "Built $OutFile ($info)" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
