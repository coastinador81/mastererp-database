"""Compare the PII-free DEV snapshot with the signed Phase 6 bundle."""

import argparse
import hashlib
import json
from collections import Counter
from decimal import Decimal
from pathlib import Path


KINDS = ("categories", "products", "customers", "nodes", "inventories",
         "drivers", "orders", "routes", "stores")


def _rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _decimal(value):
    return format(Decimal(str(value)), "f")


def _fingerprint(value):
    body = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(body.encode()).hexdigest()


def _expected(bundle):
    rows = {name: _rows(bundle / f"{name}.jsonl") for name in KINDS}
    lines = _rows(bundle / "order_items.jsonl")
    line_counts = Counter(row["payload"]["order_external_id"] for row in lines)
    routed_drivers = {row["payload"].get("driver_external_id") for row in rows["routes"]}
    expected = {
        "categories": [{"source_id": row["source_id"], "status": row["payload"]["status"]}
                       for row in rows["categories"]],
        "products": [{"source_id": row["source_id"], "status": row["payload"]["status"]}
                     for row in rows["products"]],
        "customers": [{"source_id": row["source_id"]} for row in rows["customers"]],
        "nodes": [{"target_id": row["target_id"], "status": row["payload"]["status"]}
                  for row in rows["nodes"]],
        "inventories": [{"node_id": row["payload"]["node_id"], "product_source_id": row["source_id"],
                         "stock": _decimal(row["payload"]["stock"]),
                         "reserved": _decimal(row["payload"]["reserved"])}
                        for row in rows["inventories"]],
        "drivers": [{"source_id": row["source_id"], "status": row["payload"]["status"],
                     "availability": ("AVAILABLE" if row["payload"].get("route_external_id")
                                      or row["source_id"] in routed_drivers else row["payload"]["availability"]),
                     "node_count": len(row["payload"].get("node_ids", []))}
                    for row in rows["drivers"]],
        "orders": [{"source_id": row["source_id"], "status": row["payload"]["status"],
                    "currency": row["payload"]["currency"],
                    "subtotal": _decimal(row["payload"]["subtotal"]),
                    "delivery_fee": _decimal(row["payload"]["delivery_fee"]),
                    "total": _decimal(Decimal(row["payload"]["subtotal"]) + Decimal(row["payload"]["delivery_fee"])),
                    "line_count": line_counts[row["source_id"]]} for row in rows["orders"]],
        "routes": [{"status": row["payload"]["status"], "node_id": row["payload"]["node_id"],
                    "driver_source_id": row["payload"].get("driver_external_id") or "",
                    "stop_count": len(row["payload"].get("order_external_ids", []))}
                   for row in rows["routes"]],
        "stores": [{"domain": row["payload"]["domain"], "status": row["payload"]["status"],
                    "node_id": row["payload"]["node_id"]} for row in rows["stores"]],
    }
    return {name: sorted(values, key=lambda value: json.dumps(value, sort_keys=True))
            for name, values in expected.items()}


def _actual(response):
    snapshot = response.get("snapshot")
    if response.get("status") != "succeeded" or response.get("read_only") is not True or not isinstance(snapshot, dict):
        raise ValueError("invalid DEV snapshot envelope")
    result = {}
    for name in KINDS:
        if not isinstance(snapshot.get(name), list): raise ValueError("DEV snapshot kind missing: " + name)
        values = snapshot[name]
        for value in values:
            for field in ("stock", "reserved", "subtotal", "delivery_fee", "total"):
                if field in value: value[field] = _decimal(value[field])
        result[name] = sorted(values, key=lambda value: json.dumps(value, sort_keys=True))
    return result


def reconcile(bundle, snapshot_path):
    manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
    response = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if manifest.get("source_sha256") != response.get("source_sha256"):
        raise ValueError("source SHA-256 mismatch")
    expected, actual = _expected(bundle), _actual(response)
    differences = {}
    for name in KINDS:
        expected_count, actual_count = Counter(map(_fingerprint, expected[name])), Counter(map(_fingerprint, actual[name]))
        missing = list((expected_count - actual_count).elements())
        unexpected = list((actual_count - expected_count).elements())
        if missing or unexpected:
            differences[name] = {"missing_fingerprints": sorted(missing),
                                 "unexpected_fingerprints": sorted(unexpected)}
    return {"ok": not differences, "source_sha256": manifest["source_sha256"],
            "counts": {name: {"expected": len(expected[name]), "actual": len(actual[name])} for name in KINDS},
            "fingerprints": {name: {"expected": _fingerprint(expected[name]),
                                     "actual": _fingerprint(actual[name])} for name in KINDS},
            "differences": differences}


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True); parser.add_argument("--report", type=Path)
    args = parser.parse_args(); report = reconcile(args.bundle, args.snapshot)
    body = json.dumps(report, indent=2, sort_keys=True) + "\n"; print(body, end="")
    if args.report: args.report.write_text(body, encoding="utf-8")
    if not report["ok"]: raise SystemExit(3)


if __name__ == "__main__": main()
