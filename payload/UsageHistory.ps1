param()

$ErrorActionPreference = "SilentlyContinue"
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HistoryPath = Join-Path $AppDir "usage_history.csv"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Electricity History"
        Width="650" Height="520"
        WindowStartupLocation="CenterScreen"
        Background="#111318"
        Foreground="White">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="42"/>
            <RowDefinition Height="76"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="28"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="180"/>
                <ColumnDefinition Width="80"/>
            </Grid.ColumnDefinitions>

            <TextBlock Text="ELECTRICITY HISTORY"
                       Foreground="#F0FFFFFF"
                       FontFamily="Segoe UI"
                       FontWeight="Bold"
                       FontSize="18"
                       VerticalAlignment="Center"/>

            <ComboBox x:Name="MonthSelector"
                      Grid.Column="1"
                      Height="28"
                      Margin="0,0,8,0"
                      VerticalContentAlignment="Center"/>

            <Button x:Name="RefreshButton"
                    Grid.Column="2"
                    Height="28"
                    Content="Refresh"/>
        </Grid>

        <Grid Grid.Row="1" Margin="0,4,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="#1EFFFFFF" CornerRadius="8" Padding="12,8">
                <StackPanel>
                    <TextBlock x:Name="MonthLabel" Text="MONTH" Foreground="#8FFFFFFF" FontSize="10"/>
                    <TextBlock x:Name="MonthValue" Text="£0.00" Foreground="White" FontSize="18" FontWeight="Bold"/>
                    <TextBlock x:Name="MonthSub" Text="0.000 kWh • 0.00 h" Foreground="#AFFFFFFF" FontSize="10"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="2" Background="#1EFFFFFF" CornerRadius="8" Padding="12,8">
                <StackPanel>
                    <TextBlock x:Name="YearLabel" Text="YEAR" Foreground="#8FFFFFFF" FontSize="10"/>
                    <TextBlock x:Name="YearValue" Text="£0.00" Foreground="White" FontSize="18" FontWeight="Bold"/>
                    <TextBlock x:Name="YearSub" Text="0.000 kWh • 0.00 h" Foreground="#AFFFFFFF" FontSize="10"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="4" Background="#1EFFFFFF" CornerRadius="8" Padding="12,8">
                <StackPanel>
                    <TextBlock Text="ALL TIME" Foreground="#8FFFFFFF" FontSize="10"/>
                    <TextBlock x:Name="AllValue" Text="£0.00" Foreground="White" FontSize="18" FontWeight="Bold"/>
                    <TextBlock x:Name="AllSub" Text="0.000 kWh • 0.00 h" Foreground="#AFFFFFFF" FontSize="10"/>
                </StackPanel>
            </Border>
        </Grid>

        <ListView x:Name="HistoryList"
                  Grid.Row="2"
                  Background="#171A20"
                  Foreground="#EFFFFFFF"
                  BorderBrush="#30FFFFFF"
                  BorderThickness="1">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="DATE" Width="170" DisplayMemberBinding="{Binding DateText}"/>
                    <GridViewColumn Header="ACTIVE" Width="120" DisplayMemberBinding="{Binding HoursText}"/>
                    <GridViewColumn Header="kWh" Width="120" DisplayMemberBinding="{Binding KWhText}"/>
                    <GridViewColumn Header="COST" Width="140" DisplayMemberBinding="{Binding CostText}"/>
                </GridView>
            </ListView.View>
        </ListView>

        <TextBlock x:Name="Footer"
                   Grid.Row="3"
                   Text="History starts from v1.12.1 installation."
                   Foreground="#70FFFFFF"
                   FontSize="10"
                   VerticalAlignment="Center"/>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$monthSelector = $window.FindName("MonthSelector")
$refreshButton = $window.FindName("RefreshButton")
$monthLabel = $window.FindName("MonthLabel")
$monthValue = $window.FindName("MonthValue")
$monthSub = $window.FindName("MonthSub")
$yearLabel = $window.FindName("YearLabel")
$yearValue = $window.FindName("YearValue")
$yearSub = $window.FindName("YearSub")
$allValue = $window.FindName("AllValue")
$allSub = $window.FindName("AllSub")
$historyList = $window.FindName("HistoryList")
$footer = $window.FindName("Footer")

$script:Rows = @{}

function Load-Rows {
    $script:Rows = @{}

    if (-not (Test-Path $HistoryPath)) { return }

    try {
        foreach ($row in (Import-Csv -LiteralPath $HistoryPath)) {
            if ([string]::IsNullOrWhiteSpace([string]$row.Date)) { continue }

            $script:Rows[[string]$row.Date] = [pscustomobject]@{
                Date = [string]$row.Date
                KWh = [double]$row.KWh
                CostGBP = [double]$row.CostGBP
                Seconds = [double]$row.Seconds
            }
        }
    } catch {}
}

