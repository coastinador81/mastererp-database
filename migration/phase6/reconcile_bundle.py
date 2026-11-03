"""Compare a transformed source bundle with a canonical target snapshot."""

import argparse
import hashlib
import json
from pathlib import Path


KINDS = ("categories", "products", "nodes", "inventories", "drivers", "orders", "order_items", "routes")


def read_rows(path):
    if not path.exists(): return {}
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip(): continue
        item = json.loads(line)
        key = item.get("source_id")
        if not key: raise ValueError(f"source_id missing in {path.name}")
        if key in rows: raise ValueError(f"duplicate source_id {key} in {path.name}")
        rows[key] = item
    return rows


def fingerprint(item):
    selected = {"target_id": item.get("target_id"), "payload": item.get("payload")}
    body = json.dumps(selected, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(body.encode()).hexdigest()


def reconcile(source, target):
    report = {"matched": 0, "missing": [], "unexpected": [], "mismatched": []}
    for kind in KINDS:
        expected, actual = read_rows(source / f"{kind}.jsonl"), read_rows(target / f"{kind}.jsonl")
        for key in sorted(expected.keys() - actual.keys()): report["missing"].append(f"{kind}:{key}")
        for key in sorted(actual.keys() - expected.keys()): report["unexpected"].append(f"{kind}:{key}")
        for key in sorted(expected.keys() & actual.keys()):
            if fingerprint(expected[key]) == fingerprint(actual[key]): report["matched"] += 1
            else: report["mismatched"].append(f"{kind}:{key}")
    report["ok"] = not any(report[name] for name in ("missing", "unexpected", "mismatched"))
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-bundle", type=Path, required=True)
    parser.add_argument("--target-snapshot", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = reconcile(args.source_bundle, args.target_snapshot)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    if not report["ok"]: raise SystemExit(3)


if __name__ == "__main__": main()
