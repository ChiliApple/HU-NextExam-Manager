# Changelog

## v3.2.4 (2026-10-02)

### Neu
- **Auswertung im Clients-Bereich** (Dashboard) direkt in der Ueberschrift der Box, je Rolle: wie viele Clients auf dem
  aktuellen Stand sind (hoechste Zielversion im Share) und wie viele auf welcher anderen
  Version bzw. nicht installiert, z.B.
  `Student: 25 von 28 aktuell (2.1.0.3) - 2x 2.1.0.2, 1x nicht installiert`.
  Gruen = alle aktuell, orange = Abweichungen.

## v3.2.3 (2026-10-02)

### Behoben
- **Clients-Status zeigte bei gemeinsamem Status-Share alle Schulen** (z.B. BHAK + BORG
  Eisenerz auf demselben Schulserver): Nutzen mehrere Tasks denselben Status-Share, zeigt
  der Clients-Reiter pro Task nur dessen Rechner: alle Computer unter den OUs (bzw. der
  Domaene), an denen die Install-GPOs des Tasks verknuepft sind (gPLink) - unabhaengig von
  den im Task eingetragenen OUs. Nur wenn keine Verknuepfung gefunden wird, gelten die
  Student-/Teacher-OUs aus den Task-Settings. 10 min Cache, "Aktualisieren" leert ihn.
  "Aufraeumen" loescht dann nur die Eintraege dieses Tasks; ist die AD-Abfrage nicht
  moeglich, wird nicht gefiltert bzw. das Aufraeumen abgebrochen. Tasks mit eigenem
  Status-Share: unveraendert.

## v3.2.1 (2026-10-02)

### Geaendert
- **Tool startet nach jedem Pull automatisch neu** (wie HUMig/AdminTool), auch bei manuellem
  Aufruf von Pull.ps1. Laeuft der Pull als Admin, startet das Tool direkt (keine zweite
  UAC-Abfrage), sonst ueber Start.vbs. Abschaltbar mit `-NoStart`.

### Behoben
- **Erstinstallation landete im unsichtbaren Desktop-Ordner** bei OneDrive-Desktop-Umleitung:
  Pull.ps1 nutzt jetzt den echten Desktop (`[Environment]::GetFolderPath('Desktop')`)
  statt fest `%USERPROFILE%\Desktop`.
- **Admin-Warnung hinter dem Splash versteckt** (Start ohne Admin-Rechte): Der Splash
  wird vor der Meldung geschlossen, die Meldung haengt am Hauptfenster.

## v3.2.0 (2026-10-02)

### Sicherheit - signierte Updates (wie HUMig v2.0.55+)
- **Updates nur noch aus GitHub-Releases** statt vom Branch `main`. Kanal *Stabil*
  (freigegebene Releases, Standard) oder *Test* (auch Vorab-Releases).
