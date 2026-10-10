#Requires -Version 5.1
<#
.SYNOPSIS
    MSI-Pull-Modul: Next-Exam Release abfragen, MSI downloaden, auf Shares deployen.
#>

$script:NextExamApiBase = 'https://api.github.com/repos/Bildungsportal/next-exam/releases'
$script:AssetRegex     = '^Next-Exam-(?<Role>Student|Teacher)_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Date>\d{8})_x64\.msi$'
# $script:VersionFileName obsolet - jetzt pro Rolle via Get-VersionFileName
$script:ArchiveFolder   = '_archive'

function Get-VersionFileName {
    param([Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role)
    return "version-$($Role.ToLower()).json"
}

function Get-NextExamLatestRelease {
    [CmdletBinding()]
    param(
        # Wenn gesetzt, werden auch als Pre-Release markierte Versionen beruecksichtigt.
        # Ohne expliziten Wert wird der Default aus der Config gelesen (ToolSettings.IncludePrerelease),
        # damit auch der headless Auto-Pull die Einstellung respektiert.
        [switch]$IncludePrerelease
    )

    if (-not $PSBoundParameters.ContainsKey('IncludePrerelease')) {
        try { if ([bool]$script:Config.ToolSettings.IncludePrerelease) { $IncludePrerelease = $true } } catch {}
        if (-not $IncludePrerelease) {
            try { if ([bool](Load-Config).ToolSettings.IncludePrerelease) { $IncludePrerelease = $true } } catch {}
        }
    }

    try {
        $h = @{
            Accept       = 'application/vnd.github.v3+json'
            'User-Agent' = 'HU-NextExam-Manager'
        }
        # Optional: GitHub PAT -> 5000 statt 60 API-Calls/h
        #   Config\github-token.dat (verschluesselt, nur Administratoren/SYSTEM), sonst noch config.json (nicht uebernommen)
        $tok = $null
        if (Get-Command Get-NEMGitHubToken -ErrorAction SilentlyContinue) { try { $tok = Get-NEMGitHubToken (Split-Path $PSScriptRoot -Parent) } catch {} }
        if (-not $tok -and (Get-Command Get-ConfigFilePath -ErrorAction SilentlyContinue)) {
            try { $cf = Get-ConfigFilePath; if ($cf -and (Test-Path -LiteralPath $cf)) { $tok = "$((Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json).ToolSettings.GitHubToken)".Trim() } } catch {}
        }
        if ($tok) { $h['Authorization'] = "token $tok" }

        if ($IncludePrerelease) {
            # GitHub /releases/latest ueberspringt Pre-Releases per Definition.
            # Daher /releases (neueste zuerst) abfragen und das neueste nicht-Draft-Release
            # nehmen - bevorzugt eines, das eine passende Student/Teacher-MSI enthaelt.
            $all = Invoke-RestMethod -Uri ($script:NextExamApiBase + '?per_page=30') -UseBasicParsing -Headers $h -ErrorAction Stop
            $nonDraft = @($all | Where-Object { -not $_.draft })
            $r = $nonDraft | Where-Object {
                    @($_.assets | Where-Object { $_.name -match $script:AssetRegex }).Count -gt 0
                 } | Select-Object -First 1
            if (-not $r) { $r = $nonDraft | Select-Object -First 1 }
        } else {
            # Nur stabiles Release (Verhalten wie bisher)
            $r = Invoke-RestMethod -Uri ($script:NextExamApiBase + '/latest') -UseBasicParsing -Headers $h -ErrorAction Stop
        }
    } catch {
        throw "GitHub-API-Fehler (Next-Exam Release): $_"
    }
    if (-not $r) { throw "Kein passendes Next-Exam Release gefunden (IncludePrerelease=$IncludePrerelease)." }

    $assets = @()
    foreach ($a in $r.assets) {
        if ($a.name -match $script:AssetRegex) {
            $assets += [PSCustomObject]@{
                Role        = $Matches.Role
                Version     = $Matches.Version
                BuildDate   = $Matches.Date
                FileName    = $a.name
                Size        = $a.size
                DownloadUrl = $a.browser_download_url
                # SHA256 laut GitHub ("digest": "sha256:<hex>", bei neueren Releases vorhanden)
                Sha256      = $(if ("$($a.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLower() } else { '' })
            }
        }
    }

    [PSCustomObject]@{
        TagName     = $r.tag_name
        Name        = $r.name
        PublishedAt = $r.published_at
        HtmlUrl     = $r.html_url
        Body        = $r.body
        Prerelease  = [bool]$r.prerelease
        Student     = ($assets | Where-Object { $_.Role -eq 'Student' } | Select-Object -First 1)
        Teacher     = ($assets | Where-Object { $_.Role -eq 'Teacher' } | Select-Object -First 1)
    }
}

function Read-ShareVersionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role
    )
    $fn = Get-VersionFileName -Role $Role
    $vp = Join-Path $SharePath $fn
    # Fallback: wenn neue Datei nicht da aber alte version.json existiert (Migration)
    if (-not (Test-Path $vp)) {
        $legacy = Join-Path $SharePath 'version.json'
        if (Test-Path $legacy) {
            try {
                $obj = Get-Content -Path $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
                # Nur verwenden wenn Role matcht (sonst zeigt Student-version.json bei Teacher falsche Info)
                if ($obj.Role -eq $Role) { return $obj }
            } catch {}
        }
        return $null
    }
    try {
        return (Get-Content -Path $vp -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Warning "$fn defekt: $vp ($_)"
        return $null
    }
}

function Write-ShareVersionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$BuildDate,
        [Parameter(Mandatory)][string]$FileName
    )
    if (-not (Test-Path $SharePath)) {
        New-Item -ItemType Directory -Path $SharePath -Force | Out-Null
    }
    $obj = [PSCustomObject]@{
        Role        = $Role
        Version     = $Version
        BuildDate   = $BuildDate
        FileName    = $FileName
        DeployedAt  = (Get-Date).ToString('o')
        DeployedBy  = "$env:USERDOMAIN\$env:USERNAME"
    }
    $fn = Get-VersionFileName -Role $Role
    $target = Join-Path $SharePath $fn
    $obj | ConvertTo-Json | Set-Content -Path $target -Encoding UTF8

    # Migration: alte version.json entfernen falls vorhanden und zur selben Role gehoerte
    $legacy = Join-Path $SharePath 'version.json'
    if (Test-Path $legacy) {
        try {
            $old = Get-Content -Path $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.Role -eq $Role) { Remove-Item -Path $legacy -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

function Move-OldMSIToArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$RolePrefix,  # 'Next-Exam-Student' | 'Next-Exam-Teacher'
        [int]$KeepArchiveCount = 3
    )
    $archive = Join-Path $SharePath $script:ArchiveFolder
    if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }

    # 1. Aktuelle MSIs in Archiv verschieben
    $moved = 0
    $existing = Get-ChildItem -Path $SharePath -Filter "$RolePrefix*.msi" -File -ErrorAction SilentlyContinue
    foreach ($f in $existing) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
        $newName = "{0}_{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($f.Name), $stamp, $f.Extension
        $dst = Join-Path $archive $newName
        Move-Item -Path $f.FullName -Destination $dst -Force
        $moved++
    }

    # 2. Rolling Archive: nur letzte N behalten (pro Role)
    $deleted = 0
    $archived = Get-ChildItem -Path $archive -Filter "$RolePrefix*.msi" -File -ErrorAction SilentlyContinue `
                | Sort-Object LastWriteTime -Descending
    if ($archived.Count -gt $KeepArchiveCount) {
        $toDelete = $archived | Select-Object -Skip $KeepArchiveCount
        foreach ($f in $toDelete) {
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            $deleted++
        }
    }
    return [PSCustomObject]@{ Moved = $moved; Deleted = $deleted }
}

function Invoke-MSIDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$TargetPath
    )
    $dir = Split-Path -Path $TargetPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    try {
        $tmp = "$TargetPath.part"
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop `
            -Headers @{ 'User-Agent' = 'HU-NextExam-Manager' }
        if (Test-Path $TargetPath) { Remove-Item $TargetPath -Force }
        Move-Item -Path $tmp -Destination $TargetPath -Force
        return (Get-Item $TargetPath).Length
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        throw "Download fehlgeschlagen ($Url): $_"
    }
}

