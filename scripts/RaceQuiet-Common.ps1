<#
    RaceQuiet-Common.ps1  -  shared elevate / privilege / logging helpers
    ================================================================
    Used by Pre-Race-Quiet and Post-Race-Restore so the elevation hop,
    the RaceQuiet.log writer, the RQPriv privilege helper and the
    SYSTEM schtasks hop are not copy-pasted between them.

        . (Join-Path $PSScriptRoot 'RaceQuiet-Common.ps1')

    Provides:
      Write-RaceQuietLog / Write-Log
      Initialize-Privileges / Enable-RaceQuietPrivileges
      Assert-AdminOrRelaunch
      Assert-Admin
      Invoke-SystemTaskHop
#>

function Write-RaceQuietLog {
    param(
        [string]$Msg,
        [string]$Color = 'Gray',
        [switch]$NoHost,
        [string]$StateDir = $script:StateDir,
        [string]$LogFile  = $script:LogFile
    )
    $line = ("{0}  {1}" -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)), $Msg)
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
    if (-not $NoHost) { Write-Host ("  " + $Msg) -ForegroundColor $Color }
}

# Drop-in name used throughout quiet/restore.
function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray', [switch]$NoHost)
    Write-RaceQuietLog -Msg $Msg -Color $Color -NoHost:$NoHost
}

function Initialize-Privileges {
    # Taking ownership needs SeTakeOwnershipPrivilege, and handing it back to
    # TrustedInstaller needs SeRestorePrivilege. Admins hold both, but they
    # are disabled in the token until explicitly enabled.
    if ('RQPriv' -as [type]) { return $true }
    $code = @'
using System;
using System.Runtime.InteropServices;
public class RQPriv {
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool disall, ref TOKPRIV1LUID newst, int len, IntPtr prev, IntPtr rel);
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    public struct TOKPRIV1LUID { public int Count; public long Luid; public int Attr; }
    public static bool Enable(string priv) {
        IntPtr tok = IntPtr.Zero;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
        TOKPRIV1LUID tp;
        tp.Count = 1;
        tp.Luid  = 0;
        tp.Attr  = 2;   // SE_PRIVILEGE_ENABLED
        if (!LookupPrivilegeValue(null, priv, out tp.Luid)) return false;
        return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
    try { Add-Type -TypeDefinition $code -ErrorAction Stop } catch { return $false }
    return $true
}

function Enable-RaceQuietPrivileges {
    if (-not (Initialize-Privileges)) { return $false }
    [void][RQPriv]::Enable('SeTakeOwnershipPrivilege')
    [void][RQPriv]::Enable('SeRestorePrivilege')
    [void][RQPriv]::Enable('SeBackupPrivilege')
    return $true
}

function Assert-Admin {
    param([string]$Message = 'Run this from an elevated PowerShell (right-click > Run as administrator).')
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { return $true }
    Write-Host $Message -ForegroundColor Yellow
    return $false
}

function Assert-AdminOrRelaunch {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [hashtable]$BoundParameters,
        [string]$CancelMessage = 'Elevation cancelled.'
    )
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { return $true }

    Write-Host "Elevating..." -ForegroundColor Cyan
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $ScriptPath))
    if ($BoundParameters) {
        foreach ($key in $BoundParameters.Keys) {
            $val = $BoundParameters[$key]
            if ($val -is [System.Management.Automation.SwitchParameter]) {
                if ($val.IsPresent) { $argList += ('-{0}' -f $key) }
            } elseif ($val -is [bool]) {
                if ($val) { $argList += ('-{0}' -f $key) }
            } elseif ($null -ne $val) {
                $argList += @(('-{0}' -f $key), [string]$val)
            }
        }
    }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host $CancelMessage -ForegroundColor Yellow }
    return $false
}

function Invoke-SystemTaskHop {
    param(
        [Parameter(Mandatory=$true)][object[]]$Tasks,
        [Parameter(Mandatory=$true)][ValidateSet('Disable','Enable')][string]$Action,
        [Parameter(Mandatory=$true)][string]$StateDir,
        [string]$SchTaskName = 'RaceQuiet-SystemHop',
        [string]$HelperLeaf  = 'system-hop.ps1',
        [string]$MarkerLeaf  = 'system-hop.done',
        [int]$TimeoutSec = 30,
        [switch]$FinePoll,
        [string]$ProgressActivity,
        [string]$TimeoutMessage
    )

    if (-not $Tasks -or $Tasks.Count -eq 0) { return }

    Write-Host ""
    Write-Host ("  {0} task(s) refused - retrying as SYSTEM" -f $Tasks.Count) -ForegroundColor Yellow
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

    $helper = Join-Path $StateDir $HelperLeaf
    $marker = Join-Path $StateDir $MarkerLeaf
    if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

    $cmdlet = if ($Action -eq 'Disable') { 'Disable-ScheduledTask' } else { 'Enable-ScheduledTask' }
    $lines = @('$done = @()')
    foreach ($f in $Tasks) {
        $pp = $f.Path -replace "'","''"
        $nn = $f.Name -replace "'","''"
        # NB: built by concatenation, not -f. The format operator treats the
        # literal braces in try{}/catch{} as malformed placeholders and throws.
        $lines += "try { $cmdlet -TaskPath '$pp' -TaskName '$nn' -ErrorAction Stop | Out-Null; `$done += 'OK   $pp$nn' } catch { `$done += 'FAIL $pp$nn' }"
    }
    $lines += ("`$done | Out-File -FilePath '{0}' -Encoding utf8" -f ($marker -replace "'","''"))
    Set-Content -Path $helper -Value $lines -Encoding utf8

    $cmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $helper)
    & schtasks.exe /Create /TN $SchTaskName /TR $cmd /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
    & schtasks.exe /Run /TN $SchTaskName 2>&1 | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $marker) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($FinePoll) {
            if ($ProgressActivity) {
                Write-Progress -Activity $ProgressActivity `
                               -Status ("Retrying {0} protected task(s) as SYSTEM" -f $Tasks.Count) `
                               -CurrentOperation ("waited {0:N1}s of {1}" -f $sw.Elapsed.TotalSeconds, $TimeoutSec) `
                               -PercentComplete 55
            }
            Start-Sleep -Milliseconds 100
        } else {
            Start-Sleep -Seconds 1
        }
    }
    $sw.Stop()
    if ($FinePoll -and $ProgressActivity) { Write-Progress -Activity $ProgressActivity -Completed }
    & schtasks.exe /Delete /TN $SchTaskName /F 2>&1 | Out-Null

    if (Test-Path $marker) {
        foreach ($l in (Get-Content $marker)) {
            if ($l -like 'OK*') { Write-Log ("SYSTEM " + $l) 'Green' }
            else                { Write-Log ("SYSTEM " + $l) 'Yellow' }
        }
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
    } else {
        if (-not $TimeoutMessage) {
            $TimeoutMessage = 'SYSTEM helper did not report back - re-run this script from an elevated prompt'
        }
        Write-Log $TimeoutMessage 'Yellow'
    }
    Remove-Item $helper -Force -ErrorAction SilentlyContinue
}
