[CmdletBinding()]
param(
  [string]$ReleaseId,
  [string]$OutputDirectory,
  [string]$BuildDirectory,
  [switch]$SkipTests,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PostgresVersion = '16.13.0'
$script:PostgresArchiveName = 'postgresql-16.13.0-x86_64-pc-windows-msvc.tar.gz'
$script:PostgresUrl = "https://github.com/theseus-rs/postgresql-binaries/releases/download/$($script:PostgresVersion)/$($script:PostgresArchiveName)"
$script:PostgresSha256 = '27e05be6671bb3af592ff83ac1e717bad456a6ef45d56de0ba64f719908e1f56'
$script:VipsVersion = '8.18.2'
$script:VipsArchiveName = 'vips-dev-x64-web-8.18.2.zip'
$script:VipsUrl = "https://github.com/libvips/build-win64-mxe/releases/download/v$($script:VipsVersion)/$($script:VipsArchiveName)"
$script:VipsSha256 = '08effbafe12c6700345882b011cefeb41bcb305b959f5c0812a56cd1b0ddb752'
$script:PdfNifName = 'pdf_elixide_nif-v0.4.0-nif-2.15-x86_64-pc-windows-msvc.dll.tar.gz'
$script:PdfNifUrl = "https://github.com/r8/pdf_elixide/releases/download/v0.4.0/$($script:PdfNifName)"
$script:PdfNifSha256 = '754fe266fc780fd9004ccc191bd42afb0a6a7fdf1053b3d8cf26027864b838e2'
$script:TailwindVersion = '4.1.12'
$script:TailwindExecutableName = "tailwindcss-windows-x64-$($script:TailwindVersion).exe"
$script:TailwindUrl = "https://github.com/tailwindlabs/tailwindcss/releases/download/v$($script:TailwindVersion)/tailwindcss-windows-x64.exe"
$script:TailwindSha256 = '27e14fd9c0872281464da9c0991709e0f7cadedc60e4acfac371299246d54669'
$script:EsbuildVersion = '0.25.4'
$script:EsbuildArchiveName = "esbuild-win32-x64-$($script:EsbuildVersion).tgz"
$script:EsbuildUrl = "https://registry.npmjs.org/@esbuild/win32-x64/-/win32-x64-$($script:EsbuildVersion).tgz"
$script:EsbuildSha256 = '035b7afcf6e1815a51f78a595ecca3571413a4b364777ca936c1c93ccdfbb5f4'

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  [System.IO.Path]::GetFullPath($Path)
}

function Remove-ManagedDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$AllowedParent
  )

  $fullPath = Get-FullPath $Path
  $fullParent = (Get-FullPath $AllowedParent).TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a directory outside $fullParent`: $fullPath"
  }
  if ($fullPath.TrimEnd('\') -eq $fullParent.TrimEnd('\')) {
    throw "Refusing to remove the managed parent itself: $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force
  }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = $script:RepositoryRoot
  )

  Push-Location $WorkingDirectory
  try {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "$FilePath exited with code $LASTEXITCODE"
    }
  }
  finally {
    Pop-Location
  }
}

function Invoke-CaptureNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = $script:RepositoryRoot
  )

  Push-Location $WorkingDirectory
  try {
    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "$FilePath exited with code $LASTEXITCODE`n$($output | Out-String)"
    }
    ($output | Out-String).Trim()
  }
  finally {
    Pop-Location
  }
}

function Invoke-VitestShard {
  param(
    [Parameter(Mandatory = $true)][int]$Shard,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )

  $arguments = @(
    'test', '--',
    '--pool=threads',
    '--maxWorkers=1',
    '--no-file-parallelism',
    "--shard=$Shard/4"
  )

  foreach ($attempt in 1..3) {
    $lines = [System.Collections.Generic.List[string]]::new()
    Push-Location $WorkingDirectory
    try {
      & npm.cmd @arguments 2>&1 | ForEach-Object {
        $line = $_ | Out-String
        Write-Host ($line.TrimEnd())
        $lines.Add($line)
      }
      $exitCode = $LASTEXITCODE
    }
    finally {
      Pop-Location
    }

    if ($exitCode -eq 0) { return }
    $diagnostic = $lines | Out-String
    $workerStartupTimeout =
      $diagnostic -match '\[vitest-pool-runner\]: Timeout waiting for worker to respond' -or
      $diagnostic -match '\[vitest-pool\]: Failed to start .* worker'
    if (-not $workerStartupTimeout -or $attempt -eq 3) {
      throw "Vitest shard $Shard/4 exited with code $exitCode"
    }

    Write-Warning "Vitest shard $Shard/4 hit a Windows worker startup timeout; retrying ($attempt/3)."
  }
}

function Add-LocalToolchainsToPath {
  $root = Join-Path $env:LOCALAPPDATA 'IntellectualClubDev\toolchains'
  $candidates = @(
    (Join-Path $root 'node-v24.16.0-win-x64'),
    (Join-Path $root 'elixir-1.20.2-otp-29\bin'),
    (Join-Path $root 'erl-29.0\bin'),
    (Join-Path $env:USERPROFILE '.cargo\bin')
  )
  $paths = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container })

  if (Test-Path -LiteralPath (Join-Path $root 'erl-29.0')) {
    $env:ERLANG_HOME = Join-Path $root 'erl-29.0'
  }
  if ($paths.Count -gt 0) {
    $env:Path = ($paths -join ';') + ';' + $env:Path
  }
}

function Initialize-VisualStudioEnvironment {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $installation = $null
  if (Test-Path -LiteralPath $vswhere) {
    $installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
  }
  if (-not $installation) {
    $fallback = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools'
    if (Test-Path -LiteralPath $fallback) {
      $installation = $fallback
    }
  }
  if (-not $installation) {
    throw 'Visual Studio 2022 Build Tools with the C++ workload were not found.'
  }

  $devShell = Join-Path $installation 'Common7\Tools\Launch-VsDevShell.ps1'
  & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
  foreach ($command in @('cl.exe', 'dumpbin.exe', 'mt.exe', 'rc.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
      throw "Required Visual Studio command is missing: $command"
    }
  }
}

