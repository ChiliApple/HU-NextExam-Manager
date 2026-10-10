#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled-Task Management fuer Auto-MSI-Pull.
.DESCRIPTION
    Erstellt einen Scheduled Task der das Tool mit -AutoPull Flag startet.
    Laeuft unter dem angemeldeten User (Interactive) - wichtig fuer UNC-Share-Zugriff.
#>

$script:TaskName = 'AutoPull'
$script:TaskPath = '\HU-NextExam-Manager\'

function Test-AutoPullTask {
    [CmdletBinding()]
    param()
    try {
        # Moeglichkeiten: Unter-Ordner (SYSTEM), Root (User-Fallback), Legacy-Name
        $t = Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue
        if (-not $t) { $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
        if (-not $t) { $t = Get-ScheduledTask -TaskName 'HU-NextExam-Manager-AutoPull' -ErrorAction SilentlyContinue }
        if (-not $t) { return [PSCustomObject]@{ Exists = $false } }
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Exists     = $true
            State      = $t.State
            NextRun    = $info.NextRunTime
            LastRun    = $info.LastRunTime
            LastResult = $info.LastTaskResult
            Trigger    = $t.Triggers[0]
            TaskPath   = $t.TaskPath
        }
    } catch { return [PSCustomObject]@{ Exists = $false; Error = $_.Exception.Message } }
}

