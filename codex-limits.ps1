param(
    [string]$CodexPath,
    [switch]$Check,
    [string]$PreviewPath,
    [switch]$PreviewCollapsed,
    [switch]$PreviewEdge
)


$ErrorActionPreference = 'Stop'
$refreshSeconds = 30
if (-not $CodexPath) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $bundledCodex = Join-Path $codexHome 'plugins\.plugin-appserver\codex.exe'
    $installedCodex = Get-Command codex.exe -ErrorAction SilentlyContinue
    $CodexPath = if (Test-Path -LiteralPath $bundledCodex) { $bundledCodex }
                 elseif ($installedCodex) { $installedCodex.Source }
}

function Send-CodexMessage($message) {
    $json = ($message | ConvertTo-Json -Compress -Depth 5) + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $inputStream = $script:server.StandardInput.BaseStream
    $inputStream.Write($bytes, 0, $bytes.Length)
    $inputStream.Flush()
}

function Start-CodexServer {
    if (-not $CodexPath) { throw 'Codex CLI was not found.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $CodexPath
    $startInfo.Arguments = 'app-server --listen stdio://'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.RedirectStandardError = $true
    $script:server = [Diagnostics.Process]::Start($startInfo)
    $script:server.BeginErrorReadLine()
    $script:nextLine = $script:server.StandardOutput.ReadLineAsync()
    Send-CodexMessage @{
        id = 0
        method = 'initialize'
        params = @{ clientInfo = @{ name = 'codex_limits_widget'; title = 'Codex Limits'; version = '1.0.0' } }
    }
    $script:deadline = [DateTime]::UtcNow.AddSeconds(20)
}

function Stop-CodexServer {
    if ($null -eq $script:server) { return }
    try {
        if (-not $script:server.HasExited) { $script:server.Kill() }
    } catch [InvalidOperationException] {
        # The process can exit between HasExited and Kill.
    } finally {
        $script:server.Dispose()
        $script:server = $null
        $script:serverReady = $false
        $script:contextDeadline = $null
    }
}

function Request-Limits {
    Send-CodexMessage @{ id = 1; method = 'account/rateLimits/read' }
    $script:deadline = [DateTime]::UtcNow.AddSeconds(20)
}

function Request-Context {
    if (-not $script:serverReady -or $script:contextDeadline) { return }
    $now = [DateTime]::UtcNow
    $script:nextContextRefresh = $now.AddSeconds($refreshSeconds)
    $script:contextDeadline = $now.AddSeconds(20)
    $script:contextRequestId = ++$script:nextContextRequestId
    Send-CodexMessage @{
        id = $script:contextRequestId
        method = 'thread/list'
        params = @{
            sortKey = 'recency_at'
            limit = 3
            modelProviders = @()
            # Keep the activity timestamps recorded by Codex Desktop.
            useStateDbOnly = $true
        }
    }
}

function Get-ContextRemaining([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $latest = $null
    $stream = $null
    $reader = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $reader = [IO.StreamReader]::new($stream)
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -notmatch '"type"\s*:\s*"token_count"') { continue }
            try { $record = ConvertFrom-Json -InputObject $line } catch { continue }
            if ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count' -and $record.payload.info) {
                $latest = $record.payload.info
            }
        }
    } catch [IO.IOException], [UnauthorizedAccessException] {
        return
    } finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
    $baseline = 12000 # Codex CLI excludes its base instructions from the percentage.
    $window = $latest.model_context_window
    $used = $latest.last_token_usage.total_tokens
    if ($null -eq $used -or $window -le $baseline) { return }
    $remaining = 100 * ($window - [Math]::Max($baseline, $used)) / ($window - $baseline)
    return [int][Math]::Round([Math]::Max(0, $remaining), [MidpointRounding]::AwayFromZero)
}

function Update-ContextWarning {
    $lowContext = $contextList.ItemsSource | Where-Object IsLow | Select-Object -First 1
    if ($contextPanel.Visibility -eq 'Collapsed' -and $lowContext) {
        $contextButton.Foreground = $brushes.ConvertFromString('#FFAD8C')
        $contextButton.ToolTip = 'A recent chat has less than 15% context left'
    } else {
        $contextButton.ClearValue([Windows.Controls.Control]::ForegroundProperty)
        $contextButton.ClearValue([Windows.FrameworkElement]::ToolTipProperty)
    }
}

