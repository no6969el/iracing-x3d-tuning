<#
.SYNOPSIS
Validates this repo's local documentation and script references.

.DESCRIPTION
Checks that every local file referenced in docs exists, that shared script dependencies
are present, and that the optional medic-unlock package contents match the docs.
#>

[CmdletBinding()]
param()

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Resolve-RepoPath {
    param(
        [string]$ref,
        [string]$baseDir
    )

    $ref = $ref -replace '^\./', ''
    $ref = $ref -replace '/', '\\'
    return Join-Path $baseDir $ref
}

function Test-ExternalReference {
    param([string]$ref)
    return $ref -match '^(?:https?:|mailto:|file:|//)'
}

function Test-PlaceholderReference {
    param([string]$ref)
    $lower = $ref.ToLowerInvariant()
    return $lower -in @(
        'path\\to\\script.ps1',
        'path/to/script.ps1',
        'gp.html'
    ) -or
           $lower -like 'example*' -or
           $lower -like 'sample*' -or
           $lower -like 'placeholder*'
}

function Find-BasenameInRepo {
    param([string]$basename)
    return Get-ChildItem -Path $repoRoot -Recurse -File -Filter $basename -ErrorAction SilentlyContinue
}

function Test-DocRefs {
    $docFiles = Get-ChildItem -Path $repoRoot -Recurse -Include *.md,*.html,*.txt -File
    $pattern = '([A-Za-z0-9_\\/\.-]+\.(?:md|html|txt|bat|ps1))'

    foreach ($file in $docFiles) {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        foreach ($match in [regex]::Matches($content, $pattern)) {
            $ref = $match.Groups[1].Value
            if (Test-ExternalReference $ref -or Test-PlaceholderReference $ref) {
                continue
            }

            if ($file.Name -ieq 'index.html' -and ($ref -eq 'gp.html' -or $ref -like '*path*to*script.ps1*')) {
                continue
            }

            if ($ref -match '^(?:scripts[\\/]|\.\\|\.\.|[\\/])') {
                $target = Resolve-RepoPath $ref $file.DirectoryName
                $targetRoot = Resolve-RepoPath $ref $repoRoot
                if (-not ((Test-Path -Path $target -PathType Any) -or (Test-Path -Path $targetRoot -PathType Any))) {
                    Add-Failure "Missing referenced path '$ref' in '$($file.FullName)'."
                }
            }
            elseif ($ref -match '^(?:scripts-medic-unlock[\\/])') {
                continue
            }
            else {
                $candidates = Find-BasenameInRepo $ref
                if ($candidates.Count -eq 0) {
                    Add-Failure "Missing referenced file '$ref' in '$($file.FullName)'."
                }
            }
        }
    }
}

function Test-ScriptDependencies {
    $shared = Join-Path $repoRoot 'scripts\X3D-Profiles.ps1'
    if (-not (Test-Path -Path $shared -PathType Leaf)) {
        Add-Failure "Shared dependency 'scripts/X3D-Profiles.ps1' is missing."
    }

    $scripts = Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter *.ps1 -File
    foreach ($script in $scripts) {
        if ($script.Name -ieq 'X3D-Profiles.ps1') { continue }
        $content = Get-Content -Path $script.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'X3D-Profiles\.ps1') {
            if (-not (Test-Path -Path $shared -PathType Leaf)) {
                Add-Failure "Script '$($script.Name)' references X3D-Profiles.ps1, but the shared file is missing."
            }
        }
    }
}

function Test-MedicUnlockPackage {
    $zipPath = Join-Path $repoRoot 'scripts-medic-unlock.zip'
    if (-not (Test-Path -Path $zipPath -PathType Leaf)) {
        Add-Failure "Optional file 'scripts-medic-unlock.zip' is missing."
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entries = $zip.Entries | ForEach-Object { $_.FullName }
        $zip.Dispose()
    } catch {
        Add-Failure "Unable to read ZIP archive '$zipPath': $($_.Exception.Message)"
        return
    }

    $required = @(
        'scripts-medic-unlock/README.txt',
        'scripts-medic-unlock/Pre-Race-Quiet.ps1',
        'scripts-medic-unlock/Post-Race-Restore.ps1'
    )

    foreach ($entry in $required) {
        if (-not ($entries -contains $entry)) {
            Add-Failure "Missing archive entry '$entry' inside scripts-medic-unlock.zip."
        }
    }
}

Write-Host "Validating repo references in: $repoRoot" -ForegroundColor Cyan
Test-DocRefs
Test-ScriptDependencies
Test-MedicUnlockPackage

if ($failures.Count -eq 0) {
    Write-Host "Validation complete: no missing references found." -ForegroundColor Green
    exit 0
}

Write-Host "Validation complete: $($failures.Count) issue(s) found." -ForegroundColor Yellow
foreach ($msg in $failures) {
    Write-Host "- $msg" -ForegroundColor Red
}
exit 1
