' claude-unread-tray.vbs — silent launcher for claude-unread-tray.ps1.
'
' The tray process is long-lived and owns a WinForms message loop, so a
' console window would sit on the taskbar for its whole lifetime. Launching
' through wscript with a window style of 0 avoids that entirely.
'
' Safe to run repeatedly: the PowerShell script holds a named mutex and any
' duplicate instance exits immediately.

Option Explicit

Dim sh, fso, here, ps1, cmd

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "claude-unread-tray.ps1")

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " _
      & Chr(34) & ps1 & Chr(34)

sh.Run cmd, 0, False
