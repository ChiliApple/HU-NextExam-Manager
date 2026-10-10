#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer Modules\Protect.psm1: Schutz des Programmordners, Versionsdatei, Einzelinstanz-Sperre
# Vorlage: HUMig .github\tests\HUMig.Tests.ps1 (Describe "Schutz von ProgramData\HUMig")

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:Root 'Modules\Protect.psm1') -Force -DisableNameChecking
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    function Get-NEMTestAcl([string]$Path) {
        $a = [System.IO.Directory]::GetAccessControl($Path)
        [pscustomobject]@{
            Protected = $a.AreAccessRulesProtected
            Owner = $a.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            Rules = @($a.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" } | Sort-Object)
        }
    }
}

Describe 'Programmordner: wann wird abgesichert' {
    It 'nicht auf Netzlaufwerken, Laufwerkswurzeln und in Benutzerprofilen' {
        Get-NEMAppDirSkipReason '\\server\share\HU-NextExam-Manager' | Should -Match 'UNC'
        Get-NEMAppDirSkipReason "$env:SystemDrive\" | Should -Match 'Laufwerkswurzel'
        Get-NEMAppDirSkipReason (Join-Path $env:USERPROFILE 'Desktop\HU-NextExam-Manager') | Should -Match 'Benutzerprofil'
        Get-NEMAppDirSkipReason '' | Should -Not -BeNullOrEmpty
    }
    It 'ein Ordner wie C:\Tools\HU-NextExam-Manager wird abgesichert' {
        Get-NEMAppDirSkipReason "$env:SystemDrive\Tools\HU-NextExam-Manager" | Should -BeNullOrEmpty
    }
}

Describe 'Programmordner absichern (Protect-NEMAppDir)' {
    It 'Benutzer duerfen anlegen (wie C:\Tools von C:\ erbt) -> danach nur Lesen, Besitzer Administratoren' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $r = Join-Path $TestDrive 'app1'
        New-Item -ItemType Directory -Path (Join-Path $r 'Modules') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'Modules\Config.psm1') -Value 'x'
        $null = & icacls.exe $r /inheritance:d
        $null = & icacls.exe $r /grant '*S-1-5-32-545:(CI)(S,WD)' '*S-1-5-32-545:(CI)(S,AD)' '*S-1-5-32-545:(OI)(CI)(RX)'
        @(Get-NEMAppDirIssues $r).Count | Should -BeGreaterThan 0
        Protect-NEMAppDir -Root $r | Should -Match 'abgesichert'
        $a = Get-NEMTestAcl $r
        $a.Protected | Should -BeTrue
        $a.Owner | Should -Be 'S-1-5-32-544'
        ($a.Rules -join ';') | Should -Be 'S-1-5-18=FullControl;S-1-5-32-544=FullControl;S-1-5-32-545=ReadAndExecute, Synchronize'
        @(Get-NEMAppDirIssues $r).Count | Should -Be 0
        Protect-NEMAppDir -Root $r | Should -BeNullOrEmpty   # zweiter Aufruf: schon geschuetzt, nichts zu tun
        Test-Path -LiteralPath (Join-Path $r 'Modules\Config.psm1') | Should -BeTrue
    }
    It 'entfernt Verknuepfungen nur als Link (Ziel bleibt) und setzt eigene Rechte im Inhalt zurueck' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $r = Join-Path $TestDrive 'app2'
        $outside = Join-Path $TestDrive 'aussen2'; New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'wichtig.txt') -Value 'bleibt'
        New-Item -ItemType Directory -Path (Join-Path $r 'Templates') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'Templates\Startup-NextExam.ps1') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $r 'Link') -Target $outside | Out-Null
        $null = & icacls.exe (Join-Path $r 'Templates') /grant '*S-1-5-32-545:(OI)(CI)M'
        Protect-NEMAppDir -Root $r | Should -Match 'abgesichert'
        Test-Path -LiteralPath (Join-Path $r 'Link') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'wichtig.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $r 'Templates\Startup-NextExam.ps1') | Should -BeTrue
        $s = Get-NEMTestAcl (Join-Path $r 'Templates')
        $s.Protected | Should -BeFalse
        @($s.Rules).Count | Should -Be 0
        $s.Owner | Should -Be 'S-1-5-32-544'
    }
    It 'erkennt eine vom Benutzer angelegte update.json (fremder Besitzer)' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $r = Join-Path $TestDrive 'app3'
        New-Item -ItemType Directory -Path $r -Force | Out-Null
        $f = Join-Path $r 'update.json'; Set-Content -LiteralPath $f -Value '{ "AllowUnsigned": true }'
        $null = & icacls.exe $f /setowner '*S-1-5-32-545'
        $null = & icacls.exe $r /inheritance:d /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
        (@(Get-NEMAppDirIssues $r) -join ';') | Should -Match 'Besitzer'
        Protect-NEMAppDir -Root $r | Should -Match 'abgesichert'
        ([System.IO.File]::GetAccessControl($f)).GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
    }
    It 'ohne Administratorrechte: nur pruefen, nicht absichern' {
        if ($script:IsAdmin) { Set-ItResult -Skipped -Because 'laeuft als Administrator'; return }
        $r = Join-Path $TestDrive 'app4'; New-Item -ItemType Directory -Path $r -Force | Out-Null
        (Invoke-NEMAppDirProtection -Root $r).Status | Should -BeIn @('Skipped', 'Ok', 'Unsafe')
    }
}

Describe 'Version und Einzelinstanz' {
    It 'liest die Version aus Config\version.json' {
        Get-NEMToolVersion $script:Root | Should -Match '^\d+\.\d+\.\d+$'
        $d = Join-Path $TestDrive 'nover'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Get-NEMToolVersion $d | Should -Be '0.0.0'
    }
    It 'Config\version.json passt zum neuesten Abschnitt in Docs\CHANGELOG.md' {
        $v = Get-NEMToolVersion $script:Root
        $first = @(Get-Content (Join-Path $script:Root 'Docs\CHANGELOG.md') -Encoding UTF8 | Where-Object { $_ -match '^## v\d' })[0]
        $first | Should -Match ('^## v' + [regex]::Escape($v) + '\b')
    }
    It 'Sperre je Programmordner (gleicher Ordner = gleicher Name, Gross/Klein egal)' {
        Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager' | Should -Be (Get-NEMMutexName 'c:\tools\hu-nextexam-manager\')
        Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager' | Should -Not -Be (Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager-2')
        Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager' 'AutoPull' | Should -Not -Be (Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager' 'App')
        Get-NEMMutexName 'C:\Tools\HU-NextExam-Manager' | Should -Match '^Global\\HU-NextExam-Manager_App_[0-9a-f]{16}$'
    }
}
