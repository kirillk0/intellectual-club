$ErrorActionPreference = 'Stop'

function ConvertFrom-SecureValue {
  param([Parameter(Mandatory = $true)][Security.SecureString]$Value)

  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

$username = Read-Host 'Username'
$password = ConvertFrom-SecureValue (Read-Host 'Password' -AsSecureString)
$passwordConfirmation = ConvertFrom-SecureValue (Read-Host 'Confirm password' -AsSecureString)

try {
  $payload = @($username, $password, $passwordConfirmation) -join [Environment]::NewLine
  $payload | & (Join-Path $PSScriptRoot 'intellectual_club.bat') eval 'IntellectualClub.ReleaseTasks.CreateAdmin.main(System.argv())' --line-stdin
  exit $LASTEXITCODE
}
finally {
  $password = $null
  $passwordConfirmation = $null
  $payload = $null
}
