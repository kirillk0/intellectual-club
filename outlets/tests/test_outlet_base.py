from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import outlets.outlet_base as outlet_base
from outlets.outlet_base import (
    OutletCallContext,
    OutletRunner,
    current_call_context,
    download_call_file,
    outlet_tool,
    upload_call_file,
)


class _PairingResponse:
    def __init__(self, payload: dict[str, object], status_code: int = 200) -> None:
        self._payload = payload
        self.status_code = status_code

    def json(self) -> dict[str, object]:
        return self._payload

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class OutletTokenConfigTest(unittest.TestCase):
    def test_save_token_to_file_does_not_persist_tool_instance_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "outlet.json"

            outlet_base._save_token_to_file(path, server_url="http://localhost:4000/", token="runner-token")

            payload = json.loads(path.read_text("utf-8"))

        self.assertEqual(payload["server_url"], "http://localhost:4000")
        self.assertEqual(payload["token"], "runner-token")
        self.assertIn("saved_at", payload)
        self.assertNotIn("tool_instance_id", payload)

    def test_pair_with_server_returns_token_and_ignores_tool_instance_id(self):
        manager = mock.MagicMock()
        client = mock.Mock()
        manager.__enter__.return_value = client
        manager.__exit__.return_value = False
        client.post.side_effect = [
            _PairingResponse(
                {
                    "status": "ok",
                    "device_code": "device-code",
                    "user_code": "ABCD-EFGH",
                    "verification_url": "http://localhost:4000/outlets/connect?code=ABCD-EFGH",
                    "interval": 0.5,
                    "expires_in": 30,
                }
            ),
            _PairingResponse(
                {
                    "status": "approved",
                    "token": "paired-token",
                    "tool_instance_id": 123,
                }
            ),
        ]

        with mock.patch("outlets.outlet_base.httpx.Client", return_value=manager), mock.patch(
            "outlets.outlet_base.webbrowser.open"
        ):
            token = outlet_base._pair_with_server(
                server_url="http://localhost:4000",
                default_name="shell-outlet",
                metadata={},
            )

        self.assertEqual(token, "paired-token")


class OutletRunnerCompleteRetryTest(unittest.IsolatedAsyncioTestCase):
    def _build_runner(self) -> OutletRunner:
        return OutletRunner(
            provider=object(),
            server_url="http://localhost:8002",
            token="test-token",
            runner_id="runner-a",
        )

    async def test_complete_retry_retries_on_network_error_then_succeeds(self):
        runner = self._build_runner()
        runner._mark_connected = mock.AsyncMock()  # type: ignore[method-assign]
        runner._mark_disconnected = mock.AsyncMock()  # type: ignore[method-assign]

        client = mock.AsyncMock()
        ok_response = mock.Mock(status_code=200, text="ok")
        client.post = mock.AsyncMock(side_effect=[RuntimeError("network"), ok_response])

        with mock.patch("outlets.outlet_base.asyncio.sleep", new=mock.AsyncMock()) as sleep_mock, mock.patch(
            "outlets.outlet_base.random.uniform",
            return_value=0.0,
        ):
            await runner._send_complete(
                client=client,
                call_id="call-1",
                status="done",
                result_text="ok",
                result_raw={"ok": True},
                result_media=[],
                result_artifacts=[],
                error_text="",
            )

        self.assertEqual(client.post.await_count, 2)
        sleep_mock.assert_awaited_once()
        runner._mark_connected.assert_awaited_once()
        runner._mark_disconnected.assert_awaited_once()

    async def test_complete_retry_stops_on_404(self):
        runner = self._build_runner()
        runner._mark_connected = mock.AsyncMock()  # type: ignore[method-assign]
        runner._mark_disconnected = mock.AsyncMock()  # type: ignore[method-assign]

        client = mock.AsyncMock()
        not_found_response = mock.Mock(status_code=404, text="not found")
        client.post = mock.AsyncMock(return_value=not_found_response)

        with mock.patch("outlets.outlet_base.asyncio.sleep", new=mock.AsyncMock()) as sleep_mock:
            await runner._send_complete(
                client=client,
                call_id="call-404",
                status="done",
                result_text="ok",
                result_raw={"ok": True},
                result_media=[],
                result_artifacts=[],
                error_text="",
            )

        self.assertEqual(client.post.await_count, 1)
        sleep_mock.assert_not_awaited()
        runner._mark_connected.assert_awaited_once()
        runner._mark_disconnected.assert_not_awaited()

    async def test_complete_retry_triggers_self_restart_after_max_retries(self):
        runner = self._build_runner()
        runner.complete_max_retries = 3
        runner.complete_max_seconds = 999.0
        runner._mark_connected = mock.AsyncMock()  # type: ignore[method-assign]
        runner._mark_disconnected = mock.AsyncMock()  # type: ignore[method-assign]
        runner._restart_process = mock.Mock(side_effect=SystemExit(0))  # type: ignore[method-assign]

        client = mock.AsyncMock()
        client.post = mock.AsyncMock(side_effect=RuntimeError("network"))

        with mock.patch("outlets.outlet_base.asyncio.sleep", new=mock.AsyncMock()) as sleep_mock, mock.patch(
            "outlets.outlet_base.random.uniform",
            return_value=0.0,
        ):
            with self.assertRaises(SystemExit):
                await runner._send_complete(
                    client=client,
                    call_id="call-restart",
                    status="done",
                    result_text="ok",
                    result_raw={"ok": True},
                    result_media=[],
                    result_artifacts=[],
                    error_text="",
                )

        self.assertEqual(client.post.await_count, 3)
        self.assertEqual(sleep_mock.await_count, 2)
        runner._restart_process.assert_called_once()


