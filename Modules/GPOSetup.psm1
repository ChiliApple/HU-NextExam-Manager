#Requires -Version 5.1
<#
.SYNOPSIS
    Management von Next-Exam Install-GPOs.
.DESCRIPTION
    Erstellt GPOs mit CMD-Wrapper -> PowerShell Startup-Script das via msiexec die MSI installiert.
    Registriert das Script ueber scripts.ini (CMD/Batch) + psscripts.ini (PS-Referenz).
    WICHTIG: Startup-NextExam.ps1 wird als reines ASCII mit CRLF geschrieben,
             da PowerShell 5.1 BOM-lose Dateien als ANSI interpretiert.
.NOTES
    v2.1 - Fix: Version-Inkrement korrigiert (Computer-Side = Low 16-Bit, +1 statt +0x10000)
         - Fix: Get-SysvolPath mit robustem DC-Fallback (DFS -> Server -> DC-Enumeration)
         - Fix: gpt.ini CRLF-safe + Readback-Verify
         - Fix: Set-GPOMachineExtension idempotent (erhalt bestehender Extensions)
         - Neu: Test-GPOHealth Diagnose-Funktion
         - Neu: Test-SysvolDFSConsistency
    v2.0 - Umstellung auf CMD-Wrapper-Ansatz (scripts.ini + .cmd -> .ps1)
         - Fix: psscripts.ini muss Script-Eintraege + [Shutdown]-Sektion enthalten
         - Fix: scripts.ini muss abschliessendes CRLF haben
         - Fix: Shutdown-Ordner muss existieren
#>

# Scripts CSE GUIDs (verifiziert gegen MS-GPOL/MS-GPSCR)
# {42B5FAAE-...} = Scripts CSE (Client-Side Processing)
# {40B6664F-...} = Scripts MMC Snap-In (Tool/Editor GUID)
# Quelle: https://learn.microsoft.com/en-us/archive/blogs/mempson/group-policy-client-side-extension-list
$script:ScriptsCseGuid  = '{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'
$script:ScriptsToolGuid = '{40B6664F-4972-11D1-A7CA-0000F87571E3}'

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
# FIX: Get-SysvolPath - Robustes DC-Fallback
# ============================================================
function Get-SysvolPath {
    <#
    .SYNOPSIS
        Ermittelt einen ERREICHBAREN SYSVOL-Pfad fuer eine GPO.
    .DESCRIPTION
        Problem: \\domain.fqdn\SYSVOL (DFS-Namespace) ist von Member-Servern
        oft nicht erreichbar (DFS-Referral schlaegt fehl, NTLM-Problem).
        \\DC-Hostname\SYSVOL (direkt) funktioniert immer.

        Fallback-Kette:
        0. Session-Cache (schnell bei wiederholten Aufrufen)
        1. \\DomainFQDN\SYSVOL (DFS) - testet tatsaechlichen Policy-Pfad
        2. \\Server\SYSVOL (uebergebener DC) - testet Policy-Pfad
        3. Alle DCs aus AD enumrieren und durchprobieren
        4. Fehler werfen wenn nichts erreichbar

        Quelle: https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dfsn-access-failures
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [switch]$SkipDFS
    )

    $gpoGuid = "{$($GPO.Id)}"
    $policyRelPath = "$DomainFQDN\Policies\$gpoGuid"

    # Helper: Teste ob der konkrete Policy-Ordner erreichbar ist
    function Test-PolicyPath {
        param([string]$SysvolRoot)
        $fullPath = "\\$SysvolRoot\SYSVOL\$policyRelPath"
        try {
            if (Test-Path $fullPath -ErrorAction Stop) { return $fullPath }
        } catch {}
        return $null
    }

    # 0. Session-Cache
    $cachedDC = $script:SysvolDCCache[$DomainFQDN]
    if ($cachedDC) {
        $result = Test-PolicyPath -SysvolRoot $cachedDC
        if ($result) {
            Write-Verbose "Get-SysvolPath: Cache-Hit DC=$cachedDC"
            return $result
        }
        $script:SysvolDCCache.Remove($DomainFQDN)
        Write-Verbose "Get-SysvolPath: Cache-Miss, DC=$cachedDC nicht mehr erreichbar"
    }

    # 1. DFS-Pfad
    if (-not $SkipDFS) {
        $result = Test-PolicyPath -SysvolRoot $DomainFQDN
        if ($result) {
            Write-Verbose "Get-SysvolPath: DFS-Pfad OK (\\$DomainFQDN)"
            return $result
        }
        Write-Verbose "Get-SysvolPath: DFS-Pfad NICHT erreichbar (\\$DomainFQDN\SYSVOL)"
    }

    # 2. Uebergebener Server
    if ($Server) {
        $result = Test-PolicyPath -SysvolRoot $Server
        if ($result) {
            $script:SysvolDCCache[$DomainFQDN] = $Server
            Write-Verbose "Get-SysvolPath: DC-Fallback OK (\\$Server)"
            return $result
        }
        Write-Verbose "Get-SysvolPath: Server=$Server NICHT erreichbar"
    }

    # 3. Alle DCs enumrieren
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
        } catch {
            Write-Warning "Get-SysvolPath: DC-Enumeration fehlgeschlagen: $_"
        }
    }

    foreach ($dc in $allDCs) {
        $result = Test-PolicyPath -SysvolRoot $dc
        if ($result) {
            $script:SysvolDCCache[$DomainFQDN] = $dc
            Write-Verbose "Get-SysvolPath: DC-Enumeration OK (\\$dc)"
            return $result
        }
    }

    # 4. Nichts erreichbar
    $tried = @($DomainFQDN)
    if ($Server) { $tried += $Server }
    $tried += $allDCs
    throw ("SYSVOL NICHT erreichbar fuer GPO $gpoGuid!`n" +
           "Getestete Pfade:`n" +
           ($tried | ForEach-Object { "  \\$_\SYSVOL\$policyRelPath" } | Out-String) +
           "Moegliche Ursachen:`n" +
           "  - DFS-Referral schlaegt fehl (Member-Server, kein DC)`n" +
           "  - Firewall blockiert SMB (TCP 445) zum DC`n" +
           "  - SYSVOL-Share nicht freigegeben`n" +
           "  - DNS-Aufloesung fehlerhaft")
}

