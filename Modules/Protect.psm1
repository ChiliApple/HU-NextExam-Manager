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
# Dateien mit Geheimnissen: nur SYSTEM + Administratoren duerfen sie lesen (eigene, nicht geerbte Rechte)
$script:NEMSecretFiles = @('Config\github-token.dat')
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
        $pub = "$env:PUBLIC".TrimEnd('\'); if (-not $pub) { $pub = "$pd\Public" }
        # Oeffentliches Profil (C:\Users\Public): dort duerfen alle Benutzer schreiben -> absichern
        if ($pd -and ($full -like "$pd\*") -and -not ($full -eq $pub -or $full -like "$pub\*")) { return 'Benutzerprofil (andere Benutzer haben dort keinen Zugriff)' }
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
        if ((($a -band $rp) -ne 0) -or -not $isDir) {
            $lt = "$((Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).LinkType)"
            if ($lt -in @('Junction', 'SymbolicLink', 'HardLink')) { $issues.Add("Verknuepfung ($lt): $Path"); return $false }
        }
        $acl = if ($isDir) { [System.IO.Directory]::GetAccessControl($Path) } else { [System.IO.File]::GetAccessControl($Path) }
        $own = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($script:NEMOkSids -notcontains $own) { $issues.Add("Besitzer $(ConvertTo-NEMAccountName $own): $Path") }
        if (-not $isDir -and (Test-NEMSecretFile $Root $Path)) {
            # Geheimnis: niemand ausser SYSTEM/Administratoren darf lesen (auch nicht geerbt)
            foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                if ("$($r.AccessControlType)" -eq 'Allow' -and $script:NEMOkSids -notcontains $r.IdentityReference.Value) { $issues.Add("lesbar fuer $(ConvertTo-NEMAccountName $r.IdentityReference.Value): $Path"); break }
            }
        }
        foreach ($r in $acl.GetAccessRules($true, $IsRoot, [System.Security.Principal.SecurityIdentifier])) {
            $sid = $r.IdentityReference.Value
            if ("$($r.AccessControlType)" -ne 'Allow' -or $script:NEMOkSids -contains $sid -or $sid -eq 'S-1-3-0') { continue }   # S-1-3-0 = ERSTELLER-BESITZER
            if (([long]$r.FileSystemRights -band $script:NEMBadRights) -ne 0) { $issues.Add("Schreibrecht fuer $(ConvertTo-NEMAccountName $sid): $Path") }
        }
        return $isDir
    }
    if (-not [System.IO.Directory]::Exists($Root)) { $issues.Add("Ordner fehlt: $Root"); return $issues.ToArray() }
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
    return $issues.ToArray()
}

