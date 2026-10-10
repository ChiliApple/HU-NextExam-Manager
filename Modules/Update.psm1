#Requires -Version 5.1
<#
.SYNOPSIS
    Tool-Update fuer HU-NextExam-Manager: Releases, Kanal Stabil/Test, Pruefsumme (SHA256), Signatur (PKCS#7) und Release signieren/freigeben (Herausgeber).
.DESCRIPTION
    Der Bereich HMUpdateLib ist identisch in Pull.ps1 enthalten (Pull.ps1 muss auch allein laufen - Erstinstallation).
    Die automatischen Tests auf GitHub pruefen, dass beide Fassungen gleich sind.
    Vorlage: HUMig v2.0.56 (Functions\Core-Update.ps1).
#>
#region HMUpdateLib
# Gemeinsame Update-Funktionen - identisch in Pull.ps1 und Modules\Update.psm1 (die automatischen Tests pruefen das)
# Vorlage: HUMig v2.0.99 (Functions\Core-Update.ps1) - gleiche Funktionsnamen, gleiches Signatur-Zertifikat
$script:HMManifestName  = 'HU-NextExam-Manager-files.sha256'
$script:HMSignatureName = 'HU-NextExam-Manager-files.sha256.p7s'
$script:HMUserAgent     = 'HU-NextExam-Manager'
# Offizielle Update-Quelle und Fingerabdruck des Zertifikats, mit dem ihre Releases signiert werden (oeffentlich, kein Geheimnis)
$script:HMDefaultOwner  = 'ChiliApple'
$script:HMDefaultRepo   = 'HU-NextExam-Manager'
$script:HMDefaultSigner = '1B669AE240DA1A91043C4576763D9F8E0BF762FA'

function Get-HMDefaultSigner([string]$Owner, [string]$Repo) {
    if ($Owner -eq $script:HMDefaultOwner -and $Repo -eq $script:HMDefaultRepo) { return $script:HMDefaultSigner }
    return ''
}
# Update-Einstellungen aus update.json im Tool-Ordner (fehlt die Datei: offizielle Quelle, Kanal Stabil, nur signierte Releases)
#   Signaturpflicht gilt, sobald ein Fingerabdruck bekannt ist (offizielle Quelle: eingebaut) - ausser "AllowUnsigned": true.
#   Mit Signaturpflicht gibt es keinen Branch-Modus (ein Branch-Stand ist nicht signiert).
#   Alte Felder (z.B. "RequireSignature": false) werden bewusst ignoriert.
function Get-HMUpdateConfig([string]$ConfigDir) {
    $c = [ordered]@{ Owner = $script:HMDefaultOwner; Repo = $script:HMDefaultRepo; Branch = 'main'; UseBranch = $false; Channel = 'Stable'; AllowUnsigned = $false; SignerThumbprint = ''; DefaultSigner = $false; RequireSignature = $false }
    $f = Join-Path $ConfigDir 'update.json'
    if (Test-Path -LiteralPath $f) {
        try {
            $u = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('Owner', 'Repo', 'Branch', 'SignerThumbprint')) { if ($u.PSObject.Properties[$k] -and "$($u.$k)".Trim()) { $c[$k] = "$($u.$k)".Trim() } }
            if ($u.PSObject.Properties['Channel'] -and "$($u.Channel)" -match '^(Stable|Test)$') { $c.Channel = "$($u.Channel)" }
            if ($u.PSObject.Properties['UseBranch']) { $c.UseBranch = ($u.UseBranch -eq $true) }
            if ($u.PSObject.Properties['AllowUnsigned']) { $c.AllowUnsigned = ($u.AllowUnsigned -eq $true) }
        } catch { }
    }
    $c.SignerThumbprint = ("$($c.SignerThumbprint)" -replace '[^0-9A-Fa-f]', '').ToUpper()
    if (-not $c.SignerThumbprint) {
        $d = Get-HMDefaultSigner $c.Owner $c.Repo
        if ($d) { $c.SignerThumbprint = $d; $c.DefaultSigner = $true }
    }
    $c.RequireSignature = ([bool]$c.SignerThumbprint -and -not $c.AllowUnsigned)
    if ($c.RequireSignature) { $c.UseBranch = $false }
    return [pscustomobject]$c
}
function ConvertTo-HMVersion([string]$Tag) {
    $v = "$Tag".Trim() -replace '^[vV]', ''
    $o = $null
    if ($v -match '^\d+(\.\d+){1,3}$' -and [Version]::TryParse($v, [ref]$o)) { return $o }
    return $null
}
# GitHub-Releases -> Liste (neueste zuerst): Version, Tag, Prerelease (= Kanal Test), Datum, Notizen, Pruefsummen-/Signatur-Datei
function ConvertTo-HMReleaseList($Raw) {
    $out = @()
    foreach ($r in @($Raw)) {
        if (-not $r -or $r.draft -eq $true) { continue }
        $ver = ConvertTo-HMVersion "$($r.tag_name)"
        if (-not $ver) { continue }
        $assets = @($r.assets | Where-Object { $_ })
        $man = @($assets | Where-Object { "$($_.name)" -eq $script:HMManifestName })[0]
        $sig = @($assets | Where-Object { "$($_.name)" -eq $script:HMSignatureName })[0]
        $d = ''
        try { $d = ([datetime]$r.published_at).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } catch { $d = "$($r.published_at)" }
        $out += [pscustomobject]@{
            Version = $ver; Tag = "$($r.tag_name)"; Prerelease = ($r.prerelease -eq $true); Date = $d; Notes = "$($r.body)"
            ManifestUrl = $(if ($man) { "$($man.browser_download_url)" } else { '' }); ManifestApi = $(if ($man) { "$($man.url)" } else { '' })
            SignatureUrl = $(if ($sig) { "$($sig.browser_download_url)" } else { '' }); SignatureApi = $(if ($sig) { "$($sig.url)" } else { '' })
        }
    }
    return @($out | Sort-Object Version -Descending)
}
function Get-HMReleases([string]$Owner, [string]$Repo, [string]$Token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $h = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = $script:HMUserAgent }
    if ($Token) { $h.Authorization = "token $Token" }
    # GitHub liefert die Liste mit "Cache-Control: max-age=60" - Proxys/Zwischenspeicher wuerden z.B. eine gerade
    # angehaengte Signatur bis zu 1 Minute nicht zeigen. Darum: no-cache + eindeutige Adresse je Abfrage
    $h['Cache-Control'] = 'no-cache'
    $raw = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100&nocache=$([DateTime]::UtcNow.Ticks)" -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    return @(ConvertTo-HMReleaseList $raw)
}
# Kanal Stabil = nur freigegebene Releases, Test = auch Vorab-Releases; jeweils die hoechste Version
# -SignedOnly: nur Releases mit Pruefsummen- UND Signatur-Datei (bei Signaturpflicht)
function Select-HMRelease($Releases, [string]$Channel, [switch]$SignedOnly) {
    $l = @($Releases | Where-Object { $_ -and $_.Version })
    if ($Channel -ne 'Test') { $l = @($l | Where-Object { -not $_.Prerelease }) }
    if ($SignedOnly) { $l = @($l | Where-Object { $_.ManifestUrl -and $_.SignatureUrl }) }
    return (@($l | Sort-Object Version -Descending) | Select-Object -First 1)
}
# Release-Datei (Pruefsummen/Signatur) als Bytes laden - mit Token ueber die API (private Repos).
# Ausweichweg: liefert der Download-Link von github.com einen Fehler (z.B. 503), wird dieselbe Datei ueber die API geladen
# (gleicher Inhalt; die Echtheit sichert ohnehin die Signatur/Pruefsumme)
function Get-HMReleaseAsset([string]$Url, [string]$ApiUrl, [string]$Token) {
    $tries = @()
    if ($Token -and $ApiUrl) { $tries += , @($ApiUrl, @{ Accept = 'application/octet-stream'; 'User-Agent' = $script:HMUserAgent; Authorization = "token $Token" }) }
    if ($Url) { $tries += , @($Url, @{ 'User-Agent' = $script:HMUserAgent }) }
    if ($ApiUrl) { $tries += , @($ApiUrl, @{ Accept = 'application/octet-stream'; 'User-Agent' = $script:HMUserAgent }) }
    $last = $null
    foreach ($t in $tries) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest $t[0] -Headers $t[1] -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -ErrorAction Stop
            return ,([System.IO.File]::ReadAllBytes($tmp))
        } catch { $last = $_ }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($last) { throw $last }
    throw 'keine Download-Adresse'
}
# Pruefsummen-Datei (sha256sum-Format: "<hash>  <pfad>") -> Hashtable Pfad -> Hash (klein)
function ConvertFrom-HMManifest([string]$Text) {
    $m = @{}
    foreach ($ln in ("$Text" -split "`r?`n")) {
        if ($ln -match '^([0-9a-fA-F]{64}) [ \*](.+?)\s*$') { $m[$Matches[2]] = $Matches[1].ToLower() }
    }
    return $m
}
function Get-HMFileSha256([string]$Path) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return (-join ($s.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') })) } finally { $fs.Dispose(); $s.Dispose() }
}
# Signatur (PKCS#7/CMS, abgetrennt) der Pruefsummen-Datei pruefen. Rueckgabe: '' = gueltig, sonst Grund.
# Geprueft werden die Signatur selbst und der Fingerabdruck des Zertifikats (fest eingestellt) - keine Online-Sperrlistenpruefung.
function Test-HMManifestSignature([byte[]]$Manifest, [byte[]]$Signature, [string]$Thumbprint) {
    $want = ("$Thumbprint" -replace '[^0-9A-Fa-f]', '').ToUpper()
    if (-not $want) { return 'kein Fingerabdruck (Thumbprint) des Signatur-Zertifikats eingestellt' }
    if (-not $Signature -or -not $Signature.Length) { return 'keine Signatur-Datei im Release' }
    try {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$Manifest)
        $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
        $cms.Decode($Signature)
        $cms.CheckSignature($true)
        $tps = @(foreach ($si in $cms.SignerInfos) { if ($si.Certificate) { "$($si.Certificate.Thumbprint)".ToUpper() } })
        if (-not $tps.Count) { return 'Signatur ohne Zertifikat' }
        if ($tps -notcontains $want) { return "signiert mit einem anderen Zertifikat ($($tps -join ', '))" }
        return ''
    } catch { return "Signatur ungueltig: $($_.Exception.Message)" }
}
#endregion HMUpdateLib