# ============================================================
# FIX: Update-GPOMachineVersion - Korrektes Version-Inkrement
# ============================================================
function Update-GPOMachineVersion {
    <#
    .SYNOPSIS
        Inkrementiert die Computer-Side-Version der GPO (AD + gpt.ini synchron).
    .DESCRIPTION
        GPO versionNumber Encoding (MS-GPOL):
          Version = (UserVersion << 16) | ComputerVersion
          - UserVersion     = High 16 Bit = (Version -band 0xFFFF0000) -shr 16
          - ComputerVersion = Low 16 Bit  = Version -band 0x0000FFFF

        Fuer Machine-Settings (Startup-Scripts) wird NUR der Computer-Counter
        inkrementiert: +1 (NICHT +0x10000!).

        BUG in v2.0: $current + 0x10000 inkrementierte USER-Version.
        => Client sieht: "Computer-Version unveraendert" => Scripts-CSE nicht aufgerufen
        => GPO erscheint als "Nicht angewendet (Leer)".

        Quellen:
        - https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/edc9596f-3353-4f1b-a8b4-f4388c1fffce
        - https://learn.microsoft.com/en-us/archive/blogs/grouppolicy/understanding-the-domain-based-gpo-version-number-gpmc-script-included
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )

    # 1. AD lesen
    $dn = Get-GPODN -GPO $GPO -DomainFQDN $DomainFQDN
    $adParams = @{ Identity = $dn; Properties = @('versionNumber','gPCMachineExtensionNames') }
    if ($Server) { $adParams.Server = $Server }
    $adObj = Get-ADObject @adParams

    $current = [int64]$adObj.versionNumber
    $currentUserVer     = ($current -band 0xFFFF0000) -shr 16
    $currentComputerVer = $current -band 0x0000FFFF

    # 2. Computer-Version inkrementieren (Low 16-Bit: +1)
    $newComputerVer = $currentComputerVer + 1
    $newVer = ($currentUserVer -shl 16) -bor $newComputerVer

    Write-Verbose ("Version: {0} => {1} (User={2}, Computer={3}=>{4})" -f
                    $current, $newVer, $currentUserVer, $currentComputerVer, $newComputerVer)

    # 3. AD schreiben: versionNumber + gPCMachineExtensionNames
    $cseList = "[{0}{1}]" -f $script:ScriptsCseGuid, $script:ScriptsToolGuid
    $setParams = @{
        Identity = $dn
        Replace  = @{
            versionNumber            = [int]$newVer
            gPCMachineExtensionNames = $cseList
        }
    }
    if ($Server) { $setParams.Server = $Server }
    Set-ADObject @setParams

    # 4. gpt.ini in SYSVOL aktualisieren
    $sysvol = Get-SysvolPath -GPO $GPO -DomainFQDN $DomainFQDN -Server $Server
    $gptIni = Join-Path $sysvol 'GPT.INI'

    if (Test-Path $gptIni) {
        $raw = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)

        # Version ersetzen (CRLF-safe)
        $raw = [regex]::Replace($raw, '(?im)^Version=\d+\r?$', "Version=$newVer")

        # gPCMachineExtensionNames eintragen/aktualisieren
        if ($raw -match '(?im)^gPCMachineExtensionNames=') {
            $raw = [regex]::Replace($raw, '(?im)^gPCMachineExtensionNames=.*\r?$', "gPCMachineExtensionNames=$cseList")
        } else {
            $raw = [regex]::Replace($raw, '(?im)(^Version=\d+)\r?\n', "`$1`r`ngPCMachineExtensionNames=$cseList`r`n")
        }

        # CRLF normalisieren
        $raw = $raw -replace "`r`n", "`n"
        $raw = $raw -replace "`n", "`r`n"
        if (-not $raw.EndsWith("`r`n")) { $raw += "`r`n" }

        [System.IO.File]::WriteAllText($gptIni, $raw, [System.Text.Encoding]::Default)
    } else {
        $content = "[General]`r`nVersion=$newVer`r`ngPCMachineExtensionNames=$cseList`r`ndisplayName=Neues Gruppenrichtlinienobjekt`r`n"
        [System.IO.File]::WriteAllText($gptIni, $content, [System.Text.Encoding]::Default)
    }

    # 5. Readback-Verify gpt.ini
    if (Test-Path $gptIni) {
        $verify = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)
        if ($verify -notmatch "Version=$newVer") {
            Write-Warning "gpt.ini Verify FEHLGESCHLAGEN: Version=$newVer nicht gefunden in $gptIni"
        }
        if ($verify -notmatch 'gPCMachineExtensionNames=') {
            Write-Warning "gpt.ini Verify FEHLGESCHLAGEN: gPCMachineExtensionNames fehlt in $gptIni"
        }
    } else {
        Write-Warning "gpt.ini existiert nicht nach Schreiben: $gptIni (DFS-Replication Delay?)"
    }

    # 6. AD Readback-Verify
    $verifyAD = Get-ADObject @adParams
    if ([int64]$verifyAD.versionNumber -ne $newVer) {
        Write-Warning "AD Verify FEHLGESCHLAGEN: versionNumber=$($verifyAD.versionNumber), erwartet=$newVer"
    }

    return $newVer
}

