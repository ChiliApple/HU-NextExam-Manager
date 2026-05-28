#Requires -Version 5.1
<#
.SYNOPSIS
    HU-NextExam-Manager - WPF-Tool fuer Next-Exam Versionsverwaltung.
.NOTES
    Start: powershell -NoProfile -ExecutionPolicy Bypass -File .\HU-NextExam-Manager.ps1
#>

[CmdletBinding()]
param(
    [switch]$AutoPull   # Wenn gesetzt: headless MSI-Deploy, kein UI (fuer Scheduled Task)
)

$ErrorActionPreference = 'Stop'

# --- Emergency Crash-Log (vor allem anderen) ---
$script:CrashLog = Join-Path $env:TEMP 'HU-NextExam-Manager-crash.log'
trap {
    $errMsg = "$($_.Exception.Message)`r`n`r`n$($_.InvocationInfo.PositionMessage)"
    try {
        $msg = "[{0}] CRASH: {1}`r`n{2}`r`n{3}`r`n" -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $_.Exception.Message, `
            $_.ScriptStackTrace, $_.InvocationInfo.PositionMessage
        Add-Content -Path $script:CrashLog -Value $msg -Encoding UTF8
    } catch {}
    # Console wieder anzeigen falls versteckt
    try { if ($script:ConsoleHwnd -and $script:ConsoleHwnd -ne [IntPtr]::Zero) { [HUNEM.Win32]::ShowWindow($script:ConsoleHwnd, 5) | Out-Null } } catch {}
    Write-Host "`n[CRASH] $_" -ForegroundColor Red
    Write-Host "Details: $script:CrashLog" -ForegroundColor Yellow
    # MessageBox als Fallback wenn Console nicht sichtbar
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show("HU-NextExam-Manager Crash:`n`n$errMsg`n`nLog: $script:CrashLog", 'Fehler', 'OK', 'Error') | Out-Null
    } catch {}
    Read-Host 'Enter zum Beenden'
    break
}

# --- ISE-Guard: WPF + ShowDialog() crashen die ISE ---
if ($host.Name -eq 'Windows PowerShell ISE Host' -or $psISE) {
    Write-Warning 'HU-NextExam-Manager laeuft nicht in der PowerShell ISE.'
    Write-Warning 'Starte neu in powershell.exe...'
    $script = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($script) {
        Start-Process (Get-Command powershell.exe).Source `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`""
    } else {
        Write-Warning 'Skript-Pfad nicht ermittelbar. Bitte manuell in powershell.exe starten.'
    }
    return
}

# --- AutoPull-Modus: headless (kein UI, kein Konsolen-Verstecken) ---
if ($AutoPull) {
    $RootPath    = $PSScriptRoot
    $ModulesPath = Join-Path $RootPath 'Modules'
    foreach ($m in 'Logging','Config','MSIPull','AutoPull') {
        Import-Module (Join-Path $ModulesPath "$m.psm1") -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    try {
        Invoke-AutoPullRun -ConfigPath (Join-Path $RootPath 'config.json')
        exit 0
    } catch {
        exit 1
    }
}

# --- Single-Instance-Check: wenn Tool schon laeuft, nicht nochmal starten ---
$script:MutexName = 'Global\HU-NextExam-Manager-Instance'
$script:Mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
try {
    if (-not $script:Mutex.WaitOne(0, $false)) {
        # Schon eine Instanz aktiv
        Add-Type -AssemblyName PresentationFramework -EA SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "HU-NextExam-Manager laeuft bereits.`n`nBitte das bestehende Fenster nutzen (ggf. im Taskleisten-Tray).",
            'Bereits aktiv', 'OK', 'Information') | Out-Null
        exit 0
    }
} catch {}

# --- Konsolen-Fenster verstecken (WPF-Tool, Console nicht benoetigt) ---
try {
    if (-not ('HUNEM.Win32' -as [type])) {
        Add-Type -Namespace HUNEM -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
    }
    # Eigene AppUserModelID -> Windows nutzt unseren Icon in Taskleiste (nicht powershell.exe)
    try { [HUNEM.Win32]::SetCurrentProcessExplicitAppUserModelID("HU.NextExamManager.$script:ToolVersion") | Out-Null } catch {}
    $script:ConsoleHwnd = [HUNEM.Win32]::GetConsoleWindow()
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) {
        [HUNEM.Win32]::ShowWindow($script:ConsoleHwnd, 0) | Out-Null  # 0 = SW_HIDE
    }
} catch { $script:ConsoleHwnd = [IntPtr]::Zero }

function Show-Console {
    if ($script:ConsoleHwnd -and $script:ConsoleHwnd -ne [IntPtr]::Zero) {
        try { [HUNEM.Win32]::ShowWindow($script:ConsoleHwnd, 5) | Out-Null } catch {} # SW_SHOW
    }
}

# --- Tool-Version (wird bei Release hochgezaehlt) ---
$script:ToolVersion = '2.0.2'

# --- Pfade ---
$script:RootPath    = $PSScriptRoot
$script:ModulesPath = Join-Path $script:RootPath 'Modules'
$script:XamlPath    = Join-Path $script:RootPath 'XAML\MainWindow.xaml'

# --- Assemblies (alle oben in korrekter Reihenfolge) ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName Microsoft.VisualBasic

# --- Module laden (Import-Module in Script = Global-Scope, sichtbar fuer Event-Handler) ---
foreach ($m in 'Logging','Config','MSIPull','WMIFilter','GPOSetup','AutoPull','ClientStatus','MDMDeploy') {
    $mp = Join-Path $script:ModulesPath "$m.psm1"
    if (-not (Test-Path $mp)) { throw "Modul fehlt: $mp" }
    Import-Module $mp -Force -Global -DisableNameChecking -ErrorAction Stop
}

# --- Config-Pfad festlegen (portabel: neben dem Tool) ---
Set-ConfigPath -Path (Join-Path $script:RootPath 'config.json')

# --- Config laden ---
$script:Config = Load-Config

# --- Logging initialisieren ---
Initialize-Log -Path $script:Config.ToolSettings.LogPath -Level $script:Config.ToolSettings.LogLevel
Write-Log -Message "HU-NextExam-Manager v$($script:ToolVersion) startet" -Level INFO -Source 'Main'

# --- XAML laden (mit Retry falls gerade durch Pull gelockt) ---
if (-not (Test-Path $script:XamlPath)) { throw "XAML fehlt: $script:XamlPath" }
$xamlContent = $null
for ($i = 0; $i -lt 5; $i++) {
    try {
        $xamlContent = [System.IO.File]::ReadAllText($script:XamlPath, [System.Text.UTF8Encoding]::new($false))
        break
    } catch {
        if ($i -eq 4) { throw "XAML nach 5 Versuchen gelockt: $_" }
        Start-Sleep -Milliseconds 500
    }
}
[xml]$xaml = $xamlContent
$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Log -Message "XAML-Load-Fehler: $_" -Level ERROR -Source 'XAML'
    throw
}
# --- Splash Screen ---
try {
    $splashXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" Width="400" Height="320"
        Topmost="True" ShowInTaskbar="False">
    <Border Background="#1E1E1E" CornerRadius="12" BorderBrush="#0078D4" BorderThickness="2">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Image x:Name="imgSplash" Grid.Row="0" Width="140" Height="140" Margin="0,30,0,10" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            <TextBlock Grid.Row="1" Text="HU-NextExam-Manager" FontSize="22" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,0,0,4"/>
            <TextBlock x:Name="lblSplashVersion" Grid.Row="2" FontSize="14" Foreground="#888" HorizontalAlignment="Center" Margin="0,0,0,6"/>
            <TextBlock Grid.Row="3" Text="loading modules ..." FontSize="11" Foreground="#555" FontStyle="Italic" HorizontalAlignment="Center" Margin="0,0,0,24"/>
        </Grid>
    </Border>
</Window>
"@
    [xml]$splashXml = $splashXaml
    $splashReader = New-Object System.Xml.XmlNodeReader $splashXml
    $script:SplashWindow = [Windows.Markup.XamlReader]::Load($splashReader)

    # Version setzen
    $script:SplashWindow.FindName('lblSplashVersion').Text = "v$($script:ToolVersion)"

    # Crane-Icon laden
    $splashIconPath = Join-Path $script:RootPath 'Assets\crane_check_icon.png'
    if (Test-Path $splashIconPath) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri $splashIconPath
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $script:SplashWindow.FindName('imgSplash').Source = $bmp
    }

    $script:SplashWindow.Show()
    [System.Windows.Forms.Application]::DoEvents()  # Force render

    # Splash nach 2.5s automatisch ausblenden (unabhaengig von ContentRendered)
    $script:SplashAutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SplashAutoTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:SplashAutoTimer.Add_Tick({
        $script:SplashAutoTimer.Stop()
        $script:SplashAutoTimer = $null
        if ($script:SplashWindow) {
            try {
                $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(500))))
                $fade.Add_Completed({
                    try { $script:SplashWindow.Close() } catch {}
                    $script:SplashWindow = $null
                })
                $script:SplashWindow.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
            } catch {
                try { $script:SplashWindow.Close() } catch {}
                $script:SplashWindow = $null
            }
        }
    })
    $script:SplashAutoTimer.Start()

    Write-Log 'Splash Screen angezeigt' -Level INFO -Source 'UI'
} catch {
    Write-Log "Splash Screen Fehler (nicht kritisch): $_" -Level WARN -Source 'UI'
}


# --- Icon setzen (Titelbar via Window.Icon + Taskleiste via WM_SETICON) ---
$script:IconPath = Join-Path $script:RootPath 'Assets\icon.ico'
Write-Log -Message "IconPath=$script:IconPath | Exists=$(Test-Path $script:IconPath)" -Level INFO -Source 'UI'

if (Test-Path $script:IconPath) {
    # Versuch 1: BitmapFrame aus URI
    try {
        $uri = New-Object System.Uri -ArgumentList $script:IconPath
        $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($uri, [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Write-Log -Message "Window.Icon via BitmapFrame gesetzt" -Level INFO -Source 'UI'
    } catch {
        Write-Log -Message "BitmapFrame fehl: $_ - versuche BitmapImage" -Level WARN -Source 'UI'
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.CacheOption   = 'OnLoad'
            $bmp.CreateOptions = 'IgnoreImageCache'
            $bmp.UriSource     = New-Object System.Uri $script:IconPath
            $bmp.EndInit()
            $bmp.Freeze()
            $script:Window.Icon = $bmp
            Write-Log -Message "Window.Icon via BitmapImage gesetzt" -Level INFO -Source 'UI'
        } catch {
            Write-Log -Message "BitmapImage auch fehl: $_" -Level ERROR -Source 'UI'
        }
    }

    # Taskleiste: Crane-Icon via WM_SETICON nach HWND-Init (PNG -> Bitmap -> GetHicon)
    $script:CranePath = Join-Path $script:RootPath 'Assets\crane_check_icon.png'
    $script:Window.Add_SourceInitialized({
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
            $hwnd = $helper.Handle
            if ($hwnd -ne [IntPtr]::Zero -and (Test-Path $script:CranePath)) {
                $bitmap = [System.Drawing.Bitmap]::new($script:CranePath)
                $hIcon  = $bitmap.GetHicon()
                [HUNEM.Win32]::SendMessage($hwnd, 0x0080, [IntPtr]0, $hIcon) | Out-Null  # ICON_SMALL
                [HUNEM.Win32]::SendMessage($hwnd, 0x0080, [IntPtr]1, $hIcon) | Out-Null  # ICON_BIG
                Write-Log -Message "WM_SETICON Taskleiste: crane_check_icon.png gesetzt" -Level INFO -Source 'UI'
            } elseif ($hwnd -ne [IntPtr]::Zero -and (Test-Path $script:IconPath)) {
                # Fallback: icon.ico
                $ico = New-Object System.Drawing.Icon -ArgumentList $script:IconPath
                $hIcon = $ico.Handle
                [HUNEM.Win32]::SendMessage($hwnd, 0x0080, [IntPtr]0, $hIcon) | Out-Null
                [HUNEM.Win32]::SendMessage($hwnd, 0x0080, [IntPtr]1, $hIcon) | Out-Null
                Write-Log -Message "WM_SETICON Taskleiste: Fallback icon.ico" -Level INFO -Source 'UI'
            }
        } catch { Write-Log -Message "Taskbar-Icon-Set: $_" -Level WARN -Source 'UI' }
    })
} else {
    Write-Log -Message "Icon-Datei fehlt: $script:IconPath - bitte Pull.ps1 ausfuehren" -Level WARN -Source 'UI'
}

# --- UI-Elemente in Variablen ---
function Get-UI([string]$Name) { $script:Window.FindName($Name) }

$script:lblVersion  = Get-UI 'lblVersion'
$script:tabMain     = Get-UI 'tabMain'
$script:lblStatus        = Get-UI 'lblStatus'
$script:overlayLoading   = Get-UI 'overlayLoading'
$script:lblLoadingStatus = Get-UI 'lblLoadingStatus'
$script:btnUpdate   = Get-UI 'btnUpdate'
$script:lstTasks    = Get-UI 'lstTasks'
$script:pnlDetails  = Get-UI 'pnlTaskDetails'  

# Settings-Tab Felder
$script:txtDisplayName  = Get-UI 'txtDisplayName'
$script:txtDomainFQDN   = Get-UI 'txtDomainFQDN'
$script:txtDCServer     = Get-UI 'txtDCServer'
$script:txtStudentShare = Get-UI 'txtStudentShare'
$script:txtTeacherShare = Get-UI 'txtTeacherShare'
$script:txtOUStudent    = Get-UI 'txtOUStudent'
$script:txtOUTeacher    = Get-UI 'txtOUTeacher'
$script:txtWMIStudent     = Get-UI 'txtWMIStudent'
$script:cmbWMIStudentType = Get-UI 'cmbWMIStudentType'
$script:txtWMITeacher     = Get-UI 'txtWMITeacher'
$script:cmbWMITeacherType = Get-UI 'cmbWMITeacherType'
$script:txtGPOPrefix    = Get-UI 'txtGPOPrefix'
$script:txtFWProfiles    = Get-UI 'txtFWProfiles'
$script:txtFWStudentExe  = Get-UI 'txtFWStudentExe'
$script:txtFWTeacherExe  = Get-UI 'txtFWTeacherExe'
$script:chkFWTCP         = Get-UI 'chkFWTCP'
$script:txtFWTCPPort     = Get-UI 'txtFWTCPPort'
$script:chkFWUDP         = Get-UI 'chkFWUDP'
$script:txtFWUDPPorts    = Get-UI 'txtFWUDPPorts'

$script:btnTaskAdd      = Get-UI 'btnTaskAdd'
$script:btnTaskRemove   = Get-UI 'btnTaskRemove'
$script:btnTaskSave     = Get-UI 'btnTaskSave'
$script:btnTestConn     = Get-UI 'btnTestConn'
$script:btnStudentShareBrowse = Get-UI 'btnStudentShareBrowse'
$script:btnTeacherShareBrowse = Get-UI 'btnTeacherShareBrowse'
$script:txtStatusShare     = Get-UI 'txtStatusShare'
$script:btnStatusShareInit = Get-UI 'btnStatusShareInit'

$script:lblVersion.Text = " v$($script:ToolVersion)"

# --- App-Logo (Crane-Check) in Title-Bar laden ---
$script:imgAppLogo = Get-UI 'imgAppLogo'
$cranePath = Join-Path $script:RootPath 'Assets\crane_check_icon.png'
if (Test-Path $cranePath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri $cranePath
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $script:imgAppLogo.Source = $bmp
        Write-Log 'App-Logo (Crane) geladen' -Level INFO -Source 'UI'
    } catch {
        Write-Log "App-Logo laden fehlgeschlagen: $_" -Level WARN -Source 'UI'
    }
} else {
    Write-Log "App-Logo fehlt: $cranePath" -Level WARN -Source 'UI'
}

# --- Status-Helper ---
function Set-Status([string]$Msg) {
    $script:Window.Dispatcher.Invoke([Action]{
        $script:lblStatus.Text = $Msg
        if ($script:lblLoadingStatus -and $script:overlayLoading.Visibility -eq 'Visible') {
            $script:lblLoadingStatus.Text = $Msg
        }
    })
    Write-Log -Message $Msg -Level INFO -Source 'UI'
}

function Show-LoadingOverlay { $script:overlayLoading.Visibility = 'Visible' }
function Hide-LoadingOverlay { $script:overlayLoading.Visibility = 'Collapsed' }

function Expand-LogPath {
    $p = $script:Config.ToolSettings.LogPath
    if ($p -and $p -match '%[^%]+%') {
        $p = [System.Environment]::ExpandEnvironmentVariables($p)
    }
    return $p
}

# --- Settings-Tab Logik ---
function Refresh-TaskList {
    $script:lstTasks.ItemsSource = $null
    $items = @($script:Config.Tasks) | ForEach-Object {
        $item = $_
        if ($item -is [hashtable]) { $item = [PSCustomObject]$item }
        $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.DisplayName } -Force
        $item
    }
    $script:lstTasks.ItemsSource = @($items)
}

function Load-TaskToForm($task) {
    if ($null -eq $task) {
        $script:pnlDetails.IsEnabled = $false
        return
    }
    $script:pnlDetails.IsEnabled    = $true
    $script:txtDisplayName.Text     = [string]$task.DisplayName
    $script:txtDomainFQDN.Text      = [string]$task.DomainFQDN
    $script:txtDCServer.Text        = [string]$task.DCServer
    $script:txtStudentShare.Text    = [string]$task.StudentSharePath
    $script:txtTeacherShare.Text    = [string]$task.TeacherSharePath
    $script:txtOUStudent.Text       = [string]$task.OUTargetStudent
    $script:txtOUTeacher.Text       = [string]$task.OUTargetTeacher
    $script:txtWMIStudent.Text      = [string]$task.WMIFilterStudentPattern
    $script:txtWMITeacher.Text      = [string]$task.WMIFilterTeacherPattern
    # WMI-Type Dropdown setzen
    $sType = if ($task.WMIFilterStudentType) { $task.WMIFilterStudentType } else { 'Custom' }
    $tType = if ($task.WMIFilterTeacherType) { $task.WMIFilterTeacherType } else { 'Custom' }
    $idxS = @('Prefix','Pattern','List','Custom').IndexOf($sType); if ($idxS -lt 0) { $idxS = 3 }
    $idxT = @('Prefix','Pattern','List','Custom').IndexOf($tType); if ($idxT -lt 0) { $idxT = 3 }
    $script:cmbWMIStudentType.SelectedIndex = $idxS
    $script:cmbWMITeacherType.SelectedIndex = $idxT
    $script:txtGPOPrefix.Text       = [string]$task.GPONamePrefix
    # Status-Share: wenn leer, Default aus Student-Share-Parent ableiten
    if ($task.StatusSharePath) {
        $script:txtStatusShare.Text = [string]$task.StatusSharePath
    } elseif ($task.StudentSharePath) {
        $parent = Split-Path -Path $task.StudentSharePath -Parent
        if ($parent) { $script:txtStatusShare.Text = Join-Path $parent '_status' }
        else         { $script:txtStatusShare.Text = '' }
    } else {
        $script:txtStatusShare.Text = ''
    }
    $script:txtFWProfiles.Text      = if ($task.FWProfiles) { ($task.FWProfiles -join ',') } else { 'Domain,Private' }
    $script:txtFWStudentExe.Text    = [string]$task.FWStudentExe
    $script:txtFWTeacherExe.Text    = [string]$task.FWTeacherExe
    $script:chkFWTCP.IsChecked      = [bool]$task.FWEnableTCPPort
    $script:txtFWTCPPort.Text       = [string]$task.FWTCPPort
    $script:chkFWUDP.IsChecked      = [bool]$task.FWEnableUDPPort
    $script:txtFWUDPPorts.Text      = [string]$task.FWUDPPorts
}

