"""Resolve a current policy and extract its cited section."""

import re
from datetime import datetime


def active_policy(manifest, reason_code, payment_as_of):
    as_of = datetime.fromisoformat(payment_as_of)
    eligible = []
    for entry in manifest["documents"]:
        if entry["reasonCode"] != reason_code:
            continue
        start = datetime.fromisoformat(entry["validFromUtc"])
        end = entry.get("validToUtc")
        if start <= as_of and (end is None or as_of < datetime.fromisoformat(end)):
            eligible.append((start, entry))
    if not eligible:
        return None
    latest = max(start for start, _ in eligible)
    matches = [entry for start, entry in eligible if start == latest]
    if len(matches) != 1:
        raise ValueError("Ambiguous policy versions")
    return matches[0]


def cited_section(markdown, section_id):
    if not re.fullmatch(r"[a-z0-9-]+", section_id):
        raise ValueError("Invalid policy section ID")
    anchor = f'<a id="{section_id}"></a>'
    _, separator, section = markdown.partition(anchor)
    if not separator:
        return None
    section = re.split(r'^<a id="[^"]+"></a>[ \t]*$', section, maxsplit=1, flags=re.MULTILINE)[0].strip()
    return section or None