# ============================================================
# FIX: Set-GPOMachineExtension - Idempotent
# ============================================================
function Set-GPOMachineExtension {
    <#
    .SYNOPSIS
        Setzt gPCMachineExtensionNames so dass Scripts-CSE ausgefuehrt wird.
        Idempotent: bestehende Extension-GUIDs bleiben erhalten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    $dn = Get-GPODN -GPO $GPO -DomainFQDN $DomainFQDN

    $readParams = @{ Identity = $dn; Properties = @('gPCMachineExtensionNames') }
    if ($Server) { $readParams.Server = $Server }
    $adObj = Get-ADObject @readParams

    $scriptsPair = "[{0}{1}]" -f $script:ScriptsCseGuid, $script:ScriptsToolGuid
    $currentVal = [string]$adObj.gPCMachineExtensionNames

    if ($currentVal -and $currentVal.Contains($script:ScriptsCseGuid)) {
        Write-Verbose "gPCMachineExtensionNames enthaelt bereits Scripts-CSE"
        return
    }

    if ($currentVal) {
        $newVal = $currentVal + $scriptsPair
    } else {
        $newVal = $scriptsPair
    }

    $setParams = @{ Identity = $dn; Replace = @{ gPCMachineExtensionNames = $newVal } }
    if ($Server) { $setParams.Server = $Server }
    Set-ADObject @setParams
    Write-Verbose "gPCMachineExtensionNames gesetzt: $newVal"
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
        $targetSids = @(
            "$domSid-512",   # Domain Admins
            "$domSid-519",   # Enterprise Admins
            "$domSid-520",   # Group Policy Creator Owners
            'S-1-5-32-544'   # Builtin\Administrators
        )
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $tokenSids = @($id.Groups | ForEach-Object { $_.Value })
        $tokenSids += $id.User.Value
        $match = @()
        foreach ($sid in $targetSids) {
            if ($tokenSids -contains $sid) {
                try { $name = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value }
                catch { $name = $sid }
                $match += $name
            }
        }
        return [PSCustomObject]@{ HasRights = ($match.Count -gt 0); Groups = $match; User = $id.Name }
    } catch {
        return [PSCustomObject]@{ HasRights = $null; Reason = "Check fehlgeschlagen: $_" }
    }
}

