' HU-NextExam-Manager Launcher - fensterlos + elevated (UAC-Prompt)
' Elevation: fuer die Registrierung des AutoPull-Tasks als SYSTEM und fuer
' Schreibzugriff auf Tool-Ordner ausserhalb des Userprofils.
' GPO-Rechte kommen dagegen aus AD (Domaenen-Admins / Richtlinien-Ersteller-Besitzer).
' Ortsunabhaengig: Ordner darf auf dem Desktop, unter C:\Tools o.ae. liegen.
Set oFSO = CreateObject("Scripting.FileSystemObject")
sRoot = oFSO.GetParentFolderName(WScript.ScriptFullName)
sScript = sRoot & "\HU-NextExam-Manager.ps1"

If Not oFSO.FileExists(sScript) Then
    MsgBox "HU-NextExam-Manager.ps1 nicht gefunden:" & vbCrLf & vbCrLf & sScript, 16, "HU-NextExam-Manager"
    WScript.Quit 1
End If

Set oShell = CreateObject("Shell.Application")
' verb "runas" triggert UAC-Prompt, WindowStyle 0 = versteckt (kein Konsolenfenster)
oShell.ShellExecute "powershell.exe", _
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sScript & """", _
    sRoot, "runas", 0
