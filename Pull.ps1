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

    Lokale Daten bleiben unangetastet: config.json, update.json, installed.json, Logs, HU-NextExam-Manager.exe (Starter).
    GitHub-Token (optional, nur fuer mehr API-Aufrufe/h): config.json > ToolSettings.GitHubToken.
.NOTES
    Manuell: powershell -ExecutionPolicy Bypass -File Pull.ps1 [-Version 3.2.0] [-Channel Test]
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
# Vorlage: HUMig (Functions\Core-Update.ps1) - gleiche Funktionsnamen, gleiches Signatur-Zertifikat
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
    $raw = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100" -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
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
# Release-Datei (Pruefsummen/Signatur) als Bytes laden - mit Token ueber die API (private Repos)
function Get-HMReleaseAsset([string]$Url, [string]$ApiUrl, [string]$Token) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        if ($Token -and $ApiUrl) { Invoke-WebRequest $ApiUrl -Headers @{ Accept = 'application/octet-stream'; 'User-Agent' = $script:HMUserAgent; Authorization = "token $Token" } -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -ErrorAction Stop }
        else { Invoke-WebRequest $Url -Headers @{ 'User-Agent' = $script:HMUserAgent } -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -ErrorAction Stop }
        return ,([System.IO.File]::ReadAllBytes($tmp))
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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
    else { $Target = Join-Path $env:USERPROFILE 'Desktop\HU-NextExam-Manager'; $mode = 'Erstinstallation (Desktop)' }
} else { $mode = 'Ziel per -Target' }
$Target = $Target.TrimEnd('\')

# --- Update-Einstellungen (update.json im Tool-Ordner)
$cfgDir = $Target
$cfg = Get-HMUpdateConfig $cfgDir
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

# --- optionaler Token aus config.json (nur Rate-Limit: 5000 statt 60 API-Aufrufe/h) bzw. Umgebungsvariable (CI)
$Token = "$env:HUNEM_GITHUB_TOKEN".Trim()
$cfgPath = Join-Path $Target 'config.json'
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

# --- 5. ersetzen
$ok = 0; $repl = 0
foreach ($s in $staged) {
    $done = $false; $lastErr = ''
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try { Move-Item -LiteralPath $s[0] -Destination $s[1] -Force; $done = $true } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if ($done) { try { Unblock-File -LiteralPath $s[1] -ErrorAction SilentlyContinue } catch { }; $ok++ }
    else { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue; Write-Host "  $($s[1]): nicht ersetzbar ($lastErr)" -ForegroundColor Red; $repl++ }
}

# Migration 0.8 -> 0.9: alte Files im Root entfernen (sind jetzt in Unterordnern)
foreach ($m in @('icon.ico', 'config.json.example', 'Start.bat', 'CHANGELOG.md')) {
    $old = Join-Path $Target $m
    if (Test-Path -LiteralPath $old) { try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop; Write-Host "  Migration: $m entfernt (jetzt in Assets\ / Docs\)" -ForegroundColor Yellow } catch { } }
}

try {
    [pscustomobject][ordered]@{
        Version = $(if ($useBranch) { "Branch $Branch" } else { "$($rel.Version)" }); Ref = "$ref"; Channel = $(if ($useBranch) { 'Branch' } elseif ($rel.Prerelease) { 'Test' } else { 'Stable' })
        Check = $verified; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Files = $ok
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cfgDir 'installed.json') -Encoding UTF8
} catch { }
Write-Host "`n=== Pull fertig === $ok Dateien ($verified)$(if ($repl) { " | $repl NICHT ersetzt" })" -ForegroundColor Cyan

if ($repl) { Stop-HMPull 'Einzelne Dateien konnten nicht ersetzt werden (gesperrt?) - Tool wird NICHT automatisch gestartet. Pull erneut ausfuehren.' }
# Neustart nur, wenn das Tool den Pull selbst ausgeloest hat (-WaitPid); Elevation wird vom Pull-Fenster geerbt
if ($WaitPid -gt 0 -and -not $NoStart) {
    $main = Join-Path $Target 'HU-NextExam-Manager.ps1'
    if (Test-Path -LiteralPath $main) {
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$main`"" -WorkingDirectory $Target
        Write-Host 'HU-NextExam-Manager wird neu gestartet.' -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
    exit 0
}
if (-not $NoStart) { Write-Host "Start: cd '$Target'; .\HU-NextExam-Manager.ps1   (oder Start.vbs)" -ForegroundColor Yellow }
exit 0
