from __future__ import annotations

import argparse
import asyncio
import contextvars
import inspect
import json
import logging
import os
import pathlib
import random
import socket
import subprocess
import sys
import time
import traceback
import uuid
import webbrowser
from dataclasses import dataclass
from types import UnionType
from typing import Any, Callable, Mapping, get_args, get_origin, Union

import httpx

DISCOVERY_FUNCTION = "outlet.list_tools"
logger = logging.getLogger(__name__)
_CALL_CONTEXT: contextvars.ContextVar["OutletCallContext | None"] = contextvars.ContextVar("outlet_call_context", default=None)


@dataclass(frozen=True, slots=True)
class OutletToolSpec:
    name: str
    description: str
    input_schema: dict[str, Any]


@dataclass(frozen=True, slots=True)
class OutletTool:
    spec: OutletToolSpec
    handler: Callable[..., Any]
    is_async: bool


@dataclass(frozen=True, slots=True)
class OutletCallContext:
    call_id: str
    server_url: str
    token: str


def outlet_tool(*, name: str | None = None, description: str | None = None, input_schema: dict[str, Any] | None = None):
    def decorator(func):
        setattr(
            func,
            "_outlet_tool",
            {
                "name": name,
                "description": description,
                "input_schema": input_schema,
            },
        )
        return func

    return decorator


def _safe_json(obj: Any) -> Any:
    try:
        json.dumps(obj)
        return obj
    except Exception:
        return str(obj)


def _to_one_line(text: Any) -> str:
    return " ".join(str(text).split())


def _truncate_one_line(text: Any, max_len: int) -> str:
    text_one_line = _to_one_line(text)
    if len(text_one_line) <= max_len:
        return text_one_line
    if max_len <= 3:
        return text_one_line[:max_len]
    return text_one_line[: max_len - 3] + "..."


def _format_exception(exc: BaseException) -> str:
    """
    Produce a stable, one-line error summary for logs.

    `httpx` exceptions often have an empty `str(exc)` (e.g., ReadError), so we
    include repr() and request context when available.
    """

    name = exc.__class__.__name__
    try:
        msg = str(exc).strip()
    except Exception:
        msg = ""

    try:
        rep = repr(exc)
    except Exception:
        rep = ""

    if msg:
        base = f"{name}: {msg}"
    elif rep:
        base = f"{name}: {rep}"
    else:
        base = name

    req = getattr(exc, "request", None)
    if req is not None:
        try:
            method = getattr(req, "method", "")
            url = getattr(req, "url", "")
            if method or url:
                base = f"{base} (request={method} {url})".strip()
        except Exception:
            pass

    cause = getattr(exc, "__cause__", None) or getattr(exc, "__context__", None)
    if cause is not None and cause is not exc:
        try:
            base = f"{base} (cause={cause.__class__.__name__}: {repr(cause)})"
        except Exception:
            base = f"{base} (cause={cause.__class__.__name__})"

    return _truncate_one_line(base, 300)


def _format_kv(**fields: Any) -> str:
    parts: list[str] = []
    for key, value in fields.items():
        if value is None:
            continue
        value_str = _to_one_line(value)
        if not value_str:
            continue
        if any(ch.isspace() for ch in value_str) or any(ch in value_str for ch in ['"', "'", "="]):
            value_str = json.dumps(value_str, ensure_ascii=False)
        parts.append(f"{key}={value_str}")
    return " ".join(parts)


def _configure_logging(level_name: str) -> None:
    level = getattr(logging, str(level_name or "INFO").upper(), logging.INFO)
    root = logging.getLogger()
    if not root.handlers:
        logging.basicConfig(
            level=level,
            format="%(asctime)s %(levelname)s %(message)s",
        )
    else:
        root.setLevel(level)

    noisy_http_level = logging.DEBUG if level <= logging.DEBUG else logging.WARNING
    for logger_name in ("httpx", "httpcore"):
        logging.getLogger(logger_name).setLevel(noisy_http_level)


