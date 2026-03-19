from __future__ import annotations

import unittest

from outlets.outlet_base import _build_verification_url


class BuildVerificationUrlTest(unittest.TestCase):
    def test_prefers_server_url_base_with_user_code(self):
        result = _build_verification_url(
            server_url="https://api.example.com/base/",
            user_code="ABCD-EFGH",
            verification_url="https://wrong.example.com/outlets/connect?code=ABCD-EFGH",
        )

        self.assertEqual(result, "https://api.example.com/base/outlets/connect?code=ABCD-EFGH")

    def test_url_encodes_user_code_when_rebuilding_link(self):
        result = _build_verification_url(
            server_url="https://api.example.com",
            user_code="ABCD EFGH/1",
            verification_url="",
        )

        self.assertEqual(result, "https://api.example.com/outlets/connect?code=ABCD%20EFGH%2F1")

    def test_falls_back_to_server_response_when_user_code_missing(self):
        result = _build_verification_url(
            server_url="https://api.example.com",
            user_code="",
            verification_url="https://fallback.example.com/outlets/connect?code=ABCD-EFGH",
        )

        self.assertEqual(result, "https://fallback.example.com/outlets/connect?code=ABCD-EFGH")
