#Requires -Version 5.1
<#
.SYNOPSIS
    Strukturiertes Logging fuer HU-NextExam-Manager.
#>

$script:LogFile  = (Join-Path $env:LOCALAPPDATA 'HU-NextExam-Manager\NextExam-Manager.log')
$script:LogLevel = 'INFO'

function Initialize-Log {
    [CmdletBinding()]
    param(
        [string]$Path  = (Join-Path $env:LOCALAPPDATA 'HU-NextExam-Manager\NextExam-Manager.log'),
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    # Expand %VAR% Placeholder in Config-String
    if ($Path -and $Path -match '%[^%]+%') {
        $Path = [System.Environment]::ExpandEnvironmentVariables($Path)
    }
    $script:LogFile  = $Path
    $script:LogLevel = $Level
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string]$Level = 'INFO',

        [string]$Source = 'Main'
    )
    $levels = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    if ($levels[$Level] -lt $levels[$script:LogLevel]) { return }

    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '{0} [{1,-5}] [{2}] {3}' -f $ts, $Level, $Source, $Message
    try {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Last-Resort: kein Crash bei Log-Failure
        Write-Host "LOG-FAIL: $line" -ForegroundColor Red
    }
}

# Funktionen exportieren (nur wenn als Modul geladen; bei dot-source automatisch sichtbar)
if ($ExecutionContext.SessionState.Module) {
Export-ModuleMember -Function Initialize-Log, Write-Log
}
