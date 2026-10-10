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
    v2.2 - Kein Update, solange Next-Exam laeuft (stille MSI-Installation wuerde den Pruefungsclient beenden)
         - Sperrdatei update-freeze.txt im Share: keine Installation/kein Update (z.B. am Pruefungstag)
         - Versionsvergleich numerisch (1.2.30 ist neuer als 1.2.3); aeltere Version im Share wird nicht installiert
         - Status: tatsaechlich installierte Version nach msiexec; 1641 = OK, 1618 = verschoben
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

# Version aus Text ("2.1.0.3", "v2.1.0") - $null wenn nicht lesbar
function ConvertTo-NEVersion([string]$Text) {
    $v = "$Text".Trim() -replace '^[vV]', ''
    if ($v -match '^(\d+(\.\d+){1,3})') {
        $o = $null
        if ([version]::TryParse($Matches[1], [ref]$o)) {
            # fehlende Teile mit 0 auffuellen: 1.1.3 == 1.1.3.0 (sonst gilt eine dreiteilige DisplayVersion immer als veraltet)
            return (New-Object System.Version($o.Major, $o.Minor, [Math]::Max($o.Build, 0), [Math]::Max($o.Revision, 0)))
        }
    }
    return $null
}

# Installierte Next-Exam-Version dieser Rolle (bei mehreren Eintraegen die hoechste)
function Get-NextExamInstalled {
    $hits = @()
    foreach ($reg in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path $reg)) { continue }
        $hits += @(Get-ChildItem $reg -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -and $_.DisplayName -like "Next-Exam-$Role*" })
    }
    if ($hits.Count -gt 1) { Write-InstLog "Mehrere Eintraege fuer Next-Exam-$($Role): $(($hits | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; ')" 'WARN' }
    return ($hits | Sort-Object @{ Expression = { $v = ConvertTo-NEVersion "$($_.DisplayVersion)"; if ($v) { $v } else { [version]'0.0' } } } -Descending | Select-Object -First 1)
}

# Laufende Next-Exam-Prozesse (Name/Pfad enthaelt "next-exam" oder Programm liegt im Installationsordner)
function Get-NextExamProcess($Installed) {
    $loc = ''
    if ($Installed -and "$($Installed.InstallLocation)".Trim()) { $loc = "$($Installed.InstallLocation)".Trim().TrimEnd('\') + '\' }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like '*next-exam*' -or $_.ProcessName -like '*nextexam*' -or "$($_.Path)" -like '*\Next-Exam*' -or
        ($loc -and "$($_.Path)" -and "$($_.Path)".StartsWith($loc, [System.StringComparison]::OrdinalIgnoreCase))
    })
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

    $installed = Get-NextExamInstalled
    $vTarget = ConvertTo-NEVersion "$($ver.Version)"
    $vHave = $null
    $needInstall = $true
    if ($installed) {
        Write-InstLog "Installiert: $($installed.DisplayName) $($installed.DisplayVersion)"
        $vHave = ConvertTo-NEVersion "$($installed.DisplayVersion)"
        if (-not $vTarget) {
            Write-InstLog "Ziel-Version '$($ver.Version)' nicht lesbar - kein Install" 'ERROR'
            Write-StatusJson -Installed $installed.DisplayVersion -Target $ver.Version -Action error
            exit 1
        }
        if ($vHave -and $vHave -eq $vTarget) {
            Write-InstLog "Version aktuell - kein Install noetig"
            Write-StatusJson -Installed $installed.DisplayVersion -Target $ver.Version -Action aktuell
            $needInstall = $false
        } elseif ($vHave -and $vHave -gt $vTarget) {
            # Share hat eine aeltere Version: nicht automatisch zurueckstufen (Downgrade nur bewusst/manuell)
            Write-InstLog "Installierte Version ist neuer als die im Share ($($ver.Version)) - kein Downgrade" 'WARN'
            Write-StatusJson -Installed $installed.DisplayVersion -Target $ver.Version -Action 'neuer als Share'
            $needInstall = $false
        } else {
            Write-InstLog "Version veraltet (oder nicht lesbar) - Update wird gestartet"
        }
    } else {
        Write-InstLog "Keine Installation gefunden - Erstinstall"
    }

    if (-not $needInstall) { exit 0 }

    # Sperrdatei im Share (z.B. am Pruefungstag): keine Installation, kein Update
    $freeze = Join-Path $SharePath 'update-freeze.txt'
    if (Test-Path -LiteralPath $freeze) {
        Write-InstLog "Sperrdatei vorhanden ($freeze) - Installation/Update verschoben" 'WARN'
        Write-StatusJson -Installed $(if ($installed) { $installed.DisplayVersion } else { '' }) -Target $ver.Version -Action 'gesperrt (update-freeze.txt)'
        exit 0
    }
    # Next-Exam laeuft (Pruefung moeglich): eine stille MSI-Installation wuerde den Client beenden (Restart Manager)
    $running = @(Get-NextExamProcess $installed)
    if ($running.Count) {
        Write-InstLog "Next-Exam laeuft ($(($running | ForEach-Object { "$($_.ProcessName)[$($_.Id)]" }) -join ', ')) - Update verschoben" 'WARN'
        Write-StatusJson -Installed $(if ($installed) { $installed.DisplayVersion } else { '' }) -Target $ver.Version -Action 'verschoben (laeuft)'
        exit 0
    }

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
        1641 { Write-InstLog 'Install OK (Neustart eingeleitet)'; 'installed' }
        1638 { Write-InstLog 'Install: Version bereits vorhanden' 'WARN'; 'aktuell' }
        1618 { Write-InstLog 'Install verschoben: andere Installation laeuft gerade' 'WARN'; 'verschoben (andere Installation)' }
        default { Write-InstLog "Install fehlgeschlagen (ExitCode $($proc.ExitCode))" 'ERROR'; 'error' }
    }
    # tatsaechlich installierte Version melden (nicht die Ziel-Version - sonst wirkt ein fehlgeschlagenes Update "aktuell")
    $after = Get-NextExamInstalled
    Write-StatusJson -Installed $(if ($after) { "$($after.DisplayVersion)" } else { '' }) -Target $ver.Version -Action $action
    exit $proc.ExitCode
} catch {
    Write-InstLog "EXCEPTION: $_" 'ERROR'
    exit 1
}
