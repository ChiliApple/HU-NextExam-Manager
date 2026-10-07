<h1 align="center"><img src="Assets/crane_check_icon.png" width="44" alt="" align="absmiddle"/> HU-NextExam-Manager</h1>

<p align="center"><b>Next-Exam automatisch verteilen – per GPO im Active Directory und per Intune</b><br>
Neue Versionen laden, auf die Shares legen, Install- und Firewall-GPOs mit WMI-Filtern anlegen –<br>
oder als Win32-App über Microsoft Graph in Intune verteilen. Einmal eingerichtet, läuft der Rest täglich von selbst.</p>

<p align="center">
  <a href="https://github.com/ChiliApple/HU-NextExam-Manager/releases/latest"><img src="https://img.shields.io/github/v/release/ChiliApple/HU-NextExam-Manager?label=Version&color=b9a88a" alt="Version"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows%20Server-2016%2B%20%7C%20RSAT-0078D6" alt="Windows Server 2016+ | RSAT">
  <img src="https://img.shields.io/badge/Intune-Microsoft%20Graph-2E7D32" alt="Intune / Microsoft Graph">
  <img src="https://img.shields.io/badge/Oberfl%C3%A4che-WPF-8839ef" alt="WPF">
  <a href="https://github.com/ChiliApple/HU-NextExam-Manager/actions/workflows/ci.yml"><img src="https://github.com/ChiliApple/HU-NextExam-Manager/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-Nutzung%20frei-orange" alt="Lizenz"></a>
</p>

<p align="center">
  <a href="https://chiliapple.github.io/HU-NextExam-Manager/Docs/Anleitung.html"><b>Anleitung</b></a> ·
  <a href="Docs/INSTALL.md">Installation</a> ·
  <a href="Docs/MDM-Setup.md">MDM-Setup</a> ·
  <a href="Docs/CHANGELOG.md">Änderungen</a> ·
  <a href="LICENSE">Lizenz</a>
</p>

---

