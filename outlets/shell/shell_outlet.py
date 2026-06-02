from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import mimetypes
import os
import shlex
import shutil
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any

if __package__ in {None, ""}:
    # Allow `python outlets/shell/shell_outlet.py` by restoring the project root
    # on sys.path before importing the package.
    project_root = Path(__file__).resolve().parents[2]
    project_root_str = os.fspath(project_root)
    if project_root_str not in sys.path:
        sys.path.insert(0, project_root_str)

from outlets.outlet_base import download_call_file, outlet_tool, run_outlet, upload_call_file

try:
    from PIL import Image as PILImage
    from PIL import UnidentifiedImageError
except ImportError:
    PILImage = None
    UnidentifiedImageError = OSError

logger = logging.getLogger(__name__)

_POSIX_SHELL_BASENAMES = {"bash", "zsh", "sh", "dash", "ksh"}
_TIMEOUT_TERMINATE_GRACE_SECONDS = 2.0
_TIMEOUT_DRAIN_SECONDS = 5.0

# Guardrails for huge outputs: sending multi-megabyte tool results over the
# outlet transport can break delivery (e.g., request size limits, connection
# resets). Keep defaults conservative, but allow overrides via env vars.
_MAX_STREAM_CHARS_DEFAULT = 200_000
_MAX_SUMMARY_CHARS_DEFAULT = 50_000
_JPEG_MAGIC_PREFIXES = (b"\xff\xd8\xff",)
_UTF8_ENCODING = "utf-8"
_WINDOWS_UTF8_BOOTSTRAP_MODE = "windows-force-utf8"
_WINDOWS_FORCE_UTF8_ENV = "SHELL_OUTLET_WINDOWS_FORCE_UTF8"


