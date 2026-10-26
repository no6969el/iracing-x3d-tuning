<#
    GamePerf  -  frame-time logger + AI analyst for any game, monitor or VR
    ================================================================
    Start logging, play, stop. You get:
      * per-frame timing (PresentMon) and a 1 Hz system timeline built
        on the kit's FullTrace method, in Documents\GamePerf\Sessions
      * a report: verdict, frame pacing, what limited the frames, the
        worst stutters and what the PC was doing at each one
      * ai-prompt.md - everything an AI analyst needs, including the
        game's config files - to paste into Grok / ChatGPT / Claude /
        Gemini, or send from the AI page if you connect a provider

    Low resource and silent by design: this window does nothing while you
    play (it minimises and reads one small status file a second), renders
    in software so it never touches the GPU the game is using, and never
    jumps in front of the game - when a session ends it flashes its
    taskbar button. All measurement happens in a separate, windowless
    recorder that this app starts, watches and stops.

    Start it with GamePerf.exe (the icon). It runs on the Windows
    PowerShell 5.1 engine built into Windows 10/11; Start-GamePerf.bat
    remains as a fallback.
#>

# ---- STA is required for WPF ------------------------------------
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`"" -WindowStyle Hidden
    return
}

$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
$LibDir = Join-Path $AppDir 'lib'
. (Join-Path $LibDir 'GamePerf-Common.ps1')
. (Join-Path $LibDir 'GamePerf-Games.ps1')
. (Join-Path $LibDir 'GamePerf-AI.ps1')
$LoggerPath  = Join-Path $LibDir 'GamePerf-Logger.ps1'
$AnalyzePath = Join-Path $LibDir 'GamePerf-Analyze.ps1'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Compiled helpers (a cached DLL after the first run): window chrome,
# taskbar identity, and a focus-free "done" flash.
$NativeOk = Initialize-GpNative
if ($NativeOk) {
    [GamePerf.Native.Win]::HideConsole()
    [GamePerf.Native.Win]::SetAppId('GamePerf.App')
}
$IconPath = Join-Path $AppDir 'launcher\GamePerf.ico'

# Software rendering: this window never competes with the game for the GPU.
try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch { }

$Settings = Import-GpSettings

# ================================================================
#  UI
# ================================================================
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GamePerf" Width="1120" Height="760" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0E1116" Foreground="#E8EAED"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#161A22"/>
    <SolidColorBrush x:Key="Field" Color="#11151C"/>
    <SolidColorBrush x:Key="Line" Color="#272D39"/>
    <SolidColorBrush x:Key="Sub" Color="#9AA3B2"/>
    <SolidColorBrush x:Key="Mute" Color="#687284"/>
    <SolidColorBrush x:Key="Accent" Color="#3DDC97"/>
    <SolidColorBrush x:Key="AccentDim" Color="#13261F"/>
    <SolidColorBrush x:Key="Warn" Color="#F5B544"/>
    <SolidColorBrush x:Key="Danger" Color="#F0616D"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Mute}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Sub}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Background" Value="#232937"/>
      <Setter Property="BorderBrush" Value="#2F3747"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8"/>
              <Border x:Name="Hover" Background="White" Opacity="0" CornerRadius="8"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="0.06"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="0.14"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#3DDC97"/>
      <Setter Property="BorderBrush" Value="#3DDC97"/>
      <Setter Property="Foreground" Value="#06120C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#F0616D"/>
      <Setter Property="BorderBrush" Value="#F0616D"/>
      <Setter Property="Foreground" Value="#1A0507"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#3DDC97"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style x:Key="BtnIcon" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Sub}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="12,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="9" Padding="12,11" Background="Transparent">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border x:Name="Bar" Width="3" Height="18" CornerRadius="2" Background="#3DDC97" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Hidden"/>
                <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource Icons}" FontSize="16" VerticalAlignment="Center"/>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#141820"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1A202B"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#E8EAED"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Sub}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="7" Padding="18,8" Background="Transparent" Margin="2">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource Icons}" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#3DDC97"/>
                <Setter Property="Foreground" Value="#06120C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#3A4252" Background="#11151C" VerticalAlignment="Top" Margin="0,1,0,0">
                <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="#06120C" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#3DDC97"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#3DDC97"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#3DDC97"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Background" Value="#11151C"/>
      <Setter Property="BorderBrush" Value="#2A303C"/>
      <Setter Property="CaretBrush" Value="#3DDC97"/>
      <Setter Property="SelectionBrush" Value="#3DDC97"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#3DDC97"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Background" Value="#11151C"/>
      <Setter Property="CaretBrush" Value="#3DDC97"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="#2A303C" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#3DDC97"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="B" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="4,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="#232B39"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="#13261F"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="MaxDropDownHeight" Value="360"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="B" Background="#11151C" BorderBrush="#2A303C" BorderThickness="1" CornerRadius="8">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#9AA3B2" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#3DDC97"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="12,9,34,9" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
                <Border Background="#161A22" BorderBrush="#2F3747" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter Margin="0,4"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="B" Background="Transparent" CornerRadius="10" Padding="12,10" Margin="0,0,0,4" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#141820"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1A202B"/>
                <Setter TargetName="B" Property="BorderBrush" Value="#2C5E49"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#2E3542" Margin="2"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" Focusable="False">
                  <Track.Thumb>
                    <Thumb>
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#2E3542" Margin="2"/></ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1C212B"/>
      <Setter Property="Foreground" Value="#E8EAED"/>
      <Setter Property="BorderBrush" Value="#2F3747"/>
      <Setter Property="Padding" Value="10,6"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="224"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============ NAV ============ -->
    <Border Background="#0A0C10" BorderBrush="#1A1F28" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="24,28,20,26">
          <StackPanel Orientation="Horizontal">
            <Border Width="32" Height="32" CornerRadius="9" Background="#3DDC97">
              <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource Icons}" Foreground="#06120C" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="GamePerf" FontSize="21" FontWeight="Bold" Margin="11,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="Frame-time logger + AI analyst" Foreground="{StaticResource Mute}" FontSize="11.5" Margin="1,8,0,0"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="22,0,22,20">
          <Border CornerRadius="9" Background="#12161D" Padding="12,9" BorderBrush="#1E242F" BorderThickness="1">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#687284" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtStatus" Text="Idle" Margin="9,0,0,0" FontSize="12" Foreground="{StaticResource Sub}"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="TxtVersion" Foreground="{StaticResource Mute}" FontSize="11" Margin="2,10,0,0"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavRecord" Style="{StaticResource Nav}" GroupName="Nav" Tag="&#xE7C8;" Content="Record" IsChecked="True"/>
          <RadioButton x:Name="NavResults" Style="{StaticResource Nav}" GroupName="Nav" Tag="&#xE9D9;" Content="Results"/>
          <RadioButton x:Name="NavAi" Style="{StaticResource Nav}" GroupName="Nav" Tag="&#xE8BD;" Content="AI analyst"/>
          <RadioButton x:Name="NavSettings" Style="{StaticResource Nav}" GroupName="Nav" Tag="&#xE713;" Content="Settings"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ============ PAGES ============ -->
    <Grid Grid.Column="1">

      <!-- RECORD -->
      <ScrollViewer x:Name="PageRecord" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,30,36,30" MaxWidth="920">
          <TextBlock Text="Record a session" Style="{StaticResource H1}"/>
          <TextBlock Text="Start logging, play, then stop. Everything is saved and analysed, ready for you or an AI to read." Style="{StaticResource Hint}" FontSize="13" Margin="0,6,0,22"/>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="GAME" Style="{StaticResource Caption}"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <ComboBox x:Name="CmbGame"/>
                <Button x:Name="BtnRefreshGames" Grid.Column="1" Style="{StaticResource BtnIcon}" Content="&#xE72C;" ToolTip="Look for running games again"/>
              </Grid>
              <Grid Margin="0,18,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="28"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="DISPLAY" Style="{StaticResource Caption}"/>
                  <Border Background="#11151C" CornerRadius="9" BorderBrush="#2A303C" BorderThickness="1">
                    <StackPanel Orientation="Horizontal">
                      <RadioButton x:Name="RbMonitor" Style="{StaticResource Seg}" GroupName="Mode" Tag="&#xE7F4;" Content="Monitor" IsChecked="True"/>
                      <RadioButton x:Name="RbVr" Style="{StaticResource Seg}" GroupName="Mode" Tag="&#xE7FC;" Content="VR headset"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="TARGET FPS" Style="{StaticResource Caption}"/>
                  <StackPanel Orientation="Horizontal">
                    <TextBox x:Name="TxtTarget" Width="90"/>
                    <TextBlock x:Name="TxtTargetHint" Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
              <TextBlock Text="WHAT DID YOU CHANGE SINCE LAST TIME? (OPTIONAL - HELPS THE A/B COMPARISON)" Style="{StaticResource Caption}" Margin="0,18,0,6"/>
              <TextBox x:Name="TxtLabel"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="CAPTURE" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
                <CheckBox x:Name="ChkFrames" Content="Per-frame timing (PresentMon)"/>
                <CheckBox x:Name="ChkAdmin" Content="Ask for admin when per-frame timing needs it"/>
                <TextBlock x:Name="TxtAdminHint" Style="{StaticResource Hint}" Margin="28,-6,0,10"/>
                <CheckBox x:Name="ChkStopWithGame" Content="Stop when the game closes"/>
                <CheckBox x:Name="ChkMinimize" Content="Minimise this window while logging"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="MARKER KEY" Style="{StaticResource Caption}"/>
                <ComboBox x:Name="CmbMarker"/>
                <TextBlock Text="Press it the moment you feel a hitch - the analysis looks there first. Map it to a button-box button for VR." Style="{StaticResource Hint}" Margin="0,8,0,0"/>
                <Border Background="#11151C" CornerRadius="9" Padding="12,10" Margin="0,14,0,0">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtPmStatus" Style="{StaticResource Hint}" VerticalAlignment="Center"/>
                    <Button x:Name="BtnGetPm" Grid.Column="1" Style="{StaticResource BtnGhost}" Content="Get PresentMon" Margin="8,0,0,0"/>
                  </Grid>
                </Border>
              </StackPanel>
            </Grid>
          </Border>

          <Button x:Name="BtnStart" Style="{StaticResource BtnAccent}" Height="62" FontSize="17" Margin="0,4,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="BtnStartIcon" Text="&#xE768;" FontFamily="{StaticResource Icons}" FontSize="17" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock x:Name="BtnStartText" Text="START LOGGING" FontWeight="Bold" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>

          <Border x:Name="LivePanel" Style="{StaticResource CardBox}" Margin="0,18,0,0" Visibility="Collapsed">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Ellipse x:Name="LiveDot" Width="10" Height="10" Fill="#F5B544" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtLiveState" Grid.Column="1" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0"/>
                <TextBlock x:Name="TxtLiveElapsed" Grid.Column="2" FontSize="15" Foreground="{StaticResource Sub}"/>
              </Grid>
              <TextBlock x:Name="TxtLiveSub" Style="{StaticResource Hint}" Margin="20,4,0,0"/>
              <UniformGrid x:Name="LiveTiles" Columns="4" Margin="0,16,0,0"/>
              <Border Background="#11151C" CornerRadius="9" Margin="0,6,0,0" Padding="10">
                <StackPanel>
                  <TextBlock Text="FPS, LAST 2 MINUTES" Style="{StaticResource Caption}"/>
                  <Canvas x:Name="SparkCanvas" Height="80" ClipToBounds="True"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="TxtLiveWarn" Foreground="{StaticResource Warn}" TextWrapping="Wrap" FontSize="12" Margin="0,12,0,0"/>
              <TextBlock Text="RECORDER" Style="{StaticResource Caption}" Margin="0,14,0,4"/>
              <TextBlock x:Name="TxtLiveLog" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{StaticResource Mute}" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- RESULTS -->
      <Grid x:Name="PageResults" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Background="#0C0F14" BorderBrush="#1A1F28" BorderThickness="0,0,1,0">
          <DockPanel Margin="14,26,14,14">
            <Grid DockPanel.Dock="Top" Margin="6,0,0,10">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="Sessions" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <Button x:Name="BtnRefreshSessions" Grid.Column="1" Style="{StaticResource BtnIcon}" Content="&#xE72C;" ToolTip="Reload"/>
            </Grid>
            <ListBox x:Name="LstSessions"/>
          </DockPanel>
        </Border>
        <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="30,26,30,28">
            <TextBlock x:Name="TxtResEmpty" Text="No sessions yet. Record one on the Record page." Style="{StaticResource Hint}" FontSize="14"/>
            <StackPanel x:Name="ResBody" Visibility="Collapsed">
              <TextBlock x:Name="TxtResTitle" Style="{StaticResource H1}" TextWrapping="Wrap"/>
              <TextBlock x:Name="TxtResSub" Style="{StaticResource Hint}" FontSize="13" Margin="0,6,0,0"/>
              <Border Background="#13261F" CornerRadius="10" Padding="16,12" Margin="0,16,0,16" BorderBrush="#24523F" BorderThickness="1">
                <TextBlock x:Name="TxtVerdict" TextWrapping="Wrap" FontSize="14"/>
              </Border>
              <UniformGrid x:Name="KpiGrid" Columns="4"/>
              <Border Style="{StaticResource CardBox}" Margin="0,8,0,16">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Frame time" Style="{StaticResource H2}" Margin="0"/>
                    <StackPanel x:Name="ChartLegend" Grid.Column="1" Orientation="Horizontal"/>
                  </Grid>
                  <Canvas x:Name="ChartCanvas" Height="240" ClipToBounds="True" Margin="0,12,0,0" Background="Transparent"/>
                  <TextBlock x:Name="TxtChartNote" Foreground="{StaticResource Mute}" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <WrapPanel>
                <Button x:Name="BtnAskAi" Style="{StaticResource BtnAccent}" Content="Analyse with AI"/>
                <Button x:Name="BtnCopyBrief" Style="{StaticResource Btn}" Content="Copy AI brief"/>
                <Button x:Name="BtnOpenReport" Style="{StaticResource Btn}" Content="Open report"/>
                <Button x:Name="BtnOpenFolder" Style="{StaticResource Btn}" Content="Open folder"/>
                <Button x:Name="BtnReanalyze" Style="{StaticResource Btn}" Content="Re-analyse"/>
                <Button x:Name="BtnDeleteSession" Style="{StaticResource BtnGhost}" Foreground="#F0616D" Content="Delete"/>
              </WrapPanel>
              <TextBlock x:Name="TxtResAction" Style="{StaticResource Hint}" Margin="0,2,0,0"/>
              <TextBlock Text="Findings" Style="{StaticResource H2}" Margin="0,18,0,10"/>
              <StackPanel x:Name="FindingsPanel"/>
              <TextBlock x:Name="TxtIncidentsHead" Text="Worst stutters" Style="{StaticResource H2}" Margin="0,18,0,10"/>
              <StackPanel x:Name="IncidentsPanel"/>
            </StackPanel>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- AI -->
      <Grid x:Name="PageAi" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition Width="390"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="30,26,18,26">
            <TextBlock Text="AI analyst" Style="{StaticResource H1}"/>
            <Border Background="#11151C" CornerRadius="9" Padding="12,9" Margin="0,12,0,18" BorderBrush="#2A303C" BorderThickness="1">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtAiProvider" VerticalAlignment="Center" TextWrapping="Wrap"/>
                <Button x:Name="BtnAiSettings" Grid.Column="1" Style="{StaticResource BtnGhost}" Content="Change" Margin="8,0,0,0"/>
              </Grid>
            </Border>
            <TextBlock Text="SESSION" Style="{StaticResource Caption}"/>
            <ComboBox x:Name="CmbAiSession"/>
            <TextBlock Text="CONFIG FILES ALREADY IN THE BRIEF" Style="{StaticResource Caption}" Margin="0,18,0,6"/>
            <TextBlock x:Name="TxtAiIncluded" Style="{StaticResource Hint}"/>
            <TextBlock Text="ADD MORE FILES" Style="{StaticResource Caption}" Margin="0,18,0,8"/>
            <StackPanel x:Name="AiExtraPanel"/>
            <WrapPanel>
              <Button x:Name="BtnAiAddFile" Style="{StaticResource Btn}" Content="Add file..."/>
              <Button x:Name="BtnAiFind" Style="{StaticResource Btn}" Content="Find config files"/>
            </WrapPanel>
            <CheckBox x:Name="ChkAiRemember" Content="Remember added files for this game" Margin="0,4,0,0"/>
            <TextBlock Text="OR PASTE SETTINGS / NOTES" Style="{StaticResource Caption}" Margin="0,14,0,6"/>
            <TextBox x:Name="TxtAiPaste" Height="110" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
            <TextBlock Text="ANYTHING TO FOCUS ON? (OPTIONAL)" Style="{StaticResource Caption}" Margin="0,14,0,6"/>
            <TextBox x:Name="TxtAiQuestion" Height="60" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top"/>
            <Button x:Name="BtnAiAnalyze" Style="{StaticResource BtnAccent}" Height="48" FontSize="15" Margin="0,18,0,8" Content="Analyse this session"/>
            <WrapPanel>
              <Button x:Name="BtnAiPreview" Style="{StaticResource Btn}" Content="Preview what is sent"/>
              <Button x:Name="BtnAiCopy" Style="{StaticResource Btn}" Content="Copy brief"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>
        <Grid Grid.Column="1" Margin="0,26,30,26">
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Border Background="#161A22" BorderBrush="#272D39" BorderThickness="1" CornerRadius="12" Padding="8">
            <Grid>
              <RichTextBox x:Name="RtbAnswer" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#E8EAED"
                           VerticalScrollBarVisibility="Auto" IsDocumentEnabled="True" Padding="10"/>
              <Border x:Name="AiBusy" Background="#E6161A22" CornerRadius="10" Visibility="Collapsed">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                  <TextBlock x:Name="AiBusyGlyph" Text="&#xE9D9;" FontFamily="{StaticResource Icons}" FontSize="30" Foreground="#3DDC97" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="TxtAiBusy" Margin="0,12,0,0" HorizontalAlignment="Center" Foreground="{StaticResource Sub}"/>
                </StackPanel>
              </Border>
            </Grid>
          </Border>
          <Grid Grid.Row="1" Margin="0,12,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="TxtFollow" ToolTip="Ask a follow-up question about this session"/>
            <Button x:Name="BtnAiSend" Grid.Column="1" Style="{StaticResource BtnAccent}" Margin="8,0,0,0" Content="Ask"/>
          </Grid>
        </Grid>
      </Grid>

      <!-- SETTINGS -->
      <ScrollViewer x:Name="PageSettings" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="36,30,36,30" MaxWidth="860">
          <TextBlock Text="Settings" Style="{StaticResource H1}" Margin="0,0,0,22"/>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="AI analyst (optional)" Style="{StaticResource H2}"/>
              <TextBlock Text="Without a provider GamePerf still writes ai-prompt.md for you to paste into any AI chat. With one, the AI page sends it and shows the answer. Keys are encrypted for your Windows account and only sent to that provider." Style="{StaticResource Hint}" Margin="0,0,0,14"/>
              <TextBlock Text="PROVIDER" Style="{StaticResource Caption}"/>
              <ComboBox x:Name="CmbProvider"/>
              <StackPanel x:Name="RowModel" Margin="0,14,0,0">
                <TextBlock Text="MODEL" Style="{StaticResource Caption}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtModel"/>
                  <Button x:Name="BtnListModels" Grid.Column="1" Style="{StaticResource Btn}" Content="List models" Margin="8,0,0,0"/>
                </Grid>
                <ComboBox x:Name="CmbModelList" Margin="0,8,0,0" Visibility="Collapsed"/>
              </StackPanel>
              <StackPanel x:Name="RowBaseUrl" Margin="0,14,0,0">
                <TextBlock Text="SERVER URL (OPENAI-COMPATIBLE, ENDING IN /v1)" Style="{StaticResource Caption}"/>
                <TextBox x:Name="TxtBaseUrl"/>
              </StackPanel>
              <StackPanel x:Name="RowKey" Margin="0,14,0,0">
                <TextBlock Text="API KEY" Style="{StaticResource Caption}"/>
                <PasswordBox x:Name="PwdKey"/>
                <Grid Margin="0,6,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="TxtKeyStatus" Style="{StaticResource Hint}" VerticalAlignment="Center"/>
                  <Button x:Name="BtnGetKey" Grid.Column="1" Style="{StaticResource BtnGhost}" Content="Get a key"/>
                </Grid>
              </StackPanel>
              <StackPanel x:Name="RowEffort" Margin="0,14,0,0">
                <TextBlock Text="EFFORT (CLAUDE)" Style="{StaticResource Caption}"/>
                <ComboBox x:Name="CmbEffort" Width="200" HorizontalAlignment="Left"/>
              </StackPanel>
              <WrapPanel Margin="0,16,0,0">
                <Button x:Name="BtnTestAi" Style="{StaticResource Btn}" Content="Test connection"/>
                <TextBlock x:Name="TxtTestAi" Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="4,0,0,8"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="Your goals" Style="{StaticResource H2}"/>
              <TextBlock Text="Sent with every analysis, so the AI optimises for what you want." Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <TextBox x:Name="TxtGoals" Height="110" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top"/>
              <Button x:Name="BtnResetGoals" Style="{StaticResource BtnGhost}" Content="Reset to default" HorizontalAlignment="Left" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="Targets and privacy" Style="{StaticResource H2}"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="20"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="VR TARGET FPS (HEADSET REFRESH)" Style="{StaticResource Caption}"/>
                  <TextBox x:Name="TxtVrFps"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="MONITOR TARGET FPS (0 = REFRESH RATE)" Style="{StaticResource Caption}"/>
                  <TextBox x:Name="TxtMonFps"/>
                </StackPanel>
              </Grid>
              <CheckBox x:Name="ChkRedact" Content="Hide my Windows user name, PC name and anything that looks like a password or token in AI briefs" Margin="0,16,0,10"/>
              <CheckBox x:Name="ChkIncludePrev" Content="Compare with the previous session of the same game"/>
              <CheckBox x:Name="ChkBeep" Content="Play a short sound when the marker key is pressed (off: the recorder is completely silent)"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="Per-frame timing (Intel PresentMon)" Style="{StaticResource H2}"/>
              <TextBlock x:Name="TxtPmPath" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <WrapPanel>
                <Button x:Name="BtnGetPm2" Style="{StaticResource Btn}" Content="Download PresentMon"/>
                <Button x:Name="BtnBrowsePm" Style="{StaticResource Btn}" Content="Choose PresentMon.exe..."/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="Launch and permissions" Style="{StaticResource H2}"/>
              <TextBlock Text="Start GamePerf from its icon, like any app." Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <WrapPanel>
                <Button x:Name="BtnShortcutDesktop" Style="{StaticResource Btn}" Content="Add a desktop icon"/>
                <Button x:Name="BtnShortcutStart" Style="{StaticResource Btn}" Content="Add to the Start menu"/>
              </WrapPanel>
              <TextBlock x:Name="TxtShortcut" Style="{StaticResource Hint}"/>
              <TextBlock Text="PER-FRAME TIMING WITHOUT THE ADMIN PROMPT" Style="{StaticResource Caption}" Margin="0,16,0,6"/>
              <TextBlock x:Name="TxtPerfLog" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <Button x:Name="BtnPerfLog" Style="{StaticResource Btn}" Content="Allow it for my account (one-time)" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="Data folder" Style="{StaticResource H2}"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="TxtDataRoot"/>
                <Button x:Name="BtnBrowseData" Grid.Column="1" Style="{StaticResource Btn}" Content="Browse..." Margin="8,0,0,0"/>
                <Button x:Name="BtnOpenData" Grid.Column="2" Style="{StaticResource Btn}" Content="Open" Margin="8,0,0,0"/>
              </Grid>
            </StackPanel>
          </Border>

          <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnSaveSettings" Style="{StaticResource BtnAccent}" Content="Save settings" Height="42" Padding="22,8"/>
            <TextBlock x:Name="TxtSaved" Foreground="{StaticResource Accent}" VerticalAlignment="Center" Margin="8,0,0,8"/>
          </StackPanel>
          <TextBlock x:Name="TxtAbout" Style="{StaticResource Hint}" Foreground="{StaticResource Mute}" Margin="0,18,0,0"/>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Grid>
</Window>
'@

try {
    $Window = [Windows.Markup.XamlReader]::Parse($Xaml)
} catch {
    [System.Windows.MessageBox]::Show("GamePerf could not build its window.`n`n$($_.Exception.Message)", 'GamePerf') | Out-Null
    return
}
$ui = @{}
foreach ($m in [regex]::Matches($Xaml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    $el = $Window.FindName($n)
    if ($el) { $ui[$n] = $el }
}
$Xaml = $null
if (Test-Path -LiteralPath $IconPath) {
    try { $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($IconPath))) } catch { }
}

# ---- palette for code-built elements -------------------------------
function New-GpBrush([string]$Hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}
$C = @{
    Text = New-GpBrush '#E8EAED'; Sub = New-GpBrush '#9AA3B2'; Mute = New-GpBrush '#687284'; Card = New-GpBrush '#161A22'; Field = New-GpBrush '#11151C'
    Line = New-GpBrush '#272D39'; Grid = New-GpBrush '#202633'; Accent = New-GpBrush '#3DDC97'; Warn = New-GpBrush '#F5B544'; Danger = New-GpBrush '#F0616D'
    Info = New-GpBrush '#5AA9FF'; Purple = New-GpBrush '#B48CFF'; Worst = New-GpBrush '#4C5A72'; Code = New-GpBrush '#0F131A'
}
$SevBrush = @{ high = $C.Danger; medium = $C.Warn; low = $C.Info; info = $C.Mute }
$IconFont = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
$MonoFont = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')

function New-GpText([string]$Text, $Brush = $null, [double]$Size = 13, [string]$Weight = 'Normal', [switch]$Wrap) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.FontWeight = [System.Windows.FontWeights]::$Weight
    if ($Brush) { $t.Foreground = $Brush }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}

function New-GpTile($Parent, [string]$Label) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = $C.Field; $b.CornerRadius = '10'; $b.Padding = '14,11'; $b.Margin = '0,0,10,10'
    $sp = New-Object System.Windows.Controls.StackPanel
    $cap = New-GpText $Label.ToUpperInvariant() $C.Mute 10.5 'SemiBold'
    $val = New-GpText '-' $C.Text 22 'SemiBold'
    $val.Margin = '0,4,0,0'
    $sub = New-GpText '' $C.Sub 11
    [void]$sp.Children.Add($cap); [void]$sp.Children.Add($val); [void]$sp.Children.Add($sub)
    $b.Child = $sp
    [void]$Parent.Children.Add($b)
    return @{ Value = $val; Sub = $sub; Box = $b }
}

$Live = [ordered]@{}
foreach ($k in 'FPS', 'Worst frame', 'GPU load', 'Game thread', 'VRAM', 'GPU temp', 'Markers', 'Logger') { $Live[$k] = New-GpTile $ui.LiveTiles $k }
$Kpi = [ordered]@{}
foreach ($k in 'Average FPS', '1% low', '0.1% low', 'Stutters', 'Over budget', 'GPU-bound', 'CPU-side', 'GPU headroom') { $Kpi[$k] = New-GpTile $ui.KpiGrid $k }

foreach ($pair in @(@('Average', $C.Accent), @('Worst', $C.Worst), @('Budget', $C.Warn), @('Stutter', $C.Danger), @('Marker', $C.Purple))) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = '14,0,0,0'
    $sw = New-Object System.Windows.Shapes.Rectangle
    $sw.Width = 10; $sw.Height = 3; $sw.Fill = $pair[1]; $sw.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($sw)
    $lt = New-GpText $pair[0] $C.Sub 11
    $lt.Margin = '6,0,0,0'
    [void]$sp.Children.Add($lt)
    [void]$ui.ChartLegend.Children.Add($sp)
}

# ================================================================
#  NAVIGATION
# ================================================================
$Pages = @{ Record = $ui.PageRecord; Results = $ui.PageResults; Ai = $ui.PageAi; Settings = $ui.PageSettings }
$NavFor = @{ Record = $ui.NavRecord; Results = $ui.NavResults; Ai = $ui.NavAi; Settings = $ui.NavSettings }
function Show-GpPage([string]$Name) {
    foreach ($k in $Pages.Keys) { $Pages[$k].Visibility = $(if ($k -eq $Name) { 'Visible' } else { 'Collapsed' }) }
    if (-not $NavFor[$Name].IsChecked) { $NavFor[$Name].IsChecked = $true }
    if ($Name -eq 'Ai') { Update-GpAiHeader }
}
$ui.NavRecord.Add_Checked({ Show-GpPage 'Record' })
$ui.NavResults.Add_Checked({ Show-GpPage 'Results' })
$ui.NavAi.Add_Checked({ Show-GpPage 'Ai' })
$ui.NavSettings.Add_Checked({ Show-GpPage 'Settings' })

function Show-GpError([string]$Text) { [void][System.Windows.MessageBox]::Show($Window, $Text, 'GamePerf', 'OK', 'Warning') }
function Ask-Gp([string]$Text) { return ([System.Windows.MessageBox]::Show($Window, $Text, 'GamePerf', 'YesNo', 'Question') -eq 'Yes') }
function Open-GpPath([string]$Path) {
    if (-not $Path) { return }
    try { Start-Process -FilePath $Path -ErrorAction Stop } catch { try { Start-Process notepad.exe -ArgumentList "`"$Path`"" } catch { } }
}

