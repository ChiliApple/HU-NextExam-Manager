#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer v3.4.0: Daten in Config\, GitHub-Token geschuetzt, atomares Speichern der Config,
# GPO-Versionsnummer, Intune-Erkennungsregel, Auto-Pull je Rolle

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:Root 'Modules\Logging.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\Protect.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\Config.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\GPOSetup.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\MDMDeploy.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\MSIPull.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\AutoPull.psm1') -Force -Global -DisableNameChecking
    Initialize-Log -Path (Join-Path $TestDrive 'test.log') -Level 'DEBUG'
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Daten in Config\ (config.json, update.json, installed.json)' {
    It 'verschiebt alte Dateien aus dem Programmordner nach Config\' {
        $r = Join-Path $TestDrive 'mig1'; New-Item -ItemType Directory -Path $r -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'config.json') -Value '{"a":1}'
        Set-Content -LiteralPath (Join-Path $r 'update.json') -Value '{"Channel":"Test"}'
        Get-NEMDataFile $r 'config.json' | Should -Be (Join-Path $r 'config.json')     # vor dem Verschieben: alte Datei
        $m = @(Move-NEMDataFiles $r)
        $m.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $r 'config.json') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $r 'Config\config.json') -Raw | Should -Match '"a":1'
        Get-NEMDataFile $r 'config.json' | Should -Be (Join-Path $r 'Config\config.json')
        Get-NEMDataFile $r 'installed.json' | Should -Be (Join-Path $r 'Config\installed.json')   # fehlt ueberall: neuer Ort
        @(Move-NEMDataFiles $r).Count | Should -Be 0                                              # zweiter Lauf: nichts zu tun
    }
    It 'liegen beide vor, gilt die zuletzt geaenderte, die andere bleibt als .alt' {
        $r = Join-Path $TestDrive 'mig2'; New-Item -ItemType Directory -Path (Join-Path $r 'Config') -Force | Out-Null
        $new = Join-Path $r 'Config\config.json'; $old = Join-Path $r 'config.json'
        Set-Content -LiteralPath $new -Value 'neu-alt'; (Get-Item $new).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
        Set-Content -LiteralPath $old -Value 'alt-neuer'
        $null = Move-NEMDataFiles $r
        (Get-Content -LiteralPath $new -Raw) | Should -Match 'alt-neuer'
        (Get-Content -LiteralPath "$old.alt" -Raw) | Should -Match 'neu-alt'
        Test-Path -LiteralPath $old | Should -BeFalse
        # umgekehrt: Config\ ist neuer -> alte Datei wird nur umbenannt
        Set-Content -LiteralPath $old -Value 'veraltet'; (Get-Item $old).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-5)
        $null = Move-NEMDataFiles $r
        (Get-Content -LiteralPath $new -Raw) | Should -Match 'alt-neuer'
        (Get-Content -LiteralPath "$old.alt" -Raw) | Should -Match 'veraltet'
    }
}

Describe 'Config speichern (atomar, mit Sicherung)' {
    It 'schreibt ueber eine Zwischendatei, behaelt config.json.bak und laedt bei Defekt den letzten guten Stand' {
        $d = Join-Path $TestDrive 'cfg'; $f = Join-Path $d 'config.json'
        Set-ConfigPath -Path $f
        $c = Load-Config                              # Erstanlage
        Test-Path -LiteralPath $f | Should -BeTrue
        $c.ToolSettings.LogLevel = 'WARN'
        Save-Config -Config $c
        Test-Path -LiteralPath "$f.bak" | Should -BeTrue
        Test-Path -LiteralPath "$f.tmp" | Should -BeFalse
        (Load-Config).ToolSettings.LogLevel | Should -Be 'WARN'
        Save-Config -Config $c                        # .bak = Stand mit WARN
        Set-Content -LiteralPath $f -Value '{ kaputt' -Encoding UTF8
        (Load-Config 3>$null).ToolSettings.LogLevel | Should -Be 'WARN'
    }
}

