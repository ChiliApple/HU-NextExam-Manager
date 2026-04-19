# NOTICE - Third-Party / Trademarks

## Next-Exam

"Next-Exam" ist Software und eingetragenes Kennzeichen des **Bildungsministeriums
Österreich / Bildungsportal** bzw. des jeweiligen Rechtsinhabers. Dieses Tool
("HU-NextExam-Manager") steht in keinerlei offizieller Verbindung mit dem
Bildungsportal oder den Next-Exam-Entwicklern und ist ein **inoffizielles
Drittanbieter-Hilfsmittel**.

### Was dieses Tool tut

- Lädt **ausschliesslich offiziell veröffentlichte MSI-Installer** direkt
  vom offiziellen Next-Exam GitHub-Release herunter
  (https://github.com/Bildungsportal/next-exam/releases)
- Kopiert die unveränderten MSIs in vom Administrator konfigurierte
  UNC-Shares der eigenen Organisation
- Erstellt Gruppenrichtlinien zur Verteilung dieser offiziellen Installer
  per `msiexec /i` (Standard Windows-Installer-Mechanismus)

### Was dieses Tool NICHT tut

- Verteilt keine Next-Exam-Binaries als Teil dieses Repositories
- Modifiziert keine MSI-Dateien
- Umgeht keine Lizenzbestimmungen oder Update-Mechanismen der Next-Exam Software
- Nimmt keine Änderungen an installierten Next-Exam-Kopien vor (ausserhalb
  des offiziellen msiexec-Upgrade-Pfads)
- Bietet keinen Support für die Next-Exam-Software selbst

### Nutzungsrechte für Next-Exam

Der Einsatz der Next-Exam-Software durch die Administrator-Organisation muss
im Einklang mit den **Lizenzbedingungen von Next-Exam / Bildungsportal**
erfolgen. Dieses Tool ändert daran nichts - es automatisiert lediglich die
Verteilung der offiziellen Installer innerhalb einer bereits lizenzierten
Umgebung (typischerweise österreichische Bildungseinrichtungen).

Next-Exam ist im Release-Repository unter der dort angegebenen Lizenz
veröffentlicht. Dieses Tool respektiert diese Lizenz vollständig und leitet
die Installer nicht weiter.

## GitHub API

Zugriff auf GitHub-Releases und GitHub-Content erfolgt über die offizielle
[GitHub REST API](https://docs.github.com/en/rest). Rate-Limits und Terms of
Service gelten.

## Microsoft Windows APIs

Nutzung von GroupPolicy, ActiveDirectory, NetSecurity und ScheduledTasks
PowerShell-Modulen unter den Microsoft Windows Server/Client EULAs der
jeweiligen OS-Installation.

## Kein Affiliation-Claim

Verweise auf Next-Exam, Microsoft, GitHub, Azure, Intune und weitere
Marken dienen ausschliesslich der Beschreibung der technischen
Interoperabilität und stellen keine Herstellererklärung, kein Sponsoring
und keine Zusammenarbeit dar.

## Kontakt / Haftung

Dieses Tool wird unter der **MIT License** bereitgestellt (siehe `LICENSE`
im Root). Der Autor übernimmt keine Haftung für:
- Fehler in Konfigurationen die durch das Tool in AD/GPO vorgenommen werden
- Ausfälle der Next-Exam-Services durch fehlerhafte Versionen
- Policy-Verletzungen der Administrator-Organisation beim Einsatz des Tools

Jeder Einsatz geschieht auf eigene Verantwortung des Administrators.