# Next-Exam-MSI pruefen, bevor sie verteilt wird (laeuft auf allen Clients als SYSTEM):
#   Authenticode-Signatur gueltig, Herausgeber (O= oder CN=) wie eingestellt, optional Fingerabdruck,
#   optional SHA256 laut GitHub-Release. Wirft bei jeder Abweichung.
function Test-NextExamMsiTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedPublisher = 'Open Source Open Schools (OSOS) Austria',
        [string[]]$TrustedThumbprints = @(),
        [string]$ExpectedSha256 = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "MSI fehlt: $Path" }
    if ($ExpectedSha256) {
        $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $ExpectedSha256.ToLower()) { throw "SHA256 der MSI stimmt nicht mit dem GitHub-Release ueberein ($h statt $ExpectedSha256) - nicht verteilt" }
    }
    $sig = $null
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop } catch { throw "MSI-Signatur ungueltig (nicht pruefbar: $($_.Exception.Message)) - nicht verteilt: $([System.IO.Path]::GetFileName($Path))" }
    if (-not $sig -or "$($sig.Status)" -ne 'Valid') { throw "MSI-Signatur ungueltig ($($sig.Status): $($sig.StatusMessage)) - nicht verteilt: $([System.IO.Path]::GetFileName($Path))" }
    $cert = $sig.SignerCertificate
    $pub = "$TrustedPublisher".Trim()
    if (-not $pub) { throw 'Kein vertrauenswuerdiger Herausgeber eingestellt (ToolSettings.MsiTrustedPublisher) - nicht verteilt' }
    $names = @()
    foreach ($part in ("$($cert.Subject)" -split ',(?=\s*[A-Z]+=)')) {
        if ($part.Trim() -match '^(O|CN)=(.+)$') { $names += $Matches[2].Trim().Trim('"') }
    }
    if ($names -notcontains $pub) { throw "MSI ist von '$($cert.Subject)' signiert, erwartet wird '$pub' (ToolSettings.MsiTrustedPublisher) - nicht verteilt" }
    $tps = @($TrustedThumbprints | ForEach-Object { ("$_" -replace '[^0-9A-Fa-f]', '').ToUpper() } | Where-Object { $_ })
    if ($tps.Count -and $tps -notcontains "$($cert.Thumbprint)".ToUpper()) { throw "MSI-Zertifikat $($cert.Thumbprint) ist nicht in ToolSettings.MsiTrustedThumbprints - nicht verteilt" }
    return [pscustomobject]@{ Subject = "$($cert.Subject)"; Thumbprint = "$($cert.Thumbprint)"; NotAfter = $cert.NotAfter }
}

