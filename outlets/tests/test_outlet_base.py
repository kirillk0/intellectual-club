from __future__ import annotations

import unittest
from unittest import mock

from outlets.outlet_base import OutletRunner, current_call_context, outlet_tool


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