# ================================================================
#  BACKGROUND WORK  (AI calls, downloads, re-analysis)
# ================================================================
# The window must never freeze, so slow work runs in a runspace (or a
# separate process) and one 250 ms timer collects results.
$Jobs = New-Object System.Collections.ArrayList
$JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$JobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$JobTimer.Add_Tick({
    foreach ($j in @($Jobs)) {
        $done = $false; $result = $null
        if ($j.Process) {
            if ($j.Process.HasExited) { $done = $true; $result = $j.Process.ExitCode }
        } elseif ($j.Handle.IsCompleted) {
            $done = $true
            try { $out = $j.PS.EndInvoke($j.Handle); if ($out.Count) { $result = $out[$out.Count - 1] } }
            catch { $result = @{ ok = $false; error = $_.Exception.Message } }
            try { $j.PS.Runspace.Dispose(); $j.PS.Dispose() } catch { }
        }
        if ($done) {
            $Jobs.Remove($j)
            try { & $j.OnDone $result $j.Context } catch { Show-GpError "Something went wrong: $($_.Exception.Message)" }
        }
    }
    if ($Jobs.Count -eq 0) { $JobTimer.Stop() }
})

# OnDone runs later, from the timer, so it cannot see the caller's local
# variables - anything it needs travels in -Context (its second argument).
function Start-GpJob([scriptblock]$Work, [hashtable]$Vars, [scriptblock]$OnDone, $Context = $null) {
    $ps = [PowerShell]::Create()
    $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.Open()
    $boot = "param(`$V)`n. '$((Join-Path $LibDir 'GamePerf-Common.ps1') -replace "'", "''")'`n. '$((Join-Path $LibDir 'GamePerf-Games.ps1') -replace "'", "''")'`n. '$((Join-Path $LibDir 'GamePerf-AI.ps1') -replace "'", "''")'`n"
    [void]$ps.AddScript($boot + $Work.ToString()).AddArgument($Vars)
    [void]$Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Context = $Context })
    $JobTimer.Start()
}

