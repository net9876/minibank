import argparse
import asyncio
import json
import os
from types import SimpleNamespace
from uuid import uuid4

import httpx
from azure.ai.projects import AIProjectClient
from azure.ai.projects.aio import AIProjectClient as AsyncProjectClient
from azure.identity import AzureCliCredential
from azure.identity.aio import AzureCliCredential as AsyncCliCredential
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider

from .foundry import FoundryStages, provision
from .graph import PaymentGraph
from .investigation import Investigations
from .queue import process_queue
from .registry import Gleif, Search
from .store import Dataverse, MemoryStore


def parser():
    root = argparse.ArgumentParser(description="Run the MiniBank counterparty investigation.")
    root.add_argument("--endpoint", default=os.environ.get("FOUNDRY_PROJECT_ENDPOINT"))
    commands = root.add_subparsers(dest="action", required=True)
    deploy = commands.add_parser("agents")
    deploy.add_argument("--model", default="gpt-4.1-mini")
    deploy.add_argument("--apply", action="store_true")
    start = commands.add_parser("start")
    start.add_argument("--id", default=None)
    identifier = start.add_mutually_exclusive_group(required=True)
    identifier.add_argument("--lei")
    identifier.add_argument("--name")
    start.add_argument("--jurisdiction")
    resume = commands.add_parser("resume")
    resume.add_argument("--id", required=True)
    commands.add_parser("worker-once")
    return root


class StaticDataverseToken:
    def get_token(self, scope):
        return SimpleNamespace(token=os.environ["MINIBANK_DATAVERSE_TOKEN"])


def store():
    origin = os.getenv("MINIBANK_DATAVERSE_URL")
    if not origin:
        return MemoryStore()
    credentials = StaticDataverseToken() if os.getenv("MINIBANK_DATAVERSE_TOKEN") else AzureCliCredential()
    return Dataverse(origin, credentials, os.environ["MINIBANK_DATAVERSE_ENTITY_SET"], "mbank")


async def run(project, args):
    versions = json.loads(os.environ["MINIBANK_COUNTERPARTY_AGENT_VERSIONS"])
    rows = store()
    if args.action in ("resume", "worker-once") and isinstance(rows, MemoryStore):
        raise ValueError("This command requires persisted Dataverse rows.")
    key = getattr(args, "id", None) or str(uuid4())
    with httpx.Client(timeout=12.0, follow_redirects=False) as client:
        investigations = Investigations(rows, Gleif(client), PaymentGraph(), FoundryStages(project, versions))
        if args.action == "worker-once":
            return await process_queue(rows, investigations)
        if args.action == "start":
            row = await investigations.start(key, Search(
                lei=(args.lei or "").strip().upper(),
                name=(args.name or "").strip(),
                jurisdiction=(args.jurisdiction or "").strip().upper(),
            ))
            if row["status"] != "confirmed":
                return row
        return await investigations.complete(key)


def main():
    args = parser().parse_args()
    if not args.endpoint:
        raise ValueError("Set FOUNDRY_PROJECT_ENDPOINT or use --endpoint.")
    if args.action == "agents":
        with AIProjectClient(endpoint=args.endpoint, credential=AzureCliCredential()) as project:
            result = provision(project, args.model, args.apply)
    else:
        provider = TracerProvider(resource=Resource.create({"service.name": "minibank-counterparty"}))
        if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
            from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
            provider.add_span_processor(BatchSpanProcessor(AzureMonitorTraceExporter()))
        trace.set_tracer_provider(provider)
        try:
            result = asyncio.run(run_traced(args))
        finally:
            provider.force_flush()
            provider.shutdown()
    print(json.dumps(result, indent=2, ensure_ascii=False))


async def run_traced(args):
    async with AsyncCliCredential() as credential, AsyncProjectClient(
        endpoint=args.endpoint, credential=credential
    ) as project:
        with trace.get_tracer("minibank.counterparty").start_as_current_span("counterparty_investigation"):
            return await run(project, args)


if __name__ == "__main__":
    main()