def _annotation_to_schema(annotation: Any) -> dict[str, Any]:
    if annotation is None or annotation is inspect.Signature.empty:
        return {"type": "string"}

    origin = get_origin(annotation)
    args = get_args(annotation)

    if origin is None:
        if annotation in (str,):
            return {"type": "string"}
        if annotation in (int,):
            return {"type": "integer"}
        if annotation in (float,):
            return {"type": "number"}
        if annotation in (bool,):
            return {"type": "boolean"}
        if annotation in (dict,):
            return {"type": "object"}
        if annotation in (list, tuple, set):
            return {"type": "array"}
        return {"type": "string"}

    if origin in (list, tuple, set):
        items_schema = _annotation_to_schema(args[0]) if args else {"type": "string"}
        return {"type": "array", "items": items_schema}

    if origin is dict:
        value_schema = _annotation_to_schema(args[1]) if len(args) > 1 else {"type": "string"}
        return {"type": "object", "additionalProperties": value_schema}

    if origin is type(None):
        return {"type": "null"}

    if origin is None or origin is object:
        return {"type": "string"}

    if origin in (Union, UnionType):
        non_null = [a for a in args if a is not type(None)]
        if len(non_null) == 1:
            schema = _annotation_to_schema(non_null[0])
            existing_type = schema.get("type")
            if isinstance(existing_type, list):
                if "null" not in existing_type:
                    existing_type.append("null")
                schema["type"] = existing_type
            elif isinstance(existing_type, str):
                schema["type"] = [existing_type, "null"]
            else:
                schema["type"] = ["string", "null"]
            return schema
        return {"type": "string"}

    return {"type": "string"}


def _signature_to_schema(fn: Callable[..., Any]) -> dict[str, Any]:
    sig = inspect.signature(fn)
    properties: dict[str, Any] = {}
    required: list[str] = []

    for name, param in sig.parameters.items():
        if name == "self":
            continue
        if param.kind in (inspect.Parameter.VAR_POSITIONAL, inspect.Parameter.VAR_KEYWORD):
            continue

        schema = _annotation_to_schema(param.annotation)
        properties[name] = schema

        is_required = param.default is inspect.Signature.empty
        if is_required:
            required.append(name)

    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
    }
    if required:
        schema["required"] = required
    return schema


def _build_tool_list(provider: Any) -> list[OutletTool]:
    methods = []
    decorated = False

    for name, member in inspect.getmembers(provider, predicate=callable):
        if name.startswith("_"):
            continue
        meta = getattr(member, "_outlet_tool", None)
        if meta is None and hasattr(member, "__func__"):
            meta = getattr(member.__func__, "_outlet_tool", None)
        if meta is not None:
            decorated = True
            methods.append((name, member, meta))
        else:
            methods.append((name, member, None))

    tools: list[OutletTool] = []
    for name, member, meta in methods:
        if decorated and meta is None:
            continue

        tool_name = name
        description = ""
        input_schema = None
        if isinstance(meta, dict):
            if meta.get("name"):
                tool_name = str(meta["name"])
            if meta.get("description"):
                description = str(meta["description"])
            if isinstance(meta.get("input_schema"), dict):
                input_schema = meta["input_schema"]

        if not description:
            description = inspect.getdoc(member) or ""
        if input_schema is None:
            input_schema = _signature_to_schema(member)

        tools.append(
            OutletTool(
                spec=OutletToolSpec(name=tool_name, description=description, input_schema=input_schema),
                handler=member,
                is_async=asyncio.iscoroutinefunction(member),
            )
        )

    return tools


