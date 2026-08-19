# Changelog

## v3.1.1 (2026-08-19)

### Fix
- **Pull.ps1 war fest auf den Desktop verdrahtet** — `$Target` zeigte immer auf
  `%USERPROFILE%\Desktop\HU-NextExam-Manager`. Lag das Tool woanders (z.B. `C:\Tools`
  fuer mehrere Admins), zog ein Update die Dateien auf den Desktop des ausfuehrenden
  Users, waehrend der laufende Ordner alt blieb. Neu: liegt Pull.ps1 in einer
  Installation (`Modules\` bzw. Hauptscript daneben), wird genau dieser Ordner
  aktualisiert; liegt sie allein irgendwo, bleibt es beim Desktop-Bootstrap wie
  bisher. Optional `-Target <Pfad>`. Zusaetzlich Schreibrechte-Vorabpruefung.
- **Start.vbs startete unnoetig elevated** (`runas`). Elevation bringt fuer
  GPMC/GPO-Operationen nichts — die Rechte kommen aus AD (Domaenen-Admins /
  Richtlinien-Ersteller-Besitzer). Jetzt `open`, dazu Existenzpruefung des
  Hauptscripts und gesetztes WorkingDirectory (noetig fuer Verknuepfungen).

## v3.1.0 (2026-08-06)

### Geaendert
- GPP Scheduled Task bekommt einen RegistrationTrigger: der Task laeuft jetzt SOFORT, sobald
  Group Policy ihn anlegt/aktualisiert (naechster GP-Refresh) - ohne Reboot und ohne auf den
  taeglichen 07:30-Trigger zu warten. Behebt, dass beim ersten Rollout/Update bisher ein Boot
  bzw. der Tages-Trigger abgewartet werden musste. Boot- + Daily-Trigger bleiben als Absicherung.
  (Das Startup-ps1 ist idempotent: installiert nur bei Versionsdifferenz, sonst ~1s No-op.)
## v3.0.0 (2026-08-06)

### Geaendert
- Client-Deployment von GPO-Startup-Script auf GPO-Preferences GEPLANTER TASK (SYSTEM) umgestellt.
  Startup-Scripts feuerten auf manchen Clients beim Boot unzuverlaessig (gpscript, "0 Sekunden"-Boots)
  -> Updates blieben aus. Der Task (Trigger: Systemstart +Delay + taeglich, StartWhenAvailable) ist
  immun gegen das Boot-Timing und self-healing (GPP-CSE reapplied bei jedem Refresh).
- Bestehende Rollouts migrieren automatisch beim Re-Deploy: New-NextExamInstallGPO baut die GPO in place
  um (Task rein, scripts.ini/psscripts.ini geleert, CMD-Wrapper entfernt). GUI/Status rueckwaertskompatibel.

### Neu
- Invoke-NextExamGpoMigration: findet alle Install-GPOs einer Domaene und migriert sie auf Task-Modus
  (liest Parameter aus der vorhandenen Registrierung; Firewall-GPOs werden uebersprungen). -WhatIf fuer Dry-Run.
## v2.0.4 (2026-08-05)

### Fix
- **Fenstertitel zeigte alte Version** — Die WPF-Titelleiste war fest auf `v2.0.2` verdrahtet und hinkte der tatsaechlichen Tool-Version hinterher. Titel wird jetzt zur Laufzeit aus `$script:ToolVersion` gesetzt und bleibt dadurch immer korrekt.

## v2.0.3 (2026-08-05)

### Feature
- **Pre-Release-Unterstuetzung** — Neue Checkbox „Pre-Releases einbeziehen" im MSI-Pull-Tab. Bisher fragte das Tool ausschliesslich `/releases/latest` ab, wodurch als Pre-Release markierte Next-Exam-Versionen (z.B. 2.0.0 Pre-Release) nie gefunden wurden. Bei aktivierter Checkbox wird nun `/releases` abgefragt und das neueste nicht-Draft-Release mit passender Student/Teacher-MSI verwendet.
- Einstellung wird in der Config persistiert (`ToolSettings.IncludePrerelease`, Default `$false`) und gilt auch fuer den taeglichen headless Auto-Pull.
- Release-Anzeige markiert Pre-Releases zusaetzlich mit `[PRE-RELEASE]`.
- Standardverhalten unveraendert: ohne Haken werden weiterhin nur stabile Releases gezogen.

## v2.0.2 (2026-05-28)

### Bugfix
- **MDM Deploy: 0x80070653 behoben** — setupFilePath und installCommandLine verwenden jetzt den tatsaechlichen MSI-Dateinamen aus dem GitHub-Release (z.B. `Next-Exam-Student_1.1.3.1_20260521_x64.msi`) statt des hardcoded Namens `NextExamStudent.msi`. Der Mismatch zwischen App-Definition und hochgeladenem Content fuehrte dazu, dass msiexec die MSI-Datei nicht finden konnte (Error 1619).
- **Build-AppMetadata** akzeptiert jetzt optionalen `-MSIFileName` Parameter
- **Safety-Check in Publish-NextExamToIntune** korrigiert setupFilePath automatisch falls Mismatch erkannt wird
- **Metadaten-Vergleich**: Unicode-Normalisierung bei Sonderzeichen (En-Dash, Em-Dash, typografische Anfuehrungszeichen) verhindert falsche Abweichungsmeldungen


## v2.0.1 (2026-05-11)

### Bugfix
- **ClientStatus.psm1 v2.1.1**: Multi-JSON Parse Fix
  - Konkatenierte JSON-Objekte in Status-Dateien werden jetzt korrekt behandelt
  - Nur das erste Top-Level-Objekt wird geparst, Rest wird verworfen
  - Warnung via Write-Warning wenn Multi-JSON erkannt wird
  - Behebt Parse-Fehler bei Clients mit korrupter Status-Datei (z.B. EDV0-17-Student)

## v2.0.0 (2026-04-17)

Initial Public Release.

### Features
- MSI-Verteilung via GPO (Active Directory)
- MDM-Deployment via Intune (Microsoft Graph API)
- Entra ID App Registration In-App Setup
- Win32 LOB App Packaging + Chunked Upload
- Dashboard mit Client-Status und MDM-Widget
- Auto-Pull (Scheduled Task)
- Self-Update via GitHub
- Multi-Task-Konfiguration
