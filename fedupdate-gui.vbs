' ==============================================================================
' FedUpDate - Silent GUI Launcher
' Launches the single-window GUI with zero terminal windows
' ==============================================================================

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
guiExe = scriptDir & "\gui\bin\FedUpDate.UI.exe"
serverScript = scriptDir & "\gui\Server.ps1"

' The application is the compiled window, which draws its own title bar and
' starts the server it needs by itself. This launcher started that server
' directly instead, and a server with no window of its own is reached through a
' browser, which frames the page in the operating system's own chrome and leaves
' two title bars stacked. Starting the server remains the fallback for a machine
' where the window could not be built, but it is the fallback, not the thing.
If fso.FileExists(guiExe) Then
    WshShell.Run """" & guiExe & """", 1, False
Else
    cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & serverScript & """"
    WshShell.Run cmd, 0, False
End If
