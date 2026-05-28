#Requires -Version 5.1
<#
.SYNOPSIS
    MDM/Intune-Modul fuer HU-NextExam-Manager.
    Win32-App-Upload, Content-Version-Update, Zuweisungen via Microsoft Graph API (beta).
.DESCRIPTION
    Unterstuetzt zwei Auth-Modi:
      A) Client Credentials Flow (Service Principal, DPAPI-verschluesselt)
      B) Device Code Flow (interaktiver Admin-Login, Session-basiert)
    Verschluesselt MSI → .intunewin-Format (AES-256-CBC), uploaded via Azure Blob,
    committed ueber Graph API.
.NOTES
    PS 5.1 kompatibel. Keine externen Module noetig.
    Nutzt Write-Log aus Logging.psm1 (muss vorher geladen sein).
#>

Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

#region ===== Konstanten =====

$script:GraphBaseUrl   = 'https://graph.microsoft.com/beta'
$script:GraphV1Url     = 'https://graph.microsoft.com/v1.0'
$script:LoginBaseUrl   = 'https://login.microsoftonline.com'
$script:GraphScope     = 'https://graph.microsoft.com/.default'
$script:DelegatedScope = 'DeviceManagementApps.ReadWrite.All Group.Read.All offline_access'
$script:SetupScope     = 'Application.ReadWrite.All AppRoleAssignment.ReadWrite.All DelegatedPermissionGrant.ReadWrite.All offline_access'
$script:CredBasePath   = Join-Path $env:APPDATA 'HU-NextExam'
$script:ChunkSize      = 6 * 1024 * 1024   # 6 MB Azure Blob Block-Groesse
$script:PollInterval   = 5                   # Sekunden zwischen Upload-State-Polls
$script:PollMaxRetries = 60                  # Max ~5 Minuten warten

# Well-Known Client ID fuer Device Code Flow (Microsoft Graph PowerShell analog)
# Wir verwenden die eigene App-Registration auch fuer Device Code (public client flow).
# Falls keine App-Reg vorhanden → diese Microsoft-eigene Public Client ID nutzen:
$script:FallbackPublicClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # Microsoft Graph CLI

#endregion

#region ===== DPAPI Credential Store =====

function Save-MDMCredential {
    <#
    .SYNOPSIS
        Speichert TenantId, ClientId + ClientSecret DPAPI-verschluesselt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )
    if (-not (Test-Path $script:CredBasePath)) {
        New-Item -ItemType Directory -Path $script:CredBasePath -Force | Out-Null
    }
    $obj = @{
        TenantId = $TenantId
        ClientId = $ClientId
    }
    # DPAPI-Verschluesselung des Secrets (CurrentUser-Scope)
    $secretBytes = [System.Text.Encoding]::UTF8.GetBytes($ClientSecret)
    $encBytes    = [System.Security.Cryptography.ProtectedData]::Protect(
        $secretBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $obj['SecretEnc'] = [Convert]::ToBase64String($encBytes)

    $path = Join-Path $script:CredBasePath "mdm_$TenantId.cred"
    $obj | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8 -Force
    Write-Log "MDM-Credentials gespeichert: $path" -Level INFO -Source 'MDM'
    return $path
}

function Load-MDMCredential {
    <#
    .SYNOPSIS
        Laedt DPAPI-verschluesselte MDM-Credentials fuer einen Tenant.
    .OUTPUTS
        PSCustomObject mit TenantId, ClientId, ClientSecret (entschluesselt) oder $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)

    $path = Join-Path $script:CredBasePath "mdm_$TenantId.cred"
    if (-not (Test-Path $path)) {
        Write-Log "Keine MDM-Credentials gefunden: $path" -Level WARN -Source 'MDM'
        return $null
    }
    try {
        $obj = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $encBytes    = [Convert]::FromBase64String($obj.SecretEnc)
        $secretBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $secret = [System.Text.Encoding]::UTF8.GetString($secretBytes)
        return [PSCustomObject]@{
            TenantId     = $obj.TenantId
            ClientId     = $obj.ClientId
            ClientSecret = $secret
        }
    } catch {
        Write-Log "MDM-Credentials entschluesseln fehlgeschlagen ($path): $_" -Level ERROR -Source 'MDM'
        return $null
    }
}

function Test-MDMCredentialExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    $path = Join-Path $script:CredBasePath "mdm_$TenantId.cred"
    return (Test-Path $path)
}

function Remove-MDMCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    $path = Join-Path $script:CredBasePath "mdm_$TenantId.cred"
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
        Write-Log "MDM-Credentials entfernt: $path" -Level INFO -Source 'MDM'
    }
}

#endregion

#region ===== Auth: Token-Abruf =====

function Get-MDMTokenClientCredentials {
    <#
    .SYNOPSIS
        OAuth2 Client Credentials Flow — Service Principal Token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )
    $uri  = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $script:GraphScope
    }
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        Write-Log "Client-Credentials-Token erhalten (Tenant: $TenantId)" -Level INFO -Source 'MDM'
        return [PSCustomObject]@{
            AccessToken = $resp.access_token
            ExpiresIn   = $resp.expires_in
            TokenType   = $resp.token_type
            ObtainedAt  = (Get-Date)
        }
    } catch {
        $msg = "Client-Credentials-Token fehlgeschlagen (Tenant: $TenantId): $_"
        Write-Log $msg -Level ERROR -Source 'MDM'
        throw $msg
    }
}

