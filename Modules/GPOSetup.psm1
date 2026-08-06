#Requires -Version 5.1
<#
.SYNOPSIS
    Management von Next-Exam Install-GPOs.
.DESCRIPTION
    Deployt Next-Exam Install/Update als GPO-Preferences GEPLANTER TASK (SYSTEM),
    Trigger: Bei Systemstart (+Delay, StartWhenAvailable) + taeglich als Catch-up.
    Der Task ruft das bewaehrte Startup-NextExam.ps1 auf (msiexec-Install).

    HINTERGRUND (v3.0): Bis v2.1 wurde ein GPO-COMPUTER-STARTUP-SCRIPT verwendet
    (scripts.ini + psscripts.ini + CMD-Wrapper). Das feuerte auf manchen Clients
    beim Boot NICHT zuverlaessig (gpscript "0 Sekunden" trotz identischer, korrekter
    Config) -> Clients blieben auf alter Version. Bewiesen: Script/Share/Rechte/MSI
    sind gesund (laeuft als SYSTEM fehlerfrei durch); nur der Startup-Script-TRIGGER
    war unzuverlaessig. Loesung: GPP-Scheduled-Task. Die Preferences-CSE legt/aktualisiert
    den Task bei JEDEM GP-Refresh (nicht nur beim Boot), das Feuern uebernimmt der
    Task Scheduler (BootTrigger + Daily + StartWhenAvailable) -> immun + self-healing.

    Beim Umbau wird das alte Startup-Script auf bereits ausgerollten Clients sauber
    entfernt: leere scripts.ini/psscripts.ini (Scripts-CSE raeumt die Registrierung ab).
    Die Startup-NextExam.ps1 bleibt in SYSVOL als Task-Action-Ziel liegen.

    WICHTIG: Startup-NextExam.ps1 wird als reines ASCII mit CRLF geschrieben,
             da PowerShell 5.1 BOM-lose Dateien als ANSI interpretiert.
.NOTES
    v3.1 - Task: RegistrationTrigger ergaenzt -> Task laeuft SOFORT, sobald GP ihn
           anlegt/aktualisiert (naechster GP-Refresh, ohne Boot/ohne 07:30-Warten).
           Behebt: beim ersten Rollout/Update musste bisher ein Boot/Tages-Trigger
           abgewartet werden. Boot+Daily bleiben als Absicherung.
    v3.0 - Umstellung Startup-Script -> GPP Scheduled Task (SYSTEM, Boot+Daily)
         - Migration: retire startup-script (leere scripts.ini/psscripts.ini)
         - gPCMachineExtensionNames: Scripts-CSE + Preferences-Scheduled-Tasks-CSE
         - Update-GPOMachineVersion / Set-GPOMachineExtension: -CseList parametrisiert
         - Get-NextExamInstallGPOStatus / Test-GPOHealth pruefen Task-XML
    v2.1 - Fix: Version-Inkrement korrigiert (Computer-Side = Low 16-Bit, +1)
         - Fix: Get-SysvolPath mit robustem DC-Fallback
         - Fix: gpt.ini CRLF-safe + Readback-Verify
         - Fix: Set-GPOMachineExtension idempotent
         - Neu: Test-GPOHealth / Test-SysvolDFSConsistency
    v2.0 - CMD-Wrapper-Ansatz (scripts.ini + .cmd -> .ps1)   [abgeloest durch v3.0]
#>

# ------------------------------------------------------------
# Client-Side-Extension GUIDs
# ------------------------------------------------------------
# Scripts CSE (Startup/Shutdown) - nur noch fuer sauberes Entfernen des Altskripts
# Quelle: https://learn.microsoft.com/archive/blogs/mempson/group-policy-client-side-extension-list
$script:ScriptsCseGuid  = '{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'
$script:ScriptsToolGuid = '{40B6664F-4972-11D1-A7CA-0000F87571E3}'

# Group Policy Preferences - Scheduled Tasks CSE + gemeinsame Prefs-Tool-GUID
# CSE  {AADCED64-746C-4633-A97C-D61349046527} = Scheduled Tasks client-side extension
# Tool {CAB54552-DEEA-4691-817E-ED4A4D1AFC72} = Preferences MMC-Tool (fuer alle GPP gleich)
# XML-Root {CC63F200-...} / TaskV2 {D8896631-...} = MS-GPSCH ScheduledTasks/TaskV2
$script:PrefTasksCseGuid  = '{AADCED64-746C-4633-A97C-D61349046527}'
$script:PrefToolGuid      = '{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}'
$script:PrefTasksRootClsid = '{CC63F200-7309-4ba0-B154-A71CD118DBCC}'
$script:PrefTasksV2Clsid   = '{D8896631-B747-47a7-84A6-C155337F3BC8}'

# Stabile UIDs pro Rolle (action="R" ersetzt denselben Task-Item bei Re-Deploy)
$script:TaskUid = @{
    Student = '{9F3B1A2C-1E44-4C55-9A11-4E455853544D}'
    Teacher = '{9F3B1A2C-1E44-4C55-9A11-544541434852}'
}
# Task-Name pro Rolle
function Get-NextExamTaskName { param([string]$Role) "HU-NextExam-$Role-AutoInstall" }

# Kombinierte gPCMachineExtensionNames (Scripts-CSE + Prefs-Tasks-CSE), GUID-sortiert.
# 42B5FAAE... < AADCED64... -> Scripts-Gruppe zuerst.
function Get-InstallCseList {
    ("[{0}{1}]" -f $script:ScriptsCseGuid, $script:ScriptsToolGuid) +
    ("[{0}{1}]" -f $script:PrefTasksCseGuid, $script:PrefToolGuid)
}

# Session-Cache: Erster funktionierender DC-Hostname pro Domain
$script:SysvolDCCache = @{}