Describe 'GitHub-Token geschuetzt (Config\github-token.dat)' {
    It 'speichert verschluesselt, nur fuer SYSTEM/Administratoren, und uebernimmt ihn aus config.json' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $r = Join-Path $TestDrive 'tok'; New-Item -ItemType Directory -Path $r -Force | Out-Null
        $cfg = [pscustomobject]@{ ToolSettings = [pscustomobject]@{ GitHubToken = ' github_pat_TEST123 ' } }
        Move-NEMGitHubTokenToStore $r $cfg | Should -BeTrue
        $cfg.ToolSettings.GitHubToken | Should -Be ''
        Get-NEMGitHubToken $r | Should -Be 'github_pat_TEST123'
        $f = Join-Path $r 'Config\github-token.dat'
        [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($f)) | Should -Not -Match 'github_pat'
        $acl = [System.IO.File]::GetAccessControl($f)
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ';' | Should -Be 'S-1-5-18;S-1-5-32-544'
        Move-NEMGitHubTokenToStore $r $cfg | Should -BeFalse     # leer: nichts zu tun
        Set-NEMGitHubToken -Root $r -Token ''
        Test-Path -LiteralPath $f | Should -BeFalse
        Get-NEMGitHubToken $r | Should -Be ''
    }
    It 'leert den Token in Kopien der config.json (.bak, .alt)' {
        $r = Join-Path $TestDrive 'tok3'; New-Item -ItemType Directory -Path (Join-Path $r 'Config') -Force | Out-Null
        $bak = Join-Path $r 'Config\config.json.bak'; $alt = Join-Path $r 'config.json.alt'
        '{ "ToolSettings": { "GitHubToken": "github_pat_X", "LogLevel": "INFO" } }' | Set-Content -LiteralPath $bak -Encoding UTF8
        '{ "ToolSettings": { "GitHubToken": "github_pat_Y" } }' | Set-Content -LiteralPath $alt -Encoding UTF8
        Clear-NEMTokenCopies $r
        (Get-Content -LiteralPath $bak -Raw) | Should -Not -Match 'github_pat'
        (Get-Content -LiteralPath $bak -Raw | ConvertFrom-Json).ToolSettings.LogLevel | Should -Be 'INFO'
        (Get-Content -LiteralPath $alt -Raw) | Should -Not -Match 'github_pat'
    }
    It 'Absichern des Programmordners laesst das Geheimnis unlesbar fuer Benutzer' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $r = Join-Path $TestDrive 'tok2'; New-Item -ItemType Directory -Path (Join-Path $r 'Modules') -Force | Out-Null
        Set-NEMGitHubToken -Root $r -Token 'abc'
        $f = Join-Path $r 'Config\github-token.dat'
        # Benutzer-Lesen erzwingen (z.B. von Hand zurueckgesetzt) -> muss als Problem erkannt und behoben werden
        $null = & icacls.exe $f /reset
        $null = & icacls.exe $r /grant '*S-1-5-32-545:(OI)(CI)(M)'
        (@(Get-NEMAppDirIssues $r) -join ';') | Should -Match 'lesbar fuer'
        Protect-NEMAppDir -Root $r | Should -Match 'abgesichert'
        @(Get-NEMAppDirIssues $r).Count | Should -Be 0
        $acl = [System.IO.File]::GetAccessControl($f)
        @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }).Count | Should -Be 0
        Get-NEMGitHubToken $r | Should -Be 'abc'
    }
}