function Assert-ToolVersions {
  $nodeVersion = (& node --version).Trim()
  if ($nodeVersion -ne 'v24.16.0') { throw "Expected Node 24.16.0, found $nodeVersion" }

  $rustVersion = (& rustc --version).Trim()
  if ($rustVersion -notmatch '^rustc 1\.92\.0 ') { throw "Expected Rust 1.92.0, found $rustVersion" }

  $elixirVersion = (& elixir --version 2>&1 | Out-String)
  if ($elixirVersion -notmatch 'Elixir 1\.20\.2') { throw "Expected Elixir 1.20.2, found $elixirVersion" }

  $otpVersion = (& erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>&1 | Out-String).Trim()
  if ($otpVersion -ne '29') { throw "Expected Erlang/OTP 29, found $otpVersion" }
}

function Ensure-Download {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Sha256
  )

  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if (Test-Path -LiteralPath $Path) {
    $existing = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($existing -eq $Sha256) { return }
    Remove-Item -LiteralPath $Path -Force
  }

  $temporary = "$Path.download-$PID"
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  try {
    Invoke-Native 'curl.exe' @('-fL', '--retry', '5', '--connect-timeout', '20', '--max-time', '900', '-o', $temporary, $Url)
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporary).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
      throw "Checksum mismatch for $Url. Expected $Sha256, found $actual"
    }
    Move-Item -LiteralPath $temporary -Destination $Path
  }
  finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
}

function Copy-DirectoryContents {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Remove-UnbundledPostgresLanguageExtensions {
  param([Parameter(Mandatory = $true)][string]$PostgresRoot)

  # The upstream PostgreSQL archive includes optional PL/Perl, PL/Python, and
  # PL/Tcl extension modules, but deliberately does not bundle those language
  # runtimes. Keep the portable payload closed by removing modules that could
  # never be loaded from this distribution.
  $libraryNames = @(
    'bool_plperl.dll',
    'hstore_plperl.dll',
    'jsonb_plperl.dll',
    'plperl.dll',
    'hstore_plpython3.dll',
    'jsonb_plpython3.dll',
    'ltree_plpython3.dll',
    'plpython3.dll',
    'pltcl.dll'
  )
  $libraryRoot = Join-Path $PostgresRoot 'lib'
  foreach ($name in $libraryNames) {
    $path = Join-Path $libraryRoot $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }

  $extensionRoot = Join-Path $PostgresRoot 'share\extension'
  if (Test-Path -LiteralPath $extensionRoot -PathType Container) {
    $prefixes = @(
      'bool_plperl',
      'hstore_plperl',
      'jsonb_plperl',
      'plperl',
      'hstore_plpython3',
      'jsonb_plpython3',
      'ltree_plpython3',
      'plpython3',
      'pltcl'
    )
    foreach ($prefix in $prefixes) {
      Get-ChildItem -LiteralPath $extensionRoot -File -Filter "$prefix*" |
        Remove-Item -Force
    }
  }
}

function Find-PayloadRoot {
  param(
    [Parameter(Mandatory = $true)][string]$SearchRoot,
    [Parameter(Mandatory = $true)][string]$ExecutableName
  )
  $binary = Get-ChildItem -LiteralPath $SearchRoot -Recurse -File -Filter $ExecutableName |
    Where-Object { $_.Directory.Name -eq 'bin' } |
    Select-Object -First 1
  if (-not $binary) { throw "Could not find bin\$ExecutableName below $SearchRoot" }
  $binary.Directory.Parent.FullName
}

function Ensure-Dependencies {
  param([Parameter(Mandatory = $true)][string]$BuildRoot)

  $downloadRoot = Join-Path $BuildRoot 'downloads'
  $dependencyRoot = Join-Path $BuildRoot 'dependencies'
  New-Item -ItemType Directory -Force -Path $downloadRoot, $dependencyRoot | Out-Null

  $postgresArchive = Join-Path $downloadRoot $script:PostgresArchiveName
  Ensure-Download $script:PostgresUrl $postgresArchive $script:PostgresSha256
  $postgresExtract = Join-Path $dependencyRoot "postgresql-$($script:PostgresVersion)"
  if (-not (Get-ChildItem -LiteralPath $postgresExtract -Recurse -File -Filter 'postgres.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Remove-ManagedDirectory $postgresExtract $dependencyRoot
    New-Item -ItemType Directory -Path $postgresExtract | Out-Null
    Invoke-Native 'tar.exe' @('-xf', $postgresArchive, '-C', $postgresExtract)
  }
  $postgresRoot = Find-PayloadRoot $postgresExtract 'postgres.exe'

  $vipsArchive = Join-Path $downloadRoot $script:VipsArchiveName
  Ensure-Download $script:VipsUrl $vipsArchive $script:VipsSha256
  $vipsExtract = Join-Path $dependencyRoot "libvips-$($script:VipsVersion)"
  if (-not (Get-ChildItem -LiteralPath $vipsExtract -Recurse -File -Filter 'vips.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Remove-ManagedDirectory $vipsExtract $dependencyRoot
    New-Item -ItemType Directory -Path $vipsExtract | Out-Null
    Expand-Archive -LiteralPath $vipsArchive -DestinationPath $vipsExtract
  }
  $vipsRoot = Find-PayloadRoot $vipsExtract 'vips.exe'

  $rustlerCache = Join-Path $dependencyRoot 'rustler-precompiled-cache'
  New-Item -ItemType Directory -Force -Path $rustlerCache | Out-Null
  Ensure-Download $script:PdfNifUrl (Join-Path $rustlerCache $script:PdfNifName) $script:PdfNifSha256

  $tailwindBin = Join-Path $dependencyRoot $script:TailwindExecutableName
  Ensure-Download $script:TailwindUrl $tailwindBin $script:TailwindSha256

  $esbuildArchive = Join-Path $dependencyRoot $script:EsbuildArchiveName
  Ensure-Download $script:EsbuildUrl $esbuildArchive $script:EsbuildSha256
  $esbuildExtract = Join-Path $dependencyRoot "esbuild-$($script:EsbuildVersion)"
  $esbuildBin = Join-Path $esbuildExtract 'package\esbuild.exe'
  if (-not (Test-Path -LiteralPath $esbuildBin -PathType Leaf)) {
    Remove-ManagedDirectory $esbuildExtract $dependencyRoot
    New-Item -ItemType Directory -Path $esbuildExtract | Out-Null
    Invoke-Native 'tar.exe' @('-xf', $esbuildArchive, '-C', $esbuildExtract)
  }

  [pscustomobject]@{
    PostgresRoot = $postgresRoot
    VipsRoot = $vipsRoot
    RustlerCache = $rustlerCache
    TailwindBin = $tailwindBin
    EsbuildBin = $esbuildBin
  }
}

function Get-FreeTcpPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Invoke-WithTestPostgres {
  param(
    [Parameter(Mandatory = $true)][string]$PostgresRoot,
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
  )

  $testParent = Join-Path $BuildRoot 'test-postgres'
  New-Item -ItemType Directory -Force -Path $testParent | Out-Null
  $cluster = Join-Path $testParent "cluster-$PID-$([Guid]::NewGuid().ToString('N'))"
  $data = Join-Path $cluster 'data'
  $log = Join-Path $cluster 'postgres.log'
  $port = Get-FreeTcpPort
  New-Item -ItemType Directory -Path $cluster | Out-Null
  $pgCtl = Join-Path $PostgresRoot 'bin\pg_ctl.exe'
  $started = $false
  try {
    Invoke-Native (Join-Path $PostgresRoot 'bin\initdb.exe') @(
      '-D', $data,
      '-U', 'postgres',
      '--auth=trust',
      '--encoding=UTF8',
      '--locale-provider=icu',
      '--icu-locale=en-US'
    )
    Invoke-Native $pgCtl @('-D', $data, '-l', $log, '-o', "-p $port -h 127.0.0.1", '-w', 'start')
    $started = $true
    Invoke-Native (Join-Path $PostgresRoot 'bin\createdb.exe') @('-h', '127.0.0.1', '-p', $port.ToString(), '-U', 'postgres', 'intellectual_club_test')
    $previousUrl = $env:IC_TEST_DATABASE_URL
    try {
      $env:IC_TEST_DATABASE_URL = "postgresql://postgres@127.0.0.1:$port/intellectual_club_test"
      & $ScriptBlock
    }
    finally {
      $env:IC_TEST_DATABASE_URL = $previousUrl
    }
  }
  finally {
    if ($started) { & $pgCtl -D $data -m fast -w stop | Out-Host }
    Remove-ManagedDirectory $cluster $testParent
  }
}

function Find-VcRuntimeDirectory {
  param([Parameter(Mandatory = $true)][string]$RedistRoot)

  if (-not (Test-Path -LiteralPath $RedistRoot -PathType Container)) { return $null }
  if ((Split-Path -Leaf $RedistRoot) -match '^Microsoft\.VC\d+\.CRT$') { return $RedistRoot }

  $toolsetRoots = @($RedistRoot)
  $toolsetRoots += @(Get-ChildItem -LiteralPath $RedistRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      Select-Object -ExpandProperty FullName)
  foreach ($toolsetRoot in $toolsetRoots) {
    $x64Root = Join-Path $toolsetRoot 'x64'
    $candidate = Get-ChildItem -LiteralPath $x64Root -Directory -ErrorAction SilentlyContinue |
      Where-Object Name -Match '^Microsoft\.VC\d+\.CRT$' |
      Sort-Object Name -Descending |
      Select-Object -First 1 -ExpandProperty FullName
    if ($candidate) { return $candidate }
  }
  $null
}

function Get-VcRuntimeDirectory {
  $redistRoots = @()
  if ($env:VCToolsRedistDir) { $redistRoots += $env:VCToolsRedistDir }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
      Select-Object -First 1
    if ($installation) { $redistRoots += Join-Path $installation 'VC\Redist\MSVC' }
  }
  $redistRoots += Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC'

  foreach ($redistRoot in ($redistRoots | Select-Object -Unique)) {
    $candidate = Find-VcRuntimeDirectory $redistRoot
    if ($candidate) { return $candidate }
  }
  throw 'The Visual C++ x64 redistributable directory was not found.'
}

function Copy-VcRuntime {
  param([Parameter(Mandatory = $true)][string]$Destination)
  $source = Get-VcRuntimeDirectory
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $source -File -Filter '*.dll' | Copy-Item -Destination $Destination -Force
}

function Test-PeFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $stream = [IO.File]::OpenRead($Path)
    try {
      if ($stream.Length -lt 64) { return $false }
      $reader = [IO.BinaryReader]::new($stream)
      try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset + 6 -gt $stream.Length) { return $false }
        $stream.Position = $offset
        return $reader.ReadUInt32() -eq 0x00004550
      }
      finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
  }
  catch { return $false }
}