function Test-GPOModule {
    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        throw "GroupPolicy Modul fehlt (RSAT-ADDS-Tools installieren)."
    }
    Import-Module GroupPolicy -ErrorAction Stop
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "ActiveDirectory Modul fehlt."
    }
    Import-Module ActiveDirectory -ErrorAction Stop
}

function Get-GPODN {
    param([Parameter(Mandatory)]$GPO, [Parameter(Mandatory)][string]$DomainFQDN)
    $gpoGuid = "{$($GPO.Id)}"
    $domainDN = 'DC=' + ($DomainFQDN -replace '\.', ',DC=')
    return "CN=$gpoGuid,CN=Policies,CN=System,$domainDN"
}

# ============================================================
# Get-SysvolPath - Robustes DC-Fallback
# ============================================================
function Get-SysvolPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [switch]$SkipDFS
    )
    $gpoGuid = "{$($GPO.Id)}"
    $policyRelPath = "$DomainFQDN\Policies\$gpoGuid"

    function Test-PolicyPath {
        param([string]$SysvolRoot)
        $fullPath = "\\$SysvolRoot\SYSVOL\$policyRelPath"
        try { if (Test-Path $fullPath -ErrorAction Stop) { return $fullPath } } catch {}
        return $null
    }

    $cachedDC = $script:SysvolDCCache[$DomainFQDN]
    if ($cachedDC) {
        $result = Test-PolicyPath -SysvolRoot $cachedDC
        if ($result) { return $result }
        $script:SysvolDCCache.Remove($DomainFQDN)
    }
    if (-not $SkipDFS) {
        $result = Test-PolicyPath -SysvolRoot $DomainFQDN
        if ($result) { return $result }
    }
    if ($Server) {
        $result = Test-PolicyPath -SysvolRoot $Server
        if ($result) { $script:SysvolDCCache[$DomainFQDN] = $Server; return $result }
    }
    $allDCs = @()
    try {
        $adParams = @{ Filter = { Enabled -eq $true }; Properties = @('HostName') }
        if ($Server) { $adParams.Server = $Server }
        $allDCs = @(Get-ADDomainController @adParams |
                    Where-Object { $_.HostName -and $_.HostName -ne $Server } |
                    Select-Object -ExpandProperty HostName)
    } catch {
        try {
            $srvRecords = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainFQDN" -Type SRV -ErrorAction Stop
            $allDCs = @($srvRecords |
                        Where-Object { $_.NameTarget -and $_.NameTarget -ne $Server } |
                        Select-Object -ExpandProperty NameTarget)
        } catch { Write-Warning "Get-SysvolPath: DC-Enumeration fehlgeschlagen: $_" }
    }
    foreach ($dc in $allDCs) {
        $result = Test-PolicyPath -SysvolRoot $dc
        if ($result) { $script:SysvolDCCache[$DomainFQDN] = $dc; return $result }
    }
    $tried = @($DomainFQDN); if ($Server) { $tried += $Server }; $tried += $allDCs
    throw ("SYSVOL NICHT erreichbar fuer GPO $gpoGuid!`n" +
           "Getestete Pfade:`n" +
           ($tried | ForEach-Object { "  \\$_\SYSVOL\$policyRelPath" } | Out-String))
}

# ============================================================
# Update-GPOMachineVersion - Korrektes Version-Inkrement
#   v3.0: -CseList parametrisiert (Default = Scripts-Pair -> Rueckwaertskompatibel)
# ============================================================
function Update-GPOMachineVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [string]$CseList
    )
    if (-not $CseList) {
        $CseList = "[{0}{1}]" -f $script:ScriptsCseGuid, $script:ScriptsToolGuid
    }

    $dn = Get-GPODN -GPO $GPO -DomainFQDN $DomainFQDN
    $adParams = @{ Identity = $dn; Properties = @('versionNumber','gPCMachineExtensionNames') }
    if ($Server) { $adParams.Server = $Server }
    $adObj = Get-ADObject @adParams

    $current = [int64]$adObj.versionNumber
    $currentUserVer     = ($current -band 0xFFFF0000) -shr 16
    $currentComputerVer = $current -band 0x0000FFFF
    $newComputerVer = $currentComputerVer + 1
    $newVer = ($currentUserVer -shl 16) -bor $newComputerVer

    $setParams = @{
        Identity = $dn
        Replace  = @{ versionNumber = [int]$newVer; gPCMachineExtensionNames = $CseList }
    }
    if ($Server) { $setParams.Server = $Server }
    Set-ADObject @setParams

    $sysvol = Get-SysvolPath -GPO $GPO -DomainFQDN $DomainFQDN -Server $Server
    $gptIni = Join-Path $sysvol 'GPT.INI'
    if (Test-Path $gptIni) {
        $raw = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)
        $raw = [regex]::Replace($raw, '(?im)^Version=\d+\r?$', "Version=$newVer")
        if ($raw -match '(?im)^gPCMachineExtensionNames=') {
            $raw = [regex]::Replace($raw, '(?im)^gPCMachineExtensionNames=.*\r?$', "gPCMachineExtensionNames=$CseList")
        } else {
            $raw = [regex]::Replace($raw, '(?im)(^Version=\d+)\r?\n', "`$1`r`ngPCMachineExtensionNames=$CseList`r`n")
        }
        $raw = $raw -replace "`r`n", "`n"; $raw = $raw -replace "`n", "`r`n"
        if (-not $raw.EndsWith("`r`n")) { $raw += "`r`n" }
        [System.IO.File]::WriteAllText($gptIni, $raw, [System.Text.Encoding]::Default)
    } else {
        $content = "[General]`r`nVersion=$newVer`r`ngPCMachineExtensionNames=$CseList`r`ndisplayName=Neues Gruppenrichtlinienobjekt`r`n"
        [System.IO.File]::WriteAllText($gptIni, $content, [System.Text.Encoding]::Default)
    }

    if (Test-Path $gptIni) {
        $verify = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)
        if ($verify -notmatch "Version=$newVer") { Write-Warning "gpt.ini Verify FEHLGESCHLAGEN: Version=$newVer" }
    } else { Write-Warning "gpt.ini existiert nicht nach Schreiben (DFS-Replication Delay?)" }
    $verifyAD = Get-ADObject @adParams
    if ([int64]$verifyAD.versionNumber -ne $newVer) {
        Write-Warning "AD Verify FEHLGESCHLAGEN: versionNumber=$($verifyAD.versionNumber), erwartet=$newVer"
    }
    return $newVer
}