function Add-GpProcessJob([Diagnostics.Process]$Process, [scriptblock]$OnDone, $Context = $null) {
    [void]$Jobs.Add(@{ Process = $Process; OnDone = $OnDone; Context = $Context })
    $JobTimer.Start()
}

# ================================================================
#  RECORD PAGE
# ================================================================
function Update-GpPmStatus {
    $pm = Find-GpPresentMon $Settings
    if ($pm) {
        $ui.TxtPmStatus.Text = "PresentMon ready ($(Split-Path -Leaf $pm))"
        $ui.TxtPmPath.Text = "Using $pm"
        $ui.BtnGetPm.Visibility = 'Collapsed'
    } else {
        $ui.TxtPmStatus.Text = 'PresentMon not found - per-frame timing needs it (free, from Intel).'
        $ui.TxtPmPath.Text = 'Not installed. GamePerf can download Intel''s signed console build into its tools folder, or you can point it at one you already have.'
        $ui.BtnGetPm.Visibility = 'Visible'
    }
}

function Install-GpPresentMonUi {
    if (-not (Ask-Gp "Download Intel PresentMon (free, MIT licence, about 1 MB) from GitHub?`n`nGamePerf only keeps it if it carries a valid Intel signature.")) { return }
    $ui.TxtPmStatus.Text = 'Downloading PresentMon...'
    $ui.TxtPmPath.Text = 'Downloading PresentMon...'
    Start-GpJob -Vars @{} -Work {
        try { @{ ok = $true; path = (Install-GpPresentMon) } } catch { @{ ok = $false; error = $_.Exception.Message } }
    } -OnDone {
        param($r)
        if ($r -and $r.ok) { $Settings.PresentMonPath = [string]$r.path; Export-GpSettings $Settings }
        else { Show-GpError "PresentMon could not be downloaded.`n`n$($r.error)" }
        Update-GpPmStatus
    }
}
$ui.BtnGetPm.Add_Click({ Install-GpPresentMonUi })
$ui.BtnGetPm2.Add_Click({ Install-GpPresentMonUi })
$ui.BtnBrowsePm.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'PresentMon|PresentMon*.exe|Programs|*.exe'
    if ($d.ShowDialog($Window)) { $Settings.PresentMonPath = $d.FileName; Export-GpSettings $Settings; Update-GpPmStatus }
})

function Update-GpGameList {
    $keep = $Settings.Game
    if ($ui.CmbGame.SelectedItem) { $keep = [string]$ui.CmbGame.SelectedItem.Tag }
    $ui.CmbGame.Items.Clear()
    $add = {
        param($text, $tag)
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = $text; $it.Tag = $tag
        [void]$ui.CmbGame.Items.Add($it)
        return $it
    }
    $sel = & $add 'Auto-detect - the game you switch to after pressing Start' 'auto'
    $running = @(Get-GpRunningGames)
    $runExes = @{}
    foreach ($g in $running) {
        $runExes[$g.Exe.ToLowerInvariant()] = $true
        $it = & $add ("{0}   -   running ({1})" -f $g.Name, $g.Exe) $g.Exe
        if ($keep -and ($keep -split '\|') -contains $g.Exe) { $sel = $it }
    }
    foreach ($e in $GpGameCatalog) {
        if (@($e.Exe | Where-Object { $runExes.ContainsKey($_.ToLowerInvariant()) }).Count) { continue }
        $tag = ($e.Exe -join '|')
        $it = & $add $e.Name $tag
        if ($keep -eq $tag) { $sel = $it }
    }
    if ($keep -and $keep -ne 'auto' -and -not ($ui.CmbGame.Items | Where-Object { $_.Tag -eq $keep })) {
        $sel = & $add $keep $keep
    }
    $ui.CmbGame.SelectedItem = $sel
}
$ui.BtnRefreshGames.Add_Click({ Update-GpGameList })

function Update-GpTargetHint {
    $t = ConvertTo-GpDouble $ui.TxtTarget.Text
    if (-not [double]::IsNaN($t) -and $t -gt 0) { $ui.TxtTargetHint.Text = ('= {0} ms per frame' -f (Format-GpNum (1000.0 / $t) 1)) }
    elseif ($ui.RbVr.IsChecked) { $ui.TxtTargetHint.Text = 'set this to your headset refresh rate' }
    else { $ui.TxtTargetHint.Text = '0 = your monitor refresh rate' }
}
function Set-GpModeUi([bool]$Vr) {
    if ($Vr) { $ui.TxtTarget.Text = [string]$Settings.TargetFpsVr } else { $ui.TxtTarget.Text = [string]$Settings.TargetFpsMonitor }
    Update-GpTargetHint
}
$ui.RbVr.Add_Checked({ Set-GpModeUi $true })
$ui.RbMonitor.Add_Checked({ Set-GpModeUi $false })
$ui.TxtTarget.Add_TextChanged({ Update-GpTargetHint })

foreach ($k in $GpMarkerKeys.Keys) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $k; $it.Tag = $k
    [void]$ui.CmbMarker.Items.Add($it)
    if ($k -eq $Settings.MarkerKey) { $ui.CmbMarker.SelectedItem = $it }
}
if (-not $ui.CmbMarker.SelectedItem) { $ui.CmbMarker.SelectedIndex = 0 }

function Read-GpRecordUi {
    $Settings.Game = $(if ($ui.CmbGame.SelectedItem) { [string]$ui.CmbGame.SelectedItem.Tag } else { 'auto' })
    $Settings.Mode = $(if ($ui.RbVr.IsChecked) { 'VR' } else { 'Monitor' })
    $t = ConvertTo-GpDouble $ui.TxtTarget.Text
    if ([double]::IsNaN($t) -or $t -lt 0) { $t = 0 }
    if ($Settings.Mode -eq 'VR') { if ($t -gt 0) { $Settings.TargetFpsVr = $t } } else { $Settings.TargetFpsMonitor = $t }
    $Settings.CaptureFrames = [bool]$ui.ChkFrames.IsChecked
    $Settings.RunElevated = [bool]$ui.ChkAdmin.IsChecked
    $Settings.StopWithGame = [bool]$ui.ChkStopWithGame.IsChecked
    $Settings.MinimizeWhileLogging = [bool]$ui.ChkMinimize.IsChecked
    if ($ui.CmbMarker.SelectedItem) { $Settings.MarkerKey = [string]$ui.CmbMarker.SelectedItem.Tag }
    return $t
}

# ---- live session --------------------------------------------------
$State = @{ Logging = $false; Dir = $null; Started = $null; PendingMinimize = $false; Stopping = $false; SeenStatus = $false; WorkerPid = 0 }
$FpsHist = New-Object System.Collections.Generic.List[double]
$LiveTimer = New-Object System.Windows.Threading.DispatcherTimer
$LiveTimer.Interval = [TimeSpan]::FromSeconds(1)

function Set-GpStartButton([string]$Mode) {
    switch ($Mode) {
        'start' { $ui.BtnStart.Style = $Window.FindResource('BtnAccent'); $ui.BtnStartIcon.Text = [string][char]0xE768; $ui.BtnStartText.Text = 'START LOGGING'; $ui.BtnStart.IsEnabled = $true }
        'stop' { $ui.BtnStart.Style = $Window.FindResource('BtnDanger'); $ui.BtnStartIcon.Text = [string][char]0xE71A; $ui.BtnStartText.Text = 'STOP LOGGING'; $ui.BtnStart.IsEnabled = $true }
        'busy' { $ui.BtnStartText.Text = 'FINISHING...'; $ui.BtnStart.IsEnabled = $false }
    }
}
function Set-GpStatusChip([string]$Text, $Brush) { $ui.TxtStatus.Text = $Text; $ui.StatusDot.Fill = $Brush }