# ============================================================
# Helper: Write-SysvolFile (unveraendert)
# ============================================================
function Write-SysvolFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Data,
        [switch]$Hidden
    )
    if (Test-Path $Path) {
        try { (Get-Item $Path -Force).Attributes = 'Normal' } catch {}
        try { Remove-Item -Path $Path -Force -ErrorAction Stop } catch {
            try { & takeown.exe /F $Path 2>&1 | Out-Null } catch {}
            try { & icacls.exe $Path /grant "$($env:USERDOMAIN)\$($env:USERNAME):F" /C 2>&1 | Out-Null } catch {}
            Remove-Item -Path $Path -Force -ErrorAction Stop
        }
    }
    [System.IO.File]::WriteAllBytes($Path, $Data)
    if ($Hidden) {
        (Get-Item $Path).Attributes = 'Hidden,Archive'
    }
}

function New-NextExamInstallGPO {
    <#
    .SYNOPSIS
        Erstellt (oder aktualisiert) Install-GPO fuer eine Rolle.
    .DESCRIPTION
        Verwendet CMD-Wrapper-Ansatz:
        - scripts.ini registriert Startup-NextExam.cmd (Batch)
        - CMD ruft powershell.exe -ExecutionPolicy Bypass -File Startup-NextExam.ps1
        - psscripts.ini enthaelt PS-Referenz + [Shutdown]-Sektion (beide noetig fuer CSE)
        - Startup-NextExam.ps1 wird als reines ASCII mit CRLF geschrieben
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$StartupTemplatePath,
        [string]$StatusPath
    )
    Test-GPOModule

    # 1. GPO erstellen wenn nicht vorhanden
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue
    $created = $false
    if (-not $gpo) {
        $newParams = @{ Name = $GPOName; Domain = $DomainFQDN
                        Comment = "HU-NextExam-Manager: $Role Install via Startup-Script (CMD-Wrapper)" }
        if ($Server) { $newParams.Server = $Server }
        $gpo = New-GPO @newParams
        $created = $true
    }

    function _step([string]$Label, [scriptblock]$Block) {
        try { & $Block } catch {
            throw "[Step: $Label] $($_.Exception.Message)"
        }
    }

    # 2. SYSVOL-Struktur anlegen
    _step 'SYSVOL-Dirs' {
        $script:sysvol = Get-SysvolPath -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server
        $script:scriptsDir  = Join-Path $script:sysvol 'Machine\Scripts'
        $script:startupDir  = Join-Path $script:scriptsDir 'Startup'
        $script:shutdownDir = Join-Path $script:scriptsDir 'Shutdown'
        foreach ($d in @($script:scriptsDir, $script:startupDir, $script:shutdownDir)) {
            for ($i = 1; $i -le 5; $i++) {
                if (Test-Path $d) { break }
                try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null; break } catch {}
                Start-Sleep -Milliseconds 500
            }
            if (-not (Test-Path $d)) { throw "SYSVOL-Ordner nicht erstellt: $d" }
        }
    }
    $sysvol = $script:sysvol; $scriptsDir = $script:scriptsDir
    $startupDir = $script:startupDir

    # 3. Startup-Script als reines ASCII + CRLF
    $scriptName   = 'Startup-NextExam.ps1'
    $targetScript = Join-Path $startupDir $scriptName

    _step 'Startup-PS1' {
        if (-not (Test-Path $StartupTemplatePath)) {
            throw "Startup-Template fehlt: $StartupTemplatePath"
        }
        $content = Get-Content -Path $StartupTemplatePath -Raw -Encoding UTF8
        $content = $content -replace "`r`n", "`n"
        $content = $content -replace "`n", "`r`n"
        $content = $content -replace ([char]0x00A0), ' '
        $asciiBytes = [System.Text.Encoding]::ASCII.GetBytes($content)
        Write-SysvolFile -Path $targetScript -Data $asciiBytes

        $sz = (Get-Item $targetScript).Length
        if ($sz -lt 100) {
            throw "Startup-Script verdaechtig klein ($sz bytes): $targetScript"
        }
    }

    # 4. CMD-Wrapper
    $cmdName = 'Startup-NextExam.cmd'
    $targetCmd = Join-Path $startupDir $cmdName

    _step 'CMD-Wrapper' {
        $paramLine = "-SharePath `"$SharePath`" -Role $Role"
        if ($StatusPath) { $paramLine += " -StatusPath `"$StatusPath`"" }
        $cmdContent = "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File `"%~dp0$scriptName`" $paramLine`r`n"
        $cmdBytes = [System.Text.Encoding]::Default.GetBytes($cmdContent)
        Write-SysvolFile -Path $targetCmd -Data $cmdBytes
    }

    # 5. scripts.ini (ANSI, Hidden)
    _step 'scripts.ini' {
        $iniContent = "[Startup]`r`n0CmdLine=$cmdName`r`n0Parameters=`r`n"
        $iniBytes = [System.Text.Encoding]::Default.GetBytes($iniContent)
        $iniPath = Join-Path $scriptsDir 'scripts.ini'
        Write-SysvolFile -Path $iniPath -Data $iniBytes -Hidden
    }

    # 6. psscripts.ini (UTF-16 LE mit BOM, Hidden)
    _step 'psscripts.ini' {
        $paramLine = "-SharePath `"$SharePath`" -Role $Role"
        if ($StatusPath) { $paramLine += " -StatusPath `"$StatusPath`"" }
        $psIniContent = "[Startup]`r`n0CmdLine=$scriptName`r`n0Parameters=$paramLine`r`n`r`n[Shutdown]`r`n"
        $bom = [byte[]]@(0xFF, 0xFE)
        $body = [System.Text.Encoding]::Unicode.GetBytes($psIniContent)
        $psIniPath = Join-Path $scriptsDir 'psscripts.ini'
        Write-SysvolFile -Path $psIniPath -Data ($bom + $body) -Hidden
    }

    # 7. Machine-CSE + Version updaten (v2.1: korrekt Computer-Side +1)
    Set-GPOMachineExtension -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server
    $ver = Update-GPOMachineVersion -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server

    return [PSCustomObject]@{
        GPO          = $gpo
        Name         = $gpo.DisplayName
        Id           = $gpo.Id
        SysvolPath   = $sysvol
        ScriptPath   = $targetScript
        CmdWrapper   = $targetCmd
        ScriptsIni   = (Join-Path $scriptsDir 'scripts.ini')
        PsScriptsIni = (Join-Path $scriptsDir 'psscripts.ini')
        SharePath    = $SharePath
        Role         = $Role
        Created      = $created
        VersionNew   = $ver
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
        ScriptOK     = $false
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
    $psIni       = Join-Path $scriptsDir 'psscripts.ini'
    $sIni        = Join-Path $scriptsDir 'scripts.ini'
    $script      = Join-Path $startupDir 'Startup-NextExam.ps1'
    $cmd         = Join-Path $startupDir 'Startup-NextExam.cmd'

    $result.ScriptOK     = (Test-Path $script) -and ((Get-Item $script).Length -gt 100)
    $result.CmdWrapperOK = (Test-Path $cmd)
    $result.ScriptsIniOK = (Test-Path $sIni -ErrorAction SilentlyContinue) -and
                           (Test-Path $psIni -ErrorAction SilentlyContinue)

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
        $links = @($nodes | ForEach-Object { $_.SelectSingleNode('*[local-name()="SOMPath"]').InnerText })
        $result.LinkedTo = $links
    } catch {
        try {
            $xmlParams = @{ Guid = $gpo.Id; ReportType = 'Xml'; Domain = $DomainFQDN }
            if ($Server) { $xmlParams.Server = $Server }
            [xml]$rpt = Get-GPOReport @xmlParams
            $nodes = $rpt.SelectNodes('//*[local-name()="LinksTo"]')
            $links = @($nodes | ForEach-Object { $_.SelectSingleNode('*[local-name()="SOMPath"]').InnerText })
            $result.LinkedTo = $links
            if ($LinkOU) {
                $ouName = ($LinkOU -split ',')[0] -replace '^OU=',''
                $result.LinkedToThis = [bool]($links | Where-Object { $_ -like "*/$ouName" })
            }
        } catch {}
    }
    return $result
}

function New-NextExamFWGPO {
    <#
    .SYNOPSIS
        Erstellt oder aktualisiert Firewall-GPO fuer eine Rolle.
    .DESCRIPTION
        GPO-basierte FW-Rules via -PolicyStore '<DomainFQDN>\<GPOName>'.
        Idempotent: alte Rules mit Namens-Praefix werden entfernt, neue angelegt.
    #>
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
    if (-not (Get-Module -ListAvailable -Name NetSecurity)) {
        throw "NetSecurity Modul fehlt."
    }
    Import-Module NetSecurity -ErrorAction Stop

    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction SilentlyContinue
    $created = $false
    if (-not $gpo) {
        $newParams = @{ Name = $GPOName; Domain = $DomainFQDN
                        Comment = "HU-NextExam-Manager: $Role Firewall-Rules" }
        if ($Server) { $newParams.Server = $Server }
        $gpo = New-GPO @newParams
        $created = $true
    }

    $policyStore = "$DomainFQDN\$GPOName"
    $profileStr  = ($Profiles -join ',')

    try {
        $existing = Get-NetFirewallRule -PolicyStore $policyStore -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'HU-NEM-*' }
        foreach ($r in $existing) {
            Remove-NetFirewallRule -PolicyStore $policyStore -Name $r.Name -ErrorAction SilentlyContinue
        }
    } catch {}

    $created_rules = @()

    foreach ($dir in @('Inbound','Outbound')) {
        $ruleName = "HU-NEM-$Role-App-$dir"
        $rule = New-NetFirewallRule -PolicyStore $policyStore `
                    -DisplayName $ruleName -Description "HU-NextExam-Manager: $Role EXE $dir" `
                    -Direction $dir -Action Allow -Program $ExePath `
                    -Profile $profileStr -Enabled True
        $created_rules += $ruleName
    }

    if ($EnableTCPPort -and $TCPPort -gt 0) {
        foreach ($dir in @('Inbound','Outbound')) {
            $ruleName = "HU-NEM-$Role-TCP-$dir"
            if ($dir -eq 'Inbound') {
                $null = New-NetFirewallRule -PolicyStore $policyStore `
                    -DisplayName $ruleName -Direction Inbound -Action Allow `
                    -Protocol TCP -LocalPort $TCPPort -Profile $profileStr -Enabled True
            } else {
                $null = New-NetFirewallRule -PolicyStore $policyStore `
                    -DisplayName $ruleName -Direction Outbound -Action Allow `
                    -Protocol TCP -RemotePort $TCPPort -Profile $profileStr -Enabled True
            }
            $created_rules += $ruleName
        }
    }

    if ($EnableUDPPort -and $UDPPorts) {
        $ports = $UDPPorts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($dir in @('Inbound','Outbound')) {
            $ruleName = "HU-NEM-$Role-UDP-$dir"
            if ($dir -eq 'Inbound') {
                $null = New-NetFirewallRule -PolicyStore $policyStore `
                    -DisplayName $ruleName -Direction Inbound -Action Allow `
                    -Protocol UDP -LocalPort $ports -Profile $profileStr -Enabled True
            } else {
                $null = New-NetFirewallRule -PolicyStore $policyStore `
                    -DisplayName $ruleName -Direction Outbound -Action Allow `
                    -Protocol UDP -RemotePort $ports -Profile $profileStr -Enabled True
            }
            $created_rules += $ruleName
        }
    }

    # v2.1: Korrekte Computer-Version +1
    $ver = Update-GPOMachineVersion -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server

    return [PSCustomObject]@{
        GPO          = $gpo
        Name         = $gpo.DisplayName
        Id           = $gpo.Id
        Role         = $Role
        Created      = $created
        Rules        = $created_rules
        VersionNew   = $ver
    }
}

