#Requires -Version 5.1
<#
.SYNOPSIS
    MSI-Pull-Modul: Next-Exam Release abfragen, MSI downloaden, auf Shares deployen.
#>

$script:NextExamApiUrl = 'https://api.github.com/repos/Bildungsportal/next-exam/releases/latest'
$script:AssetRegex     = '^Next-Exam-(?<Role>Student|Teacher)_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Date>\d{8})_x64\.msi$'
# $script:VersionFileName obsolet - jetzt pro Rolle via Get-VersionFileName
$script:ArchiveFolder   = '_archive'

function Get-VersionFileName {
    param([Parameter(Mandatory)][ValidateSet('Student','Teacher')][string]$Role)
    return "version-$($Role.ToLower()).json"
}

function Get-NextExamLatestRelease {
    [CmdletBinding()]
    param()
    try {
        $h = @{
            Accept       = 'application/vnd.github.v3+json'
            'User-Agent' = 'HU-NextExam-Manager'
        }
        # Optional: GitHub PAT aus Config -> 5000 statt 60 API-Calls/h
        $tok = $null
        try { $tok = $script:Config.ToolSettings.GitHubToken } catch {}
        if (-not $tok) { try { $tok = (Load-Config).ToolSettings.GitHubToken } catch {} }
        if ($tok) { $h['Authorization'] = "token $tok" }
        $r = Invoke-RestMethod -Uri $script:NextExamApiUrl -UseBasicParsing -Headers $h -ErrorAction Stop
    } catch {
        throw "GitHub-API-Fehler (Next-Exam Release): $_"
    }

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
            }
        }
    }

    [PSCustomObject]@{
        TagName     = $r.tag_name
        Name        = $r.name
        PublishedAt = $r.published_at
        HtmlUrl     = $r.html_url
        Body        = $r.body
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

function Deploy-MSIToShare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceMSI,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$BuildDate,
        [Parameter(Mandatory)][string]$FileName
    )
    if (-not (Test-Path $SharePath)) {
        New-Item -ItemType Directory -Path $SharePath -Force | Out-Null
    }
    # Archivierung vorhandener MSIs (gleiche Rolle)
    $prefix = "Next-Exam-$Role"
    $archived = Move-OldMSIToArchive -SharePath $SharePath -RolePrefix $prefix

    # Copy neue MSI
    $dst = Join-Path $SharePath $FileName
    Copy-Item -Path $SourceMSI -Destination $dst -Force

    # version.json
    Write-ShareVersionInfo -SharePath $SharePath -Role $Role -Version $Version `
                           -BuildDate $BuildDate -FileName $FileName

    [PSCustomObject]@{
        Role             = $Role
        Deployed         = $dst
        ArchivedCount    = $archived
        Size             = (Get-Item $dst).Length
    }
}

# Funktionen exportieren (nur wenn als Modul geladen; bei dot-source automatisch sichtbar)
if ($ExecutionContext.SessionState.Module) {
Export-ModuleMember -Function Get-NextExamLatestRelease, Read-ShareVersionInfo, `
                              Write-ShareVersionInfo, Move-OldMSIToArchive, `
                              Invoke-MSIDownload, Deploy-MSIToShare
}
