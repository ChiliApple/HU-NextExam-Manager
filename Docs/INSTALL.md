# HU-NextExam-Manager - Installation

## Voraussetzungen am Admin-Rechner/DC

- Windows Server 2016+ oder Client mit RSAT
- PowerShell 5.1
- Module: `GroupPolicy`, `ActiveDirectory`, `NetSecurity`
- Domain Admin oder delegierte GPO-Create/-Link-Rechte fuer die Ziel-OUs

## Erst-Deployment (Bootstrap)

Als Admin in PowerShell (KEINE ISE):

```powershell
$d = Join-Path $env:USERPROFILE 'Desktop\HU-NextExam-Manager'
New-Item -ItemType Directory -Path $d -Force | Out-Null
Invoke-WebRequest "https://raw.githubusercontent.com/ChiliApple/HU-NextExam-Manager/main/Pull.ps1" `
    -UseBasicParsing -OutFile (Join-Path $d 'Pull.ps1')
cd $d; .\Pull.ps1
```

Startet das Tool:

**Empfohlen: via Start.vbs** (triggert automatisch UAC-Prompt, dann fensterlos):

```
%USERPROFILE%\Desktop\HU-NextExam-Manager\Start.vbs
```

Tool benoetigt **lokale Admin-Rechte** fuer GPO-Operationen (GPMC-COM
braucht elevated Integritaetslevel).

**Manuell elevated:**

```powershell
cd $env:USERPROFILE\Desktop\HU-NextExam-Manager
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HU-NextExam-Manager.ps1
```

## Taegliches Update

```powershell
cd $env:USERPROFILE\Desktop\HU-NextExam-Manager
.\Pull.ps1
```

Tool vorher schliessen (sonst icon.ico-File-Lock Warning).

## Config-Portabilitaet

Die `config.json` liegt neben dem Tool (nicht in `%APPDATA%`).
Kompletter Ordner kopierbar auf anderen Server - Config geht mit.

## Erst-Setup

1. Tool starten, Tab "Settings"
2. "+ Neu" - Task anlegen (z.B. "Schulname")
3. Felder fuellen:
   - Domain FQDN, DC Server
   - Student-Share / Teacher-Share (UNC)
   - OU-Ziel Student / Teacher (**DistinguishedName**, z.B. `OU=Workstations,DC=school,DC=local`)
   - WMI-Filter-Muster (optional)
   - GPO-Name-Praefix (Default: `HU-NEXT-EXAM-`)
   - Firewall-Einstellungen (Expander)
4. "Task speichern"
5. Tab "MSI Pull" - "Release abfragen" - Task markieren - "Auswahl aktualisieren"
6. Tab "GPO Setup" - Task markieren - "Install-GPOs" - "FW-GPOs" - "Mit OU verknuepfen"
7. Client: `gpupdate /force` + Reboot

## WMI-Filter (optional, fuer Mixed-OU-Setups)

Wenn Student- und Teacher-PCs in **derselben OU** liegen, brauchst du WMI-Filter damit die
Student-GPO nicht auch den Teacher-PC trifft (und umgekehrt).

### Beispiel — Teacher-PC endet auf `-01`

Naming-Convention: jeder Teacher-PC im Raum hat im Hostname-Suffix `-01` (z.B. `PC-EDV1-01`,
`PC-EDV2-01`), alle anderen PCs sind Schueler-Clients.

**Settings-Tab pro Task:**

| Feld                         | Typ      | Muster |
|------------------------------|----------|--------|
| WMI-Filter Student (Typ + Muster) | `Custom` | `SELECT * FROM Win32_ComputerSystem WHERE NOT Name LIKE '%-01'` |
| WMI-Filter Teacher (Typ + Muster) | `Custom` | `SELECT * FROM Win32_ComputerSystem WHERE Name LIKE '%-01'` |

### Wichtig

- **Einfache Anfuehrungszeichen** `'` verwenden, nicht doppelte `"`
- **Keine Klammern** um den `LIKE`-Ausdruck
- Typ `Custom` noetig wenn `NOT`/`AND`/`OR` im Query vorkommen
- Typ `Pattern` reicht fuer reine `LIKE`-Faelle (z.B. Teacher: Typ=`Pattern`, Muster=`%-01`)

### Anwendung durch Tool

Beim Klick auf **Install-GPOs** im GPO Setup Tab:
1. Falls Pattern nicht leer, erstellt das Tool automatisch einen WMI-Filter in AD namens
   `<GPOPrefix>WMI Student` bzw. `<GPOPrefix>WMI Teacher`
2. Weist den Filter automatisch an die jeweiligen Install-GPO UND FW-GPO (falls erstellt)

### Cleanup bei Aenderung

Wenn du den WMI-Pattern aenderst, muss der alte Filter erst geloescht werden (das Tool
updated vorhandene Filter nicht, sondern ueberspringt existierende mit gleichem Namen):

- **GPO Setup Tab → "WMI-Filter cleanup"** entfernt alle Filter mit Task-Prefix
- Danach **Install-GPOs** erneut → frische Filter mit neuem Pattern

### Pruefen in GPMC

- `Forest → Domains → <deine Domain> → WMI-Filter` → beide Filter sollten sichtbar sein
- `... → Group Policy Objects → <Install-GPO>` → Tab "Geltungsbereich" → Feld "WMI-Filterung" → sollte den zugewiesenen Filter zeigen
