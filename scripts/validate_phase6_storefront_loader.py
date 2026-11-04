"""Validate Storefront configuration replay twice in disposable PostgreSQL."""
import json,subprocess,tempfile,time,uuid
from pathlib import Path
from migration.phase6.storefront_loader import render_sql
from migration.phase6.transform_export import write_bundle
ROOT=Path(__file__).resolve().parents[1];IMAGE="public.ecr.aws/docker/library/postgres:17.9-alpine"


def main():
 name="mastererp-phase6-store-"+uuid.uuid4().hex[:10];created=False
 def docker(*args,check=True):
  result=subprocess.run(["docker",*args],capture_output=True,text=True)
  if check and result.returncode:raise RuntimeError(result.stderr[-2000:])
  return result
 try:
  docker("image","inspect",IMAGE);docker("run","--detach","--rm","--network","none","--name",name,"-e","POSTGRES_HOST_AUTH_METHOD=trust",IMAGE);created=True
  for _ in range(80):
   if docker("exec",name,"pg_isready","-U","postgres",check=False).returncode==0:time.sleep(.5);break
   time.sleep(.25)
  for folder in("schema","seeds"):
   docker("cp",str(ROOT/folder),f"{name}:/tmp/{folder}")
   for path in sorted((ROOT/folder).glob("*.sql")):docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","--single-transaction","-f",f"/tmp/{folder}/{path.name}")
  with tempfile.TemporaryDirectory()as temp:
   work=Path(temp);source=work/"source.jsonl";config=work/"config.json";bundle=work/"bundle";source.write_text(json.dumps({"entityType":"MERCHANT","tenantId":"T001","merchantId":"M1","name":"Market","logo":"logo.svg","currency":"USD","deliveryFee":2,"minOrder":10,"payments":{"cash":True}})+"\n");settings={"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{"N1":"00000000-0000-0000-0000-000000000004"},"store_map":{"M1":[{"source_node_id":"N1","domain":"market.example.invalid","status":"ACTIVE","modules":["catalog","orders"]}]}};config.write_text(json.dumps(settings));report=write_bundle(source,config,bundle);sql,plan=render_sql(bundle,report["source_sha256"],config)
   if any(token in sql for token in("INSERT INTO","UPDATE ","DELETE FROM")):raise AssertionError("direct DML in Storefront loader")
   fixture="""INSERT INTO plataforma.roles(code,name) VALUES('phase6-store','Phase 6 store');INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='phase6-store' AND p.code IN('digital_sales.ecommerce.read','digital_sales.ecommerce.write');INSERT INTO plataforma.users(id,email,display_name) VALUES('00000000-0000-0000-0000-000000000003','phase6-store@example.invalid','Phase 6 Store');INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00000000-0000-0000-0000-000000000001','phase6-store','phase6-store','Phase 6 Store','active');INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) SELECT '00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003',id,'active' FROM plataforma.roles WHERE code='phase6-store';INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00000000-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='digital_sales.ecommerce';INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','Phase 6','US','USD','UTC');INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status) VALUES('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','N1','Node 1','warehouse','US','active');INSERT INTO operaciones.nodos(tenant_id,empresa_id,id,creado_por) VALUES('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000003');""";docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","-c",fixture);path=work/"store.sql";path.write_text(sql);docker("cp",str(path),f"{name}:/tmp/store.sql");docker("exec",name,"psql","-U","postgres","-f","/tmp/store.sql");docker("exec",name,"psql","-U","postgres","-f","/tmp/store.sql");counts=docker("exec",name,"psql","-U","postgres","-qAt","-c","SELECT count(*),min(estado),min(dominio),min(version) FROM ventas_digitales.tiendas;").stdout.strip()
   if counts!="1|ACTIVE|market.example.invalid|2":raise AssertionError(counts)
   print(json.dumps({"storefront":plan,"applied_twice":True,"counts":counts,"effective_role":"mastererp_app","remote_writes":False},indent=2,sort_keys=True))
 finally:
  if created:docker("rm","--force",name,check=False)


if __name__=="__main__":main()
