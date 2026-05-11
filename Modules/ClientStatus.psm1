#Requires -Version 5.1
<#
.SYNOPSIS
    Client-Status via Share-Pattern. Clients schreiben JSON nach Install.
.NOTES
    v2.1.1 - Fix: Multi-JSON-Objekte in einer Datei (nur erstes Objekt verwenden)
    v2.1   - Fix: BOM/Encoding-robustes JSON-Parsing
           - Fix: Initialize-StatusShare setzt auch SMB-Share-Permissions
           - Fix: Atomic-Write Empfehlung fuer Startup-Script
#>

function Initialize-StatusShare {
    <#
    .SYNOPSIS
        Legt Status-Share-Ordner an + setzt NTFS-ACL UND SMB-Share-Permissions.
        Domain-Computers=Write, Admins=FullControl.
    .DESCRIPTION
        v2.1 FIX: Setzt jetzt AUCH die SMB-Share-Berechtigungen, nicht nur NTFS-ACLs.
        Ohne Share-Level-Permissions bekommen Clients E_ACCESSDENIED auch wenn
        die NTFS-ACLs korrekt sind.

        Erwartet: Der Ordner ist UNTERHALB eines bestehenden SMB-Shares
        (z.B. \\schulserver\install\NEXT-EXAM\_status).
        Falls der Share nicht existiert, wird ein neuer erstellt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DomainFQDN,
        [string]$Server
    )
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    # Domain Computers Gruppe via SID (domain-SID + RID 515) - sprachunabhaengig
    $adParams = @{ Identity = $DomainFQDN }
    if ($Server) { $adParams.Server = $Server }
    $domain = Get-ADDomain @adParams
    $computersSid = [System.Security.Principal.SecurityIdentifier]::new("$($domain.DomainSID)-515")
    $adminsSid    = [System.Security.Principal.SecurityIdentifier]::new("$($domain.DomainSID)-512")
    $systemSid    = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $ownerSid     = [System.Security.Principal.SecurityIdentifier]::new('S-1-3-4')

    # --- NTFS ACLs ---
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }

    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propag  = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    $computerRights = [System.Security.AccessControl.FileSystemRights]::Write `
                  -bor [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    [void]$acl.AddAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new($computersSid, $computerRights, $inherit, $propag, $allow))

    $adminRights = [System.Security.AccessControl.FileSystemRights]::FullControl
    [void]$acl.AddAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new($adminsSid, $adminRights, $inherit, $propag, $allow))

    $systemRights = [System.Security.AccessControl.FileSystemRights]::FullControl
    [void]$acl.AddAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $systemRights, $inherit, $propag, $allow))

    $ownerRights = [System.Security.AccessControl.FileSystemRights]::Modify
    [void]$acl.AddAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new($ownerSid, $ownerRights, $inherit, $propag, $allow))

    Set-Acl -Path $Path -AclObject $acl

    # --- SMB Share Check ---
    # Pruefen ob der Status-Ordner ueber einen bestehenden Share erreichbar ist.
    # Falls nicht: eigenen Share erstellen mit passenden Permissions.
    $shareResult = $null
    try {
        # Ist der Pfad bereits unter einem existierenden Share?
        $existingShares = Get-SmbShare -ErrorAction SilentlyContinue |
            Where-Object { $Path.StartsWith($_.Path, [System.StringComparison]::OrdinalIgnoreCase) }

        if ($existingShares) {
            # Share existiert - pruefen ob Domain Computers Change-Recht hat
            $shareName = ($existingShares | Sort-Object { $_.Path.Length } -Descending | Select-Object -First 1).Name
            $shareAccess = Get-SmbShareAccess -Name $shareName -ErrorAction SilentlyContinue
            $computersAccount = $computersSid.Translate([System.Security.Principal.NTAccount]).Value

            $hasAccess = $shareAccess | Where-Object {
                ($_.AccountName -eq 'Everyone' -or
                 $_.AccountName -eq $computersAccount -or
                 $_.AccountName -like '*Domain Computers*' -or
                 $_.AccountName -like '*Domaenencomputer*' -or
                 $_.AccountName -like '*Domaincomputer*') -and
                $_.AccessRight -in @('Change','Full')
            }

            if (-not $hasAccess) {
                # Domain Computers Change-Recht auf Share-Ebene hinzufuegen
                Grant-SmbShareAccess -Name $shareName -AccountName $computersAccount `
                    -AccessRight Change -Force -ErrorAction Stop | Out-Null
                $shareResult = "Share '$shareName': Domain Computers Change-Recht hinzugefuegt"
            } else {
                $shareResult = "Share '$shareName': Berechtigungen OK"
            }
        } else {
            # Kein Share gefunden - neuen erstellen
            $shareName = '_status$'  # Hidden Share
            # Pruefen ob Share-Name schon existiert
            $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
            if (-not $existing) {
                $computersAccount = $computersSid.Translate([System.Security.Principal.NTAccount]).Value
                $adminsAccount    = $adminsSid.Translate([System.Security.Principal.NTAccount]).Value
                New-SmbShare -Name $shareName -Path $Path `
                    -FullAccess $adminsAccount `
                    -ChangeAccess $computersAccount `
                    -Description 'HU-NextExam Status Share' `
                    -ErrorAction Stop | Out-Null
                $shareResult = "Neuer Share '$shareName' erstellt"
            } else {
                $shareResult = "Share '$shareName' existiert bereits (anderer Pfad: $($existing.Path))"
            }
        }
    } catch {
        $shareResult = "SMB-Share-Setup Warnung: $($_.Exception.Message)"
        Write-Warning $shareResult
    }

    return [PSCustomObject]@{
        Path           = $Path
        DomainComputers= $computersSid.Translate([System.Security.Principal.NTAccount]).Value
        DomainAdmins   = $adminsSid.Translate([System.Security.Principal.NTAccount]).Value
        ACLSet         = $true
        ShareResult    = $shareResult
    }
}