function Save-FormToTask {
    $sel = $script:lstTasks.SelectedItem
    if ($null -eq $sel) { return }
    $sel.DisplayName             = $script:txtDisplayName.Text
    $sel.DomainFQDN              = $script:txtDomainFQDN.Text
    $sel.DCServer                = $script:txtDCServer.Text
    $sel.StudentSharePath        = $script:txtStudentShare.Text
    $sel.TeacherSharePath        = $script:txtTeacherShare.Text
    $sel.OUTargetStudent         = $script:txtOUStudent.Text
    $sel.OUTargetTeacher         = $script:txtOUTeacher.Text
    $sel.WMIFilterStudentPattern = $script:txtWMIStudent.Text
    $sel.WMIFilterTeacherPattern = $script:txtWMITeacher.Text
    $sel.WMIFilterStudentType    = [string]$script:cmbWMIStudentType.SelectedItem.Content
    $sel.WMIFilterTeacherType    = [string]$script:cmbWMITeacherType.SelectedItem.Content
    $sel.GPONamePrefix           = if ($script:txtGPOPrefix.Text) { $script:txtGPOPrefix.Text } else { 'HU-NEXT-EXAM-' }
    $sel.StatusSharePath         = $script:txtStatusShare.Text
    $sel.FWProfiles              = @(($script:txtFWProfiles.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $sel.FWProfiles)    { $sel.FWProfiles = @('Domain','Private') }
    $sel.FWStudentExe            = $script:txtFWStudentExe.Text
    $sel.FWTeacherExe            = $script:txtFWTeacherExe.Text
    $sel.FWEnableTCPPort         = [bool]$script:chkFWTCP.IsChecked
    $sel.FWTCPPort               = [int]($script:txtFWTCPPort.Text -as [int])
    if ($sel.FWTCPPort -le 0)    { $sel.FWTCPPort = 22422 }
    $sel.FWEnableUDPPort         = [bool]$script:chkFWUDP.IsChecked
    $sel.FWUDPPorts              = $script:txtFWUDPPorts.Text

    Save-Config -Config $script:Config
    Refresh-TaskList
    for ($i = 0; $i -lt $script:Config.Tasks.Count; $i++) {
        if ($script:Config.Tasks[$i].Id -eq $sel.Id) {
            $script:lstTasks.SelectedIndex = $i; break
        }
    }
    Set-Status "Task gespeichert: $($sel.DisplayName)"
}

# --- Events ---
$script:lstTasks.Add_SelectionChanged({
    Load-TaskToForm $script:lstTasks.SelectedItem
})

$script:btnTaskAdd.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Anzeigename des neuen Tasks:', 'Neuer Task', 'Neuer Task')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $new = Add-TaskToConfig -Config $script:Config -DisplayName $name
    Save-Config -Config $script:Config
    Refresh-TaskList
    $script:lstTasks.SelectedItem = ($script:Config.Tasks | Where-Object { $_.Id -eq $new.Id } | Select-Object -First 1)
    Set-Status "Task hinzugefuegt: $name"
})

$script:btnTaskRemove.Add_Click({
    $sel = $script:lstTasks.SelectedItem
    if ($null -eq $sel) { return }
    $res = [System.Windows.MessageBox]::Show(
        "Task '$($sel.DisplayName)' wirklich entfernen?",
        'Bestaetigen', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }
    Remove-TaskFromConfig -Config $script:Config -Id $sel.Id
    Save-Config -Config $script:Config
    Refresh-TaskList
    Load-TaskToForm $null
    Set-Status "Task entfernt: $($sel.DisplayName)"
})

$script:btnTaskSave.Add_Click({ Save-FormToTask })

$script:btnStudentShareBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Student-MSI Zielordner (UNC bevorzugt)'
    if ($dlg.ShowDialog() -eq 'OK') { $script:txtStudentShare.Text = $dlg.SelectedPath }
})

$script:btnTeacherShareBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Teacher-MSI Zielordner (UNC bevorzugt)'
    if ($dlg.ShowDialog() -eq 'OK') { $script:txtTeacherShare.Text = $dlg.SelectedPath }
})

$script:btnStatusShareInit.Add_Click({
    $sel = $script:lstTasks.SelectedItem
    if ($null -eq $sel) {
        [System.Windows.MessageBox]::Show('Keinen Task markiert.', 'Hinweis', 'OK', 'Information') | Out-Null; return
    }
    $path = $script:txtStatusShare.Text
    if (-not $path) {
        [System.Windows.MessageBox]::Show('Status-Share-Pfad leer.', 'Hinweis', 'OK', 'Information') | Out-Null; return
    }
    if (-not $sel.DomainFQDN) {
        [System.Windows.MessageBox]::Show('Domain FQDN fehlt.', 'Hinweis', 'OK', 'Information') | Out-Null; return
    }
    try {
        $r = Initialize-StatusShare -Path $path -DomainFQDN $sel.DomainFQDN -Server $sel.DCServer
        [System.Windows.MessageBox]::Show("Status-Share angelegt:`n`nPfad:  $($r.Path)`nWrite: $($r.DomainComputers)`nFull:  $($r.DomainAdmins)`n`nVererbung deaktiviert - nur dieser Ordner.", 'Erfolg', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Anlegen/ACL:`n`n$_", 'Fehler', 'OK', 'Error') | Out-Null
    }
})

$script:btnTestConn.Add_Click({
    $sel = $script:lstTasks.SelectedItem
    if ($null -eq $sel) { return }
    $msgs = @()
    # DC-Ping
    if ($script:txtDCServer.Text) {
        $ok = Test-Connection -ComputerName $script:txtDCServer.Text -Count 1 -Quiet -ErrorAction SilentlyContinue
        $msgs += "DC $($script:txtDCServer.Text): " + ($(if($ok){'erreichbar'}else{'NICHT erreichbar'}))
    }
    # Shares
    foreach ($p in @(@{Label='Student';Path=$script:txtStudentShare.Text}, @{Label='Teacher';Path=$script:txtTeacherShare.Text})) {
        if ($p.Path) {
            $ok = Test-Path -Path $p.Path -ErrorAction SilentlyContinue
            $msgs += "$($p.Label)-Share: " + ($(if($ok){'OK'}else{'nicht erreichbar'}))
        }
    }
    [System.Windows.MessageBox]::Show(($msgs -join "`n"), 'Verbindungstest') | Out-Null
})

function Show-ReleaseChangelog {
    if (-not $script:CurrentRelease) {
        [System.Windows.MessageBox]::Show('Bitte zuerst Release abfragen.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    $rel   = $script:CurrentRelease
    $title = "Next-Exam $($rel.TagName) - $($rel.Name)"
    $md    = "# $title`r`n`r`n"
    $md   += "**Published:** $($rel.PublishedAt)`r`n"
    $md   += "**URL:** $($rel.HtmlUrl)`r`n`r`n"
    $md   += "---`r`n`r`n"
    $md   += [string]$rel.Body

    # Fenster bauen (Code-behind, kein externes XAML)
    $win = New-Object System.Windows.Window
    $win.Title                 = "Changelog - $($rel.TagName)"
    $win.Width                 = 800
    $win.Height                = 600
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner                 = $script:Window
    $win.Background            = [System.Windows.Media.Brushes]::Black

    $grid = New-Object System.Windows.Controls.Grid
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = 'Auto'
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = '*'
    $r3 = New-Object System.Windows.Controls.RowDefinition; $r3.Height = 'Auto'
    $null = $grid.RowDefinitions.Add($r1)
    $null = $grid.RowDefinitions.Add($r2)
    $null = $grid.RowDefinitions.Add($r3)

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text       = $title
    $header.FontSize   = 16
    $header.FontWeight = 'Bold'
    $header.Foreground = [System.Windows.Media.Brushes]::White
    $header.Margin     = '10,10,10,4'
    [System.Windows.Controls.Grid]::SetRow($header, 0)
    $null = $grid.Children.Add($header)

    $txt = New-Object System.Windows.Controls.TextBox
    $txt.Text             = $md
    $txt.AcceptsReturn    = $true
    $txt.TextWrapping     = 'Wrap'
    $txt.IsReadOnly       = $true
    $txt.FontFamily       = 'Consolas'
    $txt.FontSize         = 12
    $txt.VerticalScrollBarVisibility   = 'Auto'
    $txt.HorizontalScrollBarVisibility = 'Auto'
    $txt.Background       = [System.Windows.Media.Brushes]::Black
    $txt.Foreground       = [System.Windows.Media.Brushes]::LightGray
    $txt.BorderBrush      = [System.Windows.Media.Brushes]::DimGray
    $txt.Margin           = '10,0,10,4'
    [System.Windows.Controls.Grid]::SetRow($txt, 1)
    $null = $grid.Children.Add($txt)

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation         = 'Horizontal'
    $btnPanel.HorizontalAlignment = 'Right'
    $btnPanel.Margin              = '10,4,10,10'

    $btnCopy = New-Object System.Windows.Controls.Button
    $btnCopy.Content = 'In Zwischenablage'; $btnCopy.Width = 140; $btnCopy.Margin = 4
    $btnCopy.Add_Click({ [System.Windows.Clipboard]::SetText($txt.Text) })
    $null = $btnPanel.Children.Add($btnCopy)

    $btnSaveMd = New-Object System.Windows.Controls.Button
    $btnSaveMd.Content = 'Als .md speichern'; $btnSaveMd.Width = 140; $btnSaveMd.Margin = 4
    $btnSaveMd.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'Markdown (*.md)|*.md|Alle (*.*)|*.*'
        $dlg.FileName = "NextExam-$($rel.TagName)-Changelog.md"
        if ($dlg.ShowDialog()) { [System.IO.File]::WriteAllText($dlg.FileName, $txt.Text, [System.Text.Encoding]::UTF8) }
    })
    $null = $btnPanel.Children.Add($btnSaveMd)

    $btnSaveTxt = New-Object System.Windows.Controls.Button
    $btnSaveTxt.Content = 'Als .txt speichern'; $btnSaveTxt.Width = 140; $btnSaveTxt.Margin = 4
    $btnSaveTxt.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'Text (*.txt)|*.txt|Alle (*.*)|*.*'
        $dlg.FileName = "NextExam-$($rel.TagName)-Changelog.txt"
        if ($dlg.ShowDialog()) { [System.IO.File]::WriteAllText($dlg.FileName, $txt.Text, [System.Text.Encoding]::UTF8) }
    })
    $null = $btnPanel.Children.Add($btnSaveTxt)

    $btnClose = New-Object System.Windows.Controls.Button
    $btnClose.Content = 'Schliessen'; $btnClose.Width = 100; $btnClose.Margin = 4
    $btnClose.Add_Click({ $win.Close() })
    $null = $btnPanel.Children.Add($btnClose)

    [System.Windows.Controls.Grid]::SetRow($btnPanel, 2)
    $null = $grid.Children.Add($btnPanel)

    $win.Content = $grid
    [void]$win.ShowDialog()
}

# ========== MSI Pull Tab ==========
$script:lblReleaseVersion = Get-UI 'lblReleaseVersion'
$script:lblReleaseDate    = Get-UI 'lblReleaseDate'
$script:lblReleaseStudent = Get-UI 'lblReleaseStudent'
$script:lblReleaseTeacher = Get-UI 'lblReleaseTeacher'
$script:btnReleaseRefresh   = Get-UI 'btnReleaseRefresh'
$script:btnReleaseChangelog = Get-UI 'btnReleaseChangelog'
$script:lstMSITasks     = Get-UI 'lstMSITasks'
$script:btnRefreshStatus  = Get-UI 'btnRefreshStatus'
$script:btnDeploySelected = Get-UI 'btnDeploySelected'
$script:btnDeployAll      = Get-UI 'btnDeployAll'
$script:chkAutoPull       = Get-UI 'chkAutoPull'
$script:txtAutoPullTime   = Get-UI 'txtAutoPullTime'
$script:lblAutoPullStatus = Get-UI 'lblAutoPullStatus'
$script:rbAutoPullSystem  = Get-UI 'rbAutoPullSystem'
$script:rbAutoPullUser    = Get-UI 'rbAutoPullUser'

$script:CurrentRelease = $null  # Cache

function Update-ReleaseDisplay {
    try {
        Set-Status "Frage GitHub nach Next-Exam Release..."
        $rel = Get-NextExamLatestRelease
        $script:CurrentRelease = $rel
        $script:lblReleaseVersion.Text = "Tag:       $($rel.TagName) - $($rel.Name)"
        $script:lblReleaseDate.Text    = "Stand:     $($rel.PublishedAt)"
        if ($rel.Student) { $script:lblReleaseStudent.Text = "Student:   $($rel.Student.FileName) ($([math]::Round($rel.Student.Size/1MB,1)) MB)" }
        if ($rel.Teacher) { $script:lblReleaseTeacher.Text = "Teacher:   $($rel.Teacher.FileName) ($([math]::Round($rel.Teacher.Size/1MB,1)) MB)" }
        Set-Status "Release: $($rel.TagName) (Student $($rel.Student.Version) / Teacher $($rel.Teacher.Version))"
    } catch {
        $script:lblReleaseVersion.Text = "FEHLER: $_"
        Write-Log -Message "Release-Abfrage fehlgeschlagen: $_" -Level ERROR -Source 'MSIPull'
        Set-Status "Release-Abfrage fehlgeschlagen"
    }
}

function Refresh-MSITaskStatus {
    $rows = @()
    foreach ($s in $script:Config.Tasks) {
        $studentLocal = '-'
        $teacherLocal = '-'
        try {
            if ($s.StudentSharePath -and (Test-Path $s.StudentSharePath -ErrorAction SilentlyContinue)) {
                $vi = Read-ShareVersionInfo -SharePath $s.StudentSharePath -Role Student
                if ($vi) { $studentLocal = "$($vi.Version) / $($vi.BuildDate)" }
                else { $studentLocal = '(kein version-student.json)' }
            } elseif ($s.StudentSharePath) { $studentLocal = '(Share offline)' }
        } catch { $studentLocal = '(Fehler)' }
        try {
            if ($s.TeacherSharePath -and (Test-Path $s.TeacherSharePath -ErrorAction SilentlyContinue)) {
                $vi = Read-ShareVersionInfo -SharePath $s.TeacherSharePath -Role Teacher
                if ($vi) { $teacherLocal = "$($vi.Version) / $($vi.BuildDate)" }
                else { $teacherLocal = '(kein version-teacher.json)' }
            } elseif ($s.TeacherSharePath) { $teacherLocal = '(Share offline)' }
        } catch { $teacherLocal = '(Fehler)' }

        $status = 'unbekannt'
        if ($script:CurrentRelease) {
            $remoteS = $script:CurrentRelease.Student.Version
            $remoteT = $script:CurrentRelease.Teacher.Version
            $sOk = $studentLocal -like "$remoteS*"
            $tOk = $teacherLocal -like "$remoteT*"
            if ($sOk -and $tOk) { $status = 'aktuell' }
            elseif (-not $sOk -and -not $tOk) { $status = 'beide veraltet' }
            elseif (-not $sOk) { $status = 'Student veraltet' }
            elseif (-not $tOk) { $status = 'Teacher veraltet' }
        }

        $rows += [PSCustomObject]@{
            Id               = $s.Id
            DisplayName      = $s.DisplayName
            StudentVersion   = $studentLocal
            TeacherVersion   = $teacherLocal
            Status           = $status
            StudentSharePath = $s.StudentSharePath
            TeacherSharePath = $s.TeacherSharePath
            _Task            = $s
        }
    }
    $script:lstMSITasks.ItemsSource = @($rows)
}

function Invoke-DeployToTasks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Tasks
    )

    if (-not $script:CurrentRelease) {
        [System.Windows.MessageBox]::Show('Bitte zuerst Release abfragen.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $Tasks -or $Tasks.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Kein Task ausgewaehlt.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    $missing = @($Tasks | Where-Object { -not $_.StudentSharePath -or -not $_.TeacherSharePath })
    if ($missing.Count -gt 0) {
        $names = ($missing | ForEach-Object { $_.DisplayName }) -join ', '
        [System.Windows.MessageBox]::Show("Tasks ohne Shares konfiguriert: $names", 'Fehler', 'OK', 'Warning') | Out-Null
        return
    }

    $rel = $script:CurrentRelease
    $sizeMB = [math]::Round(($rel.Student.Size + $rel.Teacher.Size)/1MB, 0)
    $names  = ($Tasks | ForEach-Object { $_.DisplayName }) -join ', '
    $res = [System.Windows.MessageBox]::Show(
        "Download + Deploy auf $($Tasks.Count) Task(s):`n`n$names`n`nVersion: $($rel.Student.Version) (Student) / $($rel.Teacher.Version) (Teacher)`nDownload-Groesse: ~$sizeMB MB`n`nArchivierung: max. 3 letzte Versionen pro Rolle, aeltere werden geloescht.",
        'Deploy bestaetigen', 'YesNo', 'Question')
    if ($res -ne 'Yes') { return }

    # UI lock
    $script:btnDeploySelected.IsEnabled = $false
    $script:btnDeployAll.IsEnabled      = $false
    $script:btnReleaseRefresh.IsEnabled = $false
    $script:btnRefreshStatus.IsEnabled  = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::AppStarting

    $tempDir = Join-Path $env:TEMP "HU-NextExam-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $script:DeployState = [PSCustomObject]@{
        Tasks      = $Tasks
        TempDir    = $tempDir
        TmpStudent = Join-Path $tempDir $rel.Student.FileName
        TmpTeacher = Join-Path $tempDir $rel.Teacher.FileName
        Release    = $rel
        Phase      = 'DL-Student'
        StartTime  = Get-Date
    }

    Start-RunspaceDownload -Url $rel.Student.DownloadUrl `
                           -Target $script:DeployState.TmpStudent `
                           -Label 'Student' -ExpectedSize $rel.Student.Size
}

