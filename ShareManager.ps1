Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:ServerScript = Join-Path $PSScriptRoot 'share_server.ps1'
$script:BackgroundImagePath = Join-Path $PSScriptRoot 'assets\share-manager-background.jpg'
$script:ServerProcess = $null
$script:ShareAddress = $null
$script:SharePassword = $null
$script:LogFile = Join-Path $PSScriptRoot 'share-debug.log'
$script:ErrorFile = Join-Path $PSScriptRoot 'share-errors.log'
$script:ConsoleFile = Join-Path $PSScriptRoot 'share-console.log'
$script:SettingsPath = Join-Path $env:APPDATA 'ShareManager\settings.json'
$script:RememberedPasswordCiphertext = $null
$script:PreferredAddress = $null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Общее хранилище" Width="1120" Height="820"
        MinWidth="930" MinHeight="700" WindowStartupLocation="CenterScreen"
        Foreground="#E8EEF8" FontFamily="Segoe UI">
  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#0A1120" Offset="0"/>
      <GradientStop Color="#111D31" Offset="0.58"/>
      <GradientStop Color="#101827" Offset="1"/>
    </LinearGradientBrush>
  </Window.Background>
  <Window.Resources>
    <SolidColorBrush x:Key="CardBrush" Color="#E6131E31"/>
    <SolidColorBrush x:Key="SoftBrush" Color="#E61C2A40"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#94A3B8"/>
    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="#26354D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="17"/>
      <Setter Property="Padding" Value="21"/>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect Color="#000000" Opacity="0.2" BlurRadius="22" ShadowDepth="4"/>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E8EEF8"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0B1423"/>
      <Setter Property="Foreground" Value="#F1F5F9"/>
      <Setter Property="BorderBrush" Value="#30435E"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="#0B1423"/>
      <Setter Property="Foreground" Value="#F1F5F9"/>
      <Setter Property="BorderBrush" Value="#30435E"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="14"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#0B1423"/>
      <Setter Property="Foreground" Value="#F1F5F9"/>
      <Setter Property="BorderBrush" Value="#30435E"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="DropDownToggle" Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
                      <Grid>
                        <ContentPresenter Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                          ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                          Margin="{Binding Padding, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                          TextElement.Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                          VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        <TextBlock Text="⌄" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="Popup" Placement="Bottom" PlacementTarget="{Binding ElementName=DropDownToggle}"
                     IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False"
                     PopupAnimation="Fade">
                <Border x:Name="PopupBorder" Background="#131E31" BorderBrush="#30435E" BorderThickness="1"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer SnapsToDevicePixels="True">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="HasItems" Value="False">
                <Setter TargetName="PopupBorder" Property="MinHeight" Value="24"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="DropDownToggle" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#94A3B8"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#F8FAFC"/>
      <Setter Property="Background" Value="#263852"/>
      <Setter Property="BorderBrush" Value="#324762"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonSurface" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonSurface" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonSurface" Property="Opacity" Value="0.72"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ButtonSurface" Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="70"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="246"/>
      <RowDefinition Height="116"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="43" Height="43" CornerRadius="13" Background="#D926385A" BorderBrush="#B33C5686" BorderThickness="1" Margin="0,0,13,0">
          <TextBlock Text="↥" Foreground="#AFC2FF" FontSize="25" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-3,0,0"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="ОБЩЕЕ ХРАНИЛИЩЕ" FontSize="19" FontWeight="Bold"/>
          <TextBlock Text="Обмен файлами через Radmin VPN" Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="1,3,0,0"/>
        </StackPanel>
      </StackPanel>
      <Border Grid.Column="1" Background="#17253A" BorderBrush="#2A3A51" BorderThickness="1" CornerRadius="18" Padding="13,8" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#64748B" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="StatusText" Text="Сервер остановлен" FontSize="12" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
    </Grid>
    <Grid Grid.Row="1" Margin="0,0,0,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="1.08*"/><ColumnDefinition Width="0.92*"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Style="{StaticResource CardStyle}" Margin="0,0,8,0">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel>
            <TextBlock Text="Как подключить друзей" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock Text="Поделитесь доступом за пару шагов" Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="0,4,0,0"/>
          </StackPanel>
          <StackPanel Grid.Row="1" Margin="0,15,0,8">
            <TextBlock Text="01   Подключитесь с друзьями к одной сети Radmin VPN." FontSize="13" Margin="0,0,0,13"/>
            <TextBlock Text="02   Выберите свой VPN-адрес в настройках ниже и нажмите «Запустить хранилище»." FontSize="13" Margin="0,0,0,13"/>
            <TextBlock Text="03   Отправьте друзьям ссылку и пароль. Им нужно открыть ссылку в браузере." FontSize="13"/>
          </StackPanel>
          <Border Grid.Row="2" Background="#0B1423" CornerRadius="10" Padding="13">
            <StackPanel>
              <TextBlock Text="ССЫЛКА ДЛЯ ДРУЗЕЙ" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold" Margin="0,0,0,7"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="AddressBox" Text="Запустите сервер, чтобы получить ссылку" IsReadOnly="True" BorderThickness="0" Background="#0B1423" Foreground="#F1F5F9" Padding="8,5" FontSize="13"/>
                <Button x:Name="CopyButton" Grid.Column="1" Content="Копировать" Padding="11,7" Background="#263852" IsEnabled="False"/>
              </Grid>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
      <Border Grid.Column="1" Style="{StaticResource CardStyle}" Padding="20" Margin="8,0,0,0">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="Подключённые устройства" FontSize="18" FontWeight="SemiBold"/>
              <TextBlock x:Name="DeviceSummary" Text="Ожидание подключений" Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="0,4,0,0"/>
            </StackPanel>
            <Border Grid.Column="1" Background="#203D43" CornerRadius="14" Padding="9,4" VerticalAlignment="Top">
              <TextBlock x:Name="DeviceCount" Text="0" Foreground="#7DE2C3" FontSize="12" FontWeight="Bold"/>
            </Border>
          </Grid>
          <ListBox x:Name="DeviceList" Grid.Row="1" Margin="0,14,0,8" Background="Transparent" BorderThickness="0" Foreground="#E8EEF8" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Padding" Value="0"/>
                <Setter Property="Margin" Value="0,0,0,7"/>
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Focusable" Value="False"/>
              </Style>
            </ListBox.ItemContainerStyle>
          </ListBox>
          <TextBlock Grid.Row="2" Text="Устройство считается активным, если обращалось к серверу за последние 2 минуты." Foreground="{StaticResource MutedBrush}" FontSize="10"/>
        </Grid>
      </Border>
    </Grid>
    <Border Grid.Row="2" Style="{StaticResource CardStyle}" Padding="18" Margin="0,0,0,14">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock Text="Настройки хранилища" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="1.2*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Margin="0,0,14,0">
            <TextBlock Text="Адрес Radmin VPN" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,5"/>
            <ComboBox x:Name="AddressPicker" Height="37" Background="#0B1423" Foreground="#F1F5F9">
              <ComboBox.ItemContainerStyle>
                <Style TargetType="ComboBoxItem">
                  <Setter Property="Foreground" Value="#E8EEF8"/>
                  <Setter Property="Background" Value="#131E31"/>
                  <Setter Property="Padding" Value="8,6"/>
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                          <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="ItemBorder" Property="Background" Value="#263852"/>
                          </Trigger>
                          <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="ItemBorder" Property="Background" Value="#263852"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                </Style>
              </ComboBox.ItemContainerStyle>
            </ComboBox>
            <Button x:Name="RefreshAddressesButton" Content="Обновить список адресов" HorizontalAlignment="Left" Padding="0" Margin="0,6,0,0" Background="Transparent" Foreground="#66C8F2" FontSize="11"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="0,0,14,0">
            <TextBlock Text="Папка для файлов" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,5"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="StorageBox" Height="37" VerticalContentAlignment="Center"/>
              <Button x:Name="BrowseButton" Grid.Column="1" Content="Обзор" Padding="11,7" Margin="6,0,0,0"/>
            </Grid>
            <TextBlock Text="Файлы сохраняются в этой папке." Foreground="{StaticResource MutedBrush}" FontSize="10" Margin="0,5,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Text="Лимит места (ГБ)" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,5"/>
            <TextBox x:Name="QuotaBox" Text="10" Height="37" VerticalContentAlignment="Center"/>
            <TextBlock Text="Пароль для друзей" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="0,11,0,5"/>
            <PasswordBox x:Name="PasswordBox" Height="37"/>
            <CheckBox x:Name="RememberPasswordBox" Content="Запомнить пароль на этом компьютере"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="2" Margin="0,11,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="SettingsHint" Text="Пароль передаётся только друзьям из вашей VPN-сети." Foreground="{StaticResource MutedBrush}" FontSize="10" VerticalAlignment="Center"/>
          <Button x:Name="StopButton" Grid.Column="1" Content="Остановить" Background="#482B35" IsEnabled="False" Margin="0,0,8,0"/>
          <Button x:Name="StartButton" Grid.Column="2" Content="Запустить хранилище" Background="#147D70" FontWeight="SemiBold" Padding="18,9"/>
        </Grid>
      </Grid>
    </Border>
    <Border Grid.Row="3" Style="{StaticResource CardStyle}" Padding="14">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="ЖУРНАЛ РАБОТЫ" FontSize="10" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
          <TextBlock x:Name="LogHint" Grid.Column="1" Text="Ошибки и события сервера" FontSize="10" Foreground="{StaticResource MutedBrush}"/>
        </Grid>
        <TextBox x:Name="LogBox" Grid.Row="1" Margin="0,7,0,0" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#0A111D" BorderThickness="0" FontFamily="Consolas" FontSize="10" Padding="8"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
$backgroundBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$backgroundBitmap.BeginInit()
$backgroundBitmap.UriSource = New-Object System.Uri($script:BackgroundImagePath, [System.UriKind]::Absolute)
$backgroundBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$backgroundBitmap.EndInit()
$backgroundBitmap.Freeze()
$backgroundBrush = New-Object System.Windows.Media.ImageBrush($backgroundBitmap)
$backgroundBrush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
$backgroundBrush.AlignmentX = [System.Windows.Media.AlignmentX]::Right
$script:Window.Background = $backgroundBrush
foreach ($name in @('StatusDot','StatusText','AddressBox','CopyButton','DeviceSummary','DeviceCount','DeviceList','AddressPicker','RefreshAddressesButton','StorageBox','BrowseButton','QuotaBox','PasswordBox','RememberPasswordBox','SettingsHint','StopButton','StartButton','LogBox','LogHint')) {
    Set-Variable -Scope Script -Name $name -Value $script:Window.FindName($name)
}

$script:StorageBox.Text = Join-Path $PSScriptRoot 'SharedFiles'
$script:LogBox.Text = 'Готово к запуску. Выберите Radmin VPN-адрес, задайте пароль и лимит места.'
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(4)
$script:DeviceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeviceTimer.Interval = [TimeSpan]::FromSeconds(8)
$script:AddressTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AddressTimer.Interval = [TimeSpan]::FromSeconds(5)

