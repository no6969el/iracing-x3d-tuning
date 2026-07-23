<#
    iRacing X3D Tuning - GUI Dashboard  (upgraded)
    ---------------------------------------------------------------
    Modern WPF interface. Upgrades over the previous version:
      * Window auto-sizes to each page (no more clipped buttons)
      * Help page + per-button tooltips (the info is back)
      * Optimize now shows the manual Process Lasso steps too
      * Adds Check race-ready status and Reset system info
      * Console window hidden for a clean app feel; safe error dialog
#>

# 1. Self-correct to STA (required for WPF)
if ($host.Runspace.ApartmentState -ne "STA") {
    Start-Process powershell.exe -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -WindowStyle Hidden
    return
}

# 2. Hide this console window (clean GUI-only look)
try {
    $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);'
    $win = Add-Type -MemberDefinition $sig -Name Win -Namespace X3D -PassThru
    $win::ShowWindow($win::GetConsoleWindow(), 0) | Out-Null
} catch { }

$ErrorActionPreference = 'SilentlyContinue'
$Root       = $PSScriptRoot
$ScriptsDir = Join-Path $Root 'scripts'
$SiteUrl    = 'https://no6969el.github.io/iracing-x3d-tuning/'

# ---------------------------------------------------------------- detection
# All CPU knowledge now lives in scripts\X3D-Profiles.ps1 (every X3D SKU,
# real CCD boundaries from the L3 cache topology, and hard validation so a
# target core can never point at a processor that doesn't exist).
$ProfileModule = Join-Path $ScriptsDir 'X3D-Profiles.ps1'
if (-not (Test-Path $ProfileModule)) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("scripts\X3D-Profiles.ps1 is missing.`n`nRe-unzip the kit so the scripts folder sits next to this file.","Missing file")
    return
}
. $ProfileModule

$cfg      = Get-X3DProfile
$CanSteer = ($cfg.TopologyKnown -and $cfg.IsX3D -and $cfg.FreqFirst -ge 1 -and $cfg.FreqFirst -lt $cfg.ActualLogical)

# ---------------------------------------------------------------- GUI
Add-Type -AssemblyName PresentationFramework