function Deploy-MSIToShare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceMSI,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$BuildDate,
        [Parameter(Mandatory)][string]$FileName,
        [string]$TrustedPublisher = 'Open Source Open Schools (OSOS) Austria',
        [string[]]$TrustedThumbprints = @(),
        [string]$ExpectedSha256 = ''
    )
    # 1. Herkunft pruefen - vor jeder Aenderung an der Freigabe
    $trust = Test-NextExamMsiTrust -Path $SourceMSI -TrustedPublisher $TrustedPublisher -TrustedThumbprints $TrustedThumbprints -ExpectedSha256 $ExpectedSha256
    # nur ein Verteilen je Freigabe und Rolle gleichzeitig auf diesem Rechner (Oberflaeche + Auto-Pull als SYSTEM)
    $key = ([System.IO.Path]::GetFullPath($SharePath).TrimEnd('\') + '|' + $Role).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    $mtx = New-Object System.Threading.Mutex($false, "Global\HU-NextExam-Manager_Deploy_$h")
    $own = $false
    try { $own = $mtx.WaitOne([TimeSpan]::FromMinutes(3)) } catch [System.Threading.AbandonedMutexException] { $own = $true }
    if (-not $own) { $mtx.Dispose(); throw "Freigabe $SharePath ($Role) wird gerade von einem anderen Vorgang beschrieben - spaeter erneut versuchen" }
    try {
    if (-not (Test-Path $SharePath)) {
        New-Item -ItemType Directory -Path $SharePath -Force | Out-Null
    }
    $dst = Join-Path $SharePath $FileName
    $srcHash = (Get-FileHash -LiteralPath $SourceMSI -Algorithm SHA256).Hash
    # gleiche Datei liegt schon unter dem Endnamen -> nicht neu kopieren (Clients koennten gerade davon installieren)
    $same = (Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq $srcHash)
    $archived = 0
    if (-not $same) {
        # 2. unter Hilfsnamen kopieren und pruefen - die Clients sehen nie eine halbe Datei
        $part = "$dst.part"
        Copy-Item -LiteralPath $SourceMSI -Destination $part -Force
        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $srcHash) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            throw "Kopie nach $SharePath fehlerhaft (Pruefsumme) - nichts veraendert"
        }
        # 3. erst jetzt alte MSIs dieser Rolle archivieren und die neue an ihren Platz
        $prefix = "Next-Exam-$Role"
        $archived = Move-OldMSIToArchive -SharePath $SharePath -RolePrefix $prefix
        Move-Item -LiteralPath $part -Destination $dst -Force
    }
    # 4. version-*.json zuletzt - erst dann sehen die Clients die neue Version
    Write-ShareVersionInfo -SharePath $SharePath -Role $Role -Version $Version `
                           -BuildDate $BuildDate -FileName $FileName
    } finally { try { $mtx.ReleaseMutex() } catch { }; $mtx.Dispose() }

    [PSCustomObject]@{
        Role             = $Role
        Deployed         = $dst
        ArchivedCount    = $archived
        Size             = (Get-Item $dst).Length
        Signer           = $trust.Subject
    }
}

# Funktionen exportieren (nur wenn als Modul geladen; bei dot-source automatisch sichtbar)
if ($ExecutionContext.SessionState.Module) {
Export-ModuleMember -Function Get-NextExamLatestRelease, Read-ShareVersionInfo, `
                              Write-ShareVersionInfo, Move-OldMSIToArchive, `
                              Invoke-MSIDownload, Deploy-MSIToShare, Test-NextExamMsiTrust
}