function Test-IsAdmin {
    $p = New-Object System.Security.Principal.WindowsPrincipal(
            [System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Register-AutoPullTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Time,
        [ValidateSet('System','User')][string]$Principal = 'System'
    )
    if (-not (Test-Path $ScriptPath)) {
        throw "Script-Pfad nicht gefunden: $ScriptPath"
    }
    if ($Time -notmatch '^\d{1,2}:\d{2}$') {
        throw "Ungueltiges Zeit-Format (HH:mm erwartet): $Time"
    }
    if ($Principal -eq 'System' -and -not (Test-IsAdmin)) {
        throw "Principal SYSTEM benoetigt lokale Admin-Rechte. Tool als Administrator starten, oder Principal 'User' waehlen."
    }

    # Legacy-Task (ohne Ordner) entfernen + neuen mit Ordner
    $legacy = Get-ScheduledTask -TaskName 'HU-NextExam-Manager-AutoPull' -ErrorAction SilentlyContinue
    if ($legacy) {
        try { Unregister-ScheduledTask -TaskName 'HU-NextExam-Manager-AutoPull' -Confirm:$false } catch {}
    }
    $existing = Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -Confirm:$false
    }

    $workDir = Split-Path -Path $ScriptPath -Parent
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -AutoPull" `
                -WorkingDirectory $workDir

    $trigger = New-ScheduledTaskTrigger -Daily -At $Time

    if ($Principal -eq 'System') {
        # Machine-Account ($env:COMPUTERNAME$) braucht Share-Zugriff (Domaenen-Computer-ACL)
        $principalObj = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        # Interactive User - laeuft nur wenn User angemeldet, StartWhenAvailable holt nach
        $userId = "$env:USERDOMAIN\$env:USERNAME"
        $principalObj = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(2))

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principalObj -Settings $settings `
                -Description 'HU-NextExam-Manager Auto-Pull fuer MSI-Updates'

    # Task-Path: SYSTEM darf Folder anlegen (Admin sowieso noetig), User nutzt Root (kein Admin fuer Folder-Create)
    $useTaskPath = if ($Principal -eq 'System') { $script:TaskPath } else { '\' }

    try {
        Register-ScheduledTask -TaskName $script:TaskName -TaskPath $useTaskPath -InputObject $task -Force -ErrorAction Stop | Out-Null
    } catch {
        # Fallback: Wenn Folder-Create fehlschlaegt, im Root versuchen
        if ($useTaskPath -ne '\') {
            try { Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -InputObject $task -Force -ErrorAction Stop | Out-Null }
            catch { throw "Register-ScheduledTask fehlgeschlagen: $($_.Exception.Message). Hinweis: Tool ggf. als Administrator starten." }
        } else {
            throw "Register-ScheduledTask fehlgeschlagen: $($_.Exception.Message). Hinweis: Tool ggf. als Administrator starten."
        }
    }
    return Test-AutoPullTask
}

function Unregister-AutoPullTask {
    [CmdletBinding()]
    param()
    $removed = $false
    # Task im Unter-Ordner (SYSTEM-Mode)
    $existing = Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue
    if ($existing) {
        try { Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -Confirm:$false; $removed = $true } catch {}
    }
    # Task im Root (User-Mode aktuell)
    $rootTask = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($rootTask) {
        try { Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Confirm:$false; $removed = $true } catch {}
    }
    # Legacy-Name im Root
    $legacy = Get-ScheduledTask -TaskName 'HU-NextExam-Manager-AutoPull' -ErrorAction SilentlyContinue
    if ($legacy) {
        try { Unregister-ScheduledTask -TaskName 'HU-NextExam-Manager-AutoPull' -Confirm:$false; $removed = $true } catch {}
    }
    # Leeren Ordner entfernen
    try {
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $folder = $scheduler.GetFolder($script:TaskPath.TrimEnd('\'))
        if (($folder.GetTasks(0).Count -eq 0) -and ($folder.GetFolders(0).Count -eq 0)) {
            $root = $scheduler.GetFolder('\')
            $root.DeleteFolder($script:TaskPath.Trim('\'), 0)
        }
    } catch {}
    return $removed
}

function Invoke-AutoPullRun {
    <#
    .SYNOPSIS
        Fuehrt den Auto-Pull aus - ohne UI, headless fuer Scheduled-Task-Aufruf.
        Erwartet: Logging.psm1, Config.psm1, MSIPull.psm1 sind bereits geladen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    Set-ConfigPath -Path $ConfigPath
    $cfg = Load-Config

    $logPath = $cfg.ToolSettings.LogPath
    if ($logPath -match '%[^%]+%') { $logPath = [Environment]::ExpandEnvironmentVariables($logPath) }
    Initialize-Log -Path $logPath -Level $cfg.ToolSettings.LogLevel
    Write-Log -Message '=== AutoPull gestartet ===' -Level INFO -Source 'AutoPull'
    $script:AutoPullErrors = 0   # Anzahl Fehler -> Rueckgabe (Exitcode der geplanten Aufgabe)

    try {
        $rel = Get-NextExamLatestRelease
        Write-Log -Message "Release: $($rel.TagName) Student=$($rel.Student.Version) Teacher=$($rel.Teacher.Version)" -Level INFO -Source 'AutoPull'

        # je Rolle getrennt: fehlt eine Rolle im Release oder hat ein Task nur eine Freigabe, laeuft die andere trotzdem
        $roles = @()
        foreach ($role in 'Student', 'Teacher') {
            $info = $rel.$role
            $shareProp = "$($role)SharePath"
            $rTasks = @($cfg.Tasks | Where-Object { $_ -and "$($_.$shareProp)" })
            if (-not $rTasks.Count) { continue }
            if (-not $info -or -not "$($info.FileName)" -or -not "$($info.DownloadUrl)") {
                $script:AutoPullErrors++
                Write-Log -Message "$role-MSI fehlt im Release $($rel.TagName) - $role wird uebersprungen" -Level ERROR -Source 'AutoPull'
                continue
            }
            $roles += [pscustomobject]@{ Role = $role; Info = $info; ShareProp = $shareProp; Tasks = $rTasks }
        }
        if (-not $roles.Count) {
            Write-Log -Message 'Keine Tasks mit Shares - nichts zu tun' -Level WARN -Source 'AutoPull'
            return [int]$script:AutoPullErrors
        }

        $temp = Join-Path $env:TEMP "HU-NextExam-AutoPull-$(Get-Random)"
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $trustP = @{ TrustedPublisher = "$($cfg.ToolSettings.MsiTrustedPublisher)"; TrustedThumbprints = @($cfg.ToolSettings.MsiTrustedThumbprints) }
            foreach ($r in $roles) {
                $info = $r.Info
                # Download nur, wenn mindestens eine Freigabe nicht aktuell ist
                $todo = @()
                foreach ($t in $r.Tasks) {
                    try {
                        $cur = Read-ShareVersionInfo -SharePath $t.($r.ShareProp) -Role $r.Role
                        if ($cur -and ($cur.Version -eq $info.Version)) { Write-Log -Message "$($t.DisplayName) $($r.Role) bereits aktuell - skip" -Level INFO -Source 'AutoPull' }
                        else { $todo += $t }
                    } catch { $todo += $t }
                }
                if (-not $todo.Count) { continue }
                $tmp = Join-Path $temp ([System.IO.Path]::GetFileName("$($info.FileName)"))
                try {
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('User-Agent', 'HU-NextExam-Manager-AutoPull')
                    Write-Log -Message "DL $($r.Role): $($info.DownloadUrl)" -Level INFO -Source 'AutoPull'
                    $wc.DownloadFile($info.DownloadUrl, $tmp)
                } catch {
                    $script:AutoPullErrors++
                    Write-Log -Message "Download $($r.Role) fehlgeschlagen: $_" -Level ERROR -Source 'AutoPull'
                    continue
                }
                foreach ($t in $todo) {
                    try {
                        $null = Deploy-MSIToShare -SourceMSI $tmp -SharePath $t.($r.ShareProp) `
                                    -Role $r.Role -Version $info.Version `
                                    -BuildDate $info.BuildDate -FileName $info.FileName -ExpectedSha256 "$($info.Sha256)" @trustP
                        Write-Log -Message "Deployed $($t.DisplayName): $($r.Role)=$($info.Version)" -Level INFO -Source 'AutoPull'
                    } catch {
                        $script:AutoPullErrors++
                        Write-Log -Message "Task $($t.DisplayName) $($r.Role) fehlgeschlagen: $_" -Level ERROR -Source 'AutoPull'
                    }
                }
            }
        } finally {
            if (Test-Path $temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $script:AutoPullErrors++
        Write-Log -Message "AutoPull-Fehler: $_" -Level ERROR -Source 'AutoPull'
    } finally {
        Write-Log -Message "=== AutoPull beendet ($($script:AutoPullErrors) Fehler) ===" -Level $(if ($script:AutoPullErrors) { 'WARN' } else { 'INFO' }) -Source 'AutoPull'
    }
    return [int]$script:AutoPullErrors
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Test-AutoPullTask, Register-AutoPullTask, `
                                  Unregister-AutoPullTask, Invoke-AutoPullRun
}
