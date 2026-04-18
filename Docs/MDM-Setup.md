# MDM Pull - Intune Integration (Vorbereitung)

**Ziel:** Next-Exam MSIs werden als Win32-App in Intune ausgerollt. Bei neuen Releases aktualisiert das Tool die bestehende App (Content Version Update) - Clients bekommen das Update automatisch.

---

## Authentifizierungs-Modi

Das Tool unterstuetzt (ab v1.1) **zwei Modi**:

### Modus A: App-Token (Client Credentials Flow)
- Service-Account-artig, laeuft unbeaufsichtigt (Auto-Pull, Scheduled Task)
- Credentials DPAPI-verschluesselt in config.json
- Benoetigt: **Schritte 1-3 unten** (App-Registration + Application Permissions + Client Secret)
- Empfohlen fuer produktiven Dauerbetrieb

### Modus B: Interaktive Anmeldung (Tenant-Admin, Session-basiert)
- Kein Secret gespeichert, kein Auto-Pull moeglich
- Tenant-Admin loggt sich pro Session an (Device-Code-Flow)
- Token gilt nur fuer laufende Session
- Benoetigt: **Schritt 1 + 2** (App-Registration + **Delegated Permissions** statt Application)
- Empfohlen fuer manuelle Einmal-Deployments oder Tests

Welcher Modus verwendet wird, waehlst du beim MDM-Pull im Tool per Radio-Button.

---

## 1. Azure App-Registration (pro Tenant)

### Schritt 1: App anlegen

1. https://portal.azure.com - mit Global Admin des jeweiligen Schul-Tenants anmelden
2. **Azure Active Directory** - **App registrations** - **+ New registration**
3. Name: `HU-NextExam-Manager-Intune` (oder beliebig)
4. Supported account types: **Accounts in this organizational directory only** (Single tenant)
5. Redirect URI: (leer lassen)
6. **Register**

Nach Anlage notieren:
- **Application (client) ID**
- **Directory (tenant) ID**

### Schritt 2: API-Permissions setzen

1. Im registrierten App - **API permissions** - **+ Add a permission** - **Microsoft Graph**
2. **Application permissions** (nicht Delegated)
3. Folgende Permissions hinzufuegen:
   - `DeviceManagementApps.ReadWrite.All` - Win32-Apps lesen/schreiben
   - `DeviceManagementConfiguration.ReadWrite.All` - Config-Profile (fuer Task-Deployment)
   - `DeviceManagementManagedDevices.Read.All` - optional fuer Status-Check

**Wenn du beide Modi unterstuetzen willst**, zusaetzlich **Delegated permissions** mit den gleichen Scopes hinzufuegen. Fuer Delegated Mode muss die App nicht zwingend Application Permissions haben, wenn nur interaktiv gearbeitet wird.
4. **Add permissions** - dann **Grant admin consent for <Tenant>** klicken

### Schritt 3: Client-Secret erstellen (nur fuer Modus A)

Bei rein interaktivem Einsatz (Modus B) diesen Schritt ueberspringen.

1. **Certificates & secrets** - **+ New client secret**
2. Description: `HU-NextExam-Manager`
3. Expires: **24 months** (empfohlen, laenger ist ggf. durch Org-Policy blockiert)
4. **Add**
5. **SOFORT** den "Value" kopieren - danach nicht mehr einsehbar!

### Schritt 4: Intune-Lizenz pruefen

Die App braucht keine Lizenz, aber Intune muss im Tenant aktiviert sein (M365 Business/A/E-Plaene mit Intune oder EMS). Das Ziel-Tenant muss Geraete ueber Autopilot/Intune managen koennen.

---

## 2. Credentials ins Tool eintragen (v1.1)

Im Settings-Tab des HU-NextExam-Managers pro Task:
- `IntuneTenantId` = Directory (tenant) ID
- `IntuneClientId` = Application (client) ID
- `IntuneClientSecret` = kopierter Secret-Value (DPAPI-verschluesselt gespeichert)

---

## 3. Geplante Graph-API-Endpoints (zur Referenz)

### Win32-App anlegen
```
POST https://graph.microsoft.com/beta/deviceAppManagement/mobileApps
```

### Content-Version einer bestehenden App aktualisieren
```
POST .../mobileApps/{id}/microsoft.graph.win32LobApp/contentVersions
PATCH .../mobileApps/{id} (committedContentVersion setzen)
```

### Content-File-Upload (mehrstufig)
1. `POST .../contentVersions/{v}/files` - Metadata
2. Polling bis `uploadState = azureStorageUriRequestSuccess` - SAS-URL
3. Azure Blob Upload (Chunked)
4. `POST .../files/{id}/commit` - Commit mit Encryption-Keys

### Docs
- https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management
- https://learn.microsoft.com/en-us/graph/api/intune-apps-win32lobapp-create

---

## 4. Hinweise

- **MSI muss .intunewin-Format** haben fuer Upload - wird beim v1.1-Upload-Prozess automatisch erstellt via IntuneWinAppUtil.exe
- IntuneWinAppUtil.exe: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool (wird bei v1.1 ins Tool integriert)
- **Detection Rule** muessen wir pro App angeben (z.B. Registry-Key oder MSI-ProductCode)
- **Requirement Rule** (OS-Version, Architektur)
- **Install / Uninstall Command**: `msiexec /i <msi> /quiet /norestart`

---

## 5. Multi-Tenant-Hinweis

Jede Schule hat eigenen M365-Tenant. Die App-Registration MUSS pro Tenant einzeln gemacht werden. Das Tool speichert pro Task eigene Credentials.

Du kannst den Prozess parallel in allen 5 Tenants durchlaufen und die 5 Credential-Sets in die Tasks eintragen.
