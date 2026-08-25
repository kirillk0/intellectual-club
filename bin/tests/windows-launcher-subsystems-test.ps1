[CmdletBinding()]
param(
    [string]$GuiLauncherPath,
    [string]$CliLauncherPath
)

$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$releaseDirectory = Join-Path $repositoryRoot "native_tools\target\x86_64-pc-windows-msvc\release"

if (-not $GuiLauncherPath) {
    $GuiLauncherPath = Join-Path $releaseDirectory "intellectual-club-launcher.exe"
}
if (-not $CliLauncherPath) {
    $CliLauncherPath = Join-Path $releaseDirectory "intellectual-club-launcher-cli.exe"
}

function Get-PeSubsystem {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path).Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Not a valid PE file: $Path"
    }

    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $optionalHeaderOffset = $peOffset + 24
    $subsystemOffset = $optionalHeaderOffset + 68
    if ($peOffset -lt 0 -or $subsystemOffset + 2 -gt $bytes.Length) {
        throw "Invalid PE header offsets: $Path"
    }
    if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
        throw "PE signature is missing: $Path"
    }

    return [BitConverter]::ToUInt16($bytes, $subsystemOffset)
}

$guiSubsystem = Get-PeSubsystem -Path $GuiLauncherPath
$cliSubsystem = Get-PeSubsystem -Path $CliLauncherPath

if ($guiSubsystem -ne 2) {
    throw "GUI launcher PE subsystem must be Windows GUI (2), got $guiSubsystem"
}
if ($cliSubsystem -ne 3) {
    throw "CLI launcher PE subsystem must be Windows CUI (3), got $cliSubsystem"
}

Write-Host "Windows launcher subsystem test passed (GUI=2, CLI=3)."