function Get-MDMTokenDeviceCode {
    <#
    .SYNOPSIS
        OAuth2 Device Code Flow — interaktiver Admin-Login.
    .PARAMETER ClientId
        App-Registration ClientId. Falls leer, wird die eigene App-Reg des Tenants aus den Credentials geladen.
    .PARAMETER OnDeviceCode
        ScriptBlock der aufgerufen wird wenn der User den Code eingeben muss.
        Erhaelt Parameter: $UserCode, $VerificationUri, $Message
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string]$ClientId,
        [scriptblock]$OnDeviceCode
    )
    # Falls keine ClientId angegeben: aus gespeicherten Credentials laden oder Fallback
    if (-not $ClientId) {
        $cred = Load-MDMCredential -TenantId $TenantId
        if ($cred) {
            $ClientId = $cred.ClientId
        } else {
            $ClientId = $script:FallbackPublicClientId
            Write-Log "Keine App-Reg fuer Tenant $TenantId - verwende Fallback-ClientId" -Level WARN -Source 'MDM'
        }
    }

    # Phase 1: Device Code anfordern
    $uri  = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/devicecode"
    $body = @{
        client_id = $ClientId
        scope     = $script:DelegatedScope
    }
    try {
        $dcResp = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        throw "Device-Code-Anforderung fehlgeschlagen: $_"
    }

    # Callback: Code dem UI/User zeigen
    if ($OnDeviceCode) {
        & $OnDeviceCode $dcResp.user_code $dcResp.verification_uri $dcResp.message
    } else {
        Write-Host $dcResp.message -ForegroundColor Cyan
    }

    # Phase 2: Polling bis User angemeldet
    $tokenUri = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/token"
    $interval = $dcResp.interval
    if (-not $interval -or $interval -lt 1) { $interval = 5 }
    $expires  = (Get-Date).AddSeconds($dcResp.expires_in)

    while ((Get-Date) -lt $expires) {
        Start-Sleep -Seconds $interval
        $pollBody = @{
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            client_id   = $ClientId
            device_code = $dcResp.device_code
        }
        try {
            $resp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $pollBody `
                        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            Write-Log "Device-Code-Token erhalten (Tenant: $TenantId)" -Level INFO -Source 'MDM'
            return [PSCustomObject]@{
                AccessToken = $resp.access_token
                ExpiresIn   = $resp.expires_in
                TokenType   = $resp.token_type
                ObtainedAt  = (Get-Date)
            }
        } catch {
            $err = $_.ErrorDetails.Message
            if ($err) {
                try { $errObj = $err | ConvertFrom-Json } catch { $errObj = $null }
                if ($errObj -and $errObj.error -eq 'authorization_pending') { continue }
                if ($errObj -and $errObj.error -eq 'slow_down') { $interval += 5; continue }
                if ($errObj -and $errObj.error -eq 'authorization_declined') {
                    throw "Admin hat Anmeldung abgelehnt."
                }
                if ($errObj -and $errObj.error -eq 'expired_token') {
                    throw "Device-Code abgelaufen. Bitte erneut versuchen."
                }
            }
            # Unbekannter Fehler beim Polling - weiter versuchen
        }
    }
    throw "Device-Code abgelaufen (Timeout)."
}


#region --- Auth Code Flow (Browser-Redirect auf localhost) ---

function Start-MDMAuthCodeListener {
    <#
    .SYNOPSIS
        Startet HttpListener auf zufaelligem localhost-Port, oeffnet Browser fuer OAuth2 Auth Code Flow.
    .OUTPUTS
        PSCustomObject mit Listener, AsyncResult, RedirectUri, TenantId, ClientId, State, CodeVerifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string]$ClientId
    )
    # ClientId ermitteln
    if (-not $ClientId) {
        $cred = Load-MDMCredential -TenantId $TenantId
        if ($cred) {
            $ClientId = $cred.ClientId
        } else {
            $ClientId = $script:FallbackPublicClientId
            Write-Log "Keine App-Reg fuer Tenant $TenantId - verwende Fallback-ClientId" -Level WARN -Source 'MDM'
        }
    }

    # Zufaelligen Port waehlen (49152-65535)
    $port = Get-Random -Minimum 49152 -Maximum 65536
    $redirectUri = "http://localhost:$port/"

    # PKCE: code_verifier + code_challenge (S256)
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $verifierBytes = New-Object byte[] 32
    $rng.GetBytes($verifierBytes)
    $codeVerifier = [Convert]::ToBase64String($verifierBytes) -replace '\+','-' -replace '/','_' -replace '='
    $rng.Dispose()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $challengeBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeBytes) -replace '\+','-' -replace '/','_' -replace '='
    $sha256.Dispose()

    # CSRF State
    $state = [Guid]::NewGuid().ToString('N')

    # HttpListener starten
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($redirectUri)
    try {
        $listener.Start()
    } catch {
        throw "HttpListener konnte nicht auf Port $port starten: $_"
    }

    # Async Accept starten (non-blocking)
    $asyncResult = $listener.BeginGetContext($null, $null)

    # Browser oeffnen
    $scopes = [Uri]::EscapeDataString($script:DelegatedScope)
    $authUrl = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/authorize?" +
        "client_id=$ClientId" +
        "&response_type=code" +
        "&redirect_uri=$([Uri]::EscapeDataString($redirectUri))" +
        "&response_mode=query" +
        "&scope=$scopes" +
        "&state=$state" +
        "&code_challenge=$codeChallenge" +
        "&code_challenge_method=S256" +
        "&prompt=select_account"

    try { Start-Process $authUrl } catch {
        Write-Log "Browser konnte nicht geoeffnet werden: $_" -Level WARN -Source 'MDM'
    }

    Write-Log "Auth Code Listener gestartet auf $redirectUri (Tenant: $TenantId)" -Level INFO -Source 'MDM'

    return [PSCustomObject]@{
        Listener     = $listener
        AsyncResult  = $asyncResult
        RedirectUri  = $redirectUri
        TenantId     = $TenantId
        ClientId     = $ClientId
        State        = $state
        CodeVerifier = $codeVerifier
        Port         = $port
    }
}

function Poll-MDMAuthCodeOnce {
    <#
    .SYNOPSIS
        Non-blocking Check ob der Browser-Callback eingegangen ist.
    .OUTPUTS
        PSCustomObject: Code (auth code string oder $null), Error ($null oder Fehlermeldung).
        Code=$null + Error=$null = noch wartend.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$ListenerContext
    )
    $result = [PSCustomObject]@{ Code = $null; Error = $null }

    if (-not $ListenerContext.AsyncResult.IsCompleted) {
        return $result   # Noch wartend
    }

    try {
        $ctx = $ListenerContext.Listener.EndGetContext($ListenerContext.AsyncResult)
        $query = $ctx.Request.QueryString

        # Antwort an Browser senden
        $responseHtml = '<html><body style="font-family:Segoe UI;text-align:center;margin-top:80px">' +
            '<h2>Anmeldung erfolgreich</h2><p>Dieses Fenster kann geschlossen werden.</p></body></html>'
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseHtml)
        $ctx.Response.ContentLength64 = $buffer.Length
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $ctx.Response.OutputStream.Close()

        # Error Check
        if ($query['error']) {
            $result.Error = "OAuth Fehler: $($query['error']) - $($query['error_description'])"
            return $result
        }

        # State pruefen (CSRF)
        if ($query['state'] -ne $ListenerContext.State) {
            $result.Error = "State-Mismatch (CSRF-Schutz). Erwartet: $($ListenerContext.State), Erhalten: $($query['state'])"
            return $result
        }

        $code = $query['code']
        if (-not $code) {
            $result.Error = 'Kein Authorization Code in der Antwort.'
            return $result
        }

        $result.Code = $code
    } catch {
        $result.Error = "Callback-Verarbeitung fehlgeschlagen: $_"
    }

    return $result
}

function Stop-MDMAuthCodeListener {
    <#
    .SYNOPSIS
        Stoppt und schliesst den HttpListener sauber.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$ListenerContext)
    try {
        if ($ListenerContext.Listener -and $ListenerContext.Listener.IsListening) {
            $ListenerContext.Listener.Stop()
        }
        if ($ListenerContext.Listener) {
            $ListenerContext.Listener.Close()
        }
    } catch {
        Write-Log "HttpListener Cleanup-Fehler: $_" -Level WARN -Source 'MDM'
    }
}

function Get-MDMTokenAuthCode {
    <#
    .SYNOPSIS
        Tauscht Authorization Code gegen Access Token (PKCE).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$AuthCode,
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$CodeVerifier
    )
    $uri  = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'authorization_code'
        client_id     = $ClientId
        code          = $AuthCode
        redirect_uri  = $RedirectUri
        code_verifier = $CodeVerifier
        scope         = $script:DelegatedScope
    }
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
                    -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        Write-Log "Auth-Code-Token erhalten (Tenant: $TenantId)" -Level INFO -Source 'MDM'
        return [PSCustomObject]@{
            AccessToken = $resp.access_token
            ExpiresIn   = $resp.expires_in
            TokenType   = $resp.token_type
            ObtainedAt  = (Get-Date)
        }
    } catch {
        $msg = "Auth-Code-Token-Austausch fehlgeschlagen (Tenant: $TenantId): $_"
        Write-Log $msg -Level ERROR -Source 'MDM'
        throw $msg
    }
}

#endregion

function Get-MDMToken {
    <#
    .SYNOPSIS
        Dispatcher: holt Token je nach Modus.
    .PARAMETER Mode
        'AppCredentials', 'DeviceCode' oder 'AuthCode'
    .NOTES
        Bei AuthCode wird synchron Token geholt (Code muss bereits vorliegen).
        Fuer den async Browser-Flow: Start-MDMAuthCodeListener + Poll-MDMAuthCodeOnce + Get-MDMTokenAuthCode
        direkt im EventHandler verwenden.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][ValidateSet('AppCredentials','DeviceCode','AuthCode')][string]$Mode,
        [scriptblock]$OnDeviceCode,
        [string]$AuthCode,
        [string]$RedirectUri,
        [string]$CodeVerifier,
        [string]$ClientId
    )
    switch ($Mode) {
        'AppCredentials' {
            $cred = Load-MDMCredential -TenantId $TenantId
            if (-not $cred) { throw "Keine MDM-Credentials fuer Tenant $TenantId hinterlegt." }
            return Get-MDMTokenClientCredentials -TenantId $cred.TenantId -ClientId $cred.ClientId -ClientSecret $cred.ClientSecret
        }
        'DeviceCode' {
            return Get-MDMTokenDeviceCode -TenantId $TenantId -OnDeviceCode $OnDeviceCode
        }
        'AuthCode' {
            if (-not $AuthCode) { throw "AuthCode-Parameter fehlt fuer Auth Code Flow." }
            if (-not $ClientId) {
                $cred = Load-MDMCredential -TenantId $TenantId
                if ($cred) { $ClientId = $cred.ClientId } else { $ClientId = $script:FallbackPublicClientId }
            }
            return Get-MDMTokenAuthCode -TenantId $TenantId -ClientId $ClientId `
                -AuthCode $AuthCode -RedirectUri $RedirectUri -CodeVerifier $CodeVerifier
        }
    }
}

#endregion