| | |
|---|---|
| **MSI Pull** | offizielle [Next-Exam](https://github.com/Bildungsportal/next-exam)-Releases (Student + Teacher) laden, auf die Shares legen, alte Versionen in `_archive\` (letzte 3) |
| **GPO Setup** | Install-GPOs (Startup-Script mit Versions-Check) + Firewall-GPOs, **WMI-Filter** für Student/Teacher in derselben OU, Verknüpfung mit den OUs |
| **MDM Deploy** | Win32-App über **Microsoft Graph** in Intune – App-Registrierung per Assistent, Paketierung, Upload, Gruppen-Zuweisung, Versions-Vergleich |
| **Auto-Pull** | geplante Aufgabe täglich (SYSTEM oder Benutzer) – neue Next-Exam-Version kommt ohne Zutun auf die Shares |
| **Client-Status** | Clients melden installierte Version zurück – Übersicht je Task im **Dashboard**, mit Aufräumen |
| **Mehrere Schulen** | mehrere Tasks pro Server (Domäne, Shares, OUs, Filter), portable Konfiguration |
| **Update** | Kanal **Stabil** oder **Test**, Vorversion per Klick, jede Datei per **SHA-256** geprüft, nur **signierte** Releases werden installiert |
| **Anleitung** | im Tool mit **F1** oder Knopf **Anleitung** – immer aktuell aus diesem Repository |

<table>
  <tr>
    <td align="center"><a href="Docs/screenshots/dashboard.png"><img src="Docs/screenshots/dashboard.png" width="390" alt="Dashboard"/></a><br><sub>Dashboard</sub></td>
    <td align="center"><a href="Docs/screenshots/mdm.png"><img src="Docs/screenshots/mdm.png" width="390" alt="MDM Deploy"/></a><br><sub>MDM Deploy (Intune)</sub></td>
  </tr>
</table>

## Schnellstart

1. `Pull.ps1` in einen leeren Ordner legen und als Domain-Admin ausführen (Befehl unter [Bootstrap-Install](#bootstrap-install))
2. **Start.vbs** starten (UAC bestätigen)
3. **Settings** → Task anlegen → **MSI Pull** → **GPO Setup** – Details im [Erst-Setup](#erst-setup)

Details: [Docs/INSTALL.md](Docs/INSTALL.md) und die [Anleitung](https://chiliapple.github.io/HU-NextExam-Manager/Docs/Anleitung.html) (im Tool mit **F1**).

**Inhalt:** [Installation](#installation) · [Die Oberfläche](#die-oberfläche) · [Erst-Setup](#erst-setup) · [WMI-Filter](#wmi-filter-konfigurieren-beispiel) · [Auto-Pull](#auto-pull-automatisieren) · [Client-Status](#client-status) · [Repo-Struktur](#repo-struktur) · [Known Issues](#known-issues--manuelle-nacharbeit) · [Lizenz](#lizenz)

> **Inoffizielles Drittanbieter-Tool** – kein Produkt des Next-Exam-Projekts. Hinweise: [Docs/NOTICE.md](Docs/NOTICE.md).

---

## Installation

### Voraussetzungen

**GPO-Deployment (Active Directory):**

- Windows Server 2016+ oder Client mit RSAT
- PowerShell 5.1 (Standard in allen aktuellen Windows-Versionen)
- RSAT-Module: `GroupPolicy`, `ActiveDirectory`, `NetSecurity`
- Domain-Admin-Konto (oder delegierte GPO-Rechte)

**MDM-Deployment (Intune) — zusätzlich:**

- Microsoft 365 Tenant mit Intune-Lizenzierung
- Globaler Administrator oder Intune Administrator Rolle
  (für Entra ID App Registration + Admin Consent)
- Intune-gemanagte Geräte (Autopilot oder manuell enrolled)
- Internetzugang vom Admin-Rechner (Graph API + Azure Blob Upload)

### Bootstrap-Install

Einmal pro Server. Als Domain-Admin-User:

```powershell
$d = Join-Path $env:USERPROFILE 'Desktop\HU-NextExam-Manager'
New-Item -ItemType Directory -Path $d -Force | Out-Null
Invoke-WebRequest "https://raw.githubusercontent.com/ChiliApple/HU-NextExam-Manager/main/Pull.ps1" `
    -UseBasicParsing -OutFile (Join-Path $d 'Pull.ps1')
cd $d; .\Pull.ps1
```

> **Hinweis:** `Pull.ps1` lädt das neueste **signierte** Release (Kanal Stabil) und prüft
> jede Datei per SHA256 und die Signatur des Herausgebers, bevor etwas ersetzt wird.
> Downloads laufen über `raw.githubusercontent.com` beim Commit des Releases.

### Starten

Doppelklick auf **Start.vbs** - triggert UAC-Prompt (Tool braucht Admin für GPO),
läuft dann fensterlos und das Tool-Fenster kommt nach ~3 Sekunden.

### Update (signierte Releases)

Im Tool: **Gold-Update-Button** oben rechts, wenn im eingestellten Kanal eine neuere,
**signierte** Version verfügbar ist. Klick → Tool schliesst, `Pull.ps1` lädt, prüft
und startet das Tool neu. Oder manuell `.\Pull.ps1` ausführen (Tool vorher schliessen).

- Updates kommen ab v3.2.0 nur noch aus **GitHub-Releases**: Kanal *Stabil* = freigegebene
  Releases, Kanal *Test* = auch Vorab-Releases.
- Jedes Release hat `HU-NextExam-Manager-files.sha256` (SHA256 aller Dateien, von der CI erstellt)
  und `HU-NextExam-Manager-files.sha256.p7s` (PKCS#7-Signatur des Herausgebers,
  Zertifikat-Fingerabdruck `1B669AE240DA1A91043C4576763D9F8E0BF762FA` ist eingebaut).
  Ohne gültige Signatur wird ein Release weder angeboten noch installiert.
- Erst werden **alle** Dateien geladen und geprüft, dann ersetzt – bei einer Abweichung bleibt alles unverändert.
- **Rechtsklick auf Update:** andere Version / Vorversion, Update-Einstellungen
  (Settings › Tool-Update: Kanal, „Nur signierte Updates annehmen“), auf dem PC des
  Herausgebers zusätzlich *Release signieren* / *Release freigeben*.
- Kommandozeile für den Herausgeber: `Tools\Sign-NextExamRelease.ps1`.

**[Anleitung](https://chiliapple.github.io/HU-NextExam-Manager/Docs/Anleitung.html):** Knopf **Anleitung** oben rechts (oder `F1`) – lädt `Docs/Anleitung.html`
immer aktuell von GitHub.

---

## Die Oberfläche

Das Tool hat **sechs Tabs**:

### Dashboard
Die zentrale Übersicht. Zeigt oben Tool-Info + den aktuellen GitHub-Release,
in der Mitte die **Clients** pro Task (welcher PC hat welche Version installiert?),
unten die **Tasks-Übersicht** mit Ampel-Status (MSI aktuell? GPOs gesetzt?).

### MSI Pull
- Klick **"Release abfragen"** → Tool holt aktuelle Next-Exam Version von GitHub
- Klick **"Changelog..."** → Release-Notes als Markdown/Text speicherbar
- **Task markieren + "Auswahl aktualisieren"** → Download MSIs einmal nach TEMP,
  dann Copy auf den Student/Teacher-Share des Tasks. Alte MSIs landen in `_archive\`
  (nur die letzten 3 werden aufgehoben)
- **Auto-Pull-Checkbox**: Scheduled Task registrieren der täglich läuft
  - **SYSTEM** = läuft ohne Anmeldung, braucht Machine-Account-Rechte auf Shares
  - **User** = läuft nur bei Anmeldung, holt verpasste Zeiten beim Login nach

### MDM Deploy
Intune Win32-App-Deployment via Microsoft Graph API für Geräteinitiative-Notebooks
(Autopilot/Intune-managed, kein Domain-Join).

> **Wichtig:** Vor dem erstmaligen **"App einrichten"** muss einmal die
> **Admin-Anmeldung** (Radio-Button) durchgeführt werden. Dabei wird der
> Admin Consent für "Microsoft Graph Command Line Tools" im Tenant erteilt.
> Checkbox **"Consent on behalf of your organization"** aktivieren!
> Danach kann auf App-Credentials (automatisch) umgeschaltet werden.

- **Entra ID App Registration**: In-App Setup erstellt automatisch die benötigte
  App Registration im Tenant (inkl. Permissions, Admin Consent, Client Secret)
- **Auth**: Client Credentials Flow (unattended) + Auth Code Flow mit PKCE (interactive)
- **Credential Store**: DPAPI-verschlüsselte Secrets in `%APPDATA%\HU-NextExam\`
- **Packaging**: Automatischer Download von `IntuneWinAppUtil.exe`, MSI → `.intunewin`
- **Upload**: Chunked Azure Blob Upload (6 MB Blocks) für grosse Pakete
- **Win32 App CRUD**: Erstellen, Aktualisieren, Löschen von Win32 LOB Apps via Graph beta
- **Gruppen-Zuweisungen**: Required + Available for enrolled devices
- **Dashboard-Widget**: Zeigt aktuelle GitHub-Release-Version vs. Intune-deployed Version
- **Status-Vergleich**: Metadaten-Diff (Version, Description, Icon, Detection Rules)

Voraussetzung: Entra ID App Registration pro Tenant - siehe **[Docs/MDM-Setup.md](Docs/MDM-Setup.md)**
oder den In-App-Setup-Button im MDM-Tab.

### GPO Setup
Oben die Tasks-Liste mit Status für alle 4 GPOs pro Task
(Install Student/Teacher + Firewall Student/Teacher).
Unten Detail-Panel mit allen Pfaden, Filtern, Rechten für den markierten Task.

Buttons:
- **Install-GPOs** → legt GPOs an mit Startup-Script (PowerShell, msiexec /quiet)
- **FW-GPOs** → Firewall-Regeln (App-Rules + optional Ports)
- **Mit OU verknüpfen** → GPO-Link zur OU aus dem Task
- **WMI-Filter cleanup** → entfernt alte WMI-Filter des Tasks (falls korrupt)
- **GPOs entfernen** → Remove-GPO für alle 4 GPOs des Tasks

### Settings
Multi-Task-Konfiguration (mehrere Deploy-Konfigurationen pro Server möglich).
Pro Task:
- Domain, DC-Server
- Student-/Teacher-Share (UNC-Pfad)
- Status-Share (optional, für Client-Feedback)
- OU-Ziele (DistinguishedNames)
- WMI-Filter (siehe unten)
- GPO-Name-Präfix (Default: `HU-NEXT-EXAM-`)
- Firewall-Einstellungen (Profile, EXE-Pfade, optional Ports)

### Log-Viewer
Live-Ansicht von `%LOCALAPPDATA%\HU-NextExam-Manager\NextExam-Manager.log`.
Filter nach Level (DEBUG/INFO/WARN/ERROR), Volltext-Suche, Log löschen.

---

## Erst-Setup

1. Tool starten → **Settings**-Tab
2. **"+ Neu"** → Task-Namen eingeben
3. Felder füllen:
   - Domain FQDN z.B. `schule.local`
   - DC-Server (Hostname oder IP)
   - Student-Share UNC z.B. `\\FILESRV\install\NEXT-EXAM\Student`
   - Teacher-Share UNC z.B. `\\FILESRV\install\NEXT-EXAM\Teacher`
   - OU-Ziel Student+Teacher als **DistinguishedName**
     `OU=Workstations,OU=EDV,DC=schule,DC=local`
   - WMI-Filter (siehe unten)
   - GPO-Präfix bleibt bei `HU-NEXT-EXAM-`
4. **"Task speichern"**
5. **MSI Pull**-Tab → "Release abfragen" → Task markieren → "Auswahl aktualisieren"
6. **GPO Setup**-Tab → Task markieren → "Install-GPOs" → "FW-GPOs" → "Mit OU verknüpfen"
7. Client neu starten (oder `gpupdate /force` + Reboot) → MSI wird installiert

---

## WMI-Filter konfigurieren (Beispiel)

Wenn Student- und Teacher-PCs in **derselben OU** liegen, musst du über
WMI-Filter trennen welcher PC welche GPO bekommt.

### Typisches Szenario

Naming-Convention: Teacher-PC im Raum endet auf `-01` (z.B. `PC-EDV1-01`),
Schüler-PCs haben jede andere Nummer (`PC-EDV1-02`, `PC-EDV1-03`, ...).

### Settings eintragen

| Feld | Typ | Muster |
|------|-----|--------|
| WMI-Filter **Student** | `Custom` | `SELECT * FROM Win32_ComputerSystem WHERE NOT Name LIKE '%-01'` |
| WMI-Filter **Teacher** | `Custom` | `SELECT * FROM Win32_ComputerSystem WHERE Name LIKE '%-01'` |

### Regeln für das Muster-Feld

- **Einfache Anführungszeichen** `'` (nicht doppelte `"`)
- **Keine Klammern** um den LIKE-Ausdruck
- **Typ `Custom`** wenn `NOT`, `AND`, `OR` vorkommt
- **Typ `Pattern`** reicht für reine LIKE-Fälle (Muster z.B. `%-01`)
- **Typ `Prefix`** für Hostname-Prefixe (Muster z.B. `PC-S` → `Name LIKE 'PC-S%'`)
- **Typ `List`** für explizite Liste (Muster z.B. `PC1,PC2,PC3`)

### Was passiert dann

Beim Klick auf **"Install-GPOs"** legt das Tool automatisch an:
- `HU-NEXT-EXAM-WMI Student` in AD (unter CN=SOM,CN=WMIPolicy,CN=System,...)
- `HU-NEXT-EXAM-WMI Teacher` in AD
- Verknüpft beide mit den jeweiligen Install- und Firewall-GPOs

### Filter-Muster ändern

Das Tool überschreibt keine bestehenden Filter. Bei Pattern-Änderung:
1. **"WMI-Filter cleanup"** im GPO-Setup-Tab → löscht alte Filter des Tasks
2. **"Install-GPOs"** → legt frische Filter mit neuem Muster an

### Verifizieren in GPMC

- `WMI-Filter` Ordner → beide Filter sichtbar
- Einzelne GPO → Tab **"Geltungsbereich"** → Feld **"WMI-Filterung"** → zeigt den zugewiesenen Filter

---

## Auto-Pull automatisieren

**MSI Pull**-Tab → Checkbox **"Auto-Pull täglich um HH:mm"**:
- Default `03:00` (anpassbar)
- **SYSTEM-Mode** empfohlen für produktiven Dauerbetrieb (braucht Share-ACL
  für Machine-Account `DOMAIN\<COMPUTERNAME>$`)
- **User-Mode** wenn Admin-Rechte nicht zentral konfigurierbar

Scheduled Task liegt unter `\HU-NextExam-Manager\AutoPull` (SYSTEM) oder
direkt im Root `\AutoPull` (User-Mode). Ruft das Tool mit `-AutoPull`-Flag
headless auf - skipped Tasks die bereits die aktuelle Version haben.

---

## Client-Status

Wenn pro Task ein **Status-Share** konfiguriert ist, schreibt das Client-
Startup-Script nach jedem Install-Check eine JSON-Datei zurück:

```json
{
  "ComputerName": "PC-EDV1-01",
  "Role": "Teacher",
  "Installed": "1.1.3.1",
  "Target": "1.1.3.1",
  "LastCheck": "2026-04-15T03:02:14+02:00",
  "LastAction": "aktuell"
}
```

Im **Dashboard** siehst du alle Clients eines Tasks mit Status.

**Einrichtung:**
1. Settings → Task → **Status-Share-Pfad** eintragen (Default-Vorschlag wird
   aus dem Student-Share abgeleitet: `<Parent>\_status`)
2. Button **"Anlegen + ACL"** → legt Ordner an, setzt NTFS-ACL:
   - Domain-Computers: Write + Read (Clients können schreiben)
   - Domain-Admins: FullControl
   - Vererbung deaktiviert (nur dieser Ordner)
3. Install-GPOs neu erstellen → Startup-Script bekommt den Status-Pfad
4. Client-Reboot → JSON wird geschrieben → im Dashboard sichtbar

---

## Repo-Struktur

```
HU-NextExam-Manager/
├── HU-NextExam-Manager.ps1  # Main (WPF-UI, PS 5.1)
├── Pull.ps1                 # Self-Update / Bootstrap (signierte Releases)
├── LICENSE                  # Nutzungslizenz
├── Tools/
│   └── Sign-NextExamRelease.ps1  # Release signieren/freigeben (Herausgeber)
├── .github/                 # CI: Tests, Pruefsummen-Datei fuer Releases
├── Start.vbs                # Fensterloser Launcher (mit UAC-Elevation)
├── README.md                # Diese Datei
├── Assets/
│   ├── icon.ico
│   ├── icon.png
│   └── crane_check_icon.png
├── Docs/
│   ├── Anleitung.html       # Benutzer-Anleitung (Knopf "Anleitung" / F1)
│   ├── INSTALL.md
│   ├── MDM-Setup.md
│   ├── CHANGELOG.md
│   ├── NOTICE.md
│   └── config.json.example
├── Modules/
│   ├── Config.psm1
│   ├── Logging.psm1
│   ├── MSIPull.psm1
│   ├── MDMDeploy.psm1
│   ├── WMIFilter.psm1
│   ├── GPOSetup.psm1
│   ├── AutoPull.psm1
│   ├── Update.psm1          # Tool-Update: Releases, SHA256, Signatur
│   └── ClientStatus.psm1
├── Templates/
│   └── Startup-NextExam.ps1  # Client-Startup-Script (via GPO deployed)
└── XAML/
    └── MainWindow.xaml
```

---


## Known Issues / Manuelle Nacharbeit

### 1. GPO "Nicht angewendet (Leer)" nach Install-GPOs erstellen

**Problem:** Nach dem Erstellen der Install-GPOs über das Tool zeigt `gpresult`
die GPOs als "Nicht angewendet (Leer)" an. Die Scripts-CSE erkennt die
programmatisch geschriebenen `scripts.ini` / `psscripts.ini` nicht als gültig.

**Workaround (manuell, pro Install-GPO):**
1. GPMC öffnen (`gpmc.msc`)
2. Die betroffene GPO finden (z.B. `HU-NEXT-EXAM-Student-Install`)
3. Rechtsklick → **Bearbeiten**
4. Computerkonfiguration → Windows-Einstellungen → **Skripts (Starten/Herunterfahren)**
5. **Starten** doppelklicken
6. Das CMD-Script (`Startup-NextExam.cmd`) sollte bereits gelistet sein
7. Einfach **OK** klicken (nichts ändern, nur bestätigen)
8. Editor schliessen
9. Für **beide** Install-GPOs wiederholen (Student + Teacher)

---

## Lizenz

Nutzungslizenz ab v3.2.0 (kostenlos benutzen, nicht verändern/weitergeben) – siehe [LICENSE](LICENSE).
Versionen bis 3.1.5 wurden unter der MIT-Lizenz veröffentlicht.
Next-Exam-Hinweise: [Docs/NOTICE.md](Docs/NOTICE.md).
