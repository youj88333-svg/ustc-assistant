"""Shared lifecycle for the dedicated visible Edge profile."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable, TypeVar

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright


T = TypeVar("T")


class CollectionError(RuntimeError):
    """A collection failure whose message is safe to show to the user."""


def default_profile_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    base = Path(local_app_data) if local_app_data else Path.home() / "AppData" / "Local"
    return base / "USTC Campus Assistant" / "edge-profile"


def run_in_edge(
    action: Callable[[Any], T],
    *,
    profile_dir: Path | None = None,
    playwright_factory: Callable[[], Any] | None = None,
) -> T:
    profile = Path(profile_dir) if profile_dir is not None else default_profile_dir()
    profile.mkdir(parents=True, exist_ok=True)
    factory = playwright_factory or sync_playwright

    try:
        with factory() as playwright:
            context = playwright.chromium.launch_persistent_context(
                str(profile),
                channel="msedge",
                headless=False,
                no_viewport=True,
            )
            try:
                page = context.pages[0] if context.pages else context.new_page()
                return action(page)
            finally:
                context.close()
    except CollectionError:
        raise
    except PlaywrightError as exc:
        raise CollectionError("browser automation failed") from exc