def _normalize_result(result: Any) -> dict[str, Any]:
    if isinstance(result, dict):
        if any(key in result for key in ("text", "raw", "media", "artifacts")):
            return {
                "text": "" if result.get("text") is None else str(result.get("text")),
                "raw": _safe_json(result.get("raw", {})),
                "media": [item for item in list(result.get("media") or []) if isinstance(item, dict)],
                "artifacts": [item for item in list(result.get("artifacts") or []) if isinstance(item, dict)],
            }
        return {"text": json.dumps(_safe_json(result), ensure_ascii=False), "raw": result, "media": [], "artifacts": []}
    if isinstance(result, tuple) and len(result) == 4:
        text = "" if result[0] is None else str(result[0])
        raw = _safe_json(result[1])
        media = [item for item in list(result[2] or []) if isinstance(item, dict)]
        artifacts = [item for item in list(result[3] or []) if isinstance(item, dict)]
        return {"text": text, "raw": raw, "media": media, "artifacts": artifacts}
    if isinstance(result, tuple) and len(result) == 2:
        text = "" if result[0] is None else str(result[0])
        return {"text": text, "raw": _safe_json(result[1]), "media": [], "artifacts": []}
    if isinstance(result, str):
        return {"text": result, "raw": {"result": result}, "media": [], "artifacts": []}
    if result is None:
        return {"text": "", "raw": {}, "media": [], "artifacts": []}
    return {"text": str(result), "raw": {"result": _safe_json(result)}, "media": [], "artifacts": []}


def _join_url(base: str, path: str) -> str:
    return base.rstrip("/") + "/" + path.lstrip("/")


def current_call_context() -> OutletCallContext | None:
    return _CALL_CONTEXT.get()


def require_call_context() -> OutletCallContext:
    context = current_call_context()
    if context is None:
        raise RuntimeError("Outlet call context is unavailable.")
    return context


async def upload_call_file(*, filename: str, mime_type: str, payload: bytes) -> dict[str, Any]:
    context = require_call_context()
    url = _join_url(context.server_url, f"/api/outlet/calls/{context.call_id}/files")
    headers = {
        "Authorization": f"Bearer {context.token}",
        "Content-Type": str(mime_type or "application/octet-stream"),
        "X-Filename": str(filename or "file.bin"),
    }
    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
        response = await client.post(url, content=payload, headers=headers)
        response.raise_for_status()
        data = response.json()
        file_data = data.get("file")
        if not isinstance(file_data, dict):
            raise RuntimeError("Outlet file upload response is invalid.")
        return file_data


async def download_call_file(*, content_id: str) -> tuple[bytes, dict[str, Any]]:
    context = require_call_context()
    url = _join_url(context.server_url, f"/api/outlet/calls/{context.call_id}/contents/{content_id}/file")
    headers = {"Authorization": f"Bearer {context.token}"}
    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        meta = {
            "content_type": response.headers.get("content-type", "application/octet-stream"),
            "content_disposition": response.headers.get("content-disposition", ""),
        }
        return bytes(response.content), meta


def _load_env_bool(key: str, default: bool) -> bool:
    raw = os.getenv(key)
    if raw is None:
        return bool(default)
    raw = str(raw).strip().lower()
    if raw in {"1", "true", "yes", "y", "on"}:
        return True
    if raw in {"0", "false", "no", "n", "off"}:
        return False
    return bool(default)


def _safe_filename(value: str) -> str:
    value = str(value or "").strip()
    if not value:
        return "outlet"
    cleaned = []
    for ch in value:
        if ch.isalnum() or ch in {"-", "_", "."}:
            cleaned.append(ch)
        else:
            cleaned.append("_")
    return "".join(cleaned)[:80] or "outlet"


def _default_config_dir() -> pathlib.Path:
    home = pathlib.Path(os.path.expanduser("~"))
    return home / ".config" / "intellectual-club" / "outlets"


def _resolve_token_file(*, default_name: str, token_file: str, config_dir: str) -> pathlib.Path:
    if token_file:
        return pathlib.Path(os.path.expanduser(token_file)).resolve()
    if config_dir:
        base = pathlib.Path(os.path.expanduser(config_dir))
    else:
        base = _default_config_dir()
    return (base / f"{_safe_filename(default_name)}.json").resolve()


