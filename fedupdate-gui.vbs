' ==============================================================================
' FedUpDate - Silent GUI Launcher
' Launches the single-window GUI with zero terminal windows
' ==============================================================================

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
serverScript = scriptDir & "\gui\Server.ps1"

cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & serverScript & """"
WshShell.Run cmd, 0, False