function Start-GpLogging {
    if ($State.Logging) { return }
    $target = Read-GpRecordUi
    Export-GpSettings $Settings
    $label = $ui.TxtLabel.Text.Trim()
    $hint = $label
    if (-not $hint -and $ui.CmbGame.SelectedItem -and $ui.CmbGame.SelectedItem.Tag -ne 'auto') { $hint = ([string]$ui.CmbGame.SelectedItem.Tag -split '\|')[0] -replace '\.exe$', '' }
    try { $dir = New-GpSessionDir -Settings $Settings -Hint $hint } catch { Show-GpError "Could not create the session folder.`n`n$($_.Exception.Message)"; return }

    $pinned = @()
    foreach ($exe in ($Settings.Game -split '\|')) { if ($Settings.GameConfigs.ContainsKey($exe)) { $pinned += @($Settings.GameConfigs[$exe]) } }
    $pm = Find-GpPresentMon $Settings
    $useFrames = $Settings.CaptureFrames -and [bool]$pm
    $req = [ordered]@{
        Game = $Settings.Game; Mode = $Settings.Mode; TargetFps = $target; Label = $label
        NoFrames = -not $useFrames; PresentMon = [string]$pm; MarkerKey = $Settings.MarkerKey; Beep = [bool]$Settings.MarkerBeep
        StopWithGame = $Settings.StopWithGame; ParentPid = $PID; ConfigFiles = @($pinned)
    }
    Write-GpJson -Path (Join-Path $dir 'request.json') -Object $req
    # The recorder never has a window. It needs admin only for per-frame timing,
    # and not even then once the account is in Performance Log Users.
    $elevate = $useFrames -and $Settings.RunElevated -and -not (Test-GpAdmin) -and -not (Test-GpPerfLogUser)
    try {
        [void](Start-GpHidden -Mode '--logger' -Argument $dir -Elevated:$elevate)
    } catch {
        if (-not $elevate -or -not (Ask-Gp "The administrator prompt was cancelled.`n`nLog anyway without per-frame timing? (The 1 Hz system log still works.)")) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        $req.NoFrames = $true
        Write-GpJson -Path (Join-Path $dir 'request.json') -Object $req
        try { [void](Start-GpHidden -Mode '--logger' -Argument $dir) }
        catch { Show-GpError "The recorder could not be started.`n`n$($_.Exception.Message)"; Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; return }
    }
    $State.Logging = $true; $State.Dir = $dir; $State.Started = Get-Date; $State.Stopping = $false; $State.SeenStatus = $false; $State.WorkerPid = 0
    $State.PendingMinimize = $Settings.MinimizeWhileLogging
    $FpsHist.Clear()
    foreach ($t in $Live.Values) { $t.Value.Text = '-'; $t.Sub.Text = '' }
    $ui.LivePanel.Visibility = 'Visible'
    $ui.TxtLiveState.Text = 'Starting the logger...'
    $ui.TxtLiveSub.Text = $dir
    $ui.TxtLiveWarn.Text = ''
    $ui.TxtLiveLog.Text = ''
    $ui.LiveDot.Fill = $C.Warn
    Set-GpStartButton 'stop'
    Set-GpStatusChip 'Starting...' $C.Warn
    $LiveTimer.Start()
}

function Stop-GpLogging {
    if (-not $State.Logging -or $State.Stopping) { return }
    $State.Stopping = $true
    try { New-Item -ItemType File -Force -Path (Join-Path $State.Dir 'stop.flag') | Out-Null } catch { }
    Set-GpStartButton 'busy'
    $ui.TxtLiveState.Text = 'Stopping and analysing...'
}

function Complete-GpLogging([string]$Note = '') {
    $LiveTimer.Stop()
    $dir = $State.Dir
    $State.Logging = $false; $State.Stopping = $false
    Set-GpStartButton 'start'
    Set-GpStatusChip 'Idle' $C.Mute
    $ui.LiveDot.Fill = $C.Mute
    if ($Note) { $ui.TxtLiveState.Text = $Note } else { $ui.TxtLiveState.Text = 'Session saved.' }
    if (Test-Path -LiteralPath (Join-Path $dir 'summary.json')) {
        Update-GpSessionList $dir
        Show-GpPage 'Results'
    }
    # Never jump in front of a game or the desktop: while minimised, the
    # taskbar button flashes and the results wait until you open the window.
    if ($Window.WindowState -eq 'Minimized') {
        Set-GpStatusChip 'Session ready' $C.Accent
        if ($NativeOk) { [GamePerf.Native.Win]::FlashTaskbar((New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle) }
    }
}

function Draw-GpSpark {
    $cv = $ui.SparkCanvas
    $cv.Children.Clear()
    $w = $cv.ActualWidth; $h = $cv.ActualHeight
    if ($w -lt 20 -or $FpsHist.Count -lt 2) { return }
    $target = ConvertTo-GpDouble $ui.TxtTarget.Text
    $max = 0.0
    foreach ($v in $FpsHist) { if ($v -gt $max) { $max = $v } }
    if (-not [double]::IsNaN($target) -and $target -gt $max) { $max = $target }
    $max = [Math]::Max(30, $max * 1.1)
    if (-not [double]::IsNaN($target) -and $target -gt 0) {
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = 0; $ln.X2 = $w; $ln.Y1 = $h - $target / $max * $h; $ln.Y2 = $ln.Y1
        $ln.Stroke = $C.Warn; $ln.StrokeThickness = 1; $ln.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('4 3')
        [void]$cv.Children.Add($ln)
    }
    $pl = New-Object System.Windows.Shapes.Polyline
    $pl.Stroke = $C.Accent; $pl.StrokeThickness = 1.6
    $pts = New-Object System.Windows.Media.PointCollection
    $n = $FpsHist.Count
    for ($i = 0; $i -lt $n; $i++) {
        $x = $w - ($n - 1 - $i) * ($w / 119.0)
        [void]$pts.Add((New-Object System.Windows.Point($x, ($h - [Math]::Min($FpsHist[$i], $max) / $max * $h))))
    }
    $pl.Points = $pts
    [void]$cv.Children.Add($pl)
}

$LiveTimer.Add_Tick({
    try {
        if (-not $State.Logging) { $LiveTimer.Stop(); return }
        $st = Read-GpJson (Join-Path $State.Dir 'status.json')
        if (-not $st) {
            # A missed read is normal now and then (antivirus, OneDrive). Only a
            # recorder that never reported at all counts as "did not start".
            if (-not $State.SeenStatus -and ((Get-Date) - $State.Started).TotalSeconds -gt 45) { Complete-GpLogging 'The recorder did not start. Was the administrator prompt cancelled?' }
            return
        }
        $State.SeenStatus = $true
        if ($st.pid) { $State.WorkerPid = [int]$st.pid }
        if ($State.PendingMinimize -and $st.state -in @('waiting', 'logging')) {
            $State.PendingMinimize = $false
            $Window.WindowState = 'Minimized'
        }
        $hb = $null
        try { $hb = [DateTime]::Parse([string]$st.heartbeat, $GpInv) } catch { }
        $stale = $hb -and ((Get-Date) - $hb).TotalSeconds -gt 15
        if ($st.state -eq 'done') { Complete-GpLogging; return }
        if ($stale) {
            # Analysis cannot heartbeat, so judge by whether the recorder process still exists.
            $alive = $true
            if ($State.WorkerPid -gt 0) { $alive = [bool](Get-Process -Id $State.WorkerPid -ErrorAction SilentlyContinue) }
            if (-not $alive) { Complete-GpLogging 'The recorder stopped unexpectedly. Whatever it recorded is in the session folder - Re-analyse it from Results.'; return }
            if ($st.state -ne 'analyzing' -and ((Get-Date) - $hb).TotalSeconds -gt 60) {
                # Give up on it - but tell it to stop, so it never keeps recording unattended.
                try { New-Item -ItemType File -Force -Path (Join-Path $State.Dir 'stop.flag') | Out-Null } catch { }
                Complete-GpLogging 'The recorder stopped responding and was asked to stop. Whatever it recorded is in the session folder.'
                return
            }
            if ($st.state -ne 'analyzing') { $ui.TxtLiveWarn.Text = 'The recorder has not reported for a while...' }
        }
        switch ([string]$st.state) {
            'waiting' {
                $ui.TxtLiveState.Text = "Waiting for $($st.waiting_for)"
                $ui.TxtLiveSub.Text = 'Switch to the game - logging locks on as soon as it is running. System data is already being recorded.'
                $ui.LiveDot.Fill = $C.Warn; Set-GpStatusChip 'Waiting for game' $C.Warn
            }
            'logging' {
                $ui.TxtLiveState.Text = "Logging $($st.game)"
                $pmText = switch ([string]$st.presentmon) { 'running' { 'per-frame timing on' } 'failed' { 'per-frame timing FAILED' } default { 'per-frame timing off' } }
                $ui.TxtLiveSub.Text = "$($st.game_exe) - $pmText - press $($Settings.MarkerKey) when you feel a hitch"
                $ui.LiveDot.Fill = $C.Danger; Set-GpStatusChip 'Logging' $C.Danger
            }
            'stopping' { $ui.TxtLiveState.Text = 'Stopping...' }
            'analyzing' { $ui.TxtLiveState.Text = 'Analysing the session...'; Set-GpStatusChip 'Analysing' $C.Info }
        }
        $el = ConvertTo-GpDouble $st.elapsed_s
        if (-not [double]::IsNaN($el)) { $ui.TxtLiveElapsed.Text = Format-GpDuration $el }
        $fps = ConvertTo-GpDouble $st.fps
        if (-not [double]::IsNaN($fps)) {
            $FpsHist.Add($fps)
            if ($FpsHist.Count -gt 120) { $FpsHist.RemoveAt(0) }
            $Live['FPS'].Value.Text = Format-GpNum $fps 0
        }
        $budget = ConvertTo-GpDouble $st.budget_ms
        $ftm = ConvertTo-GpDouble $st.ft_max
        if (-not [double]::IsNaN($ftm)) {
            $Live['Worst frame'].Value.Text = (Format-GpNum $ftm 1) + ' ms'
            $Live['Worst frame'].Value.Foreground = $(if ($budget -gt 0 -and $ftm -gt $budget * 1.25) { $C.Warn } else { $C.Text })
            $Live['Worst frame'].Sub.Text = 'this second'
        }
        $gu = ConvertTo-GpDouble $st.gpu_util
        if (-not [double]::IsNaN($gu)) { $Live['GPU load'].Value.Text = (Format-GpNum $gu 0) + '%' }
        $gb = ConvertTo-GpDouble $st.gpu_busy
        if (-not [double]::IsNaN($gb)) { $Live['GPU load'].Sub.Text = "busy $(Format-GpNum $gb 1) ms/frame" }
        $th = ConvertTo-GpDouble $st.game_thread
        if (-not [double]::IsNaN($th)) { $Live['Game thread'].Value.Text = (Format-GpNum $th 0) + '%'; $Live['Game thread'].Sub.Text = 'busiest thread, % of a core' }
        $vu = ConvertTo-GpDouble $st.vram_used; $vt = ConvertTo-GpDouble $st.vram_total
        if (-not [double]::IsNaN($vu)) {
            $Live['VRAM'].Value.Text = (Format-GpNum ($vu / 1024) 1) + ' GB'
            if (-not [double]::IsNaN($vt)) { $Live['VRAM'].Sub.Text = "of $(Format-GpNum ($vt / 1024) 0) GB" }
        }
        $gt = ConvertTo-GpDouble $st.gpu_temp
        if (-not [double]::IsNaN($gt)) {
            $Live['GPU temp'].Value.Text = (Format-GpNum $gt 0) + ' C'
            $gp = ConvertTo-GpDouble $st.gpu_power
            if (-not [double]::IsNaN($gp)) { $Live['GPU temp'].Sub.Text = "$(Format-GpNum $gp 0) W" }
        }
        $Live['Markers'].Value.Text = [string]$st.markers
        $Live['Markers'].Sub.Text = "key: $($Settings.MarkerKey)"
        $lm = ConvertTo-GpDouble $st.loop_ms
        if (-not [double]::IsNaN($lm)) { $Live['Logger'].Value.Text = (Format-GpNum $lm 0) + ' ms'; $Live['Logger'].Sub.Text = 'per 1 s sample' }
        $w = @($st.warnings) | Where-Object { $_ }
        $ui.TxtLiveWarn.Text = (@($w) -join "`n")
        $logText = Read-GpTextFile -Path (Join-Path $State.Dir 'logger.log')
        if ($logText) { $ui.TxtLiveLog.Text = (@($logText -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 4) -join "`n") }
        Draw-GpSpark
    } catch { }
})

$ui.BtnStart.Add_Click({ if ($State.Logging) { Stop-GpLogging } else { Start-GpLogging } })

# ================================================================
#  RESULTS PAGE
# ================================================================
$Current = @{ Dir = $null; Summary = $null; Meta = $null }

function Get-GpSessionDate([string]$Name) {
    try { return [DateTime]::ParseExact($Name.Substring(0, 15), 'yyyyMMdd-HHmmss', $GpInv).ToString('ddd d MMM, HH:mm', $GpInv) } catch { return $Name }
}

function New-GpChip([string]$Text, $Brush) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = $C.Field; $b.CornerRadius = '6'; $b.Padding = '7,2'; $b.Margin = '0,6,6,0'
    $t = New-GpText $Text $Brush 11
    $b.Child = $t
    return $b
}