[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iRacing X3D Tuning Dashboard" Width="640" SizeToContent="Height"
        MinHeight="300" WindowStartupLocation="CenterScreen" ResizeMode="CanResize"
        Background="#121212" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="Margin" Value="0,4,0,4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="Hint">
            <Setter Property="Foreground" Value="#888888"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="6,0,0,8"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
        <Style TargetType="Expander">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,3,0,3"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="Background" Value="#1A1A1A"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="ExpText">
            <Setter Property="Foreground" Value="#CCCCCC"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style TargetType="Button" x:Key="RunBtn">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="HorizontalAlignment" Value="Left"/>
        </Style>
    </Window.Resources>

    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Text="iRACING X3D TUNING" FontSize="22" FontWeight="Bold" Foreground="#4CAF50" HorizontalAlignment="Center"/>
        <Border Grid.Row="1" BorderBrush="#333333" BorderThickness="0,0,0,1" Margin="0,10,0,15" Padding="0,0,0,10">
            <StackPanel>
                <TextBlock x:Name="TxtSysInfo" Text="CPU | GPU" Foreground="#CCCCCC" FontSize="13" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
                <TextBlock x:Name="TxtTopo" Text="Topology" Foreground="#888888" FontSize="12" HorizontalAlignment="Center" Margin="0,5,0,0" TextAlignment="Center"/>
            </StackPanel>
        </Border>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
        <Grid>

            <!-- MAIN -->
            <StackPanel x:Name="PageMain" Visibility="Visible">
                <Button x:Name="BtnOptimize" Content="1) OPTIMIZE MY iRACING  (Recommended)" Background="#1E4620" BorderBrush="#4CAF50" FontWeight="Bold" Height="46" ToolTip="Guided baseline: shows the manual Process Lasso steps, then runs the automatic fixes."/>
                <TextBlock Style="{StaticResource Hint}" Text="Applies the proven baseline fixes, guided end to end."/>
                <Button x:Name="BtnTroubleshoot" Content="2) TROUBLESHOOT A STUTTER" ToolTip="Record a race and pinpoint what caused a hitch."/>
                <Button x:Name="BtnEachRace" Content="3) EACH-RACE ROUTINE" ToolTip="Quiet the PC before you race; restore after."/>
                <Button x:Name="BtnAdvanced" Content="ADVANCED TOOLS / UNDO" ToolTip="Run or undo individual fixes. Most people don't need this."/>
                <Button x:Name="BtnHelp" Content="HELP  /  WHAT DO I NEED FIRST" Background="#15303A" BorderBrush="#3EA6FF" ToolTip="What each step does, and the free app you need."/>
                <Grid Margin="0,15,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="BtnWebGuide" Content="Web Guide" Grid.Column="0" Margin="0,0,4,0" Background="#1E1E1E"/>
                    <Button x:Name="BtnChip" Content="CPU profile" Grid.Column="1" Margin="4,0,4,0" Background="#1E1E1E" ToolTip="See the chip that was detected, or pick it yourself."/>
                    <Button x:Name="BtnExit" Content="Exit" Grid.Column="2" Margin="4,0,0,0" Background="#4A1919" BorderBrush="#FF5252"/>
                </Grid>
            </StackPanel>

            <!-- OPTIMIZE -->
            <StackPanel x:Name="PageOptimize" Visibility="Collapsed">
                <TextBlock Text="OPTIMIZE MY iRACING" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,8"/>
                <TextBlock x:Name="TxtOptHeading" Text="First, two steps by hand in Process Lasso (free, bitsum.com):" Foreground="#FFB74D" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,6"/>
                <TextBlock x:Name="TxtOptManual" Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="6,0,0,12"/>
                <Button x:Name="BtnRunAuto" Content="Run the automatic fixes now  (Admin)" Background="#1E4620" BorderBrush="#4CAF50" FontWeight="Bold" Height="44" ToolTip="Runs Defender exclusions, USB/Game Bar, task log, timer + GPU-IRQ in one elevated window."/>
                <TextBlock Style="{StaticResource Hint}" Text="Runs the scriptable fixes in one elevated window that closes itself."/>
                <TextBlock Text="Then: set your iRacing in-game + NVIDIA options (Web Guide), and REBOOT once." Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"/>
                <Button x:Name="BtnBackFromOptimize" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,15,0,0"/>
            </StackPanel>

            <!-- TROUBLESHOOT -->
            <StackPanel x:Name="PageTroubleshoot" Visibility="Collapsed">
                <TextBlock Text="TROUBLESHOOT A STUTTER" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,10"/>
                <Expander Header="1) Record a race (FullTrace)" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Records everything your PC does while you drive. Start it, race, then press Ctrl+C to stop - it saves a CSV to your Desktop."/>
                        <Button x:Name="BtnFullTrace" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="2) Turn on task log (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Turns on Windows task logging. Do this BEFORE the race so the scan can see which background task fired during a stutter."/>
                        <Button x:Name="BtnEnableLogs" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="3) Find the cause (Scan-Stutter-Events)" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Automatically reads your most recent trace and names the most likely cause of the stutter."/>
                        <Button x:Name="BtnScan" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="4) Confirm setup is live (Preflight-Check)" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Checks that your setup is actually live: power plan, GPU-IRQ affinity, Process Lasso, and core pinning."/>
                        <Button x:Name="BtnPreflight" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="5) Watch timer resolution" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Opens a live view of the system timer resolution so you can watch it change in real time."/>
                        <Button x:Name="BtnWatchTimer" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="6) Am I race-ready? (Check status)" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Shows whether the pre-race quieting (paused background scans) is active on your PC right now."/>
                        <Button x:Name="BtnCheckQuiet1" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Button x:Name="BtnBackFromTroubleshoot" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,15,0,0"/>
            </StackPanel>

            <!-- EACH RACE -->
            <StackPanel x:Name="PageEachRace" Visibility="Collapsed">
                <TextBlock Text="EACH-RACE ROUTINE" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,10"/>
                <Button x:Name="BtnPreRace" Content="1) Before I race (Pre-Race-Quiet)" Foreground="#FFB74D" ToolTip="Pauses Windows Update/Search scans for the session. Run before you drive."/>
                <Button x:Name="BtnPostRace" Content="2) After I race (Post-Race-Restore)" Foreground="#FFB74D" ToolTip="Turns Update/Search/Defender back on. Run after every session."/>
                <Button x:Name="BtnCheckQuiet2" Content="3) Am I race-ready? (Check status)" ToolTip="Shows if the pre-race quieting is active right now."/>
                <Button x:Name="BtnBackFromEachRace" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,15,0,0"/>
            </StackPanel>

            <!-- ADVANCED -->
            <StackPanel x:Name="PageAdvanced" Visibility="Collapsed">
                <TextBlock Text="ADVANCED TOOLS" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Hint}" Text="Most people don't need these - use Optimize instead."/>
                <Expander Header="Create-Launchers (shortcuts)" Foreground="White">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Puts desktop and Start-menu shortcuts for these tools so you can run them without opening this menu."/>
                        <Button x:Name="BtnCreateLaunchers" Content="Run" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="Repair-PerfCounters (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Rebuilds Windows performance counters. Use this if a trace recording or the stutter scan fails to run."/>
                        <Button x:Name="BtnRepair" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="Set-GPU-IRQ-Affinity (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Moves GPU interrupts off the core the sim runs on to reduce hitching. Takes effect after a reboot."/>
                        <Button x:Name="BtnGPUIRQ" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="Enable-GlobalTimerResolution (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Forces a steady high-resolution system timer for smoother, more even frame pacing."/>
                        <Button x:Name="BtnTimerFix" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="Add-Defender-Exclusions (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Tells Windows Defender to skip iRacing so a mid-race virus scan can't cause a stutter."/>
                        <Button x:Name="BtnDefender" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="Apply-Guide-Extras (Admin)" Foreground="#FFB74D">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Applies the smaller guide tweaks (USB power, Game Bar, and similar) in one pass."/>
                        <Button x:Name="BtnExtras" Content="Run (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="UNDO: GPU-IRQ-Affinity (Admin)" Foreground="#FF5252">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Reverses the GPU-IRQ change and restores Windows' default interrupt handling."/>
                        <Button x:Name="BtnUndoGPU" Content="Undo (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Expander Header="UNDO: GlobalTimerResolution (Admin)" Foreground="#FF5252">
                    <StackPanel Margin="26,2,4,8">
                        <TextBlock Style="{StaticResource ExpText}" Text="Reverses the timer change and restores Windows' default timer behavior."/>
                        <Button x:Name="BtnUndoTimer" Content="Undo (Admin)" Style="{StaticResource RunBtn}"/>
                    </StackPanel>
                </Expander>
                <Button x:Name="BtnBackFromAdvanced" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,10,0,0"/>
            </StackPanel>

            <!-- CPU PROFILE / CHIP PICKER -->
            <StackPanel x:Name="PageChip" Visibility="Collapsed">
                <TextBlock Text="CPU PROFILE" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,4"/>
                <TextBlock x:Name="TxtChipNow" Foreground="#4CAF50" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,2"/>
                <TextBlock x:Name="TxtChipDetail" Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <TextBlock x:Name="TxtChipWarn" Foreground="#FFB74D" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <TextBlock Text="Wrong? Pick your chip class below - everything in a group behaves the same here." Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,8"/>
                <Button x:Name="BtnChip1" Content="6-core single-CCD   -   5500X3D / 5600X3D / 7500X3D / 7600X3D"/>
                <Button x:Name="BtnChip2" Content="8-core single-CCD   -   5700X3D / 5800X3D / 7700X3D / 7800X3D / 9800X3D / 9850X3D"/>
                <Button x:Name="BtnChip3" Content="12-core dual-CCD   -   7900X3D / 9900X3D"/>
                <Button x:Name="BtnChip4" Content="16-core dual-CCD   -   7950X3D / 9950X3D / 7945HX3D / 9955HX3D"/>
                <Button x:Name="BtnChip5" Content="16-core dual-CCD, V-Cache on BOTH   -   9950X3D2 Dual Edition"/>
                <Button x:Name="BtnChip6" Content="Something else / not an X3D   -   general fixes only"/>
                <Button x:Name="BtnChipAuto" Content="Detect my CPU again (clears the saved profile)" Background="#15303A" BorderBrush="#3EA6FF" Margin="0,10,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="After changing this, close and reopen the dashboard so every page picks up the new core numbers."/>
                <Button x:Name="BtnBackFromChip" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,10,0,0"/>
            </StackPanel>

            <!-- HELP -->
            <StackPanel x:Name="PageHelp" Visibility="Collapsed">
                <TextBlock Text="HELP  -  what each step does" FontSize="16" Foreground="White" FontWeight="Bold" Margin="0,0,0,8"/>
                <TextBlock x:Name="TxtHelpReq" Foreground="#FFB74D" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap"><Run FontWeight="Bold" Foreground="White">Optimize</Run> - runs every proven fix in order (guided). Start here.</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">FullTrace</Run> - records a race so you can see stutters; race then Ctrl+C.</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">Enable task log</Run> - turn on BEFORE a race so the scan has data.</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">Scan-Stutter-Events</Run> - reads your latest trace and names the culprit.</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">GPU-IRQ-Affinity</Run> - moves GPU interrupts off the sim's core (needs reboot).</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">Pre / Post-Race</Run> - pause background scans before a race, restore after.</TextBlock>
                <TextBlock Foreground="#CCCCCC" FontSize="13" TextWrapping="Wrap" Margin="0,6,0,0"><Run FontWeight="Bold" Foreground="White">Am I race-ready?</Run> - checks if the pre-race quieting is active right now.</TextBlock>
                <TextBlock Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0" Text="Full details, including the iRacing and NVIDIA settings, are in the Web Guide."/>
                <Button x:Name="BtnBackFromHelp" Content="Back to Main Menu" Background="#1E1E1E" Margin="0,15,0,0"/>
            </StackPanel>

        </Grid>
        </ScrollViewer>
    </Grid>