function Set-GPOMachineExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [string]$CseList
    )
    if (-not $CseList) {
        $CseList = "[{0}{1}]" -f $script:ScriptsCseGuid, $script:ScriptsToolGuid
    }
    $dn = Get-GPODN -GPO $GPO -DomainFQDN $DomainFQDN
    $setParams = @{ Identity = $dn; Replace = @{ gPCMachineExtensionNames = $CseList } }
    if ($Server) { $setParams.Server = $Server }
    Set-ADObject @setParams
}

function Test-GPOCreateRights {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DomainFQDN, [string]$Server)
    try {
        Import-Module ActiveDirectory -EA Stop
        $adParams = @{ Identity = $DomainFQDN }
        if ($Server) { $adParams.Server = $Server }
        $domain = Get-ADDomain @adParams
        $domSid = [string]$domain.DomainSID
        $targetSids = @("$domSid-512","$domSid-519","$domSid-520",'S-1-5-32-544')
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $tokenSids = @($id.Groups | ForEach-Object { $_.Value }); $tokenSids += $id.User.Value
        $match = @()
        foreach ($sid in $targetSids) {
            if ($tokenSids -contains $sid) {
                try { $name = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value }
                catch { $name = $sid }
                $match += $name
            }
        }
        return [PSCustomObject]@{ HasRights = ($match.Count -gt 0); Groups = $match; User = $id.Name }
    } catch { return [PSCustomObject]@{ HasRights = $null; Reason = "Check fehlgeschlagen: $_" } }
}

function Write-SysvolFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Data, [switch]$Hidden)
    if (Test-Path $Path) {
        try { (Get-Item $Path -Force).Attributes = 'Normal' } catch {}
        try { Remove-Item -Path $Path -Force -ErrorAction Stop } catch {
            try { & takeown.exe /F $Path 2>&1 | Out-Null } catch {}
            try { & icacls.exe $Path /grant "$($env:USERDOMAIN)\$($env:USERNAME):F" /C 2>&1 | Out-Null } catch {}
            Remove-Item -Path $Path -Force -ErrorAction Stop
        }
    }
    [System.IO.File]::WriteAllBytes($Path, $Data)
    if ($Hidden) { (Get-Item $Path).Attributes = 'Hidden,Archive' }
}

# ============================================================
# NEU v3.0: GPP ScheduledTasks.xml (TaskV2, SYSTEM) generieren
# ============================================================
function New-NextExamTaskXml {
    <#
    .SYNOPSIS
        Baut den ScheduledTasks.xml-Inhalt fuer einen SYSTEM-Task (TaskV2, action=R).
    .DESCRIPTION
        Trigger: RegistrationTrigger (feuert sofort bei GP-Anlage/-Update) + BootTrigger
                 (+BootDelay) + taeglicher CalendarTrigger. StartWhenAvailable.
        Action:  powershell.exe -File <Ps1UncPath> -SharePath .. -Role .. -StatusPath ..
        action="R" (Replace) = idempotent, self-healing bei jedem GP-Refresh; das ps1
        ist idempotent (installiert nur bei Versionsdifferenz, sonst ~1s No-op).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [Parameter(Mandatory)][string]$Ps1UncPath,
        [Parameter(Mandatory)][string]$SharePath,
        [string]$StatusPath,
        [string]$DailyTime = '07:30',
        [string]$BootDelay = 'PT2M',
        [string]$Changed   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    )
    $taskName = Get-NextExamTaskName -Role $Role
    $uid      = $script:TaskUid[$Role]

    # Argumente + XML-escapen (nur &,<,> noetig; " ist in Element-Text erlaubt)
    $argLine = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -File `"$Ps1UncPath`" -SharePath `"$SharePath`" -Role $Role"
    if ($StatusPath) { $argLine += " -StatusPath `"$StatusPath`"" }
    $esc = { param($s) $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    $argXml   = & $esc $argLine
    $descXml  = & $esc "NextExam $Role Auto-Install/Update (HU-NextExam-Manager, ersetzt GPO-Startup-Script)"
    if ($DailyTime -notmatch '^\d{1,2}:\d{2}$') { throw "DailyTime ungueltig (HH:mm): $DailyTime" }
    $startBoundary = '2020-01-01T{0}:00' -f ($DailyTime.PadLeft(5,'0'))

    @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="$($script:PrefTasksRootClsid)">
	<TaskV2 clsid="$($script:PrefTasksV2Clsid)" name="$taskName" image="0" changed="$Changed" uid="$uid" userContext="0" removePolicy="0">
		<Properties action="R" name="$taskName" runAs="NT AUTHORITY\System" logonType="S4U">
			<Task version="1.3">
				<RegistrationInfo>
					<Author>HU-NextExam-Manager</Author>
					<Description>$descXml</Description>
				</RegistrationInfo>
				<Principals>
					<Principal id="Author">
						<UserId>NT AUTHORITY\System</UserId>
						<RunLevel>HighestAvailable</RunLevel>
						<LogonType>S4U</LogonType>
					</Principal>
				</Principals>
				<Settings>
					<IdleSettings>
						<Duration>PT10M</Duration>
						<WaitTimeout>PT1H</WaitTimeout>
						<StopOnIdleEnd>false</StopOnIdleEnd>
						<RestartOnIdle>false</RestartOnIdle>
					</IdleSettings>
					<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
					<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
					<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
					<AllowHardTerminate>true</AllowHardTerminate>
					<StartWhenAvailable>true</StartWhenAvailable>
					<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
					<AllowStartOnDemand>true</AllowStartOnDemand>
					<Enabled>true</Enabled>
					<Hidden>false</Hidden>
					<ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
					<Priority>7</Priority>
					<RestartOnFailure>
						<Interval>PT5M</Interval>
						<Count>3</Count>
					</RestartOnFailure>
				</Settings>
				<Triggers>
					<RegistrationTrigger>
						<Enabled>true</Enabled>
					</RegistrationTrigger>
					<BootTrigger>
						<Enabled>true</Enabled>
						<Delay>$BootDelay</Delay>
					</BootTrigger>
					<CalendarTrigger>
						<StartBoundary>$startBoundary</StartBoundary>
						<Enabled>true</Enabled>
						<ScheduleByDay>
							<DaysInterval>1</DaysInterval>
						</ScheduleByDay>
					</CalendarTrigger>
				</Triggers>
				<Actions Context="Author">
					<Exec>
						<Command>powershell.exe</Command>
						<Arguments>$argXml</Arguments>
					</Exec>
				</Actions>
			</Task>
		</Properties>
	</TaskV2>
</ScheduledTasks>
"@
}

