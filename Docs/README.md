# HU-NextExam-Manager

WPF-Tool (PowerShell 5.1) fuer die automatische Verwaltung von Next-Exam Versionen
in Active-Directory-Umgebungen.

**Inoffizielles Drittanbieter-Tool**. Siehe `Docs/NOTICE.md` fuer Trademark-
und Nutzungsrechte-Hinweise.

## Funktion

- **MSI-Deploy:** Download offizieller Next-Exam-Releases (Student + Teacher)
  direkt von GitHub, Ablage auf konfigurierten UNC-Shares, Rolling Archive
- **GPO-Management:**
  - Install-GPOs mit PowerShell-Startup-Script (Version-Check + `msiexec /quiet`)
  - Firewall-GPOs (App-Regeln + optionale TCP/UDP-Ports)
  - WMI-Filter (Prefix/Pattern/List/Custom) automatisch erstellt + zugewiesen
- **Auto-Pull:** Scheduled Task fuer taegliche MSI-Updates (SYSTEM oder User)
- **Self-Update:** Tool aktualisiert sich via Pull.ps1 aus dem Repo
- **Dashboard + Log-Viewer** fuer Einsatzbereit-Ampel und Troubleshooting

## Anforderungen

- Windows Server 2016+ oder RSAT-Client
- PowerShell 5.1
- Module: GroupPolicy, ActiveDirectory, NetSecurity, ScheduledTasks
- Domain Admin oder delegierte GPO-Rechte

## Installation

Siehe `Docs/INSTALL.md`.

## MDM-Integration (v1.1)

Intune-Integration fuer Win32-App-Upload ueber Microsoft Graph API ist
geplant. Vorbereitung (Azure-App-Registration pro Tenant) bereits jetzt
moeglich - siehe `Docs/MDM-Setup.md`.

## Lizenz

MIT License - siehe `LICENSE`.

Third-Party Notices + Next-Exam Trademark-Hinweise - siehe `Docs/NOTICE.md`.
