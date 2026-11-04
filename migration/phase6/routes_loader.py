"""Build restartable SQL for Routes after Orders and Drivers are reconciled."""

import argparse,hashlib,json,re,uuid
from pathlib import Path
from migration.phase6.catalog_loader import key,sql_literal
from migration.phase6.drivers_loader import render_sql as render_drivers
from migration.phase6.historical_orders_loader import render_sql as render_orders
from migration.phase6.operations_inventory_loader import begin,read_jsonl


def verify_bundle(bundle,expected_source_sha256,config):
 manifest=json.loads((bundle/"manifest.json").read_text());path=bundle/"routes.jsonl"
 if not re.fullmatch(r"[0-9a-f]{64}",expected_source_sha256)or manifest.get("source_sha256")!=expected_source_sha256:raise ValueError("source SHA-256 mismatch")
 if manifest.get("errors")!=0 or hashlib.sha256(path.read_bytes()).hexdigest()!=manifest.get("output_sha256",{}).get(path.name):raise ValueError("invalid Routes bundle")
 routes=read_jsonl(path);orders={row["source_id"]:row["payload"]for row in read_jsonl(bundle/"orders.jsonl")};drivers={row["source_id"]:row["payload"]for row in read_jsonl(bundle/"drivers.jsonl")};seen=set()
 for row in routes:
  p=row["payload"];external=p.get("external_reference")
  if not external or external in seen:raise ValueError("route external references must be unique")
  seen.add(external)
  if p.get("status")not in{"PLANNED","IN_ROUTE","COMPLETED","CANCELLED"}or not p.get("date")or not p.get("node_id"):raise ValueError("invalid route state")
  if not p.get("order_external_ids"):raise ValueError("empty routes require a separate archival policy")
  for order_id in p["order_external_ids"]:
   order=orders.get(order_id)
   if not order or order.get("route_external_id")!=external:raise ValueError(f"route/order ownership mismatch: {external}:{order_id}")
   if order.get("status")=="CANCELLED":raise ValueError("cancelled routed orders require an explicit failed-delivery contract")
   if p["status"]=="COMPLETED"and order.get("status")!="DELIVERED":raise ValueError("completed route contains a non-delivered order")
  driver=p.get("driver_external_id")
  if p["status"]in{"IN_ROUTE","COMPLETED"}and not driver:raise ValueError("active/completed route requires driver")
  if driver:
   profile=drivers.get(driver)
   if not profile or p["node_id"]not in profile.get("node_ids",[]):raise ValueError("route driver is not assigned to its node")
 return manifest,sorted(routes,key=lambda row:row["source_id"]),orders


def orders_sql(values):
 return"jsonb_build_array("+",".join(f"operaciones.pedido_id_por_referencia_externa(current_company,{sql_literal(value)})"for value in values)+")"


def route_block(company,source_sha,row,orders):
 p=row["payload"];driver=p.get("driver_external_id");status=p["status"]
 assign="" if not driver else f"""IF current->>'status'='PLANNED' THEN
  PERFORM set_config('app.current_operation','operations.routes.assign',true);
  current:=operaciones.ruta_asignar(current_company,(current->>'id')::uuid,(current->>'version')::bigint,transporte.repartidor_id_por_referencia_externa(current_company,{sql_literal(driver)}));
 END IF;"""
 start="" if status not in{"IN_ROUTE","COMPLETED"}else"""IF current->>'status'='ASSIGNED' THEN
  PERFORM set_config('app.current_operation','operations.routes.transition',true);
  current:=operaciones.ruta_transicionar(current_company,(current->>'id')::uuid,(current->>'version')::bigint,'IN_ROUTE');
 END IF;"""
 delivered=[value for value in p["order_external_ids"]if orders[value]["status"]=="DELIVERED"]
 stops="\n".join(f"""IF EXISTS(SELECT 1 FROM jsonb_array_elements(current->'stops') stop WHERE stop->>'order_id'=operaciones.pedido_id_por_referencia_externa(current_company,{sql_literal(value)})::text AND stop->>'status'='PENDING') THEN
  PERFORM set_config('app.current_operation','operations.routes.stop.complete',true);
  current:=operaciones.ruta_parada_finalizar(current_company,(current->>'id')::uuid,operaciones.pedido_id_por_referencia_externa(current_company,{sql_literal(value)}),'DELIVERED','{{"source":"PHASE6_IMPORT"}}'::jsonb);
 END IF;"""for value in delivered)
 finish="" if status!="COMPLETED"else"""IF current->>'status'='IN_ROUTE' THEN
  PERFORM set_config('app.current_operation','operations.routes.transition',true);
  current:=operaciones.ruta_transicionar(current_company,(current->>'id')::uuid,(current->>'version')::bigint,'COMPLETED');
 END IF;"""
 cancel="" if status!="CANCELLED"else"""IF current->>'status' IN('PLANNED','ASSIGNED') THEN
  PERFORM set_config('app.current_operation','operations.routes.transition',true);
  current:=operaciones.ruta_transicionar(current_company,(current->>'id')::uuid,(current->>'version')::bigint,'CANCELLED');
 END IF;"""
 return f"""DO $phase6$
DECLARE current jsonb;current_company uuid:={sql_literal(company)}::uuid;
BEGIN
 PERFORM set_config('app.current_operation','operations.routes.create',true);
 current:=operaciones.ruta_crear(current_company,{sql_literal(p['node_id'])}::uuid,{sql_literal(p['date'])}::date,{sql_literal(p.get('delivery_window_ref'))},{orders_sql(p['order_external_ids'])},{sql_literal(key(source_sha,'route',row['source_id']))});
 current:=operaciones.rutas_leer(current_company,(current->>'id')::uuid);
 {assign}
 {start}
 {stops}
 {finish}
 {cancel}
END $phase6$;"""


def render_sql(bundle,expected_source_sha256,config_path,batch_size=100):
 config=json.loads(config_path.read_text());tenant,company,actor=(config[name]for name in("target_tenant_id","target_company_id","actor_user_id"));[uuid.UUID(value)for value in(tenant,company,actor)];manifest,routes,orders=verify_bundle(bundle,expected_source_sha256,config)
 orders_sql_text,_=render_orders(bundle,expected_source_sha256,config_path,batch_size);drivers_sql_text,_=render_drivers(bundle,expected_source_sha256,config_path,batch_size,allow_assigned=True);correlation=str(uuid.uuid5(uuid.UUID("8862ba5b-e680-4e87-9802-b7d55c586238"),expected_source_sha256));statements=[orders_sql_text.rstrip(),drivers_sql_text.rstrip(),"\\set ON_ERROR_STOP on"]
 batches=[routes[index:index+batch_size]for index in range(0,len(routes),batch_size)]
 for number,batch in enumerate(batches,1):statements.extend(begin(tenant,actor,correlation,f"phase6-routes-{expected_source_sha256}-{number}"));statements.extend(route_block(company,expected_source_sha256,row,orders)for row in batch);statements.append("COMMIT;")
 statements.append("");return"\n".join(statements),{"wave":"routes","source_sha256":manifest["source_sha256"],"routes":len(routes),"batch_size":batch_size,"transactions":len(batches),"restartable":True,"direct_dml":False}


def main():
 parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);parser.add_argument("--batch-size",type=int,default=100);parser.add_argument("--emit-sql",type=Path);args=parser.parse_args();sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size);print(json.dumps(plan,indent=2,sort_keys=True))
 if args.emit_sql:args.emit_sql.write_text(sql);print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__":main()
