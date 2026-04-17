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

    try {
        $rel = Get-NextExamLatestRelease
        Write-Log -Message "Release: $($rel.TagName) Student=$($rel.Student.Version) Teacher=$($rel.Teacher.Version)" -Level INFO -Source 'AutoPull'

        $tasks = @($cfg.Tasks | Where-Object { $_.StudentSharePath -and $_.TeacherSharePath })
        if ($tasks.Count -eq 0) {
            Write-Log -Message 'Keine Tasks mit Shares - nichts zu tun' -Level WARN -Source 'AutoPull'
            return
        }

        $temp = Join-Path $env:TEMP "HU-NextExam-AutoPull-$(Get-Random)"
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        $tmpS = Join-Path $temp $rel.Student.FileName
        $tmpT = Join-Path $temp $rel.Teacher.FileName

        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'HU-NextExam-Manager-AutoPull')
            Write-Log -Message "DL Student: $($rel.Student.DownloadUrl)" -Level INFO -Source 'AutoPull'
            $wc.DownloadFile($rel.Student.DownloadUrl, $tmpS)
            Write-Log -Message "DL Teacher: $($rel.Teacher.DownloadUrl)" -Level INFO -Source 'AutoPull'
            $wc.DownloadFile($rel.Teacher.DownloadUrl, $tmpT)

            foreach ($t in $tasks) {
                try {
                    # Skip wenn beide Shares schon aktuell sind
                    $curS = Read-ShareVersionInfo -SharePath $t.StudentSharePath -Role Student
                    $curT = Read-ShareVersionInfo -SharePath $t.TeacherSharePath -Role Teacher
                    $sOk = $curS -and ($curS.Version -eq $rel.Student.Version)
                    $tOk = $curT -and ($curT.Version -eq $rel.Teacher.Version)
                    if ($sOk -and $tOk) {
                        Write-Log -Message "$($t.DisplayName) bereits aktuell - skip" -Level INFO -Source 'AutoPull'
                        continue
                    }
                    if (-not $sOk) {
                        $null = Deploy-MSIToShare -SourceMSI $tmpS -SharePath $t.StudentSharePath `
                                    -Role 'Student' -Version $rel.Student.Version `
                                    -BuildDate $rel.Student.BuildDate -FileName $rel.Student.FileName
                    }
                    if (-not $tOk) {
                        $null = Deploy-MSIToShare -SourceMSI $tmpT -SharePath $t.TeacherSharePath `
                                    -Role 'Teacher' -Version $rel.Teacher.Version `
                                    -BuildDate $rel.Teacher.BuildDate -FileName $rel.Teacher.FileName
                    }
                    Write-Log -Message "Deployed $($t.DisplayName): Student=$($rel.Student.Version) Teacher=$($rel.Teacher.Version)" -Level INFO -Source 'AutoPull'
                } catch {
                    Write-Log -Message "Task $($t.DisplayName) fehlgeschlagen: $_" -Level ERROR -Source 'AutoPull'
                }
            }
        } finally {
            if (Test-Path $temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Log -Message "AutoPull-Fehler: $_" -Level ERROR -Source 'AutoPull'
    } finally {
        Write-Log -Message '=== AutoPull beendet ===' -Level INFO -Source 'AutoPull'
    }
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Test-AutoPullTask, Register-AutoPullTask, `
                                  Unregister-AutoPullTask, Invoke-AutoPullRun
}
