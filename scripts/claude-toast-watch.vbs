' claude-toast-watch.vbs — silent launcher for claude-toast-watch.ps1.
'
' Same reason as claude-focus-tab.vbs: this process lives for up to 15 minutes
' polling in the background, so a visible console window is not an option, and
' powershell.exe -WindowStyle Hidden still flashes one on creation.
'
' Args are forwarded verbatim: <claudetab-uri> <tag>

Option Explicit

Dim sh, fso, here, ps1, args, i, cmd

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "claude-toast-watch.ps1")

args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & WScript.Arguments(i) & Chr(34)
Next

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " _
      & Chr(34) & ps1 & Chr(34) & args

sh.Run cmd, 0, False
