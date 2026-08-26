$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildScript = Join-Path $repositoryRoot 'bin\build-windows-release.ps1'

if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
  throw "Windows release script is missing: $buildScript"
}

& $buildScript -SelfTest
if ($LASTEXITCODE -ne 0) {
  throw "Windows release self-test failed with exit code $LASTEXITCODE"
}
