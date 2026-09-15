# Task Container Outlet

A small headless outlet runner with one disposable Linux container per chat family.
It uses `outlet-core`, Docker Engine's Unix-socket API and a bundled SQLite library.
The runner is a single executable; **Docker Engine is still an external prerequisite**.
It does not implement its own container runtime, require Docker CLI at runtime, or run
an outlet process inside each task container.

## Quick start

Install/start Docker Engine on a Linux host. Give the service account access to its
socket. Access to a rootful Docker socket is effectively root access to the host:
use a dedicated trusted account/host, never expose the socket over unauthenticated TCP.

Build from the repository root:

```sh
cargo build --manifest-path native_tools/Cargo.toml --release -p outlet-task-container --locked
```

On an appropriately provisioned musl toolchain, use `--target x86_64-unknown-linux-musl`
(or `aarch64-unknown-linux-musl`) for a static executable. SQLite is bundled and TLS
uses rustls; no shared SQLite/OpenSSL installation is needed. GNU builds require a
compatible host libc. The macOS build can be used with a Linux Docker Engine for
local development; Windows is not a supported runner host.

Start with an outlet token from Intellectual Club:

```sh
export OUTLET_SERVER_URL=https://club.example.org
export OUTLET_TOKEN='your-outlet-token'
./outlet-task-container --data-dir ./task-state --image python:3.12-bookworm
```

Or pair once, following the printed approval URL:

```sh
./outlet-task-container --server-url https://club.example.org \
  --data-dir ./task-state --pair
# Subsequent starts use the private saved connection:
./outlet-task-container --data-dir ./task-state
```

No inbound runner port is needed: polling and files use outbound HTTP(S).
See `--help` for all CLI options and their environment-variable equivalents. The server
must support outlet execution context (`chat_id`, `root_chat_id`, `user_id`). Missing
routing information is an error; it never falls back to a shared container.

## Images

`--image` / `OUTLET_IMAGE` accepts a local image ID, tag or digest. If absent locally,
it is pulled lazily. Creation uses the resolved immutable image ID. Existing workspaces
are not replaced when a tag changes. To update a mutable tag, explicitly `docker pull`
on the host; there is no background pull/update agent. Private images can be pre-pulled
with the administrator's Docker credentials; the runner does not read registry secrets.

The image must provide `/bin/sh`, `sleep infinity`, and `mkdir`; use a conventional
Debian/Ubuntu/Python image. Its entrypoint/CMD are replaced with an idle process.
Working directory is `/workspace`; commands run as root **inside** the container to
allow installing document tools. Python's stock image does not include PDF/Office
utilities or Python document packages: install these in a custom image or with commands.
The repository's `outlet-shell-image` is also usable; its outlet entrypoint is overridden.
No host directories or Docker socket are mounted. Docker's default capabilities are
used except `NET_RAW`, with `no-new-privileges` and without privileged mode. Images declaring `VOLUME` are rejected
so files remain in the writable layer and cleanup has no hidden persistent volumes.

## Tools

- `run_command`: `argv` (preferred, preserves empty arguments) or `command` (`/bin/sh -c`),
  optional `cwd`, `env`, `stdin`, positive `timeout_seconds`, `use_secrets`.
- `download_file(file_id, local_path)`: authorized chat attachment to the container;
  creates parent directories.
- `upload_file(local_path)`: regular container file to a user-visible chat artifact.
- `read_image(local_path)`: PNG/JPEG/GIF/WebP file as model image input.

Relative paths start at `/workspace`; absolute paths are also container paths, never
runner-host paths. Upload one regular file at a time: zip/tar directories yourself.
Symlinks in downloaded container archives are rejected, never followed on the host.
Transfers are streamed through private temporary files, cleaned after each call.

`run_command` advertises background support. Enable its generated background wrapper
on the tool instance (the server disables new wrappers by default). Also enable
`check_background_task_status` and `cancel_background_task` on a bound agent-management
instance; the server hides background wrappers when no status control is available.
Enable `spawn`/`fork` there if needed; they are disabled by default on new instances.
The existing background status/cancel tools provide cursor-based progress and terminal results.
Raw progress is suppressed when managed secrets are requested; exact secret values
are redacted from final command output. Secrets go into this exec's environment, not
persistent container configuration. Commands themselves can deliberately write or
transform secrets; output redaction is not a security boundary.

## Lifecycle and persistence

Routing is keyed by the **server-issued** root chat and checked against the executing
user. Spawn/fork/handoff descendants share files and can execute concurrently. Normal
user forks in the same lineage also share state; the workspace is not a filesystem
snapshot per branch. Do not concurrently overwrite the same file unless intended.
See `docs/outlets.md` for lineage changes, the 100-hop bound and legacy-context behavior.

`containers.sqlite3` stores stable runner identity, outlet binding, container generations,
creation/deletion intents, active leases, `last_used_at` and destroyed-state tombstones.
It uses WAL and FULL synchronous durability. A data-directory lock prevents two processes
using one state database. Reuse the directory across restarts, and use a separate one
for each outlet. The database is bound to server URL and a token fingerprint; changing
the token requires a separate directory. Never copy a live database to run a second
runner. Back up the SQLite database with its backup API, or stop the runner and preserve
the entire directory including any WAL files.

