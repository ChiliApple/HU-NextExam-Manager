#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer die Update-Bibliothek (Modules\Update.psm1) - laufen bei jedem Push auf GitHub (Windows PowerShell 5.1)
# Vorlage: HUMig .github\tests\HUMig.Tests.ps1

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:Root 'Modules\Update.psm1') -Force -DisableNameChecking
    function New-HMRel($Tag, $Pre, $Assets = @(), $Draft = $false) {
        [pscustomobject]@{ tag_name = $Tag; prerelease = $Pre; draft = $Draft; published_at = '2026-10-01T08:00:00Z'; body = "Notiz $Tag"; assets = $Assets }
    }
}

Describe 'Update: Versionen und Kanal' {
    It 'erkennt Versionen aus Tags' {
        "$(ConvertTo-HMVersion 'v2.0.53')" | Should -Be '2.0.53'
        "$(ConvertTo-HMVersion '2.0.9')" | Should -Be '2.0.9'
        ConvertTo-HMVersion 'backup-20260101' | Should -BeNullOrEmpty
    }
    It 'sortiert numerisch (2.0.10 > 2.0.9) und ignoriert Entwuerfe' {
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.9' $false), (New-HMRel 'v2.0.10' $false), (New-HMRel 'v2.0.99' $false @() $true), (New-HMRel 'backup-x' $false))
        @($l).Count | Should -Be 2
        "$($l[0].Version)" | Should -Be '2.0.10'
    }
    It 'Kanal Stabil nimmt nur freigegebene, Test auch Vorab-Releases' {
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.54' $true), (New-HMRel 'v2.0.53' $false))
        (Select-HMRelease $l 'Stable').Tag | Should -Be 'v2.0.53'
        (Select-HMRelease $l 'Test').Tag | Should -Be 'v2.0.54'
        Select-HMRelease @() 'Stable' | Should -BeNullOrEmpty
    }
    It 'Signaturpflicht: nur Releases mit Pruefsumme und Signatur' {
        $m = [pscustomobject]@{ name = 'HU-NextExam-Manager-files.sha256'; browser_download_url = 'https://x/m'; url = 'https://api/m' }
        $s = [pscustomobject]@{ name = 'HU-NextExam-Manager-files.sha256.p7s'; browser_download_url = 'https://x/s'; url = 'https://api/s' }
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.56' $false @($m)), (New-HMRel 'v2.0.55' $false @($m, $s)), (New-HMRel 'v2.0.54' $false @($s)))
        (Select-HMRelease $l 'Stable' -SignedOnly).Tag | Should -Be 'v2.0.55'
        (Select-HMRelease $l 'Stable').Tag | Should -Be 'v2.0.56'
        Select-HMRelease @(ConvertTo-HMReleaseList @(New-HMRel 'v2.0.56' $false @($m))) 'Test' -SignedOnly | Should -BeNullOrEmpty
    }
    It 'findet Pruefsummen- und Signatur-Datei im Release' {
        $a = @([pscustomobject]@{ name = 'HU-NextExam-Manager-files.sha256'; browser_download_url = 'https://x/m'; url = 'https://api/m' }, [pscustomobject]@{ name = 'HU-NextExam-Manager-files.sha256.p7s'; browser_download_url = 'https://x/s'; url = 'https://api/s' })
        $r = @(ConvertTo-HMReleaseList @(New-HMRel 'v2.0.53' $false $a))[0]
        $r.ManifestUrl | Should -Be 'https://x/m'
        $r.SignatureApi | Should -Be 'https://api/s'
    }
    It 'liest update.json (Standard: offizielle Quelle, Kanal Stabil, nur signiert)' {
        $d = Join-Path $TestDrive 'cfg1'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $c = Get-HMUpdateConfig $d
        $c.Channel | Should -Be 'Stable'; $c.Owner | Should -Be 'ChiliApple'
        $c.RequireSignature | Should -BeTrue; $c.DefaultSigner | Should -BeTrue; $c.SignerThumbprint | Should -Match '^[0-9A-F]{40}$'
        Set-Content (Join-Path $d 'update.json') '{"Channel":"Test","UseBranch":true}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.Channel | Should -Be 'Test'; $c.RequireSignature | Should -BeTrue; $c.UseBranch | Should -BeFalse
        Set-Content (Join-Path $d 'update.json') '{"AllowUnsigned":true,"UseBranch":true}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeFalse; $c.UseBranch | Should -BeTrue
        Set-Content (Join-Path $d 'update.json') '{"Owner":"Schule","Repo":"Eigen"}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeFalse; $c.SignerThumbprint | Should -Be ''
        Set-Content (Join-Path $d 'update.json') '{"Owner":"Schule","Repo":"Eigen","SignerThumbprint":"ab:cd ef"}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeTrue; $c.SignerThumbprint | Should -Be 'ABCDEF'; $c.DefaultSigner | Should -BeFalse
    }
}