</Window>
"@

try {
    $Reader = New-Object System.Xml.XmlNodeReader $XAML
    $Window = [Windows.Markup.XamlReader]::Load($Reader)
} catch {
    [System.Windows.MessageBox]::Show("The dashboard failed to load.`n`n$($_.Exception.Message)","Startup error")
    return
}

# ---------------------------------------------------------------- logic
$pages = @{}
foreach($p in 'PageMain','PageOptimize','PageTroubleshoot','PageEachRace','PageAdvanced','PageHelp','PageChip'){ $pages[$p]=$Window.FindName($p) }

function Update-Header {
    $sim = if ($cfg.Simulated) { "  [SIMULATED]" } else { "" }
    $Window.FindName("TxtSysInfo").Text = "$($cfg.Model)  |  $($cfg.GpuName)$sim"
    $Window.FindName("TxtTopo").Text    = (Get-X3DTopologySummary $cfg)
    $Window.FindName("TxtOptManual").Text = (Get-X3DPinningAdvice $cfg).Trim()

    # The "do this by hand first" heading only makes sense when there IS
    # something to do by hand. Non-X3D chips have no Process Lasso step at all.
    $optHead = $Window.FindName("TxtOptHeading")
    if (-not $cfg.IsX3D) {
        $optHead.Visibility = 'Collapsed'
    } elseif ($cfg.Topology -eq 'single') {
        $optHead.Visibility = 'Visible'
        $optHead.Text = "First, one step by hand in Process Lasso (free, bitsum.com):"
    } else {
        $optHead.Visibility = 'Visible'
        $optHead.Text = "First, two steps by hand in Process Lasso (free, bitsum.com):"
    }

    if (-not $cfg.IsX3D) {
        $Window.FindName("TxtHelpReq").Text = "No 3D V-Cache detected on this CPU. The general fixes still apply; core pinning and interrupt steering are skipped. Process Lasso is optional here."
    } elseif ($cfg.Topology -eq 'single') {
        $Window.FindName("TxtHelpReq").Text = "You need: Process Lasso (free, bitsum.com) - it sets the Bitsum Highest Performance power plan."
    } else {
        $Window.FindName("TxtHelpReq").Text = "You need: Process Lasso (free, bitsum.com) - it pins the sim to your V-Cache cores AND sets the Bitsum Highest Performance power plan."
    }

    $Window.FindName("TxtChipNow").Text    = "Detected: $($cfg.Model)"
    $Window.FindName("TxtChipDetail").Text = "$($cfg.Profile)  |  $($cfg.LogicalCores) logical CPUs  |  interrupt target CPU $($cfg.FreqFirst)  |  source: $($cfg.DetectSource)"
    $warn = ''
    if ($cfg.Warnings -and $cfg.Warnings.Count) { $warn = ($cfg.Warnings -join "`n`n") }
    $Window.FindName("TxtChipWarn").Text = $warn
    $Window.FindName("TxtChipWarn").Visibility = if ($warn) { 'Visible' } else { 'Collapsed' }
}
Update-Header

