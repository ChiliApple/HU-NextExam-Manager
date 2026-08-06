# Changelog

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