function Get-NextExamFWGPOStatus {
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
        RuleCount    = 0
        LinkedTo     = @()
        LinkedToThis = $false
    }
    if (-not $gpo) { return $result }
    $result.Exists = $true
    $result.Id     = $gpo.Id

    try {
        $policyStore = "$DomainFQDN\$GPOName"
        $rules = @(Get-NetFirewallRule -PolicyStore $policyStore -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like 'HU-NEM-*' })
        $result.RuleCount = $rules.Count
    } catch {}

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
        $links = @($nodes | ForEach-Object { $_.SelectSingleNode('*[local-name()="SOMPath"]').InnerText })
        $result.LinkedTo = $links
    } catch {}
    return $result
}

function Set-NextExamGPOLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server,
        [Parameter(Mandatory)][string]$OUDistinguishedName
    )
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -ErrorAction Stop

    $linkParams = @{ Name = $GPOName; Target = $OUDistinguishedName
                     Domain = $DomainFQDN; LinkEnabled = 'Yes' }
    if ($Server) { $linkParams.Server = $Server }
    try {
        New-GPLink @linkParams -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -match 'already linked|bereits.*verkn|already\s+has\s+a\s+link') {
            # OK - schon verknuepft
        } else { throw }
    }
}

function Remove-NextExamInstallGPO {
    <#
    .SYNOPSIS
        Loescht eine GPO. Idempotent - "nicht gefunden" ist OK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    Test-GPOModule
    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN; Confirm = $false }
    if ($Server) { $gpoParams.Server = $Server }
    try {
        Remove-GPO @gpoParams -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match 'nicht gefunden|not found|gpoDisplayName') {
            return $false
        }
        throw
    }
}

