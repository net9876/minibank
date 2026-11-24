import json
from uuid import UUID

from .registry import Search

REQUESTS = "mbank_counterpartyrequests"
REQUEST_ID = "mbank_counterpartyrequestid"
INVESTIGATION_ID = "mbank_counterpartyinvestigationid"


async def process_queue(store, investigations):
    """Run one bounded worker pass over Dataverse rows."""
    pending = store.request("GET", REQUESTS, params={
        "$select": f"{REQUEST_ID},mbank_requestjson",
        "$filter": "mbank_requeststatus eq 'queued'",
        "$orderby": "createdon asc",
        "$top": "10",
    })
    pending.raise_for_status()
    results = []
    for staged in pending.json()["value"]:
        key = str(UUID(staged[REQUEST_ID]))
        try:
            query = Search(**json.loads(staged["mbank_requestjson"]))
        except (TypeError, ValueError):
            result, stage_status = {"id": key, "status": "invalid_request"}, "invalid"
        else:
            result = await investigations.start(key, query)
            if result["status"] == "confirmed":
                result = await investigations.complete(key)
            stage_status = "submitted" if result["status"] != "resolving" else "queued"
        if stage_status != "queued":
            update = store.request("PATCH", f"{REQUESTS}({key})", {"If-Match": staged["@odata.etag"]},
                                   {"mbank_requeststatus": stage_status})
            if update.status_code != 412:
                update.raise_for_status()
        results.append({"id": key, "status": result["status"]})

    confirmed = store.request("GET", store.entity_set, params={
        "$select": INVESTIGATION_ID, "$filter": "mbank_status eq 'confirmed'", "$top": "10",
    })
    confirmed.raise_for_status()
    for row in confirmed.json()["value"]:
        key = row[INVESTIGATION_ID]
        if any(item["id"] == key for item in results):
            continue
        result = await investigations.complete(key)
        results.append({"id": key, "status": result["status"]})
    return results
