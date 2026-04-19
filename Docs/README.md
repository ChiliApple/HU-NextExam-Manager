# HU-NextExam-Manager

WPF-Tool (PowerShell 5.1) für die automatische Verwaltung von Next-Exam Versionen
in Active-Directory-Umgebungen und via Intune/MDM (Microsoft Graph API).

**Inoffizielles Drittanbieter-Tool**. Siehe `Docs/NOTICE.md` für Trademark-
und Nutzungsrechte-Hinweise.

## Funktionen

- **MSI-Deploy:** Download offizieller Next-Exam-Releases (Student + Teacher)
  direkt von GitHub, Ablage auf konfigurierten UNC-Shares, Rolling Archive
- **GPO-Management:**
  - Install-GPOs mit PowerShell-Startup-Script (Version-Check + `msiexec /quiet`)
  - Firewall-GPOs (App-Regeln + optionale TCP/UDP-Ports)
  - WMI-Filter (Prefix/Pattern/List/Custom) automatisch erstellt + zugewiesen
- **MDM-Deployment:** Intune Win32-App-Upload via Microsoft Graph API
  - Entra ID App Registration per In-App Setup-Wizard
  - Client Credentials Flow + Auth Code Flow mit PKCE
  - Chunked Azure Blob Upload, Win32 App CRUD, Gruppen-Zuweisungen
- **Auto-Pull:** Scheduled Task für tägliche MSI-Updates (SYSTEM oder User)
- **Self-Update:** Tool aktualisiert sich via Pull.ps1 aus dem Repo
- **Dashboard + Log-Viewer** für Einsatzbereit-Ampel und Troubleshooting

## Anforderungen

- Windows Server 2016+ oder RSAT-Client
- PowerShell 5.1
- Module: GroupPolicy, ActiveDirectory, NetSecurity, ScheduledTasks
- Domain Admin oder delegierte GPO-Rechte

## Installation

Siehe `Docs/INSTALL.md` oder die Hauptdokumentation in `README.md`.

## Lizenz

MIT License - siehe `LICENSE`.

Third-Party Notices + Next-Exam Trademark-Hinweise - siehe `Docs/NOTICE.md`.