#region ===== Graph API Helper =====

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Graph-API-Aufruf mit Token, Retry-Logik und Error-Handling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [object]$Body,
        [string]$ContentType = 'application/json',
        [int]$MaxRetries = 3
    )
    $headers = @{
        Authorization = "Bearer $AccessToken"
    }
    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $headers
        ContentType = $ContentType
        ErrorAction = 'Stop'
    }
    if ($Body) {
        if ($Body -is [string]) {
            $params['Body'] = $Body
        } else {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ($Method -eq 'DELETE') {
                $null = Invoke-WebRequest @params -UseBasicParsing
                return $null
            }
            return Invoke-RestMethod @params
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            # 429 Too Many Requests oder 503/504 → Retry
            if ($statusCode -in @(429, 503, 504) -and $attempt -lt $MaxRetries) {
                $wait = 5 * $attempt
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) {
                    $ra = $_.Exception.Response.Headers['Retry-After']
                    if ($ra -match '^\d+$') { $wait = [int]$ra }
                }
                Write-Log "Graph-API HTTP $statusCode - Retry in ${wait}s (Versuch $attempt/$MaxRetries)" -Level WARN -Source 'MDM'
                Start-Sleep -Seconds $wait
                continue
            }
            # Fehlerdetails extrahieren
            $errBody = ''
            try {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errBody = $sr.ReadToEnd(); $sr.Close()
            } catch {}
            $msg = "Graph-API $Method $Uri -> HTTP $statusCode"
            if ($errBody) { $msg += ": $errBody" }
            Write-Log $msg -Level ERROR -Source 'MDM'
            throw $msg
        }
    }
}

#endregion

#region ===== IntuneWin Packaging (via MS Win32 Content Prep Tool) =====

$script:IntuneWinToolName = 'IntuneWinAppUtil.exe'

function Get-IntuneWinAppUtil {
    <#
    .SYNOPSIS
        Stellt sicher dass IntuneWinAppUtil.exe verfuegbar ist. Laedt bei Bedarf herunter.
    .OUTPUTS
        Pfad zur IntuneWinAppUtil.exe
    #>
    [CmdletBinding()]
    param()
    # 1. Im Tools-Ordner neben dem Modul suchen
    $modulePath = $PSScriptRoot
    $toolsDir = Join-Path (Split-Path $modulePath -Parent) 'Tools'
    $exePath  = Join-Path $toolsDir $script:IntuneWinToolName

    if (Test-Path $exePath) {
        Write-Log "IntuneWinAppUtil.exe gefunden: $exePath" -Level DEBUG -Source 'MDM'
        return $exePath
    }

    # 2. Herunterladen von GitHub (Microsoft offizielles Repo)
    Write-Log "IntuneWinAppUtil.exe nicht gefunden - lade von GitHub..." -Level INFO -Source 'MDM'
    if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

    $downloadUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'HU-NextExam-Manager')
        $wc.DownloadFile($downloadUrl, $exePath)
        $wc.Dispose()
        Write-Log "IntuneWinAppUtil.exe heruntergeladen: $exePath ($((Get-Item $exePath).Length) Bytes)" -Level INFO -Source 'MDM'
        return $exePath
    } catch {
        throw "IntuneWinAppUtil.exe konnte nicht heruntergeladen werden: $_"
    }
}

function Protect-IntuneWinFile {
    <#
    .SYNOPSIS
        Erzeugt .intunewin-Paket via Microsoft Win32 Content Prep Tool.
    .DESCRIPTION
        1. IntuneWinAppUtil.exe ausfuehren -> erzeugt .intunewin (ZIP mit verschluesseltem Content + Detection.xml)
        2. Detection.xml parsen -> EncryptionInfo extrahieren
        3. Verschluesselte Datei (IntunePackage.intunewin) + Metadaten zurueckgeben
    .OUTPUTS
        PSCustomObject: EncryptedFilePath, EncryptionInfo, OriginalSize, EncryptedSize
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-Path $SourceFile)) { throw "Quelldatei nicht gefunden: $SourceFile" }

    $toolExe = Get-IntuneWinAppUtil
    $fileName = [System.IO.Path]::GetFileName($SourceFile)
    $sourceDir = [System.IO.Path]::GetDirectoryName($SourceFile)
    $originalSize = (Get-Item $SourceFile).Length

    Write-Log "Erstelle .intunewin fuer $fileName ($originalSize Bytes)..." -Level INFO -Source 'MDM'

    # IntuneWinAppUtil.exe ausfuehren
    $intunewinDir = Join-Path $OutputDirectory 'intunewin_output'
    if (-not (Test-Path $intunewinDir)) { New-Item -ItemType Directory -Path $intunewinDir -Force | Out-Null }

    $procArgs = "-c `"$sourceDir`" -s `"$fileName`" -o `"$intunewinDir`" -q"
    Write-Log "IntuneWinAppUtil: $procArgs" -Level DEBUG -Source 'MDM'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $toolExe
    $psi.Arguments              = $procArgs
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        Write-Log "IntuneWinAppUtil FEHLER (Exit $($proc.ExitCode)): $stderr $stdout" -Level ERROR -Source 'MDM'
        throw "IntuneWinAppUtil.exe fehlgeschlagen (Exit $($proc.ExitCode)): $stderr"
    }

    # .intunewin Datei finden
    $intunewinFile = Get-ChildItem -Path $intunewinDir -Filter '*.intunewin' | Select-Object -First 1
    if (-not $intunewinFile) { throw "Keine .intunewin-Datei in $intunewinDir gefunden" }
    Write-Log ".intunewin erstellt: $($intunewinFile.FullName) ($($intunewinFile.Length) Bytes)" -Level INFO -Source 'MDM'

    # .intunewin entpacken (ist ein ZIP) — alten Extract-Ordner aufräumen
    $extractDir = Join-Path $OutputDirectory 'intunewin_extract'
    if (Test-Path $extractDir) { Remove-Item -Path $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($intunewinFile.FullName, $extractDir)

    # Detection.xml parsen — ZIP hat Root-Ordner 'IntuneWinPackage/'
    $detectionXml = Get-ChildItem -Path $extractDir -Filter 'Detection.xml' -Recurse | Select-Object -First 1
    if (-not $detectionXml) { throw "Detection.xml nicht in .intunewin gefunden" }
    Write-Log "Detection.xml gefunden: $($detectionXml.FullName)" -Level DEBUG -Source 'MDM'

    [xml]$xml = Get-Content -Path $detectionXml.FullName -Encoding UTF8
    $encInfo = $xml.ApplicationInfo.EncryptionInfo

    # Verschluesselte Datei finden
    $encryptedFile = Get-ChildItem -Path $extractDir -Filter 'IntunePackage.intunewin' -Recurse | Select-Object -First 1
    if (-not $encryptedFile) { throw "IntunePackage.intunewin nicht in .intunewin gefunden" }
    $encryptedSize = $encryptedFile.Length

    # In OutputDirectory kopieren (fuer Upload)
    $uploadFile = Join-Path $OutputDirectory 'IntunePackage.intunewin'
    Copy-Item -Path $encryptedFile.FullName -Destination $uploadFile -Force

    Write-Log "IntuneWin-Paket bereit: encrypted=$encryptedSize Bytes, original=$originalSize Bytes" -Level INFO -Source 'MDM'

    return [PSCustomObject]@{
        EncryptedFilePath = $uploadFile
        OriginalSize      = [long]$xml.ApplicationInfo.UnencryptedContentSize
        EncryptedSize     = $encryptedSize
        EncryptionInfo    = @{
            '@odata.type'        = '#microsoft.graph.fileEncryptionInfo'
            encryptionKey        = $encInfo.EncryptionKey
            macKey               = $encInfo.MacKey
            initializationVector = $encInfo.InitializationVector
            mac                  = $encInfo.Mac
            profileIdentifier    = $encInfo.ProfileIdentifier
            fileDigest           = $encInfo.FileDigest
            fileDigestAlgorithm  = $encInfo.FileDigestAlgorithm
        }
    }
}

#endregion

#region ===== App Management =====

