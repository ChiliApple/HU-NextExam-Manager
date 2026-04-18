#Requires -Version 5.1
<#
.SYNOPSIS
    Config-Modul fuer HU-NextExam-Manager. DPAPI-verschluesselt, per-User.
.DESCRIPTION
    Speichert Schul-Konfiguration unter %APPDATA%\HU-Tools\NextExamManager.cfg
    verschluesselt mit Windows DPAPI (CurrentUser Scope).
#>

Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

# Neu: Config liegt neben dem Tool (portabel, Ordner-Copy mitnehmbar).
# Alt (0.4.x): %APPDATA%\HU-Tools\NextExamManager.cfg DPAPI-verschluesselt - wird automatisch migriert.
$script:LegacyConfigDir  = Join-Path $env:APPDATA 'HU-Tools'
$script:LegacyConfigFile = Join-Path $script:LegacyConfigDir 'NextExamManager.cfg'
$script:ConfigFile       = $null  # wird per Set-ConfigPath gesetzt (Default neben Skript)

function Set-ConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:ConfigFile = $Path
}

function Get-DefaultConfig {
    [PSCustomObject]@{
        Schema       = 1
        ToolSettings = [PSCustomObject]@{
            LogPath              = (Join-Path $env:LOCALAPPDATA 'HU-NextExam-Manager\NextExam-Manager.log')
            LogLevel             = 'INFO'
            UpdateCheckOnStart   = $true
            AutoPullEnabled      = $false
            AutoPullScheduleTime = '03:00'
            GitHubToken          = ''  # Optional: GitHub PAT fuer 5000 API-Calls/h statt 60
            Window               = [PSCustomObject]@{
                Left   = $null
                Top    = $null
                Width  = $null
                Height = $null
                State  = 'Normal'
            }
        }
        Tasks = @()
        MDMTenants = @()
        MDMSettings = [PSCustomObject]@{
            DefaultPublisher     = 'Bildungsportal'
            DefaultDeveloper     = 'Mag. Thomas Michael Weissel'
            DefaultInstallCmd    = 'msiexec /i {MSI} /qn'
            DefaultUninstallCmd  = 'msiexec /x NextExamStudent.msi /qn'
            DefaultInstallContext = 'system'
        }
    }
}

function New-TaskEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName
    )
    $id = ($DisplayName -replace '[^a-zA-Z0-9\-]', '-').ToLower()
    if (-not $id) { $id = 'task-' + [Guid]::NewGuid().ToString('N').Substring(0,8) }
    [PSCustomObject]@{
        Id                      = $id
        DisplayName             = $DisplayName
        DomainFQDN              = ''
        DCServer                = ''
        StudentSharePath        = ''
        TeacherSharePath        = ''
        OUTargetStudent         = ''
        OUTargetTeacher         = ''
        WMIFilterStudentPattern = ''
        WMIFilterStudentType    = 'Custom'  # Prefix | Pattern | List | Custom
        WMIFilterTeacherPattern = ''
        WMIFilterTeacherType    = 'Custom'

        # Status-Share (Clients schreiben Install-Status zurueck)
        StatusSharePath         = ''

        # GPO
        GPONamePrefix           = 'HU-NEXT-EXAM-'

        # Firewall (Step 6b)
        FWProfiles              = @('Domain','Private')
        FWStudentExe            = '%ProgramFiles%\Next-Exam-Student\Next-Exam-Student.exe'
        FWTeacherExe            = '%ProgramFiles%\Next-Exam-Teacher\Next-Exam-Teacher.exe'
        FWEnableTCPPort         = $false
        FWTCPPort               = 22422
        FWEnableUDPPort         = $false
        FWUDPPorts              = '6024,6025'
    }
}


function New-MDMTenantEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$ClientId = ''
    )
    [PSCustomObject]@{
        TenantName = $TenantName
        TenantId   = $TenantId
        ClientId   = $ClientId
    }
}