Describe 'GPO-Versionsnummer (Computer-Teil +1)' {
    It 'erhoeht nur den Computer-Teil, auch bei grossem Benutzer-Teil (vorzeichenbehaftet im AD)' {
        $v = Get-NEMNextGPOVersion -Current 0
        $v.Signed | Should -Be 1
        (Get-NEMNextGPOVersion -Current (3 * 65536 + 7)).Signed | Should -Be (3 * 65536 + 8)
        # Benutzer-Teil >= 32768 -> negativer Wert im AD, darf nicht in [int] ueberlaufen
        $neg = [int](32768 * 65536 - 4294967296 + 5)
        $n = Get-NEMNextGPOVersion -Current $neg
        $n.User | Should -Be 32768
        $n.Computer | Should -Be 6
        $n.Signed | Should -Be ($neg + 1)
        # Computer-Teil laeuft ueber -> wieder 1, Benutzer-Teil unveraendert
        $w = Get-NEMNextGPOVersion -Current (2 * 65536 + 65535)
        $w.User | Should -Be 2
        $w.Computer | Should -Be 1
    }
}

Describe 'Intune-Erkennungsregel' {
    It 'mit ProductCode: Version >= MSI-Version (alte Installationen gelten nicht als installiert)' {
        $r = New-NEMDetectionRules -AppMetadata @{ msiProductCode = '{11111111-2222-3333-4444-555555555555}'; msiProductVersion = '2.1.0.3'; displayName = 'Next-Exam-Student' }
        $r.Count | Should -Be 1
        $r[0]['@odata.type'] | Should -Be '#microsoft.graph.win32LobAppProductCodeDetection'
        $r[0].productVersionOperator | Should -Be 'greaterThanOrEqual'
        $r[0].productVersion | Should -Be '2.1.0.3'
    }
    It 'ohne ProductCode: Datei-Erkennung als Rueckfall' {
        $r = New-NEMDetectionRules -AppMetadata @{ displayName = 'Next-Exam-Teacher' }
        $r[0]['@odata.type'] | Should -Be '#microsoft.graph.win32LobAppFileSystemDetection'
        $r[0].fileOrFolderName | Should -Be 'Next-Exam-Teacher.exe'
    }
}

Describe 'Auto-Pull je Rolle' {
    It 'fehlt eine Rolle im Release, wird die andere trotzdem verteilt und ein Fehler gezaehlt' {
        $d = Join-Path $TestDrive 'ap'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'config.json'
        Set-ConfigPath -Path $f
        $c = Load-Config
        $t = New-TaskEntry -DisplayName 'T1'
        $t.StudentSharePath = Join-Path $d 'S'; $t.TeacherSharePath = Join-Path $d 'T'
        $c.Tasks = @($t)
        $c.ToolSettings.LogPath = Join-Path $d 'ap.log'
        Save-Config -Config $c
        Mock -ModuleName AutoPull Get-NextExamLatestRelease {
            [pscustomobject]@{ TagName = 'v9.9.9.9'; Student = $null
                Teacher = [pscustomobject]@{ Version = '9.9.9.9'; BuildDate = '20260101'; FileName = 'Next-Exam-Teacher_9.9.9.9_20260101_x64.msi'; DownloadUrl = 'https://example.invalid/t.msi'; Sha256 = '' } }
        }
        Mock -ModuleName AutoPull Read-ShareVersionInfo { $null }
        Mock -ModuleName AutoPull Deploy-MSIToShare { [pscustomobject]@{ Role = $Role } }
        Mock -ModuleName AutoPull New-Object -ParameterFilter { $TypeName -eq 'System.Net.WebClient' } {
            $o = [pscustomobject]@{ Headers = New-Object System.Net.WebHeaderCollection }
            $o | Add-Member -MemberType ScriptMethod -Name DownloadFile -Value { param($u, $p) [System.IO.File]::WriteAllBytes($p, [byte[]](1..4)) }
            $o
        }
        $res = @(Invoke-AutoPullRun -ConfigPath $f) | Where-Object { $_ -is [int] } | Select-Object -Last 1
        $res | Should -Be 1
        Should -Invoke -ModuleName AutoPull Deploy-MSIToShare -Times 1 -Exactly -ParameterFilter { $Role -eq 'Teacher' }
        Should -Invoke -ModuleName AutoPull Deploy-MSIToShare -Times 0 -Exactly -ParameterFilter { $Role -eq 'Student' }
    }
}
