"""Build restartable loader SQL for unassigned Drivers and node links."""

import argparse
import hashlib
import json
import re
import uuid
from pathlib import Path

from migration.phase6.catalog_loader import key, sql_literal
from migration.phase6.operations_inventory_loader import begin, read_jsonl


def verify_bundle(bundle, expected_source_sha256, config, allow_assigned=False):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256): raise ValueError("invalid source SHA-256")
    manifest=json.loads((bundle/"manifest.json").read_text())
    if manifest.get("errors")!=0: raise ValueError("bundle contains transformation errors")
    if manifest.get("source_sha256")!=expected_source_sha256: raise ValueError("source SHA-256 mismatch")
    path=bundle/"drivers.jsonl"
    if hashlib.sha256(path.read_bytes()).hexdigest()!=manifest.get("output_sha256",{}).get(path.name): raise ValueError("bundle hash mismatch: drivers.jsonl")
    allowed_nodes=set(config.get("node_map",{}).values());drivers=read_jsonl(path);external=set()
    for row in drivers:
        payload=row["payload"];reference=payload.get("external_reference")
        if not reference or reference in external: raise ValueError("driver external references must be unique")
        external.add(reference)
        if not str(payload.get("name")or"").strip() or len(str(payload.get("phone")or""))<5: raise ValueError("driver name and phone required")
        if not allow_assigned and (payload.get("availability") not in {"AVAILABLE","OFFLINE"} or payload.get("route_external_id")): raise ValueError("assigned or on-route driver must migrate with Routes")
        if payload.get("status") not in {"ACTIVE","INACTIVE"} or payload.get("access_status") not in {"PENDING","LINKED","ERROR","DISABLED"}: raise ValueError("invalid driver state")
        if not set(payload.get("node_ids",[]))<=allowed_nodes: raise ValueError("driver has an unmapped node")
    return manifest,sorted(drivers,key=lambda row:row["source_id"])


def driver_block(company,source_sha,row,allow_assigned=False):
    payload=row["payload"];changes={name:payload[name] for name in("name","phone","email","status","availability","access_status","vehicle","license")}
    if allow_assigned and payload.get("route_external_id"): changes["availability"]="AVAILABLE"
    changes_json=sql_literal(json.dumps(changes,sort_keys=True,separators=(",",":")))+"::jsonb"
    nodes="\n".join(f"""IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(current->'node_ids') value WHERE value::uuid={sql_literal(node)}::uuid) THEN
  PERFORM set_config('app.current_operation','transport.drivers.assign',true);
  current:=transporte.repartidor_asignar_nodo({sql_literal(company)},{sql_literal(node)},(current->>'id')::uuid,true);
 END IF;"""for node in payload.get("node_ids",[]))
    return f"""DO $phase6$
DECLARE current jsonb; desired jsonb:={changes_json};
BEGIN
 PERFORM set_config('app.current_operation','transport.drivers.create',true);
 current:=transporte.repartidor_crear({sql_literal(company)},{sql_literal(payload['name'])},{sql_literal(payload['phone'])},{sql_literal(payload.get('email'))},{sql_literal(json.dumps(payload.get('vehicle',{}),sort_keys=True))}::jsonb,{sql_literal(json.dumps(payload.get('license',{}),sort_keys=True))}::jsonb,{sql_literal(payload['external_reference'])},{sql_literal(key(source_sha,'driver',row['source_id']))});
 current:=transporte.repartidores_leer({sql_literal(company)},NULL,(current->>'id')::uuid);
 IF (current->>'name',current->>'phone',COALESCE(current->>'email',''),current->>'status',current->>'availability',current->>'access_status',current->'vehicle',current->'license') IS DISTINCT FROM (desired->>'name',desired->>'phone',COALESCE(desired->>'email',''),desired->>'status',desired->>'availability',desired->>'access_status',desired->'vehicle',desired->'license') THEN
  PERFORM set_config('app.current_operation','transport.drivers.update',true);
  current:=transporte.repartidor_actualizar({sql_literal(company)},(current->>'id')::uuid,(current->>'version')::bigint,desired);
 END IF;
 {nodes}
END $phase6$;"""


def render_sql(bundle,expected_source_sha256,config_path,batch_size=200,allow_assigned=False):
    config=json.loads(config_path.read_text());tenant,company,actor=config.get("target_tenant_id"),config.get("target_company_id"),config.get("actor_user_id")
    for value in(tenant,company,actor):uuid.UUID(value)
    if batch_size not in range(1,1001):raise ValueError("batch size must be between 1 and 1000")
    manifest,drivers=verify_bundle(bundle,expected_source_sha256,config,allow_assigned);correlation=str(uuid.uuid5(uuid.UUID("92df9f4b-9ddf-46fc-8161-f074c7d886e5"),expected_source_sha256));statements=["\\set ON_ERROR_STOP on"]
    batches=[drivers[index:index+batch_size]for index in range(0,len(drivers),batch_size)]
    for number,batch in enumerate(batches,1):statements.extend(begin(tenant,actor,correlation,f"phase6-drivers-{expected_source_sha256}-{number}"));statements.extend(driver_block(company,expected_source_sha256,row,allow_assigned)for row in batch);statements.append("COMMIT;")
    statements.append("");return"\n".join(statements),{"wave":"drivers","source_sha256":manifest["source_sha256"],"drivers":len(drivers),"batch_size":batch_size,"transactions":len(batches),"active_routes":0,"direct_dml":False,"restartable":True}


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);parser.add_argument("--batch-size",type=int,default=200);parser.add_argument("--emit-sql",type=Path);args=parser.parse_args();sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size);print(json.dumps(plan,indent=2,sort_keys=True))
    if args.emit_sql:args.emit_sql.write_text(sql);print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__":main()
