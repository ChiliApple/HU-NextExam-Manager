# Changelog

## v3.4.0 (2026-10-10)

Restliche Befunde aus der Code-Pruefung (MITTEL/NIEDRIG) und Daten-Ordner `Config\`.

### Wichtig nach dem Update
- **Daten liegen jetzt in `Config\`:** `config.json`, `update.json` und `installed.json` werden beim ersten Start
  (bzw. beim naechsten Tool-Update) aus dem Programmordner nach `Config\` verschoben. Nichts zu tun. Wer die Dateien
  von Hand bearbeitet, findet sie dort. Beim Wechsel auf eine Version vor 3.4.0 kopiert das Update sie zurueck.
- **Status-Share einrichten erneut ausfuehren** (Reiter Clients, je Task): Die PCs duerfen im Status-Share nur noch
  eigene Dateien anlegen und aendern, nicht mehr die Dateien anderer PCs ueberschreiben oder loeschen.
- **Intune: naechstes Deploy passt die Erkennungsregel an.** Bisher galt jede installierte Version als "installiert"
  (Datei vorhanden) - Updates kamen per Intune nie an, und der Deinstallations-Befehl enthielt noch `{PRODUCT-CODE}`.
- Aenderungen an `Pull.ps1` (Tool-Update) wirken erst beim uebernaechsten Update - das laufende Update macht noch der
  bisherige Pull; das Tool verschiebt die Dateien dann beim Start selbst.

### Sicherheit
- **GitHub-Token geschuetzt:** Ein Token in `config.json` (`ToolSettings.GitHubToken`, fuer alle Benutzer lesbar) wird
  beim Start nach `Config\github-token.dat` uebernommen - verschluesselt (DPAPI, Rechner) und nur fuer
  Administratoren/SYSTEM lesbar; das Feld in `config.json` (und in Kopien wie `config.json.bak`) wird geleert. Neuer Token:
  wieder in `config.json` eintragen. Beim Wechsel auf eine Version vor 3.4.0 kommt er zurueck in `config.json`.
- **Status-Share:** PCs (Domain Computers) erhalten nur noch *Dateien erstellen* + *Lesen* im Ordner; Aendern nur der eigenen
  Datei (Besitzer). Lokale Administratoren am Server: Vollzugriff.
- **Intune-App-Setup:** Beim erneuten Einrichten wird das bisherige Secret des eigenen Benutzers und abgelaufene Secrets
  des Tools entfernt (vorher kam jedes Mal ein weiteres gueltiges Secret dazu). Secrets anderer Admins bleiben.
- **GPO neu anlegen nur bei echtem Zugriffsfehler:** Die Rueckfrage "GPO loeschen und neu anlegen" kam auch bei Meldungen
  wie *nicht gefunden* (z.B. Freigabe fehlt) - jetzt nur noch bei "Zugriff verweigert".

### Behoben
- **Intune: Erkennung per MSI-ProductCode und Version** (>= neue Version) statt "Datei vorhanden"; bei vorhandenen Apps
  werden Erkennung, Deinstallation und Installations-Befehl beim Update mit aktualisiert. `{PRODUCT-CODE}` wird aus der MSI
  eingesetzt.
- **GPO-Version:** Scheitert das Setzen der Version in AD oder GPT.INI, gibt es jetzt einen Fehler statt einer Warnung
  (sonst uebernehmen die PCs die Aenderung nicht). Kein Ueberlauf mehr bei grossen Versionsnummern; Schreiben und Pruefen am
  selben DC.
- **Auto-Pull je Rolle:** Fehlt im Release die Student- oder Teacher-MSI oder hat ein Task nur eine Freigabe, wird die
  andere Rolle trotzdem verteilt (vorher brach der ganze Lauf ab bzw. der Task wurde uebersprungen). MSI-Download nur, wenn
  eine Freigabe nicht aktuell ist.
- **Config wird atomar gespeichert** (Zwischendatei, vorheriger Stand als `config.json.bak`). Ist `config.json` beschaedigt,
  wird der letzte gute Stand geladen.
- **Intune-App-Setup:** Die Client-ID wird beim richtigen Tenant gespeichert (vorher: falsche Variable, nichts gespeichert;
  bei inzwischen geaenderter Auswahl beim falschen Tenant).
- **Log:** Das Intune-Deploy im Hintergrund schreibt in dieselbe Log-Datei mit derselben Stufe wie die Oberflaeche.
- **Gleichzeitiges Verteilen** auf dieselbe Freigabe (Oberflaeche und Auto-Pull) wird gesperrt.

## v3.3.2 (2026-10-10)

### Behoben
- **Verknuepfung der Firewall-GPOs wird angezeigt:** Reiter GPO Setup und Dashboard zeigten bei den FW-GPOs nur, ob die GPO
  und ihre Regeln existieren ("OK (2 Rules)") - nicht, ob sie mit der OU verknuepft ist. Eine nicht verknuepfte FW-GPO wirkt
  auf keinem PC; Next-Exam loest dann beim Start die Windows-Firewall-Abfrage aus. Jetzt: *OK (2 Rules, verknuepft)*,
  *NICHT verknuepft (2 Rules)* oder *andere OU*; im Dashboard *pruefen: nicht verknuepft* (Gesamt: Handlungsbedarf).
- **Verknuepfen prueft nach:** Nach dem Anlegen wird kontrolliert, dass die Verknuepfung an der OU steht; sonst gibt es eine
  Fehlermeldung statt eines stillen Erfolgs.

## v3.3.1 (2026-10-10)

Korrekturen aus der Code-Pruefung (alle HOCH-Befunde und mehrere MITTEL-Befunde).

### Wiederhergestellt
- **Auswertung unter der Clients-Liste** aus v3.2.4 (z.B. `Student: 25 von 28 aktuell (2.1.0.3) - 2x 2.1.0.2`,
  gruen = alle aktuell, orange = Abweichungen). v3.2.4 war nur als Release veroeffentlicht, nicht im Hauptzweig - v3.3.0 wurde
  ohne diese Aenderung gebaut.

### Wichtig nach dem Update
- **Install-GPOs neu schreiben:** Das neue Startup-Skript (keine Updates waehrend einer Pruefung) wirkt erst, wenn es in
  SYSVOL liegt. Reiter GPO: Tasks markieren, **Install-GPOs**. Der GPO-Status zeigt bis dahin *Skript veraltet*.
- **Next-Exam-MSIs werden nur noch verteilt, wenn sie gueltig vom Herausgeber signiert sind** (Standard:
  `Open Source Open Schools (OSOS) Austria`). Aendert der Hersteller das Zertifikat oder den Namen, in `config.json`
  `ToolSettings.MsiTrustedPublisher` anpassen.

### Pruefungstag / Clients (Startup-Skript)
- **Kein Update, solange Next-Exam laeuft:** Eine stille MSI-Installation beendet laufende Programme (Windows Installer /
  Restart Manager) - mitten in einer Pruefung haette das den Pruefungsclient geschlossen. Laeuft Next-Exam, wird das Update
  verschoben (Status *verschoben (laeuft)*) und beim naechsten Lauf nachgeholt.
- **Sperrdatei `update-freeze.txt`** im Install-Share: solange sie existiert, wird nichts installiert oder aktualisiert
  (z. B. am Pruefungstag). Datei anlegen = gesperrt, loeschen = frei.
- **Versionsvergleich numerisch:** `1.2.30` galt bisher als gleich wie `1.2.3` (Praefix-Vergleich) - Updates wurden
  ausgelassen. Eine aeltere Version im Share wird nicht mehr automatisch installiert (kein Downgrade).
- **Status zeigt die tatsaechlich installierte Version** (nach einem fehlgeschlagenen Update stand bisher die Ziel-Version
  als installiert da). msiexec 1641 gilt als Erfolg, 1618 als *verschoben*.
- **GPO-Status:** *OK* nur noch, wenn Skript, geplante Aufgabe und Abloesung des alten Startup-Skripts vorhanden sind und das
  Skript in SYSVOL dem Stand des Tools entspricht; sonst *unvollstaendig (...)* bzw. *Skript veraltet*.

### GPOs
- **Vorhandene GPO gleichen Namens wird nur verwendet, wenn sie vom HU-NextExam-Manager stammt.** Sonst Abbruch mit Hinweis
  (anderen GPO-Praefix waehlen).
- **Andere Einstellungen in der Install-GPO bleiben erhalten:** Die CSE-Liste wird ergaenzt statt ersetzt, aus
  `scripts.ini`/`psscripts.ini` wird nur der eigene alte Eintrag entfernt, in `ScheduledTasks.xml` nur die eigene Aufgabe
  ersetzt (bisher gingen fremde Skripte, GPP-Aufgaben und Einstellungen anderer Erweiterungen verloren).
- **Zwei Tasks derselben Domaene mit gleichem GPO-Praefix** werden erkannt: Warnung beim Speichern, GPO erstellen /
  entfernen / WMI-Filter cleanup werden fuer diese Tasks gesperrt (sie wuerden sich gegenseitig ueberschreiben bzw. loeschen).
  Wer bisher absichtlich zwei solche Tasks hatte: einem Task einen neuen Praefix geben. Dabei entstehen neue GPOs; die alten
  bleiben verknuepft, bis sie in der GPMC entfernt werden.
- Die Rueckfrage beim Entfernen nennt alle vier GPOs (Install und Firewall); WMI-Filter cleanup fragt vorher nach.
- Task-Ids sind jetzt immer eindeutig (bisher aus dem Namen abgeleitet: "BG Nord" und "BG-Nord" ergaben dieselbe Id).

### Intune / MDM
- **Token gehoert zum Tenant:** Nach einem Wechsel des MDM-Tenants wurde bisher mit dem Token des vorherigen Tenants
  gearbeitet (Deploy, Status, Gruppen landeten im falschen Tenant). Jetzt wird beim Wechsel alles verworfen und neu verbunden.
- **App nur ueber den exakten Namen** `Next-Exam-Student`/`Next-Exam-Teacher`; aehnlich benannte Apps werden nie angefasst.
  Gibt es den Namen mehrfach, bricht das Tool ab und nennt die Ids, statt eine beliebige App zu aendern.
- **Alte MSI-App ersetzen (loeschen + neu anlegen) nur nach Rueckfrage** mit Name und Id.
- Anlegen (POST) wird bei HTTP 503/504 nicht mehr automatisch wiederholt (konnte doppelte Apps erzeugen).
- Version und Metadaten werden erst nach erfolgreichem Upload gesetzt; ein Upload-Abbruch fuehrt nicht mehr dazu, dass die
  neue Version spaeter als "bereits aktuell" uebersprungen wird. Zeitueberschreitung beim Commit gilt nicht mehr als Erfolg.
- Die App-Suche liest alle Ergebnisseiten.

### MSI-Verteilung
- **Authenticode-Pruefung vor dem Verteilen** (Oberflaeche und Auto-Pull): Signatur gueltig, Herausgeber wie in
  `ToolSettings.MsiTrustedPublisher`, optional nur bestimmte Zertifikate (`ToolSettings.MsiTrustedThumbprints`). Zusaetzlich
  Abgleich mit der SHA256-Pruefsumme des GitHub-Releases, wenn GitHub sie liefert.
- **Verteilen auf den Share ohne Halbzustand:** Kopie unter Hilfsnamen, Pruefsumme vergleichen, dann alte MSI archivieren
  und umbenennen; `version-*.json` zuletzt. Gleiche Datei wird nicht erneut kopiert.
- **Auto-Pull meldet Fehler** im Ergebnis der geplanten Aufgabe (Exitcode 1) statt immer 0.

## v3.3.0 (2026-10-10)

Update-Weg auf den gemeinsamen Standard der HU-Tools gebracht (wie HU-MultiTenant und HUMig). Fuer die Next-Exam-Verteilung an
den Schulen aendert sich nichts.

### Sicherheit
- **Programmordner wird abgesichert:** Tool und Auto-Pull laufen mit Administrator- bzw. SYSTEM-Rechten direkt aus dem
  Programmordner. Liegt er z. B. unter `C:\Tools`, erben Standardbenutzer von `C:\` das Recht, dort Dateien anzulegen - etwa eine
  `update.json`, die das naechste Update auf eine fremde Quelle umlenkt. Bei jedem Start (Oberflaeche und Auto-Pull) wird jetzt
  geprueft, ob nur Administratoren und SYSTEM schreiben duerfen; wenn nicht, wird der Ordner abgesichert: Besitzer
  Administratoren, Vererbung aus, SYSTEM und Administratoren Vollzugriff, Benutzer Lesen. Eigene Rechte anderer Konten und
  Gruppen auf den Programmordner werden dabei entfernt. Verknuepfungen (Junction/Symlink) im Ordner werden entfernt (nur der
  Link). Ausgenommen: Netzlaufwerke, Ordner in Benutzerprofilen, Laufwerkswurzeln. Gelingt das Absichern nicht, fragt die
  Oberflaeche nach; der Auto-Pull bricht ab (Eintrag im Absturzprotokoll `%TEMP%\HU-NextExam-Manager-crash.log`).

### Tool-Update
- **Ruecksicherung beim Ersetzen:** Jede bisherige Datei wird zuerst zu `*.pullold`. Ist eine Datei gesperrt, wird alles
  zurueckgestellt - nie mehr ein halb aktualisiertes Tool.
- **Journal** `Config\pull-journal.json`: Bricht ein Update mittendrin ab (Absturz, Strom), stellt der naechste Pull-Lauf den
  alten Stand wieder her. Solange das Journal existiert, startet das Tool nicht (es bietet an, `Pull.ps1` auszufuehren) und der
  Auto-Pull setzt aus.
- **Aufraeumen:** Dateien, die es in der neuen Version nicht mehr gibt, werden entfernt - nur solche, die frueher per Update
  installiert wurden (`FileList` in `installed.json`). Eigene Dateien, `config.json`, `update.json`, `Config\` und `Logs\`
  bleiben immer unberuehrt. Einmalig wird ein frueher mitinstallierter Ordner `.github` entfernt (nicht in Arbeitskopien mit `.git`).
- **Release-Liste ohne Zwischenspeicher** (ein gerade signiertes Release erscheint sofort) und **Ausweichweg** beim Laden von
  Pruefsumme/Signatur (bei HTTP 503 von github.com ueber die API) - Update-Bibliothek auf dem Stand von HUMig v2.0.99.
- **Wichtig:** Ein Update laeuft immer mit dem bisher installierten `Pull.ps1`. Ruecksicherung, Journal und Aufraeumen wirken
  deshalb erst beim **naechsten** Update nach 3.3.0. Die Absicherung des Programmordners wirkt sofort beim ersten Start von 3.3.0.

### Geaendert
- **Versionsnummer** steht jetzt nur noch in `Config\version.json` (vorher im Hauptskript).
- **Einzelinstanz je Programmordner:** Zwei Installationen auf einem Server (z. B. zwei Schulen) koennen gleichzeitig laufen;
  derselbe Ordner bleibt auf eine Instanz begrenzt. Der Auto-Pull laeuft je Programmordner hoechstens einmal gleichzeitig.
- **Releases:** Ein Push auf main mit neuer Version legt das Vorab-Release (Kanal Test) automatisch an, Text aus diesem
  CHANGELOG; die automatischen Tests haengen die Pruefsummen-Datei an und pruefen danach den Update-Weg einschliesslich
  abgebrochenem Update und Aufraeumen. Es bleiben die letzten 10 Releases erhalten (das aktuelle stabile Release immer).

## v3.2.4 (2026-10-02)

### Neu
- **Auswertung im Clients-Reiter** unter der Liste, je Rolle: wie viele Clients auf dem
  aktuellen Stand sind (hoechste Zielversion im Share) und wie viele auf welcher anderen
  Version bzw. nicht installiert, z.B.
  `Student: 25 von 28 aktuell (2.1.0.3) - 2x 2.1.0.2, 1x nicht installiert`.
  Gruen = alle aktuell, orange = Abweichungen.

## v3.2.3 (2026-10-02)

### Behoben
- **Clients-Status zeigte bei gemeinsamem Status-Share alle Schulen** (z.B. zwei
  Schulen auf demselben Schulserver): Nutzen mehrere Tasks denselben Status-Share, zeigt
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