# ============================================================================
# Release signieren / freigeben - nur auf dem PC des Herausgebers (dort liegt der private Schluessel des Signatur-Zertifikats).
# Auf allen anderen PCs gibt es den Schluessel nicht - dort wird nur geprueft.
# ============================================================================
function Get-HMSigningCert([string]$Thumbprint) {
    $tp = ("$Thumbprint" -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($tp.Length -ne 40) { return $null }
    $st = $null
    try {
        $st = New-Object System.Security.Cryptography.X509Certificates.X509Store -ArgumentList 'My', 'CurrentUser'
        $st.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        foreach ($c in @($st.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $tp, $false))) {
            if ($c.HasPrivateKey -and $c.NotAfter -gt (Get-Date)) { return $c }
        }
    } catch { } finally { if ($st) { $st.Close() } }
    return $null
}
# Abgetrennte PKCS#7/CMS-Signatur der Pruefsummen-Datei (silent = keine Rueckfrage-UI, laeuft im Hintergrund)
function New-HMManifestSignature([byte[]]$Manifest, $Cert) {
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$Manifest)
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
    $signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner -ArgumentList $Cert
    $signer.IncludeOption = [System.Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $cms.ComputeSignature($signer, $true)
    return , ([byte[]]$cms.Encode())
}
# Signatur-Datei an ein Release haengen (eine vorhandene wird ersetzt) - Token mit Schreibrecht noetig
function Publish-HMReleaseSignature([string]$Owner, [string]$Repo, [string]$Tag, [byte[]]$Signature, [string]$Token) {
    $h = @{ Authorization = "token $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = $script:HMUserAgent }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    foreach ($a in @($rel.assets | Where-Object { "$($_.name)" -eq $script:HMSignatureName })) {
        Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($a.id)" -Method Delete -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop | Out-Null
    }
    Invoke-RestMethod "https://uploads.github.com/repos/$Owner/$Repo/releases/$($rel.id)/assets?name=$($script:HMSignatureName)" -Method Post -Headers $h -ContentType 'application/octet-stream' -Body $Signature -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop | Out-Null
}
# Releases signieren: ohne -Tags alle Releases mit Pruefsummen-Datei, die noch keine Signatur haben.
# Rueckgabe je Release: Tag, Ok, Text. Jede Signatur wird vor dem Hochladen geprueft.
function Invoke-HMReleaseSigning([string]$Owner, [string]$Repo, [string]$Thumbprint, [string]$Token, [string[]]$Tags = @()) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $cert = Get-HMSigningCert $Thumbprint
    if (-not $cert) { throw "Signatur-Zertifikat $Thumbprint mit privatem Schluessel ist auf diesem PC nicht vorhanden (oder abgelaufen)." }
    $list = @(Get-HMReleases $Owner $Repo $Token)
    if (@($Tags).Count) { $todo = @($list | Where-Object { @($Tags) -contains $_.Tag }) }
    else { $todo = @($list | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl }) }
    $out = @()
    foreach ($r in $todo) {
        try {
            if (-not $r.ManifestUrl) { throw 'keine Pruefsummen-Datei (automatische Tests noch nicht fertig?)' }
            $man = Get-HMReleaseAsset $r.ManifestUrl $r.ManifestApi $Token
            if (-not (ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($man))).Count) { throw 'Pruefsummen-Datei leer oder beschaedigt' }
            $sig = New-HMManifestSignature $man $cert
            $why = Test-HMManifestSignature $man $sig $cert.Thumbprint
            if ($why) { throw "Signatur-Pruefung fehlgeschlagen: $why" }
            Publish-HMReleaseSignature $Owner $Repo $r.Tag $sig $Token
            $out += [pscustomobject]@{ Tag = $r.Tag; Ok = $true; Text = 'signiert' }
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            $out += [pscustomobject]@{ Tag = $r.Tag; Ok = $false; Text = $(if ($code -in 401, 403, 404) { "kein Schreibrecht (HTTP $code) - Token pruefen" } else { "$($_.Exception.Message)" }) }
        }
    }
    return $out
}
# Release freigeben (Vorab-Release -> Stabil, "Latest"). Verweigert die Freigabe ohne gueltige Signatur.
function Publish-HMRelease([string]$Owner, [string]$Repo, [string]$Tag, [string]$Token, [string]$Thumbprint) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $h = @{ Authorization = "token $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = $script:HMUserAgent }
    $raw = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $r = @(ConvertTo-HMReleaseList @($raw))[0]
    if (-not $r) { throw "Release $Tag nicht gefunden oder ohne Versionsnummer." }
    if (-not $r.ManifestUrl) { throw "$Tag hat keine Pruefsummen-Datei - Freigabe verweigert." }
    if (-not $r.SignatureUrl) { throw "$Tag ist nicht signiert - Freigabe verweigert. Zuerst signieren." }
    $man = Get-HMReleaseAsset $r.ManifestUrl $r.ManifestApi $Token
    $sig = Get-HMReleaseAsset $r.SignatureUrl $r.SignatureApi $Token
    $why = Test-HMManifestSignature $man $sig $Thumbprint
    if ($why) { throw "$Tag - Signatur nicht gueltig ($why) - Freigabe verweigert." }
    $body = @{ prerelease = $false; make_latest = 'true' } | ConvertTo-Json
    Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/$($raw.id)" -Method Patch -Headers $h -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop | Out-Null
    return "$Tag freigegeben (Kanal Stabil, Latest)"
}

Export-ModuleMember -Function * -Variable HMManifestName, HMSignatureName, HMDefaultOwner, HMDefaultRepo, HMDefaultSigner