def _sniff_image_mime(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if any(data.startswith(prefix) for prefix in _JPEG_MAGIC_PREFIXES):
        return "image/jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    if data.startswith(b"BM"):
        return "image/bmp"
    return None


def _detect_image_mime(data: bytes) -> str | None:
    if not data:
        return None

    if PILImage is not None:
        try:
            with PILImage.open(io.BytesIO(data)) as image:
                detected_mime = PILImage.MIME.get(image.format)
                image.verify()
                if detected_mime:
                    return str(detected_mime)
        except (UnidentifiedImageError, OSError, ValueError):
            return None

    return _sniff_image_mime(data)


def _load_env_int(key: str, default: int) -> int:
    raw = os.environ.get(key)
    if raw is None:
        return int(default)
    try:
        return int(str(raw).strip())
    except ValueError:
        return int(default)


def _load_env_bool_from_mapping(env: dict[str, str] | None, key: str, default: bool) -> bool:
    if env is None:
        return bool(default)

    raw = env.get(key)
    if raw is None:
        return bool(default)

    raw = str(raw).strip().lower()
    if raw in {"1", "true", "yes", "y", "on"}:
        return True
    if raw in {"0", "false", "no", "n", "off"}:
        return False
    return bool(default)


def _truncate_text(text: str, max_chars: int) -> tuple[str, bool]:
    if not text:
        return "", False
    max_chars = max(0, int(max_chars))
    if max_chars <= 0:
        return "", True
    if len(text) <= max_chars:
        return text, False
    if max_chars <= 3:
        return text[:max_chars], True
    return text[: max_chars - 3] + "...", True


def _command_timeout_notice(timeout_seconds: int | None) -> str:
    if timeout_seconds and timeout_seconds > 0:
        seconds = int(timeout_seconds)
        unit = "second" if seconds == 1 else "seconds"
        return f"[timeout] Command exceeded timeout of {seconds} {unit}."
    return "[timeout] Command exceeded timeout."


def _append_command_timeout_notice(text: str, timeout_seconds: int | None) -> str:
    notice = _command_timeout_notice(timeout_seconds)
    text = text.strip()
    if not text:
        return notice
    return f"{text}\n\n{notice}"


def _resolve_executable(candidate: str) -> str | None:
    candidate = str(candidate or "").strip()
    if not candidate:
        return None
    if os.path.isabs(candidate):
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate
        return None
    return shutil.which(candidate)


def _detect_shell_executor() -> tuple[str, list[str], str]:
    """
    Returns (kind, argv_prefix, display_name).

    - kind: short identifier like "bash", "sh", "pwsh", "powershell", "cmd"
    - argv_prefix: argv list excluding the command string
    - display_name: human-readable, stable text for tool description
    """

    if os.name == "nt":
        pwsh = _resolve_executable("pwsh")
        if pwsh:
            return (
                "pwsh",
                [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"],
                f"{pwsh} -Command",
            )

        powershell = _resolve_executable("powershell") or _resolve_executable("powershell.exe")
        if powershell:
            return (
                "powershell",
                [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"],
                f"{powershell} -Command",
            )

        comspec = _resolve_executable(os.environ.get("COMSPEC", "")) or _resolve_executable("cmd.exe") or _resolve_executable("cmd")
        if comspec:
            return ("cmd", [comspec, "/d", "/s", "/c"], f"{comspec} /c")

        return ("cmd", ["cmd.exe", "/d", "/s", "/c"], "cmd.exe /c")

    preferred = os.environ.get("SHELL", "")
    preferred_path = _resolve_executable(preferred)
    if preferred_path:
        base = os.path.basename(preferred_path).lower()
        if base in _POSIX_SHELL_BASENAMES:
            return (base, [preferred_path, "-c"], f"{preferred_path} -c")

    for candidate in ("bash", "/bin/bash", "/usr/bin/bash", "zsh", "/bin/zsh", "/usr/bin/zsh", "sh", "/bin/sh", "/usr/bin/sh"):
        path = _resolve_executable(candidate)
        if not path:
            continue
        base = os.path.basename(path).lower()
        if base in _POSIX_SHELL_BASENAMES:
            return (base, [path, "-c"], f"{path} -c")

    return ("sh", ["/bin/sh", "-c"], "/bin/sh -c")


def _subprocess_isolation_kwargs() -> dict[str, Any]:
    if os.name == "nt":
        create_new_group = int(getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
        if create_new_group:
            return {"creationflags": create_new_group}
        return {}
    return {"start_new_session": True}


def _should_bootstrap_windows_powershell(*, shell_kind: str, env: dict[str, str]) -> bool:
    return (
        os.name == "nt"
        and shell_kind in {"pwsh", "powershell"}
        and _load_env_bool_from_mapping(env, _WINDOWS_FORCE_UTF8_ENV, True)
    )


def _wrap_windows_powershell_command(command: str) -> tuple[str, str]:
    wrapped = (
        "$utf8NoBom = [System.Text.UTF8Encoding]::new($false); "
        "[Console]::InputEncoding = $utf8NoBom; "
        "[Console]::OutputEncoding = $utf8NoBom; "
        "$OutputEncoding = $utf8NoBom; "
        "try { chcp.com 65001 > $null } catch {}; "
        f"& {{ {command} }}"
    )
    return wrapped, _WINDOWS_UTF8_BOOTSTRAP_MODE


def _decode_utf8_output(payload: bytes) -> tuple[str, bool]:
    if not payload:
        return "", False

    try:
        return payload.decode(_UTF8_ENCODING, errors="strict"), False
    except UnicodeDecodeError:
        return payload.decode(_UTF8_ENCODING, errors="replace"), True


async def _terminate_process_tree(proc: asyncio.subprocess.Process, *, grace_seconds: float) -> None:
    if proc.returncode is not None:
        return

    pgid: int | None = None
    if os.name != "nt":
        try:
            pgid = os.getpgid(proc.pid)
        except Exception:
            pgid = None

    if pgid is not None:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            return
        except Exception:
            try:
                proc.terminate()
            except ProcessLookupError:
                return
    else:
        try:
            proc.terminate()
        except ProcessLookupError:
            return

    try:
        await asyncio.wait_for(proc.wait(), timeout=max(0.1, float(grace_seconds)))
        return
    except asyncio.TimeoutError:
        pass

    if pgid is not None:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            return
        except Exception:
            try:
                proc.kill()
            except ProcessLookupError:
                return
    else:
        try:
            proc.kill()
        except ProcessLookupError:
            return

    try:
        await asyncio.wait_for(proc.wait(), timeout=1.0)
    except Exception:
        pass


_SHELL_KIND, _SHELL_ARGV_PREFIX, _SHELL_DISPLAY = _detect_shell_executor()
_SHELL_TOOL_DESCRIPTION = (
    "Run a shell command and return stdout/stderr. "
    "If `argv` is provided, the command is executed directly (no shell). "
    "If `command` is provided, it is executed via the runner shell (non-interactive). "
    "Prefer `argv` for portability."
)


class ShellOutlet:
    def outlet_runner_metadata(self) -> dict[str, Any]:
        return {
            "shell_kind": _SHELL_KIND,
            "shell_display": _SHELL_DISPLAY,
        }

    @outlet_tool(
        description=_SHELL_TOOL_DESCRIPTION,
        input_schema={
            "type": "object",
            "description": "Provide either `command` (shell string) or `argv` (array of strings). If both are set, `argv` takes precedence.",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Shell command to execute.",
                },
                "argv": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Command argv to execute without a shell (argv[0] is program).",
                },
                "cwd": {
                    "type": "string",
                    "description": "Working directory (optional).",
                },
                "env": {
                    "type": "object",
                    "description": "Environment variables (optional).",
                    "additionalProperties": {"type": "string"},
                },
                "stdin": {
                    "type": "string",
                    "description": "Standard input (optional).",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "description": "Command timeout in seconds (optional).",
                    "minimum": 0,
                },
            },
            "additionalProperties": False,
        },
    )
    async def run_command(
        self,
        command: str | None = None,
        argv: list[str] | None = None,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        stdin: str | None = None,
        timeout_seconds: int | None = None,
    ) -> tuple[str, dict[str, Any]]:
        if argv:
            argv = [str(item) for item in argv]
        if not argv and not command:
            raise ValueError("command or argv is required")

        command_display = shlex.join(argv) if argv else str(command or "")
        logger.info("Shell command: %s", command_display)

        merged_env = os.environ.copy()
        if env:
            merged_env.update({str(k): str(v) for k, v in env.items()})
        isolation_kwargs = _subprocess_isolation_kwargs()
        shell_encoding_bootstrap = ""

        if argv:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=cwd or None,
                env=merged_env,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                **isolation_kwargs,
            )
        else:
            shell_command = str(command or "")
            if _should_bootstrap_windows_powershell(shell_kind=_SHELL_KIND, env=merged_env):
                shell_command, shell_encoding_bootstrap = _wrap_windows_powershell_command(shell_command)

            executor_argv = [*_SHELL_ARGV_PREFIX, shell_command]
            proc = await asyncio.create_subprocess_exec(
                *executor_argv,
                cwd=cwd or None,
                env=merged_env,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                **isolation_kwargs,
            )

        timed_out = False
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(input=(stdin.encode("utf-8") if stdin else None)),
                timeout=None if not timeout_seconds or timeout_seconds <= 0 else float(timeout_seconds),
            )
        except asyncio.TimeoutError:
            timed_out = True
            await _terminate_process_tree(proc, grace_seconds=_TIMEOUT_TERMINATE_GRACE_SECONDS)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_DRAIN_SECONDS)
            except asyncio.TimeoutError:
                stdout = b""
                stderr = b"[timeout] command exceeded timeout and output drain window.\n"

        exit_code = proc.returncode
        if timed_out and exit_code is None:
            exit_code = -9
        stdout_text, stdout_decode_error = _decode_utf8_output(stdout)
        stderr_text, stderr_decode_error = _decode_utf8_output(stderr)

        max_stream_chars = _load_env_int("SHELL_OUTLET_MAX_STREAM_CHARS", _MAX_STREAM_CHARS_DEFAULT)
        max_summary_chars = _load_env_int("SHELL_OUTLET_MAX_SUMMARY_CHARS", _MAX_SUMMARY_CHARS_DEFAULT)

        stdout_text, stdout_truncated = _truncate_text(stdout_text, max_stream_chars)
        stderr_text, stderr_truncated = _truncate_text(stderr_text, max_stream_chars)

        summary = stdout_text
        if stderr_text:
            summary = (summary + "\n" + stderr_text).strip()
        summary = summary.strip()
        summary, summary_truncated = _truncate_text(summary, max_summary_chars)
        if timed_out:
            summary = _append_command_timeout_notice(summary, timeout_seconds)

        raw = {
            "argv": argv or [],
            "shell_kind": _SHELL_KIND if not argv else "",
            "shell_executor": _SHELL_ARGV_PREFIX[0] if (not argv and _SHELL_ARGV_PREFIX) else "",
            "shell_argv_prefix": _SHELL_ARGV_PREFIX if not argv else [],
            "shell_encoding_bootstrap": shell_encoding_bootstrap,
            "exit_code": exit_code,
            "stdout": stdout_text,
            "stderr": stderr_text,
            "stdout_encoding": _UTF8_ENCODING,
            "stderr_encoding": _UTF8_ENCODING,
            "stdout_decode_error": stdout_decode_error,
            "stderr_decode_error": stderr_decode_error,
            "timed_out": timed_out,
            "stdout_truncated": stdout_truncated,
            "stderr_truncated": stderr_truncated,
            "summary_truncated": summary_truncated,
            "stdout_bytes_total": len(stdout) if stdout else 0,
            "stderr_bytes_total": len(stderr) if stderr else 0,
        }
        return summary, raw

    @outlet_tool(
        description="Read an image file from the runner filesystem and attach it as media input.",
        input_schema={
            "type": "object",
            "properties": {
                "local_path": {
                    "type": "string",
                    "description": "Path to the image file on the runner filesystem.",
                }
            },
            "required": ["local_path"],
            "additionalProperties": False,
        },
    )
    async def read_image(self, local_path: str) -> dict[str, Any]:
        path = os.path.expanduser(str(local_path or "").strip())
        if not path:
            raise ValueError("local_path is required")
        if not os.path.exists(path):
            raise ValueError(f"File not found: {path}")
        if not os.path.isfile(path):
            raise ValueError(f"Not a file: {path}")

        with open(path, "rb") as f:
            data = f.read()

        mime_type = _detect_image_mime(data)
        if mime_type is None:
            raise ValueError("File content is not a valid image.")

        uploaded = await upload_call_file(filename=os.path.basename(path), mime_type=mime_type, payload=data)
        summary = f"Image {uploaded.get('file_external_id', '')} attached from {path}"

        return {
            "text": summary,
            "raw": {"path": path, "sha256": hashlib.sha256(data).hexdigest()},
            "media": [uploaded],
            "artifacts": [],
        }

    @outlet_tool(
        description="Download a chat file referenced by file_id into the runner filesystem.",
        input_schema={
            "type": "object",
            "properties": {
                "file_id": {
                    "type": "string",
                    "description": "File external UUID.",
                },
                "local_path": {
                    "type": "string",
                    "description": "Destination path on the runner filesystem.",
                },
            },
            "required": ["file_id", "local_path"],
            "additionalProperties": False,
        },
    )
    async def download_file(self, file_id: str, local_path: str) -> tuple[str, dict[str, Any]]:
        target_path = os.path.expanduser(str(local_path or "").strip())
        if not target_path:
            raise ValueError("local_path is required")
        file_id = str(file_id or "").strip()
        if not file_id:
            raise ValueError("file_id is required")

        payload, meta = await download_call_file(file_id=file_id)
        parent = os.path.dirname(target_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(target_path, "wb") as f:
            f.write(payload)

        return (
            f"File {file_id} downloaded to {target_path}",
            {
                "file_id": file_id,
                "path": target_path,
                "size_bytes": len(payload),
                "content_type": meta.get("content_type", "application/octet-stream"),
            },
        )

    @outlet_tool(
        description="Upload a runner filesystem file as a user-visible artifact.",
        input_schema={
            "type": "object",
            "properties": {
                "local_path": {
                    "type": "string",
                    "description": "Path to the file on the runner filesystem.",
                }
            },
            "required": ["local_path"],
            "additionalProperties": False,
        },
    )
    async def upload_file(self, local_path: str) -> dict[str, Any]:
        path = os.path.expanduser(str(local_path or "").strip())
        if not path:
            raise ValueError("local_path is required")
        if not os.path.exists(path):
            raise ValueError(f"File not found: {path}")
        if not os.path.isfile(path):
            raise ValueError(f"Not a file: {path}")

        with open(path, "rb") as f:
            data = f.read()

        mime_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
        uploaded = await upload_call_file(filename=os.path.basename(path), mime_type=mime_type, payload=data)

        return {
            "text": f"File {uploaded.get('file_external_id', '')} uploaded",
            "raw": {"path": path, "sha256": hashlib.sha256(data).hexdigest()},
            "media": [],
            "artifacts": [uploaded],
        }


def main() -> None:
    run_outlet(ShellOutlet, default_name="shell-outlet")


if __name__ == "__main__":
    main()
