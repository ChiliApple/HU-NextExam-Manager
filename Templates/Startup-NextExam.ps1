#Requires -Version 5.1
<#
.SYNOPSIS
    GPO Startup-Script fuer Next-Exam Installation/Update.
.DESCRIPTION
    Wird via CMD-Wrapper aufgerufen (Startup-NextExam.cmd -> powershell.exe -ExecutionPolicy Bypass -File).
    Prueft Version gegen Share, installiert/aktualisiert MSI bei Bedarf.
    ENCODING: Diese Datei MUSS reines ASCII mit CRLF sein!
    PowerShell 5.1 liest BOM-lose Dateien als ANSI - UTF-8 Sonderzeichen verursachen Parse-Fehler.
.NOTES
    v2.1 - Fix: JSON-Status ohne BOM schreiben (UTF8NoBOM)
         - Fix: Atomares Schreiben (temp -> rename) verhindert korrupte Dateien
         - Fix: Robusteres Share-Erreichbarkeits-Check mit Retry
#>
param(
    [Parameter(Mandatory)][string]$SharePath,
    [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
    [string]$StatusPath
)

$ErrorActionPreference = 'Continue'
$LogFile = "C:\Windows\Temp\NextExam-$Role-Install.log"

function Write-InstLog {
    param($msg, $lvl = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Write-StatusJson {
    param([string]$Installed, [string]$Target, [string]$Action)
    if (-not $StatusPath) { return }
    try {
        # Retry-Loop: Share kann beim Startup noch nicht gemountet sein
        $retries = 3
        for ($i = 1; $i -le $retries; $i++) {
            if (Test-Path $StatusPath) { break }
            if ($i -lt $retries) {
                Write-InstLog "StatusPath nicht erreichbar (Versuch $i/$retries), warte 5s..." 'WARN'
                Start-Sleep -Seconds 5
            }
        }
        if (-not (Test-Path $StatusPath)) {
            Write-InstLog "StatusPath nach $retries Versuchen nicht erreichbar: $StatusPath" 'WARN'
            return
        }

        $obj = [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Role         = $Role
            Installed    = $Installed
            Target       = $Target
            LastCheck    = (Get-Date).ToString('o')
            LastAction   = $Action
        }
        $file = Join-Path $StatusPath ("{0}-{1}.json" -f $env:COMPUTERNAME, $Role)

        # Atomares Schreiben: temp-Datei -> rename (verhindert korrupte JSON bei Absturz)
        $tmpFile = "$file.tmp"
        # UTF-8 OHNE BOM (PS 5.1 Set-Content -Encoding UTF8 schreibt MIT BOM -> Parse-Probleme)
        $json = $obj | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.UTF8Encoding]::new($false))

        # Verify: temp-Datei lesbar?
        $verify = [System.IO.File]::ReadAllText($tmpFile, [System.Text.UTF8Encoding]::new($false))
        $null = $verify | ConvertFrom-Json -ErrorAction Stop

        # Atomic rename (ueberschreibt Ziel)
        if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        Move-Item -Path $tmpFile -Destination $file -Force
        Write-InstLog "Status geschrieben: $file ($Action)"
    } catch {
        Write-InstLog "Status-Write-Fehler: $_" 'WARN'
        # Temp-Datei aufraeumen
        if ($tmpFile -and (Test-Path $tmpFile)) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Write-InstLog "=== NextExam-$Role Startup-Script gestartet ==="
    Write-InstLog "Host: $env:COMPUTERNAME | User: $env:USERNAME | Share: $SharePath"

    if (-not (Test-Path $SharePath)) {
        Write-InstLog "Share nicht erreichbar: $SharePath" 'ERROR'
        exit 1
    }

    $verFile = Join-Path $SharePath "version-$($Role.ToLower()).json"
    if (-not (Test-Path $verFile)) {
        Write-InstLog "version-file fehlt: $verFile" 'WARN'
        exit 0
    }
    $ver = Get-Content -Path $verFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-InstLog "Ziel-Version: $($ver.Version) ($($ver.FileName))"

    # Registry-Check: ist Next-Exam bereits installiert?
    $installed = $null
    foreach ($reg in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path $reg)) { continue }
        $hit = Get-ChildItem $reg -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -and $_.DisplayName -like "Next-Exam-$Role*" } |
            Select-Object -First 1
        if ($hit) { $installed = $hit; break }
    }

    $needInstall = $true
    if ($installed) {
        Write-InstLog "Installiert: $($installed.DisplayName) $($installed.DisplayVersion)"
        if ($installed.DisplayVersion -eq $ver.Version -or
            $ver.Version -like "$($installed.DisplayVersion)*" -or
            $installed.DisplayVersion -like "$($ver.Version)*") {
            Write-InstLog "Version aktuell - kein Install noetig"
            Write-StatusJson -Installed $installed.DisplayVersion -Target $ver.Version -Action aktuell
            $needInstall = $false
        } else {
            Write-InstLog "Version veraltet - Update wird gestartet"
        }
    } else {
        Write-InstLog "Keine Installation gefunden - Erstinstall"
    }

    if (-not $needInstall) { exit 0 }

    $msi = Join-Path $SharePath $ver.FileName
    if (-not (Test-Path $msi)) {
        Write-InstLog "MSI nicht erreichbar: $msi" 'ERROR'
        exit 1
    }

    $msiLog = "C:\Windows\Temp\NextExam-$Role-msiexec.log"
    Write-InstLog "Starte: msiexec /i `"$msi`" /quiet /norestart /log `"$msiLog`""
    $proc = Start-Process msiexec.exe -ArgumentList "/i","`"$msi`"","/quiet","/norestart","/log","`"$msiLog`"" -Wait -PassThru
    Write-InstLog "msiexec ExitCode: $($proc.ExitCode)"

    $action = switch ($proc.ExitCode) {
        0    { Write-InstLog 'Install OK'; 'installed' }
        3010 { Write-InstLog 'Install OK (Reboot erforderlich)'; 'installed' }
        1638 { Write-InstLog 'Install: Version bereits vorhanden' 'WARN'; 'aktuell' }
        default { Write-InstLog "Install fehlgeschlagen (ExitCode $($proc.ExitCode))" 'ERROR'; 'error' }
    }
    Write-StatusJson -Installed $ver.Version -Target $ver.Version -Action $action
    exit $proc.ExitCode
} catch {
    Write-InstLog "EXCEPTION: $_" 'ERROR'
    exit 1
}