function Update-GpSessionList([string]$Select = $null) {
    $ui.LstSessions.Items.Clear()
    $list = @(Get-GpSessions $Settings)
    $selItem = $null
    foreach ($s in $list) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Tag = $s.Dir
        $sp = New-Object System.Windows.Controls.StackPanel
        $title = $s.Game
        if (-not $title) { $title = '(no game detected)' }
        [void]$sp.Children.Add((New-GpText $title $C.Text 14 'SemiBold'))
        [void]$sp.Children.Add((New-GpText ("{0}  -  {1}  -  {2}" -f (Get-GpSessionDate $s.Name), $s.Mode, (Format-GpDuration $s.Duration)) $C.Sub 11.5))
        if ($s.Label) { $lt = New-GpText $s.Label $C.Mute 11.5; $lt.FontStyle = 'Italic'; $lt.TextTrimming = 'CharacterEllipsis'; [void]$sp.Children.Add($lt) }
        $chips = New-Object System.Windows.Controls.WrapPanel
        if ($s.Summary -and $s.Summary.frames -and $s.Summary.frames.captured) {
            $f = $s.Summary.frames
            [void]$chips.Children.Add((New-GpChip ("{0} fps" -f (Format-GpNum $f.fps_avg 0)) $C.Accent))
            [void]$chips.Children.Add((New-GpChip ("1% {0}" -f (Format-GpNum $f.low1_fps 0)) $C.Sub))
            $stBrush = $C.Sub
            if ((ConvertTo-GpDouble $f.stutters_per_min) -ge 1) { $stBrush = $C.Warn }
            [void]$chips.Children.Add((New-GpChip ("{0} stutters" -f $f.stutters) $stBrush))
        } elseif (-not $s.Summary) {
            [void]$chips.Children.Add((New-GpChip 'not analysed' $C.Warn))
        }
        [void]$sp.Children.Add($chips)
        $item.Content = $sp
        [void]$ui.LstSessions.Items.Add($item)
        if ($Select -and $s.Dir -eq $Select) { $selItem = $item }
    }
    if (-not $selItem -and $ui.LstSessions.Items.Count) { $selItem = $ui.LstSessions.Items[0] }
    if ($selItem) { $ui.LstSessions.SelectedItem = $selItem } else { Show-GpSession $null }
    Update-GpAiSessions
}

function Set-GpKpi([string]$Key, $Value, [string]$Sub = '', $Brush = $null) {
    $Kpi[$Key].Value.Text = $Value
    $Kpi[$Key].Sub.Text = $Sub
    if ($Brush) { $Kpi[$Key].Value.Foreground = $Brush } else { $Kpi[$Key].Value.Foreground = $C.Text }
}

function Show-GpSession([string]$Dir) {
    $Current.Dir = $Dir
    $ui.FindingsPanel.Children.Clear(); $ui.IncidentsPanel.Children.Clear(); $ui.ChartCanvas.Children.Clear()
    $ui.TxtResAction.Text = ''
    if (-not $Dir) { $ui.ResBody.Visibility = 'Collapsed'; $ui.TxtResEmpty.Visibility = 'Visible'; return }
    $ui.ResBody.Visibility = 'Visible'; $ui.TxtResEmpty.Visibility = 'Collapsed'
    $meta = Read-GpJson (Join-Path $Dir 'session.json')
    $sum = Read-GpJson (Join-Path $Dir 'summary.json')
    $Current.Meta = $meta; $Current.Summary = $sum
    $game = [string]$meta.game_name
    if (-not $game) { $game = '(no game detected)' }
    $ui.TxtResTitle.Text = $game
    $tgt = '-'
    if ((ConvertTo-GpDouble $meta.target_fps) -gt 0) { $tgt = "$(Format-GpNum $meta.target_fps 0) fps" }
    $sub = "{0}  -  {1}  -  target {2}  -  {3}" -f (Get-GpSessionDate (Split-Path -Leaf $Dir)), $meta.mode, $tgt, (Format-GpDuration $meta.duration_s)
    if ($meta.label) { $sub += "  -  `"$($meta.label)`"" }
    $ui.TxtResSub.Text = $sub
    if (-not $sum) {
        $ui.TxtVerdict.Text = 'This session has not been analysed yet (or the analysis failed). Press Re-analyse.'
        foreach ($k in @($Kpi.Keys)) { Set-GpKpi $k '-' }
        return
    }
    $ui.TxtVerdict.Text = [string]$sum.verdict
    $f = $sum.frames
    $budget = ConvertTo-GpDouble $sum.budget_ms
    if ($f.captured) {
        $tf = ConvertTo-GpDouble $sum.target_fps
        Set-GpKpi 'Average FPS' (Format-GpNum $f.fps_avg 1) $(if ($tf -gt 0) { "target $(Format-GpNum $tf 0)" } else { '' })
        $lowBrush = $null
        if ($tf -gt 0 -and (ConvertTo-GpDouble $f.low1_fps) -lt $tf * 0.9) { $lowBrush = $C.Warn }
        Set-GpKpi '1% low' (Format-GpNum $f.low1_fps 1) ("p99 {0} ms" -f (Format-GpNum $f.ft_p99 1)) $lowBrush
        Set-GpKpi '0.1% low' (Format-GpNum $f.low01_fps 1) ("p99.9 {0} ms" -f (Format-GpNum $f.ft_p999 1))
        $spm = ConvertTo-GpDouble $f.stutters_per_min
        Set-GpKpi 'Stutters' ([string]$f.stutters) ("{0} / min, {1} major" -f (Format-GpNum $spm 1), $f.major_stutters) $(if ($spm -ge 6) { $C.Danger } elseif ($spm -ge 1) { $C.Warn } else { $C.Accent })
        $mp = ConvertTo-GpDouble $f.missed_pct
        if ([double]::IsNaN($mp)) { Set-GpKpi 'Over budget' '-' 'no target set' }
        else { Set-GpKpi 'Over budget' ((Format-GpNum $mp 1) + '%') ("{0} frames" -f $f.missed) $(if ($mp -ge 5) { $C.Danger } elseif ($mp -ge 1) { $C.Warn } else { $C.Accent }) }
        Set-GpKpi 'GPU-bound' ((Format-GpNum $f.gpu_bound_pct 0) + '%') ("GPU busy p90 {0} ms" -f (Format-GpNum $f.gpu_busy_p90 1))
        Set-GpKpi 'CPU-side' ((Format-GpNum $f.cpu_bound_pct 0) + '%') ("CPU busy p90 {0} ms" -f (Format-GpNum $f.cpu_busy_p90 1))
        $hr = ConvertTo-GpDouble $f.gpu_headroom_pct
        Set-GpKpi 'GPU headroom' $(if ([double]::IsNaN($hr)) { '-' } else { (Format-GpNum $hr 0) + '%' }) 'vs frame budget' $(if ($hr -lt 5) { $C.Warn } elseif ($hr -ge 25) { $C.Accent } else { $null })
    } else {
        foreach ($k in @($Kpi.Keys)) { Set-GpKpi $k '-' }
        $ab = $sum.system.ab_fps
        if ($ab) { Set-GpKpi 'Average FPS' (Format-GpNum $ab.avg 1) 'Afterburner, 1 Hz' }
    }
    Draw-GpChart

    foreach ($fd in @($sum.findings)) {
        if (-not $fd) { continue }
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '0,0,0,8'
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '4'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $bar = New-Object System.Windows.Controls.Border
        $bar.Background = $SevBrush[[string]$fd.severity]; $bar.CornerRadius = '4,0,0,4'
        $box = New-Object System.Windows.Controls.Border
        $box.Background = $C.Card; $box.CornerRadius = '0,10,10,0'; $box.Padding = '14,11'
        [System.Windows.Controls.Grid]::SetColumn($box, 1)
        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.WrapPanel
        $sev = New-GpText ([string]$fd.severity).ToUpperInvariant() $SevBrush[[string]$fd.severity] 10.5 'Bold'
        $sev.Margin = '0,2,10,0'
        [void]$head.Children.Add($sev)
        [void]$head.Children.Add((New-GpText ([string]$fd.title) $C.Text 13.5 'SemiBold' -Wrap))
        [void]$sp.Children.Add($head)
        $dt = New-GpText ([string]$fd.detail) $C.Sub 12.5 -Wrap
        $dt.Margin = '0,5,0,0'
        [void]$sp.Children.Add($dt)
        $box.Child = $sp
        [void]$g.Children.Add($bar); [void]$g.Children.Add($box)
        [void]$ui.FindingsPanel.Children.Add($g)
    }

    $inc = @($sum.incidents | Where-Object { $_ })
    $ui.TxtIncidentsHead.Visibility = $(if ($inc.Count) { 'Visible' } else { 'Collapsed' })
    $kindText = @{ gpu = 'GPU spike'; cpu = 'game-thread spike'; stall = 'stall'; unknown = 'stutter' }
    foreach ($i in ($inc | Select-Object -First 10)) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = $C.Card; $b.CornerRadius = '10'; $b.Padding = '14,10'; $b.Margin = '0,0,0,6'
        $sp = New-Object System.Windows.Controls.StackPanel
        $times = ''
        if ($i.frames -gt 1) { $times = " x$($i.frames)" }
        $line1 = "{0}   {1} ms{2}   (typical {3} ms)   {4}" -f $i.clock, (Format-GpNum $i.worst_ms 1), $times, (Format-GpNum $i.typical_ms 1), $kindText[[string]$i.kind]
        [void]$sp.Children.Add((New-GpText $line1 $C.Text 12.5 'SemiBold'))
        $ctx = @($i.context)
        if ($i.background) { $ctx += "background CPU: $($i.background)" }
        $ct = $(if ($ctx.Count) { $ctx -join '  -  ' } else { 'Nothing unusual in the 1 Hz system log around it.' })
        $t2 = New-GpText $ct $C.Sub 12 -Wrap
        $t2.Margin = '0,4,0,0'
        [void]$sp.Children.Add($t2)
        $b.Child = $sp
        [void]$ui.IncidentsPanel.Children.Add($b)
    }
}

function Draw-GpChart {
    $cv = $ui.ChartCanvas
    $cv.Children.Clear()
    $sum = $Current.Summary
    $w = $cv.ActualWidth; $h = $cv.ActualHeight
    if (-not $sum -or $w -lt 100) { return }
    $ch = $sum.chart
    $t = @($ch.t); $avg = @($ch.ft_avg); $mx = @($ch.ft_max)
    if ($t.Count -lt 2) {
        $nt = New-GpText 'No frame data to chart for this session.' $C.Mute 12
        [System.Windows.Controls.Canvas]::SetLeft($nt, 8); [System.Windows.Controls.Canvas]::SetTop($nt, 8)
        [void]$cv.Children.Add($nt)
        $ui.TxtChartNote.Text = ''
        return
    }
    $budget = ConvertTo-GpDouble $ch.budget
    $vals = New-Object System.Collections.Generic.List[double]
    foreach ($v in $mx) { $d = ConvertTo-GpDouble $v; if (-not [double]::IsNaN($d)) { $vals.Add($d) } }
    $vals.Sort()
    $p98 = 20.0
    if ($vals.Count) { $p98 = $vals[[Math]::Min($vals.Count - 1, [int]($vals.Count * 0.98))] }
    $ymax = [Math]::Max($p98 * 1.25, 8)
    if ($budget -gt 0) { $ymax = [Math]::Max($ymax, $budget * 2.2) }
    $ymax = [Math]::Min($ymax, 250)
    $pl = 44.0; $pb = 20.0; $pr = 8.0; $ptop = 6.0
    $t0 = [double]$t[0]; $t1 = [double]$t[$t.Count - 1]
    if ($t1 -le $t0) { $t1 = $t0 + 1 }
    $sx = ($w - $pl - $pr) / ($t1 - $t0)
    $sy = ($h - $pb - $ptop) / $ymax

    # grid + labels
    $step = 5.0
    foreach ($s in @(2.0, 5.0, 10.0, 20.0, 25.0, 50.0)) { if ($ymax / $s -le 6) { $step = $s; break } }
    for ($y = 0.0; $y -le $ymax + 0.01; $y += $step) {
        $yy = $h - $pb - $y * $sy
        $gl = New-Object System.Windows.Shapes.Line
        $gl.X1 = $pl; $gl.X2 = $w - $pr; $gl.Y1 = $yy; $gl.Y2 = $yy; $gl.Stroke = $C.Grid; $gl.StrokeThickness = 1
        [void]$cv.Children.Add($gl)
        $lb = New-GpText ("{0} ms" -f $y) $C.Mute 10
        [System.Windows.Controls.Canvas]::SetLeft($lb, 0); [System.Windows.Controls.Canvas]::SetTop($lb, $yy - 7)
        [void]$cv.Children.Add($lb)
    }
    foreach ($frac in @(0.0, 0.25, 0.5, 0.75, 1.0)) {
        $tv = $t0 + ($t1 - $t0) * $frac
        $lb = New-GpText (Format-GpDuration $tv) $C.Mute 10
        $x = $pl + ($tv - $t0) * $sx - 14
        if ($frac -eq 1.0) { $x -= 14 }
        [System.Windows.Controls.Canvas]::SetLeft($lb, [Math]::Max($pl, $x)); [System.Windows.Controls.Canvas]::SetTop($lb, $h - $pb + 4)
        [void]$cv.Children.Add($lb)
    }
    # markers (behind the lines)
    foreach ($m in @($ch.markers)) {
        $mv = ConvertTo-GpDouble $m
        if ([double]::IsNaN($mv) -or $mv -lt $t0 -or $mv -gt $t1) { continue }
        $x = $pl + ($mv - $t0) * $sx
        $ml = New-Object System.Windows.Shapes.Line
        $ml.X1 = $x; $ml.X2 = $x; $ml.Y1 = $ptop; $ml.Y2 = $h - $pb; $ml.Stroke = $C.Purple; $ml.StrokeThickness = 1.5; $ml.Opacity = 0.8
        $ml.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('3 3')
        [void]$cv.Children.Add($ml)
    }
    # series
    foreach ($series in @(@{ v = $mx; b = $C.Worst; th = 1.0 }, @{ v = $avg; b = $C.Accent; th = 1.6 })) {
        $poly = $null
        for ($i = 0; $i -lt $t.Count; $i++) {
            $v = ConvertTo-GpDouble $series.v[$i]
            if ([double]::IsNaN($v)) { $poly = $null; continue }
            if (-not $poly) {
                $poly = New-Object System.Windows.Shapes.Polyline
                $poly.Stroke = $series.b; $poly.StrokeThickness = $series.th; $poly.StrokeLineJoin = 'Round'
                $poly.Points = New-Object System.Windows.Media.PointCollection
                [void]$cv.Children.Add($poly)
            }
            [void]$poly.Points.Add((New-Object System.Windows.Point(($pl + ([double]$t[$i] - $t0) * $sx), ($h - $pb - [Math]::Min($v, $ymax) * $sy))))
        }
    }
    if ($budget -gt 0 -and $budget -lt $ymax) {
        $bl = New-Object System.Windows.Shapes.Line
        $bl.X1 = $pl; $bl.X2 = $w - $pr; $bl.Y1 = $h - $pb - $budget * $sy; $bl.Y2 = $bl.Y1
        $bl.Stroke = $C.Warn; $bl.StrokeThickness = 1.2; $bl.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('5 4')
        [void]$cv.Children.Add($bl)
    }
    foreach ($s in @($ch.stutters)) {
        $sv = ConvertTo-GpDouble $s
        if ([double]::IsNaN($sv) -or $sv -lt $t0 -or $sv -gt $t1) { continue }
        $x = $pl + ($sv - $t0) * $sx
        $sl = New-Object System.Windows.Shapes.Line
        $sl.X1 = $x; $sl.X2 = $x; $sl.Y1 = $ptop; $sl.Y2 = $ptop + 9; $sl.Stroke = $C.Danger; $sl.StrokeThickness = 2
        [void]$cv.Children.Add($sl)
    }
    $note = "Each point is a $([int]$ch.width)-second window: green = average frame time, grey = the worst frame in it. Lower is better."
    if ($ch.source -ne 'presentmon') { $note = 'From Afterburner''s 1 Hz average - single slow frames are not visible. Enable per-frame timing for a real frame-time chart.' }
    $hidden = @($mx | Where-Object { (ConvertTo-GpDouble $_) -gt $ymax }).Count
    if ($hidden) { $note += " $hidden point(s) above $([int]$ymax) ms are clipped." }
    $ui.TxtChartNote.Text = $note
}
$ui.ChartCanvas.Add_SizeChanged({ Draw-GpChart })

$ui.LstSessions.Add_SelectionChanged({ if ($ui.LstSessions.SelectedItem) { Show-GpSession ([string]$ui.LstSessions.SelectedItem.Tag) } })
$ui.BtnRefreshSessions.Add_Click({ Update-GpSessionList $Current.Dir })
$ui.BtnOpenFolder.Add_Click({ if ($Current.Dir) { Start-Process explorer.exe -ArgumentList "`"$($Current.Dir)`"" } })
$ui.BtnOpenReport.Add_Click({ if ($Current.Dir) { Open-GpPath (Join-Path $Current.Dir 'report.md') } })
$ui.BtnCopyBrief.Add_Click({
    if (-not $Current.Dir) { return }
    $t = Read-GpTextFile -Path (Join-Path $Current.Dir 'ai-prompt.md')
    if (-not $t) { Show-GpError 'This session has no AI brief yet. Press Re-analyse.'; return }
    [System.Windows.Clipboard]::SetText($t)
    $ui.TxtResAction.Text = ("Copied {0} KB. Paste it into Grok, ChatGPT, Claude or Gemini - the config files are already inside." -f [int]($t.Length / 1024))
})
$ui.BtnAskAi.Add_Click({ if ($Current.Dir) { Select-GpAiSession $Current.Dir; Show-GpPage 'Ai' } })
$ui.BtnReanalyze.Add_Click({
    if (-not $Current.Dir) { return }
    $dir = $Current.Dir
    $ui.TxtResAction.Text = 'Analysing...'
    $ui.BtnReanalyze.IsEnabled = $false
    Start-GpJob -Vars @{ Analyze = $AnalyzePath; Dir = $dir } -Context $dir -Work {
        try { & $V.Analyze -SessionDir $V.Dir -Quiet | Out-Null; @{ ok = $true } } catch { @{ ok = $false; error = $_.Exception.Message } }
    } -OnDone {
        param($r, $sessionDir)
        $ui.BtnReanalyze.IsEnabled = $true
        $ui.TxtResAction.Text = $(if ($r -and $r.ok) { 'Analysis updated.' } else { "The analysis failed: $($r.error)" })
        Update-GpSessionList $sessionDir
    }
})
$ui.BtnDeleteSession.Add_Click({
    if (-not $Current.Dir) { return }
    if ($State.Logging -and $State.Dir -eq $Current.Dir) { Show-GpError 'That session is still recording.'; return }
    if (-not (Ask-Gp "Delete this session and all its files?`n`n$($Current.Dir)")) { return }
    try { Remove-Item -LiteralPath $Current.Dir -Recurse -Force -ErrorAction Stop } catch { Show-GpError "Could not delete it: $($_.Exception.Message)" }
    Update-GpSessionList
})

# ================================================================
#  AI PAGE
# ================================================================
$Ai = @{ Dir = $null; Meta = $null; Messages = (New-Object System.Collections.ArrayList); Config = $null; Stamp = $null; Busy = $false; Transcript = $null }

function Update-GpAiHeader {
    $cfg = Get-GpAiConfig $Settings
    $why = Test-GpAiReady $cfg
    if ($cfg.Style -eq 'none') {
        $ui.TxtAiProvider.Text = 'No AI connected. Your brief is still ready: use "Copy brief" and paste it into any AI chat.'
        $ui.BtnAiAnalyze.Content = 'Copy brief to clipboard'
    } elseif ($why) {
        $ui.TxtAiProvider.Text = "$($cfg.Name): $why"
        $ui.BtnAiAnalyze.Content = 'Analyse this session'
    } else {
        $ui.TxtAiProvider.Text = "$($cfg.Name)  -  $($cfg.Model)"
        $ui.BtnAiAnalyze.Content = 'Analyse this session'
    }
    $ui.TxtFollow.IsEnabled = ($cfg.Style -ne 'none')
    $ui.BtnAiSend.IsEnabled = ($cfg.Style -ne 'none')
}
$ui.BtnAiSettings.Add_Click({ Show-GpPage 'Settings' })

function Update-GpAiSessions {
    $keep = $Ai.Dir
    $ui.CmbAiSession.Items.Clear()
    $sel = $null
    foreach ($s in @(Get-GpSessions $Settings)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $txt = "{0}  -  {1}" -f $(if ($s.Game) { $s.Game } else { '(no game)' }), (Get-GpSessionDate $s.Name)
        if ($s.Label) { $txt += "  -  $($s.Label)" }
        $it.Content = $txt; $it.Tag = $s.Dir
        [void]$ui.CmbAiSession.Items.Add($it)
        if ($keep -and $s.Dir -eq $keep) { $sel = $it }
    }
    if (-not $sel -and $ui.CmbAiSession.Items.Count) { $sel = $ui.CmbAiSession.Items[0] }
    if ($sel) { $ui.CmbAiSession.SelectedItem = $sel }
}

function Select-GpAiSession([string]$Dir) {
    foreach ($it in $ui.CmbAiSession.Items) { if ($it.Tag -eq $Dir) { $ui.CmbAiSession.SelectedItem = $it; return } }
}

function Add-GpAiExtra([string]$Path, [bool]$Checked, [string]$Why) {
    foreach ($cb in $ui.AiExtraPanel.Children) { if ($cb.Tag -eq $Path) { return } }
    $cb = New-Object System.Windows.Controls.CheckBox
    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-GpText (Split-Path -Leaf $Path) $C.Text 12.5))
    $sub = New-GpText ("{0}  ({1})" -f (Split-Path -Parent $Path), $Why) $C.Mute 11
    $sub.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($sub)
    $cb.Content = $sp; $cb.Tag = $Path; $cb.IsChecked = $Checked; $cb.ToolTip = $Path
    [void]$ui.AiExtraPanel.Children.Add($cb)
}

