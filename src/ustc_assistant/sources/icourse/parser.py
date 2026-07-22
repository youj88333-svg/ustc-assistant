#!/usr/bin/env python3
"""Parse public, server-rendered USTC iCourse pages."""

from __future__ import annotations

import re
from typing import Any, Iterable
from urllib.parse import urljoin, urlsplit, urlunsplit

from bs4 import BeautifulSoup, Tag


BASE_URL = "https://icourse.club"


class ParseError(ValueError):
    """Raised when a public page no longer has the required structure."""


def canonicalize_source_url(url: str) -> str:
    split = urlsplit(urljoin(BASE_URL, url))
    path = split.path if split.path.endswith("/") else split.path + "/"
    return urlunsplit((split.scheme or "https", split.netloc or "icourse.club", path, "", ""))


def _source_id(url: str, kind: str) -> str:
    match = re.search(rf"/{re.escape(kind)}/(\d+)/?", urlsplit(url).path)
    if not match:
        raise ParseError(f"invalid {kind} URL")
    return match.group(1)


def _clean_text(node: Tag | None) -> str | None:
    if node is None:
        return None
    text = "\n".join(part.strip() for part in node.get_text("\n").splitlines() if part.strip())
    return text or None


def _title_subject(soup: BeautifulSoup) -> str:
    if not soup.title or not soup.title.string:
        return ""
    return re.split(r"\s+-\s+", soup.title.string.strip(), maxsplit=1)[0].strip()


def _split_course_title(value: str) -> tuple[str, list[str]]:
    value = value.strip()
    match = re.match(r"^(.*?)[（(]([^()（）]+)[）)]$", value)
    if not match:
        return value, []
    teachers = [item.strip() for item in re.split(r"[,，]", match.group(2)) if item.strip()]
    return match.group(1).strip(), teachers


def _number(value: str | None, default: int = 0) -> int:
    if value is None:
        return default
    match = re.search(r"-?\d+", value.replace(",", ""))
    return int(match.group()) if match else default


def _float(value: str | None) -> float | None:
    if value is None:
        return None
    match = re.search(r"\d+(?:\.\d+)?", value)
    return float(match.group()) if match else None


def _links(container: Tag | BeautifulSoup | None, kind: str) -> list[dict[str, Any]]:
    if container is None:
        return []
    results: list[dict[str, Any]] = []
    seen: set[str] = set()
    for anchor in container.select(f'a[href*="/{kind}/"]'):
        href = anchor.get("href")
        if not isinstance(href, str):
            continue
        try:
            source_id = _source_id(href, kind)
        except ParseError:
            continue
        if source_id in seen:
            continue
        seen.add(source_id)
        results.append(
            {
                f"source{kind.title()}Id": source_id,
                "sourceUrl": canonicalize_source_url(href),
                "label": anchor.get_text(" ", strip=True),
            }
        )
    return results


