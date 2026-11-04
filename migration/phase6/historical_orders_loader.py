"""Replay historical Orders while preserving final Inventory balances."""

import argparse
import json
import uuid
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

from migration.phase6.active_orders_loader import items_sql, json_sql, render_sql as render_active
from migration.phase6.catalog_loader import key, sql_literal
from migration.phase6.operations_inventory_loader import begin, read_jsonl
from migration.phase6.orders_preflight import HISTORICAL, inspect_bundle


def historical_block(company, source_sha, row, lines):
    payload=row["payload"];status="READY" if payload.get("route_external_id") else payload["status"]
    cancel="" if status!="CANCELLED" else f"""IF current->>'status'='PENDING' THEN
  PERFORM set_config('app.current_operation','operations.orders.transition',true);
  current:=operaciones.pedido_transicionar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,'CANCELLED','PHASE6_IMPORT');
 END IF;
 PERFORM set_config('app.current_operation','catalog.inventory.reservation.finalize',true);
 PERFORM catalogo.inventario_reserva_finalizar({sql_literal(company)},(reservation->>'reservation_ref')::uuid,'RELEASE','PHASE6_IMPORT');"""
    fulfill="" if status=="CANCELLED" else f"""IF current->>'status'='PENDING' THEN
  PERFORM set_config('app.current_operation','operations.orders.transition',true);
  current:=operaciones.pedido_transicionar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,'CONFIRMED','PHASE6_IMPORT');
 END IF;
 IF current->>'status'='CONFIRMED' THEN
  PERFORM set_config('app.current_operation','operations.preparation.start',true);
  prep:=operaciones.preparacion_iniciar({sql_literal(company)},(current->>'id')::uuid,{sql_literal(payload['node_id'])}::uuid,(current->>'version')::bigint);
  current:=operaciones.pedidos_leer({sql_literal(company)},(current->>'id')::uuid);
 END IF;
 IF current->>'status'='PREPARING' THEN
  prep:=operaciones.preparacion_leer({sql_literal(company)},(current->>'id')::uuid);
  FOR position IN 0..jsonb_array_length(prep->'items')-1 LOOP
   IF prep->'items'->position->>'status'<>'DONE' THEN
    PERFORM set_config('app.current_operation','operations.preparation.item.update',true);
    prep:=operaciones.preparacion_linea_marcar({sql_literal(company)},(current->>'id')::uuid,(prep->'items'->position->>'line_id')::uuid,(prep->'items'->position->>'version')::bigint,'DONE','PHASE6_IMPORT');
   END IF;
  END LOOP;
  PERFORM set_config('app.current_operation','operations.preparation.complete',true);
  PERFORM operaciones.preparacion_completar({sql_literal(company)},(current->>'id')::uuid,(prep->>'version')::bigint);
  current:=operaciones.pedidos_leer({sql_literal(company)},(current->>'id')::uuid);
 END IF;
 IF {sql_literal(status)} IN('OUT_FOR_DELIVERY','DELIVERED') AND current->>'status'='READY' THEN
  PERFORM set_config('app.current_operation','operations.orders.transition',true);
  current:=operaciones.pedido_transicionar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,'OUT_FOR_DELIVERY','PHASE6_IMPORT');
 END IF;
 IF {sql_literal(status)}='DELIVERED' AND current->>'status'='OUT_FOR_DELIVERY' THEN
  PERFORM set_config('app.current_operation','operations.orders.transition',true);
  current:=operaciones.pedido_transicionar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,'DELIVERED','PHASE6_IMPORT');
 END IF;"""
    return f"""DO $phase6$
DECLARE reservation jsonb;current jsonb;prep jsonb;position integer;
BEGIN
 PERFORM set_config('app.current_operation','catalog.inventory.reserve',true);
 reservation:=catalogo.inventario_reservar({sql_literal(company)}::uuid,{sql_literal(payload['node_id'])}::uuid,{items_sql(lines,True)},{sql_literal(payload['external_reference'])},{sql_literal(key(source_sha,'reservation',row['source_id']))});
 PERFORM set_config('app.current_operation','operations.orders.create',true);
 current:=operaciones.pedido_crear({sql_literal(company)}::uuid,{sql_literal(payload['node_id'])}::uuid,administracion.cliente_id_por_referencia_externa({sql_literal(company)}::uuid,{sql_literal(payload['customer_external_id'])}),{sql_literal(payload['currency'])}::char(3),{items_sql(lines)},{json_sql(payload['customer_snapshot'])},{json_sql(payload['delivery_address_snapshot'])},{json_sql(payload['payment_snapshot'])},{sql_literal(payload['delivery_window_ref'])},{sql_literal(payload['delivery_method'])},reservation->>'reservation_ref',{payload['delivery_fee']}::numeric,{sql_literal(payload['external_reference'])},{sql_literal(key(source_sha,'order',row['source_id']))});
 current:=operaciones.pedidos_leer({sql_literal(company)},(current->>'id')::uuid);
 {cancel}
 {fulfill}
END $phase6$;"""


def render_sql(bundle,expected_source_sha256,config_path,batch_size=100):
    plan=inspect_bundle(bundle,expected_source_sha256,config_path);config=json.loads(config_path.read_text());tenant,company,actor=(config[name]for name in("target_tenant_id","target_company_id","actor_user_id"));[uuid.UUID(value)for value in(tenant,company,actor)]
    orders=[row for row in read_jsonl(bundle/"orders.jsonl")if row["payload"]["status"]in HISTORICAL];groups=defaultdict(list);adjustments=defaultdict(Decimal)
    for row in read_jsonl(bundle/"order_items.jsonl"):groups[row["payload"]["order_external_id"]].append(row["payload"])
    for row in orders:
        if row["payload"]["status"]!="CANCELLED" or row["payload"].get("route_external_id"):
            for line in groups[row["source_id"]]:adjustments[(row["payload"]["node_id"],line["product_external_id"])]+=Decimal(line["quantity"])
    stocks={(row["payload"]["node_id"],row["source_id"]):Decimal(row["payload"]["stock"])+adjustments[(row["payload"]["node_id"],row["source_id"])]for row in read_jsonl(bundle/"inventories.jsonl")}
    active_sql,_=render_active(bundle,expected_source_sha256,config_path,batch_size,stock_overrides=stocks);correlation=str(uuid.uuid5(uuid.UUID("8a82fa91-5125-48ac-9ef4-f2ae40df09c5"),expected_source_sha256));statements=[active_sql.rstrip(),"\\set ON_ERROR_STOP on"]
    batches=[orders[index:index+batch_size]for index in range(0,len(orders),batch_size)]
    for number,batch in enumerate(batches,1):statements.extend(begin(tenant,actor,correlation,f"phase6-historical-orders-{expected_source_sha256}-{number}"));statements.extend(historical_block(company,expected_source_sha256,row,groups[row["source_id"]])for row in batch);statements.append("COMMIT;")
    statements.append("");return"\n".join(statements),{**plan,"wave":"historical-orders","loaded_historical":len(orders),"stock_adjustment_scopes":sum(value!=0 for value in adjustments.values()),"batch_size":batch_size,"transactions":len(batches),"restartable":True,"direct_dml":False}


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);parser.add_argument("--batch-size",type=int,default=100);parser.add_argument("--emit-sql",type=Path);args=parser.parse_args();sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size);print(json.dumps(plan,indent=2,sort_keys=True))
    if args.emit_sql:args.emit_sql.write_text(sql);print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__":main()