def _load_token_from_file(path: pathlib.Path, *, server_url: str) -> str:
    try:
        if not path.exists():
            return ""
        raw = path.read_text("utf-8")
        data = json.loads(raw)
        if not isinstance(data, dict):
            return ""
        stored_url = str(data.get("server_url") or "").strip().rstrip("/")
        if stored_url and stored_url != str(server_url or "").strip().rstrip("/"):
            return ""
        token = str(data.get("token") or "").strip()
        return token
    except Exception:
        return ""


def _save_token_to_file(path: pathlib.Path, *, server_url: str, token: str, tool_instance_id: Any | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "server_url": str(server_url or "").strip().rstrip("/"),
        "token": str(token or "").strip(),
        "tool_instance_id": tool_instance_id,
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except Exception:
        pass


def _pair_with_server(*, server_url: str, default_name: str, metadata: dict[str, Any]) -> tuple[str, Any | None]:
    start_url = _join_url(server_url, "/api/outlet/pair/start/")
    poll_url = _join_url(server_url, "/api/outlet/pair/poll/")

    with httpx.Client(timeout=httpx.Timeout(10.0)) as client:
        resp = client.post(
            start_url,
            json={
                "runner_kind": default_name,
                "metadata": metadata,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, dict) or data.get("status") != "ok":
            raise RuntimeError("Pairing start failed.")

        device_code = str(data.get("device_code") or "").strip()
        user_code = str(data.get("user_code") or "").strip()
        verification_url = str(data.get("verification_url") or "").strip()
        interval = float(data.get("interval") or 2.0)
        expires_in = float(data.get("expires_in") or 900.0)
        if not device_code or not user_code or not verification_url:
            raise RuntimeError("Pairing start response is missing fields.")

        print("Outlet token is not set. Starting browser authorization flow.", file=sys.stderr)
        print(f"Open: {verification_url}", file=sys.stderr)
        print(f"Code: {user_code}", file=sys.stderr)
        try:
            webbrowser.open(verification_url)
        except Exception:
            pass

        deadline = time.monotonic() + max(1.0, expires_in)
        while time.monotonic() < deadline:
            poll = client.post(poll_url, json={"device_code": device_code})
            if poll.status_code == 200:
                payload = poll.json()
                if isinstance(payload, dict):
                    status = str(payload.get("status") or "")
                    if status == "approved":
                        token = str(payload.get("token") or "").strip()
                        tool_instance_id = payload.get("tool_instance_id")
                        if token:
                            return token, tool_instance_id
                    if status == "consumed":
                        raise RuntimeError("Pairing token already consumed. Please restart pairing.")
            time.sleep(max(0.5, interval))

    raise RuntimeError("Pairing timed out. Please retry.")


class OutletRunner:
    def __init__(
        self,
        *,
        provider: Any,
        server_url: str,
        token: str,
        runner_id: str | None = None,
        max_concurrency: int = 20,
        poll_max_wait_seconds: float = 25.0,
        poll_check_interval_seconds: float = 1.0,
        poll_endpoint: str = "/api/outlet/poll/",
        complete_endpoint: str = "/api/outlet/complete/",
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.server_url = server_url.rstrip("/")
        self.token = token.strip()
        self.runner_id = runner_id or uuid.uuid4().hex
        self.runner_session_id = uuid.uuid4().hex
        self.max_concurrency = max(1, int(max_concurrency))
        self.poll_max_wait_seconds = float(poll_max_wait_seconds)
        self.poll_check_interval_seconds = float(poll_check_interval_seconds)
        self.poll_endpoint = poll_endpoint
        self.complete_endpoint = complete_endpoint
        self.metadata = metadata or {
            "hostname": socket.gethostname(),
            "pid": os.getpid(),
        }

        tools = _build_tool_list(provider)
        self._tool_map: dict[str, OutletTool] = {tool.spec.name: tool for tool in tools}
        self._provider = provider
        self._running: set[str] = set()
        self._running_lock = asyncio.Lock()
        self._connection_state_lock = asyncio.Lock()
        self._connected = False
        self._last_connection_error_log_at = 0.0
        self._connection_error_log_interval_seconds = 30.0
        self.complete_max_retries = max(1, _load_env_int("OUTLET_COMPLETE_MAX_RETRIES", 100))
        self.complete_max_seconds = max(1.0, _load_env_float("OUTLET_COMPLETE_MAX_SECONDS", 300.0))
        self._restart_lock = asyncio.Lock()
        self._restart_requested = False

    def _capacity(self) -> int:
        return max(0, self.max_concurrency - len(self._running))

    async def _track_start(self, call_id: str) -> None:
        async with self._running_lock:
            self._running.add(call_id)

    async def _track_end(self, call_id: str) -> None:
        async with self._running_lock:
            self._running.discard(call_id)

    async def _mark_connected(self) -> None:
        async with self._connection_state_lock:
            if self._connected:
                return
            self._connected = True
        logger.info("Connection established %s", _format_kv(server_url=self.server_url, runner_id=self.runner_id))

    async def _mark_disconnected(self, *, reason: str) -> None:
        now = time.monotonic()

        async with self._connection_state_lock:
            if self._connected:
                self._connected = False
                log_kind = "outlet.disconnected"
                should_log = True
            else:
                log_kind = "outlet.connection_error"
                should_log = (now - self._last_connection_error_log_at) >= self._connection_error_log_interval_seconds
                if should_log:
                    self._last_connection_error_log_at = now

        if should_log:
            logger.warning(
                "%s %s",
                "Connection lost" if log_kind == "outlet.disconnected" else "Connection error",
                _format_kv(
                    server_url=self.server_url,
                    runner_id=self.runner_id,
                    reason=_truncate_one_line(reason, 200),
                ),
            )

    async def serve(self) -> None:
        async with httpx.AsyncClient() as client:
            while True:
                try:
                    await self._poll_once(client)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    reason = _format_exception(exc)
                    await self._mark_disconnected(reason=reason)
                    await asyncio.sleep(2.0)

    async def _poll_once(self, client: httpx.AsyncClient) -> None:
        capacity = self._capacity()
        payload = {
            "runner_id": self.runner_id,
            "runner_session_id": self.runner_session_id,
            "capacity": capacity,
            "max_wait_seconds": self.poll_max_wait_seconds,
            "metadata": self.metadata,
        }
        headers = {"Authorization": f"Bearer {self.token}"}
        url = _join_url(self.server_url, self.poll_endpoint)
        timeout = httpx.Timeout(connect=10.0, read=self.poll_max_wait_seconds + 15.0, write=10.0, pool=None)

        response = await client.post(url, json=payload, headers=headers, timeout=timeout)
        if response.status_code == 401:
            raise RuntimeError("Unauthorized. Check outlet token.")
        if response.status_code == 409:
            raise RuntimeError("Runner already active.")
        if response.status_code >= 400:
            raise RuntimeError(f"Poll failed: {response.status_code}")

        data = response.json()
        await self._mark_connected()
        tasks = data.get("tasks")
        if not isinstance(tasks, list):
            return

        for task in tasks:
            if not isinstance(task, dict):
                continue
            call_id = str(task.get("call_id") or "")
            function_name = str(task.get("function") or "")
            if not call_id or not function_name:
                continue
            asyncio.create_task(self._handle_call(client, call_id, function_name, task.get("arguments")))

    async def _handle_call(self, client: httpx.AsyncClient, call_id: str, function_name: str, args: Any) -> None:
        await self._track_start(call_id)
        started_at = time.monotonic()
        status = "done"
        result_text = ""
        result_raw: Any = {}
        result_media: list[dict[str, Any]] = []
        result_artifacts: list[dict[str, Any]] = []
        error_text = ""
        error_type = ""
        token = _CALL_CONTEXT.set(OutletCallContext(call_id=call_id, server_url=self.server_url, token=self.token))

        try:
            if function_name == DISCOVERY_FUNCTION:
                tools_payload = [
                    {
                        "name": tool.spec.name,
                        "description": tool.spec.description,
                        "input_schema": tool.spec.input_schema,
                    }
                    for tool in self._tool_map.values()
                ]
                normalized = _normalize_result({"tools": tools_payload})
            else:
                tool = self._tool_map.get(function_name)
                if tool is None:
                    raise RuntimeError(f"Unknown tool: {function_name}")

                arguments = args if isinstance(args, Mapping) else {}
                if tool.is_async:
                    result = await tool.handler(**arguments)
                else:
                    result = await asyncio.to_thread(tool.handler, **arguments)
                normalized = _normalize_result(result)

            result_text = normalized["text"]
            result_raw = normalized["raw"]
            result_media = normalized["media"]
            result_artifacts = normalized["artifacts"]
        except Exception as exc:
            status = "error"
            error_text = str(exc) or exc.__class__.__name__
            error_type = exc.__class__.__name__
            result_raw = {
                "error": error_text,
                "traceback": traceback.format_exc(),
            }
        finally:
            _CALL_CONTEXT.reset(token)
            await self._send_complete(
                client=client,
                call_id=call_id,
                status=status,
                result_text=result_text,
                result_raw=result_raw,
                result_media=result_media,
                result_artifacts=result_artifacts,
                error_text=error_text,
            )
            duration_ms = int((time.monotonic() - started_at) * 1000)
            if function_name == DISCOVERY_FUNCTION:
                logger.info(
                    "Function called: %s %s",
                    function_name,
                    _format_kv(
                        call_id=call_id,
                        status=status,
                        duration_ms=duration_ms,
                        error_type=error_type if error_type else None,
                    ),
                )
            await self._track_end(call_id)

    async def _send_complete(
        self,
        *,
        client: httpx.AsyncClient,
        call_id: str,
        status: str,
        result_text: str,
        result_raw: Any,
        result_media: list[dict[str, Any]],
        result_artifacts: list[dict[str, Any]],
        error_text: str,
    ) -> None:
        payload = {
            "runner_id": self.runner_id,
            "runner_session_id": self.runner_session_id,
            "call_id": call_id,
            "status": status,
            "result_text": result_text,
            "result_raw": _safe_json(result_raw),
            "result_media": _safe_json(result_media),
            "result_artifacts": _safe_json(result_artifacts),
            "error_text": error_text,
            "metadata": self.metadata,
        }
        headers = {"Authorization": f"Bearer {self.token}"}
        url = _join_url(self.server_url, self.complete_endpoint)

        attempt = 0
        started_at = time.monotonic()
        backoff_seconds = 0.5
        max_backoff_seconds = 10.0
        last_retry_log_at = 0.0

        while True:
            attempt += 1
            try:
                response = await client.post(url, json=payload, headers=headers, timeout=httpx.Timeout(10.0))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                reason = _format_exception(exc)
                await self._mark_disconnected(reason=reason)
                await self._maybe_self_restart_after_complete_failure(
                    call_id=call_id,
                    attempt=attempt,
                    started_at=started_at,
                    last_reason=reason,
                    last_status_code=None,
                )
                now = time.monotonic()
                if attempt == 1 or (now - last_retry_log_at) >= 30.0:
                    last_retry_log_at = now
                    logger.warning(
                        "Completion delivery retry %s",
                        _format_kv(
                            server_url=self.server_url,
                            runner_id=self.runner_id,
                            runner_session_id=self.runner_session_id,
                            call_id=call_id,
                            attempt=attempt,
                            reason=_truncate_one_line(reason, 200),
                        ),
                    )
            else:
                if 200 <= response.status_code < 300:
                    await self._mark_connected()
                    return

                if response.status_code == 404:
                    await self._mark_connected()
                    logger.info(
                        "Completion dropped %s",
                        _format_kv(
                            server_url=self.server_url,
                            runner_id=self.runner_id,
                            runner_session_id=self.runner_session_id,
                            call_id=call_id,
                            status_code=response.status_code,
                        ),
                    )
                    return

                body_preview = _truncate_one_line(response.text, 200)
                reason = f"HTTP {response.status_code}"
                if body_preview:
                    reason = f"{reason}: {body_preview}"
                await self._mark_disconnected(reason=reason)
                await self._maybe_self_restart_after_complete_failure(
                    call_id=call_id,
                    attempt=attempt,
                    started_at=started_at,
                    last_reason=reason,
                    last_status_code=response.status_code,
                )
                now = time.monotonic()
                if attempt == 1 or (now - last_retry_log_at) >= 30.0:
                    last_retry_log_at = now
                    logger.warning(
                        "Completion delivery retry %s",
                        _format_kv(
                            server_url=self.server_url,
                            runner_id=self.runner_id,
                            runner_session_id=self.runner_session_id,
                            call_id=call_id,
                            attempt=attempt,
                            status_code=response.status_code,
                        ),
                    )

            sleep_seconds = backoff_seconds + random.uniform(0.0, min(1.0, backoff_seconds))
            await asyncio.sleep(sleep_seconds)
            backoff_seconds = min(max_backoff_seconds, backoff_seconds * 2.0)

    async def _maybe_self_restart_after_complete_failure(
        self,
        *,
        call_id: str,
        attempt: int,
        started_at: float,
        last_reason: str,
        last_status_code: int | None,
    ) -> None:
        elapsed_seconds = max(0.0, time.monotonic() - started_at)
        should_restart = attempt >= int(self.complete_max_retries) or elapsed_seconds >= float(self.complete_max_seconds)
        if not should_restart:
            return

        async with self._restart_lock:
            if self._restart_requested:
                return
            self._restart_requested = True

        logger.error(
            "Outlet self-restart requested %s",
            _format_kv(
                server_url=self.server_url,
                runner_id=self.runner_id,
                runner_session_id=self.runner_session_id,
                call_id=call_id,
                attempt=attempt,
                elapsed_seconds=f"{elapsed_seconds:.3f}",
                max_retries=self.complete_max_retries,
                max_seconds=self.complete_max_seconds,
                status_code=last_status_code,
                reason=_truncate_one_line(last_reason, 200),
            ),
        )

        self._restart_process(reason=last_reason)

        # `exec*` should not return. If it does, crash to avoid a stuck runner.
        raise RuntimeError("Outlet self-restart failed: exec returned unexpectedly.")

    def _build_restart_argv(self) -> list[str]:
        exe = (sys.executable or "").strip()
        if not exe:
            exe = "python3"

        main = sys.modules.get("__main__")
        spec = getattr(main, "__spec__", None) if main is not None else None
        module_name = getattr(spec, "name", None) if spec is not None else None

        # Prefer `python -m package.module` to keep import paths stable.
        if isinstance(module_name, str) and module_name and module_name != "__main__":
            return [exe, "-m", module_name, *sys.argv[1:]]

        script = sys.argv[0] if sys.argv else ""
        if script:
            return [exe, script, *sys.argv[1:]]

        return [exe]

    def _restart_process(self, *, reason: str) -> None:
        argv = self._build_restart_argv()
        cmd_preview = _truncate_one_line(" ".join(argv), 500)
        logger.error(
            "Restarting outlet process via exec %s",
            _format_kv(reason=_truncate_one_line(reason, 200), argv=cmd_preview),
        )

        try:
            logging.shutdown()
        except Exception:
            pass

        try:
            self._execv(argv)
        except Exception as exc:
            logger.error(
                "Outlet exec restart failed %s",
                _format_kv(error=_format_exception(exc)),
            )

            # Fallback: spawn a child process and exit. This is a last resort for
            # cases where `exec*` fails (should be rare).
            try:
                self._spawn(argv)
            except Exception as spawn_exc:
                logger.error(
                    "Outlet spawn restart failed %s",
                    _format_kv(error=_format_exception(spawn_exc)),
                )
                raise

            self._exit(0)

    def _execv(self, argv: list[str]) -> None:
        os.execvp(argv[0], argv)

    def _spawn(self, argv: list[str]) -> None:
        subprocess.Popen(argv, close_fds=True)

    def _exit(self, code: int) -> None:
        os._exit(int(code))

def _load_env_int(key: str, default: int) -> int:
    raw = os.getenv(key)
    if raw is None:
        return int(default)
    try:
        return int(raw)
    except ValueError:
        return int(default)


def _load_env_float(key: str, default: float) -> float:
    raw = os.getenv(key)
    if raw is None:
        return float(default)
    try:
        return float(raw)
    except ValueError:
        return float(default)


def run_outlet(provider_factory: Callable[[], Any], *, default_name: str) -> None:
    parser = argparse.ArgumentParser(prog=default_name)
    parser.add_argument("--server-url", default=os.getenv("OUTLET_SERVER_URL", ""))
    parser.add_argument("--token", default=os.getenv("OUTLET_TOKEN", ""))
    parser.add_argument("--token-file", default=os.getenv("OUTLET_TOKEN_FILE", ""))
    parser.add_argument("--config-dir", default=os.getenv("OUTLET_CONFIG_DIR", ""))
    parser.add_argument("--no-pairing", action="store_true", default=_load_env_bool("OUTLET_NO_PAIRING", False))
    parser.add_argument("--runner-id", default=os.getenv("OUTLET_RUNNER_ID", ""))
    parser.add_argument("--log-level", default=os.getenv("OUTLET_LOG_LEVEL", "INFO"))
    parser.add_argument("--max-concurrency", type=int, default=_load_env_int("OUTLET_MAX_CONCURRENCY", 20))
    parser.add_argument(
        "--poll-max-wait",
        type=float,
        default=_load_env_float("OUTLET_POLL_MAX_WAIT_SECONDS", 25.0),
    )
    parser.add_argument(
        "--poll-check-interval",
        type=float,
        default=_load_env_float("OUTLET_POLL_CHECK_INTERVAL_SECONDS", 1.0),
    )
    args = parser.parse_args()
    _configure_logging(str(args.log_level))

    server_url = (args.server_url or "").strip()
    token = (args.token or "").strip()
    if not server_url:
        print("--server-url is required.", file=sys.stderr)
        sys.exit(2)

    token_path = _resolve_token_file(default_name=default_name, token_file=str(args.token_file or ""), config_dir=str(args.config_dir or ""))
    if not token:
        token = _load_token_from_file(token_path, server_url=server_url)

    tool_instance_id = None
    if not token and not bool(args.no_pairing):
        try:
            token, tool_instance_id = _pair_with_server(server_url=server_url, default_name=default_name, metadata={"hostname": socket.gethostname(), "pid": os.getpid()})
            _save_token_to_file(token_path, server_url=server_url, token=token, tool_instance_id=tool_instance_id)
            print(f"Outlet token saved to: {token_path}", file=sys.stderr)
        except Exception as exc:
            print(f"Failed to authorize outlet: {exc}", file=sys.stderr)
            sys.exit(2)

    if not token:
        print("Outlet token is required. Set OUTLET_TOKEN or run pairing flow.", file=sys.stderr)
        sys.exit(2)

    provider = provider_factory()
    runner = OutletRunner(
        provider=provider,
        server_url=server_url,
        token=token,
        runner_id=(args.runner_id or None),
        max_concurrency=int(args.max_concurrency),
        poll_max_wait_seconds=float(args.poll_max_wait),
        poll_check_interval_seconds=float(args.poll_check_interval),
    )

    asyncio.run(runner.serve())
