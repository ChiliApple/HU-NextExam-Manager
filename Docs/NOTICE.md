# NOTICE - Third-Party / Trademarks

## Next-Exam

"Next-Exam" ist Software und eingetragenes Kennzeichen des **Bildungsministeriums
Oesterreich / Bildungsportal** bzw. des jeweiligen Rechtsinhabers. Dieses Tool
("HU-NextExam-Manager") steht in keinerlei offizieller Verbindung mit dem
Bildungsportal oder den Next-Exam-Entwicklern und ist ein **inoffizielles
Drittanbieter-Hilfsmittel**.

### Was dieses Tool tut

- Laedt **ausschliesslich offiziell veroeffentlichte MSI-Installer** direkt
  vom offiziellen Next-Exam GitHub-Release herunter
  (https://github.com/Bildungsportal/next-exam/releases)
- Kopiert die unveraenderten MSIs in vom Administrator konfigurierte
  UNC-Shares der eigenen Organisation
- Erstellt Gruppenrichtlinien zur Verteilung dieser offiziellen Installer
  per `msiexec /i` (Standard Windows-Installer-Mechanismus)

### Was dieses Tool NICHT tut

- Verteilt keine Next-Exam-Binaries als Teil dieses Repositories
- Modifiziert keine MSI-Dateien
- Umgeht keine Lizenzbestimmungen oder Update-Mechanismen der Next-Exam Software
- Nimmt keine Aenderungen an installierten Next-Exam-Kopien vor (ausserhalb
  des offiziellen msiexec-Upgrade-Pfads)
- Bietet keinen Support fuer die Next-Exam-Software selbst

### Nutzungsrechte fuer Next-Exam

Der Einsatz der Next-Exam-Software durch die Administrator-Organisation muss
im Einklang mit den **Lizenzbedingungen von Next-Exam / Bildungsportal**
erfolgen. Dieses Tool aendert daran nichts - es automatisiert lediglich die
Verteilung der offiziellen Installer innerhalb einer bereits lizenzierten
Umgebung (typischerweise oesterreichische Bildungseinrichtungen).

Next-Exam ist im Release-Repository unter der dort angegebenen Lizenz
veroeffentlicht. Dieses Tool respektiert diese Lizenz vollstaendig und leitet
die Installer nicht weiter.

## GitHub API

Zugriff auf GitHub-Releases und GitHub-Content erfolgt ueber die offizielle
[GitHub REST API](https://docs.github.com/en/rest). Rate-Limits und Terms of
Service gelten.

## Microsoft Windows APIs

Nutzung von GroupPolicy, ActiveDirectory, NetSecurity und ScheduledTasks
PowerShell-Modulen unter den Microsoft Windows Server/Client EULAs der
jeweiligen OS-Installation.

## Kein Affiliation-Claim

Verweise auf Next-Exam, Microsoft, GitHub, Azure, Intune und weitere
Marken dienen ausschliesslich der Beschreibung der technischen
Interoperabilitaet und stellen keine Herstellererklaerung, kein Sponsoring
und keine Zusammenarbeit dar.

## Kontakt / Haftung

Dieses Tool wird unter der **MIT License** bereitgestellt (siehe `LICENSE`
im Root). Der Autor uebernimmt keine Haftung fuer:
- Fehler in Konfigurationen die durch das Tool in AD/GPO vorgenommen werden
- Ausfaelle der Next-Exam-Services durch fehlerhafte Versionen
- Policy-Verletzungen der Administrator-Organisation beim Einsatz des Tools

Jeder Einsatz geschieht auf eigene Verantwortung des Administrators.
