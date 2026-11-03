"""Build restartable loader SQL for Nodes and unreserved Inventory."""

import argparse
import hashlib
import json
import re
import uuid
from decimal import Decimal, InvalidOperation
from pathlib import Path

from migration.phase6.catalog_loader import key, sql_literal


def read_jsonl(path):
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip(): continue
        item = json.loads(line)
        if not item.get("source_id") or not isinstance(item.get("payload"), dict): raise ValueError(f"invalid row {number} in {path.name}")
        rows.append(item)
    return rows


def verify_bundle(bundle, expected_source_sha256, config, allow_active_reservations=False):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256): raise ValueError("invalid source SHA-256")
    manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("errors") != 0: raise ValueError("bundle contains transformation errors")
    if manifest.get("source_sha256") != expected_source_sha256: raise ValueError("source SHA-256 mismatch")
    for name in ("nodes.jsonl", "inventories.jsonl"):
        if hashlib.sha256((bundle / name).read_bytes()).hexdigest() != manifest.get("output_sha256", {}).get(name): raise ValueError(f"bundle hash mismatch: {name}")
    nodes, inventories = read_jsonl(bundle / "nodes.jsonl"), read_jsonl(bundle / "inventories.jsonl")
    mapped_branches = set(config.get("node_map", {}).values())
    for row in nodes:
        payload = row["payload"]
        uuid.UUID(row["target_id"])
        if row["target_id"] not in mapped_branches or payload.get("branch_id") != row["target_id"]: raise ValueError("node is not mapped to an approved branch")
        if payload.get("status") not in {"DRAFT", "ACTIVE", "PAUSED", "SUSPENDED"}: raise ValueError("invalid node status")
    node_ids = {row["target_id"] for row in nodes}
    for row in inventories:
        payload = row["payload"]
        if payload.get("node_id") not in node_ids: raise ValueError("inventory node missing from bundle")
        try: stock, reserved = Decimal(str(payload.get("stock"))), Decimal(str(payload.get("reserved", 0)))
        except (InvalidOperation, ValueError): raise ValueError("invalid inventory quantity") from None
        if not stock.is_finite() or stock < 0 or reserved < 0 or reserved > stock: raise ValueError("invalid inventory quantity")
        if reserved != 0 and not allow_active_reservations: raise ValueError("active reservations must migrate with Orders")
        if payload.get("sales_enabled") is not True: raise ValueError("disabled sales inventory requires a later contract")
    return manifest, sorted(nodes, key=lambda row: row["source_id"]), sorted(inventories, key=lambda row: (row["payload"]["node_id"], row["source_id"]))


def begin(tenant, actor, correlation, lock):
    return ["BEGIN;", f"SELECT pg_advisory_xact_lock(hashtextextended({sql_literal(lock)},0));", "SET LOCAL ROLE mastererp_app;", f"SELECT set_config('app.current_tenant_id',{sql_literal(tenant)},true);", f"SELECT set_config('app.current_user_id',{sql_literal(actor)},true);", f"SELECT set_config('app.correlation_id',{sql_literal(correlation)},true);"]


def node_block(company, row):
    payload = row["payload"]
    desired = {"accepts_orders": payload.get("accepts_orders", False), "coverage_radius_km": payload.get("coverage_radius_km", "0"), "daily_capacity": payload.get("daily_capacity", 0), "minimum_order": payload.get("minimum_order", "0"), "delivery_fee": payload.get("delivery_fee", "0"), "opening_time": payload.get("opening_time"), "closing_time": payload.get("closing_time"), "location": payload.get("location", {})}
    desired_json = sql_literal(json.dumps(desired, sort_keys=True, separators=(",", ":"))) + "::jsonb"
    return f"""DO $phase6$
DECLARE current jsonb; desired jsonb:={desired_json}; wanted text:={sql_literal(payload['status'])}; next_state text;
BEGIN
 BEGIN current:=operaciones.nodos_leer({sql_literal(company)},{sql_literal(row['target_id'])});
 EXCEPTION WHEN no_data_found THEN
  PERFORM set_config('app.current_operation','operations.nodes.configure',true);
  current:=operaciones.nodo_configurar({sql_literal(company)},{sql_literal(row['target_id'])},desired);
 END;
 IF (current->>'accepts_orders')::boolean IS DISTINCT FROM (desired->>'accepts_orders')::boolean
 OR (current->>'coverage_radius_km')::numeric IS DISTINCT FROM (desired->>'coverage_radius_km')::numeric
 OR (current->>'daily_capacity')::integer IS DISTINCT FROM (desired->>'daily_capacity')::integer
 OR (current->>'minimum_order')::numeric IS DISTINCT FROM (desired->>'minimum_order')::numeric
 OR (current->>'delivery_fee')::numeric IS DISTINCT FROM (desired->>'delivery_fee')::numeric
 OR NULLIF(current->>'opening_time','')::time IS DISTINCT FROM NULLIF(desired->>'opening_time','')::time
 OR NULLIF(current->>'closing_time','')::time IS DISTINCT FROM NULLIF(desired->>'closing_time','')::time
 OR current->'location' IS DISTINCT FROM desired->'location' THEN
  PERFORM set_config('app.current_operation','operations.nodes.configure',true);
  current:=operaciones.nodo_configurar({sql_literal(company)},{sql_literal(row['target_id'])},desired||jsonb_build_object('version',(current->>'version')::bigint));
 END IF;
 WHILE current->>'status'<>wanted LOOP
  IF wanted='DRAFT' THEN RAISE EXCEPTION 'Cannot return migrated node to DRAFT' USING ERRCODE='23514'; END IF;
  next_state:=CASE WHEN current->>'status'='DRAFT' THEN 'ACTIVE' WHEN current->>'status'='SUSPENDED'AND wanted='PAUSED' THEN 'ACTIVE' ELSE wanted END;
  PERFORM set_config('app.current_operation','operations.nodes.transition',true);
  current:=operaciones.nodo_transicionar({sql_literal(company)},{sql_literal(row['target_id'])},(current->>'version')::bigint,next_state,'PHASE6_IMPORT');
 END LOOP;
END $phase6$;"""