function Initialize-ConfigStore {
    if (-not $script:ConfigFile) { throw 'ConfigFile nicht gesetzt - Set-ConfigPath zuerst aufrufen.' }
    $dir = Split-Path -Path $script:ConfigFile -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Save-Config {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    Initialize-ConfigStore
    $json = $Config | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($script:ConfigFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Load-Config {
    [CmdletBinding()]
    param()

    if (-not $script:ConfigFile) { throw 'ConfigFile nicht gesetzt - Set-ConfigPath zuerst aufrufen.' }

    # Neue Config existiert -> laden
    if (Test-Path $script:ConfigFile) {
        try {
            $json = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8
            $cfg  = $json | ConvertFrom-Json
        } catch {
            throw "Config laden fehlgeschlagen ($script:ConfigFile): $_"
        }
    }
    # Legacy-Migration aus %APPDATA% DPAPI-Config
    elseif (Test-Path $script:LegacyConfigFile) {
        try {
            $enc   = [System.IO.File]::ReadAllBytes($script:LegacyConfigFile)
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser')
            $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
            $cfg   = $json | ConvertFrom-Json
            Write-Warning "Legacy-Config gefunden - migriert nach $script:ConfigFile"
        } catch {
            Write-Warning "Legacy-Config nicht lesbar (evtl. anderer User): $_"
            $cfg = Get-DefaultConfig
        }
    }
    # Erstanlage
    else {
        $cfg = Get-DefaultConfig
        Save-Config -Config $cfg
        return $cfg
    }

    # Migration: Schools -> Tasks (0.4.x -> 0.5.x)
    $migrated = $false
    if ($cfg.PSObject.Properties.Name -contains 'Schools' -and -not ($cfg.PSObject.Properties.Name -contains 'Tasks')) {
        $cfg | Add-Member -NotePropertyName 'Tasks' -NotePropertyValue @($cfg.Schools) -Force
        $cfg.PSObject.Properties.Remove('Schools')
        $migrated = $true
    }
    # Default-Felder auf existierende Tasks auffuellen
    $tmpl = New-TaskEntry -DisplayName 'dummy'
    foreach ($t in @($cfg.Tasks)) {
        foreach ($prop in $tmpl.PSObject.Properties.Name) {
            if (-not ($t.PSObject.Properties.Name -contains $prop)) {
                $t | Add-Member -NotePropertyName $prop -NotePropertyValue $tmpl.$prop -Force
                $migrated = $true
            }
        }
    }
    # ToolSettings: Default-Felder nachruesten (alle neuen Props seit 0.5.x)
    $defaultSettings = (Get-DefaultConfig).ToolSettings
    foreach ($prop in $defaultSettings.PSObject.Properties.Name) {
        if (-not ($cfg.ToolSettings.PSObject.Properties.Name -contains $prop)) {
            $cfg.ToolSettings | Add-Member -NotePropertyName $prop -NotePropertyValue $defaultSettings.$prop -Force
            $migrated = $true
        }
    }
    # ToolSettings.Window nachruesten
    if (-not ($cfg.ToolSettings.PSObject.Properties.Name -contains 'Window')) {
        $cfg.ToolSettings | Add-Member -NotePropertyName 'Window' -NotePropertyValue ([PSCustomObject]@{
            Left = $null; Top = $null; Width = $null; Height = $null; State = 'Normal'
        }) -Force
        $migrated = $true
    }
    # MDMTenants + MDMSettings nachruesten (v1.5+)
    if (-not ($cfg.PSObject.Properties.Name -contains 'MDMTenants')) {
        $cfg | Add-Member -NotePropertyName 'MDMTenants' -NotePropertyValue @() -Force
        $migrated = $true
    }
    if (-not ($cfg.PSObject.Properties.Name -contains 'MDMSettings')) {
        $cfg | Add-Member -NotePropertyName 'MDMSettings' -NotePropertyValue (Get-DefaultConfig).MDMSettings -Force
        $migrated = $true
    }
    if ($migrated) { Save-Config -Config $cfg }
    return $cfg
}

function Add-TaskToConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DisplayName
    )
    $task = New-TaskEntry -DisplayName $DisplayName
    $Config.Tasks = @($Config.Tasks) + $task
    return $task
}

function Remove-TaskFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Id
    )
    $Config.Tasks = @($Config.Tasks | Where-Object { $_.Id -ne $Id })
}

function Get-ConfigFilePath { $script:ConfigFile }

# Funktionen exportieren (nur wenn als Modul geladen; bei dot-source automatisch sichtbar)
if ($ExecutionContext.SessionState.Module) {
Export-ModuleMember -Function Initialize-ConfigStore, Set-ConfigPath, Save-Config, Load-Config, `
                              Get-DefaultConfig, New-TaskEntry, New-MDMTenantEntry, `
                              Add-TaskToConfig, Remove-TaskFromConfig, `
                              Get-ConfigFilePath
}
