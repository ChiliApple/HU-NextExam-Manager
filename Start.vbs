' HU-NextExam-Manager Launcher - fensterlos, OHNE Elevation.
' WICHTIG: NICHT elevated starten. GPMC-COM (Get-GPO) laeuft im gefilterten
' Token zuverlaessiger; GPO-Rechte kommen aus AD (Domaenen-Admins /
' Richtlinien-Ersteller-Besitzer), nicht aus lokaler Elevation.
' Ortsunabhaengig: Ordner darf auf dem Desktop, unter C:\Tools o.ae. liegen.
Set oFSO = CreateObject("Scripting.FileSystemObject")
sRoot = oFSO.GetParentFolderName(WScript.ScriptFullName)
sScript = sRoot & "\HU-NextExam-Manager.ps1"

If Not oFSO.FileExists(sScript) Then
    MsgBox "HU-NextExam-Manager.ps1 nicht gefunden:" & vbCrLf & vbCrLf & sScript, 16, "HU-NextExam-Manager"
    WScript.Quit 1
End If

Set oShell = CreateObject("Shell.Application")
' verb "open" = normaler Start ohne UAC-Prompt, WindowStyle 0 = versteckt
oShell.ShellExecute "powershell.exe", _
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sScript & """", _
    sRoot, "open", 0
