"""HTML adapters for public USTC teaching-office pages."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import urljoin, urlsplit

from bs4 import BeautifulSoup, Tag

from ustc_assistant.sources.campus.catalog import (
    CampusError,
    CatalogEntry,
    canonicalize_url,
    entry_id,
)


DATE_PATTERN = re.compile(r"\b(20\d{2}-\d{2}-\d{2})\b")
NOTICE_PATH_PATTERN = re.compile(r"^/notice/.+\.html$")
GUIDE_PATH_PATTERN = re.compile(r"^/service/svc-student/.+\.html$")
EMPTY_MARKERS = (".no-results", ".wp-block-query-no-results", ".empty")
EXPLICIT_LINK_PATTERN = re.compile(r"详情见|具体办法|点击查看|参见")
ATTACHMENT_MEDIA_TYPES = {
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}


class CampusParseError(CampusError):
    """A configured campus page no longer matches its public contract."""


@dataclass(frozen=True)
class ParsedCatalogPage:
    entries: tuple[CatalogEntry, ...]
    next_url: str | None


def _collapse(value: str) -> str:
    return " ".join(value.split())


def _date_near(anchor: Tag) -> str | None:
    parent = anchor.find_parent(["article", "li", "section", "div"])
    text = parent.get_text(" ", strip=True) if parent else anchor.parent.get_text(" ", strip=True)
    match = DATE_PATTERN.search(text)
    return match.group(1) if match else None


def _category_near(anchor: Tag) -> str | None:
    parent = anchor.find_parent(attrs={"data-category": True})
    if parent:
        value = _collapse(str(parent.get("data-category", "")))
        return value or None
    category = anchor.find_previous(class_=re.compile(r"\bcategory\b"))
    if category:
        return _collapse(category.get_text(" ", strip=True)) or None
    return None


def _next_url(soup: BeautifulSoup, base_url: str) -> str | None:
    candidate = soup.select_one("a.next, a.next.page-numbers, a[rel='next']")
    if candidate is None:
        candidate = next(
            (
                anchor
                for anchor in soup.find_all("a", href=True)
                if "下一页" in anchor.get_text(" ", strip=True)
            ),
            None,
        )
    return urljoin(base_url, str(candidate["href"])) if candidate else None


def parse_teach_catalog(
    html: str,
    *,
    source: str,
    kind: str,
    base_url: str,
    observed_at: datetime,
) -> ParsedCatalogPage:
    soup = BeautifulSoup(html, "html.parser")
    entries: list[CatalogEntry] = []
    seen: set[str] = set()
    roots = soup.select("ul.article-list")
    anchors = [
        anchor
        for root in roots
        for anchor in root.find_all("a", href=True)
    ] if roots else soup.find_all("a", href=True)
    path_pattern = NOTICE_PATH_PATTERN if kind == "notice" else GUIDE_PATH_PATTERN
    for anchor in anchors:
        absolute = canonicalize_url(urljoin(base_url, str(anchor["href"])))
        if not path_pattern.match(urlsplit(absolute).path):
            continue
        title = _collapse(anchor.get_text(" ", strip=True))
        if not title:
            continue
        identity = entry_id(source, absolute)
        if identity in seen:
            continue
        seen.add(identity)
        stamp = observed_at.isoformat()
        entries.append(
            CatalogEntry(
                id=identity,
                source=source,
                kind=kind,
                title=title,
                category=_category_near(anchor),
                published_at=_date_near(anchor),
                detail_url=absolute,
                discovered_at=stamp,
                last_seen_at=stamp,
            )
        )
    if not entries and not any(soup.select_one(marker) for marker in EMPTY_MARKERS):
        raise CampusParseError("teach catalog page did not contain expected entries")
    return ParsedCatalogPage(tuple(entries), _next_url(soup, base_url))


def _media_type(url: str) -> str | None:
    return ATTACHMENT_MEDIA_TYPES.get(PurePosixPath(urlsplit(url).path).suffix.lower())


def _linked_id(prefix: str, url: str) -> str:
    digest = hashlib.sha256(canonicalize_url(url).encode("utf-8")).hexdigest()[:20]
    return f"{prefix}_{digest}"


def parse_teach_detail(html: str, url: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    title_node = soup.select_one(".single-title h1, h1")
    content_node = soup.select_one(
        ".entry-content, .article-content, .post-content, "
        "#content .entry-content, main.single > article"
    )
    if title_node is None or content_node is None:
        raise CampusParseError("teach detail page did not contain expected content")

    for selector in ("script", "style", "nav", "footer", ".share", ".print"):
        for node in content_node.select(selector):
            node.decompose()

    attachments: list[dict[str, str]] = []
    candidate_links: list[dict[str, str]] = []
    for anchor in content_node.find_all("a", href=True):
        absolute = canonicalize_url(urljoin(url, str(anchor["href"])))
        label = _collapse(anchor.get_text(" ", strip=True)) or absolute
        media_type = _media_type(absolute)
        if media_type:
            attachments.append(
                {
                    "id": _linked_id("attachment", absolute),
                    "label": label,
                    "url": absolute,
                    "mediaType": media_type,
                }
            )
            continue
        context = anchor.parent.get_text(" ", strip=True) if anchor.parent else label
        if EXPLICIT_LINK_PATTERN.search(context):
            candidate_links.append(
                {
                    "id": _linked_id("link", absolute),
                    "url": absolute,
                    "label": label,
                    "reason": "explicit-reference",
                }
            )

    images = [
        {
            "url": canonicalize_url(urljoin(url, str(image["src"]))),
            "alt": _collapse(str(image.get("alt", ""))),
        }
        for image in content_node.find_all("img", src=True)
    ]
    date_match = DATE_PATTERN.search(soup.get_text(" ", strip=True))
    return {
        "title": _collapse(title_node.get_text(" ", strip=True)),
        "content": _collapse(content_node.get_text(" ", strip=True)),
        "publishedAt": date_match.group(1) if date_match else None,
        "url": canonicalize_url(url),
        "category": None,
        "attachments": attachments,
        "images": images,
        "candidateLinks": candidate_links,
    }