class _MetadataProvider:
    def outlet_runner_metadata(self) -> dict[str, object]:
        return {
            "shell_kind": "bash",
            "shell_display": "/bin/bash -c",
        }


class OutletRunnerMetadataTest(unittest.TestCase):
    def test_runner_metadata_merges_base_and_provider_metadata(self):
        metadata = outlet_base._runner_metadata(_MetadataProvider())

        self.assertIn("hostname", metadata)
        self.assertIn("platform", metadata)
        self.assertIn("sys_platform", metadata)
        self.assertEqual(metadata["shell_kind"], "bash")
        self.assertEqual(metadata["shell_display"], "/bin/bash -c")


class _ContextAwareProvider:
    @outlet_tool(name="context_tool")
    async def context_tool(self) -> dict[str, object]:
        context = current_call_context()
        assert context is not None
        return {
            "text": context.call_id,
            "raw": {"call_id": context.call_id},
            "media": [{"file_id": 1, "filename": "image.png"}],
            "artifacts": [{"file_id": 2, "filename": "artifact.txt"}],
        }


class OutletRunnerCallContextTest(unittest.IsolatedAsyncioTestCase):
    async def test_handle_call_provides_context_and_forwards_media_artifacts(self):
        runner = OutletRunner(
            provider=_ContextAwareProvider(),
            server_url="http://localhost:8002",
            token="test-token",
            runner_id="runner-a",
        )
        runner._send_complete = mock.AsyncMock()  # type: ignore[method-assign]

        client = mock.AsyncMock()
        await runner._handle_call(client, "call-ctx", "context_tool", {})

        runner._send_complete.assert_awaited_once()
        kwargs = runner._send_complete.await_args.kwargs
        self.assertEqual(kwargs["call_id"], "call-ctx")
        self.assertEqual(kwargs["result_text"], "call-ctx")
        self.assertEqual(kwargs["result_raw"], {"call_id": "call-ctx"})
        self.assertEqual(kwargs["result_media"], [{"file_id": 1, "filename": "image.png"}])
        self.assertEqual(kwargs["result_artifacts"], [{"file_id": 2, "filename": "artifact.txt"}])


class OutletFileHelpersTest(unittest.IsolatedAsyncioTestCase):
    async def test_upload_call_file_sends_unicode_filename_in_query_params(self):
        response = mock.Mock()
        response.raise_for_status = mock.Mock()
        response.json = mock.Mock(
            return_value={
                "file": {
                    "file_id": 5,
                    "file_external_id": "file-123",
                    "filename": "привет.txt",
                }
            }
        )

        client = mock.AsyncMock()
        client.post = mock.AsyncMock(return_value=response)

        client_manager = mock.AsyncMock()
        client_manager.__aenter__.return_value = client
        client_manager.__aexit__.return_value = False

        token = outlet_base._CALL_CONTEXT.set(
            OutletCallContext(
                call_id="call-123",
                server_url="http://localhost:8002",
                token="runner-token",
            )
        )

        try:
            with mock.patch("outlets.outlet_base.httpx.AsyncClient", return_value=client_manager):
                result = await upload_call_file(
                    filename="привет.txt",
                    mime_type="text/plain",
                    payload=b"hello",
                )
        finally:
            outlet_base._CALL_CONTEXT.reset(token)

        client.post.assert_awaited_once()
        self.assertEqual(
            client.post.await_args.args,
            ("http://localhost:8002/api/outlet/calls/call-123/files",),
        )
        kwargs = client.post.await_args.kwargs
        self.assertEqual(kwargs["content"], b"hello")
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer runner-token")
        self.assertEqual(kwargs["headers"]["Content-Type"], "text/plain")
        self.assertNotIn("X-Filename", kwargs["headers"])
        self.assertEqual(kwargs["params"], {"filename": "привет.txt"})
        self.assertEqual(result["file_external_id"], "file-123")

    async def test_download_call_file_uses_file_route(self):
        response = mock.Mock()
        response.content = b"payload"
        response.headers = {
            "content-type": "application/octet-stream",
            "content-disposition": 'attachment; filename="artifact.txt"',
        }
        response.raise_for_status = mock.Mock()

        client = mock.AsyncMock()
        client.get = mock.AsyncMock(return_value=response)

        client_manager = mock.AsyncMock()
        client_manager.__aenter__.return_value = client
        client_manager.__aexit__.return_value = False

        token = outlet_base._CALL_CONTEXT.set(
            OutletCallContext(
                call_id="call-123",
                server_url="http://localhost:8002",
                token="runner-token",
            )
        )

        try:
            with mock.patch("outlets.outlet_base.httpx.AsyncClient", return_value=client_manager):
                payload, meta = await download_call_file(file_id="file-123")
        finally:
            outlet_base._CALL_CONTEXT.reset(token)

        client.get.assert_awaited_once_with(
            "http://localhost:8002/api/outlet/calls/call-123/files/file-123",
            headers={"Authorization": "Bearer runner-token"},
        )
        self.assertEqual(payload, b"payload")
        self.assertEqual(meta["content_type"], "application/octet-stream")
        self.assertEqual(meta["content_disposition"], 'attachment; filename="artifact.txt"')
