from __future__ import annotations

import asyncio
import os
import unittest
from unittest import mock

from outlets.shell.shell_outlet import ShellOutlet


class _TimeoutFakeProcess:
    def __init__(self) -> None:
        self.returncode = -9
        self._calls = 0

    async def communicate(self, input=None):  # noqa: ANN001
        self._calls += 1
        if self._calls == 1:
            await asyncio.sleep(2.0)
            return b"", b""
        return b"", b""


class ShellOutletRunCommandTimeoutTest(unittest.IsolatedAsyncioTestCase):
    async def test_run_command_uses_isolated_process_session(self):
        proc = mock.Mock()
        proc.communicate = mock.AsyncMock(return_value=(b"ok\n", b""))
        proc.returncode = 0

        with mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ) as create_exec:
            outlet = ShellOutlet()
            text, raw = await outlet.run_command(command="echo ok")

        self.assertEqual(text.strip(), "ok")
        self.assertFalse(bool(raw.get("timed_out")))
        kwargs = create_exec.await_args.kwargs
        if os.name == "nt":
            self.assertIn("creationflags", kwargs)
        else:
            self.assertTrue(bool(kwargs.get("start_new_session")))

    async def test_run_command_timeout_terminates_process_tree(self):
        proc = _TimeoutFakeProcess()

        with mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ), mock.patch(
            "outlets.shell.shell_outlet._terminate_process_tree",
            new=mock.AsyncMock(),
        ) as terminate_mock:
            outlet = ShellOutlet()
            text, raw = await outlet.run_command(command="sleep 100", timeout_seconds=1)

        self.assertEqual(text, "[timeout] Command exceeded timeout of 1 second.")
        self.assertTrue(bool(raw.get("timed_out")))
        terminate_mock.assert_awaited_once_with(proc, grace_seconds=2.0)