def parse_search_results(html: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    results: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for kind in ("course", "teacher"):
        for item in _links(soup.select_one("#search-results") or soup, kind):
            source_id = item[f"source{kind.title()}Id"]
            key = (kind, source_id)
            if key in seen:
                continue
            seen.add(key)
            results.append({"kind": kind, **item})
    return results


_DIMENSION_LABELS = {
    "课程难度": "difficulty",
    "难度": "difficulty",
    "course difficulty": "difficulty",
    "作业多少": "homework",
    "作业": "homework",
    "homework amount": "homework",
    "给分好坏": "grading",
    "给分": "grading",
    "grading": "grading",
    "收获大小": "gain",
    "收获": "gain",
    "gain": "gain",
}


def _dimensions(nodes: Iterable[Tag]) -> dict[str, str | None]:
    result: dict[str, str | None] = {key: None for key in ("difficulty", "homework", "grading", "gain")}
    for node in nodes:
        text = node.get_text(" ", strip=True)
        if ":" in text:
            label, value = text.split(":", 1)
        elif "：" in text:
            label, value = text.split("：", 1)
        else:
            continue
        key = _DIMENSION_LABELS.get(label.strip().lower())
        if key and result[key] is None:
            result[key] = value.strip()
    return result


def _parse_review(node: Tag) -> dict[str, Any]:
    review_id = str(node.get("id", "")).removeprefix("review-")
    content_node = node.select_one(f"#review-content-{review_id}") or node.select_one(".review-content")
    if content_node is None:
        raise ParseError(f"review {review_id or 'unknown'} is missing content")
    own_text = node.get_text(" ", strip=True)
    term = node.get("data-term")
    if not isinstance(term, str) or not term:
        match = re.search(r"(20\d{2})\s*(春|秋|夏)", own_text)
        term = f"{match.group(1)}{match.group(2)}" if match else None
    return {
        "sourceReviewId": review_id,
        "term": term,
        "dimensions": _dimensions(node.select("li")),
        "content": _clean_text(content_node) or "",
        "publishedAt": node.get("data-published-at"),
        "updatedAt": node.get("data-updated-at"),
        "upvoteCount": _number(_clean_text(node.select_one(f"#review-upvote-count-{review_id}"))),
        "commentCount": _number(_clean_text(node.select_one(f"#review-comment-count-{review_id}"))),
    }


def _course_rating(soup: BeautifulSoup) -> tuple[float | None, int]:
    node = soup.select_one(".course-rating")
    if node is not None:
        return _float(str(node.get("data-average")) if node.get("data-average") else _clean_text(node)), _number(str(node.get("data-review-count")) if node.get("data-review-count") else _clean_text(node))
    meta = soup.select_one('meta[property="og:description"]')
    content = str(meta.get("content", "")) if meta else ""
    return _float(content), _number(content.split("，", 1)[1] if "，" in content else content)


def parse_course_page(html: str, source_url: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    page = soup.select_one("#course-page")
    heading = page.select_one("h1") if page else None
    title_subject = _title_subject(soup)
    if heading is None and not title_subject:
        raise ParseError("course heading is missing")
    heading_text = heading.get_text(" ", strip=True) if heading else title_subject
    name, teachers = _split_course_title(heading_text)
    if not teachers:
        _, teachers = _split_course_title(title_subject)
    teacher_links = _links(soup.select_one("#teachers") or soup, "teacher")
    if not teachers and teacher_links:
        teachers = [item["label"] for item in teacher_links]
    aggregate_container = soup.select_one(".course-aggregate")
    aggregate = _dimensions((aggregate_container or soup).select("li"))
    average, review_count = _course_rating(soup)
    summary = _clean_text(soup.select_one("#course-summary"))
    terms_text = _clean_text(soup.select_one(".course-terms")) or ""
    terms = list(dict.fromkeys(re.findall(r"20\d{2}\s*(?:Spring|Fall|Summer|春|秋|夏)", terms_text, re.IGNORECASE)))
    course_numbers = re.findall(r"(?:Course No\.?|课程号)\s*[:：]\s*([A-Za-z0-9_-]+)", terms_text, re.IGNORECASE)
    return {
        "sourceCourseId": _source_id(source_url, "course"),
        "sourceUrl": canonicalize_source_url(source_url),
        "name": name,
        "teachers": teachers,
        "terms": terms,
        "courseNumbers": list(dict.fromkeys(course_numbers)),
        "averageScore": average,
        "reviewCount": review_count,
        "aggregate": aggregate,
        "siteAiSummary": {"source": "icourse", "text": summary} if summary else None,
        "reviews": [_parse_review(node) for node in soup.select(".review[id^='review-']")],
        "sameNameEntries": _links(soup.select_one("#same-name-courses"), "course"),
        "teacherOtherCourses": _links(soup.select_one("#teacher-other-courses"), "course"),
        "teacherLinks": teacher_links,
    }


def parse_teacher_page(html: str, source_url: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    page = soup.select_one("#teacher-page")
    heading = page.select_one("h1") if page else None
    name = heading.get_text(" ", strip=True) if heading else _title_subject(soup)
    if not name:
        raise ParseError("teacher heading is missing")
    text = (page or soup).get_text(" ", strip=True)
    values: dict[str, str] = {}
    if page:
        terms = page.select("dt")
        for term in terms:
            definition = term.find_next_sibling("dd")
            if definition:
                values[term.get_text(" ", strip=True).lower()] = definition.get_text(" ", strip=True)
    courses = _links(soup.select_one("#teacher-courses") or soup, "course")
    for course in courses:
        anchor = soup.select_one(f'a[href*="/course/{course["sourceCourseId"]}/"]')
        if anchor:
            course["averageScore"] = _float(str(anchor.get("data-score")))
            course["reviewCount"] = _number(str(anchor.get("data-review-count")))
    def metric(labels: tuple[str, ...], pattern: str) -> str | None:
        for label in labels:
            if label in values:
                return values[label]
        match = re.search(pattern, text, re.IGNORECASE)
        return match.group(1) if match else None
    return {
        "sourceTeacherId": _source_id(source_url, "teacher"),
        "sourceUrl": canonicalize_source_url(source_url),
        "name": name,
        "courseCount": _number(metric(("courses", "课程"), r"共\s*(\d+)\s*门课")),
        "reviewCount": _number(metric(("reviews", "点评"), r"共\s*(\d+)\s*个点评")),
        "averageScore": _float(metric(("average", "平均分"), r"平均分\s*[:：]\s*([\d.]+)")),
        "normalizedAverage": _float(metric(("normalized average", "归一化平均分"), r"归一化平均分\s*[:：]\s*([\d.]+)")),
        "courses": courses,
    }
