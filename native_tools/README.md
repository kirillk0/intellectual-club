# Native Tools

This directory contains native helper tools for Intellectual Club.

The Rust workspace builds all native binaries together:

- `openai-oauth` — OpenAI OAuth PKCE helper with token refresh support
- `intellectual-club-launcher` — launcher core; Windows builds separate GUI and CLI EXEs, while macOS keeps one combined executable
- `outlet-core` — shared HTTP transport, pairing, file helpers, runner loop, and provider interfaces
- `outlet-shell` — reusable shell outlet tools
- `outlet-shell-daemon` — headless binary for containers and server environments
- `outlet-shell-desktop` — desktop GUI for managing multiple shell outlet profiles

Build all binaries:

```bash
cargo build --manifest-path native_tools/Cargo.toml --release
```

Run the shell daemon locally:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p outlet-shell-daemon -- \
  --server-url http://localhost:4000 \
  --token '<token>'
```

Run the desktop app:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p outlet-shell-desktop
```

## macOS Releases

Build the Apple Silicon native tools payload locally:

```bash
./bin/build-macos-native-tools --output build/native-tools
```

This creates `IC Shell Outlet.app` and the `openai-oauth` terminal executable. The
`Publish Intellectual Club macOS` workflow publishes two ad-hoc-signed,
non-notarized disk images:

- `intellectual-club-native-tools-<release-id>-macos-arm64.dmg` contains
  `IC Shell Outlet.app` and `openai-oauth`;
- `intellectual-club-<release-id>-macos-arm64.dmg` additionally contains the
  full `Intellectual Club.app` launcher and server bundle.

Run the OAuth helper from Terminal after copying it to a directory on `PATH`:

```bash
openai-oauth
openai-oauth --refresh '<refresh_token>'
```

`Intellectual Club.app` supports macOS 15 and newer. The native tools are built
with a macOS 11 deployment target.

## Windows Releases

Windows releases are built and tested on Windows 11 x64 with VS 2022 Build
Tools (C++ and Windows SDK), Rust 1.92.0 MSVC, Erlang/OTP 29.0, Elixir 1.20.2,
and Node.js 24.16.0. Install those tools, then run the same script used by CI:

```powershell
pwsh -NoProfile -File .\bin\build-windows-release.ps1
```

The script downloads checksum-pinned PostgreSQL 16.13.0, libvips 8.18.2, and
the Windows PDF NIF into `build\windows`; it does not install PostgreSQL or
libvips system-wide. It runs frontend, Rust, and Elixir checks and tests before
building the release. `-SkipTests` is available for an incremental packaging
iteration after a successful full run. The packaging contract has a fast,
standalone test:

```powershell
pwsh -NoProfile -File .\bin\tests\build-windows-release-test.ps1
pwsh -NoProfile -File .\bin\tests\windows-launcher-subsystems-test.ps1
```

`Publish Intellectual Club Windows` runs on pull requests, pushes to `main`,
and manual dispatches. Publishing is restricted to `main`. Its deterministic
tag combines the commit UTC timestamp and short SHA:

```text
intellectual-club-windows-20260711T074742Z-45940cc0a1a8
```

Each published release contains exactly four assets:

- `outlet-shell-desktop-<id>-windows-x64.exe` — standalone GUI outlet with an
  embedded PE/window icon;
- `openai-oauth-<id>-windows-x64.exe` — standalone console OAuth helper;
- `intellectual-club-<id>-windows-x64.zip` — complete portable distribution;
- `SHA256SUMS.txt` — SHA-256 for the three payloads above.

The ZIP root is stable:

```text
intellectual-club-launcher.exe
intellectual-club-launcher-cli.exe
outlet-shell-desktop.exe
openai-oauth.exe
First Launch.txt
resources/
  intellectual_club/
  postgresql/
```

The launcher discovers both bundled directories relative to its own EXE, so a
fully extracted directory can be moved as a unit and opened by double-clicking
`intellectual-club-launcher.exe`. That file uses the Windows GUI PE subsystem,
so Explorer does not allocate a terminal window. Use
`intellectual-club-launcher-cli.exe` for CLI commands and `--app-dir`; it uses
the console subsystem and preserves normal stdout, stderr, exit codes, and help.
Closing the GUI launcher does not stop PostgreSQL or the BEAM application.
Configuration, databases, uploaded files, backups, and runtime state are stored
in the Windows user profile, never beside the extracted EXEs.