function Get-RadminAddresses {
    $result = @()
    foreach ($network in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($network.Name -notmatch 'Radmin' -and $network.Description -notmatch 'Radmin') {
            continue
        }
        foreach ($address in $network.GetIPProperties().UnicastAddresses) {
            if ($address.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not [System.Net.IPAddress]::IsLoopback($address.Address)) {
                $result += $address.Address.ToString()
            }
        }
    }
    return @($result | Sort-Object -Unique)
}

function Update-AddressChoices {
    $previous = [string]$script:AddressPicker.SelectedItem
    $script:AddressPicker.Items.Clear()
    try {
        $addresses = @(Get-RadminAddresses)
    }
    catch {
        [void]$script:AddressPicker.Items.Add('Не удалось прочитать сетевые адреса')
        $script:AddressPicker.SelectedIndex = 0
        $script:SettingsHint.Text = 'Ошибка чтения сетевых адресов: ' + $_.Exception.Message
        return
    }
    foreach ($address in $addresses) {
        [void]$script:AddressPicker.Items.Add($address)
    }
    if ($addresses.Count -gt 0) {
        if ($previous -and $addresses -contains $previous) {
            $script:AddressPicker.SelectedItem = $previous
        }
        elseif ($script:PreferredAddress -and $addresses -contains $script:PreferredAddress) {
            $script:AddressPicker.SelectedItem = $script:PreferredAddress
        }
        else {
            $script:AddressPicker.SelectedIndex = 0
        }
        $script:SettingsHint.Text = 'Найден адрес Radmin VPN: ' + ($addresses -join ', ')
    }
    else {
        [void]$script:AddressPicker.Items.Add('Radmin VPN не найден')
        $script:AddressPicker.SelectedIndex = 0
        $script:SettingsHint.Text = 'Подключитесь к Radmin VPN, затем обновите список адресов.'
    }
}

