<#
    Synthetic GamePerf sessions for the tests. Dot-source it.

    New-GpFixtureSession writes a session folder shaped exactly like the
    logger's: session.json, system.csv, events.csv, frames-1.csv and a
    configs\ snapshot - with known problems planted at known times, so a
    test can check the analyzer finds each one:

        t = 30 s   GPU spike         (30 ms frame, GPU busy 28 ms)
        t = 45 s   game-thread spike (35 ms frame, CPU busy 33 ms)
        t = 60.3 s stall             (45 ms frame, CPU and GPU idle) with a
                                     disk-read and hard-fault burst at 60 s
        t = 60.8 s marker key pressed
        t = 80-100 s GPU-heavy stretch: every frame 14.5 ms, GPU busy 14 ms
#>

function New-GpFixtureSession {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Name = '20261026-200000-test',
        [ValidateSet('v2', 'v1')][string]$Format = 'v2',
        [string]$ShadowValue = '2',
        [string]$Culture = ''
    )
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'configs') | Out-Null
    $qf = 10000000.0; $q0 = 1000000000.0

    $meta = [ordered]@{
        version = 'test'; started = '2026-10-26T20:00:00.0000000+00:00'; label = "shadows $ShadowValue"; mode = 'VR'
        target_fps = 90; budget_ms = 1000.0 / 90; game_request = 'auto'; qpc_start = $q0; qpc_freq = $qf; marker_key = 'ScrollLock'
        machine = [ordered]@{ cpu = 'AMD Ryzen 7 9800X3D 8-Core Processor'; cpu_cores = 8; cpu_logical = 16; topology = 'single'; is_x3d = $true
                              vcache_scope = 'single'; split_core = 8; ram_gb = 63.6; display_refresh_hz = 144; display_resolution = '2560x1440'
                              power_plan = 'Balanced'; hags = 'on'; game_mode = 'on'; game_dvr = 'off'; vbs = 'off'; hvci = 'off'; timer_res_ms = 0.5
                              nvidia = [ordered]@{ name = 'NVIDIA GeForce RTX 5090'; driver = '581.57'; vram_mb = '32607'; pcie_gen_now = '5'; pcie_width_now = '16'; pcie_gen_max = '5'; pcie_width_max = '16'; power_limit_w = '575' } }
        vr = [ordered]@{ runtimes_running = @('pi_server'); openxr = [ordered]@{ ActiveRuntime = 'C:\Program Files\Pimax\Runtime\PiOpenXR_64.json'
                         Layers = @([ordered]@{ Manifest = 'C:\Program Files\OpenXR-Quad-Views-Foveated\openxr-api-layer.json'; Enabled = $true; Scope = 'HKLM' }) } }
        game_exe = 'iRacingSim64DX11.exe'; game_name = 'iRacing'; game_path = 'C:\Program Files (x86)\iRacing\iRacingSim64DX11.exe'
        ended = '2026-10-26T20:02:00.0000000+00:00'; duration_s = 120; stop_reason = 'test'; frame_files = @('frames-1.csv'); markers = 1
        background_top = @([ordered]@{ name = 'Discord'; cpu_s = 40; avg_pct = 2.1 }, [ordered]@{ name = 'pi_server'; cpu_s = 90; avg_pct = 4.7 })
        logger_cpu_pct = 0.31; logger_avg_loop_ms = 6.2; warnings = @()
    }
    ($meta | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $dir 'session.json') -Encoding UTF8

    # ---- system.csv (1 Hz) ------------------------------------------
    $cols = 'timestamp,t_s,qpc,phase,game_pid,fg_game,marker,cpu_total,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu_eff_mhz,cpu0_int,cpu0_dpc,freqcore_int,freqcore_dpc,tot_int,tot_dpc,game_cpu,game_cores,game_top_thread,game_threads,game_ws_mb,game_private_mb,game_aff,vr_cpu,free_ram_mb,commit_pct,hardfaults_s,disk_read_mb_s,disk_write_mb_s,disk_busy_pct,disk_queue,gpu_util,gpu_mem_util,vram_used_mb,vram_total_mb,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,fan_pct,pstate,gpu_throttle,gpu_volt_mv,volt_limit,power_limit,temp_limit,noload_limit,pcie_bus_pct,fb_usage_pct,mem_temp_c,fan_rpm,ab_fps,ab_frametime_ms,pm_frames,pm_fps,pm_ft_avg_ms,pm_ft_max_ms,pm_gpu_busy_ms,pm_cpu_busy_ms,pm_over_budget,timer_res_ms,power_plan,loop_ms'
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine($cols)
    for ($s = 0; $s -lt 120; $s++) {
        $game = $s -ge 5
        $hf = 10; $disk = 5; $util = 96; $thread = 72
        if ($s -eq 60) { $hf = 2400; $disk = 310 }
        if ($s -ge 80 -and $s -lt 100) { $util = 99 }
        $thr = if ($s % 2) { '0x0000000000000004' } else { '0x0000000000000000' }
        $f = @(
            ('20:{0:00}:{1:00}.000' -f [int][math]::Floor($s / 60), ($s % 60)), $s.ToString($inv), ($q0 + $s * $qf).ToString('0', $inv),
            $(if ($game) { 'game' } else { 'wait' }), $(if ($game) { '4242' } else { '' }), $(if ($game) { '1' } else { '' }), $(if ($s -eq 61) { '1' } else { '0' }),
            '31.5', '48.2', '12.4', '3', '88', '5150', '0.4', '0.9', '1.1', '0.3', '0.5', '0.8',
            $(if ($game) { '22.5' } else { '' }), $(if ($game) { '3.6' } else { '' }), $(if ($game) { "$thread" } else { '' }), $(if ($game) { '96' } else { '' }),
            $(if ($game) { '5120' } else { '' }), $(if ($game) { '4900' } else { '' }), $(if ($game) { '0xFFFF' } else { '' }), '4.7',
            '41000', '38', "$hf", "$disk", '3', '4', '0.1',
            "$util", '45', '11800', '32607', '455.5', '2805', '14001', '71', '55', 'P0', $thr,
            '1015', '0', $(if ($s % 2) { '1' } else { '0' }), '0', '0', '6', '40', '68', '1500', '90.1', '11.1',
            '', '', '', '', '', '', '', '0.5', '"Balanced, (custom)"', '6.4'
        )
        [void]$sb.AppendLine(($f -join ','))
    }
    [IO.File]::WriteAllText((Join-Path $dir 'system.csv'), $sb.ToString())

    $ev = @(
        'timestamp,t_s,qpc,event,detail'
        "20:00:05.000,5,$(($q0 + 5 * $qf).ToString('0', $inv)),game_start,""iRacingSim64DX11.exe pid 4242"""
        "20:00:05.500,5.5,$(($q0 + 5.5 * $qf).ToString('0', $inv)),presentmon_start,""frames-1.csv"""
        "20:00:59.000,59,$(($q0 + 59 * $qf).ToString('0', $inv)),background_cpu,""Discord 2.1%; chrome 1.2%"""
        "20:01:00.800,60.8,$(($q0 + 60.8 * $qf).ToString('0', $inv)),marker,""#1"""
        "20:01:40.000,100,$(($q0 + 100 * $qf).ToString('0', $inv)),focus_lost,""explorer"""
    )
    [IO.File]::WriteAllText((Join-Path $dir 'events.csv'), ($ev -join "`n") + "`n")

    # ---- frames-1.csv (PresentMon) --------------------------------------
    $fsb = New-Object Text.StringBuilder
    if ($Format -eq 'v2') {
        [void]$fsb.AppendLine('Application,ProcessID,SwapChainAddress,PresentRuntime,SyncInterval,PresentFlags,AllowsTearing,PresentMode,CPUStartQPC,MsBetweenSimulationStart,MsBetweenPresents,MsBetweenAppStart,MsCPUBusy,MsCPUWait,MsInPresentAPI,MsRenderPresentLatency,MsGPULatency,MsGPUTime,MsGPUBusy,MsGPUWait,MsUntilDisplayed,MsBetweenDisplayChange')
    } else {
        [void]$fsb.AppendLine('Application,ProcessID,SwapChainAddress,Runtime,SyncInterval,PresentFlags,Dropped,TimeInSeconds,msInPresentAPI,msBetweenPresents,AllowsTearing,PresentMode,msUntilRenderComplete,msUntilDisplayed,msBetweenDisplayChange')
    }
    $t = 5.5
    $budget = 1000.0 / 90
    $planted = @{ 30 = @(30.0, 4.0, 28.0); 45 = @(35.0, 33.0, 5.0); 60 = @(45.0, 3.0, 3.0) }
    $done = @{}
    $i = 0
    while ($t -lt 119.5) {
        $ft = $budget + (($i % 7) - 3) * 0.05
        $gpu = 8.6; $cpu = 6.1
        if ($t -lt 8.5) { $ft = 100.0; $gpu = 2.0; $cpu = 3.0 }                 # loading
        elseif ($t -ge 80 -and $t -lt 100) { $ft = 14.5; $gpu = 14.0; $cpu = 6.5 }
        foreach ($k in $planted.Keys) {
            $at = [double]$k; if ($k -eq 60) { $at = 60.3 }
            if (-not $done.ContainsKey($k) -and $t -ge $at) { $ft = $planted[$k][0]; $cpu = $planted[$k][1]; $gpu = $planted[$k][2]; $done[$k] = $true }
        }
        $qpc = ($q0 + $t * $qf).ToString('0', $inv)
        $fts = $ft.ToString('0.####', $inv)
        if ($Format -eq 'v2') {
            [void]$fsb.AppendLine("iRacingSim64DX11.exe,4242,0x000001A2B3C4D5E0,DXGI,0,0,0,Composed: Flip,$qpc,NA,$fts,$fts,$($cpu.ToString($inv)),$((($ft - $cpu)).ToString('0.###', $inv)),0.2,9.1,1.0,$($gpu.ToString($inv)),$($gpu.ToString($inv)),0.1,20.2,$fts")
        } else {
            [void]$fsb.AppendLine("iRacingSim64DX11.exe,4242,0x000001A2B3C4D5E0,DXGI,0,0,0,$((($t - 5.5)).ToString('0.######', $inv)),0.2,$fts,0,Composed: Flip,9.1,20.2,$fts")
        }
        # a second, rarely presenting swap chain (an overlay) that must be ignored
        if ($i % 500 -eq 0 -and $Format -eq 'v2') {
            [void]$fsb.AppendLine("iRacingSim64DX11.exe,4242,0x0000000000BADBAD,DXGI,1,0,0,Composed: Flip,$qpc,NA,500,500,1,499,0.1,1,1,1,1,0,1,500")
        }
        $t += $ft / 1000.0
        $i++
    }
    [IO.File]::WriteAllText((Join-Path $dir 'frames-1.csv'), $fsb.ToString())

    # ---- configs ------------------------------------------------------
    $fixtureUser = 'Test'   # kept out of the literal path: tests/test-locale.ps1 bans hard-coded profile paths
    $ini = "[Graphics]`r`nShadowMapSize=$ShadowValue`r`nMSAASamples=4`r`n[Display]`r`nFullScreen=1`r`n; C:\Users\$($env:USERNAME)\Documents\iRacing`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'configs\01-rendererDX11OpenXR.ini'), $ini)
    $man = @([ordered]@{ file = '01-rendererDX11OpenXR.ini'; original = "C:\Users\$fixtureUser\Documents\iRacing\rendererDX11OpenXR.ini"; source = 'catalog'; note = 'iRacing'; bytes = $ini.Length; modified = '2026-10-26T19:00:00' })
    (ConvertTo-Json -InputObject $man -Depth 4) | Set-Content -LiteralPath (Join-Path $dir 'configs\manifest.json') -Encoding UTF8
    return $dir
}
