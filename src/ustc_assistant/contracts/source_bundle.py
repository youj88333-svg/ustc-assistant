import copy
import hashlib
import json
from collections.abc import Mapping
from typing import Any


SCHEMA_VERSION = "1.0"


def canonical_bundle_digest(bundle: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def make_bundle_envelope(
    *,
    bundle_id: str,
    source: str,
    account_id: str,
    collected_at: str,
    snapshot: Mapping[str, Any],
    data: Mapping[str, Any],
    producer: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    copied_data = copy.deepcopy(dict(data))
    envelope: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "bundleId": bundle_id,
        "source": source,
        "subject": {"accountId": account_id},
        "collectedAt": collected_at,
    }
    if producer is not None:
        envelope["producer"] = copy.deepcopy(dict(producer))
    envelope.update(
        {
            "snapshot": copy.deepcopy(dict(snapshot)),
            "manifest": {
                "sourceRecordCount": len(copied_data["sourceRecords"]),
                "calendarEventCount": len(copied_data["calendarEvents"]),
                "courseSeriesCount": len(copied_data["courseSeries"]),
                "scheduleRelationCount": len(
                    copied_data["scheduleRelations"]
                ),
            },
            "data": copied_data,
        }
    )
    return envelope
