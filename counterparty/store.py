from copy import deepcopy
from threading import Lock
import json
import re
from urllib.parse import urlsplit
from uuid import UUID

import httpx


class MemoryStore:
    """Fixture store with the same conditional write contract as Dataverse."""

    def __init__(self):
        self.rows = {}
        self.lock = Lock()

    def create(self, key, row):
        with self.lock:
            self.rows.setdefault(key, (deepcopy(row), 1))

    def get(self, key):
        with self.lock:
            row, version = self.rows[key]
            return deepcopy(row), version

    def replace(self, key, revision, row):
        with self.lock:
            if self.rows[key][1] != revision:
                return False
            self.rows[key] = deepcopy(row), revision + 1
            return True


class Dataverse:
    def __init__(self, url, credential, entity_set, prefix):
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".dynamics.com")
                or parsed.netloc != parsed.hostname or parsed.path not in ("", "/")
                or parsed.query or parsed.fragment):
            raise ValueError("Use the HTTPS origin for the Dataverse environment.")
        if any(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name) is None for name in (entity_set, prefix)):
            raise ValueError("Invalid Dataverse metadata names.")
        self.origin = url.rstrip("/")
        self.credential = credential
        self.entity_set = entity_set
        self.status = prefix + "_status"
        self.document = prefix + "_statejson"
        self.name = prefix + "_name"
        self.client = httpx.Client(timeout=20.0, follow_redirects=False)

    def request(self, method, resource, additional=None, payload=None, params=None):
        token = self.credential.get_token(f"{self.origin}/.default").token
        headers = {"Authorization": f"Bearer {token}", "OData-Version": "4.0", "Accept": "application/json"}
        headers.update(additional or {})
        return self.client.request(method, f"{self.origin}/api/data/v9.2/{resource}", headers=headers,
                                   json=payload, params=params)

    def _exchange(self, method, key, additional=None, row=None):
        payload = None
        if row is not None:
            payload = {
                self.name: f"Counterparty {key}",
                self.status: row["status"],
                self.document: json.dumps(row, ensure_ascii=False, separators=(",", ":")),
            }
        return self.request(method, f"{self.entity_set}({UUID(key)})", additional, payload)

    def create(self, key, row):
        response = self._exchange("PATCH", key, {"If-None-Match": "*"}, row)
        if response.status_code != 412:
            response.raise_for_status()

    def get(self, key):
        response = self._exchange("GET", key)
        response.raise_for_status()
        result = response.json()
        return json.loads(result[self.document]), result["@odata.etag"]

    def replace(self, key, revision, row):
        response = self._exchange("PATCH", key, {"If-Match": revision}, row)
        if response.status_code == 412:
            return False
        response.raise_for_status()
        return True
