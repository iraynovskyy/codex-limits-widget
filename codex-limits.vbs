Option Explicit
Dim shell, files, script, powershell
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
script = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "codex-limits.ps1")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
shell.Run """" & powershell & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """", 1, False
