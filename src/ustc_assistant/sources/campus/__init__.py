"""Public campus catalog and on-demand reading services."""

from ustc_assistant.sources.campus.catalog import CampusError
from ustc_assistant.sources.campus.service import (
    read_attachment,
    read_detail,
    refresh_catalogs,
    search_catalog,
)

__all__ = [
    "CampusError",
    "read_attachment",
    "read_detail",
    "refresh_catalogs",
    "search_catalog",
]
