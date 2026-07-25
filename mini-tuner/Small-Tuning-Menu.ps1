<#
    Small-Tuning-Menu.ps1
    Simplified iRacing tuning launcher with a single, easy workflow.
    - Keeps the initial CPU detection first
    - Offers a simple set of actions: Optimize, Race Routine, Defender Exclusions, Guide Extras
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

try {
    $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);'
    $win = Add-Type -MemberDefinition $sig -Name TunerMiniWin -Namespace TunerMini -PassThru
    $hwnd = $win::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        [void]$win::ShowWindow($hwnd, 2)
    }
} catch {}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$referenceRoot = Join-Path $workspaceRoot 'reference\iracing-x3d-tuning-main'
$scriptsDir = Join-Path $referenceRoot 'scripts'
$profileModule = Join-Path $scriptsDir 'X3D-Profiles.ps1'

if (-not (Test-Path $profileModule)) {
    [System.Windows.MessageBox]::Show("The reference scripts could not be found. Expected: $profileModule", 'Missing reference files', 'OK', 'Error') | Out-Null
    return
}

. $profileModule
$profile = Get-X3DProfile

function Show-Notification {
    param(
        [string]$Message,
        [string]$Title = 'iRacing Tuner Mini'
    )

    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}

function Invoke-ReferenceScript {
    param(
        [string]$ScriptName,
        [string]$DisplayName,
        [switch]$RequireElevation
    )

    $scriptPath = Join-Path $scriptsDir $ScriptName
    if (-not (Test-Path $scriptPath)) {
        Show-Notification "Could not find $scriptPath"
        return
    }

    $confirmMessage = "This will launch $DisplayName."
    if ($RequireElevation) {
        $confirmMessage += " It may ask for administrator permission."
    }
    $confirmMessage += " Continue?"

    $result = [System.Windows.MessageBox]::Show($confirmMessage, 'Confirm action', 'YesNo', 'Question')
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    if ($RequireElevation) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args | Out-Null
    }
    else {
        Start-Process powershell.exe -ArgumentList $args | Out-Null
    }

    Show-Notification "The action was launched. If you are prompted for elevation, approve it."
}

$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iRacing Tuner Mini"
        Width="560"
        SizeToContent="WidthAndHeight"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        Background="#0f172a"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1e293b"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Margin" Value="0,6,0,0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#475569"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="SectionTitle">
            <Setter Property="Foreground" Value="#f8fafc"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin" Value="0,0,0,6"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="BodyText">
            <Setter Property="Foreground" Value="#cbd5e1"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel>
            <TextBlock Text="iRacing Tuner Mini" FontSize="24" FontWeight="Bold" Foreground="#38bdf8"/>
            <TextBlock Text="A smaller, simpler launcher for your tuning routine." Margin="0,4,0,12" Foreground="#94a3b8"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#111827" BorderBrush="#334155" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,0,0,12">
            <StackPanel>
                <TextBlock Style="{StaticResource SectionTitle}" Text="Initial CPU check"/>
                <TextBlock x:Name="TxtCpuInfo" Style="{StaticResource BodyText}"/>
                <TextBlock x:Name="TxtCpuDetail" Style="{StaticResource BodyText}"/>
                <TextBlock x:Name="TxtCpuNote" Foreground="#86efac" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <Button x:Name="BtnOptimize" Content="Optimize My PC" Height="40" Background="#14532d" BorderBrush="#22c55e" FontWeight="Bold"/>

                <Border Background="#111827" BorderBrush="#334155" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,12,0,0">
                    <StackPanel>
                        <TextBlock Style="{StaticResource SectionTitle}" Text="Each Race Routine"/>
                        <TextBlock Style="{StaticResource BodyText}" Text="Use these before and after your session so the PC stays quiet and then restores itself."/>
                        <Button x:Name="BtnBeforeRace" Content="Before I Race"/>
                        <Button x:Name="BtnAfterRace" Content="After I Race"/>
                        <Button x:Name="BtnCheckQuiet" Content="Check Race-Ready Status"/>
                    </StackPanel>
                </Border>

                <Expander x:Name="ExpDefender" Header="Defender Exclusions" Margin="0,12,0,0" Foreground="#f8fafc" Background="#111827" BorderBrush="#334155" BorderThickness="1" Padding="6">
                    <StackPanel Margin="8,6,8,8">
                        <TextBlock Style="{StaticResource BodyText}" Text="Stops Defender from scanning iRacing files during a session so mid-race scans do not cause stutters."/>
                        <Button x:Name="BtnDefender" Content="Run Defender Exclusions"/>
                    </StackPanel>
                </Expander>

                <Expander x:Name="ExpGuideExtras" Header="Guide Extras" Margin="0,8,0,0" Foreground="#f8fafc" Background="#111827" BorderBrush="#334155" BorderThickness="1" Padding="6">
                    <StackPanel Margin="8,6,8,8">
                        <TextBlock Style="{StaticResource BodyText}" Text="Applies the small guide extras such as disabling USB selective suspend and Game Bar/Game DVR hooks."/>
                        <Button x:Name="BtnGuideExtras" Content="Run Guide Extras"/>
                    </StackPanel>
                </Expander>
            </StackPanel>
        </ScrollViewer>
    </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($XAML)