function Show-Context($message) {
    $script:contextDeadline = $null
    if ($message.error) {
        $contextStatus.Text = 'Context unavailable'
        return
    }
    $contextList.ItemsSource = @(
        foreach ($thread in $message.result.data) {
            $remaining = Get-ContextRemaining $thread.path
            $title = if ($thread.name) { $thread.name } else { 'Untitled chat' }
            $label = if ($null -eq $remaining) { 'Waiting for data' } else { '{0}% left' -f $remaining }
            [pscustomobject]@{
                Title = $title
                Remaining = $label
                IsLow = ($null -ne $remaining -and $remaining -lt 15)
            }
        }
    )
    $contextStatus.Text = if ($contextList.Items.Count) { 'Checked {0:HH:mm:ss}' -f (Get-Date) }
                          else { 'No recent local Codex chats' }
    Update-ContextWarning
}

function Show-LimitsUnavailable {
    Set-Connection 'OFFLINE' '#FFAD8C'
    $status.Text = if ($script:lastUpdated) { 'Update failed  |  Last read {0:HH:mm:ss}' -f $script:lastUpdated }
                   elseif (-not $CodexPath) { 'Codex CLI was not found.' }
                   else { 'Limits unavailable  |  Retrying in 30s' }
}

function Read-Limits {
    while ($script:nextLine.IsCompleted) {
        $line = $script:nextLine.GetAwaiter().GetResult()
        if ($null -eq $line) { throw 'Codex stopped before replying.' }
        $script:nextLine = $script:server.StandardOutput.ReadLineAsync()
        $message = ConvertFrom-Json -InputObject $line
        if ($message.id -eq 0 -and $null -ne $message.id) {
            if ($message.error) { throw 'Could not initialize Codex.' }
            Send-CodexMessage @{ method = 'initialized' }
            $script:serverReady = $true
            Request-Limits
        }
        if ($script:contextDeadline -and $message.id -eq $script:contextRequestId) { Show-Context $message }
        if ($message.id -eq 1) {
            $limits = $message.result.rateLimitsByLimitId.codex
            if (-not $limits) { $limits = $message.result.rateLimits }
            $script:deadline = $null
            $script:nextRefresh = [DateTime]::UtcNow.AddSeconds($refreshSeconds)
            if ($message.error -or -not ($limits.primary -or $limits.secondary)) {
                if ($Check) { throw 'Could not read Codex account limits.' }
                Show-LimitsUnavailable
                continue
            }
            return $limits
        }
    }
    if ($script:deadline -and [DateTime]::UtcNow -ge $script:deadline) {
        if ($Check -or -not $script:serverReady) { throw 'Codex request timed out.' }
        $script:deadline = $null
        $script:nextRefresh = [DateTime]::UtcNow.AddSeconds($refreshSeconds)
        Show-LimitsUnavailable
    }
}

