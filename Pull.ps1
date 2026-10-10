#Requires -Version 5.1
<#
.SYNOPSIS
    HU-NextExam-Manager Pull - laedt eine Tool-Version von GitHub (Release), prueft sie (SHA256 + Signatur) und ersetzt erst dann.
.DESCRIPTION
    Zielordner:
      1. -Target angegeben                                      -> gewinnt immer
      2. Pull.ps1 liegt in einer Installation (Modules\ daneben)  -> Update an Ort und Stelle (Desktop, C:\Tools, Share ...)
      3. Pull.ps1 liegt allein (Bootstrap)                      -> $env:USERPROFILE\Desktop\HU-NextExam-Manager

    Welche Version:
      -Version 3.2.0      -> genau diese Version (auch aelter = "Vorversion")
      sonst Kanal         -> -Channel oder update.json "Channel": Stable (freigegebene Releases, Standard) / Test (auch Vorab-Releases)
      -Branch / UseBranch -> Entwicklungsstand eines Branches (ohne Pruefsumme, nur ohne Signaturpflicht)

    Sicherheit:
      - jedes Release enthaelt HU-NextExam-Manager-files.sha256 (SHA256 aller Dateien, erstellt von den automatischen Tests auf GitHub)
      - Signatur: nur Releases mit gueltiger Signatur HU-NextExam-Manager-files.sha256.p7s des Herausgeber-Zertifikats werden angenommen
        (offizielle Quelle: Fingerabdruck eingebaut; eigene Quelle: update.json "SignerThumbprint").
        Abschalten nur bewusst mit update.json "AllowUnsigned": true (Settings > Tool-Update).
      - zuerst werden ALLE Dateien geladen und geprueft, erst dann ersetzt - bei einer Abweichung bleibt alles unveraendert
      - Ersetzen mit Ruecksicherung (*.pullold) und Journal (Config\pull-journal.json): scheitert ein Schritt, wird alles
        zurueckgestellt; bricht Pull mittendrin ab (Absturz, Strom), stellt der naechste Pull-Lauf den alten Stand wieder her
      - Dateien, die es im neuen Stand nicht mehr gibt, werden entfernt - nur solche, die frueher per Pull installiert wurden
        (Liste in installed.json). Eigene Dateien und die Ordner Config\ und Logs\ bleiben immer unberuehrt.

    Lokale Daten bleiben unangetastet: Config\ (config.json, update.json, installed.json, github-token.dat), Logs\,
    HU-NextExam-Manager.exe (Starter). Alte Dateien im Tool-Ordner (vor v3.4.0) werden nach Config\ verschoben.
    GitHub-Token (optional, nur fuer mehr API-Aufrufe/h): Config\github-token.dat (das Tool uebernimmt ihn aus
    config.json > ToolSettings.GitHubToken).
.NOTES
    Manuell: powershell -ExecutionPolicy Bypass -File Pull.ps1 [-Version 3.2.0] [-Channel Test] [-NoStart]
    Nach dem Update wird das Tool automatisch gestartet (ausser -NoStart).
    Zielmaschine: der Server/PC, auf dem der HU-NextExam-Manager liegt (z.B. SCHULSERVER, C:\Tools\HU-NextExam-Manager).
