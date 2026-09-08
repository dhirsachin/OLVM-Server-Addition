$script:MainWindowXamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OLVM Server Addition"
        Height="820" Width="1160" MinHeight="700" MinWidth="900"
        WindowStartupLocation="Manual" WindowStyle="SingleBorderWindow"
        ResizeMode="CanMinimize" ShowInTaskbar="True" AllowsTransparency="False"
        UseLayoutRounding="True" FontFamily="Segoe UI" FontSize="13"
        Background="#F4F6F8"
        ToolTipService.ShowDuration="30000">
 <Grid Name="MainLayout" Margin="8" MaxWidth="1160" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="*"/>
  </Grid.RowDefinitions>
  <Grid.Resources>
   <Style TargetType="GroupBox">
    <Setter Property="Margin" Value="0,0,0,4"/>
    <Setter Property="Padding" Value="5"/>
    <Setter Property="Background" Value="White"/>
    <Setter Property="BorderBrush" Value="#C9D2DC"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="#1F2933"/>
   </Style>
   <Style TargetType="Button">
    <Setter Property="Padding" Value="12,5"/>
    <Setter Property="Margin" Value="0,0,10,0"/>
    <Setter Property="MinHeight" Value="28"/>
    <Setter Property="Background" Value="#F7F8FA"/>
    <Setter Property="BorderBrush" Value="#9FAAB6"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="#1F2933"/>
   </Style>
   <Style TargetType="ComboBox">
    <Setter Property="MinHeight" Value="28"/>
    <Setter Property="BorderBrush" Value="#9FAAB6"/>
   </Style>
   <Style TargetType="TextBox">
    <Setter Property="MinHeight" Value="28"/>
    <Setter Property="BorderBrush" Value="#9FAAB6"/>
   </Style>
   <Style x:Key="SegmentRadioButton" TargetType="RadioButton">
    <Setter Property="MinHeight" Value="28"/>
    <Setter Property="Padding" Value="8,2"/>
    <Setter Property="Background" Value="White"/>
    <Setter Property="BorderBrush" Value="#9FAAB6"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="#202020"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
     <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
       <Border Name="ChoiceBorder" Background="{TemplateBinding Background}"
               BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
               CornerRadius="2" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                          RecognizesAccessKey="True"/>
       </Border>
       <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
         <Setter TargetName="ChoiceBorder" Property="Background" Value="#EAF3FB"/>
         <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#5B9BD5"/>
        </Trigger>
        <Trigger Property="IsChecked" Value="True">
         <Setter TargetName="ChoiceBorder" Property="Background" Value="#176B98"/>
         <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#125878"/>
         <Setter Property="Foreground" Value="White"/>
         <Setter Property="FontWeight" Value="SemiBold"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
         <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#003B5C"/>
         <Setter TargetName="ChoiceBorder" Property="BorderThickness" Value="2"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
         <Setter Property="Opacity" Value="0.55"/>
        </Trigger>
       </ControlTemplate.Triggers>
      </ControlTemplate>
     </Setter.Value>
   </Setter>
   </Style>
   <!-- Keep paired choices visually separate without adding outside padding. -->
   <Style x:Key="FirstSegmentRadioButton" TargetType="RadioButton" BasedOn="{StaticResource SegmentRadioButton}">
    <Setter Property="Margin" Value="0,0,2,0"/>
   </Style>
   <Style x:Key="SecondSegmentRadioButton" TargetType="RadioButton" BasedOn="{StaticResource SegmentRadioButton}">
    <Setter Property="Margin" Value="2,0,0,0"/>
   </Style>
   <Style x:Key="InfoButton" TargetType="Button">
    <Setter Property="Content" Value="i"/>
    <Setter Property="Width" Value="14"/>
    <Setter Property="Height" Value="14"/>
    <Setter Property="MinWidth" Value="14"/>
    <Setter Property="MinHeight" Value="14"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="Margin" Value="4,0,0,0"/>
    <Setter Property="Background" Value="#F7F8FA"/>
    <Setter Property="BorderBrush" Value="#8E9AA6"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="#45647E"/>
    <Setter Property="FontSize" Value="9"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Focusable" Value="True"/>
    <Setter Property="Cursor" Value="Help"/>
    <Setter Property="Template">
     <Setter.Value>
      <ControlTemplate TargetType="Button">
       <Border Name="InfoCircle" CornerRadius="7"
               Background="{TemplateBinding Background}"
               BorderBrush="{TemplateBinding BorderBrush}"
               BorderThickness="{TemplateBinding BorderThickness}"
               SnapsToDevicePixels="True">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                          RecognizesAccessKey="True"/>
       </Border>
       <ControlTemplate.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
         <Setter TargetName="InfoCircle" Property="BorderBrush" Value="#003B5C"/>
         <Setter TargetName="InfoCircle" Property="BorderThickness" Value="2"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
         <Setter TargetName="InfoCircle" Property="Background" Value="#D8E6F0"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
         <Setter Property="Opacity" Value="0.55"/>
        </Trigger>
       </ControlTemplate.Triggers>
      </ControlTemplate>
     </Setter.Value>
    </Setter>
    <Style.Triggers>
     <Trigger Property="IsMouseOver" Value="True">
      <Setter Property="Background" Value="#E8F0F6"/>
      <Setter Property="BorderBrush" Value="#47738F"/>
      <Setter Property="Foreground" Value="#0F5F8C"/>
     </Trigger>
    </Style.Triggers>
   </Style>
  </Grid.Resources>

  <Grid Grid.Row="0" Name="HeaderPanel" Width="1120" HorizontalAlignment="Center" Margin="0,0,0,4">
   <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
   <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
    <TextBlock Text="OLVM Server Addition" FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center"/>
    <Button Style="{StaticResource InfoButton}" Margin="8,0,0,0"
            AutomationProperties.Name="Provisioning workflow information">
     <Button.ToolTip>
      <TextBlock MaxWidth="420" TextWrapping="Wrap"
                 Text="Workflow: read the MAC from OLVM; create a PVS entry; assign a vDisk; add the Reboot personality; create a DHCP entry and AD machine account; verify the state; and power on the servers."/>
     </Button.ToolTip>
    </Button>
   </StackPanel>
   <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
    <Label Content="OLVM Manager (Optional)" Padding="0" VerticalAlignment="Center" Target="{Binding ElementName=OlvmManager}"/>
    <Button Style="{StaticResource InfoButton}" ToolTip="Select a preferred OLVM Manager to speed up Validation. If it cannot be queried or does not return an exact VM, Validation automatically falls back to Auto-detect."/>
    <ComboBox Name="OlvmManager" Width="340" Margin="8,0,0,0" DisplayMemberPath="Display"
              AutomationProperties.HelpText="Optional preferred OLVM Manager for the complete batch. An unsuccessful initial lookup automatically falls back to Auto-detect; Auto-detect remains recommended for mixed or unknown Manager batches.">
     <ComboBox.ItemContainerStyle>
      <Style TargetType="ComboBoxItem">
       <Setter Property="IsEnabled" Value="{Binding IsAvailable}"/>
       <Setter Property="ToolTip" Value="{Binding AvailabilityMessage}"/>
      </Style>
     </ComboBox.ItemContainerStyle>
    </ComboBox>
   </StackPanel>
  </Grid>

  <GroupBox Grid.Row="1" Name="ProvisioningSettingsGroup" Header="1. Provisioning settings" Width="1120" HorizontalAlignment="Center">
   <UniformGrid Name="ProvisioningSettingsLayout" Rows="2" Columns="3" Width="1080" Margin="2" HorizontalAlignment="Center">

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="Device Collection" Padding="0" Target="{Binding ElementName=Collection}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Select the Citrix PVS site and device collection where every new target will be created."/>
     </StackPanel>
     <ComboBox Name="Collection" DisplayMemberPath="Display" Margin="0,3,0,0" AutomationProperties.HelpText="Select the destination PVS site and collection."/>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="Assign Image (Optional)" Padding="0" Target="{Binding ElementName=AssignImageYes}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Choose Yes to enable PVS Store and assign a vDisk to every target in this batch. Choose No to create targets without a vDisk mapping."/>
     </StackPanel>
     <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
      <RadioButton Name="AssignImageYes" GroupName="AssignImageGroup" Content="Yes"
                   Style="{StaticResource FirstSegmentRadioButton}"
                   AutomationProperties.HelpText="Assign one selected Production-ready PVS image to every target in this batch."/>
      <RadioButton Name="AssignImageNo" GroupName="AssignImageGroup" Content="No" IsChecked="True"
                   Style="{StaticResource SecondSegmentRadioButton}"
                   AutomationProperties.HelpText="Create and verify the PVS targets without assigning a vDisk. This is the default."/>
     </UniformGrid>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="PVS Store (Optional)" Padding="0" Target="{Binding ElementName=PvsStore}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="After selecting Yes for Assign Image, choose the PVS Store that contains the batch vDisk."/>
     </StackPanel>
     <ComboBox Name="PvsStore" DisplayMemberPath="Display" IsEnabled="False" HorizontalAlignment="Stretch" Margin="0,3,0,0"
               ToolTip="Select Yes for Assign Image to enable this list."
               ToolTipService.ShowOnDisabled="True"
               AutomationProperties.HelpText="Disabled until Assign Image is Yes and a Device Collection is selected. Then choose the Store containing the batch vDisk."/>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="vDisk (Optional)" Padding="0" Target="{Binding ElementName=PvsImage}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="When Assign Image is Yes and a PVS Store is selected, choose a vDisk from the list for the batch."/>
     </StackPanel>
     <ComboBox Name="PvsImage" DisplayMemberPath="Name" IsEnabled="False" Margin="0,3,0,0"
               ToolTip="Select Yes for Assign Image and choose a PVS Store first."
               ToolTipService.ShowOnDisabled="True"
               AutomationProperties.HelpText="Select one Production-ready vDisk. The immutable DiskLocator ID and readiness snapshot are retained internally."/>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="Boot Type" Padding="0" Target="{Binding ElementName=BootBios}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Choose how this VDA boots. BIOS uses ardbp32.bin. UEFI x64 uses pvsnbpx64.efi."/>
     </StackPanel>
     <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
      <RadioButton Name="BootBios" GroupName="BootModeGroup" Content="BIOS (Legacy)"
                   Style="{StaticResource FirstSegmentRadioButton}"
                   AutomationProperties.HelpText="Use BIOS Legacy boot with DHCP option 67 value ardbp32.bin."/>
      <RadioButton Name="BootUefi" GroupName="BootModeGroup" Content="UEFI (x64)"
                   Style="{StaticResource SecondSegmentRadioButton}"
                   AutomationProperties.HelpText="Use UEFI x64 boot with DHCP option 67 value pvsnbpx64.efi."/>
     </UniformGrid>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="Power On (Optional)" Padding="0" Target="{Binding ElementName=PowerOnYes}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Successfully built servers will be powered on after the build."/>
     </StackPanel>
     <Border ToolTip="Available only after a PVS image is selected. No is the safe default."
             ToolTipService.ShowOnDisabled="True">
      <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
       <RadioButton Name="PowerOnYes" GroupName="PowerOnAfterBuildGroup" Content="Yes" IsEnabled="False"
                    Style="{StaticResource FirstSegmentRadioButton}"
                    AutomationProperties.HelpText="After all build operations finish, power on CreatedAndVerified VMs and any AD-warning VM explicitly approved after final non-AD verification."/>
       <RadioButton Name="PowerOnNo" GroupName="PowerOnAfterBuildGroup" Content="No" IsChecked="True" IsEnabled="False"
                    Style="{StaticResource SecondSegmentRadioButton}"
                    AutomationProperties.HelpText="Do not power on VMs after the build. This is the default."/>
      </UniformGrid>
     </Border>
    </StackPanel>
   </UniformGrid>
  </GroupBox>

  <GroupBox Grid.Row="2" Name="NamingSettingsGroup" Header="2. Server naming settings" Width="1120" HorizontalAlignment="Center">
   <UniformGrid Name="NamingSettingsLayout" Rows="1" Columns="3" Width="1080" Margin="2" HorizontalAlignment="Left">
    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="PVS target-name case" Padding="0" Target="{Binding ElementName=PvsCaseUpper}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Choose whether the target name is created in PVS using uppercase or lowercase."/>
     </StackPanel>
     <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
      <RadioButton Name="PvsCaseUpper" GroupName="PvsNameCaseGroup" Content="Upper"
                   Style="{StaticResource FirstSegmentRadioButton}"
                   AutomationProperties.HelpText="Create the PVS target name in uppercase."/>
      <RadioButton Name="PvsCaseLower" GroupName="PvsNameCaseGroup" Content="Lower"
                   Style="{StaticResource SecondSegmentRadioButton}"
                   AutomationProperties.HelpText="Create the PVS target name in lowercase."/>
     </UniformGrid>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="DHCP reservation-name case" Padding="0" Target="{Binding ElementName=DhcpCaseUpper}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Choose the letter case used only for the DHCP reservation display name."/>
     </StackPanel>
     <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
      <RadioButton Name="DhcpCaseUpper" GroupName="DhcpNameCaseGroup" Content="Upper"
                   Style="{StaticResource FirstSegmentRadioButton}"
                   AutomationProperties.HelpText="Display the DHCP reservation name in uppercase."/>
      <RadioButton Name="DhcpCaseLower" GroupName="DhcpNameCaseGroup" Content="Lower"
                   Style="{StaticResource SecondSegmentRadioButton}"
                   AutomationProperties.HelpText="Display the DHCP reservation name in lowercase."/>
     </UniformGrid>
    </StackPanel>

    <StackPanel Margin="4,3">
     <StackPanel Orientation="Horizontal">
      <Label Content="DHCP reservation name" Padding="0" Target="{Binding ElementName=ReservationHost}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Host uses the server name. FQDN uses the host plus the selected AD DNS domain. This changes the DHCP reservation display name only."/>
     </StackPanel>
     <UniformGrid Columns="2" HorizontalAlignment="Stretch" Margin="0,3,0,0">
      <RadioButton Name="ReservationHost" GroupName="ReservationNameGroup" Content="Host"
                   Style="{StaticResource FirstSegmentRadioButton}"
                   AutomationProperties.HelpText="Use only the server name as the DHCP reservation display name."/>
      <RadioButton Name="ReservationFqdn" GroupName="ReservationNameGroup" Content="FQDN"
                   Style="{StaticResource SecondSegmentRadioButton}"
                   AutomationProperties.HelpText="Use the server name plus the selected AD DNS domain as the DHCP reservation display name."/>
     </UniformGrid>
    </StackPanel>
   </UniformGrid>
  </GroupBox>

  <GroupBox Grid.Row="3" Name="DestinationGroup" Header="3. Servers and AD destination" Width="1120" HorizontalAlignment="Center">
   <Grid Name="DestinationLayout" Width="1080" Margin="2" HorizontalAlignment="Center">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="42*"/>
     <ColumnDefinition Width="58*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
     <RowDefinition Height="Auto"/>
     <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Grid.Column="0" Name="ServerInputPanel" Margin="6,4,10,4" VerticalAlignment="Top">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <Grid Grid.Row="0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0" Orientation="Horizontal">
       <Label Content="Server Details (max 50):" Padding="0" Target="{Binding ElementName=ServerList}"/>
       <Button Style="{StaticResource InfoButton}" ToolTip="Type or paste one server per line as ServerName, IPv4Address, or import a CSV/.xlsx file."/>
      </StackPanel>
      <Button Grid.Column="1" Name="ImportServers" Content="Import CSV / Excel..." Margin="8,0,0,0" Padding="10,3" MinHeight="24"
              ToolTip="Load up to 50 servers from CSV or modern Excel (.xlsx). A CSV must have exactly two fields; its optional header is ServerName,IPAddress. Excel uses columns A and B and asks you to choose when multiple worksheets are visible. Legacy .xls is not supported. Import only fills this server box; it does not run Validation or make infrastructure changes."
              AutomationProperties.Name="Import server list from CSV or Excel"
              AutomationProperties.HelpText="Import up to 50 server names and IPv4 addresses from a two-column CSV or .xlsx workbook."/>
     </Grid>
     <Border Grid.Row="2" Name="ServerListBorder" Height="56" BorderBrush="#7A7A7A" BorderThickness="1" Background="White" VerticalAlignment="Top">
      <TextBox Name="ServerList" BorderThickness="0" AcceptsReturn="True" Padding="5" FontFamily="Consolas"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
               AutomationProperties.HelpText="Enter up to 50 servers, one per line, as server name, comma, canonical IPv4 address, or use Import CSV / Excel."/>
     </Border>
    </Grid>

    <Grid Grid.Row="0" Grid.Column="1" Name="AdDestinationPanel" Margin="10,4,6,4">
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/>
     </Grid.ColumnDefinitions>

     <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
      <Label Content="DNS" Padding="0" Target="{Binding ElementName=AdDnsDomain}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="Detected from this PVS server and editable. It selects the AD domain used for OU browsing and is also appended to the server name."/>
     </StackPanel>
     <TextBox Grid.Row="0" Grid.Column="2" Name="AdDnsDomain" VerticalContentAlignment="Center"
              AutomationProperties.HelpText="Editable AD DNS domain used for OU validation and as the FQDN suffix only when reverse DNS has no usable PTR record."/>

     <StackPanel Grid.Row="2" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
      <Label Content="OU" Padding="0" Target="{Binding ElementName=OuSelector}"/>
      <Button Style="{StaticResource InfoButton}" ToolTip="The OU list is preloaded for the detected DNS domain. Open it to select an OU. The OU's distinguished name is retained internally."/>
     </StackPanel>
     <ComboBox Grid.Row="2" Grid.Column="2" Name="OuSelector" IsEditable="True" IsTextSearchEnabled="False"
               StaysOpenOnEdit="True" DisplayMemberPath="Display"
               AutomationProperties.HelpText="Open the preloaded OU list, type to filter, and select an exact OU."/>

     <TextBox Name="OrganizationalUnit" Visibility="Collapsed"/>
    </Grid>
   </Grid>
  </GroupBox>

  <Grid Grid.Row="4" Name="ActionBar" Width="1120" HorizontalAlignment="Center" Margin="0,0,0,4">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
   <TextBlock Grid.Row="0" Grid.Column="0" Name="Status" FontWeight="SemiBold" VerticalAlignment="Center"
              TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="48" Margin="0,0,16,0"
              ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"
              Text="" Visibility="Collapsed"/>
   <!-- Keep the primary workflow and supporting result actions in one clear
        left-to-right sequence. -->
   <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal">
    <Button Name="Preview" Content="Validation" ToolTip="Read-only. Checks every selected system and creates nothing."/>
    <Button Name="Create" Content="Build" IsEnabled="False" Background="#0F6CBD" Foreground="White" FontWeight="SemiBold"
            ToolTip="Enabled after Validation when at least one server is Ready. Build processes only Ready servers; Blocked and exact existing rows are skipped unchanged. Existing mismatched state is never overwritten."/>
    <Button Name="ViewDetails" Content="Open details" IsEnabled="False" Padding="10,3"
            ToolTip="Open every field and the complete message for the selected result in a resizable window."/>
    <Button Name="OpenLog" Content="Open log" Padding="10,3"
            ToolTip="Open the log file for this launch in Notepad."/>
    <Button Name="Reset" Content="Reset" Margin="0" Padding="10,3"
            ToolTip="Start from scratch. Clears all current inputs, selections, Validation state, and displayed Results after confirmation, then opens a new Run ID and log."/>
   </StackPanel>
   <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Name="ExecutionNote" Text="" Foreground="DimGray"
              FontWeight="SemiBold" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,5,16,0" Visibility="Collapsed"/>
   <ProgressBar Grid.Row="2" Grid.ColumnSpan="2" Name="Progress" Height="6" Margin="0,6,0,0" Visibility="Collapsed"/>
  </Grid>

  <GroupBox Grid.Row="5" Name="ResultsGroup" Header="4. Results" Width="1120" HorizontalAlignment="Center">
   <Grid>
    <DataGrid Name="ResultGrid" IsReadOnly="True" AutoGenerateColumns="False"
              CanUserResizeColumns="False" CanUserResizeRows="True" RowHeight="30" MinRowHeight="30" MinHeight="36" ColumnHeaderHeight="42" SelectionMode="Single"
              GridLinesVisibility="All" VerticalGridLinesBrush="#8A8A8A" HorizontalGridLinesBrush="#B5B5B5"
              BorderBrush="#7A7A7A" BorderThickness="1" SnapsToDevicePixels="True"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
              ToolTip="Select a row and choose Open details. Double-clicking a row also opens the complete result.">
     <DataGrid.ColumnHeaderStyle>
      <Style TargetType="DataGridColumnHeader">
       <Setter Property="Padding" Value="8,4"/>
       <Setter Property="FontWeight" Value="SemiBold"/>
       <Setter Property="HorizontalContentAlignment" Value="Left"/>
       <!-- The theme separator and header border otherwise overlap at some
            star-column rounding points and appear as two vertical lines. -->
       <Setter Property="SeparatorVisibility" Value="Collapsed"/>
       <Setter Property="BorderBrush" Value="#8A8A8A"/>
       <Setter Property="BorderThickness" Value="0,0,1,1"/>
       <Setter Property="SnapsToDevicePixels" Value="True"/>
       <Setter Property="ContentTemplate">
        <Setter.Value>
         <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate>
        </Setter.Value>
       </Setter>
      </Style>
     </DataGrid.ColumnHeaderStyle>
     <DataGrid.Columns>
      <!-- Predictable values use fixed widths. Machine and DHCP size to their
           displayed content; a smaller work area scrolls instead of clipping. -->
      <DataGridTextColumn Header="Sr. No." Binding="{Binding Line}" Width="60"/>
      <DataGridTextColumn Header="Machine" Binding="{Binding MachineName}" Width="SizeToCells" MinWidth="130"/>
      <DataGridTextColumn Header="IP address" Binding="{Binding IPAddress}" Width="125"/>
      <DataGridTextColumn Header="MAC" Binding="{Binding MacAddress}" Width="150"/>
      <DataGridTextColumn Header="DHCP name" Binding="{Binding DhcpName}" Width="SizeToCells" MinWidth="235"/>
      <DataGridTextColumn Header="Reboot day" Binding="{Binding RebootDay}" Width="95"/>
      <DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="160"/>
      <DataGridTextColumn Header="Power" Binding="{Binding PowerResult}" Width="120"/>
     </DataGrid.Columns>
    </DataGrid>
   </Grid>
  </GroupBox>
  <Border Grid.RowSpan="6" Name="BusyOverlay" Visibility="Collapsed" Background="#01FFFFFF"
          Panel.ZIndex="1000" Cursor="Wait" Focusable="True"
          ToolTip="A tracked operation or background PVS read is in progress. Inputs and actions remain locked until it finishes."/>
 </Grid>
</Window>
'@
