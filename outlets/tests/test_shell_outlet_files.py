from __future__ import annotations

import base64
import os
import tempfile
import unittest
from unittest import mock

from outlets.shell.shell_outlet import ShellOutlet


class ShellOutletFileTest(unittest.IsolatedAsyncioTestCase):
    async def test_read_image_uploads_detected_image(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as handle:
            handle.write(image_payload())
            path = handle.name

        try:
            outlet = ShellOutlet()
            with mock.patch(
                "outlets.shell.shell_outlet.upload_call_file",
                new=mock.AsyncMock(
                    return_value={
                        "file_id": 7,
                        "file_external_id": "img-123",
                        "filename": os.path.basename(path),
                        "mime_type": "image/png",
                        "size_bytes": len(image_payload()),
                        "sha256": "sha",
                        "is_image": True,
                    }
                ),
            ) as upload_mock:
                result = await outlet.read_image(path)

            self.assertEqual(result["text"], f"Image img-123 attached from {path}")
            self.assertEqual(result["media"][0]["file_id"], 7)
            self.assertEqual(upload_mock.await_args.kwargs["mime_type"], "image/png")
        finally:
            os.unlink(path)

    async def test_read_image_rejects_invalid_image_payload(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as handle:
            handle.write(b"<html><body>404 Not Found</body></html>")
            path = handle.name

        try:
            outlet = ShellOutlet()

            with self.assertRaisesRegex(ValueError, "File content is not a valid image."):
                await outlet.read_image(path)
        finally:
            os.unlink(path)

    async def test_read_image_falls_back_to_signature_sniffing_without_pillow(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as handle:
            handle.write(image_payload())
            path = handle.name

        try:
            outlet = ShellOutlet()
            with mock.patch("outlets.shell.shell_outlet.PILImage", None), mock.patch(
                "outlets.shell.shell_outlet.upload_call_file",
                new=mock.AsyncMock(
                    return_value={
                        "file_id": 8,
                        "file_external_id": "img-456",
                        "filename": os.path.basename(path),
                        "mime_type": "image/png",
                        "size_bytes": len(image_payload()),
                        "sha256": "sha",
                        "is_image": True,
                    }
                ),
            ) as upload_mock:
                result = await outlet.read_image(path)

            self.assertEqual(result["media"][0]["file_id"], 8)
            self.assertEqual(upload_mock.await_args.kwargs["mime_type"], "image/png")
        finally:
            os.unlink(path)

    async def test_read_image_fails_closed_without_pillow_for_unknown_signature(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as handle:
            handle.write(b"not-an-image")
            path = handle.name

        try:
            outlet = ShellOutlet()
            with mock.patch("outlets.shell.shell_outlet.PILImage", None):
                with self.assertRaisesRegex(ValueError, "File content is not a valid image."):
                    await outlet.read_image(path)
        finally:
            os.unlink(path)

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


def image_payload() -> bytes:
    return base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    )