function Start-RunspaceDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][long]$ExpectedSize
    )
    # Runspace erstellen - laeuft echt parallel zum UI-Thread
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($url, $target, $sizeHint)
        try {
            # TLS 1.2 fuer GitHub release downloads
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'HU-NextExam-Manager')
            $wc.DownloadFile($url, $target)  # SYNC im Runspace - blockt nur diesen Thread
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }).AddArgument($Url).AddArgument($Target).AddArgument($ExpectedSize)
    $ps.Runspace = $rs
    $handle = $ps.BeginInvoke()

    # State fuer Polling
    $script:DL = [PSCustomObject]@{
        Runspace = $rs
        PS       = $ps
        Handle   = $handle
        Target   = $Target
        Label    = $Label
        Expected = $ExpectedSize
        Timer    = $null
        Start    = Get-Date
    }

    # DispatcherTimer pollt File-Size + Handle-Status auf UI-Thread
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        try {
            $d = $script:DL
            if (-not $d) { return }
            # Progress aktualisieren
            $cur = 0
            if (Test-Path $d.Target) { $cur = (Get-Item $d.Target).Length }
            $pct = if ($d.Expected -gt 0) { [int](($cur / $d.Expected) * 100) } else { 0 }
            $mb  = [math]::Round($cur / 1MB, 1)
            $tot = [math]::Round($d.Expected / 1MB, 1)
            Set-Status ("Download {0}: {1} MB / {2} MB  ({3}%)" -f $d.Label, $mb, $tot, $pct)

            # Fertig?
            if ($d.Handle.IsCompleted) {
                $d.Timer.Stop()
                try {
                    $result = $d.PS.EndInvoke($d.Handle)
                    $resObj = if ($result -and $result.Count -gt 0) { $result[0] } else { @{ Success = $false; Error = 'Leeres Ergebnis' } }
                } catch {
                    $resObj = @{ Success = $false; Error = $_.Exception.Message }
                }
                # Cleanup Runspace
                try { $d.PS.Dispose() } catch {}
                try { $d.Runspace.Close(); $d.Runspace.Dispose() } catch {}
                $script:DL = $null

                if ($resObj.Success) {
                    Finalize-DeployPhase -Label $d.Label -Success
                } else {
                    Finalize-DeployPhase -Label $d.Label -ErrorMessage $resObj.Error
                }
            }
        } catch {
            Write-Log -Message "Timer-Tick-Fehler: $_" -Level ERROR -Source 'MSIPull'
        }
    })
    $script:DL.Timer = $timer
    $timer.Start()

    Set-Status "Download $Label startet..."
}

function Finalize-DeployPhase {
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$Success,
        [string]$ErrorMessage
    )
    if ($ErrorMessage) {
        [System.Windows.MessageBox]::Show("Download $Label fehlgeschlagen:`n`n$ErrorMessage", 'Fehler', 'OK', 'Error') | Out-Null
        Cleanup-DeployState
        return
    }
    $state = $script:DeployState
    if (-not $state) { return }
    $rel = $state.Release
    switch ($state.Phase) {
        'DL-Student' {
            $state.Phase = 'DL-Teacher'
            Start-RunspaceDownload -Url $rel.Teacher.DownloadUrl -Target $state.TmpTeacher `
                                   -Label 'Teacher' -ExpectedSize $rel.Teacher.Size
        }
        'DL-Teacher' {
            $state.Phase = 'Deploy'
            Invoke-DeployLoop
        }
    }
}
function Invoke-DeployLoop {
    $state = $script:DeployState
    $rel   = $state.Release
    $errs  = @()
    try {
        foreach ($s in $state.Tasks) {
            Set-Status "Deploy -> $($s.DisplayName) ..."
            $script:Window.Dispatcher.Invoke([Action]{}, 'Background')
            try {
                $null = Deploy-MSIToShare -SourceMSI $state.TmpStudent -SharePath $s.StudentSharePath `
                            -Role 'Student' -Version $rel.Student.Version `
                            -BuildDate $rel.Student.BuildDate -FileName $rel.Student.FileName
                $null = Deploy-MSIToShare -SourceMSI $state.TmpTeacher -SharePath $s.TeacherSharePath `
                            -Role 'Teacher' -Version $rel.Teacher.Version `
                            -BuildDate $rel.Teacher.BuildDate -FileName $rel.Teacher.FileName
                Write-Log -Message "Deployed $($s.DisplayName): Student $($rel.Student.Version) / Teacher $($rel.Teacher.Version)" -Level INFO -Source 'MSIPull'
            } catch {
                $errs += "$($s.DisplayName): $_"
                Write-Log -Message "Deploy-Fehler $($s.DisplayName): $_" -Level ERROR -Source 'MSIPull'
            }
        }
        $dur = (Get-Date) - $state.StartTime
        if ($errs.Count -eq 0) {
            Set-Status ("Deploy abgeschlossen: {0} Task(s) in {1:N0}s" -f $state.Tasks.Count, $dur.TotalSeconds)
            [System.Windows.MessageBox]::Show("Fertig. $($state.Tasks.Count) Task(s) aktualisiert ($([math]::Round($dur.TotalSeconds,0))s).", 'Erfolg', 'OK', 'Information') | Out-Null
        } else {
            Set-Status "Deploy teilweise fehlgeschlagen"
            [System.Windows.MessageBox]::Show("Deploy mit Fehlern:`n`n" + ($errs -join "`n"), 'Fehler', 'OK', 'Warning') | Out-Null
        }
    } finally {
        Cleanup-DeployState
    }
}

function Cleanup-DeployState {
    if ($script:DeployState -and $script:DeployState.TempDir -and (Test-Path $script:DeployState.TempDir)) {
        Remove-Item $script:DeployState.TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:DeployState = $null
    $script:btnDeploySelected.IsEnabled = $true
    $script:btnDeployAll.IsEnabled      = $true
    $script:btnReleaseRefresh.IsEnabled = $true
    $script:btnRefreshStatus.IsEnabled  = $true
    $script:Window.Cursor = $null
    try { Refresh-MSITaskStatus } catch {}
}

$script:btnReleaseRefresh.Add_Click({ Update-ReleaseDisplay; Refresh-MSITaskStatus })
$script:btnReleaseChangelog.Add_Click({ Show-ReleaseChangelog })
$script:btnRefreshStatus.Add_Click({
    Show-LoadingOverlay
    Set-Status "Lade MSI-Status..."
    try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
    try { Refresh-MSITaskStatus; Set-Status "MSI-Status aktualisiert" } finally { Hide-LoadingOverlay }
})

$script:btnDeploySelected.Add_Click({
    $selRows = @($script:lstMSITasks.SelectedItems)
    if ($selRows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Kein Task markiert. Mit Linksklick (oder Strg/Shift + Klick fuer mehrere) auswaehlen.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    $tasks = @($selRows | ForEach-Object { $_._Task })
    Invoke-DeployToTasks -Tasks $tasks
})

$script:btnDeployAll.Add_Click({
    $tasks = @($script:Config.Tasks)
    if ($tasks.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks konfiguriert. Bitte zuerst im Settings-Tab anlegen.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-DeployToTasks -Tasks $tasks
})

function Update-AutoPullStatusDisplay {
    try {
        $t = Test-AutoPullTask
        if ($t.Exists) {
            $nr = if ($t.NextRun) { $t.NextRun.ToString('yyyy-MM-dd HH:mm') } else { '-' }
            # 267011 = 0x41303 = SCHED_S_TASK_HAS_NOT_RUN. 1999-11-30 ist Never-Run-Marker
            $neverRun = ($t.LastResult -eq 267011) -or (-not $t.LastRun) -or ($t.LastRun.Year -lt 2000)
            $lr = if ($neverRun) { 'nie' } else { $t.LastRun.ToString('yyyy-MM-dd HH:mm') }
            $rc = if ($neverRun) { '' } elseif ($null -ne $t.LastResult) { " (ExitCode $($t.LastResult))" } else { '' }
            $script:lblAutoPullStatus.Text = "Registriert | Naechste: $nr | Letzte: $lr$rc"
            $script:chkAutoPull.IsChecked  = $true
            if ($t.Trigger -and $t.Trigger.StartBoundary) {
                try { $script:txtAutoPullTime.Text = ([datetime]$t.Trigger.StartBoundary).ToString('HH:mm') } catch {}
            }
        } else {
            $script:lblAutoPullStatus.Text = '(nicht registriert)'
            $script:chkAutoPull.IsChecked  = $false
        }
    } catch {
        $script:lblAutoPullStatus.Text = "Status-Fehler: $_"
    }
}

$script:chkAutoPull.Add_Click({
    try {
        if ($script:chkAutoPull.IsChecked) {
            $time = $script:txtAutoPullTime.Text
            if ($time -notmatch '^\d{1,2}:\d{2}$') {
                [System.Windows.MessageBox]::Show('Zeit-Format: HH:mm (z.B. 03:00)', 'Hinweis', 'OK', 'Warning') | Out-Null
                $script:chkAutoPull.IsChecked = $false
                return
            }
            $sp = Join-Path $script:RootPath 'HU-NextExam-Manager.ps1'
            $principal = if ($script:rbAutoPullSystem.IsChecked) { 'System' } else { 'User' }
            $null = Register-AutoPullTask -ScriptPath $sp -Time $time -Principal $principal
            if (-not ($script:Config.ToolSettings.PSObject.Properties.Name -contains 'AutoPullPrincipal')) {
                $script:Config.ToolSettings | Add-Member -NotePropertyName 'AutoPullPrincipal' -NotePropertyValue 'System' -Force
            }
            $script:Config.ToolSettings.AutoPullEnabled      = $true
            $script:Config.ToolSettings.AutoPullScheduleTime = $time
            $script:Config.ToolSettings.AutoPullPrincipal    = $principal
            Save-Config -Config $script:Config
            Set-Status "Auto-Pull registriert (taeglich $time)"
        } else {
            $null = Unregister-AutoPullTask
            $script:Config.ToolSettings.AutoPullEnabled = $false
            Save-Config -Config $script:Config
            Set-Status 'Auto-Pull entfernt'
        }
        Update-AutoPullStatusDisplay
    } catch {
        [System.Windows.MessageBox]::Show("Auto-Pull Fehler:`n`n$_", 'Fehler', 'OK', 'Error') | Out-Null
        Update-AutoPullStatusDisplay
    }
})

$script:txtAutoPullTime.Add_LostFocus({
    # Wenn bereits aktiv: bei Zeit-Aenderung re-registrieren
    if ($script:chkAutoPull.IsChecked) {
        $time = $script:txtAutoPullTime.Text
        if ($time -match '^\d{1,2}:\d{2}$') {
            try {
                $sp = Join-Path $script:RootPath 'HU-NextExam-Manager.ps1'
                $principal = if ($script:rbAutoPullSystem.IsChecked) { 'System' } else { 'User' }
                $null = Register-AutoPullTask -ScriptPath $sp -Time $time -Principal $principal
                $script:Config.ToolSettings.AutoPullScheduleTime = $time
                Save-Config -Config $script:Config
                Update-AutoPullStatusDisplay
                Set-Status "Auto-Pull Zeit aktualisiert ($time)"
            } catch {}
        }
    }
})

# ========== GPO Setup Tab ==========
$script:lstGPOTasks   = Get-UI 'lstGPOTasks'
$script:btnGPORefresh = Get-UI 'btnGPORefresh'
$script:btnGPOCreate    = Get-UI 'btnGPOCreate'
$script:btnGPOCreateFW  = Get-UI 'btnGPOCreateFW'
$script:btnGPOLink    = Get-UI 'btnGPOLink'
$script:btnGPORemove  = Get-UI 'btnGPORemove'
$script:txtGPODetail  = Get-UI 'txtGPODetail'

function Get-InstallGPONames {
    param($Task)
    $prefix = if ($Task.GPONamePrefix) { $Task.GPONamePrefix } else { 'HU-NEXT-EXAM-' }
    [PSCustomObject]@{
        Student    = "$($prefix)Student-Install"
        Teacher    = "$($prefix)Teacher-Install"
        StudentFW  = "$($prefix)Firewall Student"
        TeacherFW  = "$($prefix)Firewall Teacher"
        StudentWMI = "$($prefix)WMI Student"
        TeacherWMI = "$($prefix)WMI Teacher"
    }
}

function Refresh-GPOTaskStatusAsync {
    <#
    .SYNOPSIS
        Startet GPO-Status-Refresh im Runspace (UI bleibt reaktiv + Overlay animiert).
    #>
    param([scriptblock]$OnComplete)

    $tasks = @($script:Config.Tasks | ForEach-Object {
        # Nur serialisierbare Felder
        @{
            Id                = $_.Id
            DisplayName       = $_.DisplayName
            DomainFQDN        = $_.DomainFQDN
            DCServer          = $_.DCServer
            OUTargetStudent   = $_.OUTargetStudent
            OUTargetTeacher   = $_.OUTargetTeacher
            StudentSharePath  = $_.StudentSharePath
            TeacherSharePath  = $_.TeacherSharePath
            GPONamePrefix     = if ($_.GPONamePrefix) { $_.GPONamePrefix } else { 'HU-NEXT-EXAM-' }
        }
    })

    $modPath = $script:ModulesPath

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create().AddScript({
        param($tasks, $modPath)
        try {
            Import-Module (Join-Path $modPath 'GPOSetup.psm1')  -Force -Global -DisableNameChecking
            Import-Module GroupPolicy, ActiveDirectory -ErrorAction SilentlyContinue
        } catch {}

        $rows = @()
        foreach ($t in $tasks) {
            $prefix = $t.GPONamePrefix
            $names = @{
                Student   = "$($prefix)Student-Install"
                Teacher   = "$($prefix)Teacher-Install"
                StudentFW = "$($prefix)Firewall Student"
                TeacherFW = "$($prefix)Firewall Teacher"
            }
            $sStat = 'fehlt'; $tStat = 'fehlt'; $sLink = '-'; $tLink = '-'
            $sFW = '-'; $tFW = '-'
            if ($t.DomainFQDN) {
                try {
                    $s = Get-NextExamInstallGPOStatus -GPOName $names.Student -DomainFQDN $t.DomainFQDN -Server $t.DCServer -LinkOU $t.OUTargetStudent
                    if ($s.Exists) {
                        $sStat = if ($s.ScriptOK) { 'OK' } else { 'unvollstaendig' }
                        $sLink = if ($s.LinkedToThis) { 'verknuepft' } elseif ($s.LinkedTo.Count -gt 0) { 'andere OU' } else { 'nicht verknuepft' }
                    }
                } catch { $sStat = 'FEHLER' }
                try {
                    $te = Get-NextExamInstallGPOStatus -GPOName $names.Teacher -DomainFQDN $t.DomainFQDN -Server $t.DCServer -LinkOU $t.OUTargetTeacher
                    if ($te.Exists) {
                        $tStat = if ($te.ScriptOK) { 'OK' } else { 'unvollstaendig' }
                        $tLink = if ($te.LinkedToThis) { 'verknuepft' } elseif ($te.LinkedTo.Count -gt 0) { 'andere OU' } else { 'nicht verknuepft' }
                    }
                } catch { $tStat = 'FEHLER' }
                try {
                    $s2 = Get-NextExamFWGPOStatus -GPOName $names.StudentFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                    if ($s2.Exists) { $sFW = "OK ($($s2.RuleCount) Rules)" } else { $sFW = 'fehlt' }
                } catch { $sFW = 'FEHLER' }
                try {
                    $t2 = Get-NextExamFWGPOStatus -GPOName $names.TeacherFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                    if ($t2.Exists) { $tFW = "OK ($($t2.RuleCount) Rules)" } else { $tFW = 'fehlt' }
                } catch { $tFW = 'FEHLER' }
            } else { $sStat = '(Domain fehlt)'; $tStat = '(Domain fehlt)' }

            $rows += [PSCustomObject]@{
                Id = $t.Id; DisplayName = $t.DisplayName; DomainFQDN = $t.DomainFQDN
                StudentGPOStatus = $sStat; TeacherGPOStatus = $tStat
                StudentLinkStatus = $sLink; TeacherLinkStatus = $tLink
                StudentFWStatus = $sFW; TeacherFWStatus = $tFW
            }
        }
        return ,$rows
    }).AddArgument($tasks).AddArgument($modPath)

    $ps.Runspace = $rs
    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try {
                $result = $ps.EndInvoke($handle)
                $rowsAsync = @($result[0])
                # _Task zurueck-mappen (Runspace-Objekte haben kein _Task)
                $mapped = foreach ($r in $rowsAsync) {
                    $task = $script:Config.Tasks | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
                    $r | Add-Member -NotePropertyName '_Task' -NotePropertyValue $task -Force -PassThru
                }
                $script:lstGPOTasks.ItemsSource = @($mapped)
                try { Update-GPODetailPanel } catch {}
            } catch {
                Write-Log -Message "GPOStatus-Async Fehler: $_" -Level ERROR -Source 'GPOSetup'
            } finally {
                try { $ps.Dispose() } catch {}
                try { $rs.Close(); $rs.Dispose() } catch {}
            }
            if ($OnComplete) { & $OnComplete }
        }
    })
    $timer.Start()
}

function Refresh-GPOTaskStatus {
    $rows = @()
    $all  = @($script:Config.Tasks)
    $n    = $all.Count
    $idx  = 0
    foreach ($t in $all) {
        $idx++
        Set-Status ("GPO-Status {0}/{1}: {2} ..." -f $idx, $n, $t.DisplayName)
        # Dispatcher-Pump: UI + Overlay-Animation aktualisieren
        try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}

        $names = Get-InstallGPONames -Task $t
        $sStat = 'fehlt'; $tStat = 'fehlt'; $sLink = '-'; $tLink = '-'
        if ($t.DomainFQDN) {
            try {
                $s = Get-NextExamInstallGPOStatus -GPOName $names.Student -DomainFQDN $t.DomainFQDN `
                        -Server $t.DCServer -LinkOU $t.OUTargetStudent
                if ($s.Exists) {
                    $sStat = if ($s.ScriptOK) { 'OK' } else { 'unvollstaendig' }
                    $sLink = if ($s.LinkedToThis) { 'verknuepft' } elseif ($s.LinkedTo.Count -gt 0) { 'andere OU' } else { 'nicht verknuepft' }
                }
            } catch { $sStat = "FEHLER" }
            try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
            try {
                $te = Get-NextExamInstallGPOStatus -GPOName $names.Teacher -DomainFQDN $t.DomainFQDN `
                        -Server $t.DCServer -LinkOU $t.OUTargetTeacher
                if ($te.Exists) {
                    $tStat = if ($te.ScriptOK) { 'OK' } else { 'unvollstaendig' }
                    $tLink = if ($te.LinkedToThis) { 'verknuepft' } elseif ($te.LinkedTo.Count -gt 0) { 'andere OU' } else { 'nicht verknuepft' }
                }
            } catch { $tStat = "FEHLER" }
            try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
        } else { $sStat = '(Domain fehlt)'; $tStat = '(Domain fehlt)' }

        # FW-GPO
        $sFW = '-'; $tFW = '-'
        if ($t.DomainFQDN) {
            try {
                $s2 = Get-NextExamFWGPOStatus -GPOName $names.StudentFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                if ($s2.Exists) { $sFW = "OK ($($s2.RuleCount) Rules)" } else { $sFW = 'fehlt' }
            } catch { $sFW = 'FEHLER' }
            try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
            try {
                $t2 = Get-NextExamFWGPOStatus -GPOName $names.TeacherFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                if ($t2.Exists) { $tFW = "OK ($($t2.RuleCount) Rules)" } else { $tFW = 'fehlt' }
            } catch { $tFW = 'FEHLER' }
            try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
        }

        $rows += [PSCustomObject]@{
            Id                 = $t.Id
            DisplayName        = $t.DisplayName
            DomainFQDN         = $t.DomainFQDN
            StudentGPOStatus   = $sStat
            TeacherGPOStatus   = $tStat
            StudentLinkStatus  = $sLink
            TeacherLinkStatus  = $tLink
            StudentFWStatus    = $sFW
            TeacherFWStatus    = $tFW
            _Task              = $t
        }
    }
    $script:lstGPOTasks.ItemsSource = $rows
    Update-GPODetailPanel
}

