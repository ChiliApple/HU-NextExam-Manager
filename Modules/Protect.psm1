#Requires -Version 5.1
<#
.SYNOPSIS
    Schutz des Programmordners: nur Administratoren und SYSTEM duerfen dort schreiben.
.DESCRIPTION
    Der HU-NextExam-Manager laeuft mit Administratorrechten, der Auto-Pull als geplante Aufgabe sogar als SYSTEM - jeweils
    direkt aus dem Programmordner. Duerfen Standardbenutzer dort Dateien anlegen (z.B. C:\Tools erbt von C:\ das Recht
    "Dateien erstellen" fuer Benutzer), koennten sie Code oder eine update.json einschleusen, die dann mit diesen Rechten laeuft.
    Darum wird der Programmordner bei jedem Start geprueft und bei Bedarf abgesichert
    (Vorlage: HUMig Functions\Core-Protect.ps1, Protect-HMDataDir):
      - Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen/Ausfuehren
      - Inhalt: Besitzer Administratoren, nur geerbte Rechte; Verknuepfungen (Junction/Symlink) werden entfernt (nur der Link)
    Nicht angefasst werden Ordner auf Netzlaufwerken (UNC), in Benutzerprofilen (dort haben andere Benutzer ohnehin keinen
    Zugriff) und Laufwerkswurzeln.
.NOTES
    Zielmaschine: der Server/PC, auf dem der HU-NextExam-Manager liegt (als Administrator oder SYSTEM).
#>

$script:NEMOkSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')   # SYSTEM, Administratoren, TrustedInstaller
$script:NEMBadRights = ([long][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership') -bor 0x50000000L   # + GENERIC_WRITE, GENERIC_ALL

function Test-NEMIsAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

# Grund, warum ein Ordner nicht abgesichert wird ('' = absichern)
function Get-NEMAppDirSkipReason([string]$Root) {
    if (-not "$Root".Trim()) { return 'Pfad unbekannt' }
    if ($Root -like '\\*') { return 'Netzlaufwerk (UNC) - Rechte bitte am Server pruefen' }
    if (-not [System.IO.Path]::IsPathRooted($Root)) { return 'kein absoluter Pfad' }
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full.Length -le 3) { return 'Laufwerkswurzel' }
    try {
        $pd = [Environment]::ExpandEnvironmentVariables("$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop).ProfilesDirectory)").TrimEnd('\')
        if ($pd -and ($full -like "$pd\*")) { return 'Benutzerprofil (andere Benutzer haben dort keinen Zugriff)' }
    } catch { }
    try {
        $drv = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($full))
        if ($drv.DriveType -ne [System.IO.DriveType]::Fixed) { return "Laufwerkstyp $($drv.DriveType)" }
    } catch { }
    return ''
}

# Ist der Ordner sicher? Liefert eine Liste der Probleme (leer = sicher).
#   Wurzel: Besitzer SYSTEM/Administratoren, kein anderer Eintrag (auch geerbt) mit Schreib-/Loesch-/Rechte-Recht
#   Inhalt: Besitzer SYSTEM/Administratoren, keine eigenen Eintraege mit solchen Rechten, keine Verknuepfungen
function Get-NEMAppDirIssues([string]$Root) {
    $issues = New-Object System.Collections.Generic.List[string]
    $rp = [System.IO.FileAttributes]::ReparsePoint
    $check = {
        param([string]$Path, [bool]$IsRoot)
        $a = [System.IO.File]::GetAttributes($Path)
        $isDir = (($a -band [System.IO.FileAttributes]::Directory) -ne 0)
        if (($a -band $rp) -ne 0) {
            $lt = "$((Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).LinkType)"
            if ($lt -in @('Junction', 'SymbolicLink')) { $issues.Add("Verknuepfung: $Path"); return $false }
        }
        $acl = if ($isDir) { [System.IO.Directory]::GetAccessControl($Path) } else { [System.IO.File]::GetAccessControl($Path) }
        $own = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($script:NEMOkSids -notcontains $own) { $issues.Add("Besitzer $(ConvertTo-NEMAccountName $own): $Path") }
        foreach ($r in $acl.GetAccessRules($true, $IsRoot, [System.Security.Principal.SecurityIdentifier])) {
            $sid = $r.IdentityReference.Value
            if ("$($r.AccessControlType)" -ne 'Allow' -or $script:NEMOkSids -contains $sid -or $sid -eq 'S-1-3-0') { continue }   # S-1-3-0 = ERSTELLER-BESITZER
            if (([long]$r.FileSystemRights -band $script:NEMBadRights) -ne 0) { $issues.Add("Schreibrecht fuer $(ConvertTo-NEMAccountName $sid): $Path") }
        }
        return $isDir
    }
    if (-not [System.IO.Directory]::Exists($Root)) { $issues.Add("Ordner fehlt: $Root"); return , $issues.ToArray() }
    try {
        [void](& $check $Root $true)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count) {
            $d = $stack.Pop()
            foreach ($e in [System.IO.Directory]::GetFileSystemEntries($d)) {
                if (& $check $e $false) {
                    $a = [System.IO.File]::GetAttributes($e)
                    if (($a -band $rp) -eq 0) { $stack.Push($e) }
                }
            }
        }
    } catch { $issues.Add("nicht pruefbar: $($_.Exception.Message)") }
    return , $issues.ToArray()
}

function ConvertTo-NEMAccountName([string]$Sid) {
    try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid }
}

