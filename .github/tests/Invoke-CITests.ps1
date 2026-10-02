#Requires -Version 5.1
<#
.SYNOPSIS
    Automatische Pruefungen fuer HU-NextExam-Manager (GitHub Actions, Windows PowerShell 5.1) - blockierend.
.DESCRIPTION
    1. Syntax aller PowerShell-Dateien (Parser); Nicht-ASCII nur mit UTF-8-BOM (sonst liest PS 5.1 falsch)
    2. XAML-Hauptfenster laden; alle im Code per Get-UI verwendeten Steuerelemente vorhanden
    3. Update-Bibliothek in Pull.ps1 und Modules\Update.psm1 identisch
    4. PSScriptAnalyzer: keine Fehler (Schweregrad Error)
    5. Pester-Tests (.github\tests\*.Tests.ps1)
.NOTES
    Aufruf (auch lokal): powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1
    Zielmaschine: Windows-PC / GitHub-Runner mit Internet (PSScriptAnalyzer, Pester werden bei Bedarf installiert).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fail = New-Object System.Collections.Generic.List[string]
function Step([string]$Name, [scriptblock]$Do) {
    Write-Host "== $Name" -ForegroundColor Cyan
    try { $r = & $Do; if ($r) { Write-Host "   $r" -ForegroundColor Green } else { Write-Host '   OK' -ForegroundColor Green } }
    catch { $fail.Add("$Name : $($_.Exception.Message)"); Write-Host "   FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "HU-NextExam-Manager CI - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)"

# 1. Syntax + Kodierung
Step 'Syntax und Kodierung aller .ps1/.psm1' {
    $bad = @()
    $files = @(Get-ChildItem -Path $root -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\\.git\\' })
    foreach ($f in $files) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { $bad += "$($f.Name): " + (($e | Select-Object -First 2 | ForEach-Object { "Zeile $($_.Extent.StartLineNumber) $($_.Message)" }) -join ' | ') }
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        if (-not $bom -and @($b | Where-Object { $_ -gt 127 }).Count) { $bad += "$($f.Name): Nicht-ASCII-Zeichen ohne UTF-8-BOM" }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
    "$($files.Count) Dateien"
}

# 2. XAML + Steuerelemente
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Step 'XAML Hauptfenster + alle Get-UI-Steuerelemente aus HU-NextExam-Manager.ps1' {
    [xml]$x = Get-Content (Join-Path $root 'XAML\MainWindow.xaml') -Raw -Encoding UTF8
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $txt = Get-Content (Join-Path $root 'HU-NextExam-Manager.ps1') -Raw -Encoding UTF8
    $names = @([regex]::Matches($txt, "Get-UI\s+'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $miss = @($names | Where-Object { -not $w.FindName($_) })
    if ($miss.Count) { throw "fehlt im XAML: $($miss -join ', ')" }
    "$($names.Count) Steuerelemente"
}

# 3. Update-Bibliothek identisch
Step 'Update-Bibliothek Pull.ps1 = Modules\Update.psm1' {
    $re = '(?s)#region HMUpdateLib.*?#endregion HMUpdateLib'
    $a = [regex]::Match((Get-Content (Join-Path $root 'Pull.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    $b = [regex]::Match((Get-Content (Join-Path $root 'Modules\Update.psm1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    if (-not $a -or -not $b) { throw 'Bereich HMUpdateLib fehlt' }
    if ($a -ne $b) { throw 'Bereich HMUpdateLib unterscheidet sich - beide Dateien gleich halten' }
    "$(($a -split "`n").Count) Zeilen"
}

# 4. PSScriptAnalyzer
function Install-CIModule([string]$Name, [string]$Max = '') {
    if (Get-Module -ListAvailable -Name $Name | Where-Object { -not $Max -or $_.Version -le [Version]$Max } | Select-Object -First 1) { return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    $p = @{ Name = $Name; Force = $true; Scope = 'CurrentUser'; SkipPublisherCheck = $true; AllowClobber = $true }
    if ($Max) { $p.MaximumVersion = $Max }
    Install-Module @p
}
Step 'PSScriptAnalyzer (Fehler)' {
    Install-CIModule 'PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    if ($r.Count) { throw (($r | Select-Object -First 10 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join ' | ') }
    'keine Fehler'
}

# 5. Pester
Step 'Pester-Tests' {
    Install-CIModule 'Pester' '5.99.99'
    Import-Module Pester -MaximumVersion 5.99.99 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount -gt 0) { throw "$($res.FailedCount) von $($res.TotalCount) Tests fehlgeschlagen" }
    "$($res.PassedCount) Tests bestanden"
}

Write-Host ''
if ($fail.Count) {
    Write-Host "FEHLGESCHLAGEN ($($fail.Count)):" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($env:GITHUB_STEP_SUMMARY) { (@('### HU-NextExam-Manager CI: FEHLGESCHLAGEN') + @($fail | ForEach-Object { "- $_" })) | Add-Content $env:GITHUB_STEP_SUMMARY }
    exit 1
}
Write-Host 'ALLE PRUEFUNGEN BESTANDEN' -ForegroundColor Green
if ($env:GITHUB_STEP_SUMMARY) { '### HU-NextExam-Manager CI: alle Pruefungen bestanden' | Add-Content $env:GITHUB_STEP_SUMMARY }
exit 0