function Set-ServerStatus {
    param([bool]$Running, [string]$Message)

    $script:StatusText.Text = $Message
    if ($Running) {
        $script:StatusDot.Fill = [System.Windows.Media.Brushes]::MediumSeaGreen
    }
    else {
        $script:StatusDot.Fill = [System.Windows.Media.Brushes]::SlateGray
    }
    $script:StartButton.IsEnabled = -not $Running
    $script:StopButton.IsEnabled = $Running
    $script:AddressPicker.IsEnabled = -not $Running
    $script:QuotaBox.IsEnabled = -not $Running
    $script:StorageBox.IsEnabled = -not $Running
    $script:BrowseButton.IsEnabled = -not $Running
    $script:PasswordBox.IsEnabled = -not $Running
    $script:RememberPasswordBox.IsEnabled = -not $Running
    $script:RefreshAddressesButton.IsEnabled = -not $Running
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return
    }
    try {
        $settings = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8))
        if ($settings.StoragePath) {
            $script:StorageBox.Text = [string]$settings.StoragePath
        }
        if ($settings.MaxGB) {
            $script:QuotaBox.Text = [string]$settings.MaxGB
        }
        if ($settings.RadminAddress -match '^(?:\d{1,3}\.){3}\d{1,3}$') {
            $script:PreferredAddress = [string]$settings.RadminAddress
        }
        if ($settings.RememberPassword -and $settings.EncryptedPassword) {
            $securePassword = ConvertTo-SecureString -String ([string]$settings.EncryptedPassword)
            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
            try {
                $script:PasswordBox.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
            }
            $script:RememberPasswordBox.IsChecked = $true
            $script:RememberedPasswordCiphertext = [string]$settings.EncryptedPassword
        }
    }
    catch {
        $message = 'Не удалось прочитать сохранённые настройки: ' + $_.Exception.Message
        $script:SettingsHint.Text = $message
        $script:LogBox.Text = $message
    }
}

