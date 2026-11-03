"""Validate order, reservation and inventory consistency before SQL generation."""

import argparse
import hashlib
import json
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

from migration.phase6.catalog_loader import verify_bundle
from migration.phase6.operations_inventory_loader import read_jsonl

ACTIVE = {"PENDING", "CONFIRMED", "PREPARING"}
HISTORICAL = {"READY", "OUT_FOR_DELIVERY", "DELIVERED", "CANCELLED"}


def inspect_bundle(bundle, expected_source_sha256, config_path):
    config = json.loads(config_path.read_text())
    manifest = verify_bundle(bundle, expected_source_sha256)[0]
    for name in ("orders.jsonl", "order_items.jsonl", "inventories.jsonl"):
        if hashlib.sha256((bundle/name).read_bytes()).hexdigest()!=manifest.get("output_sha256",{}).get(name): raise ValueError(f"bundle hash mismatch: {name}")
    orders = read_jsonl(bundle / "orders.jsonl")
    lines = read_jsonl(bundle / "order_items.jsonl")
    inventories = read_jsonl(bundle / "inventories.jsonl")
    line_groups = defaultdict(list)
    for row in lines:
        payload = row["payload"]
        if not payload.get("product_external_id") or Decimal(payload["quantity"]) <= 0:
            raise ValueError("order item product and positive quantity required")
        line_groups[payload["order_external_id"]].append(payload)
    active_totals = defaultdict(Decimal); classifications = defaultdict(int)
    order_ids = set()
    for row in orders:
        payload = row["payload"]; external = payload.get("external_reference")
        if not external or external in order_ids: raise ValueError("order external references must be unique")
        order_ids.add(external); status = payload.get("status")
        if status not in ACTIVE | HISTORICAL: raise ValueError(f"unsupported order status: {status}")
        if not payload.get("node_id") or not payload.get("customer_external_id"): raise ValueError("order node and customer required")
        if not line_groups.get(external): raise ValueError(f"order items missing: {external}")
        if status in ACTIVE:
            if payload.get("inventory_committed") is not True: raise ValueError(f"active order without committed reservation: {external}")
            for line in line_groups[external]: active_totals[(payload["node_id"], line["product_external_id"])] += Decimal(line["quantity"])
            classifications["active_with_reservation"] += 1
        else:
            if status != "CANCELLED" and payload.get("inventory_committed") is True: raise ValueError(f"historical order still reserves inventory: {external}")
            classifications["historical_or_routed"] += 1
    inventory_totals = {}
    for row in inventories:
        payload = row["payload"]
        key = (payload["node_id"], row["source_id"])
        if key in inventory_totals: raise ValueError("duplicate inventory scope")
        inventory_totals[key] = Decimal(payload["reserved"])
    differences = []
    for scope in sorted(set(active_totals) | set(inventory_totals)):
        expected = active_totals.get(scope, Decimal(0)); actual = inventory_totals.get(scope, Decimal(0))
        if expected != actual: differences.append({"node_id":scope[0],"product_external_id":scope[1],"orders_reserved":str(expected),"inventory_reserved":str(actual)})
    if differences: raise ValueError("reservation reconciliation failed: " + json.dumps(differences, sort_keys=True))
    orphan_lines = sorted(set(line_groups) - order_ids)
    if orphan_lines: raise ValueError("orphan order items: " + ",".join(orphan_lines))
    return {"wave":"orders-preflight","source_sha256":manifest["source_sha256"],"orders":len(orders),"items":len(lines),"active_with_reservation":classifications["active_with_reservation"],"historical_or_routed":classifications["historical_or_routed"],"reservation_scopes":len(active_totals),"reconciled":True,"database_writes":False}


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);args=parser.parse_args()
    print(json.dumps(inspect_bundle(args.bundle,args.expected_source_sha256,args.config),indent=2,sort_keys=True))


if __name__=="__main__": main()
