' HU-NextExam-Manager Launcher - fensterlos + elevated (UAC-Prompt)
' Tool benoetigt lokalen Admin fuer GPO-Operationen (GPMC-COM).
Set oFSO = CreateObject("Scripting.FileSystemObject")
sRoot = oFSO.GetParentFolderName(WScript.ScriptFullName)
sScript = sRoot & "\HU-NextExam-Manager.ps1"

Set oShell = CreateObject("Shell.Application")
' verb "runas" triggert UAC-Prompt, WindowStyle 0 = versteckt
oShell.ShellExecute "powershell.exe", _
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sScript & """", _
    "", "runas", 0