function Apply-WMIFilterToGPOs {
    <#
    .SYNOPSIS
        Erstellt (falls noetig) WMI-Filter aus Task-Pattern und verknuepft mit den 4 GPOs.
    .OUTPUTS
        Array von Status-Strings (infos + errors).
    #>
    param([Parameter(Mandatory)]$Task)

    $report = @()
    if (-not $Task.DomainFQDN) { return ,$report }
    $names = Get-InstallGPONames -Task $Task

    foreach ($role in @('Student','Teacher')) {
        $pattern = if ($role -eq 'Student') { $Task.WMIFilterStudentPattern } else { $Task.WMIFilterTeacherPattern }
        $type    = if ($role -eq 'Student') { $Task.WMIFilterStudentType }    else { $Task.WMIFilterTeacherType }
        if (-not $pattern) { continue }
        if (-not $type) { $type = 'Custom' }

        $filterName = if ($role -eq 'Student') { $names.StudentWMI } else { $names.TeacherWMI }
        $installGPO = if ($role -eq 'Student') { $names.Student } else { $names.Teacher }
        $fwGPO      = if ($role -eq 'Student') { $names.StudentFW } else { $names.TeacherFW }

        try {
            $query = ConvertTo-WQLQuery -Type $type -Value $pattern
        } catch {
            $msg = "WMI-Query ${role}: $_"
            Write-Log -Message $msg -Level ERROR -Source 'WMIFilter'
            $report += "FEHLER $msg"
            continue
        }

        try {
            $existing = Get-WMIFilter -DomainFQDN $Task.DomainFQDN -Server $Task.DCServer -Name $filterName
            if (-not $existing) {
                $null = New-WMIFilter -DomainFQDN $Task.DomainFQDN -Server $Task.DCServer `
                            -Name $filterName -Description "HU-NextExam-Manager Task $($Task.DisplayName) $role" `
                            -Query $query
                Write-Log -Message "WMI-Filter erstellt: $filterName" -Level INFO -Source 'WMIFilter'
                $report += "OK erstellt: $filterName"
            } else {
                $report += "OK vorhanden: $filterName"
            }
            foreach ($gpoN in @($installGPO, $fwGPO)) {
                try {
                    Set-WMIFilterOnGPO -DomainFQDN $Task.DomainFQDN -Server $Task.DCServer `
                                       -GPOName $gpoN -WMIFilterName $filterName
                    Write-Log -Message "WMI-Filter $filterName an GPO $gpoN" -Level INFO -Source 'WMIFilter'
                    $report += "OK zugewiesen: $filterName -> $gpoN"
                } catch {
                    $msg = "WMI-Assign $filterName -> ${gpoN}: $($_.Exception.Message)"
                    Write-Log -Message $msg -Level WARN -Source 'WMIFilter'
                    $report += "FEHLER $msg"
                }
            }
        } catch {
            $msg = "WMI-Handling ${role}: $($_.Exception.Message)"
            Write-Log -Message $msg -Level ERROR -Source 'WMIFilter'
            $report += "FEHLER $msg"
        }
    }
    return ,$report
}

function Test-IsElevated {
    $p = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedRestart {
    $exe    = (Get-Command powershell.exe).Source
    $script = Join-Path $script:RootPath 'HU-NextExam-Manager.ps1'
    try {
        Start-Process $exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`""
        Start-Sleep -Milliseconds 500
        $script:Window.Close()
    } catch {
        [System.Windows.MessageBox]::Show("Elevation abgebrochen oder fehlgeschlagen:`n`n$_", 'Fehler', 'OK', 'Error') | Out-Null
    }
}

function Invoke-GPOCreateForTasks {
    param([object[]]$Tasks)
    $tmpl = Join-Path $script:RootPath 'Templates\Startup-NextExam.ps1'
    if (-not (Test-Path $tmpl)) {
        [System.Windows.MessageBox]::Show("Startup-Template fehlt: $tmpl", 'Fehler', 'OK', 'Error') | Out-Null
        return
    }

    $errs = @(); $ok = 0
    foreach ($t in $Tasks) {
        if (-not $t.DomainFQDN -or -not $t.StudentSharePath -or -not $t.TeacherSharePath) {
            $errs += "$($t.DisplayName): Domain/Shares fehlen"; continue
        }
        $names = Get-InstallGPONames -Task $t
        foreach ($role in @('Student','Teacher')) {
            $share  = if ($role -eq 'Student') { $t.StudentSharePath } else { $t.TeacherSharePath }
            $gpoN   = if ($role -eq 'Student') { $names.Student } else { $names.Teacher }
            try {
                Set-Status "Erstelle GPO '$gpoN' ..."
                $null = New-NextExamInstallGPO -GPOName $gpoN -Role $role `
                            -SharePath $share -DomainFQDN $t.DomainFQDN `
                            -Server $t.DCServer -StartupTemplatePath $tmpl `
                            -StatusPath $t.StatusSharePath
                Write-Log -Message "GPO angelegt/aktualisiert: $gpoN ($role, $share)" -Level INFO -Source 'GPOSetup'
                $ok++
            } catch {
                $exMsg = $_.Exception.Message
                $isAccess = $exMsg -match '0x80070005|E_ACCESSDENIED|wurde verweigert|Access.*denied|nicht gefunden|gpoDisplayName'
                Write-Log -Message "GPO-Create ${gpoN}: $_ | Pos: $($_.InvocationInfo.PositionMessage)" -Level ERROR -Source 'GPOSetup'

                if ($isAccess) {
                    $res = [System.Windows.MessageBox]::Show(
                        "GPO '$gpoN' laesst sich nicht aktualisieren (psscripts.ini-Schreibzugriff verweigert).`n`n" +
                        "Tritt auf wenn die Datei in einem frueheren Tool-Lauf mit anderer Ownership angelegt wurde.`n`n" +
                        "Diese eine GPO via Remove-GPO loeschen und neu anlegen?`n`n" +
                        "HINWEIS: Remove-GPO loescht NUR diese GPO (AD-Objekt + den Unterordner" +
                        " SYSVOL\Policies\{GUID-dieser-GPO}\). Andere GPOs, SYSVOL und AD bleiben unberuehrt.`n" +
                        "Bestehende OU-Verknuepfungen DIESER GPO gehen verloren und muessen neu gesetzt werden.",
                        "Einzelne GPO neu anlegen?", 'YesNo', 'Question')
                    if ($res -eq 'Yes') {
                        try {
                            Set-Status "Entferne alte GPO $gpoN ..."
                            Remove-NextExamInstallGPO -GPOName $gpoN -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                            Start-Sleep -Seconds 1
                            Set-Status "Erstelle neu: $gpoN ..."
                            $null = New-NextExamInstallGPO -GPOName $gpoN -Role $role `
                                        -SharePath $share -DomainFQDN $t.DomainFQDN `
                                        -Server $t.DCServer -StartupTemplatePath $tmpl `
                                        -StatusPath $t.StatusSharePath
                            Write-Log -Message "GPO $gpoN frisch neu angelegt" -Level INFO -Source 'GPOSetup'
                            $ok++
                            continue
                        } catch {
                            $errs += "$($t.DisplayName)/$role ($gpoN) - Neu-Anlegen fehlgeschlagen: $($_.Exception.Message)"
                            continue
                        }
                    }
                }
                $errs += "$($t.DisplayName)/$role ($gpoN): $exMsg"
            }
        }
    }
    Refresh-GPOTaskStatus
    # Alle WMI-Reports sammeln (erneut) fuer detaillierte Anzeige
    $allWmi = @()
    foreach ($t in $Tasks) {
        $pattern = $t.WMIFilterStudentPattern; $pattern2 = $t.WMIFilterTeacherPattern
        if ($pattern -or $pattern2) {
            $allWmi += "=== Task: $($t.DisplayName) ==="
            try { $r = Apply-WMIFilterToGPOs -Task $t; $allWmi += $r } catch { $allWmi += "FEHLER Apply: $_" }
        }
    }
    $msg = "$ok GPO(s) erstellt/aktualisiert."
    if ($allWmi.Count -gt 0) { $msg += "`n`nWMI-Filter:`n" + ($allWmi -join "`n") }
    if ($errs.Count -eq 0) {
        [System.Windows.MessageBox]::Show($msg, 'Erfolg', 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.MessageBox]::Show("$msg`n`nFehler:`n" + ($errs -join "`n"), 'Fehler', 'OK', 'Warning') | Out-Null
    }
}

function Invoke-GPOLinkForTasks {
    param([object[]]$Tasks)
    $errs = @(); $ok = 0
    foreach ($t in $Tasks) {
        if (-not $t.DomainFQDN) { $errs += "$($t.DisplayName): Domain fehlt"; continue }
        $names = Get-InstallGPONames -Task $t
        # Install-GPOs + FW-GPOs werden beide verknuepft
        $linkSet = @(
            @{ Name = $names.Student;   OU = $t.OUTargetStudent; Role = 'Student' },
            @{ Name = $names.Teacher;   OU = $t.OUTargetTeacher; Role = 'Teacher' },
            @{ Name = $names.StudentFW; OU = $t.OUTargetStudent; Role = 'Student(FW)' },
            @{ Name = $names.TeacherFW; OU = $t.OUTargetTeacher; Role = 'Teacher(FW)' }
        )
        foreach ($ls in $linkSet) {
            $gpoN = $ls.Name
            $ou   = $ls.OU
            $role = $ls.Role
            if (-not $ou) { $errs += "$($t.DisplayName)/${role}: OUTarget fehlt"; continue }
            # Sanity-Check: OU muss ein DN sein (OU=..., DC=...)
            if ($ou -notmatch '^(OU|CN|DC)=') {
                $errs += "$($t.DisplayName)/${role}: '$ou' ist kein DistinguishedName (erwartet: OU=Name,DC=domain,DC=tld)"
                continue
            }
            try {
                Set-Status "Verknuepfe '$gpoN' mit $ou ..."
                Set-NextExamGPOLink -GPOName $gpoN -DomainFQDN $t.DomainFQDN -Server $t.DCServer -OUDistinguishedName $ou
                Write-Log -Message "GPO $gpoN verknuepft mit $ou" -Level INFO -Source 'GPOSetup'
                $ok++
            } catch {
                $errs += "$($t.DisplayName)/${role}: $($_.Exception.Message)"
                Write-Log -Message "GPO-Link ${gpoN}: $_" -Level ERROR -Source 'GPOSetup'
            }
        }
    }
    Refresh-GPOTaskStatus
    if ($errs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("$ok Link(s) erstellt.", 'Erfolg', 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.MessageBox]::Show("$ok OK, Fehler:`n`n" + ($errs -join "`n"), 'Warnung', 'OK', 'Warning') | Out-Null
    }
}

function Invoke-GPORemoveForTasks {
    param([object[]]$Tasks)
    $names = @($Tasks | ForEach-Object { $_.DisplayName }) -join ', '
    $res = [System.Windows.MessageBox]::Show(
        "Alle Install-GPOs fuer $($Tasks.Count) Task(s) entfernen?`n`n$names`n`nDies loescht die GPOs komplett aus AD und SYSVOL.",
        'Bestaetigen', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }
    $errs = @(); $ok = 0
    foreach ($t in $Tasks) {
        if (-not $t.DomainFQDN) { continue }
        $ns = Get-InstallGPONames -Task $t
        foreach ($gpoN in @($ns.Student, $ns.Teacher, $ns.StudentFW, $ns.TeacherFW)) {
            try {
                Set-Status "Entferne GPO '$gpoN' ..."
                Remove-NextExamInstallGPO -GPOName $gpoN -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                Write-Log -Message "GPO entfernt: $gpoN" -Level INFO -Source 'GPOSetup'
                $ok++
            } catch {
                if ($_.Exception.Message -match 'not found|nicht gefunden') {
                    # OK - gab es nicht
                } else {
                    $errs += "$($t.DisplayName) ($gpoN): $($_.Exception.Message)"
                }
            }
        }
    }
    Refresh-GPOTaskStatus
    if ($errs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("$ok GPO(s) entfernt.", 'Erfolg', 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.MessageBox]::Show("$ok OK, Fehler:`n`n" + ($errs -join "`n"), 'Warnung', 'OK', 'Warning') | Out-Null
    }
}

function Invoke-FWGPOCreateForTasks {
    param([object[]]$Tasks)
    $errs = @(); $ok = 0
    foreach ($t in $Tasks) {
        if (-not $t.DomainFQDN) { $errs += "$($t.DisplayName): Domain fehlt"; continue }
        if (-not $t.FWStudentExe -or -not $t.FWTeacherExe) { $errs += "$($t.DisplayName): FW-EXE-Pfade fehlen"; continue }
        $names = Get-InstallGPONames -Task $t
        $profiles = @($t.FWProfiles)
        if (-not $profiles -or $profiles.Count -eq 0) { $profiles = @('Domain','Private') }

        $jobs = @(
            @{ Name = $names.StudentFW; Role = 'Student'; Exe = $t.FWStudentExe },
            @{ Name = $names.TeacherFW; Role = 'Teacher'; Exe = $t.FWTeacherExe }
        )
        foreach ($j in $jobs) {
            try {
                Set-Status "Erstelle FW-GPO '$($j.Name)' ..."
                $null = New-NextExamFWGPO -GPOName $j.Name -Role $j.Role `
                            -DomainFQDN $t.DomainFQDN -Server $t.DCServer `
                            -ExePath $j.Exe -Profiles $profiles `
                            -EnableTCPPort ([bool]$t.FWEnableTCPPort) -TCPPort ([int]$t.FWTCPPort) `
                            -EnableUDPPort ([bool]$t.FWEnableUDPPort) -UDPPorts $t.FWUDPPorts
                Write-Log -Message "FW-GPO angelegt/aktualisiert: $($j.Name) ($($j.Role))" -Level INFO -Source 'GPOSetup'
                $ok++
            } catch {
                $exMsg = $_.Exception.Message
                $isAccess = $exMsg -match '0x80070005|E_ACCESSDENIED|wurde verweigert|Access.*denied|nicht gefunden|gpoDisplayName'
                Write-Log -Message "FW-GPO-Create $($j.Name): $exMsg | Pos: $($_.InvocationInfo.PositionMessage)" -Level ERROR -Source 'GPOSetup'
                if ($isAccess) {
                    $res = [System.Windows.MessageBox]::Show(
                        "FW-GPO '$($j.Name)' Fehler beim Anlegen/Aktualisieren:`n$exMsg`n`n" +
                        "FW-GPO via Remove-GPO loeschen und neu anlegen?`n`n" +
                        "HINWEIS: Remove-GPO loescht NUR diese FW-GPO. OU-Verknuepfungen und FW-Rules DIESER GPO gehen verloren.",
                        "FW-GPO neu anlegen?", 'YesNo', 'Question')
                    if ($res -eq 'Yes') {
                        try {
                            Remove-NextExamInstallGPO -GPOName $j.Name -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                            Start-Sleep -Seconds 1
                            $null = New-NextExamFWGPO -GPOName $j.Name -Role $j.Role `
                                        -DomainFQDN $t.DomainFQDN -Server $t.DCServer `
                                        -ExePath $j.Exe -Profiles $profiles `
                                        -EnableTCPPort ([bool]$t.FWEnableTCPPort) -TCPPort ([int]$t.FWTCPPort) `
                                        -EnableUDPPort ([bool]$t.FWEnableUDPPort) -UDPPorts $t.FWUDPPorts
                            Write-Log -Message "FW-GPO $($j.Name) frisch neu angelegt" -Level INFO -Source 'GPOSetup'
                            $ok++
                            continue
                        } catch {
                            $errs += "$($t.DisplayName)/$($j.Role) - Neu-Anlegen fehlgeschlagen: $($_.Exception.Message)"
                            continue
                        }
                    }
                }
                $errs += "$($t.DisplayName)/$($j.Role): $exMsg"
            }
        }
        # WMI-Filter auch fuer FW-GPOs zuweisen
        try {
            $wmiReport = Apply-WMIFilterToGPOs -Task $t
            if ($wmiReport) {
                foreach ($line in $wmiReport) {
                    if ($line -like 'FEHLER*') { $errs += "WMI $($t.DisplayName): $line" }
                }
            }
        } catch { Write-Log -Message "WMI-Apply FW: $_" -Level WARN -Source 'GPOSetup'; $errs += "WMI-Apply FW $($t.DisplayName): $_" }
    }
    Refresh-GPOTaskStatus
    if ($errs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("$ok FW-GPO(s) erstellt/aktualisiert.", 'Erfolg', 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.MessageBox]::Show("$ok OK, Fehler:`n`n" + ($errs -join "`n"), 'Fehler', 'OK', 'Warning') | Out-Null
    }
}

$script:btnGPOCreateFW.Add_Click({
    $rows = @($script:lstGPOTasks.SelectedItems)
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks markiert.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-FWGPOCreateForTasks -Tasks @($rows | ForEach-Object { $_._Task })
})

function Update-GPODetailPanel {
    $row = $script:lstGPOTasks.SelectedItem
    if (-not $row) { $script:txtGPODetail.Text = 'Keine Task markiert.'; return }
    $t = $row._Task
    $names = Get-InstallGPONames -Task $t

    $profs = if ($t.FWProfiles) { ($t.FWProfiles -join ', ') } else { '(default: Domain, Private)' }
    $tcp   = if ($t.FWEnableTCPPort) { "aktiv ($($t.FWTCPPort))" } else { 'aus' }
    $udp   = if ($t.FWEnableUDPPort) { "aktiv ($($t.FWUDPPorts))" } else { 'aus' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Task: $($t.DisplayName)")
    [void]$sb.AppendLine("Domain: $($t.DomainFQDN)  |  DC: $($t.DCServer)")
    [void]$sb.AppendLine(('-' * 70))
    [void]$sb.AppendLine("INSTALL-GPOs")
    [void]$sb.AppendLine("  $($names.Student)")
    [void]$sb.AppendLine("    Share:   $($t.StudentSharePath)")
    [void]$sb.AppendLine("    OU:      $($t.OUTargetStudent)")
    [void]$sb.AppendLine("    Status:  $($row.StudentGPOStatus) | Link: $($row.StudentLinkStatus)")
    [void]$sb.AppendLine("  $($names.Teacher)")
    [void]$sb.AppendLine("    Share:   $($t.TeacherSharePath)")
    [void]$sb.AppendLine("    OU:      $($t.OUTargetTeacher)")
    [void]$sb.AppendLine("    Status:  $($row.TeacherGPOStatus) | Link: $($row.TeacherLinkStatus)")
    [void]$sb.AppendLine(('-' * 70))
    [void]$sb.AppendLine("FIREWALL-GPOs  [Profile: $profs | TCP: $tcp | UDP: $udp]")
    [void]$sb.AppendLine("  $($names.StudentFW)")
    [void]$sb.AppendLine("    EXE:     $($t.FWStudentExe)")
    [void]$sb.AppendLine("    Status:  $($row.StudentFWStatus)")
    [void]$sb.AppendLine("  $($names.TeacherFW)")
    [void]$sb.AppendLine("    EXE:     $($t.FWTeacherExe)")
    [void]$sb.AppendLine("    Status:  $($row.TeacherFWStatus)")
    [void]$sb.AppendLine(('-' * 70))
    $sType = if ($t.WMIFilterStudentType) { $t.WMIFilterStudentType } else { 'Custom' }
    $tType = if ($t.WMIFilterTeacherType) { $t.WMIFilterTeacherType } else { 'Custom' }
    [void]$sb.AppendLine("WMI-FILTER  (wird bei GPO-Create automatisch erzeugt + zugewiesen falls Pattern gesetzt)")
    [void]$sb.AppendLine("  Student [$sType]: $($t.WMIFilterStudentPattern)")
    [void]$sb.AppendLine("  Teacher [$tType]: $($t.WMIFilterTeacherPattern)")

    $script:txtGPODetail.Text = $sb.ToString()
}

$script:lstGPOTasks.Add_SelectionChanged({ Update-GPODetailPanel })

$script:btnGPORefresh.Add_Click({
    Show-LoadingOverlay
    Set-Status "Lade GPO-Status (kann pro Task ~30s dauern)..."
    try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
    try {
        Refresh-GPOTaskStatus
        Set-Status "GPO-Status aktualisiert"
    } catch {
        Set-Status "Fehler: $($_.Exception.Message)"
    } finally {
        Hide-LoadingOverlay
    }
})

$script:btnGPOCreate.Add_Click({
    $rows = @($script:lstGPOTasks.SelectedItems)
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks markiert.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-GPOCreateForTasks -Tasks @($rows | ForEach-Object { $_._Task })
})

$script:btnGPOLink.Add_Click({
    $rows = @($script:lstGPOTasks.SelectedItems)
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks markiert.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-GPOLinkForTasks -Tasks @($rows | ForEach-Object { $_._Task })
})

$script:btnGPOWMICleanup = Get-UI 'btnGPOWMICleanup'
if ($script:btnGPOWMICleanup) {
$script:btnGPOWMICleanup.Add_Click({
    $rows = @($script:lstGPOTasks.SelectedItems)
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks markiert.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    foreach ($r in $rows) {
        $t = $r._Task
        $prefix = if ($t.GPONamePrefix) { $t.GPONamePrefix + 'WMI' } else { 'HU-NEXT-EXAM-WMI' }
        try {
            $removed = Remove-WMIFilterByPrefix -DomainFQDN $t.DomainFQDN -Server $t.DCServer -Prefix $prefix
            if ($removed.Count -gt 0) {
                [System.Windows.MessageBox]::Show("Entfernt: " + ($removed -join ', '), 'OK', 'OK', 'Information') | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("Keine WMI-Filter mit Prefix '$prefix' gefunden.", 'Info', 'OK', 'Information') | Out-Null
            }
        } catch {
            [System.Windows.MessageBox]::Show("Fehler: $_", 'Fehler', 'OK', 'Error') | Out-Null
        }
    }
    Refresh-GPOTaskStatus
})
}

$script:btnGPORemove.Add_Click({
    $rows = @($script:lstGPOTasks.SelectedItems)
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine Tasks markiert.', 'Hinweis', 'OK', 'Information') | Out-Null
        return
    }
    Invoke-GPORemoveForTasks -Tasks @($rows | ForEach-Object { $_._Task })
})

# ========== Dashboard Tab ==========
$script:lblDashToolVer    = Get-UI 'lblDashToolVer'
$script:lblDashConfigPath = Get-UI 'lblDashConfigPath'
$script:lblDashLogPath    = Get-UI 'lblDashLogPath'
$script:lblDashRelTag     = Get-UI 'lblDashRelTag'
$script:lblDashRelStudent = Get-UI 'lblDashRelStudent'
$script:lblDashRelTeacher = Get-UI 'lblDashRelTeacher'
$script:btnDashRefresh    = Get-UI 'btnDashRefresh'
$script:lstDashTasks      = Get-UI 'lstDashTasks'

function Update-Dashboard {
    $script:lblDashToolVer.Text    = "Tool-Version: $($script:ToolVersion)"
    $script:lblDashConfigPath.Text = "Config: $script:RootPath\config.json"
    $script:lblDashLogPath.Text    = "Log:    $(Expand-LogPath)"

    if ($script:CurrentRelease) {
        $r = $script:CurrentRelease
        $script:lblDashRelTag.Text     = "Tag:        $($r.TagName) - $($r.Name)   Stand: $($r.PublishedAt)"
        $script:lblDashRelStudent.Text = "Student:    $($r.Student.Version) ($($r.Student.BuildDate)) - $($r.Student.FileName)"
        $script:lblDashRelTeacher.Text = "Teacher:    $($r.Teacher.Version) ($($r.Teacher.BuildDate)) - $($r.Teacher.FileName)"
    }

    $rows = @()
    foreach ($t in $script:Config.Tasks) {
        # MSI-Info aus Shares
        $sMsi = '-'; $tMsi = '-'; $msiStatus = '-'
        try {
            if ($t.StudentSharePath -and (Test-Path $t.StudentSharePath -EA SilentlyContinue)) {
                $vi = Read-ShareVersionInfo -SharePath $t.StudentSharePath -Role Student
                if ($vi) { $sMsi = $vi.Version }
            }
            if ($t.TeacherSharePath -and (Test-Path $t.TeacherSharePath -EA SilentlyContinue)) {
                $vi = Read-ShareVersionInfo -SharePath $t.TeacherSharePath -Role Teacher
                if ($vi) { $tMsi = $vi.Version }
            }
        } catch {}
        if ($script:CurrentRelease) {
            $rs = $script:CurrentRelease.Student.Version
            $rt = $script:CurrentRelease.Teacher.Version
            if ($sMsi -like "$rs*" -and $tMsi -like "$rt*") { $msiStatus = 'aktuell' }
            elseif ($sMsi -eq '-' -and $tMsi -eq '-')      { $msiStatus = 'nicht deployed' }
            else                                            { $msiStatus = 'veraltet' }
        }

        # GPO-Status kompakt
        $instStat = '?'; $fwStat = '?'
        if ($t.DomainFQDN) {
            $names = Get-InstallGPONames -Task $t
            try {
                $sS = Get-NextExamInstallGPOStatus -GPOName $names.Student -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                $sT = Get-NextExamInstallGPOStatus -GPOName $names.Teacher -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                $instStat = if ($sS.Exists -and $sT.Exists) { 'beide OK' }
                            elseif (-not $sS.Exists -and -not $sT.Exists) { 'fehlen' }
                            else { 'teilweise' }
            } catch { $instStat = 'Fehler' }
            try {
                $fS = Get-NextExamFWGPOStatus -GPOName $names.StudentFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                $fT = Get-NextExamFWGPOStatus -GPOName $names.TeacherFW -DomainFQDN $t.DomainFQDN -Server $t.DCServer
                $fwStat = if ($fS.Exists -and $fT.Exists) { 'beide OK' }
                          elseif (-not $fS.Exists -and -not $fT.Exists) { 'fehlen' }
                          else { 'teilweise' }
            } catch { $fwStat = 'Fehler' }
        }

        # Gesamt-Ampel
        $overall = if ($msiStatus -eq 'aktuell' -and $instStat -eq 'beide OK' -and $fwStat -eq 'beide OK') { 'OK' }
                   elseif ($msiStatus -eq 'veraltet' -or $instStat -eq 'fehlen' -or $fwStat -eq 'fehlen') { 'Handlungsbedarf' }
                   else { 'pruefen' }

        $rows += [PSCustomObject]@{
            DisplayName      = $t.DisplayName
            StudentMSI       = $sMsi
            TeacherMSI       = $tMsi
            MSIStatus        = $msiStatus
            InstallGPOStatus = $instStat
            FWGPOStatus      = $fwStat
            Overall          = $overall
        }
    }
    $script:lstDashTasks.ItemsSource = @($rows)
}

$script:btnDashRefresh.Add_Click({
    $script:btnDashRefresh.IsEnabled = $false
    Show-LoadingOverlay
    try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
    try {
        Set-Status 'Frage GitHub nach Release...'
        try { Update-ReleaseDisplay } catch {}
        Set-Status 'Lese MSI-Shares...'
        try { Refresh-MSITaskStatus } catch {}
        Set-Status 'Pruefe GPO-Status (kann ~30s dauern)...'
        try { Refresh-GPOTaskStatus } catch {}
        # MDM-Status abfragen wenn Credentials vorhanden
        $mdmTenant = $script:cmbMDMTenant.SelectedItem
        if ($mdmTenant) {
            Set-Status 'Pruefe MDM-Status (Intune)...'
            try {
                # Token holen (automatisch wenn Credentials existieren)
                if (-not (Test-MDMTokenValid)) {
                    if (Test-MDMCredentialExists -TenantId $mdmTenant.TenantId) {
                        $script:MDMToken = Get-MDMToken -TenantId $mdmTenant.TenantId -Mode 'AppCredentials'
                    }
                }
                if (Test-MDMTokenValid) {
                    # GitHub-Version
                    $rel = Get-NextExamLatestRelease
                    if ($rel.Student) { $script:MDMLastCheck['StudentGH'] = $rel.Student.Version }
                    if ($rel.Teacher) { $script:MDMLastCheck['TeacherGH'] = $rel.Teacher.Version }
                    # Intune-Versionen
                    foreach ($role in 'Student','Teacher') {
                        $app = Get-NextExamIntuneApp -AccessToken $script:MDMToken.AccessToken -DisplayNameFilter "Next-Exam-$role"
                        if ($app) {
                            $script:MDMLastCheck["${role}Intune"] = $app.appVersion
                            $script:MDMLastCheck["${role}App"]    = $app
                        } else {
                            $script:MDMLastCheck["${role}Intune"] = $null
                            $script:MDMLastCheck["${role}App"]    = $null
                        }
                    }
                    Update-MDMDashboardWidget
                    Update-MDMAuthStatusUI 'Verbunden (App-Token)' '#107C10'
                }
            } catch {
                Write-Log "Dashboard MDM-Check fehlgeschlagen: $_" -Level WARN -Source 'MDM-UI'
            }
        }
        Update-Dashboard
        Set-Status 'Dashboard aktualisiert'
    } finally {
        $script:btnDashRefresh.IsEnabled = $true
        Hide-LoadingOverlay
    }
})

# ========== Log-Viewer Tab ==========
$script:cmbLogLevel   = Get-UI 'cmbLogLevel'
$script:txtLogSearch  = Get-UI 'txtLogSearch'
$script:lblLogFile    = Get-UI 'lblLogFile'
$script:btnLogRefresh = Get-UI 'btnLogRefresh'
$script:btnLogOpenDir = Get-UI 'btnLogOpenDir'
$script:btnLogClear   = Get-UI 'btnLogClear'
$script:txtLogContent = Get-UI 'txtLogContent'

function Update-LogView {
    $path = Expand-LogPath
    $script:lblLogFile.Text = $path
    if (-not $path -or -not (Test-Path $path)) {
        $script:txtLogContent.Text = "(Log-Datei nicht gefunden: $path)"
        return
    }
    try {
        $lines = Get-Content -Path $path -Encoding UTF8 -ErrorAction Stop

        # Level-Filter
        $lvl = [string]$script:cmbLogLevel.SelectedItem.Content
        if ($lvl -and $lvl -ne 'ALL') {
            $lines = $lines | Where-Object { $_ -match "\[$lvl" }
        }
        # Search-Filter
        $q = $script:txtLogSearch.Text
        if ($q) { $lines = $lines | Where-Object { $_ -like "*$q*" } }

        # nur letzte 2000 Zeilen (Performance), neueste oben
        $lines = @($lines) | Select-Object -Last 2000
        [Array]::Reverse($lines)
        $script:txtLogContent.Text = $lines -join "`r`n"
        # Scroll nach oben (neueste Eintraege zuerst)
        $script:txtLogContent.CaretIndex = 0
        $script:txtLogContent.ScrollToHome()
    } catch {
        $script:txtLogContent.Text = "(Fehler beim Laden: $_)"
    }
}

$script:btnLogRefresh.Add_Click({ Update-LogView })
$script:cmbLogLevel.Add_SelectionChanged({ Update-LogView })
$script:txtLogSearch.Add_TextChanged({ Update-LogView })

$script:btnLogClear.Add_Click({
    $path = Expand-LogPath
    if (-not $path -or -not (Test-Path $path)) { return }
    $res = [System.Windows.MessageBox]::Show(
        "Log-Datei leeren?`n`n$path",
        'Bestaetigen', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }
    $clearedOk = $false
    # Versuch 1: Inhalt ueberschreiben
    try {
        [System.IO.File]::WriteAllText($path, '', [System.Text.UTF8Encoding]::new($false))
        $clearedOk = $true
    } catch {}
    # Versuch 2: Datei loeschen + neu anlegen
    if (-not $clearedOk) {
        try {
            Remove-Item -Path $path -Force -ErrorAction Stop
            New-Item -ItemType File -Path $path -Force | Out-Null
            $clearedOk = $true
        } catch {}
    }
    # Versuch 3: LogPath-Vorschlag umstellen
    if (-not $clearedOk) {
        $alt = [Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\HU-NextExam-Manager\NextExam-Manager.log')
        $res2 = [System.Windows.MessageBox]::Show(
            "Log-Datei kann nicht geleert werden (Zugriff verweigert):`n$path`n`n" +
            "Soll der LogPath in config.json auf den neuen Standard umgestellt werden?`n`n$alt",
            'Log-Pfad umstellen?', 'YesNo', 'Warning')
        if ($res2 -eq 'Yes') {
            try {
                $dir = Split-Path $alt -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $script:Config.ToolSettings.LogPath = '%LOCALAPPDATA%\HU-NextExam-Manager\NextExam-Manager.log'
                Save-Config -Config $script:Config
                Initialize-Log -Path $alt -Level $script:Config.ToolSettings.LogLevel
                [System.Windows.MessageBox]::Show("LogPath umgestellt auf:`n$alt`n`nBitte Tool neu starten.", 'OK', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show("Umstellung fehlgeschlagen: $_", 'Fehler', 'OK', 'Error') | Out-Null
            }
        }
        return
    }
    Write-Log -Message 'Log durch User geleert' -Level INFO -Source 'UI'
    Update-LogView
})

$script:btnLogOpenDir.Add_Click({
    $path = Expand-LogPath
    if ($path) {
        $dir = Split-Path -Path $path -Parent
        if ($dir -and (Test-Path $dir)) {
            Start-Process explorer.exe -ArgumentList $dir
        } else {
            [System.Windows.MessageBox]::Show("Log-Ordner nicht gefunden: $dir", 'Hinweis', 'OK', 'Information') | Out-Null
        }
    }
})

# ========== MDM Pull Tab ==========

#region MDM UI-Element-Referenzen
$script:cmbMDMTenant         = Get-UI 'cmbMDMTenant'
$script:rbMDMAuthAppToken    = Get-UI 'rbMDMAuthAppToken'
$script:rbMDMAuthInteractive = Get-UI 'rbMDMAuthInteractive'
$script:lblMDMAuthStatus     = Get-UI 'lblMDMAuthStatus'
$script:lblMDMDeviceCode     = Get-UI 'lblMDMDeviceCode'
$script:btnMDMConnect        = Get-UI 'btnMDMConnect'
$script:btnMDMSetupApp       = Get-UI 'btnMDMSetupApp'
$script:btnMDMRefreshStatus  = Get-UI 'btnMDMRefreshStatus'
$script:btnMDMOpenDocs       = Get-UI 'btnMDMOpenDocs'
$script:lblMDMStudentIntune  = Get-UI 'lblMDMStudentIntune'
$script:lblMDMStudentGitHub  = Get-UI 'lblMDMStudentGitHub'
$script:lblMDMStudentStatus  = Get-UI 'lblMDMStudentStatus'
$script:lblMDMTeacherIntune  = Get-UI 'lblMDMTeacherIntune'
$script:lblMDMTeacherGitHub  = Get-UI 'lblMDMTeacherGitHub'
$script:lblMDMTeacherStatus  = Get-UI 'lblMDMTeacherStatus'
$script:lblMDMOverallStatus  = Get-UI 'lblMDMOverallStatus'
$script:lblMDMMetaDiffHeader = Get-UI 'lblMDMMetaDiffHeader'
$script:lstMDMMetaDiffs      = Get-UI 'lstMDMMetaDiffs'
$script:txtMDMDescription   = Get-UI 'txtMDMDescription'
$script:txtMDMInfoUrl        = Get-UI 'txtMDMInfoUrl'
$script:imgMDMAppIcon        = Get-UI 'imgMDMAppIcon'
$script:lblMDMIconPath       = Get-UI 'lblMDMIconPath'
$script:lblMDMIconStatus     = Get-UI 'lblMDMIconStatus'

# App-Icon Vorschau laden
$mdmIconPath = Join-Path $script:RootPath 'Assets\icon.png'
if (Test-Path $mdmIconPath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri $mdmIconPath
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $script:imgMDMAppIcon.Source = $bmp
        $script:lblMDMIconStatus.Text = '(gefunden)'
        $script:lblMDMIconStatus.Foreground = '#107C10'
    } catch {
        $script:lblMDMIconStatus.Text = '(Laden fehlgeschlagen)'
        $script:lblMDMIconStatus.Foreground = '#FF4444'
    }
} else {
    $script:lblMDMIconStatus.Text = '(nicht gefunden)'
    $script:lblMDMIconStatus.Foreground = '#FFD700'
}
$script:txtMDMGroupFilter    = Get-UI 'txtMDMGroupFilter'
$script:chkMDMAvailableAll   = Get-UI 'chkMDMAvailableAll'
$script:btnMDMLoadGroups     = Get-UI 'btnMDMLoadGroups'
$script:lstMDMGroups         = Get-UI 'lstMDMGroups'
$script:txtMDMPublisher      = Get-UI 'txtMDMPublisher'
$script:txtMDMDeveloper      = Get-UI 'txtMDMDeveloper'
$script:txtMDMInstallCmd     = Get-UI 'txtMDMInstallCmd'
$script:txtMDMUninstallCmd   = Get-UI 'txtMDMUninstallCmd'
$script:cmbMDMInstallContext = Get-UI 'cmbMDMInstallContext'
$script:prgMDM               = Get-UI 'prgMDM'
$script:lblMDMProgress       = Get-UI 'lblMDMProgress'
$script:btnMDMDeployStudent  = Get-UI 'btnMDMDeployStudent'
$script:btnMDMDeployTeacher  = Get-UI 'btnMDMDeployTeacher'
$script:btnMDMDeployBoth     = Get-UI 'btnMDMDeployBoth'
$script:chkMDMForceDeploy    = Get-UI 'chkMDMForceDeploy'
# Dashboard MDM Widget
$script:lblDashMDMTenant      = Get-UI 'lblDashMDMTenant'
$script:lblDashMDMStudentVer  = Get-UI 'lblDashMDMStudentVer'
$script:lblDashMDMStudentGH   = Get-UI 'lblDashMDMStudentGH'
$script:lblDashMDMStudentIcon = Get-UI 'lblDashMDMStudentIcon'
$script:lblDashMDMTeacherVer  = Get-UI 'lblDashMDMTeacherVer'
$script:lblDashMDMTeacherGH   = Get-UI 'lblDashMDMTeacherGH'
$script:lblDashMDMTeacherIcon = Get-UI 'lblDashMDMTeacherIcon'
#endregion

#region MDM State
$script:MDMToken        = $null   # Token-Objekt (AccessToken, ExpiresIn, ObtainedAt)
$script:MDMGroups       = @()     # Geladene Gruppen
$script:MDMLastCheck    = @{}     # Letzter Versions-Check: @{ StudentIntune=''; TeacherIntune=''; StudentGH=''; TeacherGH='' }
#endregion

#region MDM Helper-Funktionen

function Get-SelectedMDMTenant {
    $sel = $script:cmbMDMTenant.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('Bitte zuerst einen MDM-Tenant auswaehlen.', 'MDM', 'OK', 'Information') | Out-Null
        return $null
    }
    return $sel
}

function Get-MDMAuthMode {
    if ($script:rbMDMAuthAppToken.IsChecked) { return 'AppCredentials' }
    return 'AuthCode'
}

function Test-MDMTokenValid {
    if (-not $script:MDMToken) { return $false }
    $elapsed = ((Get-Date) - $script:MDMToken.ObtainedAt).TotalSeconds
    # Token als ungueltig behandeln wenn 80% der Laufzeit abgelaufen
    return ($elapsed -lt ($script:MDMToken.ExpiresIn * 0.8))
}

function Update-MDMAuthStatusUI {
    param([string]$Text, [string]$Color = '#9A9A9A')
    $script:lblMDMAuthStatus.Text       = $Text
    $script:lblMDMAuthStatus.Foreground = $Color
}

function Update-MDMProgressUI {
    param([int]$Step, [int]$Total, [string]$Message)
    if ($Total -gt 0) {
        $script:prgMDM.Value = [Math]::Round(($Step / $Total) * 100)
    }
    $script:lblMDMProgress.Text = $Message
}

function Reset-MDMProgressUI {
    $script:prgMDM.Value = 0
    $script:lblMDMProgress.Text = ''
}

function Update-MDMDashboardWidget {
    # Tenant-Name
    $sel = $script:cmbMDMTenant.SelectedItem
    if ($sel) {
        $script:lblDashMDMTenant.Text       = "Tenant: $($sel.TenantName)"
        $script:lblDashMDMTenant.Foreground  = '#E0E0E0'
    } else {
        $script:lblDashMDMTenant.Text       = 'Tenant: nicht konfiguriert'
        $script:lblDashMDMTenant.Foreground  = '#9A9A9A'
    }

    # Versionen + Icons
    foreach ($role in 'Student','Teacher') {
        $intuneVer = $script:MDMLastCheck["${role}Intune"]
        $ghVer     = $script:MDMLastCheck["${role}GH"]

        # Dashboard Labels
        $verLabel  = $script:Window.FindName("lblDashMDM${role}Ver")
        $ghLabel   = $script:Window.FindName("lblDashMDM${role}GH")
        $iconLabel = $script:Window.FindName("lblDashMDM${role}Icon")

        if ($verLabel)  { $verLabel.Text  = "Intune: $(if ($intuneVer) { $intuneVer } else { '-' })" }
        if ($ghLabel)   { $ghLabel.Text   = "GitHub: $(if ($ghVer) { $ghVer } else { '-' })" }

        if ($iconLabel) {
            if (-not $intuneVer -and -not $ghVer) {
                $iconLabel.Text    = [char]0x2753   # ❓
                $iconLabel.ToolTip = 'Nicht geprueft'
            }
            elseif (-not $intuneVer) {
                $iconLabel.Text    = [char]0x2795   # ➕
                $iconLabel.ToolTip = 'Nicht deployt'
                $iconLabel.Foreground = '#FFD700'
            }
            elseif ($intuneVer -eq $ghVer) {
                $iconLabel.Text    = [char]0x2705   # ✅
                $iconLabel.ToolTip = 'Aktuell'
                $iconLabel.Foreground = '#107C10'
            }
            else {
                $iconLabel.Text    = [char]::ConvertFromUtf32(0x1F504)  # 🔄
                $iconLabel.ToolTip = 'Update verfuegbar'
                $iconLabel.Foreground = '#0A84FF'
            }
        }

        # MDM-Tab Labels + Versions-Farbe
        $tabIntuneLabel = $script:Window.FindName("lblMDM${role}Intune")
        $tabGHLabel     = $script:Window.FindName("lblMDM${role}GitHub")
        if ($tabIntuneLabel) {
            $tabIntuneLabel.Text = "Intune: $(if ($intuneVer) { $intuneVer } else { '-' })"
            # Gelb wenn Intune aelter, Gruen wenn aktuell
            if ($intuneVer -and $ghVer) {
                try {
                    $iV = [System.Version]$intuneVer
                    $gV = [System.Version]$ghVer
                    if ($iV -lt $gV) {
                        $tabIntuneLabel.Foreground = '#FFD700'  # Gelb = veraltet
                    } elseif ($iV -ge $gV) {
                        $tabIntuneLabel.Foreground = '#107C10'  # Gruen = aktuell
                    }
                } catch { $tabIntuneLabel.Foreground = '#E0E0E0' }
            } else {
                $tabIntuneLabel.Foreground = '#E0E0E0'
            }
        }
        if ($tabGHLabel) { $tabGHLabel.Text = "GitHub: $(if ($ghVer) { $ghVer } else { '-' })" }

        # Dashboard Intune-Label einfaerben
        if ($verLabel -and $intuneVer -and $ghVer) {
            try {
                $iV2 = [System.Version]$intuneVer
                $gV2 = [System.Version]$ghVer
                if ($iV2 -lt $gV2) { $verLabel.Foreground = '#FFD700' }
                elseif ($iV2 -ge $gV2) { $verLabel.Foreground = '#107C10' }
            } catch { $verLabel.Foreground = '#E0E0E0' }
        }
    }
}

function Initialize-MDMTenantComboBox {
    # MDMTenants aus Config laden (neuer Key in config.json)
    $script:cmbMDMTenant.Items.Clear()
    if ($script:Config.PSObject.Properties.Name -contains 'MDMTenants') {
        foreach ($t in @($script:Config.MDMTenants)) {
            if ($t -is [hashtable]) { $t = [PSCustomObject]$t }
            # ToString-Override damit WPF den TenantName anzeigt (DisplayMemberPath geht nicht mit PSCustomObject in PS 5.1)
            $t | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.TenantName } -Force
            $script:cmbMDMTenant.Items.Add($t) | Out-Null
        }
        if ($script:cmbMDMTenant.Items.Count -gt 0) {
            $script:cmbMDMTenant.SelectedIndex = 0
        }
    }
}

function Build-AppMetadata {
    param(
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [string]$MSIFileName
    )
    $displayName = "Next-Exam-$Role"
    # Use actual MSI filename from GitHub Release if provided, otherwise fallback
    $msiName = if ($MSIFileName) { $MSIFileName } else { "NextExam$Role.msi" }
    $desc = if ($script:txtMDMDescription.Text) { $script:txtMDMDescription.Text } else { $displayName }
    $iconFile = Join-Path $script:RootPath 'Assets\icon.png'
    # Install-Command: replace any .msi reference with actual filename
    $installCmd = $script:txtMDMInstallCmd.Text -replace '[^\s"]+\.msi', $msiName
    $uninstallCmd = $script:txtMDMUninstallCmd.Text
    return @{
        _role              = $Role
        displayName        = $displayName
        description        = $desc
        publisher          = $script:txtMDMPublisher.Text
        developer          = $script:txtMDMDeveloper.Text
        informationUrl     = $script:txtMDMInfoUrl.Text
        installCommandLine = $installCmd
        uninstallCommandLine = $uninstallCmd
        installExperience  = ($script:cmbMDMInstallContext.SelectedItem.Content)
        setupFilePath      = $msiName
        iconPath           = $(if (Test-Path $iconFile) { $iconFile } else { $null })
    }
}

#endregion

#region MDM Event-Handler

# --- Tenant-ComboBox initialisieren ---
Initialize-MDMTenantComboBox



#region MDM Tenant-Settings GUI (Settings-Tab)
$script:lstMDMTenants       = Get-UI 'lstMDMTenants'
$script:btnMDMTenantAdd     = Get-UI 'btnMDMTenantAdd'
$script:btnMDMTenantEdit    = Get-UI 'btnMDMTenantEdit'
$script:btnMDMTenantRemove  = Get-UI 'btnMDMTenantRemove'
$script:btnMDMTenantSaveCred = Get-UI 'btnMDMTenantSaveCred'

function Refresh-MDMTenantList {
    $items = @()
    if ($script:Config.PSObject.Properties.Name -contains 'MDMTenants') {
        foreach ($t in @($script:Config.MDMTenants)) {
            $credExists = Test-MDMCredentialExists -TenantId $t.TenantId
            $items += [PSCustomObject]@{
                TenantName = $t.TenantName
                TenantId   = $t.TenantId
                ClientId   = $t.ClientId
                CredStatus = $(if ($credExists) { 'Gespeichert' } else { '-' })
            }
        }
    }
    $script:lstMDMTenants.ItemsSource = @($items)
    # Auch MDM-Tab ComboBox aktualisieren
    Initialize-MDMTenantComboBox
}

$script:btnMDMTenantAdd.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Tenant-Name (z.B. Gym-Leoben):', 'MDM-Tenant hinzufuegen', '')
    if (-not $name) { return }
    $tid = [Microsoft.VisualBasic.Interaction]::InputBox('Tenant-ID (Directory ID aus Azure Portal):', 'MDM-Tenant hinzufuegen', '')
    if (-not $tid) { return }
    $cid = [Microsoft.VisualBasic.Interaction]::InputBox('Client-ID (Application ID, leer lassen wenn noch keine App-Reg):', 'MDM-Tenant hinzufuegen', '')

    if (-not ($script:Config.PSObject.Properties.Name -contains 'MDMTenants')) {
        $script:Config | Add-Member -NotePropertyName 'MDMTenants' -NotePropertyValue @() -Force
    }
    $entry = New-MDMTenantEntry -TenantName $name -TenantId $tid -ClientId $cid
    $script:Config.MDMTenants = @($script:Config.MDMTenants) + $entry
    Save-Config -Config $script:Config
    Refresh-MDMTenantList
    Write-Log "MDM-Tenant hinzugefuegt: $name ($tid)" -Level INFO -Source 'Settings'
})

$script:btnMDMTenantEdit.Add_Click({
    $sel = $script:lstMDMTenants.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('Bitte einen Tenant auswaehlen.', 'MDM', 'OK', 'Information') | Out-Null
        return
    }
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox('Tenant-Name:', 'MDM-Tenant bearbeiten', $sel.TenantName)
    if (-not $newName) { return }
    $newTid = [Microsoft.VisualBasic.Interaction]::InputBox('Tenant-ID:', 'MDM-Tenant bearbeiten', $sel.TenantId)
    if (-not $newTid) { return }
    $newCid = [Microsoft.VisualBasic.Interaction]::InputBox('Client-ID:', 'MDM-Tenant bearbeiten', $sel.ClientId)

    foreach ($t in @($script:Config.MDMTenants)) {
        if ($t.TenantId -eq $sel.TenantId) {
            $t.TenantName = $newName
            $t.TenantId   = $newTid
            $t.ClientId   = $newCid
            break
        }
    }
    Save-Config -Config $script:Config
    Refresh-MDMTenantList
    Write-Log "MDM-Tenant bearbeitet: $newName ($newTid)" -Level INFO -Source 'Settings'
})

$script:btnMDMTenantRemove.Add_Click({
    $sel = $script:lstMDMTenants.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('Bitte einen Tenant auswaehlen.', 'MDM', 'OK', 'Information') | Out-Null
        return
    }
    $answer = [System.Windows.MessageBox]::Show(
        "Tenant '$($sel.TenantName)' wirklich entfernen?`nGespeicherte Credentials werden ebenfalls geloescht.",
        'MDM-Tenant entfernen', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $script:Config.MDMTenants = @($script:Config.MDMTenants | Where-Object { $_.TenantId -ne $sel.TenantId })
    Save-Config -Config $script:Config
    Remove-MDMCredential -TenantId $sel.TenantId
    Refresh-MDMTenantList
    Write-Log "MDM-Tenant entfernt: $($sel.TenantName)" -Level INFO -Source 'Settings'
})

$script:btnMDMTenantSaveCred.Add_Click({
    $sel = $script:lstMDMTenants.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('Bitte einen Tenant auswaehlen.', 'MDM', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $sel.ClientId) {
        [System.Windows.MessageBox]::Show('Client-ID muss zuerst gesetzt werden (Bearbeiten).', 'MDM', 'OK', 'Warning') | Out-Null
        return
    }
    $secret = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Client-Secret fuer '$($sel.TenantName)' eingeben:`n(wird DPAPI-verschluesselt gespeichert, nur auf diesem PC/User lesbar)",
        'MDM Client-Secret', '')
    if (-not $secret) { return }

    try {
        Save-MDMCredential -TenantId $sel.TenantId -ClientId $sel.ClientId -ClientSecret $secret
        [System.Windows.MessageBox]::Show('Credentials gespeichert.', 'MDM', 'OK', 'Information') | Out-Null
        Refresh-MDMTenantList
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Speichern: $_", 'MDM', 'OK', 'Error') | Out-Null
    }
})

# Initial befuellen
Refresh-MDMTenantList
#endregion

# --- Docs oeffnen ---
$script:btnMDMOpenDocs.Add_Click({
    $md = Join-Path $script:RootPath 'Docs\MDM-Setup.md'
    if (Test-Path $md) {
        try { Start-Process $md } catch {
            [System.Windows.MessageBox]::Show("Kann Docs nicht oeffnen: $_", 'Fehler', 'OK', 'Error') | Out-Null
        }
    } else {
        [System.Windows.MessageBox]::Show("Docs\MDM-Setup.md nicht gefunden.", 'Hinweis', 'OK', 'Information') | Out-Null
    }
})

# --- Verbinden (Token holen) ---
# Auth-Code Listener State
$script:MDMAuthCodeContext = $null
$script:MDMAuthCodeTimer   = $null

$script:btnMDMConnect.Add_Click({
    $tenant = Get-SelectedMDMTenant
    if (-not $tenant) { return }

    $mode = Get-MDMAuthMode
    Update-MDMAuthStatusUI 'Verbinde...' '#FFD700'
    $script:btnMDMConnect.IsEnabled = $false

    if ($mode -eq 'AppCredentials') {
        # --- Synchroner Client Credentials Flow ---
        try {
            $script:MDMToken = Get-MDMToken -TenantId $tenant.TenantId -Mode 'AppCredentials'
            Update-MDMAuthStatusUI "Verbunden (App-Token)" '#107C10'
            $script:lblMDMDeviceCode.Text = ''
            Write-Log "MDM verbunden: Tenant=$($tenant.TenantName), Modus=AppCredentials" -Level INFO -Source 'MDM-UI'
        } catch {
            Update-MDMAuthStatusUI "Fehler: $_" '#FF4444'
            Write-Log "MDM Verbindung fehlgeschlagen: $_" -Level ERROR -Source 'MDM-UI'
        } finally {
            $script:btnMDMConnect.IsEnabled = $true
        }
        return
    }

    # --- Auth Code Flow (Browser-Redirect, non-blocking) ---
    try {
        # Alten Listener aufraeumen falls vorhanden
        if ($script:MDMAuthCodeTimer) {
            $script:MDMAuthCodeTimer.Stop()
            $script:MDMAuthCodeTimer = $null
        }
        if ($script:MDMAuthCodeContext) {
            Stop-MDMAuthCodeListener -ListenerContext $script:MDMAuthCodeContext
            $script:MDMAuthCodeContext = $null
        }

        $script:MDMAuthCodeContext = Start-MDMAuthCodeListener -TenantId $tenant.TenantId
        $script:lblMDMDeviceCode.Text = "Browser geoeffnet - bitte anmelden..."
        Update-MDMAuthStatusUI 'Warte auf Browser-Anmeldung...' '#FFD700'

        # DispatcherTimer fuer non-blocking Polling (1 Sekunde Intervall)
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({
            try {
                if (-not $script:MDMAuthCodeContext) {
                    $this.Stop()
                    return
                }
                $poll = Poll-MDMAuthCodeOnce -ListenerContext $script:MDMAuthCodeContext
                if ($poll.Error) {
                    # Fehler
                    $this.Stop()
                    Stop-MDMAuthCodeListener -ListenerContext $script:MDMAuthCodeContext
                    $script:MDMAuthCodeContext = $null
                    Update-MDMAuthStatusUI "Fehler: $($poll.Error)" '#FF4444'
                    $script:lblMDMDeviceCode.Text = ''
                    $script:btnMDMConnect.IsEnabled = $true
                    Write-Log "MDM Auth Code Fehler: $($poll.Error)" -Level ERROR -Source 'MDM-UI'
                    return
                }
                if ($poll.Code) {
                    # Auth Code erhalten - Token holen
                    $this.Stop()
                    $ctx = $script:MDMAuthCodeContext
                    Stop-MDMAuthCodeListener -ListenerContext $ctx
                    $script:MDMAuthCodeContext = $null

                    $script:MDMToken = Get-MDMTokenAuthCode `
                        -TenantId $ctx.TenantId `
                        -ClientId $ctx.ClientId `
                        -AuthCode $poll.Code `
                        -RedirectUri $ctx.RedirectUri `
                        -CodeVerifier $ctx.CodeVerifier

                    Update-MDMAuthStatusUI "Verbunden (Admin-Token)" '#107C10'
                    $script:lblMDMDeviceCode.Text = ''
                    $script:btnMDMConnect.IsEnabled = $true
                    Write-Log "MDM verbunden: Tenant=$($ctx.TenantId), Modus=AuthCode" -Level INFO -Source 'MDM-UI'
                }
                # else: noch wartend, Timer laeuft weiter
            } catch {
                $this.Stop()
                if ($script:MDMAuthCodeContext) {
                    Stop-MDMAuthCodeListener -ListenerContext $script:MDMAuthCodeContext
                    $script:MDMAuthCodeContext = $null
                }
                Update-MDMAuthStatusUI "Fehler: $_" '#FF4444'
                $script:lblMDMDeviceCode.Text = ''
                $script:btnMDMConnect.IsEnabled = $true
                Write-Log "MDM Auth Code Timer-Fehler: $_" -Level ERROR -Source 'MDM-UI'
            }
        })
        $script:MDMAuthCodeTimer = $timer
        $timer.Start()

    } catch {
        Update-MDMAuthStatusUI "Fehler: $_" '#FF4444'
        $script:lblMDMDeviceCode.Text = ''
        $script:btnMDMConnect.IsEnabled = $true
        Write-Log "MDM Auth Code Start fehlgeschlagen: $_" -Level ERROR -Source 'MDM-UI'
    }
})

