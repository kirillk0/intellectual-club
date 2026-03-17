from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from outlets.shell.shell_outlet import ShellOutlet


class ShellOutletFileTest(unittest.IsolatedAsyncioTestCase):
    async def test_upload_file_returns_artifact_result(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as handle:
            handle.write(b"hello")
            path = handle.name

        try:
            outlet = ShellOutlet()
            with mock.patch(
                "outlets.shell.shell_outlet.upload_call_file",
                new=mock.AsyncMock(
                    return_value={
                        "file_id": 5,
                        "file_external_id": "file-123",
                        "filename": os.path.basename(path),
                        "mime_type": "text/plain",
                        "size_bytes": 5,
                        "sha256": "sha",
                        "is_image": False,
                    }
                ),
            ):
                result = await outlet.upload_file(path)

            self.assertEqual(result["text"], "File file-123 uploaded")
            self.assertEqual(result["artifacts"][0]["file_id"], 5)
            self.assertEqual(result["media"], [])
        finally:
            os.unlink(path)

    async def test_download_file_writes_payload(self):
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            target_path = handle.name

        try:
            outlet = ShellOutlet()
            with mock.patch(
                "outlets.shell.shell_outlet.download_call_file",
                new=mock.AsyncMock(return_value=(b"payload", {"content_type": "application/octet-stream"})),
            ):
                text, raw = await outlet.download_file("content-123", target_path)

            self.assertEqual(text, f"File content-123 downloaded to {target_path}")
            self.assertEqual(raw["size_bytes"], 7)
            with open(target_path, "rb") as handle:
                self.assertEqual(handle.read(), b"payload")
        finally:
            os.unlink(target_path)
