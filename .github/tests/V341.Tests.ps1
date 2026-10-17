#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer v3.4.1: Client-Status gegen die MSI-Version in der Freigabe des Tasks,
# Spalten-Griff im Header-Template

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:Root 'Modules\ClientStatus.psm1') -Force -Global -DisableNameChecking
    function New-Row([string]$Role, [string]$Installed, [string]$Target, [string]$Action) {
        [PSCustomObject]@{ ComputerName = 'PC1'; Role = $Role; Installed = $Installed; Target = $Target; LastCheck = '2026-10-17T10:00:00'
                           LastAction = $Action; FileModified = (Get-Date); File = "C:\x\PC1-$Role.json" }
    }
}

Describe 'Update-ClientStatusTarget' {
    It 'nach MSI Pull: alte Meldung "aktuell" wird zu "Update ausstehend", Ziel = Share-Version' {
        $r = @(Update-ClientStatusTarget -Rows @(New-Row 'Student' '2.1.0.3' '2.1.0.3' 'aktuell') -StudentVersion '2.1.2.5' -TeacherVersion '2.1.2.5')
        $r.Count | Should -Be 1
        $r[0].Target | Should -Be '2.1.2.5'
        $r[0].ClientTarget | Should -Be '2.1.0.3'
        $r[0].LastAction | Should -Be 'Update ausstehend'
        $r[0].File | Should -Be 'C:\x\PC1-Student.json'
    }
    It 'Client hat schon gegen die Share-Version geprueft: seine Meldung bleibt' {
        $r = @(Update-ClientStatusTarget -Rows @(New-Row 'Teacher' '2.1.0.3' '2.1.2.5' 'verschoben (laeuft)') -StudentVersion '2.1.2.5' -TeacherVersion '2.1.2.5')
        $r[0].LastAction | Should -Be 'verschoben (laeuft)'
        $r = @(Update-ClientStatusTarget -Rows @(New-Row 'Student' '2.1.2.5' '2.1.2.5' 'installed') -StudentVersion '2.1.2.5')
        $r[0].LastAction | Should -Be 'installed'
    }
    It 'installierte Version bestimmt den Status, wenn der Client die Share-Version noch nicht kennt' {
        (@(Update-ClientStatusTarget -Rows @(New-Row 'Student' '2.1.2.5' '2.1.0.3' 'installed') -StudentVersion '2.1.2.5'))[0].LastAction | Should -Be 'aktuell'
        (@(Update-ClientStatusTarget -Rows @(New-Row 'Student' '2.2.0.0' '2.1.0.3' 'aktuell') -StudentVersion '2.1.2.5'))[0].LastAction | Should -Be 'neuer als Share'
        (@(Update-ClientStatusTarget -Rows @(New-Row 'Student' '' '2.1.0.3' 'error') -StudentVersion '2.1.2.5'))[0].LastAction | Should -Be 'Update ausstehend'
    }
    It 'Rollen getrennt; ohne Share-Version und bei Parse-Fehler-Zeilen bleibt die Zeile unveraendert' {
        $rows = @((New-Row 'Student' '2.1.0.3' '2.1.0.3' 'aktuell'), (New-Row 'Teacher' '2.1.0.3' '2.1.0.3' 'aktuell'), (New-Row '-' '-' '-' 'Parse-Fehler: x'))
        $r = @(Update-ClientStatusTarget -Rows $rows -StudentVersion '2.1.2.5' -TeacherVersion '')
        $r.Count | Should -Be 3
        $r[0].LastAction | Should -Be 'Update ausstehend'
        $r[1].Target | Should -Be '2.1.0.3'
        $r[1].LastAction | Should -Be 'aktuell'
        $r[2].LastAction | Should -Be 'Parse-Fehler: x'
    }
    It 'leere Liste' {
        @(Update-ClientStatusTarget -Rows @() -StudentVersion '2.1.2.5').Count | Should -Be 0
        @(Update-ClientStatusTarget -Rows $null -StudentVersion '2.1.2.5').Count | Should -Be 0
    }
}

Describe 'Listen-Spalten' {
    It 'Header-Template hat den Griff PART_HeaderGripper (Breite ziehen / Doppelklick)' {
        $x = [System.IO.File]::ReadAllText((Join-Path $script:Root 'XAML\MainWindow.xaml'))
        $x | Should -Match 'x:Name="PART_HeaderGripper"'
    }
    It 'Hauptskript passt Spalten nach neuem Inhalt an und prueft Clients gegen die Share-Version' {
        $s = [System.IO.File]::ReadAllText((Join-Path $script:Root 'HU-NextExam-Manager.ps1'))
        $s | Should -Match 'function Update-NEMListColumns'
        $s | Should -Match 'ItemsSourceProperty'
        $s | Should -Match 'Update-ClientStatusTarget -Rows'
    }
}
