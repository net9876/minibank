from dataclasses import asdict
from uuid import UUID

from .registry import Entity, RegistryUnavailable, Search, now, valid_lei


class Conflict(RuntimeError):
    pass


class Investigations:
    def __init__(self, store, registry, graph, agents):
        self.store = store
        self.registry = registry
        self.graph = graph
        self.agents = agents

    async def start(self, key, query: Search):
        key = str(UUID(key))
        request = asdict(query)
        self.store.create(key, {"id": key, "request": request, "status": "resolving", "traces": []})
        row, revision = self.store.get(key)
        if row["request"] != request:
            raise Conflict("This investigation ID is already bound to a different request.")
        if row["status"] != "resolving":
            return row
        try:
            candidates, trace = await self.agents.run(
                "entity-research", key, "resolve_identity", lambda: self.registry.find(query),
                lambda rows: {"candidateLeis": [item.lei for item in rows]},
            )
        except RegistryUnavailable:
            return self._save(key, revision, row | {"status": "resolving", "error": "registry_unavailable"})
        resolution = {
            "candidates": [asdict(item) | {"source": item.source} for item in candidates],
            "traces": [*row["traces"], trace],
            "status": {0: "identity_not_found", 1: "confirmed"}.get(len(candidates), "awaiting_approval"),
            "confirmedLei": candidates[0].lei if len(candidates) == 1 else None,
            "error": None,
        }
        return self._save(key, revision, row | resolution)

    def reserve_approval(self, key, flow_run, expected_actor):
        key, flow_run, expected_actor = str(UUID(key)), str(UUID(flow_run)), str(UUID(expected_actor))
        row, revision = self.store.get(key)
        if row["status"] != "awaiting_approval":
            raise Conflict("Only an ambiguous investigation can be assigned for approval.")
        reservation = {"flowRun": flow_run, "expectedActor": expected_actor}
        if not row.get("approval"):
            row = self._save(key, revision, row | {"approval": reservation})
        if any((row.get("approval") or {}).get(field) != value for field, value in reservation.items()):
            raise Conflict("A different flow already reserved this investigation.")
        return row

    def bind_approval(self, key, flow_run, approval_id):
        key, flow_run, approval_id = str(UUID(key)), str(UUID(flow_run)), str(UUID(approval_id))
        row, revision = self.store.get(key)
        reservation = row.get("approval") or {}
        if row["status"] != "awaiting_approval" or reservation.get("flowRun") != flow_run:
            raise Conflict("The approval is not reserved by this flow.")
        if not reservation.get("approvalId"):
            row = self._save(key, revision, row | {"approval": reservation | {"approvalId": approval_id}})
        if (row.get("approval") or {}).get("approvalId") != approval_id:
            raise Conflict("A different Teams approval ID is already assigned.")
        return row

    def approve(self, key, selected_lei, approval_id, actor):
        key = str(UUID(key))
        approval_id, actor = str(UUID(approval_id)), str(UUID(actor))
        if not valid_lei(selected_lei):
            raise ValueError("Approval ID, responder and a valid candidate LEI are required.")
        row, revision = self.store.get(key)
        decision = {"approvalId": approval_id, "lei": selected_lei, "actor": actor}
        existing = row.get("decision")
        if existing:
            if all(existing.get(field) == value for field, value in decision.items()):
                return row
            raise Conflict("A different approval decision is already recorded.")
        reservation = row.get("approval") or {}
        if (row["status"] != "awaiting_approval" or reservation.get("approvalId") != approval_id
                or reservation.get("expectedActor") != actor
                or selected_lei not in {item["lei"] for item in row["candidates"]}):
            raise Conflict("The selected LEI is not an eligible candidate for this investigation.")
        replacement = row | {"decision": decision | {"recordedAt": now()},
                             "status": "confirmed", "confirmedLei": selected_lei}
        outcome = self._save(key, revision, replacement)
        if any((outcome.get("decision") or {}).get(field) != value for field, value in decision.items()):
            raise Conflict("A different approval decision was recorded concurrently.")
        return outcome

    async def complete(self, key):
        key = str(UUID(key))
        row, revision = self.store.get(key)
        if row["status"] != "confirmed":
            return row
        confirmed_data = next(item for item in row["candidates"] if item["lei"] == row["confirmedLei"])
        confirmed = Entity(**{field: confirmed_data[field] for field in ("lei", "name", "jurisdiction", "observed_at")})
        trace_list = list(row["traces"])
        try:
            relationships, trace = await self.agents.run(
                "entity-research", key, "read_confirmed_relationships",
                lambda: self._registry_evidence(confirmed),
                lambda result: {"relationships": [
                    {"child": item.child, "parent": item.parent, "type": item.kind}
                    for item in result[1]
                ]},
            )
            trace_list.append(trace)
            entities, edges = relationships
            matches, trace = await self.agents.run(
                "relationship-analyst", key, "lookup_confirmed_payments",
                lambda: self.graph.find(confirmed, entities, edges),
                lambda rows: {"syntheticMatches": [
                    {"paymentId": item["payment"]["paymentId"], "paidLei": item["payment"]["beneficiaryLei"],
                     "evidenceCount": len(item["chain"])}
                    for item in rows
                ]},
            )
            trace_list.append(trace)
        except RegistryUnavailable:
            return self._save(key, revision, row | {"traces": trace_list, "error": "registry_unavailable"})

        result = {
            "matches": matches,
            "registryCoverage": {
                "relationshipLeis": sorted(entities),
                "noPublishedActiveParentFor": sorted(set(entities) - {item.child for item in edges}),
            },
            "ontologyVersion": self.graph.ontology_version,
            "scope": "Isolated synthetic lab payments and observed accounting-consolidation records.",
            "limitation": "Missing registry parent data does not establish the absence of a parent. "
                          "Accounting consolidation does not establish beneficial ownership.",
        }
        return self._save(key, revision, row | {"status": "completed", "outcome": result, "traces": trace_list, "error": None})

    def _registry_evidence(self, confirmed):
        entities = {confirmed.lei: confirmed}
        edges = self.registry.relationships(confirmed.lei)
        # Related fixture entities are enumerated only after the identity gate.
        for lei in self.graph.paid_entity_ids():
            if lei == confirmed.lei:
                continue
            matches = self.registry.find(Search(lei=lei))
            if len(matches) == 1:
                entities[lei] = matches[0]
                edges.extend(self.registry.relationships(lei))
        return entities, edges

    def _save(self, key, revision, next_row):
        if self.store.replace(key, revision, next_row):
            return next_row
        return self.store.get(key)[0]
