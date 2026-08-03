' claude-focus-tab.vbs — silent launcher for claude-focus-tab.ps1.
'
' The `claudetab:` protocol handler points here rather than straight at
' powershell.exe: launching PowerShell directly flashes a console window for
' a few hundred milliseconds on every toast click, and -WindowStyle Hidden
' does not suppress it (the console is allocated before the switch is read).
' wscript.exe with an intWindowStyle of 0 never creates one.
'
' Forwards every argument through to the PowerShell script verbatim.

Option Explicit

Dim sh, fso, here, ps1, args, i, cmd

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "claude-focus-tab.ps1")

args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & WScript.Arguments(i) & Chr(34)
Next

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " _
      & Chr(34) & ps1 & Chr(34) & args

' 0 = hidden window, False = do not wait for it to exit.
sh.Run cmd, 0, False