function Show-GpAiConversation([string]$Status = '') {
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily = $Window.FontFamily; $doc.FontSize = 13.5; $doc.Foreground = $C.Text; $doc.PagePadding = '6'
    if ($Ai.Messages.Count -eq 0) {
        $saved = $null
        if ($Ai.Dir) { $saved = Get-ChildItem -LiteralPath $Ai.Dir -Filter 'ai-analysis-*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
        if ($saved) {
            $p = New-Object System.Windows.Documents.Paragraph (New-Object System.Windows.Documents.Run ("Saved analysis: $($saved.Name)"))
            $p.Foreground = $C.Mute; $p.FontSize = 11.5
            [void]$doc.Blocks.Add($p)
            Add-GpMarkdown $doc (Read-GpTextFile -Path $saved.FullName)
        } else {
            Add-GpMarkdown $doc "## Ready when you are`n`nPick a session, add any config files GamePerf did not find, and press **Analyse this session**. The AI gets the report, a 10-second timeline, your goals and the config files.`n`nNo AI connected? **Copy brief** puts the same thing on your clipboard to paste into Grok, ChatGPT, Claude or Gemini."
        }
    }
    for ($i = 0; $i -lt $Ai.Messages.Count; $i++) {
        $m = $Ai.Messages[$i]
        if ($m.role -eq 'user') {
            $txt = [string]$m.content
            if ($i -eq 0) { $txt = "Sent the session brief ({0} KB) to {1} ({2})." -f [int]($txt.Length / 1024), $Ai.Config.Name, $Ai.Config.Model }
            $p = New-Object System.Windows.Documents.Paragraph
            $p.Background = $C.Field; $p.Padding = '12,8'; $p.Margin = '0,10,0,10'; $p.Foreground = $C.Sub
            $b = New-Object System.Windows.Documents.Bold (New-Object System.Windows.Documents.Run $(if ($i -eq 0) { '' } else { 'You: ' }))
            [void]$p.Inlines.Add($b)
            [void]$p.Inlines.Add((New-Object System.Windows.Documents.Run $txt))
            [void]$doc.Blocks.Add($p)
        } else {
            Add-GpMarkdown $doc ([string]$m.content)
        }
    }
    if ($Status) {
        $p = New-Object System.Windows.Documents.Paragraph (New-Object System.Windows.Documents.Run $Status)
        $p.Foreground = $C.Mute; $p.FontSize = 11.5
        [void]$doc.Blocks.Add($p)
    }
    $ui.RtbAnswer.Document = $doc
    $ui.RtbAnswer.ScrollToEnd()
}

function Add-GpInlines($Paragraph, [string]$Text) {
    # **bold**, `code`, *italic* - enough for what analysts write.
    $parts = [regex]::Split($Text, '(\*\*[^*]+\*\*|`[^`]+`|(?<![\w*])\*[^*\s][^*]*\*(?![\w*]))')
    foreach ($part in $parts) {
        if (-not $part) { continue }
        if ($part -match '^\*\*(.+)\*\*$') { [void]$Paragraph.Inlines.Add((New-Object System.Windows.Documents.Bold (New-Object System.Windows.Documents.Run $Matches[1]))) }
        elseif ($part -match '^`(.+)`$') {
            $r = New-Object System.Windows.Documents.Run $Matches[1]
            $r.FontFamily = $MonoFont; $r.Background = $C.Code; $r.Foreground = $C.Accent
            [void]$Paragraph.Inlines.Add($r)
        }
        elseif ($part -match '^\*(.+)\*$') { [void]$Paragraph.Inlines.Add((New-Object System.Windows.Documents.Italic (New-Object System.Windows.Documents.Run $Matches[1]))) }
        else { [void]$Paragraph.Inlines.Add((New-Object System.Windows.Documents.Run $part)) }
    }
}

function Add-GpMarkdown($Doc, [string]$Markdown) {
    if (-not $Markdown) { return }
    $code = $null
    foreach ($raw in ($Markdown -split "`r?`n")) {
        if ($raw -match '^\s*```') {
            if ($null -eq $code) { $code = New-Object Text.StringBuilder }
            else {
                $p = New-Object System.Windows.Documents.Paragraph (New-Object System.Windows.Documents.Run ($code.ToString().TrimEnd()))
                $p.FontFamily = $MonoFont; $p.FontSize = 12; $p.Background = $C.Code; $p.Padding = '12,10'; $p.Margin = '0,6,0,10'
                [void]$Doc.Blocks.Add($p)
                $code = $null
            }
            continue
        }
        if ($null -ne $code) { [void]$code.AppendLine($raw); continue }
        $line = $raw.TrimEnd()
        if (-not $line.Trim()) { continue }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = '0,3,0,3'
        if ($line -match '^(#{1,6})\s+(.*)$') {
            $lvl = $Matches[1].Length
            $p.FontSize = $(if ($lvl -le 1) { 21 } elseif ($lvl -eq 2) { 18 } else { 15 })
            $p.FontWeight = 'SemiBold'; $p.Margin = '0,14,0,4'
            if ($lvl -le 2) { $p.Foreground = $C.Accent }
            Add-GpInlines $p ($Matches[2] -replace '\*\*', '')
        } elseif ($line -match '^(\s*)[-*+]\s+(.*)$') {
            $p.Margin = ('{0},2,0,2' -f (14 + 14 * [Math]::Floor($Matches[1].Length / 2)))
            $dot = New-Object System.Windows.Documents.Run ([string][char]0x2022 + '  ')
            $dot.Foreground = $C.Accent
            [void]$p.Inlines.Add($dot)
            Add-GpInlines $p $Matches[2]
        } elseif ($line -match '^\s*(\d+)[.)]\s+(.*)$') {
            $p.Margin = '14,2,0,2'
            $num = New-Object System.Windows.Documents.Run ($Matches[1] + '.  ')
            $num.Foreground = $C.Accent; $num.FontWeight = 'SemiBold'
            [void]$p.Inlines.Add($num)
            Add-GpInlines $p $Matches[2]
        } elseif ($line -match '^\s*\|') {
            if ($line -match '^\s*\|[\s:\-|]+\|?\s*$') { continue }
            $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            $p.FontFamily = $MonoFont; $p.FontSize = 12; $p.Margin = '0,0,0,0'
            Add-GpInlines $p ($cells -join '   |   ')
        } elseif ($line -match '^>\s?(.*)$') {
            $p.BorderBrush = $C.Accent; $p.BorderThickness = '3,0,0,0'; $p.Padding = '10,2'; $p.Foreground = $C.Sub
            Add-GpInlines $p $Matches[1]
        } else {
            Add-GpInlines $p $line
        }
        [void]$Doc.Blocks.Add($p)
    }
}

function Set-GpAiBusy([bool]$Busy, [string]$Text = '') {
    $Ai.Busy = $Busy
    $ui.AiBusy.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
    # Pulse only while waiting: a forever-running animation would keep WPF
    # redrawing at 60 Hz the whole time the app is open.
    if ($Busy) {
        $a = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.25, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(800)))
        $a.AutoReverse = $true
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $ui.AiBusyGlyph.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } else {
        $ui.AiBusyGlyph.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    }
    $ui.TxtAiBusy.Text = $Text
    $ui.BtnAiAnalyze.IsEnabled = -not $Busy
    $ui.BtnAiSend.IsEnabled = -not $Busy
}

