from __future__ import annotations

import unittest
from unittest import mock

from outlets.shell import shell_outlet
from outlets.shell.shell_outlet import ShellOutlet


class ShellOutletEncodingTest(unittest.IsolatedAsyncioTestCase):
    async def test_windows_powershell_command_gets_utf8_bootstrap(self):
        proc = mock.Mock()
        proc.communicate = mock.AsyncMock(return_value=("Привет\n".encode("utf-8"), b""))
        proc.returncode = 0

        with mock.patch("outlets.shell.shell_outlet.os.name", "nt"), mock.patch(
            "outlets.shell.shell_outlet._SHELL_KIND",
            "powershell",
        ), mock.patch(
            "outlets.shell.shell_outlet._SHELL_ARGV_PREFIX",
            ["powershell", "-NoLogo", "-Command"],
        ), mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ) as create_exec:
            outlet = ShellOutlet()
            text, raw = await outlet.run_command(command="Write-Output 'Привет'")

        self.assertEqual(text.strip(), "Привет")
        self.assertEqual(raw["shell_encoding_bootstrap"], "windows-force-utf8")
        self.assertFalse(raw["stdout_decode_error"])
        self.assertEqual(raw["stdout_encoding"], "utf-8")

        args = create_exec.await_args.args
        self.assertEqual(args[:3], ("powershell", "-NoLogo", "-Command"))
        wrapped_command = args[3]
        self.assertIn("[Console]::InputEncoding = $utf8NoBom", wrapped_command)
        self.assertIn("[Console]::OutputEncoding = $utf8NoBom", wrapped_command)
        self.assertIn("$OutputEncoding = $utf8NoBom", wrapped_command)
        self.assertIn("chcp.com 65001 > $null", wrapped_command)
        self.assertIn("& { Write-Output 'Привет' }", wrapped_command)

    async def test_windows_powershell_command_can_disable_utf8_bootstrap(self):
        proc = mock.Mock()
        proc.communicate = mock.AsyncMock(return_value=(b"ok\n", b""))
        proc.returncode = 0

        with mock.patch("outlets.shell.shell_outlet.os.name", "nt"), mock.patch(
            "outlets.shell.shell_outlet._SHELL_KIND",
            "pwsh",
        ), mock.patch(
            "outlets.shell.shell_outlet._SHELL_ARGV_PREFIX",
            ["pwsh", "-NoLogo", "-NoProfile", "-Command"],
        ), mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ) as create_exec:
            outlet = ShellOutlet()
            _text, raw = await outlet.run_command(
                command="Write-Output 'ok'",
                env={"SHELL_OUTLET_WINDOWS_FORCE_UTF8": "0"},
            )

        self.assertEqual(raw["shell_encoding_bootstrap"], "")
        args = create_exec.await_args.args
        self.assertEqual(args[4], "Write-Output 'ok'")

    async def test_argv_execution_is_not_wrapped_by_powershell_bootstrap(self):
        proc = mock.Mock()
        proc.communicate = mock.AsyncMock(return_value=(b"direct\n", b""))
        proc.returncode = 0

        with mock.patch("outlets.shell.shell_outlet.os.name", "nt"), mock.patch(
            "outlets.shell.shell_outlet._SHELL_KIND",
            "powershell",
        ), mock.patch(
            "outlets.shell.shell_outlet._SHELL_ARGV_PREFIX",
            ["powershell", "-NoLogo", "-Command"],
        ), mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ) as create_exec:
            outlet = ShellOutlet()
            text, raw = await outlet.run_command(argv=["python", "-c", "print('direct')"])

        self.assertEqual(text.strip(), "direct")
        self.assertEqual(create_exec.await_args.args, ("python", "-c", "print('direct')"))
        self.assertEqual(raw["shell_encoding_bootstrap"], "")
        self.assertEqual(raw["shell_kind"], "")
        self.assertEqual(raw["shell_executor"], "")
        self.assertEqual(raw["shell_argv_prefix"], [])

    async def test_invalid_utf8_output_sets_diagnostic_flags(self):
        proc = mock.Mock()
        proc.communicate = mock.AsyncMock(return_value=(b"\xffhello", b"\xfeerror"))
        proc.returncode = 0

        with mock.patch(
            "outlets.shell.shell_outlet.asyncio.create_subprocess_exec",
            new=mock.AsyncMock(return_value=proc),
        ):
            outlet = ShellOutlet()
            text, raw = await outlet.run_command(argv=["tool"])

        self.assertIn("\ufffdhello", raw["stdout"])
        self.assertIn("\ufffderror", raw["stderr"])
        self.assertIn("\ufffdhello", text)
        self.assertTrue(raw["stdout_decode_error"])
        self.assertTrue(raw["stderr_decode_error"])
        self.assertEqual(raw["stdout_encoding"], shell_outlet._UTF8_ENCODING)
        self.assertEqual(raw["stderr_encoding"], shell_outlet._UTF8_ENCODING)