Labels only mark ownership. Names include runner ID, root chat and generation. Only
verified owned containers are removed. Missing/stopped containers are recreated on the
next call; replies include a warning, reset reason and workspace generation. A Docker
communication error is **not** interpreted as a missing container. No command is silently
replayed after an uncertain result.

Idle containers and their timestamps survive a clean restart. If the runner crashes
while a call is active, startup removes the affected container to stop orphaned execs;
its next call explicitly reports the lost workspace. Aborted futures leave durable
deletion intent and attempt immediate cleanup. Background result/progress records remain
in `outlet-core` memory and do not survive a runner process restart; SQLite does not
pretend to recover a command result it cannot know.

If the database is lost, its identity is lost too. Old labelled containers are left
untouched, not adopted with guessed timestamps. Unknown objects in a known namespace
are warned about and left for manual inspection. Database corruption fails startup.

## Soft retention and emergency bounds

| Setting | Default | Meaning |
|---|---:|---|
| `OUTLET_MAX_CONTAINERS` | 32 | Soft retained-container target; 0 disables |
| `OUTLET_MAX_DISK_BYTES` | 20 GiB | Soft sum of owned writable layers (`SizeRw`); 0 disables |
| `OUTLET_GUARANTEED_TTL_SECONDS` | 86400 | Minimum idle retention after the most recent completed use |
| `OUTLET_MEMORY_BYTES` | 2 GiB | Per-container hard memory limit, swap bounded too; 0 disables |
| `OUTLET_PIDS_LIMIT` | 256 | Per-container process bound |
| `OUTLET_CPUS` | 2 | Per-container CPU ceiling |
| `OUTLET_COMMAND_TIMEOUT_SECONDS` | 300 | Default command timeout; overridable per call |
| `OUTLET_MAX_CONCURRENCY` | 20 | Shared foreground/background execution concurrency |
| `OUTLET_MAX_FILE_BYTES` | 512 MiB | Safety bound for each streamed file transfer |
| `OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS` | 86400 | In-memory background result retention |

Only creation triggers LRU housekeeping. It evicts least-recently-used **inactive**
containers outside the guaranteed TTL until under the soft targets. Busy containers
cannot be evicted even if a command runs longer than TTL. If all candidates are protected,
creation proceeds above the targets. There is no per-user quota or hard count limit.

Disk accounting is advisory: it excludes shared image layers, temporary transfer files,
Docker metadata and SQLite. Container logging is disabled to avoid unbounded Docker logs.
Lazy cleanup cannot enforce a hard disk budget while existing containers keep writing.
Monitor actual host free space; do not use the soft target as a filesystem quota.

**Command timeout or `background_cancel` destroys the entire shared task container**, stopping its
process tree and losing its writable files and any concurrent work. File-transfer
interruption also resets it conservatively. OOM/process/CPU limits are emergency host
protection, not tenant policies. OOM may kill only the offending exec rather than PID 1;
a surviving container can retain its files. There is no global resource watchdog: size
memory limits for your host and use a dedicated machine for untrusted workloads.
The TTL guarantee covers housekeeping, not OOM, manual removal, failures or cancellation.

Stopping a foreground chat generation does **not** cancel a command already dispatched
to an outlet: the current transport has no foreground-cancel operation. It runs until
completion or its runner-side timeout. Use the background wrapper for long work needing
explicit cancellation. Image preparation precedes the command timeout and has a separate
15-minute deadline; image pulls do not block emergency deletion of other workspaces.

## Administration

See `outlet-task-container.service` for an example systemd service. Store environment
configuration in a root-readable `/etc/outlet-task-container.env`, and put the binary
at `/usr/local/bin/outlet-task-container`. The service account needs its private state
directory and access to the Docker socket. `SIGINT`/`SIGTERM` stop polling and clean up
active work while retaining idle containers. Do not restart a desktop outlet to deploy
this separate runner.

```sh
journalctl -u outlet-task-container -f
docker ps -a --filter label=org.intellectual-club.task-runner
# Emergency removal of a specific task (use the ID from its reply/log):
docker rm -f <container-id>
```

There is no global `docker prune`, image pruning, scheduler, cluster management, or
background expiry daemon. Docker containers share the host kernel and normal bridge
network. This is suitable for trusted internal users, not a hostile multi-tenant sandbox.
Do not mount sensitive host data or expose the Engine socket inside task images.

## Tests

```sh
cargo test --manifest-path native_tools/Cargo.toml -p outlet-core -p outlet-task-container
# Explicit opt-in: creates/removes only isolated test namespaces on a Linux Engine.
OUTLET_TEST_DOCKER_SOCKET=/var/run/docker.sock OUTLET_TEST_IMAGE=python:3.12-bookworm \
  cargo test --manifest-path native_tools/Cargo.toml -p outlet-task-container -- --ignored --test-threads=1
```