function Import-GpAiSession([string]$Dir) {
    $Ai.Dir = $Dir
    $Ai.Messages.Clear(); $Ai.Transcript = $null
    $ui.AiExtraPanel.Children.Clear()
    $ui.TxtAiPaste.Text = ''; $ui.TxtAiQuestion.Text = ''
    $Ai.Meta = $null
    if (-not $Dir) { $ui.TxtAiIncluded.Text = 'No session selected.'; Show-GpAiConversation; return }
    $Ai.Meta = Read-GpJson (Join-Path $Dir 'session.json')
    $man = @(Read-GpJson (Join-Path $Dir 'configs\manifest.json'))
    $man = @($man | Where-Object { $_ })
    if ($man.Count) { $ui.TxtAiIncluded.Text = (@($man | ForEach-Object { "$(Split-Path -Leaf $_.original)   ($($_.source))" }) -join "`n") }
    else { $ui.TxtAiIncluded.Text = 'None were found for this game. Add them below, paste them, or press "Find config files".' }
    $exe = [string]$Ai.Meta.game_exe
    if ($exe -and $Settings.GameConfigs.ContainsKey($exe)) {
        foreach ($f in @($Settings.GameConfigs[$exe])) {
            if ($f -and (Test-Path -LiteralPath $f) -and -not ($man | Where-Object { $_.original -eq $f })) { Add-GpAiExtra $f $true 'remembered' }
        }
    }
    Show-GpAiConversation
}
# Refilling the list (after Save, Re-analyse, a new session...) reselects the
# same session; only a real change of session may reset the conversation.
$ui.CmbAiSession.Add_SelectionChanged({
    if (-not $ui.CmbAiSession.SelectedItem) { return }
    $dir = [string]$ui.CmbAiSession.SelectedItem.Tag
    if ($dir -eq $Ai.Dir) { return }
    if ($Ai.Busy) { Select-GpAiSession $Ai.Dir; return }
    Import-GpAiSession $dir
})

$ui.BtnAiAddFile.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Multiselect = $true
    $d.Filter = 'Config files|*.ini;*.cfg;*.json;*.xml;*.lua;*.opt;*.prf;*.txt;*.yaml;*.yml;*.vrsettings;*.conf|All files|*.*'
    if ($Ai.Meta -and $Ai.Meta.game_path) { try { $d.InitialDirectory = Get-GpInstallRoot ([string]$Ai.Meta.game_path) } catch { } }
    if ($d.ShowDialog($Window)) { foreach ($f in $d.FileNames) { Add-GpAiExtra $f $true 'added by you' } }
})

$ui.BtnAiFind.Add_Click({
    if (-not $Ai.Meta -or -not $Ai.Meta.game_exe) { Show-GpError 'This session did not detect a game, so there is nothing to search for. Add the files by hand.'; return }
    $man = @(Read-GpJson (Join-Path $Ai.Dir 'configs\manifest.json') | Where-Object { $_ })
    $found = @(Find-GpGameConfigFiles -Exe ([string]$Ai.Meta.game_exe) -ExePath ([string]$Ai.Meta.game_path) -Vr:($Ai.Meta.mode -eq 'VR') -Settings $Settings)
    $new = 0
    foreach ($f in $found) {
        if ($man | Where-Object { $_.original -eq $f.Path }) { continue }
        Add-GpAiExtra $f.Path ($f.Source -ne 'search') $f.Source
        $new++
    }
    if (-not $new) { [void][System.Windows.MessageBox]::Show($Window, 'Nothing new found - the brief already has every config file GamePerf can locate for this game.', 'GamePerf') }
})

function Get-GpAiFirst {
    $extra = @($ui.AiExtraPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    if ($ui.ChkAiRemember.IsChecked -and $Ai.Meta -and $Ai.Meta.game_exe -and $extra.Count) {
        $exe = [string]$Ai.Meta.game_exe
        $cur = @()
        if ($Settings.GameConfigs.ContainsKey($exe)) { $cur = @($Settings.GameConfigs[$exe]) }
        $Settings.GameConfigs[$exe] = @(($cur + $extra) | Where-Object { $_ } | Select-Object -Unique)
        Export-GpSettings $Settings
    }
    return (New-GpAiFirstMessage -SessionDir $Ai.Dir -ExtraFiles $extra -Pasted $ui.TxtAiPaste.Text -Question $ui.TxtAiQuestion.Text -Redact:([bool]$Settings.Redact))
}

function Send-GpAiConversation {
    $cfg = $Ai.Config
    Set-GpAiBusy $true ("Asking {0} ({1})... large reasoning models can take a few minutes." -f $cfg.Name, $cfg.Model)
    Show-GpAiConversation
    Start-GpJob -Vars @{ Config = $cfg; Messages = $Ai.Messages.ToArray() } -Work {
        Invoke-GpAiChat -Config $V.Config -Messages $V.Messages
    } -OnDone {
        param($r)
        Set-GpAiBusy $false
        if ($r -and $r.ok) {
            [void]$Ai.Messages.Add(@{ role = 'assistant'; content = [string]$r.text })
            $Ai.Transcript = Save-GpAiTranscript -SessionDir $Ai.Dir -Config $Ai.Config -Messages $Ai.Messages.ToArray() -Stamp $Ai.Stamp
            $note = "Saved to $(Split-Path -Leaf $Ai.Transcript)"
            if ($r.usage) { $note += "  -  $($r.usage)" }
            Show-GpAiConversation $note
        } else {
            # Drop the unanswered question so the conversation stays valid.
            if ($Ai.Messages.Count -gt 0 -and $Ai.Messages[$Ai.Messages.Count - 1].role -eq 'user') { $Ai.Messages.RemoveAt($Ai.Messages.Count - 1) }
            Show-GpAiConversation
            Show-GpError "The AI request failed.`n`n$($r.error)"
        }
    }
}

$ui.BtnAiAnalyze.Add_Click({
    if ($Ai.Busy) { return }
    if (-not $Ai.Dir) { Show-GpError 'Pick a session first.'; return }
    $cfg = Get-GpAiConfig $Settings
    if ($cfg.Style -eq 'none') { $ui.BtnAiCopy.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))); return }
    $why = Test-GpAiReady $cfg
    if ($why) { Show-GpError $why; Show-GpPage 'Settings'; return }
    try { $first = Get-GpAiFirst } catch { Show-GpError $_.Exception.Message; return }
    if ($first.Length -gt 500000 -and -not (Ask-Gp ("The brief is {0} KB - large enough to be slow or expensive. Send it anyway?" -f [int]($first.Length / 1024)))) { return }
    $Ai.Config = $cfg
    $Ai.Stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', $GpInv)
    $Ai.Messages.Clear()
    [void]$Ai.Messages.Add(@{ role = 'user'; content = $first })
    Send-GpAiConversation
})

function Send-GpFollowUp {
    $q = $ui.TxtFollow.Text.Trim()
    if (-not $q -or $Ai.Busy) { return }
    if ($Ai.Messages.Count -eq 0) { Show-GpError 'Run an analysis first - follow-up questions continue that conversation.'; return }
    [void]$Ai.Messages.Add(@{ role = 'user'; content = $q })
    $ui.TxtFollow.Text = ''
    Send-GpAiConversation
}
$ui.BtnAiSend.Add_Click({ Send-GpFollowUp })
$ui.TxtFollow.Add_KeyDown({ if ($_.Key -eq 'Return') { Send-GpFollowUp } })