- **Pruefsumme + Signatur:** Die CI haengt an jedes Release
  `HU-NextExam-Manager-files.sha256` (SHA256 aller Dateien). Der Herausgeber signiert
  diese Datei (PKCS#7/CMS, abgetrennt) -> `HU-NextExam-Manager-files.sha256.p7s`.
  Jeder Client prueft offline Signatur + eingebauten Fingerabdruck
  (`1B669AE240DA1A91043C4576763D9F8E0BF762FA`, gleiches Zertifikat wie HUMig).
  Unsignierte Releases werden weder angeboten noch installiert.
- **Pull.ps1 neu:** laedt erst ALLE Dateien als `*.pulltmp`, prueft jeden SHA256 und
  ersetzt erst dann; bei einem Fehler bleibt alles unveraendert. Schreibt `installed.json`
  (Version, Kanal, Pruefung). Parameter `-Version`, `-Channel`, `-WaitPid`, `-NoStart`,
  `-NonInteractive`. Startet das Tool nach einem Update aus dem Tool heraus neu.
- **Neues Modul `Modules/Update.psm1`** (Bereich `HMUpdateLib` identisch mit Pull.ps1).
- **Update-Knopf:** Update-Check im Hintergrund gegen die Releases (kein CDN-Cache-Problem
  mehr). Rechtsklick: *Andere Version / Vorversion installieren* (Liste mit Spalte
  *Signatur*), *Jetzt nach Updates suchen*, *Update-Einstellungen*; auf dem PC mit dem
  Signatur-Schluessel zusaetzlich *Release signieren* und *Release freigeben*
  (Freigabe verweigert ohne gueltige Signatur).
- **Settings > Tool-Update:** Kanal, "Nur signierte Updates annehmen (empfohlen)"
  (Abhaken nur nach Warnung, gespeichert als `AllowUnsigned` in `update.json`),
  Fingerabdruck. Der eingebaute Fingerabdruck wird nicht in `update.json` geschrieben.
- **Dashboard > Tool:** zeigt Kanal und Pruefnachweis der Installation.
- **CI (GitHub Actions):** Syntax, XAML/Steuerelemente, Update-Bibliothek identisch,
  PSScriptAnalyzer, Pester; bei Releases Pruefsummen-Datei + Test des Update-Wegs.
- **Tools/Sign-NextExamRelease.ps1:** Signieren/Freigeben per Kommandozeile.

### Neu
- **Anleitung** (`Docs/Anleitung.html`) mit Knopf *Anleitung* oben rechts bzw. `F1` -
  wird immer aktuell von GitHub geladen (passend zur installierten Version).

### Lizenz
- **Nutzungslizenz statt MIT** (wie HUMig): kostenlos benutzen und in der eigenen
  Organisation kopieren, aber nicht veraendern/weitergeben/verkaufen. Versionen bis 3.1.5
  bleiben unter MIT.

### Hinweis Umstieg
- Die erste Aktualisierung von v3.1.x laeuft noch ueber den alten Pull-Weg (ungeprueft).
  Ab v3.2.0 gilt die Signaturpruefung.

## v3.1.5 (2026-09-30)

### Geaendert
- **Verknuepfung: ein Button statt zwei** (wie HU-AdminTool v2) — im Settings-Tab
  "Desktop-Verknuepfung" gibt es nur noch den Button "Verknuepfung":
  Linksklick = eigener Desktop, Rechtsklick = oeffentlicher Desktop (alle Benutzer,
  mit Sicherheitsabfrage).

## v3.1.4 (2026-09-30)

### Feature
- **Desktop-Verknuepfung aus den Settings** — neuer Bereich "Desktop-Verknuepfung"
  im Settings-Tab mit zwei Buttons: *mein Desktop* und *alle Benutzer* (oeffentlicher
  Desktop, mit Sicherheitsabfrage). Erzeugt lokal einen Starter
  `HU-NextExam-Manager.exe` aus C#-Quelltext (Logo aus `Assets\icon.ico`, startet
  PowerShell versteckt mit UAC-Abfrage, kein Konsolenfenster, an Taskleiste
  anheftbar) und legt `HU-NextExam-Manager.lnk` darauf an. Alte Verknuepfungen auf
  `Start.vbs`/EXE desselben Tool-Ordners werden dabei ersetzt. Faellt die EXE-Erzeugung
  aus, zeigt die Verknuepfung auf `wscript.exe Start.vbs`. Muster wie HU-AdminTool v2.
  Die EXE ist gitignored und wird von `Pull.ps1` nicht angefasst.

## v3.1.3 (2026-09-11)

### Feature
- **Aufraeum-Button im Clients-Status** — im Dashboard-Reiter "Clients" gibt es
  neben "Aktualisieren" jetzt "Aufraeumen" (rot). Loescht alle `*.json`-Statusdateien
  im Status-Share des gewaehlten Tasks nach einer Sicherheitsabfrage. Zweck: veraltete
  Eintraege entfernen (z.B. nach Geraete-Umbenennung, wenn alte Rechnernamen im Status
  haengenbleiben). Die Clients legen ihre Statusdatei beim naechsten Start automatisch
  neu an. Neue Modul-Funktion `Clear-ClientStatus` in `Modules/ClientStatus.psm1`.

## v3.1.2 (2026-08-19)

### Fix
- **Start.vbs wieder mit Elevation** — in v3.1.1 war `runas` durch `open` ersetzt
  worden. Das war falsch: Elevation wird fuer die Registrierung des AutoPull-Tasks
  als SYSTEM gebraucht, und `ShellExecute` blendet das Konsolenfenster nur mit
  `runas` zuverlaessig aus (mit `open` blieb ein Fenster hinter dem Splash stehen).
  Existenzpruefung des Hauptscripts und WorkingDirectory aus v3.1.1 bleiben.

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
