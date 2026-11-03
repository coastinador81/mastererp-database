"""Build SQL for active Orders and their exact Inventory reservations."""

import argparse
import json
import uuid
from collections import defaultdict
from pathlib import Path

from migration.phase6.catalog_loader import key, sql_literal
from migration.phase6.operations_inventory_loader import begin, read_jsonl, render_sql as render_operations
from migration.phase6.orders_preflight import ACTIVE, inspect_bundle


def json_sql(value):
    return sql_literal(json.dumps(value, sort_keys=True, separators=(",", ":"))) + "::jsonb"


def items_sql(lines, reservation=False):
    entries = []
    for line in sorted(lines, key=lambda value: value["position"]):
        pairs = ["'product_id'", f"catalogo.producto_id_por_referencia_externa({sql_literal(line['product_external_id'])})", "'quantity'", f"{line['quantity']}::numeric"]
        if not reservation: pairs.extend(["'product_name'", sql_literal(line["product_name"]), "'unit_price'", f"{line['unit_price']}::numeric"])
        entries.append("jsonb_build_object(" + ",".join(pairs) + ")")
    return "jsonb_build_array(" + ",".join(entries) + ")"


def order_block(company, source_sha, row, lines):
    payload=row["payload"]; status=payload["status"]; desired=[line["preparation_status"] for line in sorted(lines,key=lambda value:value["position"])]
    confirm = "" if status == "PENDING" else f"""PERFORM set_config('app.current_operation','operations.orders.transition',true);
 current:=operaciones.pedido_transicionar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,'CONFIRMED','PHASE6_IMPORT');"""
    prepare = "" if status != "PREPARING" else f"""PERFORM set_config('app.current_operation','operations.preparation.start',true);
 prep:=operaciones.preparacion_iniciar({sql_literal(company)},(current->>'id')::uuid,{sql_literal(payload['node_id'])}::uuid,(current->>'version')::bigint);
 FOR position IN 0..jsonb_array_length(desired)-1 LOOP
  IF desired->>position='DONE' THEN
   PERFORM set_config('app.current_operation','operations.preparation.item.update',true);
   prep:=operaciones.preparacion_linea_marcar({sql_literal(company)},(current->>'id')::uuid,(prep->'items'->position->>'line_id')::uuid,(prep->'items'->position->>'version')::bigint,'DONE','PHASE6_IMPORT');
  END IF;
 END LOOP;"""
    return f"""DO $phase6$
DECLARE reservation jsonb; current jsonb; prep jsonb; desired jsonb:={json_sql(desired)}; position integer;
BEGIN
 PERFORM set_config('app.current_operation','catalog.inventory.reserve',true);
 reservation:=catalogo.inventario_reservar({sql_literal(company)}::uuid,{sql_literal(payload['node_id'])}::uuid,
  {items_sql(lines,True)},{sql_literal(payload['external_reference'])},{sql_literal(key(source_sha,'reservation',row['source_id']))});
 PERFORM set_config('app.current_operation','operations.orders.create',true);
 current:=operaciones.pedido_crear({sql_literal(company)}::uuid,{sql_literal(payload['node_id'])}::uuid,
  administracion.cliente_id_por_referencia_externa({sql_literal(company)}::uuid,{sql_literal(payload['customer_external_id'])}),
  {sql_literal(payload['currency'])}::char(3),{items_sql(lines)},{json_sql(payload['customer_snapshot'])},
  {json_sql(payload['delivery_address_snapshot'])},{json_sql(payload['payment_snapshot'])},
  {sql_literal(payload['delivery_window_ref'])},{sql_literal(payload['delivery_method'])},reservation->>'reservation_ref',
  {payload['delivery_fee']}::numeric,{sql_literal(payload['external_reference'])},{sql_literal(key(source_sha,'order',row['source_id']))});
 {confirm}
 {prepare}
END $phase6$;"""


def render_sql(bundle,expected_source_sha256,config_path,batch_size=100,stock_overrides=None):
    plan=inspect_bundle(bundle,expected_source_sha256,config_path);config=json.loads(config_path.read_text());tenant,company,actor=(config[name] for name in("target_tenant_id","target_company_id","actor_user_id"))
    for value in(tenant,company,actor):uuid.UUID(value)
    if batch_size not in range(1,501):raise ValueError("batch size must be between 1 and 500")
    orders=[row for row in read_jsonl(bundle/"orders.jsonl") if row["payload"]["status"] in ACTIVE];groups=defaultdict(list)
    for row in read_jsonl(bundle/"order_items.jsonl"):groups[row["payload"]["order_external_id"]].append(row["payload"])
    inventory_sql,_=render_operations(bundle,expected_source_sha256,config_path,batch_size,allow_active_reservations=True,stock_overrides=stock_overrides)
    correlation=str(uuid.uuid5(uuid.UUID("091d4796-a4e2-46bd-ac35-9828a459e93d"),expected_source_sha256));statements=[inventory_sql.rstrip(),"\\set ON_ERROR_STOP on"]
    batches=[orders[index:index+batch_size]for index in range(0,len(orders),batch_size)]
    for number,batch in enumerate(batches,1):
        statements.extend(begin(tenant,actor,correlation,f"phase6-active-orders-{expected_source_sha256}-{number}"));statements.extend(order_block(company,expected_source_sha256,row,groups[row["source_id"]])for row in batch);statements.append("COMMIT;")
    statements.append("");return"\n".join(statements),{**plan,"wave":"active-orders","loaded_orders":len(orders),"deferred_orders":plan["historical_or_routed"],"batch_size":batch_size,"transactions":len(batches),"restartable":True,"direct_dml":False}


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);parser.add_argument("--batch-size",type=int,default=100);parser.add_argument("--emit-sql",type=Path);args=parser.parse_args();sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size);print(json.dumps(plan,indent=2,sort_keys=True))
    if args.emit_sql:args.emit_sql.write_text(sql);print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__":main()