function Save-Settings {
    $encryptedPassword = $script:RememberedPasswordCiphertext
    $rememberPassword = [bool]$script:RememberPasswordBox.IsChecked
    if ($rememberPassword) {
        $password = $script:PasswordBox.Password
        if (-not [string]::IsNullOrWhiteSpace($password)) {
            $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
            $encryptedPassword = ConvertFrom-SecureString -SecureString $securePassword
        }
    }
    else {
        $encryptedPassword = $null
    }

    $address = [string]$script:AddressPicker.SelectedItem
    if ($address -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') {
        $address = $script:PreferredAddress
    }
    $settings = @{
        StoragePath = $script:StorageBox.Text
        MaxGB = $script:QuotaBox.Text
        RadminAddress = $address
        RememberPassword = $rememberPassword
        EncryptedPassword = $encryptedPassword
    }
    $settingsDirectory = Split-Path -Parent $script:SettingsPath
    if (-not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $settings -Depth 3
    [IO.File]::WriteAllText($script:SettingsPath, $json, [Text.UTF8Encoding]::new($false))
    $script:RememberedPasswordCiphertext = $encryptedPassword
}

function Add-DeviceCard {
    param([string]$Address, [string]$LastSeen, [bool]$Online)

    $panel = New-Object System.Windows.Controls.Grid
    $panel.Margin = '0'
    $panel.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $panel.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    $labels = New-Object System.Windows.Controls.StackPanel
    $labels.Children.Add((New-Object System.Windows.Controls.TextBlock -Property @{ Text = $Address; FontSize = 13; FontWeight = 'SemiBold' })) | Out-Null
    $labels.Children.Add((New-Object System.Windows.Controls.TextBlock -Property @{ Text = 'Radmin VPN'; FontSize = 10; Foreground = [System.Windows.Media.Brushes]::LightSlateGray; Margin = '0,2,0,0' })) | Out-Null
    $panel.Children.Add($labels) | Out-Null
    $badge = New-Object System.Windows.Controls.TextBlock
    $badge.Text = if ($Online) { '● В сети' } else { 'Был(а) в ' + $LastSeen }
    $badge.Foreground = if ($Online) { [System.Windows.Media.Brushes]::MediumAquamarine } else { [System.Windows.Media.Brushes]::LightSlateGray }
    $badge.FontSize = 10
    $badge.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($badge, 1)
    $panel.Children.Add($badge) | Out-Null
    $card = New-Object System.Windows.Controls.Border
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1A2940')
    $card.CornerRadius = '8'
    $card.Padding = '11,8'
    $card.Child = $panel
    [void]$script:DeviceList.Items.Add($card)
}

function Update-LogView {
    $lines = @()
    if (Test-Path -LiteralPath $script:LogFile) {
        $lines += Get-Content -LiteralPath $script:LogFile -Tail 7 -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:ErrorFile) {
        $errorLines = @(Get-Content -LiteralPath $script:ErrorFile -Tail 4 -ErrorAction SilentlyContinue)
        if ($errorLines.Count -gt 0) {
            $lines += $errorLines | ForEach-Object { 'ОШИБКА: ' + $_ }
        }
    }
    if ($lines.Count -gt 0) {
        $script:LogBox.Text = ($lines -join [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
    }
}

function Update-DeviceView {
    if ($null -eq $script:ServerProcess -or $script:ServerProcess.HasExited -or
        [string]::IsNullOrWhiteSpace($script:ShareAddress) -or [string]::IsNullOrWhiteSpace($script:SharePassword)) {
        $script:DeviceList.Items.Clear()
        $script:DeviceCount.Text = '0'
        $script:DeviceSummary.Text = 'Ожидание подключений'
        return
    }
    try {
        $credential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('manager:' + $script:SharePassword))
        $request = [Net.HttpWebRequest]::Create($script:ShareAddress.TrimEnd('/') + '/api/devices')
        $request.Method = 'GET'
        $request.Timeout = 700
        $request.ReadWriteTimeout = 700
        $request.Headers.Add('Authorization', 'Basic ' + $credential)
        $response = $request.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $data = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally {
            $response.Dispose()
        }
        $result = ConvertFrom-Json -InputObject $data
        $script:DeviceList.Items.Clear()
        foreach ($device in $result.devices) {
            Add-DeviceCard -Address $device.address -LastSeen $device.lastSeen -Online ([bool]$device.online)
        }
        $count = @($result.devices).Count
        $script:DeviceCount.Text = [string]$count
        if ($count -eq 0) {
            $script:DeviceSummary.Text = 'Пока никто не подключался'
        }
        else {
            $script:DeviceSummary.Text = 'Устройства, недавно обращавшиеся к хранилищу'
        }
        $script:LogHint.Text = 'Ошибки и события сервера'
    }
    catch {
        $script:DeviceSummary.Text = 'Не удалось обновить список устройств'
        $script:LogHint.Text = $_.Exception.Message
    }
}

$script:Timer.Add_Tick({
    if ($null -ne $script:ServerProcess) {
        try {
            $script:ServerProcess.Refresh()
            if ($script:ServerProcess.HasExited) {
                Set-ServerStatus -Running $false -Message 'Сервер остановлен'
                $script:ShareAddress = $null
                $script:SharePassword = $null
                $script:Timer.Stop()
                $script:DeviceTimer.Stop()
                $script:AddressBox.Text = 'Сервер остановлен'
                $script:CopyButton.IsEnabled = $false
                $script:ServerProcess.Dispose()
                $script:ServerProcess = $null
                Update-LogView
            }
        }
        catch {
            Set-ServerStatus -Running $false -Message 'Не удалось проверить сервер'
        }
    }
    Update-LogView
})
$script:DeviceTimer.Add_Tick({ Update-DeviceView })
$script:AddressTimer.Add_Tick({
    if ($null -eq $script:ServerProcess -and -not $script:AddressPicker.IsDropDownOpen) {
        Update-AddressChoices
    }
})

$script:RefreshAddressesButton.Add_Click({ Update-AddressChoices })
$script:RememberPasswordBox.Add_Click({
    try {
        Save-Settings
    }
    catch {
        [System.Windows.MessageBox]::Show('Не удалось сохранить настройки: ' + $_.Exception.Message, 'Ошибка', 'OK', 'Error') | Out-Null
    }
})
$script:BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку для общего файлового хранилища'
    $dialog.SelectedPath = $script:StorageBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:StorageBox.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
})
$script:CopyButton.Add_Click({
    if ($script:ShareAddress) {
        [System.Windows.Clipboard]::SetText($script:ShareAddress)
        $script:CopyButton.Content = 'Скопировано'
    }
})
$script:StartButton.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:ServerScript -PathType Leaf)) {
            throw 'Не найден файл share_server.ps1 рядом с программой.'
        }
        $selectedAddress = [string]$script:AddressPicker.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selectedAddress) -or $selectedAddress -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') {
            throw 'Сначала подключитесь к Radmin VPN и выберите VPN-адрес.'
        }
        [double]$quota = 0
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $quotaText = $script:QuotaBox.Text.Replace(',', '.')
        if (-not [double]::TryParse($quotaText, [Globalization.NumberStyles]::AllowDecimalPoint, $culture, [ref]$quota) -or $quota -lt 0.01 -or $quota -gt 100000) {
            throw 'Введите лимит от 0,01 до 100000 ГБ.'
        }
        $password = $script:PasswordBox.Password
        if ([string]::IsNullOrWhiteSpace($password)) {
            throw 'Придумайте пароль для друзей.'
        }
        if ([string]::IsNullOrWhiteSpace($script:StorageBox.Text)) {
            throw 'Укажите папку для файлов.'
        }
        $storage = [IO.Path]::GetFullPath($script:StorageBox.Text)
        if (-not (Test-Path -LiteralPath $storage -PathType Container)) {
            New-Item -ItemType Directory -Path $storage -Force | Out-Null
        }
        $script:StorageBox.Text = $storage
        Save-Settings

        $script:ErrorFile = Join-Path $PSScriptRoot 'share-errors.log'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port 8765 -BindAddress "{1}" -MaxGB {2} -DebugMode' -f $script:ServerScript, $selectedAddress, $quota.ToString($culture)
        $env:HOUSE_SHARE_PASSWORD = $password
        $env:HOUSE_SHARE_STORAGE = $storage
        try {
            $script:ServerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:ConsoleFile -RedirectStandardError $script:ErrorFile
        }
        finally {
            Remove-Item Env:\HOUSE_SHARE_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item Env:\HOUSE_SHARE_STORAGE -ErrorAction SilentlyContinue
        }
        $script:SharePassword = $password
        $script:ShareAddress = 'http://' + $selectedAddress + ':8765/'
        $script:AddressBox.Text = $script:ShareAddress
        $script:CopyButton.Content = 'Копировать'
        $script:CopyButton.IsEnabled = $true
        $script:PasswordBox.Clear()
        Set-ServerStatus -Running $true -Message 'Запуск сервера…'
        $script:Timer.Start()
        $script:DeviceTimer.Start()
        Update-LogView
    }
    catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Не удалось запустить хранилище', 'OK', 'Warning') | Out-Null
    }
})
$script:StopButton.Add_Click({
    if ($null -ne $script:ServerProcess) {
        try {
            if (-not $script:ServerProcess.HasExited) {
                $script:ServerProcess.Kill()
                $script:ServerProcess.WaitForExit(3000) | Out-Null
            }
        }
        catch {
            [System.Windows.MessageBox]::Show('Не удалось остановить сервер: ' + $_.Exception.Message, 'Ошибка', 'OK', 'Error') | Out-Null
        }
        $script:ServerProcess.Dispose()
        $script:ServerProcess = $null
    }
    $script:Timer.Stop()
    $script:DeviceTimer.Stop()
    $script:ShareAddress = $null
    $script:SharePassword = $null
    $script:AddressBox.Text = 'Сервер остановлен'
    $script:CopyButton.IsEnabled = $false
    $script:DeviceList.Items.Clear()
    $script:DeviceCount.Text = '0'
    $script:DeviceSummary.Text = 'Ожидание подключений'
    Set-ServerStatus -Running $false -Message 'Сервер остановлен'
    Update-LogView
})
$script:Window.Add_Closed({
    $script:AddressTimer.Stop()
    $script:Timer.Stop()
    $script:DeviceTimer.Stop()
    try {
        Save-Settings
    }
    catch {
        [System.Windows.MessageBox]::Show('Не удалось сохранить настройки: ' + $_.Exception.Message, 'Ошибка', 'OK', 'Error') | Out-Null
    }
    if ($null -ne $script:ServerProcess) {
        try {
            if (-not $script:ServerProcess.HasExited) {
                $script:ServerProcess.Kill()
                $script:ServerProcess.WaitForExit(3000) | Out-Null
            }
        }
        catch { }
        $script:ServerProcess.Dispose()
        $script:ServerProcess = $null
    }
})

Load-Settings
Update-AddressChoices
$script:AddressTimer.Start()
$script:Window.ShowDialog() | Out-Null
