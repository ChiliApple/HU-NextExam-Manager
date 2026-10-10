#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer die Korrekturen aus der Code-Pruefung (v3.3.1):
# GPO-Inhalte zusammenfuehren (H3), MSI-Herkunft (H1), Versionsvergleich im Startup-Skript (M1/H2)

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:Root 'Modules\Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\GPOSetup.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Modules\MSIPull.psm1') -Force -DisableNameChecking
    # Funktionen aus dem Startup-Skript (ohne es auszufuehren) laden
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Templates\Startup-NextExam.ps1'), [ref]$tok, [ref]$err)
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('ConvertTo-NEVersion') }, $true)) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

Describe 'GPO: vorhandene Inhalte bleiben erhalten (H3)' {
    It 'CSE-Liste wird ergaenzt, nicht ersetzt, und GUID-sortiert' {
        $reg = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
        $add = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}][{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]'
        $m = Merge-NEMCseList -Existing $reg -Add $add
        $m | Should -Be ('[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]' + $add)
        Merge-NEMCseList -Existing $m -Add $add | Should -Be $m                 # idempotent
        Merge-NEMCseList -Existing '' -Add $add | Should -Be $add
        # gleiche CSE mit weiterem Tool: Tools werden vereinigt
        Merge-NEMCseList -Existing '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{11111111-1111-1111-1111-111111111111}]' -Add '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]' |
            Should -Be '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{11111111-1111-1111-1111-111111111111}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
    }
    It 'scripts.ini: nur der eigene Eintrag verschwindet, andere Skripte bleiben (neu nummeriert)' {
        $ini = "[Startup]`r`n0CmdLine=Startup-NextExam.ps1`r`n0Parameters=-Role Student`r`n1CmdLine=\\srv\s\Drucker.cmd`r`n1Parameters=`r`n`r`n[Shutdown]`r`n0CmdLine=Aus.cmd`r`n0Parameters=/x`r`n"
        $r = Remove-NEMScriptIniEntry -Text $ini
        $r.Kept | Should -Be 2
        $r.Text | Should -Not -Match 'Startup-NextExam'
        $r.Text | Should -Match '(?m)^0CmdLine=\\\\srv\\s\\Drucker\.cmd'
        $r.Text | Should -Match '(?m)^\[Shutdown\]'
        $r.Text | Should -Match '(?m)^0CmdLine=Aus\.cmd'
        (Remove-NEMScriptIniEntry -Text '').Text | Should -Match '^\[Startup\]'
        $cfg = Remove-NEMScriptIniEntry -Text "[ScriptsConfig]`r`nStartExecutePSFirst=true`r`n[Startup]`r`n0CmdLine=Startup-NextExam.ps1`r`n0Parameters=`r`n"
        $cfg.Text | Should -Match '(?m)^StartExecutePSFirst=true'
    }
    It 'ScheduledTasks.xml: nur die eigene Aufgabe wird ersetzt, fremde bleiben' {
        $old = '<?xml version="1.0" encoding="utf-8"?><ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}"><TaskV2 name="Fremd" uid="1"/><TaskV2 name="HU-NextExam-Student-AutoInstall" uid="alt"/></ScheduledTasks>'
        $new = '<?xml version="1.0" encoding="utf-8"?><ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}"><TaskV2 name="HU-NextExam-Student-AutoInstall" uid="neu"/></ScheduledTasks>'
        $m = Merge-NEMScheduledTasksXml -ExistingXml $old -NewXml $new -TaskName 'HU-NextExam-Student-AutoInstall'
        $x = [xml]$m
        @($x.ScheduledTasks.TaskV2).Count | Should -Be 2
        @($x.ScheduledTasks.TaskV2 | Where-Object { $_.name -eq 'Fremd' }).Count | Should -Be 1
        ($x.ScheduledTasks.TaskV2 | Where-Object { $_.name -eq 'HU-NextExam-Student-AutoInstall' }).uid | Should -Be 'neu'
        $m | Should -Match '^<\?xml version="1.0" encoding="utf-8"\?>'
        { Merge-NEMScheduledTasksXml -ExistingXml '<kaputt' -NewXml $new -TaskName 'x' } | Should -Throw '*nicht lesbar*'
        $sa = Merge-NEMScheduledTasksXml -ExistingXml ($old -replace 'encoding="utf-8"', 'encoding="utf-8" standalone="yes"') -NewXml $new -TaskName 'HU-NextExam-Student-AutoInstall'
        $sa | Should -Match '^\uFEFF?<\?xml version="1.0" encoding="utf-8"'
    }
}

Describe 'MSI-Herkunft (H1)' {
    It 'unsignierte Datei wird nicht verteilt' {
        $f = Join-Path $TestDrive 'Next-Exam-Student_1.0.0.0_20260101_x64.msi'; [System.IO.File]::WriteAllBytes($f, [byte[]](1..64))
        { Test-NextExamMsiTrust -Path $f } | Should -Throw '*Signatur ungueltig*'
        { Deploy-MSIToShare -SourceMSI $f -SharePath (Join-Path $TestDrive 'share') -Role Student -Version '1.0.0.0' -BuildDate '20260101' -FileName 'x.msi' } | Should -Throw '*Signatur*'
        Test-Path (Join-Path $TestDrive 'share') | Should -BeFalse   # Freigabe unberuehrt
    }
    It 'falsche Pruefsumme wird vor der Signatur erkannt' {
        $f = Join-Path $TestDrive 'a.msi'; [System.IO.File]::WriteAllBytes($f, [byte[]](1..64))
        { Test-NextExamMsiTrust -Path $f -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA256*'
    }
    It 'ohne eingestellten Herausgeber wird nichts verteilt' {
        # Signatur ist hier ohnehin ungueltig - die Pruefreihenfolge stellt sicher, dass nie ohne Herausgeber verteilt wird
        $f = Join-Path $TestDrive 'b.msi'; [System.IO.File]::WriteAllBytes($f, [byte[]](1..64))
        { Test-NextExamMsiTrust -Path $f -TrustedPublisher '' } | Should -Throw
    }
}

Describe 'Startup-Skript: Versionsvergleich (M1)' {
    It 'vergleicht numerisch statt per Praefix' {
        (ConvertTo-NEVersion '1.2.30.0') -gt (ConvertTo-NEVersion '1.2.3.0') | Should -BeTrue
        (ConvertTo-NEVersion '1.2.3.10') -gt (ConvertTo-NEVersion '1.2.3.9') | Should -BeTrue
        (ConvertTo-NEVersion 'v2.1.0.3') -eq (ConvertTo-NEVersion '2.1.0.3') | Should -BeTrue
        (ConvertTo-NEVersion '1.1.3') -eq (ConvertTo-NEVersion '1.1.3.0') | Should -BeTrue   # dreiteilige DisplayVersion
        ConvertTo-NEVersion '' | Should -BeNullOrEmpty
        ConvertTo-NEVersion 'abc' | Should -BeNullOrEmpty
    }
    It 'Startup-Skript ist reines ASCII (PS 5.1 liest es ohne BOM als ANSI)' {
        $b = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'Templates\Startup-NextExam.ps1'))
        @($b | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