function Get-Totals([string]$Prefix) {
    $kwh = 0.0
    $cost = 0.0
    $seconds = 0.0

    foreach ($key in $script:Rows.Keys) {
        if ([string]::IsNullOrEmpty($Prefix) -or $key.StartsWith($Prefix)) {
            $row = $script:Rows[$key]
            $kwh += [double]$row.KWh
            $cost += [double]$row.CostGBP
            $seconds += [double]$row.Seconds
        }
    }

    return [pscustomobject]@{
        KWh = $kwh
        CostGBP = $cost
        Seconds = $seconds
    }
}

function Refresh-Months {
    $previous = [string]$monthSelector.SelectedValue
    $keys = @((Get-Date).ToString("yyyy-MM"))

    foreach ($key in $script:Rows.Keys) {
        if ($key.Length -ge 7) {
            $keys += $key.Substring(0,7)
        }
    }

    $items = @()

    foreach ($key in ($keys | Sort-Object -Unique -Descending)) {
        try {
            $dt = [DateTime]::ParseExact(
                "$key-01",
                "yyyy-MM-dd",
                [System.Globalization.CultureInfo]::InvariantCulture
            )

            $items += [pscustomobject]@{
                Key = $key
                Label = $dt.ToString("MMMM yyyy", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
            }
        } catch {}
    }

    $monthSelector.DisplayMemberPath = "Label"
    $monthSelector.SelectedValuePath = "Key"
    $monthSelector.ItemsSource = $items

    $available = @($items | ForEach-Object { $_.Key })

    if (-not [string]::IsNullOrWhiteSpace($previous) -and $available -contains $previous) {
        $monthSelector.SelectedValue = $previous
    } else {
        $monthSelector.SelectedValue = (Get-Date).ToString("yyyy-MM")
    }
}

function Refresh-View {
    $monthKey = [string]$monthSelector.SelectedValue

    if ([string]::IsNullOrWhiteSpace($monthKey)) {
        $monthKey = (Get-Date).ToString("yyyy-MM")
    }

    $yearKey = $monthKey.Substring(0,4)

    $m = Get-Totals $monthKey
    $y = Get-Totals $yearKey
    $a = Get-Totals ""

    try {
        $md = [DateTime]::ParseExact(
            "$monthKey-01",
            "yyyy-MM-dd",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $monthLabel.Text = $md.ToString("MMMM yyyy", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
    } catch {
        $monthLabel.Text = $monthKey
    }

    $yearLabel.Text = $yearKey

    $monthValue.Text = ("£{0:0.00}" -f $m.CostGBP)
    $monthSub.Text = ("{0:0.000} kWh  •  {1:0.00} h" -f $m.KWh,($m.Seconds / 3600.0))

    $yearValue.Text = ("£{0:0.00}" -f $y.CostGBP)
    $yearSub.Text = ("{0:0.000} kWh  •  {1:0.00} h" -f $y.KWh,($y.Seconds / 3600.0))

    $allValue.Text = ("£{0:0.00}" -f $a.CostGBP)
    $allSub.Text = ("{0:0.000} kWh  •  {1:0.00} h" -f $a.KWh,($a.Seconds / 3600.0))

    $list = @()

    foreach ($key in ($script:Rows.Keys | Where-Object { $_.StartsWith($monthKey) } | Sort-Object -Descending)) {
        $row = $script:Rows[$key]

        try {
            $d = [DateTime]::ParseExact(
                $key,
                "yyyy-MM-dd",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $dateText = $d.ToString("ddd dd MMM yyyy", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
        } catch {
            $dateText = $key
        }

        $list += [pscustomobject]@{
            DateText = $dateText
            HoursText = ("{0:0.00} h" -f ($row.Seconds / 3600.0))
            KWhText = ("{0:0.000}" -f $row.KWh)
            CostText = ("£{0:0.000}" -f $row.CostGBP)
        }
    }

    $historyList.ItemsSource = $list
    $footer.Text = ("{0} logged day(s) in selected month • auto-saved by the widget every minute" -f $list.Count)
}

$monthSelector.Add_SelectionChanged({
    Refresh-View
})

$refreshButton.Add_Click({
    Load-Rows
    Refresh-Months
    Refresh-View
})

Load-Rows
Refresh-Months
Refresh-View

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(10)
$timer.Add_Tick({
    Load-Rows
    Refresh-Months
    Refresh-View
})
$timer.Start()

$window.Add_Closed({
    try { $timer.Stop() } catch {}
})

[void]$window.ShowDialog()
