# install.ps1 — install claude-wt-notify.
#
# Copies the helper scripts into %LOCALAPPDATA%\ClaudeCode\ and registers two
# things under HKCU:
#
#   claudetab:            URI scheme, so clicking a toast focuses the tab
#   AppUserModelId\...    toast identity, so toasts read "Claude Code"
#
# The scripts are copied rather than run in place. If you keep this repo
# inside WSL, a \\wsl.localhost\ UNC path only resolves while the distro is
# running, and the shell can invoke a protocol handler when it is not.
#
# HKCU scope only: no elevation, no UAC prompt, nothing written system-wide.
#
# Run from Windows:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
# Run from WSL:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass \
#     -File "$(wslpath -w ./install.ps1)"
#
# Uninstall:  .\install.ps1 -Uninstall

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$Scheme    = 'claudetab'
$Aumid     = 'Claude.Code'
$TargetDir = Join-Path $env:LOCALAPPDATA 'ClaudeCode'
$RegRoot   = "HKCU:\Software\Classes\$Scheme"
$AumidKey  = "HKCU:\Software\Classes\AppUserModelId\$Aumid"

if ($Uninstall) {
    if (Test-Path $RegRoot) {
        Remove-Item -Path $RegRoot -Recurse -Force
        Write-Host "Unregistered ${Scheme}: protocol." -ForegroundColor Yellow
    } else {
        Write-Host "${Scheme}: protocol was not registered." -ForegroundColor DarkGray
    }
    if (Test-Path $AumidKey) {
        Remove-Item -Path $AumidKey -Recurse -Force
        Write-Host "Unregistered AppUserModelID '$Aumid' (toasts revert to the PowerShell identity)." -ForegroundColor Yellow
    }
    foreach ($f in 'claude-focus-tab.ps1', 'claude-focus-tab.vbs',
                   'claude-toast-watch.ps1', 'claude-toast-watch.vbs',
                   'claude-unread-tray.ps1', 'claude-unread-tray.vbs') {
        $p = Join-Path $TargetDir $f
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed $p" -ForegroundColor Yellow }
    }
    return
}

# --- copy the handler into place --------------------------------------------

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

foreach ($f in 'claude-focus-tab.ps1', 'claude-focus-tab.vbs',
               'claude-toast-watch.ps1', 'claude-toast-watch.vbs',
                   'claude-unread-tray.ps1', 'claude-unread-tray.vbs') {
    $src = Join-Path (Join-Path $PSScriptRoot 'scripts') $f
    if (-not (Test-Path $src)) { throw "Missing source file: $src" }
    Copy-Item -Path $src -Destination (Join-Path $TargetDir $f) -Force
    Write-Host "Installed $f -> $TargetDir" -ForegroundColor Green
}

# --- register the protocol ---------------------------------------------------

$vbs     = Join-Path $TargetDir 'claude-focus-tab.vbs'
$command = '"{0}\System32\wscript.exe" "{1}" "%1"' -f $env:WINDIR, $vbs

New-Item -Path $RegRoot -Force | Out-Null
New-ItemProperty -Path $RegRoot -Name '(Default)' -Value 'URL:Claude Code Tab' -PropertyType String -Force | Out-Null
# The presence of a (possibly empty) "URL Protocol" value is what marks a key
# as a URI scheme handler. Without it the shell ignores the registration.
New-ItemProperty -Path $RegRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

$cmdKey = Join-Path $RegRoot 'shell\open\command'
New-Item -Path $cmdKey -Force | Out-Null
New-ItemProperty -Path $cmdKey -Name '(Default)' -Value $command -PropertyType String -Force | Out-Null

Write-Host "Registered ${Scheme}: -> $command" -ForegroundColor Green

# --- register the toast identity ---------------------------------------------

# Without this, toasts are attributed to "Windows PowerShell" because that is
# the AUMID the raising process inherits. A registry key is sufficient; the
# Start Menu shortcut Microsoft's docs describe is not required (verified
# against wpndatabase.db). cc-notify.sh also creates this key on demand, so
# this is really just to keep install/uninstall symmetric.
$icon = Join-Path $TargetDir 'claude-icon.png'
New-Item -Path $AumidKey -Force | Out-Null
New-ItemProperty -Path $AumidKey -Name 'DisplayName' -Value 'Claude Code' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $AumidKey -Name 'ShowInSettings' -Value 1 -PropertyType DWord -Force | Out-Null
if (Test-Path $icon) {
    New-ItemProperty -Path $AumidKey -Name 'IconUri' -Value $icon -PropertyType String -Force | Out-Null
}
Write-Host "Registered AppUserModelID '$Aumid' (toasts show as 'Claude Code')." -ForegroundColor Green

Write-Host ""
Write-Host "Test with:  start claudetab:<base64url-token>" -ForegroundColor Cyan
Write-Host "Log at:     $TargetDir\focus-tab.log" -ForegroundColor Cyan
