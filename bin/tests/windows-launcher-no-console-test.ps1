[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherCliPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$launcherCli = (Resolve-Path -LiteralPath $LauncherCliPath).Path
$workingRoot = (Resolve-Path -LiteralPath $WorkingDirectory).Path

Push-Location $workingRoot
try {
    $statusOutput = & $launcherCli status --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher status failed with exit code ${LASTEXITCODE}:`n$($statusOutput | Out-String)"
    }
}
finally {
    Pop-Location
}

$status = ($statusOutput | Out-String) | ConvertFrom-Json
if (-not $status.app.healthy -or -not $status.app.pid) {
    throw "The application must be healthy before checking its console host: $($status | ConvertTo-Json -Depth 10)"
}

$appPid = [int]$status.app.pid
$appProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $appPid"
if (-not $appProcess) {
    throw "Application process $appPid disappeared before its console host could be checked."
}

$terminalProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'WindowsTerminal.exe'" |
    Where-Object { $_.CreationDate -ge $appProcess.CreationDate.AddSeconds(-1) } |
    ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
if ($terminalProcesses.Count -ne 0) {
    $terminals = ($terminalProcesses | ForEach-Object { "pid=$($_.Id) title=$($_.MainWindowTitle)" }) -join ', '
    throw "The application release command pid $appPid ($($appProcess.Name)) created a visible Windows Terminal window ($terminals). Double-click startup must not create a console window."
}

Write-Host "Windows launcher background-console test passed (application pid $appPid created no visible terminal window)."
