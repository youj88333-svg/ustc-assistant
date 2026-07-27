from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ustc_assistant.common.auth import (
    AccountMismatch,
    AuthBoundaryError,
    CollectionCancelled,
    LoginCredentials,
    fill_ustc_login,
    profile_dir_for_account,
    raise_if_cancelled,
    verify_ustc_account,
)


class FakeLocator:
    def __init__(self, page, selector):
        self.page = page
        self.selector = selector
        self.first = self

    def fill(self, value):
        self.page.fills.append((self.selector, value))

    def get_attribute(self, name):
        return self.page.account_value if name == "data-ustc-account" else None

    def input_value(self):
        return self.page.account_value


class FakePage:
    def __init__(self, url, account_value=None):
        self.url = url
        self.account_value = account_value
        self.fills = []

    def locator(self, selector):
        return FakeLocator(self, selector)


class StorageIdentityPage(FakePage):
    def __init__(self, candidates):
        super().__init__("https://young.ustc.edu.cn/login/app")
        self.candidates = candidates

    def evaluate(self, script, *args):
        return list(self.candidates)


class LoginBoundaryTests(unittest.TestCase):
    def test_credentials_fill_only_on_official_cas_origin_without_submit(self):
        page = FakePage("https://id.ustc.edu.cn/cas/login?service=redacted")

        fill_ustc_login(page, LoginCredentials("PB00000000", "secret"))

        self.assertEqual(
            [
                ('input[name="username"], #username', "PB00000000"),
                ('input[type="password"]', "secret"),
            ],
            page.fills,
        )

    def test_credentials_are_rejected_on_non_allowlisted_origin(self):
        with self.assertRaises(AuthBoundaryError):
            fill_ustc_login(
                FakePage("https://example.com/login"),
                LoginCredentials("PB00000000", "secret"),
            )

    def test_account_mismatch_is_sanitized(self):
        page = FakePage(
            "https://jw.ustc.edu.cn/home",
            account_value="PB11111111",
        )

        with self.assertRaises(AccountMismatch) as caught:
            verify_ustc_account(page, "PB22222222")

        self.assertEqual("account_mismatch", caught.exception.code)
        self.assertNotIn("PB11111111", str(caught.exception))
        self.assertNotIn("PB22222222", str(caught.exception))

    def test_account_matches_nested_second_classroom_storage_wrapper(self):
        page = StorageIdentityPage(
            [
                json.dumps(
                    {
                        "expire": 1790000000000,
                        "value": "PB22222222",
                    }
                )
            ]
        )

        verify_ustc_account(page, "PB22222222")

    def test_nested_storage_requires_an_exact_account_value(self):
        page = StorageIdentityPage(
            [
                json.dumps(
                    {
                        "expire": 1790000000000,
                        "value": {
                            "username": "PB11111111",
                            "description": "not-PB22222222",
                        },
                    }
                )
            ]
        )

        with self.assertRaises(AccountMismatch):
            verify_ustc_account(page, "PB22222222")


class SessionIdentityTests(unittest.TestCase):
    def test_profile_path_is_stable_and_isolated_per_local_account(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            first = profile_dir_for_account("acct_one", base_dir=base)
            again = profile_dir_for_account("acct_one", base_dir=base)
            second = profile_dir_for_account("../acct_two", base_dir=base)

        self.assertEqual(first, again)
        self.assertNotEqual(first, second)
        self.assertEqual(base, first.parent)
        self.assertEqual(base, second.parent)
        self.assertNotIn("acct_one", first.name)

    def test_cancel_callback_raises_stable_error(self):
        with self.assertRaises(CollectionCancelled) as caught:
            raise_if_cancelled(lambda: True)

        self.assertEqual("cancelled", caught.exception.code)


if __name__ == "__main__":
    unittest.main()