function Get-NextExamIntuneApp {
    <#
    .SYNOPSIS
        Sucht nach bestehender Next-Exam App im Tenant (windowsMobileMSI oder win32LobApp).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$DisplayNameFilter  # z.B. 'Next-Exam-Student'
    )
    # OData-Filter: nur contains auf displayName -- kein isof (funktioniert nicht mit delegierten Tokens)
    $filter = "contains(displayName,'$DisplayNameFilter')"
    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps?`$filter=$filter"

    $result = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri
    $allApps = @()
    if ($result.value) { $allApps = @($result.value) }

    # Client-seitig auf MSI + Win32 filtern und Name mit Regex pruefen
    $pattern = 'next[\s\-_]?exam'
    $apps = @($allApps | Where-Object {
        $_.'@odata.type' -match '(windowsMobileMSI|win32LobApp)' -and
        $_.displayName -match $pattern -and
        $_.displayName -match [regex]::Escape($DisplayNameFilter)
    })

    if ($apps.Count -eq 0) {
        Write-Log "Keine Intune-App gefunden fuer '$DisplayNameFilter'" -Level INFO -Source 'MDM'
        return $null
    }
    if ($apps.Count -gt 1) {
        Write-Log "WARNUNG: $($apps.Count) Apps gefunden fuer '$DisplayNameFilter' - verwende erste" -Level WARN -Source 'MDM'
    }
    $app = $apps[0]

    # largeIcon wird bei Listen-Abfragen nicht mitgeliefert — separater GET noetig
    try {
        $iconUri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$($app.id)?`$select=largeIcon"
        $iconResp = Invoke-GraphRequest -AccessToken $AccessToken -Uri $iconUri
        if ($iconResp.largeIcon) {
            $app | Add-Member -NotePropertyName 'largeIcon' -NotePropertyValue $iconResp.largeIcon -Force
        }
    } catch {
        Write-Log "largeIcon-Abfrage fehlgeschlagen (nicht kritisch): $_" -Level DEBUG -Source 'MDM'
    }

    # Version: windowsMobileMSI nutzt productVersion, win32LobApp nutzt displayVersion
    $version = $null
    if ($app.'@odata.type' -eq '#microsoft.graph.windowsMobileMSI') {
        $version = $app.productVersion
    } else {
        $version = $app.displayVersion
    }

    # Einheitliches Ergebnis-Objekt mit normalisierter Version + Metadaten
    $result = New-Object PSObject
    $result | Add-Member -NotePropertyName 'id'                  -NotePropertyValue $app.id
    $result | Add-Member -NotePropertyName 'displayName'         -NotePropertyValue $app.displayName
    $result | Add-Member -NotePropertyName 'appVersion'          -NotePropertyValue $version
    $result | Add-Member -NotePropertyName 'appType'             -NotePropertyValue $app.'@odata.type'
    $result | Add-Member -NotePropertyName 'publishingState'     -NotePropertyValue $app.publishingState
    $result | Add-Member -NotePropertyName 'fileName'            -NotePropertyValue $app.fileName
    # Metadaten-Felder fuer Abgleich
    $result | Add-Member -NotePropertyName 'description'         -NotePropertyValue $app.description
    $result | Add-Member -NotePropertyName 'publisher'           -NotePropertyValue $app.publisher
    $result | Add-Member -NotePropertyName 'developer'           -NotePropertyValue $app.developer
    $result | Add-Member -NotePropertyName 'informationUrl'      -NotePropertyValue $app.informationUrl
    $result | Add-Member -NotePropertyName 'installCommandLine'  -NotePropertyValue $app.installCommandLine
    $result | Add-Member -NotePropertyName 'uninstallCommandLine' -NotePropertyValue $app.uninstallCommandLine
    $result | Add-Member -NotePropertyName 'largeIcon'           -NotePropertyValue $app.largeIcon

    Write-Log "Intune-App gefunden: $($app.displayName) v$version [$($app.'@odata.type')] (ID: $($app.id))" -Level INFO -Source 'MDM'
    return $result
}

function New-NextExamIntuneApp {
    <#
    .SYNOPSIS
        Erstellt eine neue Win32 LobApp in Intune.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][hashtable]$AppMetadata
    )
    # Pflichtfelder pruefen
    foreach ($key in @('displayName','installCommandLine','uninstallCommandLine')) {
        if (-not $AppMetadata[$key]) { throw "AppMetadata.$key ist Pflichtfeld." }
    }

    # Payload zusammenbauen
    $payload = @{
        '@odata.type'          = '#microsoft.graph.win32LobApp'
        displayName            = $AppMetadata['displayName']
        description            = if ($AppMetadata['description']) { $AppMetadata['description'] } else { $AppMetadata['displayName'] }
        publisher              = if ($AppMetadata['publisher']) { $AppMetadata['publisher'] } else { 'Bildungsportal' }
        developer              = if ($AppMetadata['developer']) { $AppMetadata['developer'] } else { 'Mag. Thomas Michael Weissel' }
        displayVersion         = if ($AppMetadata['displayVersion']) { $AppMetadata['displayVersion'] } else { '1.0.0.0' }
        installCommandLine     = $AppMetadata['installCommandLine']
        uninstallCommandLine   = $AppMetadata['uninstallCommandLine']
        installExperience      = @{
            '@odata.type'   = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount    = if ($AppMetadata['installExperience']) { $AppMetadata['installExperience'] } else { 'system' }
            deviceRestartBehavior = 'suppress'
        }
        informationUrl         = 'https://github.com/Bildungsportal/next-exam'
        isFeatured             = $false
        applicableArchitectures = 'x64'
        minimumSupportedWindowsRelease = '1903'
        fileName               = if ($AppMetadata['setupFilePath']) { $AppMetadata['setupFilePath'] } else { "NextExam$($AppMetadata['_role']).msi" }
        setupFilePath          = if ($AppMetadata['setupFilePath']) { $AppMetadata['setupFilePath'] } else { "NextExam$($AppMetadata['_role']).msi" }
    }

    # Detection Rule: MSI Product Code (bevorzugt) oder File-basiert
    if ($AppMetadata['msiProductCode']) {
        $payload['detectionRules'] = @(
            @{
                '@odata.type'  = '#microsoft.graph.win32LobAppProductCodeDetection'
                productCode    = $AppMetadata['msiProductCode']
                productVersionOperator = 'greaterThanOrEqual'
                productVersion = if ($AppMetadata['displayVersion']) { $AppMetadata['displayVersion'] } else { '1.0.0.0' }
            }
        )
    } else {
        # Fallback: File-Detection
        $exeName = if ($AppMetadata['displayName'] -match 'Student') { 'Next-Exam-Student.exe' } else { 'Next-Exam-Teacher.exe' }
        $payload['detectionRules'] = @(
            @{
                '@odata.type' = '#microsoft.graph.win32LobAppFileSystemDetection'
                path          = '%ProgramFiles%\' + ($AppMetadata['displayName'] -replace '\s', '-')
                fileOrFolderName = $exeName
                detectionType    = 'exists'
                check32BitOn64System = $false
            }
        )
    }

    # Requirement Rule
    $payload['requirementRules'] = @(
        @{
            '@odata.type'                = '#microsoft.graph.win32LobAppRegistryRequirement'
            operator                     = 'notConfigured'
            detectionValue               = $null
            keyPath                      = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            valueName                    = 'CurrentBuild'
            detectionType                = 'exists'
            check32BitOn64System         = $false
        }
    )
    # Alternativ: minimumFreeDiskSpaceInMB, minimumMemoryInMB, etc. via Metadata

    # Icon setzen (largeIcon) wenn vorhanden
    if ($AppMetadata['iconPath'] -and (Test-Path $AppMetadata['iconPath'])) {
        $iconBytes = [System.IO.File]::ReadAllBytes($AppMetadata['iconPath'])
        $iconB64   = [Convert]::ToBase64String($iconBytes)
        $payload['largeIcon'] = @{
            '@odata.type' = '#microsoft.graph.mimeContent'
            type          = 'image/png'
            value         = $iconB64
        }
        Write-Log "largeIcon gesetzt ($($iconBytes.Length) Bytes)" -Level DEBUG -Source 'MDM'
    }

    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps"
    $app = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Method POST -Body $payload
    Write-Log "Win32-App erstellt: $($app.displayName) (ID: $($app.id))" -Level INFO -Source 'MDM'
    return $app
}

function Update-NextExamIntuneAppMetadata {
    <#
    .SYNOPSIS
        Aktualisiert Metadaten einer bestehenden Win32 App via PATCH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][hashtable]$Updates  # z.B. @{ displayVersion = '2.1.3'; description = '...' }
    )
    $payload = @{ '@odata.type' = '#microsoft.graph.win32LobApp' }
    foreach ($key in $Updates.Keys) { $payload[$key] = $Updates[$key] }

    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId"
    Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Method PATCH -Body $payload
    Write-Log "App-Metadaten aktualisiert (ID: $AppId)" -Level INFO -Source 'MDM'
}