function Read-ClientStatus {
    <#
    .SYNOPSIS
        Liest alle *.json im Status-Ordner und gibt aggregierte Liste zurueck.
    .DESCRIPTION
        v2.1 FIX: Robust gegen BOM, Encoding-Varianten, leere Dateien,
        abgeschnittenes JSON (z.B. durch unterbrochenen Schreibvorgang).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }
    $files = Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue
    $result = foreach ($f in $files) {
        try {
            # Robust lesen: ReadAllText mit UTF8 (stripped BOM automatisch)
            $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))

            # BOM-Bytes entfernen falls vorhanden (PS 5.1 Set-Content -Encoding UTF8 schreibt BOM)
            if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) {
                $raw = $raw.Substring(1)
            }
            # Null-Bytes und unsichtbare Steuerzeichen am Anfang/Ende entfernen
            $raw = $raw.Trim([char]0x0000, [char]0xFEFF, [char]0x200B, ' ', "`t", "`r", "`n")

            if (-not $raw -or $raw.Length -lt 2) {
                throw "Leere oder zu kurze JSON-Datei ($($raw.Length) Zeichen)"
            }

            # JSON muss mit { beginnen
            if ($raw[0] -ne '{') {
                # Versuche alles vor dem ersten { abzuschneiden (z.B. BOM-Reste)
                $idx = $raw.IndexOf('{')
                if ($idx -ge 0) {
                    $raw = $raw.Substring($idx)
                } else {
                    throw "Kein JSON-Objekt gefunden"
                }
            }

            # v2.1.1 Fix: Falls mehrere JSON-Objekte konkateniert (z.B. durch alten Schreibvorgang)
            # nur das erste Top-Level-Objekt extrahieren
            $trimmed = $raw.TrimStart()
            if ($trimmed.Length -gt 1 -and $trimmed[0] -eq '{') {
                $depth = 0; $endIdx = -1
                for ($ci = 0; $ci -lt $trimmed.Length; $ci++) {
                    switch ($trimmed[$ci]) {
                        '{' { $depth++ }
                        '}' { $depth--; if ($depth -eq 0) { $endIdx = $ci; break } }
                    }
                    if ($endIdx -ge 0) { break }
                }
                if ($endIdx -ge 0 -and $endIdx -lt ($trimmed.Length - 1)) {
                    # Es gibt Content NACH dem ersten Objekt -> abschneiden
                    $remainder = $trimmed.Substring($endIdx + 1).Trim()
                    if ($remainder.Length -gt 0) {
                        $raw = $trimmed.Substring(0, $endIdx + 1)
                        Write-Warning "Multi-JSON in $($f.Name) - nur erstes Objekt verwendet"
                    }
                }
            }

            $obj = $raw | ConvertFrom-Json -ErrorAction Stop

            [PSCustomObject]@{
                ComputerName = [string]$obj.ComputerName
                Role         = [string]$obj.