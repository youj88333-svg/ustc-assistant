import json
import math
from collections import Counter
from collections.abc import Mapping, Sequence
from datetime import date, datetime
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


MAX_BUNDLE_BYTES = 16 * 1024 * 1024
MAX_NESTING_DEPTH = 64
CANONICAL_SCHEMA_PATH = (
    Path(__file__).resolve().parents[3]
    / "schemas"
    / "source-bundle-1.0.schema.json"
)

_SAFE_MESSAGES = {
    "unsupported_version": "The SourceBundle version is not supported.",
    "invalid_envelope": "The SourceBundle envelope is invalid.",
    "incomplete_snapshot": "The SourceBundle snapshot is incomplete.",
    "subject_mismatch": "The SourceBundle belongs to a different account.",
    "count_mismatch": "The SourceBundle counts are inconsistent.",
    "duplicate_identity": "The SourceBundle contains a duplicate identity.",
    "dangling_reference": "The SourceBundle contains an invalid reference.",
    "invalid_time": "The SourceBundle contains an invalid time range.",
    "limit_exceeded": "The SourceBundle exceeds a contract limit.",
}

_SENSITIVE_KEY_FRAGMENTS = {
    "authorization",
    "browserprofile",
    "contextid",
    "cookie",
    "credential",
    "password",
    "profilepath",
    "sessionid",
    "studentid",
    "token",
    "userid",
}

_TIME_FIELDS = {
    "collectedAt",
    "endAt",
    "endDateExclusive",
    "fromDate",
    "sourceUpdatedAt",
    "startAt",
    "startDate",
    "throughDate",
}

_RECORD_ENTITY_TYPES = {
    "jw_course_series": "course_series",
    "jw_course_occurrence": "calendar_event",
    "jw_exam": "calendar_event",
    "jw_exam_course_relation": "schedule_relation",
    "young_registered_schedule": "calendar_event",
}


class SourceBundleValidationError(ValueError):
    def __init__(self, code: str, safe_message: str):
        self.code = code
        self.safe_message = safe_message
        super().__init__(f"{code}: {safe_message}")


def _raise(code: str) -> None:
    raise SourceBundleValidationError(code, _SAFE_MESSAGES[code])