# Interrupt steering only makes sense when we actually understand the CPU.
if (-not $CanSteer) {
    $b = $Window.FindName("BtnGPUIRQ")
    if ($b) { $b.IsEnabled = $false; $b.ToolTip = "Not applicable on this CPU - topology unknown or no V-Cache." }
}

function Show-Page($name){ foreach($k in $pages.Keys){ $pages[$k].Visibility = 'Collapsed' }; $pages[$name].Visibility = 'Visible' }

function Launch-Script($FileName, [switch]$Admin) {
    $path = Join-Path $ScriptsDir $FileName
    if (-not (Test-Path $path)) {
        [System.Windows.MessageBox]::Show("Cannot find $FileName in the 'scripts' folder.","File missing")
        return
    }
    $env:X3D_FREQ_FIRST_CORE = "$($cfg.FreqFirst)"
    $env:X3D_SIMULATED       = $(if ($cfg.Simulated) { '1' } else { '0' })
    $argStr = "-NoExit -ExecutionPolicy Bypass -File `"$path`""
    try {
        if ($Admin) { Start-Process 'powershell.exe' -Verb RunAs -ArgumentList $argStr }
        else        { Start-Process 'powershell.exe'           -ArgumentList $argStr }
    } catch { [System.Windows.MessageBox]::Show("Launch failed or the admin prompt was cancelled.","Error") }
}

# navigation
$Window.FindName("BtnOptimize").Add_Click({ Show-Page 'PageOptimize' })
$Window.FindName("BtnTroubleshoot").Add_Click({ Show-Page 'PageTroubleshoot' })
$Window.FindName("BtnEachRace").Add_Click({ Show-Page 'PageEachRace' })
$Window.FindName("BtnAdvanced").Add_Click({ Show-Page 'PageAdvanced' })
$Window.FindName("BtnHelp").Add_Click({ Show-Page 'PageHelp' })
$Window.FindName("BtnChip").Add_Click({ Show-Page 'PageChip' })
$Window.FindName("BtnBackFromChip").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnBackFromOptimize").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnBackFromTroubleshoot").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnBackFromEachRace").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnBackFromAdvanced").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnBackFromHelp").Add_Click({ Show-Page 'PageMain' })
$Window.FindName("BtnExit").Add_Click({ $Window.Close() })
$Window.FindName("BtnWebGuide").Add_Click({ Start-Process $SiteUrl })

function Set-ChipClass($key) {
    Clear-X3DConfig
    if ($key -eq 'AUTO') {
        $script:cfg = Get-X3DProfile -NoCache
    } else {
        $cls = Get-X3DClasses | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($cls -and $cls.Cores -ge 1) { $script:cfg = Get-X3DProfile -NoCache -Assume $cls }
        else                            { $script:cfg = Get-X3DProfile -NoCache }
    }
    Export-X3DConfig $script:cfg
    Update-Header
    [System.Windows.MessageBox]::Show(
        "Profile set to:`n$($script:cfg.Model)`n$($script:cfg.Profile)`n`nInterrupt target: CPU $($script:cfg.FreqFirst)`n`nClose and reopen the dashboard so every page picks up the new numbers.",
        "CPU profile updated")
}

$Window.FindName("BtnChip1").Add_Click({ Set-ChipClass '1' })
$Window.FindName("BtnChip2").Add_Click({ Set-ChipClass '2' })
$Window.FindName("BtnChip3").Add_Click({ Set-ChipClass '3' })
$Window.FindName("BtnChip4").Add_Click({ Set-ChipClass '4' })
$Window.FindName("BtnChip5").Add_Click({ Set-ChipClass '5' })
$Window.FindName("BtnChip6").Add_Click({ Set-ChipClass '6' })
$Window.FindName("BtnChipAuto").Add_Click({ Set-ChipClass 'AUTO' })

# tools
$Window.FindName("BtnFullTrace").Add_Click({ Launch-Script 'FullTrace.ps1' })
$Window.FindName("BtnEnableLogs").Add_Click({ Launch-Script 'Enable-DiagnosticLogs.ps1' -Admin })
$Window.FindName("BtnScan").Add_Click({ Launch-Script 'Scan-Stutter-Events.ps1' })
$Window.FindName("BtnPreflight").Add_Click({ Launch-Script 'Preflight-Check.ps1' })
$Window.FindName("BtnWatchTimer").Add_Click({ Launch-Script 'Watch-TimerResolution.ps1' })
$Window.FindName("BtnCheckQuiet1").Add_Click({ Launch-Script 'Check-Quiet-Status.ps1' })
$Window.FindName("BtnCheckQuiet2").Add_Click({ Launch-Script 'Check-Quiet-Status.ps1' })
$Window.FindName("BtnPreRace").Add_Click({ Launch-Script 'Pre-Race-Quiet.ps1' -Admin })
$Window.FindName("BtnPostRace").Add_Click({ Launch-Script 'Post-Race-Restore.ps1' -Admin })
$Window.FindName("BtnCreateLaunchers").Add_Click({ Launch-Script 'Create-Launchers.ps1' })
$Window.FindName("BtnRepair").Add_Click({ Launch-Script 'Repair-PerfCounters.ps1' -Admin })
$Window.FindName("BtnGPUIRQ").Add_Click({ Launch-Script 'Set-GPU-IRQ-Affinity.ps1' -Admin })
$Window.FindName("BtnTimerFix").Add_Click({ Launch-Script 'Enable-GlobalTimerResolution.ps1' -Admin })
$Window.FindName("BtnDefender").Add_Click({ Launch-Script 'Add-Defender-Exclusions.ps1' -Admin })
$Window.FindName("BtnExtras").Add_Click({ Launch-Script 'Apply-Guide-Extras.ps1' -Admin })
$Window.FindName("BtnUndoGPU").Add_Click({ Launch-Script 'Undo-GPU-IRQ-Affinity.ps1' -Admin })
$Window.FindName("BtnUndoTimer").Add_Click({ Launch-Script 'Undo-GlobalTimerResolution.ps1' -Admin })

# optimize - run the automatic fixes in one elevated window
$Window.FindName("BtnRunAuto").Add_Click({
    # No Process Lasso prerequisite on a non-X3D chip, so don't ask about one.
    # The UAC prompt that follows is confirmation enough.
    $result = 'Yes'
    if ($cfg.IsX3D) {
        $prereq = if ($cfg.Topology -eq 'single') {
            "Make sure you set the Process Lasso power plan shown above first. Continue?"
        } else {
            "Make sure you did the Process Lasso steps shown above first. Continue?"
        }
        $result = [System.Windows.MessageBox]::Show(
            "This runs the automatic fixes in one elevated window (it closes itself when done).`n`n$prereq",
            "Run automatic fixes", [System.Windows.MessageBoxButton]::YesNo)
    }
    if ($result -eq 'Yes') {
        $auto = @('Add-Defender-Exclusions.ps1','Apply-Guide-Extras.ps1','Enable-DiagnosticLogs.ps1','Enable-GlobalTimerResolution.ps1')
        if ($CanSteer) { $auto += 'Set-GPU-IRQ-Affinity.ps1' }
        $simFlag = $(if ($cfg.Simulated) { '1' } else { '0' })
        $sb = "`$env:X3D_FREQ_FIRST_CORE='$($cfg.FreqFirst)'; `$env:X3D_SIMULATED='$simFlag'; `$Host.UI.RawUI.WindowTitle='Applying Fixes';"
        if ($cfg.Simulated) { $sb += " `$env:X3D_FORCE_PROFILE='$($env:X3D_FORCE_PROFILE)';" }
        foreach($script in $auto) {
            $pth = Join-Path $ScriptsDir $script
            if (Test-Path $pth) {
                $esc = $pth -replace "'","''"
                $sb += " Write-Host ''; Write-Host 'Running $script...' -ForegroundColor Cyan; & '$esc';"
            }
        }
        $sb += " Write-Host ''; Write-Host 'ALL FIXES APPLIED - reboot once. This window closes in 6 seconds...' -ForegroundColor Green; Start-Sleep 6"
        try {
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sb))
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
        } catch { [System.Windows.MessageBox]::Show("Admin prompt cancelled.","Aborted") }
    }
})

# Grow the window to fit the page, but never past the screen; scroll only when it must
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($wa.Height -gt 0) { $Window.MaxHeight = [Math]::Max(300, $wa.Height - 40) }
} catch { }

$Window.ShowDialog() | Out-Null