def inventory_block(company, source_sha, row, stock_override=None):
    payload = row["payload"]
    stock = payload["stock"] if stock_override is None else str(stock_override)
    expected_version = "current_version" if stock_override is None else "0"
    return f"""DO $phase6$
DECLARE product uuid; current jsonb; current_version bigint:=0;
BEGIN
 product:=catalogo.producto_id_por_referencia_externa({sql_literal(row['source_id'])});
 BEGIN current:=catalogo.inventario_leer({sql_literal(company)},{sql_literal(payload['node_id'])},product); current_version:=(current->>'version')::bigint;
 EXCEPTION WHEN no_data_found THEN current:=NULL; current_version:=0; END;
 IF current IS NULL OR (current->>'stock')::numeric<>{stock}::numeric THEN
  PERFORM set_config('app.current_operation','catalog.inventory.set',true);
  PERFORM catalogo.inventario_establecer({sql_literal(company)},{sql_literal(payload['node_id'])},product,{stock}::numeric,{expected_version},'PHASE6_IMPORT',{sql_literal(key(source_sha,'inventory',row['source_id'] + ':' + payload['node_id'] + ':' + stock))});
 END IF;
END $phase6$;"""


def render_sql(bundle, expected_source_sha256, config_path, batch_size=200, allow_active_reservations=False, stock_overrides=None):
    config = json.loads(config_path.read_text(encoding="utf-8"))
    tenant, company, actor = config.get("target_tenant_id"), config.get("target_company_id"), config.get("actor_user_id")
    for value in (tenant, company, actor): uuid.UUID(value)
    if batch_size not in range(1, 1001): raise ValueError("batch size must be between 1 and 1000")
    manifest, nodes, inventories = verify_bundle(bundle, expected_source_sha256, config, allow_active_reservations)
    correlation = str(uuid.uuid5(uuid.UUID("45696c39-2e76-48d8-bca8-27e890f074ac"), expected_source_sha256))
    statements = ["\\set ON_ERROR_STOP on"]
    batches = [("nodes", nodes[index:index+batch_size]) for index in range(0, len(nodes), batch_size)] + [("inventory", inventories[index:index+batch_size]) for index in range(0, len(inventories), batch_size)]
    for number, (kind, batch) in enumerate(batches, 1):
        statements.extend(begin(tenant, actor, correlation, f"phase6-{kind}-{expected_source_sha256}-{number}"))
        statements.extend(node_block(company, row) if kind == "nodes" else inventory_block(company, expected_source_sha256, row, (stock_overrides or {}).get((row["payload"]["node_id"], row["source_id"]))) for row in batch)
        statements.append("COMMIT;")
    statements.append("")
    plan = {"wave":"nodes-inventory","source_sha256":manifest["source_sha256"],"nodes":len(nodes),"inventories":len(inventories),"batch_size":batch_size,"transactions":len(batches),"active_reservations":0,"direct_dml":False,"restartable":True}
    return "\n".join(statements), plan


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--bundle",type=Path,required=True); parser.add_argument("--config",type=Path,required=True); parser.add_argument("--expected-source-sha256",required=True); parser.add_argument("--batch-size",type=int,default=200); parser.add_argument("--emit-sql",type=Path)
    args=parser.parse_args(); sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size); print(json.dumps(plan,indent=2,sort_keys=True))
    if args.emit_sql: args.emit_sql.write_text(sql,encoding="utf-8"); print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__": main()