#>
param(
    [string]$Target,
    [int]$WaitPid = 0,
    [switch]$NoStart,
    [string]$Owner,
    [string]$Repo,
    [string]$Branch,
    [ValidateSet('', 'Stable', 'Test')][string]$Channel = '',
    [string]$Version = '',
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

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

function Stop-HMPull([string]$Msg) {
    Write-Host "[FEHLER] $Msg" -ForegroundColor Red
    if (-not $NonInteractive) { Read-Host 'Enter zum Beenden' | Out-Null }
    exit 1
}

# --- Zielordner
if (-not $Target) {
    $here = $PSScriptRoot
    if ($here -and ((Test-Path (Join-Path $here 'Modules')) -or (Test-Path (Join-Path $here 'HU-NextExam-Manager.ps1')))) { $Target = $here; $mode = 'Update (an Ort und Stelle)' }
    else {
        # echter Desktop (auch bei OneDrive-Umleitung), nicht fest %USERPROFILE%\Desktop
        $desk = [Environment]::GetFolderPath('Desktop')
        if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
        $Target = Join-Path $desk 'HU-NextExam-Manager'; $mode = 'Erstinstallation (Desktop)'
    }
} else { $mode = 'Ziel per -Target' }
$Target = $Target.TrimEnd('\')

# --- abgebrochenes Update (Journal vorhanden): bisherige Dateien aus *.pullold zuruecksetzen
$jrDir = Join-Path $Target 'Config'
$jr = Join-Path $jrDir 'pull-journal.json'
if (Test-Path -LiteralPath $jr) {
    Write-Host '[WARN] Letztes Update wurde abgebrochen - stelle bisherige Dateien wieder her...' -ForegroundColor Yellow
    # Erst zuweisen, dann durchlaufen: PS 5.1 gibt ein JSON-Array aus ConvertFrom-Json als EIN Objekt aus
    $jl = $null
    try { $jl = Get-Content -LiteralPath $jr -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Stop-HMPull "Journal $jr nicht lesbar ($($_.Exception.Message)) - bitte *.pullold im Tool-Ordner pruefen." }
    $jbad = 0
    foreach ($jp in @($jl)) {
        if (-not "$jp") { continue }
        $jo = "$jp.pullold"
        if (Test-Path -LiteralPath $jo) {
            try { Move-Item -LiteralPath $jo -Destination "$jp" -Force -ErrorAction Stop; Write-Host "  zurueckgestellt: $jp" -ForegroundColor DarkGray }
            catch { $jbad++; Write-Host "  [WARN] $($jp): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Remove-Item -LiteralPath "$jp.pulltmp" -Force -ErrorAction SilentlyContinue
    }
    # Journal nur loeschen, wenn alles zurueckgestellt ist - sonst bleibt die Start-Sperre bestehen
    if ($jbad) { Stop-HMPull "$jbad Datei(en) konnten nicht zurueckgestellt werden (gesperrt?) - Tool schliessen und Pull erneut ausfuehren." }
    Remove-Item -LiteralPath $jr -Force -ErrorAction SilentlyContinue
}

# --- Daten liegen ab v3.4.0 in Config\ (config.json, update.json, installed.json); Verschieben erst, wenn das Tool beendet ist
$cfgDir = Join-Path $Target 'Config'
# Pfad einer Datendatei: Config\<Name>, nur falls dort keine liegt aber noch die alte im Tool-Ordner diese
function Get-PullDataFile([string]$Name) {
    $n = Join-Path $cfgDir $Name; $o = Join-Path $Target $Name
    if (-not (Test-Path -LiteralPath $n -PathType Leaf) -and (Test-Path -LiteralPath $o -PathType Leaf)) { return $o }
    return $n
}

# --- Update-Einstellungen (Config\update.json)
$cfg = Get-HMUpdateConfig (Split-Path -Parent (Get-PullDataFile 'update.json'))
if (-not $Owner) { $Owner = $cfg.Owner }
if (-not $Repo)  { $Repo = $cfg.Repo }
# andere Quelle per Parameter: eingebauter Fingerabdruck gilt nur fuer die offizielle Quelle
if ($cfg.DefaultSigner -and ($Owner -ne $cfg.Owner -or $Repo -ne $cfg.Repo)) {
    $cfg.SignerThumbprint = Get-HMDefaultSigner $Owner $Repo
    $cfg.RequireSignature = ([bool]$cfg.SignerThumbprint -and -not $cfg.AllowUnsigned)
}
if ($Branch -and $cfg.RequireSignature) { Stop-HMPull "Branch-Stand ist nicht signiert - nur moeglich, wenn 'Nur signierte Updates' ausgeschaltet ist (Settings > Tool-Update)." }
if (-not $Channel) { $Channel = $cfg.Channel }
$useBranch = [bool]$Branch -or ($cfg.UseBranch -and -not $Version)
if (-not $Branch) { $Branch = $cfg.Branch }

# --- optionaler Token (nur Rate-Limit: 5000 statt 60 API-Aufrufe/h): Umgebungsvariable (CI),
#     Config\github-token.dat (verschluesselt, nur Administratoren/SYSTEM) bzw. noch nicht uebernommen in config.json
$Token = "$env:HUNEM_GITHUB_TOKEN".Trim()
$tokFile = Join-Path $cfgDir 'github-token.dat'
if (-not $Token -and (Test-Path -LiteralPath $tokFile -PathType Leaf)) {
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $Token = [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($tokFile), [System.Text.Encoding]::UTF8.GetBytes('HU-NextExam-Manager GitHubToken'), 'LocalMachine')).Trim()
    } catch { $Token = '' }
}
$cfgPath = Get-PullDataFile 'config.json'
if (-not $Token -and (Test-Path -LiteralPath $cfgPath)) {
    try { $tc = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($tc.ToolSettings.GitHubToken) { $Token = "$($tc.ToolSettings.GitHubToken)".Trim() } } catch { }
}

Write-Host '=== HU-NextExam-Manager Pull ===' -ForegroundColor Cyan
Write-Host "Benutzer:   $env:USERNAME" -ForegroundColor Gray
Write-Host "Zielordner: $Target" -ForegroundColor Gray
Write-Host "Modus:      $mode" -ForegroundColor Gray
Write-Host "Quelle:     $Owner/$Repo$(if ($Token) { ' (mit Token)' })" -ForegroundColor Gray
Write-Host "Kanal:      $(if ($useBranch) { "Branch $Branch" } elseif ($Channel -eq 'Test') { 'Test' } else { 'Stabil' })$(if ($cfg.RequireSignature) { ', nur signierte Updates' } else { ', OHNE Signaturpflicht' })" -ForegroundColor Gray
Write-Host ''

if ($WaitPid -gt 0) {
    $proc = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "Warte bis HU-NextExam-Manager (PID $WaitPid) beendet ist..." -ForegroundColor Yellow
        try { $null = $proc.WaitForExit(60000) } catch { }
        if (-not $proc.HasExited) { try { Stop-Process -Id $WaitPid -Force; $null = $proc.WaitForExit(10000) } catch { } }
    }
    Start-Sleep -Milliseconds 800
}

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
try {
    $probe = Join-Path $Target ('.pullprobe_' + [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe -Force
} catch { Stop-HMPull "Kein Schreibzugriff auf '$Target'. PowerShell als Administrator starten oder Ordnerrechte setzen." }

# --- alte Datendateien aus dem Tool-Ordner nach Config\ (ab v3.4.0; das Tool ist jetzt beendet)
#     Liegen beide vor (Wechsel auf eine aeltere Version und zurueck), gilt die zuletzt geaenderte, die andere bleibt als *.alt
foreach ($dn in @('config.json', 'update.json', 'installed.json')) {
    $dOld = Join-Path $Target $dn
    $dNew = Join-Path $cfgDir $dn
    if (-not (Test-Path -LiteralPath $dOld -PathType Leaf)) { continue }
    try {
        if (-not (Test-Path -LiteralPath $cfgDir -PathType Container)) { New-Item -ItemType Directory -Path $cfgDir -Force -ErrorAction Stop | Out-Null }
        if (-not (Test-Path -LiteralPath $dNew -PathType Leaf)) { Move-Item -LiteralPath $dOld -Destination $dNew -ErrorAction Stop }
        elseif ((Get-Item -LiteralPath $dOld -Force).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dNew -Force).LastWriteTimeUtc) {
            Move-Item -LiteralPath $dNew -Destination "$dOld.alt" -Force -ErrorAction Stop; Move-Item -LiteralPath $dOld -Destination $dNew -Force -ErrorAction Stop
        } else { Move-Item -LiteralPath $dOld -Destination "$dOld.alt" -Force -ErrorAction Stop }
        Write-Host "  Migration: $dn -> Config\$dn" -ForegroundColor DarkGray
    } catch { Write-Host "  [WARN] $dn nicht nach Config\ verschiebbar: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function New-GHHeaders([string]$Accept) {
    $h = @{ Accept = $Accept; 'User-Agent' = 'HU-NextExam-Manager-Pull' }
    if ($script:Token) { $h['Authorization'] = "token $($script:Token)" }
    return $h
}
$ProgressPreference = 'SilentlyContinue'

# --- 1. Version waehlen (Release) bzw. Branch
$ref = $null; $rel = $null; $manifest = $null; $verified = 'ohne Pruefsumme'
for ($attempt = 1; $attempt -le 2 -and -not $ref; $attempt++) {
    try {
        if ($useBranch) {
            $r = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
            $ref = "$($r.object.sha)"
        } else {
            $list = @(Get-HMReleases $Owner $Repo $Token)
            if ($Version) {
                $want = ConvertTo-HMVersion $Version
                $rel = @($list | Where-Object { $want -and $_.Version -eq $want })[0]
                if (-not $rel) { Stop-HMPull "Version $Version gibt es nicht als Release ($Owner/$Repo)." }
            } else {
                $rel = Select-HMRelease $list $Channel -SignedOnly:$cfg.RequireSignature
                if (-not $rel) { Stop-HMPull "Kein $(if ($cfg.RequireSignature) { 'signiertes ' })Release im Kanal $(if ($Channel -eq 'Test') { 'Test' } else { 'Stabil' }) gefunden ($Owner/$Repo)." }
            }
            # Tag -> Commit (funktioniert auch bei annotierten Tags)
            $cm = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/commits/$($rel.Tag)" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
            $ref = "$($cm.sha)"
        }
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        # abgelaufener/falscher Token in config.json: ohne Token weiter (Repo ist oeffentlich)
        if ($Token -and $code -eq 401 -and $attempt -eq 1) {
            Write-Host '[WARN] GitHub-Token aus config.json ungueltig (HTTP 401) - weiter ohne Token' -ForegroundColor Yellow
            $Token = ''; $script:Token = ''
            continue
        }
        Stop-HMPull "GitHub nicht erreichbar: $($_.Exception.Message)"
    }
}
if (-not $ref) { Stop-HMPull 'Version nicht ermittelbar' }
if ($useBranch) { Write-Host "Version:    Entwicklungsstand Branch '$Branch' ($($ref.Substring(0, [Math]::Min(12, $ref.Length))))" -ForegroundColor Yellow }
else { Write-Host "Version:    $($rel.Tag)  ($(if ($rel.Prerelease) { 'Test' } else { 'Stabil' }), $($rel.Date))" -ForegroundColor Gray }

# --- 2. Pruefsumme und Signatur
if (-not $useBranch) {
    $manBytes = $null
    if ($rel.ManifestUrl) {
        try { $manBytes = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi $Token } catch { Stop-HMPull "Pruefsummen-Datei nicht ladbar: $($_.Exception.Message)" }
        $manifest = ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($manBytes))
        if (-not $manifest.Count) { Stop-HMPull 'Pruefsummen-Datei ist leer oder beschaedigt.' }
        $verified = 'Pruefsumme (SHA256)'
    }
    if ($cfg.RequireSignature) {
        if (-not $manBytes) { Stop-HMPull "Nur signierte Updates erlaubt - $($rel.Tag) hat keine Pruefsummen-Datei." }
        $sigBytes = $null
        if ($rel.SignatureUrl) { try { $sigBytes = Get-HMReleaseAsset $rel.SignatureUrl $rel.SignatureApi $Token } catch { Stop-HMPull "Signatur nicht ladbar: $($_.Exception.Message)" } }
        $why = Test-HMManifestSignature $manBytes $sigBytes $cfg.SignerThumbprint
        if ($why) { Stop-HMPull "Nur signierte Updates erlaubt - $($rel.Tag): $why" }
        $verified = "Pruefsumme + Signatur ($($cfg.SignerThumbprint.Substring(0, [Math]::Min(8, $cfg.SignerThumbprint.Length)))...)"
        Write-Host 'Signatur:   gueltig' -ForegroundColor Green
    }
    if (-not $manifest) {
        Write-Host "[WARN] $($rel.Tag) hat keine Pruefsummen-Datei (Versionen vor 3.2.0 oder die automatischen Tests sind noch nicht fertig/fehlgeschlagen)." -ForegroundColor Yellow
        if ($NonInteractive) { Stop-HMPull 'ohne Pruefsumme nicht erlaubt (-NonInteractive)' }
        $a = Read-Host 'Trotzdem ohne Pruefung laden? (j/N)'
        if ("$a".Trim() -notmatch '^[jJyY]') { Stop-HMPull 'abgebrochen' }
    }
}
Write-Host "Pruefung:   $verified" -ForegroundColor Gray

# --- 3. Dateiliste
try { $tree = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/trees/${ref}?recursive=1" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing }
catch { Stop-HMPull "Dateiliste nicht lesbar: $($_.Exception.Message)" }
$files = @($tree.tree | Where-Object { $_.type -eq 'blob' -and "$($_.path)" -notlike '.github/*' -and "$($_.path)" -notlike '*/.gitkeep' -and "$($_.path)" -ne '.gitkeep' })
if (-not $files.Count) { Stop-HMPull 'Repo-Inhalt leer' }
Write-Host "$($files.Count) Dateien`n" -ForegroundColor Gray

# --- 4. alles laden und pruefen (noch nichts ersetzen)
$staged = New-Object System.Collections.Generic.List[object]
$fail = 0
foreach ($f in $files) {
    $local = Join-Path $Target ($f.path -replace '/', '\')
    $dir = Split-Path $local -Parent
    try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { Write-Host "  $($f.path): Ordner nicht anlegbar" -ForegroundColor Red; $fail++; continue }
    Write-Host ('  {0,-48} ... ' -f $f.path) -NoNewline
    $tmp = "$local.pulltmp"
    $done = $false; $lastErr = ''
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try {
            # raw.githubusercontent.com beim Commit-SHA: zaehlt nicht gegen das API-Limit, kein CDN-Cache-Problem
            $enc = (($f.path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            Invoke-WebRequest "https://raw.githubusercontent.com/$Owner/$Repo/$ref/$enc" -Headers @{ 'User-Agent' = 'HU-NextExam-Manager-Pull' } -UseBasicParsing -OutFile $tmp
            $done = $true
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if (-not $done) { Write-Host "FEHLER: $lastErr" -ForegroundColor Red; $fail++; continue }
    if ($manifest) {
        $want = $manifest[$f.path]
        $have = Get-HMFileSha256 $tmp
        if (-not $want) { Write-Host 'FEHLER: nicht in der Pruefsummen-Datei' -ForegroundColor Red; $fail++; $staged.Add(@($tmp, $local)); continue }
        if ($have -ne $want) { Write-Host 'FEHLER: Pruefsumme stimmt nicht' -ForegroundColor Red; $fail++; $staged.Add(@($tmp, $local)); continue }
        Write-Host 'OK (geprueft)' -ForegroundColor Green
    } else { Write-Host "OK ($((Get-Item -LiteralPath $tmp -Force).Length) bytes)" -ForegroundColor Green }
    $staged.Add(@($tmp, $local))
}
if ($fail) {
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Stop-HMPull "$fail Datei(en) nicht geladen oder Pruefsumme falsch - es wurde NICHTS veraendert, das Tool bleibt auf der bisherigen Version."
}

# --- 5. ersetzen - mit Ruecksicherung: jede bisherige Datei wird erst zu *.pullold umbenannt;
#        scheitert ein Schritt, wird alles zurueckgestellt (nie halb aktualisiert).
#        Bricht Pull mittendrin ab (Absturz, Strom), stellt der naechste Pull-Lauf anhand des Journals zurueck.
$journal = $jr
$moved = New-Object System.Collections.Generic.List[object]   # @(Ziel, Sicherung oder '')
$repl = 0; $lastErr = ''
try { if (-not (Test-Path -LiteralPath $jrDir)) { New-Item -ItemType Directory -Path $jrDir -Force | Out-Null } } catch { }
try { ConvertTo-Json -InputObject @($staged | ForEach-Object { "$($_[1])" }) | Set-Content -LiteralPath $journal -Encoding UTF8 -ErrorAction Stop }
catch {
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Stop-HMPull "Journal nicht schreibbar ($($_.Exception.Message)) - es wurde NICHTS veraendert."
}
foreach ($s in $staged) {
    $old = "$($s[1]).pullold"
    $done = $false
    $had = Test-Path -LiteralPath $s[1]      # einmal vor den Wiederholungen bestimmen
    $backedUp = $false                       # bisherige Datei liegt gerade als *.pullold
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try {
            if ($had -and -not $backedUp) { Move-Item -LiteralPath $s[1] -Destination $old -Force; $backedUp = $true }
            try { Move-Item -LiteralPath $s[0] -Destination $s[1] -Force }
            catch { if ($backedUp) { try { Move-Item -LiteralPath $old -Destination $s[1] -Force; $backedUp = $false } catch { } }; throw }
            $moved.Add(@($s[1], $(if ($had) { $old } else { '' })))
            $done = $true
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if (-not $done) {
        if ($backedUp) { try { Move-Item -LiteralPath $old -Destination $s[1] -Force } catch { Write-Host "  [WARN] $($s[1]): Sicherung nicht zurueckgestellt ($($_.Exception.Message))" -ForegroundColor Yellow } }
        Write-Host "  $($s[1]): nicht ersetzbar ($lastErr)" -ForegroundColor Red; $repl++; break
    }
}
if ($repl) {
    # zurueckstellen (umgekehrte Reihenfolge): neue Dateien entfernen, Sicherungen zurueck
    for ($k = $moved.Count - 1; $k -ge 0; $k--) {
        $m = $moved[$k]
        try { if ($m[1]) { Move-Item -LiteralPath $m[1] -Destination $m[0] -Force } else { Remove-Item -LiteralPath $m[0] -Force } }
        catch { Write-Host "  [WARN] $($m[0]): nicht zurueckgestellt ($($_.Exception.Message))" -ForegroundColor Yellow }
    }
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
    Stop-HMPull "Eine Datei war gesperrt ($lastErr) - alles wurde zurueckgestellt, das Tool bleibt auf der bisherigen Version. Tool schliessen und Pull erneut ausfuehren."
}
# Abschluss: zuerst das Journal loeschen (ab hier gilt der neue Stand), dann die Sicherungen.
# Umgekehrt koennte ein Abbruch beim Aufraeumen einen Mischstand aus alt und neu herstellen.
Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
foreach ($m in $moved) {
    try { Unblock-File -LiteralPath $m[0] -ErrorAction SilentlyContinue } catch { }
    if ($m[1]) { Remove-Item -LiteralPath $m[1] -Force -ErrorAction SilentlyContinue }
}
$ok = $moved.Count

# --- 6. Dateien entfernen, die es im neuen Stand nicht mehr gibt - nur solche, die frueher per Pull installiert wurden
#        (Liste in installed.json). Eigene Dateien und die Datenordner bleiben immer unberuehrt.
$newFiles = @($files | ForEach-Object { "$($_.path)" })
$instFile = Get-PullDataFile 'installed.json'
$prevFiles = @()
try { if (Test-Path -LiteralPath $instFile) { $pi = Get-Content -LiteralPath $instFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($pi.PSObject.Properties['FileList']) { $prevFiles = @($pi.FileList) } } } catch { }
$removedOld = 0
$keepDirs = '^(Config|Logs)/'
$rootFull = [IO.Path]::GetFullPath($Target).TrimEnd('\') + '\'
foreach ($oldPath in @($prevFiles | ForEach-Object { "$_" } | Where-Object { $_ -and $newFiles -notcontains $_ -and $_ -notmatch $keepDirs -and $_ -notmatch '(^|/)\.\.(/|$)' -and $_ -notmatch '^[\\/]|:' })) {
    $p = [IO.Path]::GetFullPath((Join-Path $Target ($oldPath -replace '/', '\')))
    if (-not $p.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        try { Remove-Item -LiteralPath $p -Force; $removedOld++; Write-Host "  entfernt (nicht mehr im Programm): $oldPath" -ForegroundColor DarkGray } catch { }
    }
}

# Migration 0.8 -> 0.9: alte Files im Root entfernen (sind jetzt in Unterordnern)
foreach ($m in @('icon.ico', 'config.json.example', 'Start.bat', 'CHANGELOG.md')) {
    $old = Join-Path $Target $m
    if (Test-Path -LiteralPath $old) { try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop; Write-Host "  Migration: $m entfernt (jetzt in Assets\ / Docs\)" -ForegroundColor Yellow } catch { } }
}
# Migration: alte Installationen haben den Ordner .github mitgeladen (gehoert nur ins Repo, nie in eine Installation).
# Nicht in einer Entwickler-Arbeitskopie (.git vorhanden).
$ghDir = Join-Path $Target '.github'
if ((Test-Path -LiteralPath $ghDir -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $Target '.git'))) {
    $ghAttr = [System.IO.File]::GetAttributes($ghDir)
    if (($ghAttr -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        try { Remove-Item -LiteralPath $ghDir -Recurse -Force -ErrorAction Stop; Write-Host '  Migration: Ordner .github entfernt (gehoert nicht in eine Installation)' -ForegroundColor Yellow } catch { }
    }
}

try {
    [pscustomobject][ordered]@{
        Version = $(if ($useBranch) { "Branch $Branch" } else { "$($rel.Version)" }); Ref = "$ref"; Channel = $(if ($useBranch) { 'Branch' } elseif ($rel.Prerelease) { 'Test' } else { 'Stable' })
        Check = $verified; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Files = $ok; FileList = $newFiles
    } | ConvertTo-Json | Set-Content -LiteralPath $instFile -Encoding UTF8
} catch { }
# Wechsel auf eine Version vor 3.4.0: die liest ihre Daten noch aus dem Tool-Ordner -> dorthin kopieren (Config\ bleibt)
$relVer = $null
if (-not $useBranch) { try { $relVer = [version](("$($rel.Version)" -replace '^v', '') -replace '-.*$', '') } catch { $relVer = $null } }
if ($relVer -and $relVer -lt [version]'3.4.0') {
    foreach ($dn in @('config.json', 'update.json', 'installed.json')) {
        $dNew = Join-Path $cfgDir $dn
        if (Test-Path -LiteralPath $dNew -PathType Leaf) {
            try { Copy-Item -LiteralPath $dNew -Destination (Join-Path $Target $dn) -Force -ErrorAction Stop; Write-Host "  aeltere Version: $dn in den Tool-Ordner kopiert" -ForegroundColor DarkGray } catch { }
        }
    }
}
Write-Host "`n=== Pull fertig === $ok Dateien ($verified)$(if ($removedOld) { " | $removedOld alte entfernt" })" -ForegroundColor Cyan


# Tool nach dem Update gleich wieder starten (ausser -NoStart, z.B. CI)
#   Pull laeuft schon als Admin -> direkt starten (erbt die Rechte, keine zweite UAC-Abfrage)
#   sonst ueber Start.vbs (UAC-Abfrage, fensterlos)
if (-not $NoStart) {
    $main = Join-Path $Target 'HU-NextExam-Manager.ps1'
    $vbs  = Join-Path $Target 'Start.vbs'
    $isAdmin = $false
    try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    try {
        if ($isAdmin -and (Test-Path -LiteralPath $main)) {
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$main`"" -WorkingDirectory $Target
        } elseif (Test-Path -LiteralPath $vbs) {
            Start-Process wscript.exe -ArgumentList "`"$vbs`"" -WorkingDirectory $Target
        } elseif (Test-Path -LiteralPath $main) {
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$main`"" -WorkingDirectory $Target
        }
        Write-Host 'HU-NextExam-Manager wird gestartet.' -ForegroundColor Green
        Start-Sleep -Seconds 2
    } catch { Write-Host "[WARN] Start fehlgeschlagen: $($_.Exception.Message) - bitte Start.vbs von Hand starten" -ForegroundColor Yellow }
}
exit 0