function Resize-Window {
    try {
        $window.Dispatcher.BeginInvoke([System.Action]{
            $window.SizeToContent = 'Manual'
            $window.UpdateLayout()
            $window.SizeToContent = 'WidthAndHeight'
            $window.UpdateLayout()
        }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    } catch {}
}

$cpuInfo = $window.FindName('TxtCpuInfo')
$cpuDetail = $window.FindName('TxtCpuDetail')
$cpuNote = $window.FindName('TxtCpuNote')

if ($profile) {
    $cpuInfo.Text = "Detected CPU: $($profile.Model)"
    $cpuDetail.Text = "$($profile.Profile) | $((Get-X3DTopologySummary $profile))"
    $cpuNote.Text = "This initial check is used so the optimizer and race routine logic can match your CPU profile before anything else runs."
}
else {
    $cpuInfo.Text = 'CPU profile could not be detected.'
    $cpuDetail.Text = 'The scripts will still try to run, but the logic may be limited.'
    $cpuNote.Text = 'You can still continue using the simplified menu.'
}

$window.Add_Loaded({ Resize-Window })

$expanderNames = @('ExpDefender','ExpGuideExtras')
foreach ($expanderName in $expanderNames) {
    $expander = $window.FindName($expanderName)
    if ($expander) {
        $expander.Add_Expanded({ Resize-Window })
        $expander.Add_Collapsed({ Resize-Window })
    }
}

$window.FindName('BtnOptimize').Add_Click({
    $baselineScript = Join-Path $scriptsDir 'Apply-Baseline.ps1'
    if (-not (Test-Path $baselineScript)) {
        Show-Notification "Could not find the baseline script: $baselineScript"
        return
    }

    $result = [System.Windows.MessageBox]::Show('This launches the full baseline optimizer and may prompt for administrator access. Continue?', 'Optimize My PC', 'YesNo', 'Question')
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$baselineScript`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args | Out-Null
    Show-Notification 'The optimizer was launched. Follow the prompts and reboot after it completes.'
})

$window.FindName('BtnBeforeRace').Add_Click({ Invoke-ReferenceScript -ScriptName 'Pre-Race-Quiet.ps1' -DisplayName 'the before-race routine' -RequireElevation })
$window.FindName('BtnAfterRace').Add_Click({ Invoke-ReferenceScript -ScriptName 'Post-Race-Restore.ps1' -DisplayName 'the after-race routine' -RequireElevation })
$window.FindName('BtnCheckQuiet').Add_Click({ Invoke-ReferenceScript -ScriptName 'Check-Quiet-Status.ps1' -DisplayName 'the race-ready check' })
$window.FindName('BtnDefender').Add_Click({ Invoke-ReferenceScript -ScriptName 'Add-Defender-Exclusions.ps1' -DisplayName 'Defender exclusions' -RequireElevation })
$window.FindName('BtnGuideExtras').Add_Click({ Invoke-ReferenceScript -ScriptName 'Apply-Guide-Extras.ps1' -DisplayName 'Guide extras' -RequireElevation })

$window.ShowDialog() | Out-Null
