"""Authentication boundaries shared by school source collectors."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

from ustc_assistant.common.browser import CollectionError, default_profile_dir


CAS_HOSTS = frozenset({"id.ustc.edu.cn"})
USERNAME_SELECTOR = 'input[name="username"], #username'
PASSWORD_SELECTOR = 'input[type="password"]'
ACCOUNT_SELECTOR = (
    '[data-ustc-account], input[name="fine_username"], input[name="username"]'
)


class AuthBoundaryError(CollectionError):
    code = "auth_boundary"


class UserActionRequired(CollectionError):
    code = "needs_user_action"


class AccountMismatch(CollectionError):
    code = "account_mismatch"


class CollectionCancelled(CollectionError):
    code = "cancelled"


@dataclass(frozen=True)
class LoginCredentials:
    username: str
    password: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.username, str) or not self.username.strip():
            raise ValueError("username must be non-blank text")
        if self.password is not None and not isinstance(self.password, str):
            raise ValueError("password must be text or None")


def is_ustc_cas_origin(url: str) -> bool:
    parsed = urlsplit(url)
    return parsed.scheme == "https" and parsed.hostname in CAS_HOSTS


def profile_dir_for_account(
    account_id: str, *, base_dir: Path | None = None
) -> Path:
    if not isinstance(account_id, str) or not account_id.strip():
        raise ValueError("account_id must be non-blank text")
    digest = hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:24]
    base = (
        Path(base_dir)
        if base_dir is not None
        else default_profile_dir().parent / "edge-profiles"
    )
    return base / digest


def raise_if_cancelled(
    cancel_check: Callable[[], bool] | None,
) -> None:
    if cancel_check is not None and cancel_check():
        raise CollectionCancelled("collection cancelled")


def fill_ustc_login(page: Any, credentials: LoginCredentials) -> None:
    if not is_ustc_cas_origin(str(getattr(page, "url", ""))):
        raise AuthBoundaryError("login page is not an allowlisted USTC CAS origin")
    page.locator(USERNAME_SELECTOR).first.fill(credentials.username)
    if credentials.password is not None:
        page.locator(PASSWORD_SELECTOR).first.fill(credentials.password)


def _account_from_page(page: Any) -> str | None:
    locator = page.locator(ACCOUNT_SELECTOR).first
    count = getattr(locator, "count", None)
    if callable(count) and count() == 0:
        return None
    value = locator.get_attribute("data-ustc-account")
    if not value:
        try:
            value = locator.input_value()
        except Exception:
            value = None
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _contains_exact_account(
    candidate: Any,
    expected: str,
    *,
    depth: int = 0,
) -> bool:
    if depth > 8:
        return False
    if isinstance(candidate, str):
        value = candidate.strip()
        if value.casefold() == expected.casefold():
            return True
        if not value or len(value) > 65_536:
            return False
        try:
            decoded = json.loads(value)
        except (TypeError, ValueError):
            return False
        return _contains_exact_account(decoded, expected, depth=depth + 1)
    if isinstance(candidate, dict):
        return any(
            _contains_exact_account(value, expected, depth=depth + 1)
            for value in candidate.values()
        )
    if isinstance(candidate, list):
        return any(
            _contains_exact_account(value, expected, depth=depth + 1)
            for value in candidate
        )
    return False


def verify_ustc_account(page: Any, expected_username: str) -> None:
    actual = _account_from_page(page)
    expected = expected_username.strip()
    if actual is not None and actual.casefold() == expected.casefold():
        return
    evaluate = getattr(page, "evaluate", None)
    if callable(evaluate):
        candidates = evaluate(
            """() => {
              const values = [];
              for (const entry of performance.getEntriesByType('resource')) {
                try {
                  const url = new URL(entry.name);
                  values.push(
                    url.searchParams.get('fine_username'),
                    url.searchParams.get('username')
                  );
                } catch (_) {}
              }
              for (const storage of [localStorage, sessionStorage]) {
                for (let index = 0; index < storage.length; index++) {
                  const key = storage.key(index);
                  if (key && /user(name)?|account/i.test(key)) {
                    values.push(storage.getItem(key));
                  }
                }
              }
              return values.filter(value => typeof value === 'string');
            }"""
        )
        if isinstance(candidates, list) and any(
            _contains_exact_account(candidate, expected)
            for candidate in candidates
        ):
            return
    raise AccountMismatch("authenticated school account could not be verified")
