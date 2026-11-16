#!/usr/bin/env python3
"""SPEC-PLAT-04 R50, R52, R62, D8: the Debezium outbox connector configs (debezium/*-outbox.json).

Moved from case-service's DebeziumConnectorConfigTest when the platform got its own repository (ADR-017).
Each row is (example id, file, key, expected value); table rows check the include list. Exit code = failures.
"""
import json
import re
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "debezium"

SETTINGS = [
    ("PLAT-D8 {svc}: pgoutput", "plugin.name", "pgoutput"),
    ("PLAT-D8 {svc}: dedicated CDC role", "database.user", "gc_cdc"),
    ("PLAT-D8 {svc}: password from the environment", "database.password", "${env:GC_CDC_PASSWORD}"),
    ("PLAT-R52 {svc}: migration-owned publication", "publication.name", "gc_outbox"),
    ("PLAT-R52 {svc}: never auto-create (FOR ALL TABLES)", "publication.autocreate.mode", "disabled"),
    ("PLAT-R50 {svc}: outbox event router", "transforms.outbox.type", "io.debezium.transforms.outbox.EventRouter"),
    ("PLAT-R50 {svc}: key = aggregate id", "transforms.outbox.table.field.event.key", "aggregate_id"),
    ("PLAT-R50 {svc}: topic per aggregate", "transforms.outbox.route.by.field", "aggregate_type"),
    ("PLAT-R50 {svc}: topic name", "transforms.outbox.route.topic.replacement", "{svc}.${routedByValue}.events"),
    ("PLAT-R50 {svc}: headers", "transforms.outbox.table.fields.additional.placement",
     "event_type:header:eventType,trace_id:header:traceId,occurred_at:header:occurredAt"),
    ("PLAT-R50 {svc}: string keys", "key.converter", "org.apache.kafka.connect.storage.StringConverter"),
    ("PLAT-R50 {svc}: plain JSON values", "value.converter.schemas.enable", "false"),
    ("PLAT-R62 {svc}: heartbeat every 10 s", "heartbeat.interval.ms", "10000"),
]

TABLES = [
    ("PLAT-R52 case: shard outbox captured", "case", "in_s01.outbox", True),
    ("PLAT-R52 case: BR shard outbox captured", "case", "br_s63.outbox", True),
    ("PLAT-R52 case: cases not captured", "case", "in_s01.cases", False),
    ("PLAT-R62 case: heartbeat not routed", "case", "msg.cdc_heartbeat", False),
    ("PLAT-R52 iam: outbox captured", "iam", "iam.outbox", True),
    ("PLAT-R52 iam: users not captured", "iam", "iam.user_account", False),
    ("PLAT-R62 iam: heartbeat not routed", "iam", "iam.cdc_heartbeat", False),
    ("PLAT-R52 grower: shard outbox captured", "grower", "in_s39.outbox", True),
    ("PLAT-R52 grower: growers not captured", "grower", "in_s39.grower", False),
    ("PLAT-R52 grower: user links not captured", "grower", "dir.grower_user_link", False),
    ("PLAT-R62 grower: heartbeat not routed", "grower", "msg.cdc_heartbeat", False),
]


def config(svc: str) -> dict:
    return json.loads((DIR / f"{svc}-outbox.json").read_text(encoding="utf-8"))["config"]


def main() -> int:
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  ({detail})"))
        failures += 0 if ok else 1

    for svc in ("case", "iam", "grower"):
        cfg = config(svc)
        for name, key, expected in SETTINGS:
            expected = expected.replace("{svc}", svc)
            check(name.replace("{svc}", svc), cfg.get(key) == expected, f"{key}={cfg.get(key)!r}, expected {expected!r}")
        heartbeat = cfg.get("heartbeat.action.query", "")
        check(f"PLAT-R62 {svc}: heartbeat upsert", "cdc_heartbeat" in heartbeat and "ON CONFLICT" in heartbeat, heartbeat)
    for name, svc, table, captured in TABLES:
        include = re.compile(config(svc)["table.include.list"])
        check(name, bool(include.fullmatch(table)) == captured, f"{table} captured={not captured}")
    print(f"connector check: {failures} failure(s)")
    return failures


if __name__ == "__main__":
    sys.exit(main())