# --- Status pruefen ---
$script:btnMDMRefreshStatus.Add_Click({
    $tenant = Get-SelectedMDMTenant
    if (-not $tenant) { return }
    if (-not (Test-MDMTokenValid)) {
        [System.Windows.MessageBox]::Show('Bitte zuerst verbinden (Token abgelaufen oder nicht vorhanden).', 'MDM', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        $script:lblMDMOverallStatus.Text = 'Pruefe...'

        # GitHub-Version holen (aus MSIPull-Modul)
        $rel = Get-NextExamLatestRelease
        if ($rel.Student) { $script:MDMLastCheck['StudentGH'] = $rel.Student.Version }
        if ($rel.Teacher) { $script:MDMLastCheck['TeacherGH'] = $rel.Teacher.Version }

        # Intune-Versionen pruefen + Metadaten-Abgleich
        $allMetaDiffs = @()
        foreach ($role in 'Student','Teacher') {
            $app = Get-NextExamIntuneApp -AccessToken $script:MDMToken.AccessToken -DisplayNameFilter "Next-Exam-$role"
            if ($app) {
                $script:MDMLastCheck["${role}Intune"] = $app.appVersion
                $script:MDMLastCheck["${role}App"]    = $app  # App-Objekt fuer Metadaten-Abgleich
                $statusLabel = $script:Window.FindName("lblMDM${role}Status")
                if ($statusLabel) { $statusLabel.Text = "App-ID: $($app.id)" }

                # Metadaten-Abgleich (Option C: Defaults + UI-Werte)
                $uiMeta = @{}
                if ($script:txtMDMPublisher.Text)    { $uiMeta['publisher']      = $script:txtMDMPublisher.Text }
                if ($script:txtMDMDeveloper.Text)     { $uiMeta['developer']      = $script:txtMDMDeveloper.Text }
                if ($script:txtMDMDescription.Text)   { $uiMeta['description']    = $script:txtMDMDescription.Text }
                if ($script:txtMDMInfoUrl.Text)       { $uiMeta['informationUrl'] = $script:txtMDMInfoUrl.Text }
                $iconFile = Join-Path $script:RootPath 'Assets\icon.png'
                $diffs = Compare-NextExamAppMetadata -IntuneApp $app -UIMetadata $uiMeta -IconPath $iconFile
                $mismatches = @($diffs | Where-Object { -not $_.Match })
                if ($mismatches.Count -gt 0) {
                    foreach ($m in $mismatches) {
                        $allMetaDiffs += "${role}: $($m.Property) (Intune='$($m.Actual)' / Soll='$($m.Expected)')"
                    }
                }
            } else {
                $script:MDMLastCheck["${role}Intune"] = $null
                $script:MDMLastCheck["${role}App"]    = $null
                $statusLabel = $script:Window.FindName("lblMDM${role}Status")
                if ($statusLabel) { $statusLabel.Text = 'Nicht gefunden' }
            }
        }

        Update-MDMDashboardWidget

        # Button-Text dynamisch: "aktualisieren" wenn veraltet, "deployen" wenn neu/aktuell
        $anyOutdated = $false
        foreach ($role in 'Student','Teacher') {
            $btn = $script:Window.FindName("btnMDMDeploy$role")
            if ($btn) {
                $iv = $script:MDMLastCheck["${role}Intune"]
                $gv = $script:MDMLastCheck["${role}GH"]
                if ($iv -and $gv) {
                    try {
                        if ([System.Version]$iv -lt [System.Version]$gv) {
                            $btn.Content    = "$role aktualisieren"
                            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF8C00')
                            $anyOutdated = $true
                        } else {
                            $btn.Content    = "$role deployen"
                            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0A84FF')
                        }
                    } catch {}
                } elseif (-not $iv -and $gv) {
                    $btn.Content    = "$role deployen"
                    $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0A84FF')
                }
            }
        }
        if ($anyOutdated) {
            $script:btnMDMDeployBoth.Content    = 'Beide aktualisieren'
            $script:btnMDMDeployBoth.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF8C00')
        } else {
            $script:btnMDMDeployBoth.Content    = 'Beide deployen'
            $script:btnMDMDeployBoth.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#107C10')
        }

        # Status-Text + Metadaten-DataGrid befuellen
        if ($allMetaDiffs.Count -gt 0) {
            $script:lblMDMOverallStatus.Text       = "Geprueft - $($allMetaDiffs.Count) Metadaten-Abweichung(en)"
            $script:lblMDMOverallStatus.Foreground = '#FFD700'
            # DataGrid befuellen
            $script:lblMDMMetaDiffHeader.Text       = "Metadaten-Abweichungen ($($allMetaDiffs.Count)):"
            $script:lblMDMMetaDiffHeader.Visibility = 'Visible'
            $script:lstMDMMetaDiffs.Visibility      = 'Visible'
            $gridItems = @()
            foreach ($d in $allMetaDiffs) {
                # Parse: "Student: publisher (Intune='X' / Soll='Y')"
                if ($d -match '^(\w+):\s+(\w+)\s+\(Intune=''(.*)'' / Soll=''(.*)''\)$') {
                    $gridItems += [PSCustomObject]@{
                        Role     = $Matches[1]
                        Field    = $Matches[2]
                        Actual   = $Matches[3]
                        Expected = $Matches[4]
                    }
                }
            }
            $script:lstMDMMetaDiffs.ItemsSource = @($gridItems)
            Write-Log "MDM Status-Check: $($allMetaDiffs.Count) Metadaten-Abweichungen" -Level WARN -Source 'MDM-UI'
        } else {
            $script:lblMDMOverallStatus.Text       = 'Geprueft - Metadaten OK'
            $script:lblMDMOverallStatus.Foreground = '#107C10'
            $script:lblMDMMetaDiffHeader.Visibility = 'Collapsed'
            $script:lstMDMMetaDiffs.Visibility      = 'Collapsed'
            Write-Log 'MDM Status-Check abgeschlossen - Metadaten OK' -Level INFO -Source 'MDM-UI'
        }

    } catch {
        $script:lblMDMOverallStatus.Text       = "Fehler: $_"
        $script:lblMDMOverallStatus.Foreground = '#FF4444'
        Write-Log "MDM Status-Check Fehler: $_" -Level ERROR -Source 'MDM-UI'
    }
})

# --- Gruppen laden ---
$script:btnMDMLoadGroups.Add_Click({
    if (-not (Test-MDMTokenValid)) {
        [System.Windows.MessageBox]::Show('Bitte zuerst verbinden.', 'MDM', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $script:btnMDMLoadGroups.Content = 'Lade...'
        $script:btnMDMLoadGroups.IsEnabled = $false
        $script:MDMGroups = @(Get-IntuneGroups -AccessToken $script:MDMToken.AccessToken)

        # Gruppen-Typ bestimmen fuer Anzeige
        $displayGroups = foreach ($g in $script:MDMGroups) {
            $type = if ($g.groupTypes -contains 'DynamicMembership') { 'Dynamisch' }
                    elseif ($g.groupTypes -contains 'Unified') { 'M365' }
                    else { 'Security' }
            [PSCustomObject]@{
                id          = $g.id
                displayName = $g.displayName
                GroupType   = $type
            }
        }
        $script:lstMDMGroups.ItemsSource = @($displayGroups)
        Write-Log "$($script:MDMGroups.Count) Gruppen geladen" -Level INFO -Source 'MDM-UI'
    } catch {
        [System.Windows.MessageBox]::Show("Gruppen laden fehlgeschlagen: $_", 'MDM', 'OK', 'Error') | Out-Null
        Write-Log "Gruppen laden Fehler: $_" -Level ERROR -Source 'MDM-UI'
    } finally {
        $script:btnMDMLoadGroups.Content = 'Gruppen laden'
        $script:btnMDMLoadGroups.IsEnabled = $true
    }
})

# --- Gruppen-Filter ---
$script:txtMDMGroupFilter.Add_TextChanged({
    $filter = $script:txtMDMGroupFilter.Text
    if (-not $filter) {
        $script:lstMDMGroups.ItemsSource = @($script:MDMGroups | ForEach-Object {
            [PSCustomObject]@{ id = $_.id; displayName = $_.displayName; GroupType = 'Security' }
        })
        return
    }
    $filtered = $script:MDMGroups | Where-Object { $_.displayName -like "*$filter*" } | ForEach-Object {
        [PSCustomObject]@{ id = $_.id; displayName = $_.displayName; GroupType = 'Security' }
    }
    $script:lstMDMGroups.ItemsSource = @($filtered)
})

# --- Deploy-Funktionen (Runspace-basiert - UI bleibt reaktiv) ---
function Invoke-MDMDeploy {
    param([Parameter(Mandatory)][ValidateSet('Student','Teacher','Both')][string]$Scope)

    $tenant = Get-SelectedMDMTenant
    if (-not $tenant) { return }
    if (-not (Test-MDMTokenValid)) {
        [System.Windows.MessageBox]::Show('Bitte zuerst verbinden.', 'MDM', 'OK', 'Warning') | Out-Null
        return
    }

    # UI-Werte vor Runspace-Start sammeln (UI-Thread!)
    $selectedGroupIds = @()
    foreach ($item in $script:lstMDMGroups.SelectedItems) {
        $selectedGroupIds += $item.id
    }
    $availableAll = ($script:chkMDMAvailableAll.IsChecked -eq $true)
    $forceDeploy  = ($script:chkMDMForceDeploy.IsChecked -eq $true)
    $accessToken  = $script:MDMToken.AccessToken
    $roles = switch ($Scope) {
        'Student' { @('Student') }
        'Teacher' { @('Teacher') }
        'Both'    { @('Student','Teacher') }
    }
    # Metadaten auf UI-Thread lesen (benoetigt UI-Controls)
    $metadataMap = @{}
    foreach ($r in $roles) {
        $metadataMap[$r] = Build-AppMetadata -Role $r
    }

    # Buttons deaktivieren waehrend Deploy
    $script:btnMDMDeployStudent.IsEnabled = $false
    $script:btnMDMDeployTeacher.IsEnabled = $false
    $script:btnMDMDeployBoth.IsEnabled    = $false
    Reset-MDMProgressUI
    Update-MDMProgressUI 0 1 'Starte Deploy im Hintergrund...'

    # --- Phase 1: Release holen + MSI downloaden (UI-Thread, schnell) ---
    Update-MDMProgressUI 0 1 'Hole GitHub-Release...'
    try {
        $rel = Get-NextExamLatestRelease
    } catch {
        Update-MDMProgressUI 0 1 "GitHub-Release Fehler: $_"
        $script:btnMDMDeployStudent.IsEnabled = $true
        $script:btnMDMDeployTeacher.IsEnabled = $true
        $script:btnMDMDeployBoth.IsEnabled    = $true
        [System.Windows.MessageBox]::Show("GitHub-Release konnte nicht geholt werden:`n$_", 'MDM', 'OK', 'Error') | Out-Null
        return
    }

    $msiPaths = @{}  # Role -> @{ Path; Version; FileName }
    $deployTempBase = Join-Path $env:TEMP "HU-MDM-Deploy-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $deployTempBase -Force | Out-Null

    foreach ($role in $roles) {
        $asset = if ($role -eq 'Student') { $rel.Student } else { $rel.Teacher }
        if (-not $asset) {
            Write-Log "Kein $role-Asset im Release gefunden - uebersprungen" -Level WARN -Source 'MDM-UI'
            continue
        }
        $msiPath = Join-Path $deployTempBase $asset.FileName
        Update-MDMProgressUI 1 6 "Downloade $role MSI..."
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'HU-NextExam-Manager')
            $wc.DownloadFile($asset.DownloadUrl, $msiPath)
            $wc.Dispose()
            $fileSize = (Get-Item $msiPath).Length
            Write-Log "MSI Download OK: $role = $fileSize Bytes -> $msiPath" -Level INFO -Source 'MDM-UI'
            $msiPaths[$role] = @{ Path = $msiPath; Version = $asset.Version; FileName = $asset.FileName }
        } catch {
            Write-Log "MSI Download FEHLER $role : $_" -Level ERROR -Source 'MDM-UI'
            Update-MDMProgressUI 0 1 "$role Download fehlgeschlagen: $_"
            $script:btnMDMDeployStudent.IsEnabled = $true
            $script:btnMDMDeployTeacher.IsEnabled = $true
            $script:btnMDMDeployBoth.IsEnabled    = $true
            [System.Windows.MessageBox]::Show("$role MSI Download fehlgeschlagen:`n$_", 'MDM', 'OK', 'Error') | Out-Null
            if (Test-Path $deployTempBase) { Remove-Item -Path $deployTempBase -Recurse -Force -ErrorAction SilentlyContinue }
            return
        }
    }

    if ($msiPaths.Count -eq 0) {
        Update-MDMProgressUI 0 1 'Keine MSI-Assets gefunden'
        $script:btnMDMDeployStudent.IsEnabled = $true
        $script:btnMDMDeployTeacher.IsEnabled = $true
        $script:btnMDMDeployBoth.IsEnabled    = $true
        if (Test-Path $deployTempBase) { Remove-Item -Path $deployTempBase -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }

    Update-MDMProgressUI 2 6 'Starte Publish im Hintergrund...'

    # --- Phase 2: Publish im Runspace (schwerer Teil: encrypt + upload) ---
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.AddScript({
        param($msiPaths, $accessToken, $selectedGroupIds, $availableAll, $forceDeploy, $metadataMap, $modulesPath, $deployTempBase)

        # Module im Runspace laden (Logging zuerst - wird von MDMDeploy benoetigt)
        Import-Module (Join-Path $modulesPath 'Logging.psm1')   -Force -ErrorAction Stop
        Import-Module (Join-Path $modulesPath 'MDMDeploy.psm1') -Force -ErrorAction Stop

        $results = @()
        try {
            foreach ($role in $msiPaths.Keys) {
                $msiInfo = $msiPaths[$role]
                $metadata = $metadataMap[$role]
                $metadata['displayVersion'] = $msiInfo.Version
                # Fix setupFilePath + installCommandLine to match actual MSI filename (prevents 0x80070653)
                $actualMsiName = $msiInfo.FileName
                if ($actualMsiName -and $metadata['setupFilePath'] -ne $actualMsiName) {
                    Write-Log "setupFilePath Korrektur: '$($metadata['setupFilePath'])' -> '$actualMsiName'" -Level INFO -Source 'MDM'
                    $metadata['setupFilePath'] = $actualMsiName
                    $metadata['installCommandLine'] = $metadata['installCommandLine'] -replace '[^\s"]+\.msi', $actualMsiName
                }

                try {
                    $publishParams = @{
                        AccessToken        = $accessToken
                        MSIPath            = $msiInfo.Path
                        AppMetadata        = $metadata
                        RequiredGroupIds   = $selectedGroupIds
                        AvailableForAllUsers = $availableAll
                    }
                    if ($forceDeploy) { $publishParams['Force'] = $true }
                    $result = Publish-NextExamToIntune @publishParams

                    $results += @{ Role = $role; Success = $result.Success; Message = $result.Message; Version = $msiInfo.Version; Action = $result.Action }
                } catch {
                    $results += @{ Role = $role; Success = $false; Message = $_.Exception.Message; Version = $msiInfo.Version }
                }
            }
        } catch {
            $results += @{ Role = 'ALL'; Success = $false; Message = $_.Exception.Message; Version = '' }
        } finally {
            # Temp-MSIs aufraeumen
            if ($deployTempBase -and (Test-Path $deployTempBase)) {
                Remove-Item -Path $deployTempBase -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        return ,$results
    }).AddArgument($msiPaths).AddArgument($accessToken).AddArgument($selectedGroupIds).AddArgument($availableAll).AddArgument($forceDeploy).AddArgument($metadataMap).AddArgument($script:ModulesPath).AddArgument($deployTempBase)

    $ps.Runspace = $rs
    $handle = $ps.BeginInvoke()

    # Polling-Timer: prueft alle 500ms ob Runspace fertig
    $script:MDMDeployTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:MDMDeployTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:MDMDeployState = [PSCustomObject]@{ PS = $ps; Runspace = $rs; Handle = $handle; Dots = 0 }

    $script:MDMDeployTimer.Add_Tick({
        $d = $script:MDMDeployState
        if (-not $d) { $script:MDMDeployTimer.Stop(); return }

        # Fortschritts-Animation
        $d.Dots = ($d.Dots + 1) % 4
        $dots = '.' * $d.Dots
        Update-MDMProgressUI 50 100 "Deploy laeuft$dots"

        if ($d.Handle.IsCompleted) {
            $script:MDMDeployTimer.Stop()
            try {
                $results = @($d.PS.EndInvoke($d.Handle))
                # Flatten: wenn verschachtelt
                if ($results.Count -eq 1 -and $results[0] -is [System.Collections.IEnumerable] -and $results[0] -isnot [hashtable]) {
                    $results = @($results[0])
                }

                $allOk = $true
                $msgs  = @()
                foreach ($r in $results) {
                    if ($r.Success) {
                        $msgs += "$($r.Role): $($r.Message)"
                        if ($r.Role -ne 'ALL' -and $r.Version) {
                            $script:MDMLastCheck["$($r.Role)Intune"] = $r.Version
                        }
                    } else {
                        $allOk = $false
                        $msgs += "$($r.Role) FEHLER: $($r.Message)"
                    }
                }

                if ($allOk) {
                    Update-MDMProgressUI 100 100 ($msgs -join ' | ')
                } else {
                    Update-MDMProgressUI 0 100 ($msgs -join ' | ')
                    [System.Windows.MessageBox]::Show(($msgs -join "`n"), 'MDM Deploy', 'OK', 'Warning') | Out-Null
                }

                Update-MDMDashboardWidget

            } catch {
                Update-MDMProgressUI 0 100 "Runspace-Fehler: $_"
                Write-Log "MDM Deploy Runspace-Fehler: $_" -Level ERROR -Source 'MDM-UI'
            } finally {
                try { $d.PS.Dispose() } catch {}
                try { $d.Runspace.Close(); $d.Runspace.Dispose() } catch {}
                $script:MDMDeployState = $null
                # Buttons wieder aktivieren
                $script:btnMDMDeployStudent.IsEnabled = $true
                $script:btnMDMDeployTeacher.IsEnabled = $true
                $script:btnMDMDeployBoth.IsEnabled    = $true
            }
        }
    })
    $script:MDMDeployTimer.Start()
    Write-Log "MDM Deploy Runspace gestartet fuer: $($roles -join ', ')" -Level INFO -Source 'MDM-UI'
}

$script:btnMDMDeployStudent.Add_Click({ Invoke-MDMDeploy -Scope 'Student' })
$script:btnMDMDeployTeacher.Add_Click({ Invoke-MDMDeploy -Scope 'Teacher' })
$script:btnMDMDeployBoth.Add_Click({ Invoke-MDMDeploy -Scope 'Both' })

# --- App einrichten (Entra ID App Registration Setup) ---
$script:btnMDMSetupApp.Add_Click({
    $tenant = Get-SelectedMDMTenant
    if (-not $tenant) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "App-Registration fuer Tenant: $($tenant.TenantName)`n`n" +
        "Erstellt automatisch:`n" +
        "  - App Registration 'HU-NextExam-Manager'`n" +
        "  - API Permissions (DeviceManagementApps + Group.Read)`n" +
        "  - Admin Consent`n" +
        "  - Client Secret (365 Tage)`n" +
        "  - DPAPI Credential-Datei`n`n" +
        "Ein Browser-Fenster oeffnet sich fuer die Global-Admin-Anmeldung.`n" +
        "Fortfahren?",
        'MDM App-Setup', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $script:btnMDMSetupApp.IsEnabled = $false
    Update-MDMAuthStatusUI 'Setup: Warte auf Admin-Anmeldung...' '#FFD700'
    $script:lblMDMDeviceCode.Text = 'Browser geoeffnet - bitte als Global Admin anmelden...'

    try {
        $script:MDMSetupContext = Start-MDMSetupAuthListener -TenantId $tenant.TenantId

        # DispatcherTimer fuer non-blocking Polling
        $setupTimer = New-Object System.Windows.Threading.DispatcherTimer
        $setupTimer.Interval = [TimeSpan]::FromSeconds(1)
        $setupTimer.Add_Tick({
            try {
                if (-not $script:MDMSetupContext) {
                    $this.Stop()
                    return
                }
                $poll = Poll-MDMAuthCodeOnce -ListenerContext $script:MDMSetupContext
                if ($poll.Error) {
                    $this.Stop()
                    Stop-MDMAuthCodeListener -ListenerContext $script:MDMSetupContext
                    $script:MDMSetupContext = $null
                    Update-MDMAuthStatusUI "Setup-Fehler: $($poll.Error)" '#FF4444'
                    $script:lblMDMDeviceCode.Text = ''
                    $script:btnMDMSetupApp.IsEnabled = $true
                    Write-Log "MDM Setup Auth Fehler: $($poll.Error)" -Level ERROR -Source 'MDM-UI'
                    return
                }
                if ($poll.Code) {
                    $this.Stop()
                    $ctx = $script:MDMSetupContext
                    Stop-MDMAuthCodeListener -ListenerContext $ctx
                    $script:MDMSetupContext = $null

                    Update-MDMAuthStatusUI 'Setup: Token erhalten, erstelle App...' '#FFD700'
                    $script:lblMDMDeviceCode.Text = ''

                    # Token holen mit Setup-Scopes
                    try {
                        $setupToken = Get-MDMTokenAuthCode `
                            -TenantId $ctx.TenantId `
                            -ClientId $ctx.ClientId `
                            -AuthCode $poll.Code `
                            -RedirectUri $ctx.RedirectUri `
                            -CodeVerifier $ctx.CodeVerifier

                        # App Registration erstellen
                        $result = Register-MDMEntraApp `
                            -AccessToken $setupToken.AccessToken `
                            -TenantId $ctx.TenantId

                        # Tenant Config aktualisieren (ClientId eintragen)
                        $tenantObj = Get-SelectedMDMTenant
                        if ($tenantObj -and (-not $tenantObj.ClientId -or $tenantObj.ClientId -ne $result.ClientId)) {
                            $tenantObj | Add-Member -NotePropertyName 'ClientId' -NotePropertyValue $result.ClientId -Force
                            try { Save-Config -Config $script:AppConfig } catch {
                                Write-Log "Config-Speichern fehlgeschlagen: $_" -Level WARN -Source 'MDM-UI'
                            }
                        }

                        $statusText = if ($result.IsExisting) { 'aktualisiert' } else { 'erstellt' }
                        Update-MDMAuthStatusUI "App $statusText - bereit!" '#107C10'

                        $infoMsg = "App-Registration $statusText!`n`n" +
                            "Client-ID: $($result.ClientId)`n" +
                            "Secret gueltig bis: $($result.SecretExpiresAt)`n" +
                            "Credentials: $($result.CredentialPath)`n`n" +
                            "Die App kann jetzt ueber 'App-Credentials' verbunden werden."
                        [System.Windows.MessageBox]::Show($infoMsg, 'MDM App-Setup', 'OK', 'Information') | Out-Null

                        Write-Log "MDM App-Setup abgeschlossen: ClientId=$($result.ClientId)" -Level INFO -Source 'MDM-UI'
                    } catch {
                        Update-MDMAuthStatusUI "Setup-Fehler: $_" '#FF4444'
                        Write-Log "MDM App-Setup fehlgeschlagen: $_" -Level ERROR -Source 'MDM-UI'
                        [System.Windows.MessageBox]::Show("App-Setup fehlgeschlagen:`n`n$_", 'MDM App-Setup', 'OK', 'Error') | Out-Null
                    }
                    $script:btnMDMSetupApp.IsEnabled = $true
                }
            } catch {
                $this.Stop()
                if ($script:MDMSetupContext) {
                    Stop-MDMAuthCodeListener -ListenerContext $script:MDMSetupContext
                    $script:MDMSetupContext = $null
                }
                Update-MDMAuthStatusUI "Setup-Fehler: $_" '#FF4444'
                $script:lblMDMDeviceCode.Text = ''
                $script:btnMDMSetupApp.IsEnabled = $true
                Write-Log "MDM Setup Timer-Fehler: $_" -Level ERROR -Source 'MDM-UI'
            }
        })
        $script:MDMSetupTimer = $setupTimer
        $setupTimer.Start()

    } catch {
        Update-MDMAuthStatusUI "Setup-Fehler: $_" '#FF4444'
        $script:lblMDMDeviceCode.Text = ''
        $script:btnMDMSetupApp.IsEnabled = $true
        Write-Log "MDM Setup Start fehlgeschlagen: $_" -Level ERROR -Source 'MDM-UI'
    }
})

# --- Dashboard-Widget initial befuellen ---
# Nur Tenant-Name anzeigen, keine Intune-Abfrage beim Start
$sel = $script:cmbMDMTenant.SelectedItem
if ($sel) {
    $tName = if ($sel -is [hashtable]) { $sel.TenantName } else { $sel.TenantName }
    $script:lblDashMDMTenant.Text      = "Tenant: $tName"
    $script:lblDashMDMTenant.Foreground = '#E0E0E0'
} else {
    $script:lblDashMDMTenant.Text      = 'MDM: nicht konfiguriert'
    $script:lblDashMDMTenant.Foreground = '#9A9A9A'
}

#endregion


# ========== Clients Tab ==========
$script:cmbClientTask    = Get-UI 'cmbClientTask'
$script:lblClientShare   = Get-UI 'lblClientShare'
$script:btnClientRefresh = Get-UI 'btnClientRefresh'
$script:lstClients       = Get-UI 'lstClients'

function Refresh-ClientsList {
    $t = $script:cmbClientTask.SelectedItem
    if (-not $t) { $script:lstClients.ItemsSource = @(); $script:lblClientShare.Text = ''; return }
    if (-not $t.StatusSharePath) {
        $script:lstClients.ItemsSource = @()
        $script:lblClientShare.Text = '(Kein Status-Share konfiguriert - siehe Settings)'
        return
    }
    $script:lblClientShare.Text = $t.StatusSharePath
    try {
        $rows = Read-ClientStatus -Path $t.StatusSharePath
        $script:lstClients.ItemsSource = @($rows)
    } catch {
        $script:lblClientShare.Text = "Fehler: $_"
    }
}

function Refresh-ClientTaskDropdown {
    $selId = if ($script:cmbClientTask.SelectedItem) { $script:cmbClientTask.SelectedItem.Id } else { $null }
    $script:cmbClientTask.ItemsSource = $null
    $tasks = @($script:Config.Tasks) | ForEach-Object {
        $item = $_
        if ($item -is [hashtable]) { $item = [PSCustomObject]$item }
        $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.DisplayName } -Force
        $item
    }
    $script:cmbClientTask.ItemsSource = @($tasks)
    if ($selId) {
        $script:cmbClientTask.SelectedItem = $script:Config.Tasks | Where-Object { $_.Id -eq $selId } | Select-Object -First 1
    } elseif ($script:Config.Tasks.Count -gt 0) {
        $script:cmbClientTask.SelectedIndex = 0
    }
}

$script:cmbClientTask.Add_SelectionChanged({ Refresh-ClientsList })
$script:btnClientRefresh.Add_Click({
    Show-LoadingOverlay
    try { $script:Window.Dispatcher.Invoke([Action]{}, 'Render') | Out-Null } catch {}
    try { Refresh-ClientsList } finally { Hide-LoadingOverlay }
})

# ========== Tool-Self-Update (Check gegen GitHub-Repo) ==========
$script:UpdatePullToken  = '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'
$script:UpdateRepoOwner  = 'ChiliApple'
$script:UpdateRepoName   = 'HU-NextExam-Manager'
$script:UpdateApiUrl     = "https://raw.githubusercontent.com/$($script:UpdateRepoOwner)/$($script:UpdateRepoName)/main/HU-NextExam-Manager.ps1"
$script:UpdateAvailable  = $false
$script:UpdateRemoteVer  = ''

function ConvertTo-CleanVersion {
    param([string]$V)
    $clean = $V -replace '-dev|-beta|-rc.*|-alpha',''
    $clean = $clean -replace '[^\d\.]',''
    try { return [Version]$clean } catch { return $null }
}

function Invoke-UpdateCheck {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $h = @{
            'User-Agent'  = 'HU-NextExam-Manager-UpdateCheck'
        }
        $r = Invoke-WebRequest -Uri $script:UpdateApiUrl -Headers $h -UseBasicParsing -ErrorAction Stop
        $text = if ($r.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($r.Content)
        } else { [string]$r.Content }
        # Backtick-Escape damit $script literal bleibt statt expandiert
        if ($text -match "\`$script:ToolVersion\s*=\s*'([^']+)'") {
            $remote = $Matches[1].Trim()
            $lv = ConvertTo-CleanVersion $script:ToolVersion
            $rv = ConvertTo-CleanVersion $remote
            Write-Log -Message "Update-Check: Lokal=$($script:ToolVersion) | Remote=$remote" -Level INFO -Source 'Update'
            if ($lv -and $rv -and ($rv -gt $lv)) {
                $script:UpdateAvailable = $true
                $script:UpdateRemoteVer = $remote
                $script:btnUpdate.Content    = "Update v$remote"
                $script:btnUpdate.IsEnabled  = $true
                $script:btnUpdate.Background = [System.Windows.Media.Brushes]::Gold
                $script:btnUpdate.Foreground = [System.Windows.Media.Brushes]::Black
                Set-Status "Update verfuegbar: v$remote"
            } else {
                $script:btnUpdate.Content   = "Aktuell v$($script:ToolVersion)"
                $script:btnUpdate.IsEnabled = $true
            }
        } else {
            $script:btnUpdate.Content   = 'Update-Check fehl'
            $script:btnUpdate.IsEnabled = $true
            Write-Log -Message 'Update-Check: Regex ohne Match' -Level WARN -Source 'Update'
        }
    } catch {
        $script:btnUpdate.Content   = 'Offline'
        $script:btnUpdate.IsEnabled = $true
        Write-Log -Message "Update-Check-Fehler: $_" -Level WARN -Source 'Update'
    }
}

$script:btnUpdate.Add_Click({
    if (-not $script:UpdateAvailable) {
        # Kein Update bekannt - erneut pruefen
        $script:btnUpdate.Content = 'Pruefe...'
        try { Invoke-UpdateCheck } catch {}
        return
    }
    $res = [System.Windows.MessageBox]::Show(
        "Tool wird neu gestartet:`n`n  Aktuell: v$($script:ToolVersion)`n  Neu:     v$($script:UpdateRemoteVer)`n`nFortfahren?",
        "Update auf v$($script:UpdateRemoteVer)", 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }
    $pullScript = Join-Path $script:RootPath 'Pull.ps1'
    if (-not (Test-Path $pullScript)) {
        [System.Windows.MessageBox]::Show("Pull.ps1 nicht gefunden: $pullScript", 'Fehler', 'OK', 'Error') | Out-Null
        return
    }
    try {
        $exe = (Get-Command powershell.exe).Source
        Start-Process $exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',$pullScript | Out-Null
        Set-Status 'Pull laeuft in separatem Fenster. Tool schliesst in 3s.'
        Start-Sleep -Seconds 3
        $script:Window.Close()
    } catch {
        [System.Windows.MessageBox]::Show("Update-Start fehlgeschlagen:`n$_", 'Fehler', 'OK', 'Error') | Out-Null
    }
})

# --- Window-Geometrie aus Config anwenden (vor ShowDialog) ---
try {
    $wcfg = $script:Config.ToolSettings.Window
    if ($wcfg -and $wcfg.Width -and $wcfg.Height -and [double]$wcfg.Width -gt 200 -and [double]$wcfg.Height -gt 150) {
        $script:Window.WindowStartupLocation = 'Manual'
        if ($null -ne $wcfg.Left)   { $script:Window.Left   = [double]$wcfg.Left }
        if ($null -ne $wcfg.Top)    { $script:Window.Top    = [double]$wcfg.Top }
        $script:Window.Width  = [double]$wcfg.Width
        $script:Window.Height = [double]$wcfg.Height
        if ($wcfg.State -eq 'Maximized') { $script:Window.WindowState = 'Maximized' }
    }
} catch { Write-Log -Message "Window-Load: $_" -Level WARN -Source 'UI' }

# --- Fenstergeometrie beim Schliessen speichern ---
$script:Window.Add_Closing({
    try {
        $st = [string]$script:Window.WindowState
        if ($st -eq 'Maximized') {
            $b = $script:Window.RestoreBounds
            $l = $b.Left; $t = $b.Top; $w = $b.Width; $h = $b.Height
        } else {
            $l = $script:Window.Left; $t = $script:Window.Top
            $w = $script:Window.Width; $h = $script:Window.Height
        }
        if (-not ($script:Config.ToolSettings.PSObject.Properties.Name -contains 'Window')) {
            $script:Config.ToolSettings | Add-Member -NotePropertyName 'Window' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $script:Config.ToolSettings.Window = [PSCustomObject]@{
            Left = $l; Top = $t; Width = $w; Height = $h; State = $st
        }
        Save-Config -Config $script:Config
    } catch {
        Write-Log -Message "Window-Save: $_" -Level WARN -Source 'UI'
    }
})

# --- Window.Loaded ---
$script:Window.Add_Loaded({
    try {
        # ABSOLUT MINIMAL: nur das was sofort da ist
        Refresh-TaskList
        Load-TaskToForm $null
        try { Refresh-ClientTaskDropdown } catch {}
        try {
            $script:txtAutoPullTime.Text = if ($script:Config.ToolSettings.AutoPullScheduleTime) { $script:Config.ToolSettings.AutoPullScheduleTime } else { '03:00' }
            $pr = if ($script:Config.ToolSettings.AutoPullPrincipal) { $script:Config.ToolSettings.AutoPullPrincipal } else { 'System' }
            if ($pr -eq 'User') { $script:rbAutoPullUser.IsChecked = $true } else { $script:rbAutoPullSystem.IsChecked = $true }
            Update-AutoPullStatusDisplay
        } catch {}
        Set-Status "Bereit - Tabs ueber 'Status aktualisieren' manuell laden"
        Hide-LoadingOverlay
        # Hinweis wenn nicht elevated (GPO-Operationen brauchen Admin)
        try {
            if (-not (Test-IsElevated)) {
                Set-Status "WARNUNG: Tool laeuft NICHT als Admin - GPO-Operationen werden scheitern"
                [System.Windows.MessageBox]::Show(
                    "Das Tool laeuft OHNE lokale Admin-Rechte.`n`n" +
                    "GPO-Erstellen, -Entfernen, -Verknuepfen und FW-GPO-Rules werden mit " +
                    "'Zugriff verweigert' (E_ACCESSDENIED) fehlschlagen.`n`n" +
                    "Empfehlung: Tool ueber Start.vbs starten (bringt UAC-Prompt automatisch) " +
                    "oder PowerShell als Administrator oeffnen und dann HU-NextExam-Manager.ps1 starten.",
                    "Admin-Rechte empfohlen", 'OK', 'Warning') | Out-Null
            }
        } catch {}
        # Update-Check (schnell) + Log-View - async
        $script:Window.Dispatcher.BeginInvoke([Action]{
            try { Update-LogView } catch {}
            try { Invoke-UpdateCheck } catch {}
        }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    } catch {
        Write-Log -Message "Loaded-Fehler: $_" -Level ERROR -Source 'UI'
        [System.Windows.MessageBox]::Show("Startfehler: $_", 'Fehler', 'OK', 'Error') | Out-Null
    }
})

# --- Start ---
try {
    # --- Splash Fade-Out Fallback bei ContentRendered (falls AutoTimer noch nicht gefeuert) ---
$script:Window.Add_ContentRendered({
    if ($script:SplashAutoTimer) {
        $script:SplashAutoTimer.Stop()
        $script:SplashAutoTimer = $null
    }
    if ($script:SplashWindow) {
        try {
            $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(500))))
            $fade.Add_Completed({
                try { $script:SplashWindow.Close() } catch {}
                $script:SplashWindow = $null
            })
            $script:SplashWindow.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
        } catch {
            try { $script:SplashWindow.Close() } catch {}
            $script:SplashWindow = $null
        }
    }
})

$script:Window.ShowDialog()
} catch {
    Write-Log -Message "Fatal: $_" -Level ERROR -Source 'Main'
    [System.Windows.MessageBox]::Show("Fehler: $_", 'HU-NextExam-Manager', 'OK', 'Error') | Out-Null
}

Write-Log -Message "HU-NextExam-Manager beendet" -Level INFO -Source 'Main'
try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
