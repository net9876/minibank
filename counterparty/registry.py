from dataclasses import dataclass
from datetime import datetime, timezone
import re
import unicodedata

import httpx

ROOT = "https://api.gleif.org/api/v1/lei-records"
LEI = re.compile(r"[A-Z0-9]{18}[0-9]{2}", re.ASCII)
JURISDICTION = re.compile(r"[A-Z]{2}(?:-[A-Z0-9]{1,3})?", re.ASCII)
RELATIONS = {
    "direct": "IS_DIRECTLY_CONSOLIDATED_BY",
    "ultimate": "IS_ULTIMATELY_CONSOLIDATED_BY",
}


class RegistryUnavailable(RuntimeError):
    pass


def valid_lei(value):
    if not isinstance(value, str) or LEI.fullmatch(value) is None:
        return False
    digits = "".join(c if c.isdigit() else str(ord(c) - 55) for c in value)
    return int(digits) % 97 == 1


@dataclass(frozen=True)
class Search:
    lei: str = ""
    name: str = ""
    jurisdiction: str = ""

    def __post_init__(self):
        if self.lei:
            if not valid_lei(self.lei) or self.name or self.jurisdiction:
                raise ValueError("Supply one valid LEI, or a public legal name and jurisdiction.")
            return
        if not 2 <= len(self.name) <= 100 or not JURISDICTION.fullmatch(self.jurisdiction):
            raise ValueError("A public legal name and jurisdiction are required.")
        if any(not (c.isalpha() or c.isdecimal() or c in " .,&'’()-/") for c in self.name):
            raise ValueError("Unexpected characters in the legal name.")


@dataclass(frozen=True)
class Entity:
    lei: str
    name: str
    jurisdiction: str
    observed_at: str

    @property
    def source(self):
        return f"{ROOT}/{self.lei}"


@dataclass(frozen=True)
class Relationship:
    child: str
    parent: str
    kind: str
    record_id: str
    source: str
    observed_at: str
    valid_from: str | None
    corroboration: str | None


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize(value):
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


class Gleif:
    def __init__(self, client):
        self.client = client

    def _read(self, url, params=None):
        try:
            response = self.client.get(url, params=params, follow_redirects=False)
            if response.status_code == 404:
                return None
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, dict) or "data" not in payload:
                raise ValueError("Missing JSON:API data")
            return payload
        except (httpx.HTTPError, ValueError) as error:
            raise RegistryUnavailable("GLEIF returned an unavailable or malformed result.") from error

    def find(self, query: Search):
        if query.lei:
            payload = self._read(f"{ROOT}/{query.lei}")
            rows = [payload["data"]] if payload and payload["data"] else []
        else:
            payload = self._read(
                ROOT,
                {"filter[entity.legalName]": query.name, "page[size]": "20"},
            )
            if payload is None:
                raise RegistryUnavailable("GLEIF search collection is unavailable.")
            if payload.get("links", {}).get("next"):
                raise ValueError("Too many registry candidates. Narrow the legal name or enter an LEI.")
            rows = payload["data"]
        found = {}
        for row in rows:
            entity = row.get("attributes", {}).get("entity", {})
            name = entity.get("legalName", {}).get("name", "")
            jurisdiction = entity.get("jurisdiction") or ""
            lei = row.get("id")
            if not valid_lei(lei) or not isinstance(name, str) or not name or len(name) > 256:
                continue
            if query.lei and lei != query.lei:
                raise RegistryUnavailable("The returned LEI did not match the lookup.")
            if query.name and (
                normalize(query.name) not in normalize(name)
                or not (jurisdiction == query.jurisdiction or jurisdiction.startswith(query.jurisdiction + "-"))
            ):
                continue
            found[lei] = Entity(lei, name, jurisdiction, now())
        return sorted(found.values(), key=lambda item: (item.name, item.lei))

    def relationships(self, lei):
        if not valid_lei(lei):
            raise ValueError("Invalid confirmed LEI.")
        evidence = []
        for endpoint, kind in RELATIONS.items():
            url = f"{ROOT}/{lei}/{endpoint}-parent-relationship"
            payload = self._read(url)
            if not payload or not payload["data"]:
                continue
            row = payload["data"]
            attrs = row.get("attributes", {})
            relation = attrs.get("relationship", {})
            if relation.get("status") != "ACTIVE":
                continue
            start = relation.get("startNode", {})
            end = relation.get("endNode", {})
            if (
                relation.get("type") != kind or start.get("id") != lei or start.get("type") != "LEI"
                or end.get("type") != "LEI" or not valid_lei(end.get("id")) or end["id"] == lei
                or not row.get("id")
            ):
                raise RegistryUnavailable("GLEIF returned an inconsistent relationship.")
            registration = attrs.get("registration", {})
            if registration.get("status") not in ("PUBLISHED", "LAPSED"):
                continue
            evidence.append(Relationship(lei, end["id"], kind, row["id"], url, now(),
                                         attrs.get("validFrom"), registration.get("corroborationLevel")))
        return evidence
