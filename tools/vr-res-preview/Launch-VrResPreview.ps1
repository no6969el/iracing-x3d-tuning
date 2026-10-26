# Launch the free VR resolution preview. Safe to dot-source from the dashboard.
# Captured while this file is executing so a later call still finds the exe
# next to this script, not next to whoever dot-sourced it.
$VrPreviewRoot = $PSScriptRoot
if (-not $VrPreviewRoot) { $VrPreviewRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Start-VrResPreview {
    $here = $VrPreviewRoot

    $candidates = @(
        (Join-Path $here 'dist\vr-res-preview.exe'),
        (Join-Path $here 'vr-res-preview.exe'),
        (Join-Path $here 'build\bin\Release\vr-res-preview.exe')
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        $nested = Get-ChildItem -Path (Join-Path $here 'dist') -Filter vr-res-preview.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($nested) { $exe = $nested.FullName }
    }

    if (-not $exe) {
        $msg = @"
The VR resolution preview build is not in this folder yet.

Download the Windows x64 artifact named vr-res-preview-win64 from the GitHub Actions workflow, unzip it, and put vr-res-preview.exe in:

tools\vr-res-preview\dist\

Start SteamVR first, with SteamVR as the active OpenXR runtime. Leave SteamVR's per-application resolution for vr-res-preview.exe at 100%. This test has its own scale control and does not change any PC setting.

Open the Actions page now?
"@
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        $answer = [System.Windows.MessageBox]::Show($msg, 'VR Resolution Preview', 'YesNo', 'Information')
        if ($answer -eq 'Yes') {
            Start-Process 'https://github.com/no6969el/iracing-x3d-tuning/actions/workflows/vr-res-preview.yml'
        }
        return
    }

    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-VrResPreview
}