function Compare-NextExamAppMetadata {
    <#
    .SYNOPSIS
        Vergleicht Intune-IST-Metadaten mit SOLL-Werten (Defaults + UI-Overrides).
    .DESCRIPTION
        Option C: Defaults aus New-NextExamIntuneApp als Basis, UI-Werte ueberschreiben wenn vorhanden.
        Gibt Array von PSObjects zurueck mit Property, Expected, Actual, Match.
    .PARAMETER IntuneApp
        Result-Objekt von Get-NextExamIntuneApp (mit Metadaten-Feldern).
    .PARAMETER UIMetadata
        Hashtable mit UI-Werten (optional). Keys: description, publisher, developer, informationUrl.
        Nur gesetzte Keys ueberschreiben die Defaults.
    .PARAMETER IconPath
        Pfad zur lokalen icon.png. Wenn gesetzt, wird geprueft ob Intune-App ein largeIcon hat.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSObject]$IntuneApp,
        [hashtable]$UIMetadata = @{},
        [string]$IconPath
    )

    # Defaults (gleiche Werte wie New-NextExamIntuneApp)
    $defaults = @{
        publisher      = 'Bildungsportal'
        developer      = 'Mag. Thomas Michael Weissel'
        informationUrl = 'https://github.com/Bildungsportal/next-exam'
        description    = $IntuneApp.displayName  # Default = displayName
    }

    # UI-Overrides anwenden (Option C)
    foreach ($key in $UIMetadata.Keys) {
        if ($UIMetadata[$key] -and $UIMetadata[$key].ToString().Trim()) {
            $defaults[$key] = $UIMetadata[$key].ToString().Trim()
        }
    }

    $diffs = @()
    foreach ($field in @('description','publisher','developer','informationUrl')) {
        $expected = $defaults[$field]
        $actual   = $IntuneApp.$field
        # Normalize Unicode dashes/quotes before comparison (prevents false positives)
        $normExpected = if ($expected) { $expected -replace '[\u2013\u2014]', '-' -replace '[\u2018\u2019]', "'" -replace '[\u201C\u201D]', '"' } else { $expected }
        $normActual   = if ($actual)   { $actual   -replace '[\u2013\u2014]', '-' -replace '[\u2018\u2019]', "'" -replace '[\u201C\u201D]', '"' } else { $actual }
        $match    = ($normActual -eq $normExpected)
        $diffs += [PSCustomObject]@{
            Property = $field
            Expected = $expected
            Actual   = if ($actual) { $actual } else { '(leer)' }
            Match    = $match
        }
    }

    # Icon-Check: Hat die Intune-App ein largeIcon gesetzt?
    $hasIcon = $false
    if ($IntuneApp.largeIcon -and $IntuneApp.largeIcon.value) {
        $hasIcon = $true
    }
    $iconExpected = if ($IconPath -and (Test-Path $IconPath)) { $true } else { $false }
    $diffs += [PSCustomObject]@{
        Property = 'largeIcon'
        Expected = if ($iconExpected) { 'vorhanden (lokal)' } else { '(kein Icon konfiguriert)' }
        Actual   = if ($hasIcon) { 'vorhanden' } else { '(kein Icon)' }
        Match    = ($hasIcon -eq $iconExpected) -or (-not $iconExpected)
    }

    $mismatches = @($diffs | Where-Object { -not $_.Match })
    if ($mismatches.Count -gt 0) {
        $fields = ($mismatches | ForEach-Object { $_.Property }) -join ', '
        Write-Log "Metadaten-Abweichung: $fields" -Level WARN -Source 'MDM'
    } else {
        Write-Log "Metadaten stimmen ueberein" -Level INFO -Source 'MDM'
    }

    return $diffs
}

#endregion

#region ===== Content Upload Pipeline =====

function New-IntuneContentVersion {
    <#
    .SYNOPSIS
        Erstellt eine neue Content-Version fuer eine Win32-App.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId
    )
    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions"
    $cv = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Method POST -Body @{}
    Write-Log "Content-Version erstellt: $($cv.id) (App: $AppId)" -Level INFO -Source 'MDM'
    return $cv
}

function New-IntuneContentFile {
    <#
    .SYNOPSIS
        Erstellt einen Content-File-Eintrag (Metadaten) in einer Content-Version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$ContentVersionId,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][long]$SizeUnencrypted,
        [Parameter(Mandatory)][long]$SizeEncrypted
    )
    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files"
    $body = @{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name          = $FileName
        size          = $SizeUnencrypted
        sizeEncrypted = $SizeEncrypted
        manifest      = $null
        isDependency  = $false
    }
    $file = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Method POST -Body $body
    Write-Log "Content-File erstellt: $($file.id) ($FileName)" -Level INFO -Source 'MDM'
    return $file
}

function Wait-IntuneFileReady {
    <#
    .SYNOPSIS
        Pollt bis Azure Storage URI bereit ist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$ContentVersionId,
        [Parameter(Mandatory)][string]$FileId
    )
    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files/$FileId"

    for ($i = 0; $i -lt $script:PollMaxRetries; $i++) {
        Start-Sleep -Seconds $script:PollInterval
        $file = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri
        $state = $file.uploadState

        if ($state -eq 'azureStorageUriRequestSuccess') {
            Write-Log "Azure Storage URI bereit (File: $FileId)" -Level INFO -Source 'MDM'
            return $file
        }
        if ($state -eq 'azureStorageUriRequestFailed') {
            throw "Azure Storage URI Anforderung fehlgeschlagen (File: $FileId)"
        }
        if ($state -eq 'commitFileFailed') {
            throw "File-Commit fehlgeschlagen (File: $FileId)"
        }
        Write-Log "Upload-State: $state - warte... (Poll $($i+1)/$script:PollMaxRetries)" -Level DEBUG -Source 'MDM'
    }
    throw "Timeout: Azure Storage URI nicht bereit nach $($script:PollMaxRetries * $script:PollInterval) Sekunden."
}

function Send-AzureBlobChunks {
    <#
    .SYNOPSIS
        Uploaded eine verschluesselte Datei in Chunks als Azure Block Blob.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$AzureStorageUri
    )
    $fileBytes  = [System.IO.File]::ReadAllBytes($FilePath)
    $totalSize  = $fileBytes.Length
    $chunkCount = [Math]::Ceiling($totalSize / $script:ChunkSize)
    $blockIds   = @()

    Write-Log "Azure Blob Upload: $totalSize Bytes in $chunkCount Chunks" -Level INFO -Source 'MDM'

    for ($i = 0; $i -lt $chunkCount; $i++) {
        $offset = $i * $script:ChunkSize
        $length = [Math]::Min($script:ChunkSize, $totalSize - $offset)
        $chunk  = New-Object byte[] $length
        [Array]::Copy($fileBytes, $offset, $chunk, 0, $length)

        # Block-ID: 6-stellig, Base64-kodiert, gleiche Laenge
        $blockId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(('Block{0:D6}' -f $i)))
        $blockIds += $blockId

        # PUT Block
        $blockUri = "$AzureStorageUri&comp=block&blockid=$([Uri]::EscapeDataString($blockId))"
        $request = [System.Net.HttpWebRequest]::Create($blockUri)
        $request.Method = 'PUT'
        $request.Headers.Add('x-ms-blob-type', 'BlockBlob')
        $request.ContentLength = $length
        $request.Timeout = 120000   # 2 Min pro Chunk

        $stream = $request.GetRequestStream()
        $stream.Write($chunk, 0, $length)
        $stream.Close()

        $response = $request.GetResponse()
        $response.Close()

        $pct = [Math]::Round((($i + 1) / $chunkCount) * 100)
        Write-Log "  Chunk $($i+1)/$chunkCount uploaded ($pct%)" -Level DEBUG -Source 'MDM'
    }

    # Block-Liste committen
    $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
    foreach ($bid in $blockIds) {
        $blockListXml += "<Latest>$bid</Latest>"
    }
    $blockListXml += '</BlockList>'

    $listUri = "$AzureStorageUri&comp=blocklist"
    $request = [System.Net.HttpWebRequest]::Create($listUri)
    $request.Method = 'PUT'
    $request.ContentType = 'application/xml'
    $listBytes = [System.Text.Encoding]::UTF8.GetBytes($blockListXml)
    $request.ContentLength = $listBytes.Length

    $stream = $request.GetRequestStream()
    $stream.Write($listBytes, 0, $listBytes.Length)
    $stream.Close()

    $response = $request.GetResponse()
    $response.Close()

    Write-Log "Azure Blob Upload abgeschlossen ($chunkCount Chunks committed)" -Level INFO -Source 'MDM'
}

