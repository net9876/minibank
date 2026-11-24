from dataclasses import asdict
from pathlib import Path
import json

from rdflib import Graph, Literal, Namespace, RDF, URIRef
from rdflib.namespace import OWL, PROV

MB = Namespace("https://minibank.example/ontology/")
LEIS = Namespace("https://api.gleif.org/api/v1/lei-records/")
FIBO = Namespace("https://spec.edmcouncil.org/fibo/ontology/BE/LegalEntities/LEIEntities/")
ASSETS = Path(__file__).parent


class PaymentGraph:
    def __init__(self, payment_file=ASSETS / "synthetic_payments.json"):
        self.payments = json.loads(payment_file.read_text(encoding="utf-8"))
        self.ontology = Graph().parse(ASSETS / "fibo_subset.ttl", format="turtle")
        self.ontology_version = str(self.ontology.value(MB.FiboSubset, OWL.versionIRI))
        if any(item["synthetic"] is not True for item in self.payments):
            raise ValueError("This lookup only accepts isolated synthetic payment records.")

    def paid_entity_ids(self):
        return sorted({item["beneficiaryLei"] for item in self.payments})

    def find(self, confirmed, entities, relationships):
        graph = Graph()
        graph += self.ontology
        rdf_relations = {}
        for entity in entities.values():
            uri = LEIS[entity.lei]
            graph.add((uri, RDF.type, FIBO.LEIRegisteredEntity))
            graph.add((uri, PROV.wasDerivedFrom, URIRef(entity.source)))
            graph.add((uri, PROV.generatedAtTime, Literal(entity.observed_at)))
        for item in relationships:
            graph.add((LEIS[item.child], MB[item.kind], LEIS[item.parent]))
            source = URIRef(item.source)
            graph.add((source, RDF.type, FIBO.RelationshipRecord))
            graph.add((source, MB.child, LEIS[item.child]))
            graph.add((source, MB.parent, LEIS[item.parent]))
            graph.add((source, MB.relationshipType, Literal(item.kind)))
            graph.add((source, PROV.generatedAtTime, Literal(item.observed_at)))
            graph.add((source, MB.recordId, Literal(item.record_id)))
            rdf_relations[item.child, item.kind, item.parent] = item

        matches = []
        for payment in self.payments:
            paid_lei = payment["beneficiaryLei"]
            if paid_lei not in entities:
                continue
            predicate = MB.paidTo
            payment_uri = URIRef("urn:minibank:synthetic:" + payment["paymentId"])
            graph.add((payment_uri, predicate, LEIS[paid_lei]))
            graph.add((payment_uri, MB.synthetic, Literal(True)))
            paid_lei = str(graph.value(payment_uri, predicate)).removeprefix(str(LEIS))
            chain = self._chain(graph, confirmed.lei, paid_lei, rdf_relations)
            if chain is not None:
                matches.append({"payment": payment, "paidEntity": asdict(entities[paid_lei]),
                                "paidEntitySource": entities[paid_lei].source, "chain": chain})
        return matches

    @staticmethod
    def _chain(graph, requested, paid, evidence):
        if requested == paid:
            return []
        for kind in ("IS_DIRECTLY_CONSOLIDATED_BY", "IS_ULTIMATELY_CONSOLIDATED_BY"):
            for child, parent in ((requested, paid), (paid, requested)):
                if (LEIS[child], MB[kind], LEIS[parent]) in graph:
                    return [asdict(evidence[child, kind, parent])]
        kind = "IS_ULTIMATELY_CONSOLIDATED_BY"
        left = set(graph.objects(LEIS[requested], MB[kind]))
        right = set(graph.objects(LEIS[paid], MB[kind]))
        parents = left & right
        if len(parents) == 1:
            parent = str(next(iter(parents))).removeprefix(str(LEIS))
            return [asdict(evidence[lei, kind, parent]) for lei in (requested, paid)]
        return None
