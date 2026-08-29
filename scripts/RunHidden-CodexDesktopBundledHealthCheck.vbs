Option Explicit

Dim shell, fso, scriptDir, quickRepair, cmd, exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
quickRepair = fso.BuildPath(scriptDir, "Invoke-CodexDesktopQuickRepair.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & quickRepair & """ -Route Auto"
exitCode = shell.Run(cmd, 0, True)
WScript.Quit exitCode