# Programmordner absichern. Rueckgabe: '' = war schon sicher, sonst Text. Wirft, wenn es nicht gelingt.
function Protect-NEMAppDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rp = [System.IO.FileAttributes]::ReparsePoint
    if (-not [System.IO.Directory]::Exists($Root)) { throw "Ordner fehlt: $Root" }
    if (([System.IO.File]::GetAttributes($Root) -band $rp) -ne 0) { throw "$Root ist eine Verknuepfung - bitte den echten Programmordner verwenden" }
    $before = @(Get-NEMAppDirIssues $Root)
    if (-not $before.Count) { return '' }
    $admSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    # Besitz uebernehmen: icacls setzt den Besitzer auch ohne Zugriffsrecht (Wiederherstellungsrecht der Administratoren)
    $takeOver = {
        param([string]$Path)
        $o = & icacls.exe "$Path" /setowner '*S-1-5-32-544' /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { $o2 = & takeown.exe /F "$Path" /A 2>&1; if ($LASTEXITCODE -ne 0) { throw "Besitz von $Path nicht uebernehmbar: $o $o2" } }
    }
    # 1. Wurzel: Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen
    & $takeOver $Root
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner($admSid)
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($x[0])), [System.Security.AccessControl.FileSystemRights]$x[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    [System.IO.Directory]::SetAccessControl($Root, $sec)
    # 2. Inhalt: Verknuepfungen entfernen (nur den Link), alles andere: Besitzer Administratoren, nur geerbte Rechte.
    #    Eigener Durchlauf statt icacls /T: folgt keinen Verknuepfungen. Zweimal, falls waehrenddessen etwas angelegt wurde.
    for ($pass = 1; $pass -le 2; $pass++) {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count) {
            $d = $stack.Pop()
            $entries = $null
            try { $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
            catch { & $takeOver $d; $null = & icacls.exe "$d" /reset /C /Q 2>&1; $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
            foreach ($e in $entries) {
                $a = [System.IO.File]::GetAttributes($e)
                $isDir = (($a -band [System.IO.FileAttributes]::Directory) -ne 0)
                if (($a -band $rp) -ne 0) {
                    $lt = "$((Get-Item -LiteralPath $e -Force -ErrorAction SilentlyContinue).LinkType)"
                    if ($lt -in @('Junction', 'SymbolicLink')) {
                        if ($isDir) { [System.IO.Directory]::Delete($e, $false) } else { [System.IO.File]::Delete($e) }
                        continue
                    }
                    if ($isDir) { continue }
                }
                if ($pass -eq 1) {
                    & $takeOver $e
                    $o = & icacls.exe "$e" /reset /C /Q 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Rechte von $e nicht zuruecksetzbar: $o" }
                }
                if ($isDir) { $stack.Push($e) }
            }
        }
    }
    $after = @(Get-NEMAppDirIssues $Root)
    if ($after.Count) { throw "$Root konnte nicht abgesichert werden: $($after[0])" }
    $shown = @($before | Select-Object -First 5)
    return "$Root abgesichert (nur Administratoren/SYSTEM duerfen schreiben). Vorher: $($shown -join '; ')$(if ($before.Count -gt 5) { " (+$($before.Count - 5) weitere)" })"
}

# Pruefen + absichern, fuer den Start des Tools. Rueckgabe: Status Skipped / Ok / Fixed / Unsafe / Failed, Text
function Invoke-NEMAppDirProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $why = Get-NEMAppDirSkipReason $Root
    if ($why) { return [pscustomobject]@{ Status = 'Skipped'; Text = "Programmordner nicht abgesichert: $why" } }
    if (-not (Test-NEMIsAdmin)) {
        $iss = @(Get-NEMAppDirIssues $Root)
        if ($iss.Count) { return [pscustomobject]@{ Status = 'Unsafe'; Text = "Programmordner ist nicht geschuetzt ($($iss[0])) - ohne Administratorrechte nicht absicherbar" } }
        return [pscustomobject]@{ Status = 'Ok'; Text = 'Programmordner geschuetzt' }
    }
    try {
        $t = Protect-NEMAppDir -Root $Root
        if ($t) { return [pscustomobject]@{ Status = 'Fixed'; Text = $t } }
        return [pscustomobject]@{ Status = 'Ok'; Text = 'Programmordner geschuetzt' }
    } catch { return [pscustomobject]@{ Status = 'Failed'; Text = "Programmordner nicht absicherbar: $($_.Exception.Message)" } }
}

# Versionsnummer des Tools (einzige Quelle: Config\version.json)
function Get-NEMToolVersion([string]$Root) {
    try {
        $v = "$((Get-Content -LiteralPath (Join-Path $Root 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)".Trim()
        if ($v -match '^\d+(\.\d+){1,3}$') { return $v }
    } catch { }
    return '0.0.0'
}

# Name der Einzelinstanz-Sperre je Programmordner (Global: gilt auch zwischen Sitzungen, z.B. Auto-Pull als SYSTEM)
function Get-NEMMutexName([string]$Root, [string]$Kind = 'App') {
    $p = [System.IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($p))[0..7] | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    return "Global\HU-NextExam-Manager_$($Kind)_$h"
}

Export-ModuleMember -Function Test-NEMIsAdmin, Get-NEMAppDirSkipReason, Get-NEMAppDirIssues, Protect-NEMAppDir, Invoke-NEMAppDirProtection, Get-NEMToolVersion, Get-NEMMutexName
