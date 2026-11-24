"""Generate a reproducible JSON snapshot for the MiniBank SQL loader."""

import argparse
import hashlib
import json
import random
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


REASONS = {
    "BEN_VERIFICATION": "Beneficiary details pending verification",
    "PAYMENT_REVIEW": "Payment details pending operational review",
    "PROCESSING_EXCEPTION": "Payment processing exception pending review",
}
FIXED_AS_OF = "2026-11-20T12:00:00Z"


def utc(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def generate(seed, as_of):
    rng = random.Random(seed)
    customers = [
        {"customerId": f"CUS-{n:04}", "alias": f"Synthetic customer {n:03}",
         "segment": rng.choice(("Retail", "Small business", "Commercial"))}
        for n in range(1, 101)
    ]
    accounts = [
        {"accountId": f"ACC-{n:04}", "customerId": f"CUS-{(n - 1) % 100 + 1:04}",
         "currency": "USD"}
        for n in range(1, 151)
    ]
    beneficiaries = [
        {"beneficiaryId": f"BEN-{n:04}", "alias": f"Synthetic beneficiary {n:03}",
         "countryCode": rng.choice(("US", "CA", "GB"))}
        for n in range(1, 61)
    ]
    payments, events = [], []
    for n in range(1001, 2001):
        payment_id = f"PAY-{n}"
        account = rng.choice(accounts)["accountId"]
        beneficiary = rng.choice(beneficiaries)["beneficiaryId"]
        cents = rng.randrange(100, 2_000_000)
        created = as_of - timedelta(hours=rng.randrange(4, 24 * 60), minutes=rng.randrange(60))
        route = rng.randrange(5)
        reason = rng.choice(tuple(REASONS))
        if n in (1042, 1043):
            account = "ACC-0001" if n == 1042 else "ACC-0101"
            beneficiary = "BEN-0001"
            created = as_of - timedelta(days=2, hours=n - 1042)
            reason = "BEN_VERIFICATION"
            route = 0
        if n == 1042:
            cents = 25000
        if route == 0:
            statuses = ("Submitted", "On hold")
        elif route == 1:
            statuses = ("Submitted", "On hold", "Processing", "Settled")
        else:
            statuses = ("Submitted", "Processing", "Settled")
        for sequence, status in enumerate(statuses, 1):
            events.append({
                "eventId": f"{payment_id}-{sequence}", "paymentId": payment_id,
                "sequenceNo": sequence, "eventUtc": utc(created + timedelta(hours=sequence - 1)),
                "status": status, "reasonCode": reason if status == "On hold" else None,
            })
        last = events[-1]
        payments.append({
            "paymentId": payment_id, "accountId": account, "beneficiaryId": beneficiary,
            "amount": f"{cents // 100}.{cents % 100:02}00", "currency": "USD",
            "createdUtc": utc(created), "status": last["status"], "reasonCode": last["reasonCode"],
            "holdReason": REASONS[last["reasonCode"]] if last["reasonCode"] else None,
            "asOfUtc": utc(as_of),
        })
    return dict(Customer=customers, Account=accounts, Beneficiary=beneficiaries,
                Payment=payments, PaymentEvent=events)


def verify(snapshot):
    customer_ids = {row["customerId"] for row in snapshot["Customer"]}
    accounts = {row["accountId"]: row["customerId"] for row in snapshot["Account"]}
    beneficiary_ids = {row["beneficiaryId"] for row in snapshot["Beneficiary"]}
    payments = {row["paymentId"]: row for row in snapshot["Payment"]}
    event_ids = {row["eventId"] for row in snapshot["PaymentEvent"]}
    assert tuple(map(len, (customer_ids, accounts, beneficiary_ids, payments))) == (100, 150, 60, 1000)
    assert len(event_ids) == len(snapshot["PaymentEvent"])
    assert set(accounts.values()) <= customer_ids
    assert all(p["accountId"] in accounts and p["beneficiaryId"] in beneficiary_ids for p in payments.values())
    counts = Counter(event["paymentId"] for event in snapshot["PaymentEvent"])
    assert counts.keys() == payments.keys() and all(2 <= size <= 4 for size in counts.values())
    last_events = {}
    for event in snapshot["PaymentEvent"]:
        previous = last_events.get(event["paymentId"])
        assert event["sequenceNo"] == (previous["sequenceNo"] + 1 if previous else 1)
        assert previous is None or previous["eventUtc"] < event["eventUtc"]
        assert event["eventUtc"] <= payments[event["paymentId"]]["asOfUtc"]
        last_events[event["paymentId"]] = event
    for payment_id, payment in payments.items():
        assert (payment["status"], payment["reasonCode"]) == (
            last_events[payment_id]["status"], last_events[payment_id]["reasonCode"]
        )
    first, second = payments["PAY-1042"], payments["PAY-1043"]
    assert (first["currency"], first["amount"], first["status"], first["reasonCode"], first["holdReason"]) == (
        "USD", "250.0000", "On hold", "BEN_VERIFICATION", REASONS["BEN_VERIFICATION"]
    )
    assert second["status"] == "On hold" and second["beneficiaryId"] == first["beneficiaryId"]
    assert first["accountId"] != second["accountId"]
    assert accounts[first["accountId"]] == accounts[second["accountId"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--as-of", default=FIXED_AS_OF)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    as_of = datetime.fromisoformat(args.as_of.replace("Z", "+00:00"))
    if as_of.utcoffset() != timedelta(0) or as_of.microsecond:
        parser.error("--as-of must be in UTC with whole-second precision")
    snapshot = generate(args.seed, as_of)
    verify(snapshot)
    encoded = (json.dumps(snapshot, ensure_ascii=True, separators=(",", ":")) + "\n").encode("utf-8")
    args.output.write_bytes(encoded)
    print(json.dumps({"counts": {name: len(rows) for name, rows in snapshot.items()},
                      "sha256": hashlib.sha256(encoded).hexdigest()}))


if __name__ == "__main__":
    main()