# Gehoert $Path zu den Geheimnis-Dateien des Programmordners $Root?
function Test-NEMSecretFile([string]$Root, [string]$Path) {
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $f = [System.IO.Path]::GetFullPath($Path)
    foreach ($s in $script:NEMSecretFiles) { if ([string]::Equals($f, (Join-Path $r $s), [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

# Geheimnis-Datei: Besitzer Administratoren, Vererbung aus, nur SYSTEM + Administratoren
function Set-NEMSecretFileAcl([string]$Path) {
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), [System.Security.AccessControl.FileSystemRights]::FullControl, 'Allow')))
    }
    [System.IO.File]::SetAccessControl($Path, $sec)
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
    # Verknuepfung? Junction/SymbolicLink/HardLink -> nur den Link/Namen entfernen, nie das Ziel anfassen
    $isLink = {
        param([string]$Path, [System.IO.FileAttributes]$Attr)
        $isDir = (($Attr -band [System.IO.FileAttributes]::Directory) -ne 0)
        if ((($Attr -band $rp) -eq 0) -and $isDir) { return $false }
        $lt = "$((Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).LinkType)"
        return ($lt -in @('Junction', 'SymbolicLink', 'HardLink'))
    }
    # 1. ZUERST alle Verknuepfungen entfernen - bevor irgendwo Rechte gesetzt werden (die Wurzel-ACL wird an
    #    vorhandene Unterobjekte weitergegeben). Eigener Durchlauf statt icacls /T: folgt keinen Verknuepfungen.
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count) {
        $d = $stack.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
        catch { & $takeOver $d; $null = & icacls.exe "$d" /grant '*S-1-5-32-544:(F)' /C /Q 2>&1; $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
        foreach ($e in $entries) {
            $a = [System.IO.File]::GetAttributes($e)
            $isDir = (($a -band [System.IO.FileAttributes]::Directory) -ne 0)
            if (& $isLink $e $a) {
                if ($isDir) { [System.IO.Directory]::Delete($e, $false) } else { [System.IO.File]::Delete($e) }
                continue
            }
            if ($isDir -and (($a -band $rp) -eq 0)) { $stack.Push($e) }
        }
    }
    # 2. Wurzel: Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen
    & $takeOver $Root
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner($admSid)
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($x[0])), [System.Security.AccessControl.FileSystemRights]$x[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    [System.IO.Directory]::SetAccessControl($Root, $sec)
    # 3. Inhalt: Besitzer Administratoren, nur geerbte Rechte. Zweimal, falls waehrenddessen etwas angelegt wurde
    #    (Verknuepfungen, die inzwischen entstanden sind, werden dabei ebenfalls entfernt).
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
                if (& $isLink $e $a) {
                    if ($isDir) { [System.IO.Directory]::Delete($e, $false) } else { [System.IO.File]::Delete($e) }
                    continue
                }
                if ((($a -band $rp) -ne 0) -and $isDir) { continue }   # andere Reparse-Ordner nicht durchlaufen
                if ($pass -eq 1) {
                    & $takeOver $e
                    if (-not $isDir -and (Test-NEMSecretFile $Root $e)) { Set-NEMSecretFileAcl $e }   # Geheimnis: nicht lesbar fuer Benutzer
                    else {
                        $o = & icacls.exe "$e" /reset /C /Q 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "Rechte von $e nicht zuruecksetzbar: $o" }
                    }
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

# Daten des Tools liegen ab v3.4.0 in Config\ (frueher direkt im Programmordner)
$script:NEMDataFiles = @('config.json', 'update.json', 'installed.json')

# Pfad einer Datendatei: Config\<Name>; nur wenn dort keine liegt, aber noch die alte im Programmordner, diese
function Get-NEMDataFile([string]$Root, [string]$Name) {
    $new = Join-Path (Join-Path $Root 'Config') $Name
    $old = Join-Path $Root $Name
    if (-not (Test-Path -LiteralPath $new -PathType Leaf) -and (Test-Path -LiteralPath $old -PathType Leaf)) { return $old }
    return $new
}

# Alte Datendateien aus dem Programmordner nach Config\ verschieben. Liegen beide vor (z.B. nach einem Wechsel auf eine
# aeltere Version und zurueck), gilt die zuletzt geaenderte; die andere bleibt als <Name>.alt im Programmordner.
# Rueckgabe: Liste der Meldungen (leer = nichts zu tun)
function Move-NEMDataFiles([string]$Root) {
    $msgs = New-Object System.Collections.Generic.List[string]
    $dir = Join-Path $Root 'Config'
    foreach ($n in $script:NEMDataFiles) {
        $old = Join-Path $Root $n
        $new = Join-Path $dir $n
        if (-not (Test-Path -LiteralPath $old -PathType Leaf)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            if (Test-Path -LiteralPath $new -PathType Leaf) {
                if ((Get-Item -LiteralPath $old -Force).LastWriteTimeUtc -gt (Get-Item -LiteralPath $new -Force).LastWriteTimeUtc) {
                    Move-Item -LiteralPath $new -Destination "$old.alt" -Force -ErrorAction Stop
                    Move-Item -LiteralPath $old -Destination $new -Force -ErrorAction Stop
                    $msgs.Add("$n nach Config\ verschoben (neuer als die dortige, diese liegt jetzt als $n.alt im Programmordner)")
                } else {
                    Move-Item -LiteralPath $old -Destination "$old.alt" -Force -ErrorAction Stop
                    $msgs.Add("$n im Programmordner ist aelter als Config\$n - umbenannt in $n.alt")
                }
            } else {
                Move-Item -LiteralPath $old -Destination $new -ErrorAction Stop
                $msgs.Add("$n nach Config\ verschoben")
            }
        } catch { $msgs.Add("$n nicht nach Config\ verschiebbar: $($_.Exception.Message)") }
    }
    return $msgs.ToArray()
}

# --- GitHub-Token (optional, nur fuer mehr API-Abrufe/h): Config\github-token.dat
#     DPAPI (LocalMachine: auch der Auto-Pull als SYSTEM kann ihn lesen), Datei nur fuer SYSTEM + Administratoren lesbar
$script:NEMTokenEntropy = [System.Text.Encoding]::UTF8.GetBytes('HU-NextExam-Manager GitHubToken')
function Get-NEMGitHubToken([string]$Root) {
    $f = Join-Path $Root 'Config\github-token.dat'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $b = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($f), $script:NEMTokenEntropy, 'LocalMachine')
        return ([System.Text.Encoding]::UTF8.GetString($b)).Trim()
    } catch { return '' }
}
# Token speichern ('' = loeschen). Braucht Administratorrechte.
function Set-NEMGitHubToken([string]$Root, [string]$Token) {
    $dir = Join-Path $Root 'Config'
    $f = Join-Path $dir 'github-token.dat'
    $Token = "$Token".Trim()
    if (-not $Token) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }; return }
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Token), $script:NEMTokenEntropy, 'LocalMachine')
    # erst leer anlegen und absichern, dann den Inhalt schreiben (nie lesbar fuer Benutzer)
    $tmp = "$f.tmp"
    [System.IO.File]::WriteAllBytes($tmp, [byte[]]@())
    Set-NEMSecretFileAcl $tmp
    [System.IO.File]::WriteAllBytes($tmp, $enc)
    Move-Item -LiteralPath $tmp -Destination $f -Force -ErrorAction Stop
    Set-NEMSecretFileAcl $f
}
# Token aus config.json (ToolSettings.GitHubToken, dort lesbar fuer alle Benutzer) in die geschuetzte Datei uebernehmen.
# Rueckgabe: $true = Config geaendert (Feld geleert) -> speichern
function Move-NEMGitHubTokenToStore([string]$Root, $Config) {
    try { $t = "$($Config.ToolSettings.GitHubToken)".Trim() } catch { return $false }
    if (-not $t -or -not (Test-NEMIsAdmin)) { return $false }
    Set-NEMGitHubToken -Root $Root -Token $t
    $Config.ToolSettings.GitHubToken = ''
    return $true
}

# Name der Einzelinstanz-Sperre je Programmordner (Global: gilt auch zwischen Sitzungen, z.B. Auto-Pull als SYSTEM)
function Get-NEMMutexName([string]$Root, [string]$Kind = 'App') {
    $p = [System.IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($p))[0..7] | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    return "Global\HU-NextExam-Manager_$($Kind)_$h"
}

Export-ModuleMember -Function Test-NEMIsAdmin, Get-NEMAppDirSkipReason, Get-NEMAppDirIssues, Protect-NEMAppDir, Invoke-NEMAppDirProtection, Get-NEMToolVersion, Get-NEMMutexName, `
    Test-NEMSecretFile, Set-NEMSecretFileAcl, Get-NEMDataFile, Move-NEMDataFiles, Get-NEMGitHubToken, Set-NEMGitHubToken, Move-NEMGitHubTokenToStore