# ============================================================
# NEU: Test-GPOHealth - Diagnose
# ============================================================
function Test-GPOHealth {
    <#
    .SYNOPSIS
        Diagnostiziert GPO-Probleme (SYSVOL, Version, CSE, Scripts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GPOName,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    Test-GPOModule

    $result = [ordered]@{
        GPOName = $GPOName; Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        RunningOn = $env:COMPUTERNAME; IsDC = $false; Checks = [ordered]@{}; Errors = @()
    }
    try { $result.IsDC = ((Get-CimInstance Win32_ComputerSystem -EA Stop).DomainRole -ge 4) } catch {}

    $gpoParams = @{ Name = $GPOName; Domain = $DomainFQDN }
    if ($Server) { $gpoParams.Server = $Server }
    $gpo = Get-GPO @gpoParams -EA SilentlyContinue
    if (-not $gpo) { $result.Errors += "GPO nicht gefunden"; return [PSCustomObject]$result }
    $result.Checks['GPO_Id'] = $gpo.Id.ToString()

    # SYSVOL
    $result.Checks['SYSVOL_DFS'] = (Test-Path "\\$DomainFQDN\SYSVOL\$DomainFQDN\Policies\{$($gpo.Id)}" -EA SilentlyContinue)
    if ($Server) { $result.Checks['SYSVOL_Direct'] = (Test-Path "\\$Server\SYSVOL\$DomainFQDN\Policies\{$($gpo.Id)}" -EA SilentlyContinue) }

    try {
        $sysvol = Get-SysvolPath -GPO $gpo -DomainFQDN $DomainFQDN -Server $Server
        $result.Checks['SYSVOL_Resolved'] = $sysvol
    } catch { $result.Errors += "SYSVOL: $_"; return [PSCustomObject]$result }

    # gpt.ini
    $gptIni = Join-Path $sysvol 'GPT.INI'
    $result.Checks['gptini_Exists'] = (Test-Path $gptIni)
    if (Test-Path $gptIni) {
        $txt = [System.IO.File]::ReadAllText($gptIni, [System.Text.Encoding]::Default)
        if ($txt -match 'Version=(\d+)') {
            $v = [int64]$Matches[1]
            $result.Checks['gptini_Version'] = $v
            $result.Checks['gptini_ComputerVer'] = $v -band 0xFFFF
        }
        $result.Checks['gptini_HasCSE'] = ($txt -match 'gPCMachineExtensionNames=')
    }

    # AD
    $dn = Get-GPODN -GPO $gpo -DomainFQDN $DomainFQDN
    $adP = @{ Identity = $dn; Properties = @('versionNumber','gPCMachineExtensionNames') }
    if ($Server) { $adP.Server = $Server }
    try {
        $ad = Get-ADObject @adP
        $adV = [int64]$ad.versionNumber
        $result.Checks['AD_Version'] = $adV
        $result.Checks['AD_ComputerVer'] = $adV -band 0xFFFF
        $result.Checks['AD_HasScriptsCSE'] = ([string]$ad.gPCMachineExtensionNames).Contains($script:ScriptsCseGuid)
        if ($result.Checks.ContainsKey('gptini_Version')) {
            $result.Checks['VersionSync'] = ($adV -eq $result.Checks['gptini_Version'])
        }
    } catch { $result.Errors += "AD: $_" }

    # Scripts
    $sd = Join-Path $sysvol 'Machine\Scripts'
    $result.Checks['scripts_ini']   = (Test-Path (Join-Path $sd 'scripts.ini') -EA SilentlyContinue)
    $result.Checks['psscripts_ini'] = (Test-Path (Join-Path $sd 'psscripts.ini') -EA SilentlyContinue)
    $ps1 = Join-Path $sd 'Startup\Startup-NextExam.ps1'
    $result.Checks['StartupPS1'] = (Test-Path $ps1)
    if (Test-Path $ps1) { $result.Checks['StartupPS1_Size'] = (Get-Item $ps1).Length }

    return [PSCustomObject]$result
}

# ============================================================
# NEU: Test-SysvolDFSConsistency
# ============================================================
function Test-SysvolDFSConsistency {
    <#
    .SYNOPSIS
        Prueft ob GPO-Daten auf allen DCs konsistent sind (DFS-Replication Check).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GPO,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    $gpoGuid = "{$($GPO.Id)}"
    $relPath = "$DomainFQDN\Policies\$gpoGuid"

    $adP = @{ Filter = { Enabled -eq $true }; Properties = @('HostName') }
    if ($Server) { $adP.Server = $Server }
    $allDCs = @(Get-ADDomainController @adP | Select-Object -ExpandProperty HostName)

    $results = foreach ($dc in $allDCs) {
        $e = [ordered]@{ DC = $dc; Reachable = $false; Version = $null; HasScripts = $false }
        $p = "\\$dc\SYSVOL\$relPath"
        if (Test-Path $p -EA SilentlyContinue) {
            $e.Reachable = $true
            $g = Join-Path $p 'GPT.INI'
            if (Test-Path $g) {
                $t = [System.IO.File]::ReadAllText($g, [System.Text.Encoding]::Default)
                if ($t -match 'Version=(\d+)') { $e.Version = [int64]$Matches[1] }
            }
            $e.HasScripts = (Test-Path (Join-Path $p 'Machine\Scripts\scripts.ini') -EA SilentlyContinue)
        }
        [PSCustomObject]$e
    }

    $vers = @($results | Where-Object { $_.Reachable -and $null -ne $_.Version } | Select-Object -ExpandProperty Version -Unique)
    [PSCustomObject]@{ GPO = $gpoGuid; Consistent = ($vers.Count -le 1); DCResults = $results; UniqueVersions = $vers }
}

# Funktionen exportieren
if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Test-GPOModule, Test-GPOCreateRights, `
                                  New-NextExamFWGPO, `
                                  Get-NextExamFWGPOStatus, `
                                  New-NextExamInstallGPO, `
                                  Get-NextExamInstallGPOStatus, `
                                  Set-NextExamGPOLink, `
                                  Remove-NextExamInstallGPO, `
                                  Set-GPOMachineExtension, `
                                  Update-GPOMachineVersion, `
                                  Test-GPOHealth, `
                                  Test-SysvolDFSConsistency
}