function New-NextExamInstallGPO {
    <#
    .SYNOPSIS
        Erstellt/aktualisiert Install-GPO fuer eine Rolle - v3.0 via GPP Scheduled Task.
    .DESCRIPTION
        - Schreibt Startup-NextExam.ps1 nach Machine\Scripts\Startup (Task-Action-Ziel, ASCII+CRLF)
        - Schreibt Machine\Preferences\ScheduledTasks\ScheduledTasks.xml (SYSTEM-Task)
        - MIGRATION: leert scripts.ini/psscripts.ini -> Scripts-CSE entfernt Altskript-Registrierung
        - Setzt gPCMachineExtensionNames = Scripts-CSE + Prefs-ScheduledTasks-CSE, Version +1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$StartupTemplatePath,
        [string]$StatusPath,
        [string]$DailyTime = '07:30',
        [string]$BootDelay = 'PT2M'
    )
    Test-GPOModule

    # 1. GPO erstellen wenn nicht vorhanden
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue
    $created = $false
    if (-not $gpo) {
        $newParams = @{ Name = $GPOName; Domain = $DomainFQDN
                        Comment = "HU-NextExam-Manager: $Role Install via GPP Scheduled Task" }
        if ($Server) { $newParams.Server = $Server }
        $gpo = New-GPO @newParams
        $created = $true
    }

    function _step([string]$Label, [scriptblock]$Block) {
        try { & $Block } catch { throw "[Step: $Label] $($_.Exception.Message)" }
    }

    # 2. SYSVOL-Struktur (Scripts + Preferences\ScheduledTasks)
    _step 'SYSVOL-Dirs' {
        $script:sysvol      = Get-SysvolPath -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server
        $script:scriptsDir  = Join-Path $script:sysvol 'Machine\Scripts'
        $script:startupDir  = Join-Path $script:scriptsDir 'Startup'
        $script:shutdownDir = Join-Path $script:scriptsDir 'Shutdown'
        $script:prefTasksDir= Join-Path $script:sysvol 'Machine\Preferences\ScheduledTasks'
        foreach ($d in @($script:scriptsDir, $script:startupDir, $script:shutdownDir, $script:prefTasksDir)) {
            for ($i = 1; $i -le 5; $i++) {
                if (Test-Path $d) { break }
                try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null; break } catch {}
                Start-Sleep -Milliseconds 500
            }
            if (-not (Test-Path $d)) { throw "SYSVOL-Ordner nicht erstellt: $d" }
        }
    }
    $sysvol = $script:sysvol; $scriptsDir = $script:scriptsDir
    $startupDir = $script:startupDir; $prefTasksDir = $script:prefTasksDir

    # 3. Startup-Script als reines ASCII + CRLF (Task-Action-Ziel)
    $scriptName   = 'Startup-NextExam.ps1'
    $targetScript = Join-Path $startupDir $scriptName
    _step 'Startup-PS1' {
        if (-not (Test-Path $StartupTemplatePath)) { throw "Startup-Template fehlt: $StartupTemplatePath" }
        $content = Get-Content -Path $StartupTemplatePath -Raw -Encoding UTF8
        $content = $content -replace "`r`n", "`n"; $content = $content -replace "`n", "`r`n"
        $content = $content -replace ([char]0x00A0), ' '
        $asciiBytes = [System.Text.Encoding]::ASCII.GetBytes($content)
        Write-SysvolFile -Path $targetScript -Data $asciiBytes
        $sz = (Get-Item $targetScript).Length
        if ($sz -lt 100) { throw "Startup-Script verdaechtig klein ($sz bytes)" }
    }
    # UNC-Pfad zum Script (fuer die Task-Action). SYSTEM/Computerkonto liest SYSVOL.
    $ps1Unc = $targetScript

    # 4. GPP ScheduledTasks.xml (UTF-8, sichtbar - GPP-XML sind nicht hidden)
    $tasksXmlPath = Join-Path $prefTasksDir 'ScheduledTasks.xml'
    _step 'ScheduledTasks.xml' {
        $xml = New-NextExamTaskXml -Role $Role -Ps1UncPath $ps1Unc -SharePath $SharePath `
                    -StatusPath $StatusPath -DailyTime $DailyTime -BootDelay $BootDelay
        $xml = $xml -replace "`r`n","`n"; $xml = $xml -replace "`n","`r`n"
        $utf8 = New-Object System.Text.UTF8Encoding($false)   # UTF-8 OHNE BOM
        Write-SysvolFile -Path $tasksXmlPath -Data ($utf8.GetBytes($xml))
    }

    # 5. MIGRATION: altes Startup-Script abraeumen -> leere scripts.ini + psscripts.ini
    #    (Scripts-CSE laeuft, findet 0 Scripts, entfernt die alte Registrierung am Client)
    _step 'Retire-Startup-Script' {
        $emptyScripts = "[Startup]`r`n"
        Write-SysvolFile -Path (Join-Path $scriptsDir 'scripts.ini') `
            -Data ([System.Text.Encoding]::Default.GetBytes($emptyScripts)) -Hidden
        $emptyPs = "[Startup]`r`n`r`n[Shutdown]`r`n"
        $bom = [byte[]]@(0xFF,0xFE)
        Write-SysvolFile -Path (Join-Path $scriptsDir 'psscripts.ini') `
            -Data ($bom + [System.Text.Encoding]::Unicode.GetBytes($emptyPs)) -Hidden
        # alten CMD-Wrapper loeschen (nicht mehr benoetigt)
        $oldCmd = Join-Path $startupDir 'Startup-NextExam.cmd'
        if (Test-Path $oldCmd) { try { (Get-Item $oldCmd -Force).Attributes='Normal'; Remove-Item $oldCmd -Force } catch {} }
    }

    # 6. CSE (Scripts + Prefs-Tasks) + Version +1
    $cseList = Get-InstallCseList
    $ver = Update-GPOMachineVersion -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server -CseList $cseList

    return [PSCustomObject]@{
        GPO          = $gpo
        Name         = $gpo.DisplayName
        Id           = $gpo.Id
        SysvolPath   = $sysvol
        ScriptPath   = $targetScript
        TaskXmlPath  = $tasksXmlPath
        TaskName     = (Get-NextExamTaskName -Role $Role)
        SharePath    = $SharePath
        Role         = $Role
        DeployMode   = 'ScheduledTask'
        Created      = $created
        VersionNew   = $ver
        # --- Rueckwaertskompatibel (v2.x GUI liest evtl. diese Felder) ---
        CmdWrapper   = $null
        ScriptsIni   = (Join-Path $scriptsDir 'scripts.ini')
        PsScriptsIni = (Join-Path $scriptsDir 'psscripts.ini')
    }
}

function Get-NextExamInstallGPOStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [string]$LinkOU
    )
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue

    $result = [PSCustomObject]@{
        Name         = $GPOName
        Exists       = $false
        Id           = $null
        TaskXmlOK    = $false
        ScriptOK     = $false
        StartupRetired = $false
        # --- Rueckwaertskompatibel (v2.x GUI liest diese Felder) ---
        CmdWrapperOK = $false
        ScriptsIniOK = $false
        LinkedTo     = @()
        LinkedToThis = $false
    }
    if (-not $gpo) { return $result }
    $result.Exists = $true
    $result.Id     = $gpo.Id

    $sysvol      = Get-SysvolPath -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server
    $scriptsDir  = Join-Path $sysvol 'Machine\Scripts'
    $startupDir  = Join-Path $scriptsDir 'Startup'
    $tasksXml    = Join-Path $sysvol 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml'
    $script      = Join-Path $startupDir 'Startup-NextExam.ps1'
    $sIni        = Join-Path $scriptsDir 'scripts.ini'

    $result.TaskXmlOK = (Test-Path $tasksXml) -and ((Get-Item $tasksXml).Length -gt 100)
    $result.ScriptOK  = (Test-Path $script)   -and ((Get-Item $script).Length -gt 100)
    # Kompat-Felder: in Task-Modus = Deployment-Health (Task-XML vorhanden) -> GUI bleibt gruen
    $result.CmdWrapperOK = $result.TaskXmlOK
    $result.ScriptsIniOK = $result.TaskXmlOK
    # "retired" = scripts.ini existiert, enthaelt aber keinen 0CmdLine-Eintrag mehr
    if (Test-Path $sIni) {
        try {
            $ini = [System.IO.File]::ReadAllText($sIni, [System.Text.Encoding]::Default)
            $result.StartupRetired = ($ini -notmatch '(?im)^\s*0CmdLine=')
        } catch {}
    } else { $result.StartupRetired = $true }

    try {
        if ($LinkOU) {
            $ghParams = @{ Target = $LinkOU; Domain = $DomainFQDN }
            if ($Server) { $ghParams.Server = $Server }
            $inh = Get-GPInheritance @ghParams -ErrorAction Stop
            $result.LinkedToThis = [bool]($inh.GpoLinks | Where-Object { $_.DisplayName -eq $GPOName })
        }
        $xmlParams = @{ Guid = $gpo.Id; ReportType = 'Xml'; Domain = $DomainFQDN }
        if ($Server) { $xmlParams.Server = $Server }
        [xml]$rpt = Get-GPOReport @xmlParams
        $nodes = $rpt.SelectNodes('//*[local-name()="LinksTo"]')
        $result.LinkedTo = @($nodes | ForEach-Object { $_.SelectSingleNode('*[local-name()="SOMPath"]').InnerText })
    } catch {}
    return $result
}

# ---- Firewall-GPO (unveraendert) ----
function New-NextExamFWGPO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$ExePath,
        [string[]]$Profiles    = @('Domain','Private'),
        [bool]$EnableTCPPort   = $false,
        [int]$TCPPort          = 22422,
        [bool]$EnableUDPPort   = $false,
        [string]$UDPPorts      = '6024,6025'
    )
    Test-GPOModule
    if (-not (Get-Module -ListAvailable -Name NetSecurity)) { throw "NetSecurity Modul fehlt." }
    Import-Module NetSecurity -ErrorAction Stop

    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue
    $created = $false
    if (-not $gpo) {
        $newParams = @{ Name = $GPOName; Domain = $DomainFQDN; Comment = "HU-NextExam-Manager: $Role Firewall-Rules" }
        if ($Server) { $newParams.Server = $Server }
        $gpo = New-GPO @newParams; $created = $true
    }
    $policyStore = "$DomainFQDN\$GPOName"; $profileStr = ($Profiles -join ',')
    try {
        $existing = Get-NetFirewallRule -PolicyStore $policyStore -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'HU-NEM-*' }
        foreach ($r in $existing) { Remove-NetFirewallRule -PolicyStore $policyStore -Name $r.Name -ErrorAction SilentlyContinue }
    } catch {}
    $created_rules = @()
    foreach ($dir in @('Inbound','Outbound')) {
        $ruleName = "HU-NEM-$Role-App-$dir"
        $null = New-NetFirewallRule -PolicyStore $policyStore -DisplayName $ruleName `
                    -Description "HU-NextExam-Manager: $Role EXE $dir" -Direction $dir -Action Allow `
                    -Program $ExePath -Profile $profileStr -Enabled True
        $created_rules += $ruleName
    }
    if ($EnableTCPPort -and $TCPPort -gt 0) {
        foreach ($dir in @('Inbound','Outbound')) {
            $ruleName = "HU-NEM-$Role-TCP-$dir"
            if ($dir -eq 'Inbound') {
                $null = New-NetFirewallRule -PolicyStore $policyStore -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $TCPPort -Profile $profileStr -Enabled True
            } else {
                $null = New-NetFirewallRule -PolicyStore $policyStore -DisplayName $ruleName -Direction Outbound -Action Allow -Protocol TCP -RemotePort $TCPPort -Profile $profileStr -Enabled True
            }
            $created_rules += $ruleName
        }
    }
    if ($EnableUDPPort -and $UDPPorts) {
        $ports = $UDPPorts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($dir in @('Inbound','Outbound')) {
            $ruleName = "HU-NEM-$Role-UDP-$dir"
            if ($dir -eq 'Inbound') {
                $null = New-NetFirewallRule -PolicyStore $policyStore -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol UDP -LocalPort $ports -Profile $profileStr -Enabled True
            } else {
                $null = New-NetFirewallRule -PolicyStore $policyStore -DisplayName $ruleName -Direction Outbound -Action Allow -Protocol UDP -RemotePort $ports -Profile $profileStr -Enabled True
            }
            $created_rules += $ruleName
        }
    }
    # FW-GPO nutzt die Firewall-CSE (von New-NetFirewallRule gesetzt); nur Version +1,
    # Default-CseList NICHT ueberschreiben -> hier gPCMachineExtensionNames unangetastet lassen:
    $dn = Get-GPODN -GPO $gpo -DomainFQDN $DomainFQDN
    $adP = @{ Identity = $dn; Properties = 'gPCMachineExtensionNames' }; if ($Server) { $adP.Server = $Server }
    $curCse = [string](Get-ADObject @adP).gPCMachineExtensionNames
    $ver = Update-GPOMachineVersion -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server -CseList $curCse
    return [PSCustomObject]@{ GPO=$gpo; Name=$gpo.DisplayName; Id=$gpo.Id; Role=$Role; Created=$created; Rules=$created_rules; VersionNew=$ver }
}

function Get-NextExamFWGPOStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GPOName, [Parameter(Mandatory)][string]$DomainFQDN, [string]$Server, [string]$LinkOU)
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }; if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue
    $result = [PSCustomObject]@{ Name=$GPOName; Exists=$false; Id=$null; RuleCount=0; LinkedTo=@(); LinkedToThis=$false }
    if (-not $gpo) { return $result }
    $result.Exists = $true; $result.Id = $gpo.Id
    try {
        $policyStore = "$DomainFQDN\$GPOName"
        $rules = @(Get-NetFirewallRule -PolicyStore $policyStore -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'HU-NEM-*' })
        $result.RuleCount = $rules.Count
    } catch {}
    try {
        if ($LinkOU) {
            $ghParams = @{ Target = $LinkOU; Domain = $DomainFQDN }; if ($Server) { $ghParams.Server = $Server }
            $inh = Get-GPInheritance @ghParams -ErrorAction Stop
            $result.LinkedToThis = [bool]($inh.GpoLinks | Where-Object { $_.DisplayName -eq $GPOName })
        }
        $xmlParams = @{ Guid = $gpo.Id; ReportType = 'Xml'; Domain = $DomainFQDN }; if ($Server) { $xmlParams.Server = $Server }
        [xml]$rpt = Get-GPOReport @xmlParams
        $nodes = $rpt.SelectNodes('//*[local-name()="LinksTo"]')
        $result.LinkedTo = @($nodes | ForEach-Object { $_.SelectSingleNode('*[local-name()="SOMPath"]').InnerText })
    } catch {}
    return $result
}

function Set-NextExamGPOLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GPOName, [Parameter(Mandatory)][string]$DomainFQDN, [string]$Server, [Parameter(Mandatory)][string]$OUDistinguishedName)
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }; if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction Stop
    $linkParams = @{ Name = $GPOName; Target = $OUDistinguishedName; Domain = $DomainFQDN; LinkEnabled = 'Yes' }
    if ($Server) { $linkParams.Server = $Server }
    try { New-GPLink @linkParams -ErrorAction Stop | Out-Null }
    catch { if ($_.Exception.Message -match 'already linked|bereits.*verkn|already\s+has\s+a\s+link') {} else { throw } }
}

function Remove-NextExamInstallGPO {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GPOName, [Parameter(Mandatory)][string]$DomainFQDN, [string]$Server)
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN; Confirm = $false }; if ($Server) { $gpoParams.Server = $Server }
    try { Remove-GPO @gpoParams -ErrorAction Stop; return $true }
    catch { if ($_.Exception.Message -match 'nicht gefunden|not found|gpoDisplayName') { return $false }; throw }
}

# ============================================================
# Test-GPOHealth - Diagnose (v3.0: prueft Task-XML statt Startup-Script)
# ============================================================
function Test-GPOHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GPOName, [Parameter(Mandatory)][string]$DomainFQDN, [string]$Server)
    Test-GPOModule
    $result = [ordered]@{ GPOName=$GPOName; Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); RunningOn=$env:COMPUTERNAME; IsDC=$false; Checks=[ordered]@{}; Errors=@() }
    try { $result.IsDC = ((Get-CimInstance Win32_ComputerSystem -EA Stop).DomainRole -ge 4) } catch {}
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }; if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -EA SilentlyContinue
    if (-not $gpo) { $result.Errors += "GPO nicht gefunden"; return [PSCustomObject]$result }
    $result.Checks['GPO_Id'] = $gpo.Id.ToString()
    try { $sysvol = Get-SysvolPath -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server; $result.Checks['SYSVOL_Resolved'] = $sysvol }
    catch { $result.Errors += "SYSVOL: $_"; return [PSCustomObject]$result }

    $gptIni = Join-Path $sysvol 'GPT.INI'
    $result.Checks['gptini_Exists'] = (Test-Path $gptIni)
    if (Test-Path $gptIni) {
        $txt = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)
        if ($txt -match 'Version=(\d+)') { $v=[int64]$Matches[1]; $result.Checks['gptini_Version']=$v; $result.Checks['gptini_ComputerVer']=$v -band 0xFFFF }
        $result.Checks['gptini_HasPrefTasksCSE'] = ($txt -match [regex]::Escape($script:PrefTasksCseGuid))
    }
    $dn = Get-GPODN -GPO $gpo -DomainFQDN $DomainFQDN
    $adP = @{ Identity = $dn; Properties = @('versionNumber','gPCMachineExtensionNames') }; if ($Server) { $adP.Server = $Server }
    try {
        $ad = Get-ADObject @adP; $adV=[int64]$ad.versionNumber
        $result.Checks['AD_Version']=$adV; $result.Checks['AD_ComputerVer']=$adV -band 0xFFFF
        $result.Checks['AD_HasPrefTasksCSE'] = ([string]$ad.gPCMachineExtensionNames).Contains($script:PrefTasksCseGuid)
        if ($result.Checks.ContainsKey('gptini_Version')) { $result.Checks['VersionSync'] = ($adV -eq $result.Checks['gptini_Version']) }
    } catch { $result.Errors += "AD: $_" }

    $taskXml = Join-Path $sysvol 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml'
    $result.Checks['TaskXml'] = (Test-Path $taskXml)
    if (Test-Path $taskXml) {
        $result.Checks['TaskXml_Size'] = (Get-Item $taskXml).Length
        try { [xml]$tx = Get-Content $taskXml -Raw; $result.Checks['TaskXml_Valid'] = [bool]$tx.ScheduledTasks.TaskV2 } catch { $result.Checks['TaskXml_Valid'] = $false; $result.Errors += "TaskXml Parse: $_" }
    }
    $ps1 = Join-Path $sysvol 'Machine\Scripts\Startup\Startup-NextExam.ps1'
    $result.Checks['StartupPS1'] = (Test-Path $ps1)
    if (Test-Path $ps1) { $result.Checks['StartupPS1_Size'] = (Get-Item $ps1).Length }
    # Migration: alter Startup-Eintrag entfernt?
    $sIni = Join-Path $sysvol 'Machine\Scripts\scripts.ini'
    if (Test-Path $sIni) {
        $ini = [System.IO.File]::ReadAllText($sIni, [System.Text.Encoding]::Default)
        $result.Checks['OldStartupRetired'] = ($ini -notmatch '(?im)^\s*0CmdLine=')
    } else { $result.Checks['OldStartupRetired'] = $true }
    return [PSCustomObject]$result
}

function Test-SysvolDFSConsistency {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$GPO, [Parameter(Mandatory)][string]$DomainFQDN, [string]$Server)
    $gpoGuid = "{$($GPO.Id)}"; $relPath = "$DomainFQDN\Policies\$gpoGuid"
    $adP = @{ Filter = { Enabled -eq $true }; Properties = @('HostName') }; if ($Server) { $adP.Server = $Server }
    $allDCs = @(Get-ADDomainController @adP | Select-Object -ExpandProperty HostName)
    $results = foreach ($dc in $allDCs) {
        $e = [ordered]@{ DC=$dc; Reachable=$false; Version=$null; HasTaskXml=$false }
        $p = "\\$dc\SYSVOL\$relPath"
        if (Test-Path $p -EA SilentlyContinue) {
            $e.Reachable = $true
            $g = Join-Path $p 'GPT.INI'
            if (Test-Path $g) { $t=[System.IO.File]::ReadAllText($g,[System.Text.Encoding]::Default); if ($t -match 'Version=(\d+)') { $e.Version=[int64]$Matches[1] } }
            $e.HasTaskXml = (Test-Path (Join-Path $p 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml') -EA SilentlyContinue)
        }
        [PSCustomObject]$e
    }
    $vers = @($results | Where-Object { $_.Reachable -and $null -ne $_.Version } | Select-Object -ExpandProperty Version -Unique)
    [PSCustomObject]@{ GPO=$gpoGuid; Consistent=($vers.Count -le 1); DCResults=$results; UniqueVersions=$vers }
}

# ============================================================
# NEU v3.0: Invoke-NextExamGpoMigration - "Alle migrieren"
#   Findet bestehende Install-GPOs selbst, liest deren aktuelle Parameter
#   und baut sie in place auf Task-Modus um. Kein config.json/Hauptscript noetig.
# ============================================================
function Invoke-NextExamGpoMigration {
    <#
    .SYNOPSIS
        Migriert ALLE bestehenden NextExam-Install-GPOs vom Startup-Script auf Task-Modus.
    .DESCRIPTION
        - Findet GPOs per Namensfilter (Default 'HU-NEXT-EXAM-*').
        - Erkennt die alte Startup-Script-Registrierung an psscripts.ini (0CmdLine=Startup-NextExam.ps1).
        - Liest die dort hinterlegten Parameter (-SharePath/-Role/-StatusPath) aus.
        - Ruft New-NextExamInstallGPO in place auf -> GPP-Task rein, Startup-Script raus.
        - Firewall-GPOs und bereits migrierte GPOs werden automatisch uebersprungen.
        Idempotent. Kein config.json noetig - migriert exakt das, was ausgerollt ist.
    .PARAMETER StartupTemplatePath
        Optional: frisches Startup-NextExam.ps1. Ohne Angabe wird je GPO das bereits
        in dessen SYSVOL liegende ps1 als Vorlage verwendet (Logik ist unveraendert).
    .PARAMETER WhatIf
        Nur anzeigen, was migriert wuerde - keine Aenderung.
    .EXAMPLE
        Invoke-NextExamGpoMigration -DomainFQDN schule.intern -WhatIf
        Invoke-NextExamGpoMigration -DomainFQDN schule.intern | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [string]$NameFilter = 'HU-NEXT-EXAM-*',
        [string]$StartupTemplatePath,
        [switch]$WhatIf
    )
    Test-GPOModule
    $gpoParams = @{ All = $true; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $all = @(Get-GPO @gpoParams | Where-Object { $_.DisplayName -like $NameFilter })

    $report = foreach ($g in $all) {
        $entry = [ordered]@{ Name=$g.DisplayName; Action='skip'; Role=$null; Detail='' }
        try {
            $sysvol = Get-SysvolPath -GPO $g -DomainFQDN $DomainFQDN -Server $Server
        } catch { $entry.Action='error'; $entry.Detail="SYSVOL: $($_.Exception.Message)"; [PSCustomObject]$entry; continue }

        $scriptsDir = Join-Path $sysvol 'Machine\Scripts'
        $psIni      = Join-Path $scriptsDir 'psscripts.ini'
        $existPs1   = Join-Path $scriptsDir 'Startup\Startup-NextExam.ps1'

        if (-not (Test-Path $psIni)) { $entry.Detail='keine psscripts.ini (z.B. Firewall-GPO)'; [PSCustomObject]$entry; continue }
        $ini = try { [System.IO.File]::ReadAllText($psIni, [System.Text.Encoding]::Unicode) } catch { '' }

        if ($ini -notmatch '(?im)^\s*0CmdLine\s*=\s*Startup-NextExam\.ps1') {
            $entry.Detail = if ($ini -match 'Startup-NextExam') { 'bereits migriert' } else { 'kein NextExam-Startup-Script' }
            [PSCustomObject]$entry; continue
        }

        $params = ''
        if ($ini -match '(?im)^\s*0Parameters\s*=\s*(.+)$') { $params = $Matches[1].Trim() }
        $role   = if ($params -match '-Role\s+(\w+)')            { $Matches[1] } else { $null }
        $share  = if ($params -match '-SharePath\s+"([^"]+)"')   { $Matches[1] } else { $null }
        $status = if ($params -match '-StatusPath\s+"([^"]+)"')  { $Matches[1] } else { $null }
        if (-not $role -or -not $share) { $entry.Action='error'; $entry.Detail="Parameter nicht lesbar: '$params'"; [PSCustomObject]$entry; continue }
        $entry.Role = $role

        $tpl = if ($StartupTemplatePath) { $StartupTemplatePath } else { $existPs1 }
        if (-not (Test-Path $tpl)) { $entry.Action='error'; $entry.Detail="Template/PS1 fehlt: $tpl"; [PSCustomObject]$entry; continue }

        if ($WhatIf) {
            $entry.Action='would-migrate'; $entry.Detail="Role=$role Share=$share Status=$status"
            [PSCustomObject]$entry; continue
        }
        try {
            $res = New-NextExamInstallGPO -GPOName $g.DisplayName -Role $role -DomainFQDN $DomainFQDN -Server $Server `
                        -SharePath $share -StatusPath $status -StartupTemplatePath $tpl
            $entry.Action='migrated'; $entry.Detail="v$($res.VersionNew) Task=$($res.TaskName)"
        } catch { $entry.Action='error'; $entry.Detail=$_.Exception.Message }
        [PSCustomObject]$entry
    }
    return @($report)
}

# Funktionen exportieren
if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Test-GPOModule, Test-GPOCreateRights, `
                                  New-NextExamFWGPO, Get-NextExamFWGPOStatus, `
                                  New-NextExamInstallGPO, Get-NextExamInstallGPOStatus, `
                                  New-NextExamTaskXml, Invoke-NextExamGpoMigration, `
                                  Set-NextExamGPOLink, Remove-NextExamInstallGPO, `
                                  Set-GPOMachineExtension, Update-GPOMachineVersion, `
                                  Test-GPOHealth, Test-SysvolDFSConsistency
}