function Get-PeMachine {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $offset = [BitConverter]::ToInt32($bytes, 0x3C)
  [BitConverter]::ToUInt16($bytes, $offset + 4)
}

function Get-PeSubsystem {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $offset = [BitConverter]::ToInt32($bytes, 0x3C)
  [BitConverter]::ToUInt16($bytes, $offset + 24 + 68)
}

function Get-PeImports {
  param([Parameter(Mandatory = $true)][string]$Path)
  $output = & dumpbin.exe /nologo /dependents $Path 2>$null
  if ($LASTEXITCODE -ne 0) { return @() }
  @($output | ForEach-Object {
      if ($_ -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { $Matches[1] }
    } | Where-Object { $_ } | Sort-Object -Unique)
}

function Initialize-PeResourceInspector {
  if ('ReleasePeResources' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ReleasePeResources {
    private const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
    private delegate bool EnumResNameProc(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumResNameProc callback, IntPtr parameter);

    public static bool HasResource(string fileName, int type) {
        IntPtr module = LoadLibraryEx(fileName, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
        if (module == IntPtr.Zero) return false;
        bool found = false;
        EnumResNameProc callback = (m, t, n, p) => { found = true; return false; };
        EnumResourceNames(module, new IntPtr(type), callback, IntPtr.Zero);
        FreeLibrary(module);
        GC.KeepAlive(callback);
        return found;
    }
}
'@
}

function Assert-WindowsPayload {
  param([Parameter(Mandatory = $true)][string]$StagingRoot)

  $launcher = Join-Path $StagingRoot 'intellectual-club-launcher.exe'
  $launcherCli = Join-Path $StagingRoot 'intellectual-club-launcher-cli.exe'
  $outlet = Join-Path $StagingRoot 'outlet-shell-desktop.exe'
  $oauth = Join-Path $StagingRoot 'openai-oauth.exe'
  $release = Join-Path $StagingRoot 'resources\intellectual_club'
  $postgres = Join-Path $StagingRoot 'resources\postgresql'

  foreach ($path in @(
      $launcher, $launcherCli, $outlet, $oauth,
      (Join-Path $release 'bin\intellectual_club.bat'),
      (Join-Path $release 'bin\create-admin.bat'),
      (Join-Path $release 'bin\create-admin.ps1'),
      (Join-Path $postgres 'bin\postgres.exe'),
      (Join-Path $postgres 'bin\initdb.exe'),
      (Join-Path $postgres 'bin\libpq.dll')
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release file is missing: $path" }
  }
  if (-not (Get-ChildItem -LiteralPath $release -Directory -Filter 'erts-*' | Select-Object -First 1)) {
    throw 'The BEAM release does not contain ERTS.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $release 'lib') -PathType Container)) {
    throw 'The BEAM release does not contain application libraries.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $release 'lib') -PathType Container) -or
      -not (Get-ChildItem -LiteralPath (Join-Path $release 'lib') -Directory -Filter 'intellectual_club-*' |
        ForEach-Object { Join-Path $_.FullName 'priv\libvips\bin\vips.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1)) {
    throw 'The BEAM release does not contain bundled libvips.'
  }

  $peFiles = Get-ChildItem -LiteralPath $StagingRoot -Recurse -File |
    Where-Object { $_.Extension -in @('.exe', '.dll') } |
    Where-Object { Test-PeFile $_.FullName }
  foreach ($pe in $peFiles) {
    $machine = Get-PeMachine $pe.FullName
    if ($machine -ne 0x8664) {
      throw "Expected x64 PE machine 0x8664 in $($pe.FullName), found 0x$($machine.ToString('x4'))"
    }
  }

  foreach ($rustExe in @($launcher, $launcherCli, $outlet, $oauth)) {
    $imports = Get-PeImports $rustExe
    if ($imports | Where-Object { $_ -match '^(?i:VCRUNTIME|MSVCP|UCRTBASE)' }) {
      throw "Rust executable is not using the static CRT: $rustExe"
    }
  }

  $launcherSubsystem = Get-PeSubsystem $launcher
  if ($launcherSubsystem -ne 2) {
    throw "GUI launcher PE subsystem must be Windows GUI (2), found $launcherSubsystem"
  }
  $launcherCliSubsystem = Get-PeSubsystem $launcherCli
  if ($launcherCliSubsystem -ne 3) {
    throw "CLI launcher PE subsystem must be Windows CUI (3), found $launcherCliSubsystem"
  }

  Initialize-PeResourceInspector
  if (-not [ReleasePeResources]::HasResource($launcher, 14)) { throw 'Launcher PE icon resource is missing.' }
  if (-not [ReleasePeResources]::HasResource($launcherCli, 14)) { throw 'CLI launcher PE icon resource is missing.' }
  if (-not [ReleasePeResources]::HasResource($outlet, 14)) { throw 'Outlet PE icon resource is missing.' }

  $allNames = @{}
  foreach ($pe in $peFiles) { $allNames[$pe.Name.ToLowerInvariant()] = $true }
  $system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
  foreach ($pe in $peFiles) {
    foreach ($dependency in (Get-PeImports $pe.FullName)) {
      $lower = $dependency.ToLowerInvariant()
      if ($lower.StartsWith('api-ms-win-') -or $lower.StartsWith('ext-ms-win-')) { continue }
      if ($allNames.ContainsKey($lower)) { continue }
      if (Test-Path -LiteralPath (Join-Path $system32 $dependency)) { continue }
      throw "Unresolved DLL import $dependency from $($pe.FullName)"
    }
  }
}

function Assert-ReleaseTree {
  param([Parameter(Mandatory = $true)][string]$StagingRoot)
  $expectedRoot = @(
    'First Launch.txt',
    'intellectual-club-launcher-cli.exe',
    'intellectual-club-launcher.exe',
    'openai-oauth.exe',
    'outlet-shell-desktop.exe',
    'resources'
  )
  $actualRoot = @(Get-ChildItem -LiteralPath $StagingRoot -Force | Select-Object -ExpandProperty Name | Sort-Object)
  if (($actualRoot -join "`n") -ne (($expectedRoot | Sort-Object) -join "`n")) {
    throw "Unexpected staging root. Expected $($expectedRoot -join ', '), found $($actualRoot -join ', ')"
  }
  $resourceNames = @(Get-ChildItem -LiteralPath (Join-Path $StagingRoot 'resources') -Directory | Select-Object -ExpandProperty Name | Sort-Object)
  if (($resourceNames -join ',') -ne 'intellectual_club,postgresql') {
    throw "Unexpected resources directories: $($resourceNames -join ', ')"
  }
}

function Write-FirstLaunchInstructions {
  param([Parameter(Mandatory = $true)][string]$Path)
  $text = @'
INTELLECTUAL CLUB - FIRST LAUNCH

1. Extract the entire ZIP archive before running anything. Do not start the launcher from inside the ZIP preview.
2. Double-click intellectual-club-launcher.exe. The launcher finds the application and PostgreSQL in the adjacent resources folder automatically.
3. Windows SmartScreen may warn about this unsigned build. Check SHA256SUMS.txt from the GitHub release before choosing to run it.

Use intellectual-club-launcher-cli.exe from PowerShell or Command Prompt for status, doctor, backup, and other command-line operations.

Keep both launcher executables and the resources folder together. You may move the fully extracted directory as a unit. Application data is stored in your Windows user profile, not beside these executables.
'@
  [IO.File]::WriteAllText($Path, $text.TrimStart() + "`r`n", [Text.UTF8Encoding]::new($false))
}

function New-ReleaseArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$ManagedBuildRoot,
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$LauncherCliPath,
    [Parameter(Mandatory = $true)][string]$OutletPath,
    [Parameter(Mandatory = $true)][string]$OAuthPath,
    [Parameter(Mandatory = $true)][string]$BeamReleaseRoot,
    [Parameter(Mandatory = $true)][string]$PostgresRoot,
    [switch]$ValidateBinaries
  )

  $stagingParent = Join-Path $ManagedBuildRoot 'staging'
  $staging = Join-Path $stagingParent $Id
  New-Item -ItemType Directory -Force -Path $stagingParent | Out-Null
  Remove-ManagedDirectory $staging $stagingParent
  New-Item -ItemType Directory -Path (Join-Path $staging 'resources') | Out-Null

  Copy-Item -LiteralPath $LauncherPath -Destination (Join-Path $staging 'intellectual-club-launcher.exe')
  Copy-Item -LiteralPath $LauncherCliPath -Destination (Join-Path $staging 'intellectual-club-launcher-cli.exe')
  Copy-Item -LiteralPath $OutletPath -Destination (Join-Path $staging 'outlet-shell-desktop.exe')
  Copy-Item -LiteralPath $OAuthPath -Destination (Join-Path $staging 'openai-oauth.exe')
  foreach ($binaryCopy in @(
      @($LauncherPath, (Join-Path $staging 'intellectual-club-launcher.exe')),
      @($LauncherCliPath, (Join-Path $staging 'intellectual-club-launcher-cli.exe')),
      @($OutletPath, (Join-Path $staging 'outlet-shell-desktop.exe')),
      @($OAuthPath, (Join-Path $staging 'openai-oauth.exe'))
    )) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $binaryCopy[0]).Hash -ne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryCopy[1]).Hash) {
      throw "Staged executable differs from its release build: $($binaryCopy[1])"
    }
  }
  Write-FirstLaunchInstructions (Join-Path $staging 'First Launch.txt')
  Copy-DirectoryContents $BeamReleaseRoot (Join-Path $staging 'resources\intellectual_club')
  $stagedPostgres = Join-Path $staging 'resources\postgresql'
  Copy-DirectoryContents $PostgresRoot $stagedPostgres
  Remove-UnbundledPostgresLanguageExtensions $stagedPostgres

  Assert-ReleaseTree $staging
  if ($ValidateBinaries) { Assert-WindowsPayload $staging }

  New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
  $outletAsset = Join-Path $OutputRoot "outlet-shell-desktop-$Id-windows-x64.exe"
  $oauthAsset = Join-Path $OutputRoot "openai-oauth-$Id-windows-x64.exe"
  $zipAsset = Join-Path $OutputRoot "intellectual-club-$Id-windows-x64.zip"
  $sumsAsset = Join-Path $OutputRoot 'SHA256SUMS.txt'
  foreach ($asset in @($outletAsset, $oauthAsset, $zipAsset, $sumsAsset)) {
    if (Test-Path -LiteralPath $asset) { Remove-Item -LiteralPath $asset -Force }
  }

  Copy-Item -LiteralPath $OutletPath -Destination $outletAsset
  Copy-Item -LiteralPath $OAuthPath -Destination $oauthAsset
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipAsset, [IO.Compression.CompressionLevel]::Optimal, $false)

  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $outletAsset).Hash -ne
      (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $staging 'outlet-shell-desktop.exe')).Hash) {
    throw 'Standalone outlet executable differs from the copy in the ZIP.'
  }
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $oauthAsset).Hash -ne
      (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $staging 'openai-oauth.exe')).Hash) {
    throw 'Standalone OAuth executable differs from the copy in the ZIP.'
  }

  $archive = [IO.Compression.ZipFile]::OpenRead($zipAsset)
  try {
    $rootEntries = @($archive.Entries |
        Where-Object { $_.FullName.TrimEnd('/') -ne '' } |
        ForEach-Object { $_.FullName.TrimEnd('/').Split('/')[0] } |
        Sort-Object -Unique)
    $expected = @('First Launch.txt', 'intellectual-club-launcher-cli.exe', 'intellectual-club-launcher.exe', 'openai-oauth.exe', 'outlet-shell-desktop.exe', 'resources') | Sort-Object
    if (($rootEntries -join "`n") -ne ($expected -join "`n")) {
      throw "Unexpected ZIP root entries: $($rootEntries -join ', ')"
    }
  }
  finally { $archive.Dispose() }

  $sumLines = foreach ($asset in @($outletAsset, $oauthAsset, $zipAsset)) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $asset).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $asset)"
  }
  [IO.File]::WriteAllLines($sumsAsset, $sumLines, [Text.UTF8Encoding]::new($false))

  [pscustomobject]@{
    Outlet = $outletAsset
    OAuth = $oauthAsset
    Zip = $zipAsset
    Checksums = $sumsAsset
    Staging = $staging
  }
}

