#Requires -Version 5.1
<#
.SYNOPSIS
    HU-NextExam-Manager-Release signieren / freigeben (Herausgeber) - Kommandozeilen-Variante von
    HU-NextExam-Manager: Rechtsklick auf "Update" > "Release signieren" bzw. "Release freigeben".
.DESCRIPTION
    1. Laedt HU-NextExam-Manager-files.sha256 des Releases (SHA256 aller Dateien, erstellt von den automatischen Tests auf GitHub).
    2. Signiert sie mit dem Signatur-Zertifikat aus "Eigene Zertifikate" (CurrentUser\My, mit privatem Schluessel)
       -> HU-NextExam-Manager-files.sha256.p7s (PKCS#7/CMS, abgetrennte Signatur) und prueft die Signatur.
    3. Mit -UploadToken: haengt die Signatur an das Release. Ohne: Datei liegt in -OutDir und wird auf GitHub
       (Releases > Version > Bearbeiten) von Hand angehaengt.
    -Publish: gibt das Release frei (Vorab-Release -> Stabil, Latest) - verweigert ohne gueltige Signatur.

    Der private Schluessel verlaesst den PC nie. Die Pruefsummen-Datei selbst wird nicht veraendert.
.PARAMETER Version
    Release-Version, z.B. 3.2.0. Ohne Angabe (nur mit -UploadToken): alle Releases mit Pruefsumme, die noch nicht signiert sind.
.PARAMETER UploadToken
    GitHub-Token mit Schreibrecht (Fine-grained PAT, Repository HU-NextExam-Manager, Contents: Read and write).
.NOTES
    Signieren:  powershell -ExecutionPolicy Bypass -File Tools\Sign-NextExamRelease.ps1 -Version 3.2.0 -UploadToken <token>
    Nur Datei:  powershell -ExecutionPolicy Bypass -File Tools\Sign-NextExamRelease.ps1 -Version 3.2.0 -OutDir $env:USERPROFILE\Downloads
    Freigeben:  powershell -ExecutionPolicy Bypass -File Tools\Sign-NextExamRelease.ps1 -Version 3.2.0 -UploadToken <token> -Publish
    Zielmaschine: PC des Herausgebers (nb001, als der Benutzer, in dessen Zertifikatsspeicher das Signatur-Zertifikat liegt).
#>
param(
    [string]$Version = '',
    [string]$Thumbprint = '',
    [string]$Owner = '',
    [string]$Repo = '',
    [string]$OutDir = '',
    [string]$UploadToken = '',
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules\Update.psm1') -Force -DisableNameChecking
$cfg = Get-HMUpdateConfig $root
if (-not $Owner) { $Owner = $cfg.Owner }
if (-not $Repo) { $Repo = $cfg.Repo }
if (-not $Thumbprint) { $Thumbprint = $cfg.SignerThumbprint }
if (-not $Thumbprint) { $Thumbprint = Get-HMDefaultSigner $Owner $Repo }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

if ($Publish) {
    if (-not $Version -or -not $UploadToken) { throw '-Publish braucht -Version und -UploadToken.' }
    $rel = @(Get-HMReleases $Owner $Repo $UploadToken | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
    if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
    Write-Host (Publish-HMRelease $Owner $Repo $rel.Tag $UploadToken $Thumbprint) -ForegroundColor Green
    exit 0
}

$cert = Get-HMSigningCert $Thumbprint
if (-not $cert) { throw "Signatur-Zertifikat '$Thumbprint' mit privatem Schluessel ist auf diesem PC nicht vorhanden (CurrentUser\My von $env:USERNAME) oder abgelaufen." }
Write-Host "Zertifikat: $($cert.Subject)  ($($cert.Thumbprint), gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy')))" -ForegroundColor Cyan

if ($UploadToken) {
    $tags = @()
    if ($Version) {
        $rel = @(Get-HMReleases $Owner $Repo $UploadToken | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
        if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
        $tags = @($rel.Tag)
    }
    $res = @(Invoke-HMReleaseSigning $Owner $Repo $cert.Thumbprint $UploadToken $tags)
    if (-not $res.Count) { Write-Host 'Nichts zu signieren - alle Releases mit Pruefsumme sind signiert.' -ForegroundColor Green }
    foreach ($x in $res) { Write-Host "$($x.Tag): $($x.Text)" -ForegroundColor $(if ($x.Ok) { 'Green' } else { 'Red' }) }
    if (@($res | Where-Object { -not $_.Ok }).Count) { exit 1 }
    exit 0
}

# ohne Token: nur Datei erstellen
if (-not $Version) { throw 'Ohne -UploadToken bitte -Version angeben.' }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'HU-NextExam-Signatur' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$rel = @(Get-HMReleases $Owner $Repo '' | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
if (-not $rel.ManifestUrl) { throw "Release $($rel.Tag) hat noch keine Pruefsummen-Datei (automatische Tests noch nicht fertig oder fehlgeschlagen)." }
$man = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi ''
$sig = New-HMManifestSignature $man $cert
$why = Test-HMManifestSignature $man $sig $cert.Thumbprint
if ($why) { throw "Signatur-Pruefung fehlgeschlagen: $why" }
$sigFile = Join-Path $OutDir 'HU-NextExam-Manager-files.sha256.p7s'
[System.IO.File]::WriteAllBytes($sigFile, $sig)
Write-Host "Signatur erstellt und geprueft: $sigFile" -ForegroundColor Green
Write-Host "Jetzt auf GitHub: Releases > $($rel.Tag) > Bearbeiten > die Datei anhaengen > Speichern." -ForegroundColor Yellow