function Complete-IntuneFileUpload {
    <#
    .SYNOPSIS
        Committed den File-Upload und aktualisiert die App mit der neuen Content-Version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$ContentVersionId,
        [Parameter(Mandatory)][string]$FileId,
        [Parameter(Mandatory)][hashtable]$EncryptionInfo
    )
    # File committen
    $commitUri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files/$FileId/commit"
    $commitBody = @{ fileEncryptionInfo = $EncryptionInfo }
    Invoke-GraphRequest -AccessToken $AccessToken -Uri $commitUri -Method POST -Body $commitBody
    Write-Log "File-Commit gesendet (File: $FileId)" -Level INFO -Source 'MDM'

    # Warten bis Commit verarbeitet
    $fileUri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files/$FileId"
    for ($i = 0; $i -lt $script:PollMaxRetries; $i++) {
        Start-Sleep -Seconds $script:PollInterval
        $file = Invoke-GraphRequest -AccessToken $AccessToken -Uri $fileUri
        if ($file.uploadState -eq 'commitFileSuccess') {
            Write-Log "File-Commit erfolgreich (File: $FileId)" -Level INFO -Source 'MDM'
            break
        }
        if ($file.uploadState -eq 'commitFileFailed') {
            throw "File-Commit fehlgeschlagen (File: $FileId, State: $($file.uploadState))"
        }
        Write-Log "  Commit-State: $($file.uploadState) - warte..." -Level DEBUG -Source 'MDM'
    }

    # App mit committedContentVersion aktualisieren
    $patchUri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId"
    $patchBody = @{
        '@odata.type'           = '#microsoft.graph.win32LobApp'
        committedContentVersion = $ContentVersionId
    }
    Invoke-GraphRequest -AccessToken $AccessToken -Uri $patchUri -Method PATCH -Body $patchBody
    Write-Log "App committedContentVersion gesetzt: $ContentVersionId" -Level INFO -Source 'MDM'
}

#endregion

#region ===== Zuweisungen =====

function Get-IntuneGroups {
    <#
    .SYNOPSIS
        Laedt alle Gruppen aus dem Tenant (fuer Zuweisung).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$Top = 999
    )
    $groups = @()
    $uri = "$script:GraphV1Url/groups?`$select=id,displayName,groupTypes,membershipRule&`$top=$Top"

    do {
        $result = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri
        if ($result.value) { $groups += $result.value }
        $uri = $result.'@odata.nextLink'
    } while ($uri)

    $groups = @($groups | Sort-Object -Property displayName)
    Write-Log "$($groups.Count) Gruppen geladen" -Level INFO -Source 'MDM'
    return $groups
}

function Set-NextExamIntuneAssignment {
    <#
    .SYNOPSIS
        Setzt App-Zuweisungen: Required fuer ausgewaehlte Gruppen + Available fuer alle User.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$AppId,
        [string[]]$RequiredGroupIds,
        [bool]$AvailableForAllUsers = $true
    )
    $assignments = @()

    # Required-Zuweisungen fuer ausgewaehlte Gruppen
    foreach ($gid in $RequiredGroupIds) {
        $assignments += @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = 'required'
            target        = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId       = $gid
            }
            settings      = @{
                '@odata.type'       = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications       = 'showReboot'
                installTimeSettings = $null
                restartSettings     = $null
                deliveryOptimizationPriority = 'notConfigured'
            }
        }
    }

    # Available fuer alle lizenzierten User
    if ($AvailableForAllUsers) {
        $assignments += @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = 'available'
            target        = @{
                '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
            }
            settings      = @{
                '@odata.type'       = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications       = 'showAll'
                installTimeSettings = $null
                restartSettings     = $null
                deliveryOptimizationPriority = 'notConfigured'
            }
        }
    }

    $uri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$AppId/assign"
    $body = @{ mobileAppAssignments = $assignments }
    Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Method POST -Body $body
    Write-Log "Zuweisungen gesetzt: $($RequiredGroupIds.Count) Required-Gruppen, AllUsers=$AvailableForAllUsers" -Level INFO -Source 'MDM'
}

#endregion

#region ===== Orchestrierung =====

