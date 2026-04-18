# MDM Deploy - Intune Integration

Next-Exam MSIs werden als Win32 LOB App in Intune deployed. Bei neuen Releases
aktualisiert das Tool die bestehende App (Content Version Update) — Clients
bekommen das Update automatisch.

---

## Voraussetzungen

- Microsoft 365 Tenant mit Intune-Lizenzierung
- Globaler Administrator oder Intune Administrator Rolle
- Intune-gemanagte Geraete (Autopilot oder manuell enrolled)
- Internetzugang vom Admin-Rechner (Graph API + Azure Blob Upload)

---

## Authentifizierungs-Modi

### Modus A: App-Credentials (automatisch)

- Laeuft unbeaufsichtigt (fuer Dauerbetrieb)
- Client Secret DPAPI-verschluesselt in `%APPDATA%\HU-NextExam\mdm_{tenantId}.cred`
- Benoetigt: Entra ID App Registration mit Application Permissions + Client Secret

### Modus B: Admin-Anmeldung (interaktiv)

- Auth Code Flow mit PKCE via Browser-Login
- Token gilt nur fuer die laufende Session
- Benoetigt: Entra ID App Registration mit Delegated Permissions
- Empfohlen fuer Ersteinrichtung und Tests

Welcher Modus verwendet wird, waehlst du im MDM-Tab per Radio-Button.

---

## Einrichtung

### Option 1: In-App Setup (empfohlen)

1. Tool starten, **MDM-Tab** oeffnen
2. **"+ Tenant"** — Namen eingeben
3. **Radio-Button auf "Admin-Anmeldung (diese Session)"** umschalten
4. **"Verbinden"** klicken — Browser oeffnet sich, mit **Global Admin** anmelden
5. Im Browser-Dialog: Checkbox **"Consent on behalf of your organization"** aktivieren → **Accept**
6. Zurueck im Tool: Status zeigt "Verbunden (Admin-Token)"
7. Jetzt **"App einrichten"** klicken
8. Bestaetigen — das Tool erstellt automatisch die App Registration
9. Das Tool erstellt automatisch:
   - Entra ID App Registration (`HU-NextExam-Manager-MDM`)
   - Public Client Konfiguration (PKCE, localhost Redirect URIs)
   - Application Permissions: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All`
   - Delegated Permissions: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All`
   - Admin Consent
   - Client Secret (24 Monate)
10. Credentials werden automatisch DPAPI-verschluesselt gespeichert
11. Radio-Button zurueck auf **"App-Credentials (automatisch)"** → **"Verbinden"** — fertig

> **Warum zuerst Admin-Anmeldung?** Das "App einrichten" braucht Graph-API-Rechte
> (Application.ReadWrite.All) um die App Registration zu erstellen. Diese Rechte
> muessen ueber den Admin Consent Dialog im Browser erteilt werden. Ohne diesen
> Schritt schlaegt die App-Erstellung mit "consent_required" fehl.

### Option 2: Manuell via Azure Portal

Falls der In-App Setup nicht moeglich ist (z.B. Conditional Access blockiert localhost):

1. https://entra.microsoft.com — mit Global Admin anmelden
2. **App registrations** — **+ New registration**
3. Name: `HU-NextExam-Manager-MDM`
4. Supported account types: **Single tenant**
5. Redirect URI: **Public client/native** — `http://localhost:8400/callback`
6. **Register**

Danach:

7. **Authentication** — Add platform — Mobile and desktop — weitere URIs:
   - `http://localhost:8401/callback`
   - `http://localhost:8402/callback`
8. **Allow public client flows** aktivieren
9. **API permissions** — Add permission — Microsoft Graph:
   - Application: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All`
   - Delegated: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All`
10. **Grant admin consent**
11. **Certificates & secrets** — New client secret (24 Monate) — Value kopieren

Im Tool:

12. MDM-Tab — Tenant auswaehlen — **"Verbinden"**
13. Beim ersten Verbinden fragt das Tool nach Client ID + Tenant ID + Secret
14. Credentials werden DPAPI-verschluesselt gespeichert

---

## Verwendung

### Deploy

1. MDM-Tab — Tenant auswaehlen — **"Verbinden"**
2. Tool zeigt aktuelle GitHub-Release-Version vs. Intune-Version
3. Optional: Gruppen-Zuweisung konfigurieren (Required/Available)
4. Optional: App-Metadaten anpassen (Description, Publisher, Icon)
5. **"Student deployen"** / **"Teacher deployen"** / **"Beide deployen"**

Das Tool:
- Laedt MSI von GitHub herunter
- Verpackt als `.intunewin` (IntuneWinAppUtil.exe, wird automatisch heruntergeladen)
- Erstellt oder aktualisiert die Win32 App in Intune
- Setzt Detection Rule (MSI Product Code)
- Setzt Install/Uninstall Commands (`msiexec /i ... /qn`)
- Laedt App-Icon hoch
- Weist Gruppen zu

### Status pruefen

- **"Status pruefen"** — vergleicht Metadaten zwischen GitHub-Release und Intune-App
  (Version, Description, Icon, Detection Rules)
- Dashboard-Widget zeigt Versions-Vergleich auf einen Blick

---

## Multi-Tenant

Jeder M365-Tenant braucht eine eigene App Registration. Im Tool koennen beliebig
viele Tenants konfiguriert werden. Das Dashboard zeigt den ersten konfigurierten
Tenant mit Credentials.

---

## API-Referenz

| Aktion | Endpoint |
|---|---|
| App erstellen | `POST /beta/deviceAppManagement/mobileApps` |
| App aktualisieren | `PATCH /beta/deviceAppManagement/mobileApps/{id}` |
| Content Version | `POST .../contentVersions` |
| File Upload | `POST .../contentVersions/{v}/files` → Azure Blob Upload → Commit |
| Gruppen-Zuweisung | `POST .../mobileApps/{id}/assign` |

Docs: https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management