Describe 'Update: Pruefsumme und Signatur' {
    It 'liest die Pruefsummen-Datei (sha256sum-Format)' {
        $m = ConvertFrom-HMManifest (('a' * 64) + "  Functions/X.ps1`n" + ('B' * 64) + " *Docs/a b.html`r`nkaputt")
        $m.Count | Should -Be 2
        $m['Docs/a b.html'] | Should -Be ('b' * 64)
    }
    It 'berechnet SHA256 wie Get-FileHash' {
        $f = Join-Path $TestDrive 'h.bin'; [System.IO.File]::WriteAllBytes($f, [byte[]](1..200))
        Get-HMFileSha256 $f | Should -Be (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    }
    It 'prueft die Signatur (gueltig / anderes Zertifikat / veraendert / fehlt)' {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $cert = $null; $fromStore = $false
        try {
            if (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue) {
                $cert = New-SelfSignedCertificate -Subject 'CN=HU-NextExam-Manager CI Test' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
                $fromStore = $true
            } else {
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN=HU-NextExam-Manager CI Test', $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $cert = $req.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddDays(1))
            }
            $man = [System.Text.Encoding]::UTF8.GetBytes(('a' * 64) + "  HU-NextExam-Manager.ps1`n")
            $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$man)
            $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
            $cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner -ArgumentList $cert), $true)
            $sig = $cms.Encode()
            Test-HMManifestSignature $man $sig $cert.Thumbprint | Should -BeNullOrEmpty
            Test-HMManifestSignature $man $sig ('0' * 40) | Should -Match 'anderen Zertifikat'
            $man2 = [System.Text.Encoding]::UTF8.GetBytes(('b' * 64) + "  HU-NextExam-Manager.ps1`n")
            Test-HMManifestSignature $man2 $sig $cert.Thumbprint | Should -Match 'ungueltig'
            Test-HMManifestSignature $man $null $cert.Thumbprint | Should -Match 'keine Signatur'
            Test-HMManifestSignature $man $sig '' | Should -Match 'Fingerabdruck'
            # Signieren wie im Tool (Release signieren)
            $sig2 = New-HMManifestSignature $man $cert
            Test-HMManifestSignature $man $sig2 $cert.Thumbprint | Should -BeNullOrEmpty
            if ($fromStore) { (Get-HMSigningCert $cert.Thumbprint).Thumbprint | Should -Be $cert.Thumbprint }
            Get-HMSigningCert ('0' * 40) | Should -BeNullOrEmpty
        } finally { if ($fromStore -and $cert) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue } }
    }
}

Describe 'Update: Konfig-Umstieg' {
    It 'ignoriert das alte Feld RequireSignature (Bestandsinstallationen bleiben geschuetzt)' {
        $d = Join-Path $TestDrive 'cfg2'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content (Join-Path $d 'update.json') '{"RequireSignature":false}' -Encoding UTF8
        (Get-HMUpdateConfig $d).RequireSignature | Should -BeTrue
    }
    It 'eingebaute Quelle und Fingerabdruck stimmen' {
        Get-HMDefaultSigner 'ChiliApple' 'HU-NextExam-Manager' | Should -Be '1B669AE240DA1A91043C4576763D9F8E0BF762FA'
        Get-HMDefaultSigner 'ChiliApple' 'HUMig' | Should -Be ''
    }
}