For example, from the extracted directory:

```powershell
.\intellectual-club-launcher-cli.exe doctor
.\intellectual-club-launcher-cli.exe status --json
.\intellectual-club-launcher-cli.exe stop
```

The archive is unsigned and may trigger SmartScreen; verify `SHA256SUMS.txt`
before running it. Windows 11 x64 is the tested and guaranteed platform.
Windows 10 is best-effort, and Windows ARM64, MSI/MSIX, code signing,
auto-update, and an independent installer flow are not provided.

Run OpenAI OAuth from the Rust workspace during development:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth -- --refresh '<refresh_token>'
```

Build and run the desktop launcher from the development macOS app bundle:

```bash
./bin/build-dev-artifacts
open "build/dev/Intellectual Club.app"
```

Opening the app starts PostgreSQL and the bundled BEAM release, then opens the web UI.
Closing the launcher window leaves both services running. Run the bundled launcher from
CLI to manage them:

```bash
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" start
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" restart
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" status --json
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" logs
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" open
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" create-admin
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" backup
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" move-files --to /path/to/files
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" stop
```

The launcher stores config, PostgreSQL data, file storage, backups, runtime status, and
cached PostgreSQL installations in OS-specific app data directories via
`directories::ProjectDirs`.

The `create-admin` command prompts for credentials without echoing the password, starts
the embedded PostgreSQL instance when needed, applies pending migrations, and creates a
new administrator. The same form is available in the launcher's `Administrators` page.

## Shell Outlet Image

The canonical shell Docker image uses `outlet-shell-daemon` as the entrypoint command while keeping a Python utility environment for agent work.

Build and run:

```bash
docker build -t outlet-shell -f native_tools/outlet-shell-image/Dockerfile .
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_TOKEN="<token>" \
  outlet-shell
```

The image contains common CLI tools and the Python data/science utility packages from `native_tools/outlet-shell-image/requirements.additional.txt`. The host folder `./share` can be mounted into the container at `/mnt/share` if you want a shared workspace.

## Shell Daemon Settings

Required settings:

- `OUTLET_SERVER_URL` or `--server-url`
- `OUTLET_TOKEN` or `--token`

Optional settings:

- `OUTLET_RUNNER_ID` or `--runner-id`
- `OUTLET_LOG_LEVEL` or `--log-level`
- `OUTLET_MAX_CONCURRENCY` or `--max-concurrency`
- `OUTLET_BACKGROUND_CONTROL_CAPACITY` or `--background-control-capacity`
- `OUTLET_POLL_MAX_WAIT_SECONDS` or `--poll-max-wait`
- `OUTLET_COMPLETE_MAX_RETRIES` or `--complete-max-retries`
- `OUTLET_COMPLETE_MAX_SECONDS` or `--complete-max-seconds`
- `OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS` or `--background-terminal-ttl-seconds` (must be greater than zero)
- `SHELL_OUTLET_MAX_STREAM_CHARS`
- `SHELL_OUTLET_MAX_SUMMARY_CHARS`
- `SHELL_OUTLET_WINDOWS_FORCE_UTF8`

## Background Tool Calls

The outlet protocol accepts `background_start`, `background_status`, and
`background_cancel` poll operations in addition to the default `execute` operation.
The server supplies a stable `background_task_id`; starting the same id again is
idempotent only when the function and arguments are unchanged.

Background execution is kept in memory by `outlet-core`. Foreground calls and running
background jobs share the configured provider concurrency limit, while status and
cancel control calls do not consume a provider slot. The runner reports a separate
`control_capacity` poll lane so those operations remain deliverable while provider
execution is saturated. Completed, failed, and canceled entries remain queryable for
24 hours by default. The TTL is configurable with
`OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS` or
`--background-terminal-ttl-seconds`. Runner process restarts intentionally do not
recover in-memory background jobs. After a terminal result expires, the runner keeps
the request digest for the rest of the runner session: replaying that UUID cannot run
the side effect again and returns the stable `outlet_task_expired` error.

`outlet-shell` advertises background support for `run_command`. Its stdout and stderr
are exposed as cursor-based progress entries, and cancellation terminates the command
process tree. The in-memory progress log is capped at 400,000 characters and reports a
truncation marker and total observed character count when the cap is reached.
