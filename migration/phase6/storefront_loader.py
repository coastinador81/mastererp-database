"""Build restartable SQL for Merchant to canonical Storefront configuration."""
import argparse,hashlib,json,re,uuid
from pathlib import Path
from migration.phase6.catalog_loader import sql_literal
from migration.phase6.operations_inventory_loader import begin,read_jsonl


def verify_bundle(bundle,expected_source_sha256,config):
 manifest=json.loads((bundle/"manifest.json").read_text());path=bundle/"stores.jsonl"
 if not re.fullmatch(r"[0-9a-f]{64}",expected_source_sha256)or manifest.get("source_sha256")!=expected_source_sha256:raise ValueError("source SHA-256 mismatch")
 if manifest.get("errors")!=0 or hashlib.sha256(path.read_bytes()).hexdigest()!=manifest.get("output_sha256",{}).get(path.name):raise ValueError("invalid Storefront bundle")
 stores=read_jsonl(path);domains=set();nodes=set(config.get("node_map",{}).values())
 for row in stores:
  p=row["payload"];domain=p.get("domain")
  if not domain or domain in domains or p.get("node_id")not in nodes:raise ValueError("store domains must be unique and nodes mapped")
  domains.add(domain)
  if p.get("status")not in{"DRAFT","ACTIVE","PAUSED"}or not str(p.get("name")or"").strip():raise ValueError("invalid store configuration")
  if not isinstance(p.get("branding"),dict)or not isinstance(p.get("configuration"),dict)or not isinstance(p.get("modules"),list):raise ValueError("invalid store JSON configuration")
 return manifest,sorted(stores,key=lambda row:row["source_id"])


def store_block(company,row):
 p=row["payload"];desired=json.dumps({"status":p["status"],"branding":p["branding"],"configuration":p["configuration"],"modules":p["modules"]},sort_keys=True,separators=(",",":"))
 return f"""DO $phase6$
DECLARE current jsonb;desired jsonb:={sql_literal(desired)}::jsonb;
BEGIN
 SELECT value INTO current FROM jsonb_array_elements(ventas_digitales.tiendas_leer({sql_literal(company)}::uuid)) value WHERE value->>'domain'={sql_literal(p['domain'])};
 PERFORM set_config('app.current_operation','digital_sales.ecommerce.configure',true);
 IF current IS NULL THEN
  current:=ventas_digitales.tienda_configurar({sql_literal(company)}::uuid,NULL,{sql_literal(p['node_id'])}::uuid,{sql_literal(p['domain'])},{sql_literal(p['name'])},NULL,desired);
 END IF;
 IF (current->>'node_id',current->>'domain',current->>'name',current->>'status',current->'branding',current->'configuration',current->'modules') IS DISTINCT FROM ({sql_literal(p['node_id'])},{sql_literal(p['domain'])},{sql_literal(p['name'])},desired->>'status',desired->'branding',desired->'configuration',desired->'modules') THEN
  current:=ventas_digitales.tienda_configurar({sql_literal(company)}::uuid,(current->>'id')::uuid,{sql_literal(p['node_id'])}::uuid,{sql_literal(p['domain'])},{sql_literal(p['name'])},(current->>'version')::bigint,desired);
 END IF;
END $phase6$;"""


def render_sql(bundle,expected_source_sha256,config_path,batch_size=100):
 config=json.loads(config_path.read_text());tenant,company,actor=(config[name]for name in("target_tenant_id","target_company_id","actor_user_id"));[uuid.UUID(value)for value in(tenant,company,actor)];manifest,stores=verify_bundle(bundle,expected_source_sha256,config);correlation=str(uuid.uuid5(uuid.UUID("e6065cd7-b525-45c1-a819-42e343ba2fde"),expected_source_sha256));statements=["\\set ON_ERROR_STOP on"];batches=[stores[index:index+batch_size]for index in range(0,len(stores),batch_size)]
 for number,batch in enumerate(batches,1):statements.extend(begin(tenant,actor,correlation,f"phase6-storefront-{expected_source_sha256}-{number}"));statements.extend(store_block(company,row)for row in batch);statements.append("COMMIT;")
 statements.append("");return"\n".join(statements),{"wave":"storefront","source_sha256":manifest["source_sha256"],"stores":len(stores),"batch_size":batch_size,"transactions":len(batches),"restartable":True,"direct_dml":False}


def main():
 parser=argparse.ArgumentParser();parser.add_argument("--bundle",type=Path,required=True);parser.add_argument("--config",type=Path,required=True);parser.add_argument("--expected-source-sha256",required=True);parser.add_argument("--batch-size",type=int,default=100);parser.add_argument("--emit-sql",type=Path);args=parser.parse_args();sql,plan=render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size);print(json.dumps(plan,indent=2,sort_keys=True))
 if args.emit_sql:args.emit_sql.write_text(sql);print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__=="__main__":main()
