#Requires -Version 5.1
<#
.SYNOPSIS
    HU-NextExam-Manager Pull-Script - holt alle aktuellen Dateien aus dem GitHub-Repo.
.NOTES
    Als Admin ausfuehren: powershell -ExecutionPolicy Bypass -File Pull.ps1
#>
$ErrorActionPreference = 'Stop'

$Owner  = 'ChiliApple'
$Repo   = 'HU-NextExam-Manager'
$Branch = 'main'
$Target = Join-Path $env:USERPROFILE 'Desktop\HU-NextExam-Manager'

Write-Host "=== HU-NextExam-Manager Pull ===" -ForegroundColor Cyan
Write-Host "Benutzer:   $env:USERNAME"   -ForegroundColor Gray
Write-Host "Zielordner: $Target"          -ForegroundColor Gray

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }

# Token aus config.json lesen (falls vorhanden) -> 5000 statt 60 API-Calls/h
$GitHubToken = $null
$cfgPath = Join-Path $Target 'config.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.ToolSettings.GitHubToken) {
            $GitHubToken = $cfg.ToolSettings.GitHubToken
            Write-Host "GitHub-Token: aus config.json (5000 Calls/h)" -ForegroundColor Green
        }
    } catch {}
}
if (-not $GitHubToken) {
    Write-Host "GitHub-Token: keiner konfiguriert (60 Calls/h Limit)" -ForegroundColor Yellow
    Write-Host "  Tipp: In config.json unter ToolSettings 'GitHubToken' eintragen" -ForegroundColor Yellow
}

# API-Header (2 Calls fuer Tree-Listing), Downloads ueber raw.githubusercontent.com (kein Rate-Limit)
$HApi = @{ Accept = 'application/vnd.github.v3+json'; 'User-Agent' = 'HU-NextExam-Manager-Pull' }
if ($GitHubToken) { $HApi['Authorization'] = "token $GitHubToken" }

try {
    $ref = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch" -Headers $HApi
    $sha = $ref.object.sha
    Write-Host "Commit-SHA: $sha" -ForegroundColor Gray
} catch {
    Write-Host "[FEHLER] $_" -ForegroundColor Red; exit 1
}

$tree  = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/trees/${sha}?recursive=1" -Headers $HApi
$files = @($tree.tree | Where-Object { $_.type -eq 'blob' })
Write-Host "$($files.Count) Dateien im Repo`n" -ForegroundColor Gray

$ok = 0; $fail = 0
foreach ($f in $files) {
    if ($f.path -eq '.gitkeep' -or $f.path -like '*/.gitkeep') { continue }
    $local = Join-Path $Target ($f.path -replace '/', '\')
    $dir   = Split-Path $local -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Host ("  {0,-50} ... " -f $f.path) -NoNewline
    try {
        # Download via raw.githubusercontent.com — zaehlt NICHT gegen API-Rate-Limit
        $u = "https://raw.githubusercontent.com/$Owner/$Repo/$sha/$($f.path)"
        Invoke-WebRequest $u -UseBasicParsing -OutFile $local
        Write-Host "OK ($((Get-Item $local).Length) bytes)" -ForegroundColor Green
        $ok++
    } catch { Write-Host "FEHLER: $_" -ForegroundColor Red; $fail++ }
}

# Migration 0.8 -> 0.9: alte Files im Root entfernen (sind jetzt in Unterordnern)
$migrateRemove = @('icon.ico','config.json.example','Start.bat','CHANGELOG.md','LICENSE')
foreach ($f in $migrateRemove) {
    $old = Join-Path $Target $f
    if (Test-Path $old) {
        try { Remove-Item $old -Force -ErrorAction Stop; Write-Host "  Migration: $f entfernt (jetzt in Assets\ / Docs\)" -ForegroundColor Yellow } catch {}
    }
}

Write-Host "`n=== Pull fertig === OK: $ok | Fehler: $fail" -ForegroundColor Cyan
Write-Host "Start: cd '$Target'; .\HU-NextExam-Manager.ps1" -ForegroundColor Yellow