function Wait-ForMainWindow {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$TimeoutSeconds = 30
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($Process.HasExited) { throw "$Name exited before creating a window." }
    $Process.Refresh()
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return }
    Start-Sleep -Milliseconds 250
  }
  throw "$Name did not create a top-level window within $TimeoutSeconds seconds."
}

function Close-GuiProcess {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
  if ($Process.HasExited) { return }
  [void]$Process.CloseMainWindow()
  if (-not $Process.WaitForExit(10000)) {
    $Process.Kill($true)
    $Process.WaitForExit()
  }
}

function Wait-ForHttpStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][int]$ExpectedStatus,
    [int]$TimeoutSeconds = 30
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $lastStatus = $null
  $lastError = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -NoProxy -SkipHttpErrorCheck -Uri $Uri -TimeoutSec 5
      $lastStatus = $response.StatusCode
      if ($lastStatus -eq $ExpectedStatus) { return }
    }
    catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 250
  }

  $detail = if ($lastStatus) { "last HTTP status was $lastStatus" } else { "last error was $lastError" }
  throw "$Uri did not return HTTP $ExpectedStatus within $TimeoutSeconds seconds; $detail"
}

function Wait-ForManagedDistributionProcessesToExit {
  param(
    [Parameter(Mandatory = $true)][string]$DistributionRoot,
    [int]$TimeoutSeconds = 30
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $managedNames = @('erl', 'postgres', 'intellectual-club-launcher', 'intellectual-club-launcher-cli')
  do {
    $remaining = @(Get-Process -Name $managedNames -ErrorAction SilentlyContinue | Where-Object {
        try {
          $_.Path -and $_.Path.StartsWith($DistributionRoot, [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
          $false
        }
      })
    if ($remaining.Count -eq 0) { return }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)

  $details = $remaining | ForEach-Object { "$($_.Name) pid=$($_.Id)" }
  throw "Managed processes remained after launcher stop: $($details -join ', ')"
}

function Invoke-EndToEndSmoke {
  param(
    [Parameter(Mandatory = $true)][string]$StagingRoot,
    [Parameter(Mandatory = $true)][string]$BuildRoot
  )

  $smokeParent = Join-Path $BuildRoot 'smoke'
  New-Item -ItemType Directory -Force -Path $smokeParent | Out-Null
  $smokeRoot = Join-Path $smokeParent "Путь с пробелами-$PID-$([Guid]::NewGuid().ToString('N'))"
  $distribution = Join-Path $smokeRoot 'Intellectual Club'
  $profileRoot = Join-Path $smokeRoot 'isolated-profile'
  New-Item -ItemType Directory -Force -Path $distribution, $profileRoot | Out-Null
  Copy-DirectoryContents $StagingRoot $distribution

  $previousAppData = $env:APPDATA
  $previousLocalAppData = $env:LOCALAPPDATA
  $launcher = Join-Path $distribution 'intellectual-club-launcher.exe'
  $launcherCli = Join-Path $distribution 'intellectual-club-launcher-cli.exe'
  $outlet = Join-Path $distribution 'outlet-shell-desktop.exe'
  $oauth = Join-Path $distribution 'openai-oauth.exe'
  $launcherGui = $null
  $outletGui = $null
  try {
    $env:APPDATA = Join-Path $profileRoot 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileRoot 'AppData\Local'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null

    $paths = Invoke-CaptureNative $launcherCli @('paths', '--json') $distribution | ConvertFrom-Json
    if ([IO.Path]::GetFullPath($paths.app_dir) -ne [IO.Path]::GetFullPath((Join-Path $distribution 'resources\intellectual_club'))) {
      throw "Launcher did not discover its bundled application: $($paths.app_dir)"
    }
    $config = Get-Content -LiteralPath $paths.config_path -Raw | ConvertFrom-Json
    $config.postgres_port = Get-FreeTcpPort
    $config.app_port = Get-FreeTcpPort
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paths.config_path -Encoding utf8NoBOM

    Invoke-Native $launcherCli @('doctor') $distribution
    Invoke-Native $launcherCli @('start') $distribution
    $status = Invoke-CaptureNative $launcherCli @('status', '--json') $distribution | ConvertFrom-Json
    if (-not $status.app.healthy -or -not $status.postgres.healthy -or -not $status.daemon.healthy) {
      throw "Launcher status is not healthy after start: $($status | ConvertTo-Json -Depth 10)"
    }
    & (Join-Path $script:RepositoryRoot 'bin\tests\windows-launcher-no-console-test.ps1') `
      -LauncherCliPath $launcherCli `
      -WorkingDirectory $distribution
    Wait-ForHttpStatus "http://127.0.0.1:$($config.app_port)/health" 204 30

    $createAdmin = Join-Path $distribution 'resources\intellectual_club\bin\create-admin.bat'
    $env:DATABASE_URL = $status.status.database_url
    $env:FILE_STORAGE_PATH = $config.files_data_dir
    $env:PORT = $config.app_port.ToString()
    $env:SECRET_KEY_BASE = $config.secret_key_base
    $env:TOKEN_SIGNING_SECRET = $config.token_signing_secret
    $adminPayload = @{ username = 'windows-smoke-admin'; password = 'Windows-Smoke-Password-42!'; password_confirmation = 'Windows-Smoke-Password-42!' } | ConvertTo-Json -Compress
    $adminOutput = $adminPayload | & $createAdmin --json-stdin 2>&1
    if ($LASTEXITCODE -ne 0 -or ($adminOutput | Out-String) -notmatch '"ok"\s*:\s*true') {
      throw "create-admin smoke failed:`n$($adminOutput | Out-String)"
    }

    $backup = Join-Path $profileRoot 'smoke-backup.dump'
    Invoke-Native $launcherCli @('backup', '--output', $backup) $distribution
    $backupFiles = [IO.Path]::ChangeExtension($backup, 'files')
    foreach ($backupPath in @($backup, "$backup.json", $backupFiles)) {
      if (-not (Test-Path -LiteralPath $backupPath)) { throw "Backup smoke output is missing: $backupPath" }
    }

    $launcherStartInfo = [Diagnostics.ProcessStartInfo]::new($launcher)
    $launcherStartInfo.WorkingDirectory = $distribution
    $launcherStartInfo.UseShellExecute = $false
    $launcherGui = [Diagnostics.Process]::Start($launcherStartInfo)
    Wait-ForMainWindow $launcherGui 'launcher GUI'
    Close-GuiProcess $launcherGui
    $launcherGui = $null
    $statusAfterGui = Invoke-CaptureNative $launcherCli @('status', '--json') $distribution | ConvertFrom-Json
    if (-not $statusAfterGui.app.healthy -or -not $statusAfterGui.postgres.healthy) {
      throw 'Closing the launcher GUI stopped a managed service.'
    }

    $outletStartInfo = [Diagnostics.ProcessStartInfo]::new($outlet)
    $outletStartInfo.WorkingDirectory = $distribution
    $outletStartInfo.UseShellExecute = $false
    $outletGui = [Diagnostics.Process]::Start($outletStartInfo)
    Wait-ForMainWindow $outletGui 'outlet GUI'
    Close-GuiProcess $outletGui
    $outletGui = $null

    Invoke-Native $oauth @('--help') $distribution
    Assert-ReleaseTree $distribution
    Invoke-Native $launcherCli @('stop') $distribution
    $stopped = Invoke-CaptureNative $launcherCli @('status', '--json') $distribution | ConvertFrom-Json
    if ($stopped.daemon.healthy -or $stopped.app.healthy -or $stopped.postgres.healthy) {
      throw "A managed service remained healthy after stop: $($stopped | ConvertTo-Json -Depth 10)"
    }
    Wait-ForManagedDistributionProcessesToExit $distribution 30
  }
  finally {
    if ($launcherGui) { Close-GuiProcess $launcherGui }
    if ($outletGui) { Close-GuiProcess $outletGui }
    if (Test-Path -LiteralPath $launcherCli) { & $launcherCli stop 2>$null | Out-Null }
    foreach ($name in @('DATABASE_URL', 'FILE_STORAGE_PATH', 'PORT', 'SECRET_KEY_BASE', 'TOKEN_SIGNING_SECRET')) {
      Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
    Remove-ManagedDirectory $smokeRoot $smokeParent
  }
}

function Invoke-PackagingSelfTest {
  $parent = Join-Path ([IO.Path]::GetTempPath()) 'intellectual-club-windows-release-self-test'
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $root = Join-Path $parent "run-$PID-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $root | Out-Null
  try {
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousUserProfile = $env:USERPROFILE
    $previousPath = $env:Path
    $previousErlangHome = $env:ERLANG_HOME
    try {
      foreach ($case in @(
          @{ Name = 'none'; Directories = @(); Expected = @() },
          @{ Name = 'one'; Directories = @('profile\.cargo\bin'); Expected = @('profile\.cargo\bin') },
          @{
            Name = 'multiple'
            Directories = @('local\IntellectualClubDev\toolchains\node-v24.16.0-win-x64', 'profile\.cargo\bin')
            Expected = @('local\IntellectualClubDev\toolchains\node-v24.16.0-win-x64', 'profile\.cargo\bin')
          }
        )) {
        $caseRoot = Join-Path $root "toolchain-path-$($case.Name)"
        $env:LOCALAPPDATA = Join-Path $caseRoot 'local'
        $env:USERPROFILE = Join-Path $caseRoot 'profile'
        foreach ($relative in $case.Directories) {
          New-Item -ItemType Directory -Force -Path (Join-Path $caseRoot $relative) | Out-Null
        }
        $env:Path = 'existing-path'

        Add-LocalToolchainsToPath

        $expectedPaths = @($case.Expected | ForEach-Object { Join-Path $caseRoot $_ })
        $expectedPath = if ($expectedPaths.Count -gt 0) {
          ($expectedPaths -join ';') + ';existing-path'
        }
        else {
          'existing-path'
        }
        if ($env:Path -ne $expectedPath) {
          throw "Local toolchain path discovery failed for $($case.Name): expected '$expectedPath', found '$env:Path'"
        }
      }
    }
    finally {
      $env:LOCALAPPDATA = $previousLocalAppData
      $env:USERPROFILE = $previousUserProfile
      $env:Path = $previousPath
      $env:ERLANG_HOME = $previousErlangHome
    }

    $previousVcToolsRedistDir = $env:VCToolsRedistDir
    $testRedistRoot = Join-Path $root 'vc-redist'
    $expectedCrtDirectory = Join-Path $testRedistRoot 'x64\Microsoft.VC145.CRT'
    New-Item -ItemType Directory -Force -Path $expectedCrtDirectory | Out-Null
    try {
      $env:VCToolsRedistDir = $testRedistRoot
      $actualCrtDirectory = Get-VcRuntimeDirectory
      if ($actualCrtDirectory -ne $expectedCrtDirectory) {
        throw "VC runtime discovery ignored the active toolset: expected '$expectedCrtDirectory', found '$actualCrtDirectory'"
      }
    }
    finally {
      $env:VCToolsRedistDir = $previousVcToolsRedistDir
    }

    $sources = Join-Path $root 'sources'
    $beam = Join-Path $sources 'beam'
    $postgres = Join-Path $sources 'postgres'
    New-Item -ItemType Directory -Force -Path (Join-Path $beam 'bin'), (Join-Path $postgres 'bin'), (Join-Path $postgres 'lib'), (Join-Path $postgres 'share\extension') | Out-Null
    [IO.File]::WriteAllText((Join-Path $sources 'launcher.exe'), 'launcher')
    [IO.File]::WriteAllText((Join-Path $sources 'launcher-cli.exe'), 'launcher cli')
    [IO.File]::WriteAllText((Join-Path $sources 'outlet.exe'), 'outlet')
    [IO.File]::WriteAllText((Join-Path $sources 'oauth.exe'), 'oauth')
    [IO.File]::WriteAllText((Join-Path $beam 'bin\intellectual_club.bat'), 'release')
    [IO.File]::WriteAllText((Join-Path $postgres 'bin\postgres.exe'), 'postgres')
    [IO.File]::WriteAllText((Join-Path $postgres 'bin\initdb.exe'), 'initdb')
    [IO.File]::WriteAllText((Join-Path $postgres 'bin\libpq.dll'), 'libpq')
    [IO.File]::WriteAllText((Join-Path $postgres 'lib\plperl.dll'), 'optional runtime')
    [IO.File]::WriteAllText((Join-Path $postgres 'share\extension\plperl.control'), 'optional runtime')

    $result = New-ReleaseArtifacts `
      -Id 'selftest-0000000' `
      -OutputRoot (Join-Path $root 'output') `
      -ManagedBuildRoot (Join-Path $root 'build') `
      -LauncherPath (Join-Path $sources 'launcher.exe') `
      -LauncherCliPath (Join-Path $sources 'launcher-cli.exe') `
      -OutletPath (Join-Path $sources 'outlet.exe') `
      -OAuthPath (Join-Path $sources 'oauth.exe') `
      -BeamReleaseRoot $beam `
      -PostgresRoot $postgres

    foreach ($asset in @($result.Outlet, $result.OAuth, $result.Zip, $result.Checksums)) {
      if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) { throw "Self-test asset is missing: $asset" }
    }
    $stagedLauncherCli = Join-Path $result.Staging 'intellectual-club-launcher-cli.exe'
    if (-not (Test-Path -LiteralPath $stagedLauncherCli -PathType Leaf)) {
      throw "CLI launcher is missing from the portable distribution: $stagedLauncherCli"
    }
    if ((Get-Content -LiteralPath $result.Checksums).Count -ne 3) {
      throw 'SHA256SUMS.txt must contain exactly three payload checksums.'
    }
    foreach ($removed in @(
        (Join-Path $result.Staging 'resources\postgresql\lib\plperl.dll'),
        (Join-Path $result.Staging 'resources\postgresql\share\extension\plperl.control')
      )) {
      if (Test-Path -LiteralPath $removed) { throw "Optional PostgreSQL language module was staged: $removed" }
    }
    Write-Host 'Windows release packaging self-test passed.' -ForegroundColor Green
  }
  finally {
    Remove-ManagedDirectory $root $parent
  }
}

if ($SelfTest) {
  Invoke-PackagingSelfTest
  exit 0
}

if ($env:OS -ne 'Windows_NT') { throw 'This release must be built on Windows.' }
Add-LocalToolchainsToPath
Initialize-VisualStudioEnvironment
Assert-ToolVersions

if (-not $ReleaseId) {
  $sha = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $shortSha = $sha.Substring(0, 12)
  $epoch = [long]((& git -C $script:RepositoryRoot show -s --format=%ct $sha).Trim())
  $timestamp = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'")
  $ReleaseId = "$timestamp-$shortSha"
}
if ($ReleaseId -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid release id: $ReleaseId" }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $script:RepositoryRoot 'build\windows' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $script:RepositoryRoot "dist\windows\$ReleaseId" }
$BuildDirectory = Get-FullPath $BuildDirectory
$OutputDirectory = Get-FullPath $OutputDirectory
New-Item -ItemType Directory -Force -Path $BuildDirectory, $OutputDirectory | Out-Null

Write-Step 'Preparing pinned PostgreSQL, libvips, and PDF NIF payloads'
$dependencies = Ensure-Dependencies $BuildDirectory
$env:RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = $dependencies.RustlerCache
$env:IC_VIPS_BIN = Join-Path $dependencies.VipsRoot 'bin\vips.exe'
$env:MIX_TAILWIND_PATH = $dependencies.TailwindBin
$env:MIX_ESBUILD_PATH = $dependencies.EsbuildBin

Invoke-Native 'mix' @('local.hex', '--if-missing', '--force') (Join-Path $script:RepositoryRoot 'server')
Invoke-Native 'mix' @('local.rebar', '--if-missing', '--force') (Join-Path $script:RepositoryRoot 'server')

if (-not $SkipTests) {
  Write-Step 'Testing and building the frontend'
  $env:npm_config_fetch_retries = '5'
  $env:npm_config_fetch_timeout = '600000'
  # Keep installation deterministic without coupling the release job to the
  # npm advisory service (which can hang after reification on Windows).
  Invoke-Native 'npm.cmd' @('ci', '--no-audit') (Join-Path $script:RepositoryRoot 'frontend')
  # Worker startup is slow under Windows Defender after a clean npm install.
  # Four sequential shards keep Vitest's per-file isolation while bounding
  # the number of worker handshakes in each process.
  foreach ($shard in 1..4) {
    Invoke-VitestShard $shard (Join-Path $script:RepositoryRoot 'frontend')
  }
  Invoke-Native 'npm.cmd' @('run', 'typecheck') (Join-Path $script:RepositoryRoot 'frontend')
  Invoke-Native 'npm.cmd' @('run', 'build') (Join-Path $script:RepositoryRoot 'frontend')

  Write-Step 'Checking and testing the Rust workspace'
  Invoke-Native 'cargo' @('fmt', '--all', '--', '--check') (Join-Path $script:RepositoryRoot 'native_tools')
  Invoke-Native 'cargo' @('check', '--workspace', '--locked', '--target', 'x86_64-pc-windows-msvc') (Join-Path $script:RepositoryRoot 'native_tools')
  Invoke-Native 'cargo' @('test', '--workspace', '--locked', '--target', 'x86_64-pc-windows-msvc') (Join-Path $script:RepositoryRoot 'native_tools')

  Write-Step 'Checking and testing the Elixir application against portable PostgreSQL'
  Invoke-WithTestPostgres $dependencies.PostgresRoot $BuildDirectory {
    $server = Join-Path $script:RepositoryRoot 'server'
    $env:MIX_ENV = 'test'
    Invoke-Native 'mix' @('deps.get') $server
    Invoke-Native 'mix' @('picosat.sync') $server
    Invoke-Native 'mix' @('compile', '--warnings-as-errors') $server
    Invoke-Native 'mix' @('format', '--check-formatted') $server
    Invoke-Native 'mix' @('test') $server
    Invoke-Native 'mix' @('precommit') $server
  }
}

Write-Step 'Building four static-CRT Rust release executables'
$nativeRoot = Join-Path $script:RepositoryRoot 'native_tools'
Invoke-Native 'cargo' @(
  'build', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc',
  '--package', 'intellectual-club-launcher',
  '--package', 'outlet-shell-desktop',
  '--package', 'openai-oauth'
) $nativeRoot
$rustRelease = Join-Path $nativeRoot 'target\x86_64-pc-windows-msvc\release'
$launcherPath = Join-Path $rustRelease 'intellectual-club-launcher.exe'
$launcherCliPath = Join-Path $rustRelease 'intellectual-club-launcher-cli.exe'
$outletPath = Join-Path $rustRelease 'outlet-shell-desktop.exe'
$oauthPath = Join-Path $rustRelease 'openai-oauth.exe'

Write-Step 'Building the Windows BEAM release'
$serverRoot = Join-Path $script:RepositoryRoot 'server'
$env:MIX_ENV = 'prod'
Invoke-Native 'mix' @('deps.get', '--only', 'prod') $serverRoot
Invoke-Native 'mix' @('picosat.sync') $serverRoot
Invoke-Native 'mix' @('compile', '--warnings-as-errors') $serverRoot
Invoke-Native 'mix' @('assets.deploy') $serverRoot
Invoke-Native 'mix' @('release', '--overwrite') $serverRoot
$beamRelease = Join-Path $serverRoot '_build\prod\rel\intellectual_club'
$applicationPriv = Get-ChildItem -LiteralPath (Join-Path $beamRelease 'lib') -Directory -Filter 'intellectual_club-*' |
  Select-Object -First 1 |
  ForEach-Object { Join-Path $_.FullName 'priv' }
if (-not $applicationPriv) { throw 'Could not locate the Intellectual Club application priv directory.' }
Copy-DirectoryContents $dependencies.VipsRoot (Join-Path $applicationPriv 'libvips')

$ertsBin = Get-ChildItem -LiteralPath $beamRelease -Directory -Filter 'erts-*' |
  Select-Object -First 1 |
  ForEach-Object { Join-Path $_.FullName 'bin' }
if (-not $ertsBin) { throw 'Could not locate the ERTS bin directory.' }
Copy-VcRuntime $ertsBin
Copy-VcRuntime (Join-Path $dependencies.PostgresRoot 'bin')

Write-Step 'Staging, validating, and packaging Windows assets'
$artifacts = New-ReleaseArtifacts `
  -Id $ReleaseId `
  -OutputRoot $OutputDirectory `
  -ManagedBuildRoot $BuildDirectory `
  -LauncherPath $launcherPath `
  -LauncherCliPath $launcherCliPath `
  -OutletPath $outletPath `
  -OAuthPath $oauthPath `
  -BeamReleaseRoot $beamRelease `
  -PostgresRoot $dependencies.PostgresRoot `
  -ValidateBinaries

if (-not $SkipTests) {
  Write-Step 'Running portable end-to-end and GUI smoke tests'
  Invoke-EndToEndSmoke $artifacts.Staging $BuildDirectory
}

Write-Host "`nWindows release is ready:" -ForegroundColor Green
foreach ($path in @($artifacts.Outlet, $artifacts.OAuth, $artifacts.Zip, $artifacts.Checksums)) {
  Write-Host "  $path"
}