$ui.BtnAiPreview.Add_Click({
    if (-not $Ai.Dir) { return }
    try { $first = Get-GpAiFirst } catch { Show-GpError $_.Exception.Message; return }
    $p = Join-Path $Ai.Dir 'ai-request-preview.md'
    Write-GpTextFile -Path $p -Text $first
    try { Start-Process notepad.exe -ArgumentList "`"$p`"" } catch { Open-GpPath $p }
})
$ui.BtnAiCopy.Add_Click({
    if (-not $Ai.Dir) { return }
    try { $first = Get-GpAiFirst } catch { Show-GpError $_.Exception.Message; return }
    [System.Windows.Clipboard]::SetText($first)
    Show-GpAiConversation ("Copied {0} KB to the clipboard. Paste it into Grok, ChatGPT, Claude or Gemini." -f [int]($first.Length / 1024))
})

# ================================================================
#  SETTINGS PAGE
# ================================================================
foreach ($id in $GpAiProviders.Keys) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $GpAiProviders[$id].Name; $it.Tag = $id
    [void]$ui.CmbProvider.Items.Add($it)
}
foreach ($e in 'low', 'medium', 'high', 'xhigh', 'max') {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $e; $it.Tag = $e
    [void]$ui.CmbEffort.Items.Add($it)
}

function Get-GpUiProviderId {
    if ($ui.CmbProvider.SelectedItem) { return [string]$ui.CmbProvider.SelectedItem.Tag }
    return 'none'
}

function Update-GpProviderRows {
    $id = Get-GpUiProviderId
    $p = $GpAiProviders[$id]
    $none = ($id -eq 'none')
    $ui.RowModel.Visibility = $(if ($none) { 'Collapsed' } else { 'Visible' })
    $ui.RowBaseUrl.Visibility = $(if ($id -in @('custom', 'ollama', 'lmstudio')) { 'Visible' } else { 'Collapsed' })
    $ui.RowKey.Visibility = $(if ($none -or $p.NoKey) { 'Collapsed' } else { 'Visible' })
    $ui.RowEffort.Visibility = $(if ($id -eq 'anthropic') { 'Visible' } else { 'Collapsed' })
    $ui.BtnTestAi.Visibility = $(if ($none) { 'Collapsed' } else { 'Visible' })
    $ui.CmbModelList.Visibility = 'Collapsed'
    $ui.TxtTestAi.Text = ''
    $model = ''
    if ($Settings.AiModels.ContainsKey($id)) { $model = [string]$Settings.AiModels[$id] }
    if (-not $model) { $model = [string]$p.Model }
    $ui.TxtModel.Text = $model
    $base = $p.BaseUrl
    if ($id -in @('custom', 'ollama', 'lmstudio') -and $Settings.AiBaseUrl -and $Settings.AiProvider -eq $id) { $base = $Settings.AiBaseUrl }
    $ui.TxtBaseUrl.Text = [string]$base
    $ui.PwdKey.Password = ''
    if ($Settings.AiKeys.ContainsKey($id) -and $Settings.AiKeys[$id]) { $ui.TxtKeyStatus.Text = 'A key is saved (encrypted for your Windows account). Type a new one to replace it.' }
    elseif ($p.KeyEnv -and [Environment]::GetEnvironmentVariable([string]$p.KeyEnv)) { $ui.TxtKeyStatus.Text = "Using $($p.KeyEnv) from your environment." }
    elseif ($p.KeyOptional) { $ui.TxtKeyStatus.Text = 'Optional for this server.' }
    else { $ui.TxtKeyStatus.Text = 'No key saved yet.' }
    $ui.BtnGetKey.Visibility = $(if ($p.KeyUrl) { 'Visible' } else { 'Collapsed' })
}
$ui.CmbProvider.Add_SelectionChanged({ Update-GpProviderRows })
$ui.BtnGetKey.Add_Click({ $p = $GpAiProviders[(Get-GpUiProviderId)]; if ($p.KeyUrl) { Start-Process $p.KeyUrl } })

function Get-GpUiAiConfig {
    <# The AI config as currently typed on the page, saved or not - for List models / Test. #>
    $tmp = @{} + $Settings
    $id = Get-GpUiProviderId
    $tmp.AiProvider = $id
    $tmp.AiModels = @{} + $Settings.AiModels
    $tmp.AiModels[$id] = $ui.TxtModel.Text.Trim()
    $tmp.AiBaseUrl = $ui.TxtBaseUrl.Text.Trim()
    $cfg = Get-GpAiConfig $tmp
    if ($ui.PwdKey.Password) { $cfg.ApiKey = $ui.PwdKey.Password }
    if ($ui.CmbEffort.SelectedItem) { $cfg.Effort = [string]$ui.CmbEffort.SelectedItem.Tag }
    return $cfg
}

$ui.BtnListModels.Add_Click({
    $cfg = Get-GpUiAiConfig
    $ui.TxtTestAi.Text = 'Asking for the model list...'
    $ui.BtnListModels.IsEnabled = $false
    Start-GpJob -Vars @{ Config = $cfg } -Work { Get-GpAiModels -Config $V.Config } -OnDone {
        param($r)
        $ui.BtnListModels.IsEnabled = $true
        if (-not $r -or -not $r.ok) { $ui.TxtTestAi.Text = "Could not list models: $($r.error)"; return }
        $ui.CmbModelList.Items.Clear()
        foreach ($m in $r.models) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $it.Content = $m; $it.Tag = $m
            [void]$ui.CmbModelList.Items.Add($it)
        }
        $ui.CmbModelList.Visibility = 'Visible'
        $ui.TxtTestAi.Text = "$(@($r.models).Count) models available - pick one above."
    }
})
$ui.CmbModelList.Add_SelectionChanged({ if ($ui.CmbModelList.SelectedItem) { $ui.TxtModel.Text = [string]$ui.CmbModelList.SelectedItem.Tag } })

$ui.BtnTestAi.Add_Click({
    $cfg = Get-GpUiAiConfig
    $why = Test-GpAiReady $cfg
    if ($why) { $ui.TxtTestAi.Text = $why; return }
    $ui.TxtTestAi.Text = 'Testing...'
    $ui.BtnTestAi.IsEnabled = $false
    Start-GpJob -Vars @{ Config = $cfg } -Work {
        Invoke-GpAiChat -Config $V.Config -Messages @(@{ role = 'user'; content = 'Reply with the single word OK.' }) -System 'You are a connection test. Reply with OK.'
    } -OnDone {
        param($r)
        $ui.BtnTestAi.IsEnabled = $true
        if ($r -and $r.ok) { $ui.TxtTestAi.Text = "Connected - $($r.model) replied." } else { $ui.TxtTestAi.Text = "Failed: $($r.error)" }
    }
})

function Set-GpSettingsUi {
    foreach ($it in $ui.CmbProvider.Items) { if ($it.Tag -eq $Settings.AiProvider) { $ui.CmbProvider.SelectedItem = $it } }
    if (-not $ui.CmbProvider.SelectedItem) { $ui.CmbProvider.SelectedIndex = 0 }
    foreach ($it in $ui.CmbEffort.Items) { if ($it.Tag -eq $Settings.AiEffort) { $ui.CmbEffort.SelectedItem = $it } }
    if (-not $ui.CmbEffort.SelectedItem) { $ui.CmbEffort.SelectedIndex = 2 }
    Update-GpProviderRows
    $ui.TxtGoals.Text = [string]$Settings.Goals
    $ui.TxtVrFps.Text = [string]$Settings.TargetFpsVr
    $ui.TxtMonFps.Text = [string]$Settings.TargetFpsMonitor
    $ui.ChkRedact.IsChecked = [bool]$Settings.Redact
    $ui.ChkIncludePrev.IsChecked = [bool]$Settings.IncludePrevious
    $ui.ChkBeep.IsChecked = [bool]$Settings.MarkerBeep
    $ui.TxtDataRoot.Text = Get-GpDataRoot $Settings
    $ui.ChkFrames.IsChecked = [bool]$Settings.CaptureFrames
    $ui.ChkAdmin.IsChecked = [bool]$Settings.RunElevated
    $ui.ChkStopWithGame.IsChecked = [bool]$Settings.StopWithGame
    $ui.ChkMinimize.IsChecked = [bool]$Settings.MinimizeWhileLogging
    if ($Settings.Mode -eq 'VR') { $ui.RbVr.IsChecked = $true } else { $ui.RbMonitor.IsChecked = $true }
    Set-GpModeUi ($Settings.Mode -eq 'VR')
}

$ui.BtnResetGoals.Add_Click({ $ui.TxtGoals.Text = Get-GpDefaultGoals })
$ui.BtnBrowseData.Add_Click({
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Where should GamePerf keep its sessions?'
        $d.SelectedPath = $ui.TxtDataRoot.Text
        if ($d.ShowDialog() -eq 'OK') { $ui.TxtDataRoot.Text = $d.SelectedPath }
    } catch { }
})
$ui.BtnOpenData.Add_Click({
    $p = $ui.TxtDataRoot.Text
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$p`""
})

$ui.BtnSaveSettings.Add_Click({
    $id = Get-GpUiProviderId
    $Settings.AiProvider = $id
    if ($id -ne 'none') { $Settings.AiModels[$id] = $ui.TxtModel.Text.Trim() }
    if ($id -in @('custom', 'ollama', 'lmstudio')) { $Settings.AiBaseUrl = $ui.TxtBaseUrl.Text.Trim() }
    if ($ui.PwdKey.Password) { $Settings.AiKeys[$id] = Protect-GpSecret $ui.PwdKey.Password; $ui.PwdKey.Password = '' }
    if ($ui.CmbEffort.SelectedItem) { $Settings.AiEffort = [string]$ui.CmbEffort.SelectedItem.Tag }
    $g = $ui.TxtGoals.Text.Trim()
    $Settings.Goals = $(if ($g) { $g } else { Get-GpDefaultGoals })
    $v = ConvertTo-GpDouble $ui.TxtVrFps.Text; if (-not [double]::IsNaN($v) -and $v -gt 0) { $Settings.TargetFpsVr = $v }
    $v = ConvertTo-GpDouble $ui.TxtMonFps.Text; if (-not [double]::IsNaN($v) -and $v -ge 0) { $Settings.TargetFpsMonitor = $v }
    $Settings.Redact = [bool]$ui.ChkRedact.IsChecked
    $Settings.IncludePrevious = [bool]$ui.ChkIncludePrev.IsChecked
    $Settings.MarkerBeep = [bool]$ui.ChkBeep.IsChecked
    $dr = $ui.TxtDataRoot.Text.Trim()
    $default = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GamePerf'
    $Settings.DataRoot = $(if ($dr -and $dr -ne $default) { $dr } else { '' })
    try { Export-GpSettings $Settings; $ui.TxtSaved.Text = 'Saved.' } catch { Show-GpError "Could not save settings: $($_.Exception.Message)" }
    Update-GpProviderRows
    Update-GpAiHeader
    Set-GpModeUi ([bool]$ui.RbVr.IsChecked)
    Update-GpSessionList $Current.Dir
})

# ================================================================
#  STARTUP / SHUTDOWN
# ================================================================
# ---- launch + permissions card -------------------------------------
function Update-GpLaunchUi {
    $launcher = Get-GpLauncherPath
    $ui.BtnShortcutDesktop.IsEnabled = [bool]$launcher
    $ui.BtnShortcutStart.IsEnabled = [bool]$launcher
    if (-not $launcher) { $ui.TxtShortcut.Text = 'GamePerf.exe is missing from the GamePerf folder - re-extract the kit.' }
    else {
        $have = @()
        if (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GamePerf.lnk')) { $have += 'desktop' }
        if (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'GamePerf.lnk')) { $have += 'Start menu' }
        $ui.TxtShortcut.Text = $(if ($have.Count) { "GamePerf is on your $($have -join ' and ')." } else { '' })
    }
    $member = Test-GpPerfLogUser
    if ($member -and $Settings.PerfLogPending) { $Settings.PerfLogPending = $false; Export-GpSettings $Settings }
    if (Test-GpAdmin) {
        $ui.TxtPerfLog.Text = 'GamePerf is running as administrator, so per-frame timing never needs a prompt.'
        $ui.BtnPerfLog.IsEnabled = $false
        $ui.TxtAdminHint.Text = ''
    } elseif ($member) {
        $ui.TxtPerfLog.Text = 'On. Your account is in Performance Log Users, so per-frame timing starts without an admin prompt.'
        $ui.BtnPerfLog.IsEnabled = $false; $ui.BtnPerfLog.Content = 'Already allowed'
        $ui.TxtAdminHint.Text = 'Not needed on this PC: your account can record per-frame timing without admin.'
    } elseif ($Settings.PerfLogPending) {
        $ui.TxtPerfLog.Text = 'Added. Sign out of Windows and back in once to finish - until then, Start still asks for admin.'
        $ui.BtnPerfLog.IsEnabled = [bool]$launcher
        $ui.TxtAdminHint.Text = 'Sign out of Windows and back in once and this prompt goes away.'
    } else {
        $ui.TxtPerfLog.Text = 'Per-frame timing uses Windows event tracing, which normally means an admin prompt every time you press Start. Adding your account to the built-in "Performance Log Users" group grants just that permission - nothing else. One admin prompt now, then sign out and back in once.'
        $ui.BtnPerfLog.IsEnabled = [bool]$launcher
        $ui.TxtAdminHint.Text = 'Tip: Settings > "Allow it for my account" removes this prompt for good.'
    }
}

$ui.BtnShortcutDesktop.Add_Click({ try { [void](New-GpShortcut 'Desktop') } catch { Show-GpError $_.Exception.Message }; Update-GpLaunchUi })
$ui.BtnShortcutStart.Add_Click({ try { [void](New-GpShortcut 'StartMenu') } catch { Show-GpError $_.Exception.Message }; Update-GpLaunchUi })
$ui.BtnPerfLog.Add_Click({
    if (-not (Ask-Gp "Add your Windows account to the built-in Performance Log Users group?`n`nMembers may record performance traces - what per-frame timing needs - without being an administrator. Windows asks for admin once now; afterwards, sign out and back in.")) { return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try { $p = Start-GpHidden -Mode '--grant-perflog' -Argument $sid -Elevated } catch { $ui.TxtPerfLog.Text = "Not changed ($($_.Exception.Message))."; return }
    $ui.BtnPerfLog.IsEnabled = $false
    $ui.TxtPerfLog.Text = 'Working...'
    Add-GpProcessJob -Process $p -OnDone {
        param($code)
        if ($code -eq 0 -or $code -eq 2) {
            $Settings.PerfLogPending = $true
            Export-GpSettings $Settings
            [void][System.Windows.MessageBox]::Show($Window, "Done. Sign out of Windows and back in once - after that, GamePerf records per-frame timing without asking for admin.", 'GamePerf')
        } else { Show-GpError 'Windows did not accept the change. Details are in %LOCALAPPDATA%\GamePerf\launcher.log.' }
        Update-GpLaunchUi
    }
})

$ui.TxtVersion.Text = "v$GamePerfVersion  -  iRacing X3D Tuning kit"
$ui.TxtAbout.Text = "GamePerf $GamePerfVersion. Part of the iRacing X3D Tuning kit (MIT). Uses Intel PresentMon for per-frame timing and the kit's CPU detection (scripts\X3D-Profiles.ps1). Settings: $(Get-GpSettingsPath)"

$Window.Add_SourceInitialized({
    try {
        if ($NativeOk) { [GamePerf.Native.Win]::DarkTitleBar((New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle) }
    } catch { }
})

$Window.Add_Closing({
    param($sender, $e)
    if ($State.Logging) {
        if (-not (Ask-Gp "A session is still recording.`n`nStop it and close? Everything recorded so far is kept and analysed.")) { $e.Cancel = $true; return }
        try { New-Item -ItemType File -Force -Path (Join-Path $State.Dir 'stop.flag') | Out-Null } catch { }
    }
    try { $LiveTimer.Stop(); $JobTimer.Stop() } catch { }
})

$Window.Add_Activated({ if ($ui.TxtStatus.Text -eq 'Session ready') { Set-GpStatusChip 'Idle' $C.Mute } })

$Window.Add_Loaded({
    Set-GpSettingsUi
    Update-GpGameList
    Update-GpPmStatus
    Update-GpSessionList
    Update-GpAiHeader
    Update-GpLaunchUi
    Show-GpPage 'Record'
    if (-not $Settings.FirstRunDone) {
        $Settings.FirstRunDone = $true
        Export-GpSettings $Settings
        if ((Get-GpLauncherPath) -and (Ask-Gp "Welcome to GamePerf.`n`nAdd a GamePerf icon to your desktop and Start menu?")) {
            try { [void](New-GpShortcut 'Desktop'); [void](New-GpShortcut 'StartMenu') } catch { Show-GpError "Could not create the shortcuts: $($_.Exception.Message)" }
            Update-GpLaunchUi
        }
    }
})

[void]$Window.ShowDialog()
