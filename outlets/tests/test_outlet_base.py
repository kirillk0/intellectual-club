from __future__ import annotations

import unittest
from unittest import mock

import outlets.outlet_base as outlet_base
from outlets.outlet_base import OutletCallContext, OutletRunner, current_call_context, download_call_file, outlet_tool


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