@lru_cache(maxsize=1)
def _canonical_validator() -> Draft202012Validator:
    schema = json.loads(CANONICAL_SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


def validate_source_bundle(bundle: Mapping[str, Any]) -> None:
    if not isinstance(bundle, Mapping):
        _raise("invalid_envelope")

    _inspect_structure(bundle)
    try:
        encoded_size = len(
            json.dumps(
                bundle,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        )
    except (TypeError, ValueError, OverflowError):
        _raise("invalid_envelope")
    if encoded_size > MAX_BUNDLE_BYTES:
        _raise("limit_exceeded")

    if bundle.get("schemaVersion") != "1.0":
        _raise("unsupported_version")

    snapshot = bundle.get("snapshot")
    if isinstance(snapshot, Mapping):
        if snapshot.get("completeness") != "complete":
            _raise("incomplete_snapshot")
        scope = snapshot.get("scope")
        if isinstance(scope, Mapping):
            components = scope.get("components")
            if isinstance(components, Sequence) and not isinstance(
                components, (str, bytes)
            ):
                for component in components:
                    if (
                        isinstance(component, Mapping)
                        and component.get("status") != "complete"
                    ):
                        _raise("incomplete_snapshot")

    schema_errors = sorted(
        _canonical_validator().iter_errors(bundle),
        key=lambda error: [str(part) for part in error.absolute_path],
    )
    if schema_errors:
        _raise(_schema_error_code(schema_errors[0]))

    data = bundle["data"]
    _check_unique_identities(data)
    _check_manifest(bundle["manifest"], data)
    _check_times(data["calendarEvents"])
    _check_references(data)
    _check_scope(bundle["source"], snapshot["scope"], data)


def validate_source_bundle_subject(
    bundle: Mapping[str, Any], expected_account_id: str
) -> None:
    subject = bundle.get("subject")
    if (
        not isinstance(subject, Mapping)
        or subject.get("accountId") != expected_account_id
    ):
        _raise("subject_mismatch")


def _inspect_structure(value: Any, depth: int = 0) -> None:
    if depth > MAX_NESTING_DEPTH:
        _raise("limit_exceeded")
    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str):
                _raise("invalid_envelope")
            normalized_key = key.lower().replace("_", "").replace("-", "")
            if any(
                fragment in normalized_key
                for fragment in _SENSITIVE_KEY_FRAGMENTS
            ):
                _raise("invalid_envelope")
            _inspect_structure(child, depth + 1)
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _inspect_structure(child, depth + 1)
    elif isinstance(value, float) and not math.isfinite(value):
        _raise("invalid_envelope")


def _schema_error_code(error: Any) -> str:
    path = {str(part) for part in error.absolute_path}
    if error.validator in {"maxItems", "maxLength", "maximum"}:
        return "limit_exceeded"
    if (
        error.validator == "oneOf"
        and error.absolute_path
        and error.absolute_path[-1] == "time"
        and isinstance(error.instance, Mapping)
    ):
        branch = {"timed": 0, "all_day": 1}.get(error.instance.get("kind"))
        if branch is None:
            return "invalid_envelope"
        relevant = [
            child
            for child in error.context
            if _schema_branch_index(child) == branch
        ]
        if any(
            child.validator in {"pattern", "format", "const"}
            for child in relevant
        ):
            return "invalid_time"
        return "invalid_envelope"
    if path & _TIME_FIELDS:
        return "invalid_time"
    return "invalid_envelope"


def _schema_branch_index(error: Any) -> int | None:
    parts = list(error.absolute_schema_path)
    try:
        return parts[parts.index("oneOf") + 1]
    except (ValueError, IndexError):
        return None


def _check_unique_identities(data: Mapping[str, Any]) -> None:
    for collection_name in (
        "sourceRecords",
        "calendarEvents",
        "courseSeries",
        "scheduleRelations",
    ):
        identities = [
            item["externalId"] for item in data[collection_name]
        ]
        if len(identities) != len(set(identities)):
            _raise("duplicate_identity")


def _check_manifest(
    manifest: Mapping[str, Any], data: Mapping[str, Any]
) -> None:
    expected = {
        "sourceRecordCount": len(data["sourceRecords"]),
        "calendarEventCount": len(data["calendarEvents"]),
        "courseSeriesCount": len(data["courseSeries"]),
        "scheduleRelationCount": len(data["scheduleRelations"]),
    }
    if any(manifest[name] != count for name, count in expected.items()):
        _raise("count_mismatch")


def _parse_datetime(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        _raise("invalid_time")
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 28800:
        _raise("invalid_time")
    return parsed


def _parse_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError:
        _raise("invalid_time")


def _check_times(events: Sequence[Mapping[str, Any]]) -> None:
    for event in events:
        event_time = event["time"]
        if event_time["kind"] == "timed":
            if _parse_datetime(event_time["startAt"]) >= _parse_datetime(
                event_time["endAt"]
            ):
                _raise("invalid_time")
        elif _parse_date(event_time["startDate"]) >= _parse_date(
            event_time["endDateExclusive"]
        ):
            _raise("invalid_time")


def _check_references(data: Mapping[str, Any]) -> None:
    entities = {
        "calendar_event": {
            item["externalId"] for item in data["calendarEvents"]
        },
        "course_series": {
            item["externalId"] for item in data["courseSeries"]
        },
        "schedule_relation": {
            item["externalId"] for item in data["scheduleRelations"]
        },
    }
    entity_kinds = {
        "calendar_event": {
            item["externalId"]: item["sourceDetails"]["kind"]
            for item in data["calendarEvents"]
        },
        "course_series": {
            item["externalId"]: item["sourceDetails"]["kind"]
            for item in data["courseSeries"]
        },
        "schedule_relation": {
            item["externalId"]: "jw_exam_course_relation"
            for item in data["scheduleRelations"]
        },
    }

    mapping_counts: Counter[tuple[str, str]] = Counter()
    for record in data["sourceRecords"]:
        expected_type = _RECORD_ENTITY_TYPES[record["recordType"]]
        entity_type = record["entityType"]
        entity_id = record["entityExternalId"]
        if (
            entity_type != expected_type
            or entity_id not in entities[entity_type]
            or entity_kinds[entity_type][entity_id] != record["recordType"]
        ):
            _raise("dangling_reference")
        mapping_counts[(entity_type, entity_id)] += 1

    if any(count > 1 for count in mapping_counts.values()):
        _raise("duplicate_identity")
    for entity_type, identities in entities.items():
        if any(
            mapping_counts[(entity_type, identity)] != 1
            for identity in identities
        ):
            _raise("dangling_reference")

    course_series = entities["course_series"]
    for event in data["calendarEvents"]:
        series_id = event["seriesExternalId"]
        if series_id is not None and series_id not in course_series:
            _raise("dangling_reference")

    for relation in data["scheduleRelations"]:
        primary = relation["primary"]
        related = relation["related"]
        if (
            primary["externalId"] not in entities[primary["entityType"]]
            or related["externalId"] not in entities[related["entityType"]]
        ):
            _raise("dangling_reference")
        if (
            relation["relationType"] == "exam_for_course"
            and (
                primary["entityType"] != "calendar_event"
                or related["entityType"] != "course_series"
                or entity_kinds["calendar_event"][
                    primary["externalId"]
                ]
                != "jw_exam"
            )
        ):
            _raise("dangling_reference")


def _check_scope(
    source: str, scope: Mapping[str, Any], data: Mapping[str, Any]
) -> None:
    if source == "ustc_jw":
        record_counts = Counter(
            record["recordType"] for record in data["sourceRecords"]
        )
        observed = {
            component["name"]: component["observedRecordCount"]
            for component in scope["components"]
        }
        course_count = (
            record_counts["jw_course_series"]
            + record_counts["jw_course_occurrence"]
        )
        exam_count = (
            record_counts["jw_exam"]
            + record_counts["jw_exam_course_relation"]
        )
        if (
            observed["course_table"] != course_count
            or observed["exam_arrange"] != exam_count
        ):
            _raise("count_mismatch")
        semester_key = scope["semesterKey"]
        for series in data["courseSeries"]:
            if series["semesterKey"] != semester_key:
                _raise("dangling_reference")
        for event in data["calendarEvents"]:
            details = event["sourceDetails"]
            if details.get("semesterKey") != semester_key:
                _raise("dangling_reference")
        return

    from_date = _parse_date(scope["fromDate"])
    through_date = _parse_date(scope["throughDate"])
    if from_date > through_date:
        _raise("invalid_time")
    expected_days = (through_date - from_date).days + 1
    if (
        scope["expectedDateCount"] != expected_days
        or scope["checkedDateCount"] != expected_days
        or scope["emptyDateCount"] > scope["checkedDateCount"]
    ):
        _raise("count_mismatch")
    for event in data["calendarEvents"]:
        event_time = event["time"]
        if event_time["kind"] == "timed":
            event_date = _parse_datetime(event_time["startAt"]).date()
        else:
            event_date = _parse_date(event_time["startDate"])
        if not from_date <= event_date <= through_date:
            _raise("invalid_time")