if ($Check) {
    try {
        Start-CodexServer
        do {
            $limits = Read-Limits
            if (-not $limits) { Start-Sleep -Milliseconds 100 }
        } until ($limits)
        Write-Output 'Codex account limits received.'
    } finally {
        Stop-CodexServer
    }
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

$form = [Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Limits" Width="338" SizeToContent="Height" Topmost="True"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" Foreground="#F5F7FF" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="Manual" UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="CloseButton" TargetType="Button">
            <Setter Property="Foreground" Value="#B1BAD0"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="7" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#39405C"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <DataTemplate x:Key="Dial">
            <StackPanel Margin="2,0" HorizontalAlignment="Center">
                <Grid Width="92" Height="92" HorizontalAlignment="Center">
                    <Ellipse Margin="3.5" UseLayoutRounding="False" Stroke="#31374C" StrokeThickness="5" Fill="#191E32"/>
                    <Path Data="{Binding Geometry}" Stroke="{Binding Accent}" StrokeThickness="5"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                        <Path.Effect>
                            <DropShadowEffect Color="{Binding Glow}" BlurRadius="12" Opacity="0.45" ShadowDepth="0"/>
                        </Path.Effect>
                    </Path>
                    <TextBlock Text="{Binding Usage}" FontSize="24" FontWeight="SemiBold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"
                               AutomationProperties.Name="{Binding UsageDescription}"/>
                </Grid>
                <TextBlock Text="{Binding Label}" Margin="0,4,0,2" FontWeight="SemiBold" TextAlignment="Center"/>
                <TextBlock Text="{Binding Reset}" FontSize="11" Foreground="#B1BAD0" TextAlignment="Center"/>
            </StackPanel>
        </DataTemplate>
        <DataTemplate x:Key="EdgeDial">
            <Grid Width="28" Height="28" ToolTip="{Binding Label}">
                <Viewbox>
                    <Grid Width="92" Height="92">
                        <Ellipse Margin="3.5" UseLayoutRounding="False" Stroke="#384259" StrokeThickness="5"/>
                        <Path Data="{Binding Geometry}" Stroke="{Binding Accent}" StrokeThickness="5"
                              StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Grid>
                </Viewbox>
                <TextBlock Text="{Binding Usage}" Foreground="#F3F6FF" FontSize="9.5" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"
                           AutomationProperties.Name="{Binding UsageDescription}"/>
            </Grid>
        </DataTemplate>
    </Window.Resources>
    <Grid>
    <Border Name="FullWidget" Margin="8" CornerRadius="23" BorderThickness="1" BorderBrush="#414763">
        <Border.Background>
            <RadialGradientBrush Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.85" RadiusY="1.05">
                <GradientStop Color="#282D4C"/>
                <GradientStop Color="#141929" Offset="1"/>
            </RadialGradientBrush>
        </Border.Background>
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="16" Opacity="0.38" ShadowDepth="2"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid Name="Header" Background="Transparent" Margin="14,8,10,5">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Canvas Width="19" Height="17" Margin="0,0,7,0">
                        <Ellipse Canvas.Left="3" Canvas.Top="4" Width="11" Height="11" Stroke="#8CCAFF" StrokeThickness="1.2"/>
                        <Path Data="M 1,13 C -1,9 15,0 17,4 C 19,8 3,17 1,13" Stroke="#8CCAFF" StrokeThickness="1.2"/>
                    </Canvas>
                    <TextBlock Text="Codex Limits" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Ellipse Name="ConnectionDot" Fill="#929AB1" Width="6" Height="6" Margin="0,0,5,0"/>
                    <TextBlock Name="Connection" Text="WAIT" FontSize="10" FontWeight="SemiBold"
                               Foreground="#B1BAD0" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" Margin="12,0,0,0">
                        <Button Name="TuckButton" Style="{StaticResource CloseButton}"
                                Width="26" Height="26" ToolTip="Tuck to right edge"
                                AutomationProperties.Name="Tuck Orbit to right edge">
                            <Canvas Width="14" Height="14">
                                <Path Data="M 5,4 L 9,7 L 5,10" StrokeThickness="1.2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                            </Canvas>
                        </Button>
                        <Button Name="CloseButton" Style="{StaticResource CloseButton}"
                                Width="26" Height="26" AutomationProperties.Name="Close Codex Limits">
                            <Canvas Width="14" Height="14">
                                <Path Data="M 4,4 L 10,10 M 10,4 L 4,10" StrokeThickness="1.2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                            </Canvas>
                        </Button>
                    </StackPanel>
                </StackPanel>
            </Grid>
            <UniformGrid Grid.Row="1" Rows="1" Margin="12,3,12,13">
                <ContentControl Name="PrimaryDial" ContentTemplate="{StaticResource Dial}" HorizontalContentAlignment="Stretch"/>
                <ContentControl Name="SecondaryDial" ContentTemplate="{StaticResource Dial}" HorizontalContentAlignment="Stretch"/>
            </UniformGrid>
            <Border Grid.Row="2" BorderThickness="0,1,0,0" BorderBrush="#31374C" Padding="14,8">
                <DockPanel>
                    <Button Name="ContextButton" DockPanel.Dock="Right" Style="{StaticResource CloseButton}"
                            Width="65" Height="20" FontSize="11" Content="Context &#9656;"
                            AutomationProperties.Name="Show recent chat context"/>
                    <TextBlock Name="Status" Text="Connecting to Codex..." FontSize="11" Foreground="#B1BAD0" VerticalAlignment="Center"/>
                </DockPanel>
            </Border>
            <Border Name="ContextPanel" Grid.Row="3" Visibility="Collapsed"
                    BorderThickness="0,1,0,0" BorderBrush="#31374C" Padding="14,10,14,12">
                <StackPanel>
                    <DockPanel>
                        <TextBlock Name="ContextStatus" DockPanel.Dock="Right" FontSize="11"
                                   Foreground="#B1BAD0" VerticalAlignment="Center"/>
                        <TextBlock Text="Recent chats" FontWeight="SemiBold"/>
                    </DockPanel>
                    <ItemsControl Name="ContextList">
                        <ItemsControl.ItemTemplate>
                            <DataTemplate>
                                <DockPanel Margin="0,7,0,0">
                                    <TextBlock DockPanel.Dock="Right" Text="{Binding Remaining}" Margin="8,0,0,0"
                                               FontSize="11" VerticalAlignment="Center">
                                        <TextBlock.Style>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="Foreground" Value="#8CCAFF"/>
                                                <Style.Triggers>
                                                    <DataTrigger Binding="{Binding IsLow}" Value="True">
                                                        <Setter Property="Foreground" Value="#FFAD8C"/>
                                                    </DataTrigger>
                                                </Style.Triggers>
                                            </Style>
                                        </TextBlock.Style>
                                    </TextBlock>
                                    <TextBlock Text="{Binding Title}" ToolTip="{Binding Title}"
                                               TextTrimming="CharacterEllipsis" FontSize="12"/>
                                </DockPanel>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
    <Button Name="EdgeTab" Visibility="Collapsed" Height="82" ToolTip="Restore Orbit"
            AutomationProperties.Name="Restore Orbit from the right edge">
        <StackPanel>
            <Path Data="M 7,0 L 3,4 L 7,8" Stroke="#B9DCFF" StrokeThickness="1.3"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  HorizontalAlignment="Center" Margin="0,0,0,4"/>
            <ContentControl Content="{Binding Content, ElementName=PrimaryDial}"
                            Visibility="{Binding Visibility, ElementName=PrimaryDial}"
                            ContentTemplate="{StaticResource EdgeDial}"/>
            <ContentControl Content="{Binding Content, ElementName=SecondaryDial}"
                            Visibility="{Binding Visibility, ElementName=SecondaryDial}"
                            ContentTemplate="{StaticResource EdgeDial}" Margin="0,3,0,0"/>
        </StackPanel>
        <Button.Template>
            <ControlTemplate TargetType="Button">
                <Border Name="TabSurface" CornerRadius="12,0,0,12" BorderThickness="1,1,0,1"
                        BorderBrush="#48627F" Background="#202C43">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="TabSurface" Property="Background" Value="#304764"/>
                    </Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="TabSurface" Property="BorderBrush" Value="#8CCAFF"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Button.Template>
    </Button>
    </Grid>
</Window>
'@)

$rows = @($form.FindName('PrimaryDial'), $form.FindName('SecondaryDial'))
$status = $form.FindName('Status')
$connection = $form.FindName('Connection')
$connectionDot = $form.FindName('ConnectionDot')
$contextButton = $form.FindName('ContextButton')
$contextPanel = $form.FindName('ContextPanel')
$contextList = $form.FindName('ContextList')
$contextStatus = $form.FindName('ContextStatus')
$fullWidget = $form.FindName('FullWidget')
$tuckButton = $form.FindName('TuckButton')
$edgeTab = $form.FindName('EdgeTab')
$fullWidth = $form.Width
$edgeWidth = 40
$brushes = New-Object Windows.Media.BrushConverter
$colors = New-Object Windows.Media.ColorConverter

function New-OrbitArc([int]$used) {
    if ($used -eq 0) { return [Windows.Media.Geometry]::Empty }
    $center = [Windows.Point]::new(46, 46)
    $radius = 40
    if ($used -eq 100) { return [Windows.Media.EllipseGeometry]::new($center, $radius, $radius) }
    $angle = [Math]::PI * 2 * $used / 100
    $end = [Windows.Point]::new(46 + $radius * [Math]::Sin($angle), 46 - $radius * [Math]::Cos($angle))
    $arc = [Windows.Media.ArcSegment]::new($end, [Windows.Size]::new($radius, $radius), 0, ($used -gt 50), 'Clockwise', $true)
    $figure = [Windows.Media.PathFigure]::new()
    $figure.StartPoint = [Windows.Point]::new(46, 6)
    $figure.Segments.Add($arc)
    $geometry = [Windows.Media.PathGeometry]::new()
    $geometry.Figures.Add($figure)
    return $geometry
}

function Show-Limit($row, $window, [string]$accent) {
    if (-not $window) {
        $row.Visibility = 'Collapsed'
        return
    }
    $minutes = $window.windowDurationMins
    $duration = if (-not $minutes) { 'Limit' }
                elseif ($minutes -eq 10080) { 'Weekly limit' }
                elseif ($minutes % 1440 -eq 0) { '{0}-day limit' -f ($minutes / 1440) }
                elseif ($minutes % 60 -eq 0) { '{0}-hour limit' -f ($minutes / 60) }
                else { '{0}-minute limit' -f $minutes }
    $used = [Math]::Min(100, [Math]::Max(0, [int]$window.usedPercent))
    $resetText = if ($window.resetsAt) {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds($window.resetsAt).LocalDateTime
        if ($reset.Date -eq [DateTime]::Today) { 'Resets at {0:HH:mm}' -f $reset }
        else { 'Resets {0:ddd, HH:mm}' -f $reset }
    } else { 'Reset time unavailable' }
    if ($used -ge 90) { $accent = '#FFAD8C' }
    $row.Content = [pscustomobject]@{
        Geometry = New-OrbitArc $used
        Accent = $brushes.ConvertFromString($accent)
        Glow = $colors.ConvertFromString($accent)
        Usage = '{0}%' -f $used
        UsageDescription = '{0}% used' -f $used
        Label = $duration
        Reset = $resetText
    }
    $row.Visibility = 'Visible'
}

function Set-Connection([string]$label, [string]$color) {
    $connection.Text = $label
    $connection.Foreground = $connectionDot.Fill = $brushes.ConvertFromString($color)
}

foreach ($row in $rows) {
    $row.Content = [pscustomobject]@{ Usage = [char]0x2014; Label = 'Waiting for data'; Reset = '' }
}
$form.FindName('CloseButton').Add_Click({ $form.Close() })
$form.FindName('Header').Add_MouseLeftButtonDown({ $form.DragMove() })
function Move-EdgeTab([double]$top) {
    $form.Top = [Math]::Max($script:edgeAreaTop, [Math]::Min($top, $script:edgeAreaBottom - $edgeTab.Height))
    $script:restoreTop = [Math]::Max($script:edgeAreaTop, [Math]::Min($form.Top, $script:edgeAreaBottom - $script:expandedHeight))
}

$tuckButton.Add_Click({
    $script:expandedLeft = $form.Left
    $handle = [Windows.Interop.WindowInteropHelper]::new($form).Handle
    $area = [Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    # Screen bounds are in pixels. Convert them through the current window's DPI.
    $topRight = $form.PointFromScreen([Windows.Point]::new($area.Right, $area.Top))
    $bottomRight = $form.PointFromScreen([Windows.Point]::new($area.Right, $area.Bottom))
    $edgeLeft = $form.Left + $topRight.X - $edgeWidth
    $script:edgeAreaTop = $form.Top + $topRight.Y
    $script:edgeAreaBottom = $form.Top + $bottomRight.Y
    $script:expandedHeight = $form.ActualHeight
    $script:restoreTop = $form.Top
    $edgeTop = [Math]::Max($script:edgeAreaTop, [Math]::Min($form.Top, $script:edgeAreaBottom - $edgeTab.Height))

    $fullWidget.Visibility = 'Collapsed'
    $edgeTab.Visibility = 'Visible'
    $form.Width = $edgeWidth
    $form.Left = $edgeLeft
    $form.Top = $edgeTop
    $null = $edgeTab.Focus()
})
$edgeTab.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    $script:edgeDragStart = $form.PointToScreen($eventArgs.GetPosition($form))
    $script:edgeDragTop = $form.Top
    $script:edgeDragging = $false
})
$edgeTab.Add_PreviewMouseMove({
    param($sender, $eventArgs)
    if ($null -eq $script:edgeDragStart -or -not $edgeTab.IsMouseCaptured -or $eventArgs.LeftButton -ne 'Pressed') { return }
    $start = $form.PointFromScreen($script:edgeDragStart)
    $offsetY = $eventArgs.GetPosition($form).Y - $start.Y
    if (-not $script:edgeDragging -and [Math]::Abs($offsetY) -lt [Windows.SystemParameters]::MinimumVerticalDragDistance) { return }

    $script:edgeDragging = $true
    Move-EdgeTab ($script:edgeDragTop + $offsetY)
})
$edgeTab.Add_PreviewMouseLeftButtonUp({
    param($sender, $eventArgs)
    $script:edgeDragStart = $null
    if ($script:edgeDragging) {
        $script:edgeDragging = $false
        $eventArgs.Handled = $true
        $edgeTab.ReleaseMouseCapture()
    }
})
$edgeTab.Add_Click({
    $edgeTab.Visibility = 'Collapsed'
    $fullWidget.Visibility = 'Visible'
    $form.Width = $fullWidth
    $form.Left = $script:expandedLeft
    $form.Top = $script:restoreTop
    $null = $tuckButton.Focus()
})
$contextButton.Add_Click({
    $isOpen = $contextPanel.Visibility -ne 'Visible'
    $contextPanel.Visibility = if ($isOpen) { 'Visible' } else { 'Collapsed' }
    $contextButton.Content = 'Context ' + [char]$(if ($isOpen) { 0x25BE } else { 0x25B8 })
    Update-ContextWarning
    if ($isOpen) {
        $contextStatus.Text = 'Loading...'
        Request-Context
    }
})

if ($PreviewPath) {
    Show-Limit $rows[0] @{ windowDurationMins = 300; usedPercent = 42 } '#8CCAFF'
    Show-Limit $rows[1] @{ windowDurationMins = 10080; usedPercent = 76 } '#C3A7FF'
    $rows[0].Content.Reset = 'Resets at 23:40'
    $rows[1].Content.Reset = 'Resets Fri, 09:00'
    Set-Connection 'LIVE' '#8CCAFF'
    $status.Text = 'Updated 22:34:25  |  Every 30s'
    $contextPanel.Visibility = 'Visible'
    $contextButton.Content = 'Context ' + [char]0x25BE
    $contextStatus.Text = 'Checked 22:34:25'
    $contextList.ItemsSource = @(
        [pscustomobject]@{ Title = '🎲 Рандомні питання'; Remaining = '69% left'; IsLow = $false }
        [pscustomobject]@{ Title = 'Architecture & System Design'; Remaining = '12% left'; IsLow = $true }
        [pscustomobject]@{ Title = 'Підготовка до співбесіди'; Remaining = '87% left'; IsLow = $false }
    )
    if ($PreviewCollapsed) {
        $contextPanel.Visibility = 'Collapsed'
        $contextButton.Content = 'Context ' + [char]0x25B8
    }
    Update-ContextWarning
    if ($PreviewEdge) {
        $fullWidget.Visibility = 'Collapsed'
        $edgeTab.Visibility = 'Visible'
    }
    $previewWidth = if ($PreviewEdge) { $edgeWidth } else { $fullWidth }
    $visual = $form.Content
    $visual.Measure([Windows.Size]::new($previewWidth, [double]::PositiveInfinity))
    $size = [Windows.Size]::new($previewWidth, $visual.DesiredSize.Height)
    $visual.Arrange([Windows.Rect]::new(0, 0, $size.Width, $size.Height))
    $visual.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int]($size.Width * 2), [int]($size.Height * 2), 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file = [IO.File]::Create($PreviewPath)
    try { $encoder.Save($file) } finally { $file.Dispose() }
    return
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:nextRefresh = [DateTime]::UtcNow
$script:nextContextRefresh = $script:nextRefresh
$script:nextContextRequestId = 1
$timer.Add_Tick({
    try {
        if ($script:contextDeadline -and [DateTime]::UtcNow -ge $script:contextDeadline) {
            $script:contextDeadline = $null
            $contextStatus.Text = 'Context refresh timed out'
        }
        if (-not $script:server -and [DateTime]::UtcNow -ge $script:nextRefresh) {
            Start-CodexServer
        }
        if (-not $script:server) { return }
        if (-not $script:deadline -and [DateTime]::UtcNow -ge $script:nextRefresh) {
            Request-Limits
        }
        $limits = Read-Limits
        if ([DateTime]::UtcNow -ge $script:nextContextRefresh) {
            Request-Context
        }
        if ($limits) {
            Show-Limit $rows[0] $limits.primary '#8CCAFF'
            Show-Limit $rows[1] $limits.secondary '#C3A7FF'
            Set-Connection 'LIVE' '#8CCAFF'
            $script:lastUpdated = Get-Date
            $status.Text = 'Updated {0:HH:mm:ss}  |  Every {1}s' -f $script:lastUpdated, $refreshSeconds
        }
    } catch {
        Show-LimitsUnavailable
        Stop-CodexServer
        $script:deadline = $null
        $script:nextRefresh = [DateTime]::UtcNow.AddSeconds($refreshSeconds)
        $contextStatus.Text = 'Context unavailable'
    }
})

$form.Add_Loaded({
    $area = [Windows.SystemParameters]::WorkArea
    $form.Left = $area.Right - $form.Width - 8
    $form.Top = $area.Top + 8
    $timer.Start()
})
try {
    $null = $form.ShowDialog()
} finally {
    $timer.Stop()
    Stop-CodexServer
}