function Publish-NextExamToIntune {
    <#
    .SYNOPSIS
        Haupt-Workflow: MSI als Win32-App in Intune deployen.
    .DESCRIPTION
        1. Token holen (Modus A oder B)
        2. Bestehende App suchen
        3. Versions-Vergleich
        4. Neu anlegen oder Content-Update
        5. Zuweisungen setzen
    .PARAMETER MSIPath
        Pfad zur MSI-Datei (lokal oder UNC).
    .PARAMETER AppMetadata
        Hashtable mit App-Metadaten (displayName, installCommandLine, etc.)
    .PARAMETER OnProgress
        ScriptBlock fuer Fortschritts-Callback: param($Step, $Total, $Message)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$MSIPath,
        [Parameter(Mandatory)][hashtable]$AppMetadata,
        [string[]]$RequiredGroupIds = @(),
        [bool]$AvailableForAllUsers = $true,
        [switch]$Force,
        [scriptblock]$OnProgress
    )
    $steps = 6
    $report = @{ Success = $false; Action = ''; AppId = ''; Message = '' }

    # --- Safety: setupFilePath muss mit tatsaechlichem MSI-Dateinamen uebereinstimmen ---
    $actualMsiName = [System.IO.Path]::GetFileName($MSIPath)
    if ($AppMetadata['setupFilePath'] -and $AppMetadata['setupFilePath'] -ne $actualMsiName) {
        Write-Log "setupFilePath Korrektur: '$($AppMetadata['setupFilePath'])' -> '$actualMsiName' (verhindert 0x80070653)" -Level WARN -Source 'MDM'
        $AppMetadata['setupFilePath'] = $actualMsiName
        $AppMetadata['installCommandLine'] = $AppMetadata['installCommandLine'] -replace '[^\s"]+\.msi', $actualMsiName
    }

    # Helper: Progress melden
    $progress = {
        param($step, $msg)
        Write-Log "Publish [$step/$steps]: $msg" -Level INFO -Source 'MDM'
        if ($OnProgress) { & $OnProgress $step $steps $msg }
    }

    try {
        # --- Step 1: Bestehende App suchen ---
        & $progress 1 "Suche bestehende App: $($AppMetadata['displayName'])"
        $existingApp = Get-NextExamIntuneApp -AccessToken $AccessToken -DisplayNameFilter $AppMetadata['displayName']

        # --- Step 2: Versions-Vergleich ---
        & $progress 2 'Versions-Vergleich'
        $newVersion = $AppMetadata['displayVersion']
        if ($existingApp -and $existingApp.appVersion -and -not $Force) {
            try {
                $currentVer = [System.Version]$existingApp.appVersion
                $targetVer  = [System.Version]$newVersion
                if ($targetVer -le $currentVer) {
                    $report.Action  = 'Skipped'
                    $report.AppId   = $existingApp.id
                    $report.Message = "Bereits aktuell oder aelter: Intune=$currentVer, Neu=$targetVer"
                    $report.Success = $true
                    Write-Log $report.Message -Level INFO -Source 'MDM'
                    return $report
                }
            } catch {
                Write-Log "Versions-Vergleich fehlgeschlagen ($($existingApp.appVersion) vs $newVersion) - fahre fort" -Level WARN -Source 'MDM'
            }
        } elseif ($Force -and $existingApp) {
            Write-Log "Force-Deploy: Versions-Vergleich uebersprungen (Intune=$($existingApp.appVersion), Neu=$newVersion)" -Level INFO -Source 'MDM'
        }

        # --- Step 3: App anlegen oder Metadaten aktualisieren ---
        if (-not $existingApp) {
            & $progress 3 'Neue Win32-App anlegen'
            $app = New-NextExamIntuneApp -AccessToken $AccessToken -AppMetadata $AppMetadata
            $report.Action = 'Created'
        } elseif ($existingApp.appType -eq '#microsoft.graph.windowsMobileMSI') {
            # Bestehende App ist windowsMobileMSI -> loeschen und als win32LobApp neu erstellen
            & $progress 3 "App-Migration: windowsMobileMSI -> win32LobApp (loesche $($existingApp.id))"
            Write-Log "Alte windowsMobileMSI-App loeschen: $($existingApp.displayName) (ID: $($existingApp.id))" -Level WARN -Source 'MDM'
            $deleteUri = "$script:GraphBaseUrl/deviceAppManagement/mobileApps/$($existingApp.id)"
            Invoke-GraphRequest -AccessToken $AccessToken -Uri $deleteUri -Method DELETE
            Start-Sleep -Seconds 5  # Warten bis Intune die Loeschung verarbeitet hat
            $app = New-NextExamIntuneApp -AccessToken $AccessToken -AppMetadata $AppMetadata
            $report.Action = 'Migrated'
        } else {
            & $progress 3 "App aktualisieren: $($existingApp.id)"
            $updates = @{
                displayVersion = $newVersion
                description    = if ($AppMetadata['description']) { $AppMetadata['description'] } else { $AppMetadata['displayName'] }
            }
            # Icon mitschicken wenn vorhanden
            if ($AppMetadata['iconPath'] -and (Test-Path $AppMetadata['iconPath'])) {
                $iconBytes = [System.IO.File]::ReadAllBytes($AppMetadata['iconPath'])
                $updates['largeIcon'] = @{
                    '@odata.type' = '#microsoft.graph.mimeContent'
                    type          = 'image/png'
                    value         = [Convert]::ToBase64String($iconBytes)
                }
            }
            Update-NextExamIntuneAppMetadata -AccessToken $AccessToken -AppId $existingApp.id -Updates $updates
            $app = $existingApp
            $report.Action = 'Updated'
        }
        $report.AppId = $app.id

        # --- Step 4: MSI verschluesseln + Content-Version erstellen ---
        & $progress 4 'MSI verschluesseln + Content-Version erstellen'
        $tempDir = Join-Path $env:TEMP "HU-MDM-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            $enc = Protect-IntuneWinFile -SourceFile $MSIPath -OutputDirectory $tempDir

            $cv = New-IntuneContentVersion -AccessToken $AccessToken -AppId $app.id
            $msiFileName = [System.IO.Path]::GetFileName($MSIPath)
            $cf = New-IntuneContentFile -AccessToken $AccessToken -AppId $app.id `
                    -ContentVersionId $cv.id -FileName $msiFileName `
                    -SizeUnencrypted $enc.OriginalSize -SizeEncrypted $enc.EncryptedSize

            # --- Step 5: Upload ---
            & $progress 5 'Upload nach Azure Blob Storage'
            $fileReady = Wait-IntuneFileReady -AccessToken $AccessToken -AppId $app.id `
                            -ContentVersionId $cv.id -FileId $cf.id
            Send-AzureBlobChunks -FilePath $enc.EncryptedFilePath -AzureStorageUri $fileReady.azureStorageUri
            Complete-IntuneFileUpload -AccessToken $AccessToken -AppId $app.id `
                -ContentVersionId $cv.id -FileId $cf.id -EncryptionInfo $enc.EncryptionInfo

        } finally {
            # Temp-Verzeichnis aufraeumen
            if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # --- Step 6: Zuweisungen ---
        & $progress 6 'Zuweisungen setzen'
        if ($RequiredGroupIds.Count -gt 0 -or $AvailableForAllUsers) {
            Set-NextExamIntuneAssignment -AccessToken $AccessToken -AppId $app.id `
                -RequiredGroupIds $RequiredGroupIds -AvailableForAllUsers $AvailableForAllUsers
        } else {
            Write-Log "Keine Zuweisungen konfiguriert - uebersprungen" -Level INFO -Source 'MDM'
        }

        $report.Success = $true
        $report.Message = "$($report.Action): $($AppMetadata['displayName']) v$newVersion (App-ID: $($app.id))"
        Write-Log "Publish abgeschlossen: $($report.Message)" -Level INFO -Source 'MDM'

    } catch {
        $report.Success = $false
        $report.Message = "Publish fehlgeschlagen: $_"
        Write-Log $report.Message -Level ERROR -Source 'MDM'
    }

    return $report
}

#endregion

#region ===== App Registration Setup =====

function Start-MDMSetupAuthListener {
    <#
    .SYNOPSIS
        Startet Auth Code Flow mit erweiterten Scopes fuer App Registration Setup.
        Verwendet die Fallback Public Client ID (MS Graph CLI).
    .OUTPUTS
        PSCustomObject (Listener-Kontext wie Start-MDMAuthCodeListener).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId
    )
    $ClientId = $script:FallbackPublicClientId

    # Zufaelligen Port waehlen
    $port = Get-Random -Minimum 49152 -Maximum 65536
    $redirectUri = "http://localhost:$port/"

    # PKCE
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $verifierBytes = New-Object byte[] 32
    $rng.GetBytes($verifierBytes)
    $codeVerifier = [Convert]::ToBase64String($verifierBytes) -replace '\+','-' -replace '/','_' -replace '='
    $rng.Dispose()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $challengeBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeBytes) -replace '\+','-' -replace '/','_' -replace '='
    $sha256.Dispose()

    $state = [Guid]::NewGuid().ToString('N')

    # HttpListener
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($redirectUri)
    try { $listener.Start() } catch {
        throw "HttpListener konnte nicht auf Port $port starten: $_"
    }
    $asyncResult = $listener.BeginGetContext($null, $null)

    # Browser mit Setup-Scopes oeffnen
    $scopes = [Uri]::EscapeDataString($script:SetupScope)
    $authUrl = "$script:LoginBaseUrl/$TenantId/oauth2/v2.0/authorize?" +
        "client_id=$ClientId" +
        "&response_type=code" +
        "&redirect_uri=$([Uri]::EscapeDataString($redirectUri))" +
        "&response_mode=query" +
        "&scope=$scopes" +
        "&state=$state" +
        "&code_challenge=$codeChallenge" +
        "&code_challenge_method=S256" +
        "&prompt=consent"
    try { Start-Process $authUrl } catch {
        Write-Log "Browser konnte nicht geoeffnet werden: $_" -Level WARN -Source 'MDM'
    }

    Write-Log "Setup-Auth Listener gestartet auf $redirectUri (Tenant: $TenantId, Scopes: Setup)" -Level INFO -Source 'MDM'

    return [PSCustomObject]@{
        Listener     = $listener
        AsyncResult  = $asyncResult
        RedirectUri  = $redirectUri
        TenantId     = $TenantId
        ClientId     = $ClientId
        State        = $state
        CodeVerifier = $codeVerifier
        Port         = $port
    }
}


function Register-MDMEntraApp {
    <#
    .SYNOPSIS
        Erstellt App Registration im Tenant, setzt Permissions, Admin Consent, Secret.
        Speichert Credentials DPAPI-verschluesselt.
    .PARAMETER AccessToken
        Admin-Token mit Application.ReadWrite.All + AppRoleAssignment.ReadWrite.All Scopes.
    .PARAMETER TenantId
        Entra ID Tenant-ID.
    .PARAMETER AppDisplayName
        Name der App-Registrierung (Default: HU-NextExam-Manager).
    .PARAMETER SecretValidityDays
        Laufzeit des Client Secrets in Tagen (Default: 365).
    .OUTPUTS
        PSCustomObject mit AppId, ClientId, Secret, CredentialPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$AppDisplayName = 'HU-NextExam-Manager',
        [int]$SecretValidityDays = 365
    )

    $graphBase = $script:GraphBaseUrl -replace '/beta$', '/v1.0'
    $totalSteps = 7

    # --- Helper fuer v1.0 Aufrufe ---
    function Invoke-SetupRequest {
        param([string]$Uri, [string]$Method = 'GET', [object]$Body)
        $headers = @{ Authorization = "Bearer $AccessToken" }
        $params = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $headers
            ContentType = 'application/json'
            ErrorAction = 'Stop'
        }
        if ($Body) {
            $params['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        }
        if ($Method -eq 'DELETE') {
            $null = Invoke-WebRequest @params -UseBasicParsing
            return $null
        }
        return Invoke-RestMethod @params
    }

    # === Step 1: Graph Service Principal nachschlagen (Permission-IDs) ===
    $stepNum = 1
    Write-Log "[$stepNum/$totalSteps] Schlage Graph-Permission-IDs nach..." -Level INFO -Source 'MDM-Setup'

    $graphResourceAppId = '00000003-0000-0000-c000-000000000000'
    $spSearch = Invoke-SetupRequest -Uri "$graphBase/servicePrincipals?`$filter=appId eq '$graphResourceAppId'&`$select=id,appId,appRoles,oauth2PermissionScopes"
    $graphSP = $spSearch.value | Select-Object -First 1
    if (-not $graphSP) { throw "Microsoft Graph Service Principal nicht gefunden im Tenant." }

    # Delegated Permission IDs
    $delegatedPerms = @{}
    foreach ($pName in @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All')) {
        $found = $graphSP.oauth2PermissionScopes | Where-Object { $_.value -eq $pName }
        if ($found) { $delegatedPerms[$pName] = $found.id }
        else { Write-Log "WARNUNG: Delegated '$pName' nicht gefunden" -Level WARN -Source 'MDM-Setup' }
    }

    # Application Permission IDs
    $appPerms = @{}
    foreach ($pName in @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All')) {
        $found = $graphSP.appRoles | Where-Object { $_.value -eq $pName }
        if ($found) { $appPerms[$pName] = $found.id }
        else { Write-Log "WARNUNG: AppRole '$pName' nicht gefunden" -Level WARN -Source 'MDM-Setup' }
    }

    Write-Log "  Delegated IDs: $($delegatedPerms | ConvertTo-Json -Compress)" -Level DEBUG -Source 'MDM-Setup'
    Write-Log "  AppRole IDs: $($appPerms | ConvertTo-Json -Compress)" -Level DEBUG -Source 'MDM-Setup'

    # === Step 2: Pruefen ob App bereits existiert ===
    $stepNum = 2
    Write-Log "[$stepNum/$totalSteps] Pruefe bestehende App '$AppDisplayName'..." -Level INFO -Source 'MDM-Setup'

    $existingSearch = Invoke-SetupRequest -Uri "$graphBase/applications?`$filter=displayName eq '$AppDisplayName'&`$select=id,appId,displayName"
    $existingApp = $existingSearch.value | Select-Object -First 1

    if ($existingApp) {
        Write-Log "  App existiert bereits: AppId=$($existingApp.appId), ObjectId=$($existingApp.id)" -Level WARN -Source 'MDM-Setup'
        $appObjectId = $existingApp.id
        $appClientId = $existingApp.appId
        $stepNum = 4
    } else {
        # === Step 3: App Registration erstellen ===
        $stepNum = 3
        Write-Log "[$stepNum/$totalSteps] Erstelle App Registration..." -Level INFO -Source 'MDM-Setup'

        # ResourceAccess zusammenbauen
        $resourceAccess = @()
        foreach ($id in $delegatedPerms.Values) {
            $resourceAccess += @{ id = $id; type = 'Scope' }
        }
        foreach ($id in $appPerms.Values) {
            $resourceAccess += @{ id = $id; type = 'Role' }
        }

        $appPayload = @{
            displayName            = $AppDisplayName
            signInAudience         = 'AzureADMyOrg'
            requiredResourceAccess = @(
                @{
                    resourceAppId  = $graphResourceAppId
                    resourceAccess = $resourceAccess
                }
            )
            publicClient = @{
                redirectUris = @(
                    'http://localhost'
                    'http://localhost:8400'
                    'http://localhost:8401'
                    'http://localhost:8402'
                )
            }
            isFallbackPublicClient = $true
        }

        $newApp = Invoke-SetupRequest -Uri "$graphBase/applications" -Method POST -Body $appPayload
        $appObjectId = $newApp.id
        $appClientId = $newApp.appId
        Write-Log "  App erstellt: AppId=$appClientId, ObjectId=$appObjectId" -Level INFO -Source 'MDM-Setup'

        Start-Sleep -Seconds 5
        $stepNum = 4
    }

    # === Step 4: Service Principal erstellen ===
    Write-Log "[$stepNum/$totalSteps] Service Principal erstellen/pruefen..." -Level INFO -Source 'MDM-Setup'

    $spSearch2 = Invoke-SetupRequest -Uri "$graphBase/servicePrincipals?`$filter=appId eq '$appClientId'&`$select=id,appId"
    $appSP = $spSearch2.value | Select-Object -First 1

    if (-not $appSP) {
        $appSP = Invoke-SetupRequest -Uri "$graphBase/servicePrincipals" -Method POST -Body @{
            appId = $appClientId
        }
        Write-Log "  Service Principal erstellt: $($appSP.id)" -Level INFO -Source 'MDM-Setup'
        Start-Sleep -Seconds 3
    } else {
        Write-Log "  Service Principal existiert: $($appSP.id)" -Level INFO -Source 'MDM-Setup'
    }

    # === Step 5: Application Permissions + Admin Consent ===
    $stepNum = 5
    Write-Log "[$stepNum/$totalSteps] AppRole Assignments (Application Permissions)..." -Level INFO -Source 'MDM-Setup'

    $existingRoles = Invoke-SetupRequest -Uri "$graphBase/servicePrincipals/$($appSP.id)/appRoleAssignments?`$select=id,appRoleId"
    $existingRoleIds = @($existingRoles.value | ForEach-Object { $_.appRoleId })

    foreach ($pName in $appPerms.Keys) {
        $roleId = $appPerms[$pName]
        if ($roleId -in $existingRoleIds) {
            Write-Log "  AppRole '$pName' bereits zugewiesen." -Level DEBUG -Source 'MDM-Setup'
            continue
        }
        try {
            Invoke-SetupRequest -Uri "$graphBase/servicePrincipals/$($appSP.id)/appRoleAssignments" -Method POST -Body @{
                principalId = $appSP.id
                resourceId  = $graphSP.id
                appRoleId   = $roleId
            } | Out-Null
            Write-Log "  AppRole '$pName' zugewiesen." -Level INFO -Source 'MDM-Setup'
        } catch {
            Write-Log "  FEHLER bei AppRole '$pName': $_" -Level ERROR -Source 'MDM-Setup'
        }
    }

    # === Step 6: Delegated Permissions Consent ===
    $stepNum = 6
    Write-Log "[$stepNum/$totalSteps] Delegated Permission Consent..." -Level INFO -Source 'MDM-Setup'

    $scopeString = ($delegatedPerms.Keys) -join ' '
    $grantSearch = Invoke-SetupRequest -Uri "$graphBase/oauth2PermissionGrants?`$filter=clientId eq '$($appSP.id)' and resourceId eq '$($graphSP.id)'"
    $existingGrant = $grantSearch.value | Select-Object -First 1

    if ($existingGrant) {
        $currentScopes = ($existingGrant.scope -split ' ') | Where-Object { $_ }
        $missing = $delegatedPerms.Keys | Where-Object { $_ -notin $currentScopes }
        if ($missing) {
            $newScope = (($currentScopes + $missing) | Select-Object -Unique) -join ' '
            Invoke-SetupRequest -Uri "$graphBase/oauth2PermissionGrants/$($existingGrant.id)" -Method PATCH -Body @{
                scope = $newScope
            } | Out-Null
            Write-Log "  Delegated Scopes aktualisiert: $newScope" -Level INFO -Source 'MDM-Setup'
        } else {
            Write-Log "  Delegated Consent bereits vollstaendig." -Level DEBUG -Source 'MDM-Setup'
        }
    } else {
        Invoke-SetupRequest -Uri "$graphBase/oauth2PermissionGrants" -Method POST -Body @{
            clientId    = $appSP.id
            consentType = 'AllPrincipals'
            resourceId  = $graphSP.id
            scope       = $scopeString
        } | Out-Null
        Write-Log "  Delegated Consent erteilt: $scopeString" -Level INFO -Source 'MDM-Setup'
    }

    # === Step 7: Client Secret generieren ===
    $stepNum = 7
    Write-Log "[$stepNum/$totalSteps] Client Secret generieren..." -Level INFO -Source 'MDM-Setup'

    $endDate = (Get-Date).AddDays($SecretValidityDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $secretResult = Invoke-SetupRequest -Uri "$graphBase/applications/$appObjectId/addPassword" -Method POST -Body @{
        passwordCredential = @{
            displayName = "HU-NextExam-Manager ($(Get-Date -Format 'yyyy-MM-dd'))"
            endDateTime = $endDate
        }
    }
    $clientSecret = $secretResult.secretText
    Write-Log "  Secret erstellt (gueltig bis: $endDate)" -Level INFO -Source 'MDM-Setup'

    # === Credentials DPAPI-verschluesselt speichern ===
    $credPath = Save-MDMCredential -TenantId $TenantId -ClientId $appClientId -ClientSecret $clientSecret
    Write-Log "Setup abgeschlossen: App=$AppDisplayName, ClientId=$appClientId, Credentials=$credPath" -Level INFO -Source 'MDM-Setup'

    return [PSCustomObject]@{
        AppDisplayName  = $AppDisplayName
        AppObjectId     = $appObjectId
        ClientId        = $appClientId
        TenantId        = $TenantId
        SecretExpiresAt = $endDate
        CredentialPath  = $credPath
        IsExisting      = [bool]$existingApp
    }
}

#endregion

#region ===== Export =====

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function `
        Save-MDMCredential, Load-MDMCredential, Test-MDMCredentialExists, Remove-MDMCredential, `
        Get-MDMToken, Get-MDMTokenClientCredentials, Get-MDMTokenDeviceCode, `
        Start-MDMAuthCodeListener, Poll-MDMAuthCodeOnce, Stop-MDMAuthCodeListener, Get-MDMTokenAuthCode, `
        Start-MDMSetupAuthListener, Register-MDMEntraApp, `
        Invoke-GraphRequest, `
        Get-IntuneWinAppUtil, Protect-IntuneWinFile, `
        Get-NextExamIntuneApp, New-NextExamIntuneApp, Update-NextExamIntuneAppMetadata, Compare-NextExamAppMetadata, `
        New-IntuneContentVersion, New-IntuneContentFile, Wait-IntuneFileReady, `
        Send-AzureBlobChunks, Complete-IntuneFileUpload, `
        Get-IntuneGroups, Set-NextExamIntuneAssignment, `
        Publish-NextExamToIntune
}

#endregion
