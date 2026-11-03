"""Validate catalog then Nodes/Inventory loaders twice in disposable PostgreSQL."""

import json
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from migration.phase6.catalog_loader import render_sql as render_catalog
from migration.phase6.operations_inventory_loader import render_sql as render_operations
from migration.phase6.drivers_loader import render_sql as render_drivers
from migration.phase6.customers_loader import render_sql as render_customers
from migration.phase6.transform_export import write_bundle


ROOT=Path(__file__).resolve().parents[1]; IMAGE="public.ecr.aws/docker/library/postgres:17.9-alpine"


def main():
 name="mastererp-phase6-ops-"+uuid.uuid4().hex[:10];created=False
 def docker(*args,check=True):
  result=subprocess.run(["docker",*args],capture_output=True,text=True)
  if check and result.returncode:raise RuntimeError(result.stderr[-2000:])
  return result
 try:
  docker("image","inspect",IMAGE);docker("run","--detach","--rm","--network","none","--name",name,"-e","POSTGRES_HOST_AUTH_METHOD=trust",IMAGE);created=True
  for _ in range(80):
   if docker("exec",name,"pg_isready","-U","postgres",check=False).returncode==0:break
   time.sleep(.25)
  else:raise RuntimeError("PostgreSQL not ready")
  for folder in("schema","seeds"):
   docker("cp",str(ROOT/folder),f"{name}:/tmp/{folder}")
   for path in sorted((ROOT/folder).glob("*.sql")):docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","--single-transaction","-f",f"/tmp/{folder}/{path.name}")
  with tempfile.TemporaryDirectory()as temp:
   work=Path(temp);source=work/"source.jsonl";config=work/"config.json";bundle=work/"bundle"
   items=[
    {"PK":"TENANT#T001#CUSTOMER#C1","SK":"META","entityType":"CUSTOMER","tenantId":"T001","customerId":"C1","name":"Customer One","email":"customer@example.invalid","status":"ACTIVE"},
    {"PK":"TENANT#T001#PRODUCT#P1","SK":"META","entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","price":2.5,"categoryId":"food","status":"ACTIVE"},
    {"PK":"TENANT#T001#PRODUCT#P1","SK":"INVENTORY","entityType":"INVENTORY","tenantId":"T001","productId":"P1","nodeId":"NODE-1","stock":10,"reserved":0},
    {"PK":"TENANT#T001","SK":"NODE#NODE-1","entityType":"NODE","tenantId":"T001","nodeId":"NODE-1","status":"ACTIVE","acceptsOrders":True,"coverageRadiusKm":5,"dailyCapacity":50},]
   items.extend([{"PK":"TENANT#T001#DRIVER#D1","SK":"META","entityType":"DRIVER","tenantId":"T001","driverId":"D1","name":"Driver One","phone":"04140000000","email":"driver@example.invalid","status":"AVAILABLE","accessStatus":"PENDING"},{"PK":"TENANT#T001","SK":"NODE#NODE-1#DRIVER#D1","entityType":"NODE_DRIVER","tenantId":"T001","nodeId":"NODE-1","driverId":"D1","status":"available"}])
   source.write_text("".join(json.dumps(item)+"\n"for item in items))
   settings={"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","default_source_node_id":"NODE-1","node_map":{"NODE-1":"00000000-0000-0000-0000-000000000004"}}
   config.write_text(json.dumps(settings));report=write_bundle(source,config,bundle)
   catalog_sql,_=render_catalog(bundle,report["source_sha256"],config);customers_sql,customers_plan=render_customers(bundle,report["source_sha256"],config);operations_sql,plan=render_operations(bundle,report["source_sha256"],config);drivers_sql,drivers_plan=render_drivers(bundle,report["source_sha256"],config)
   if any(token in operations_sql for token in("INSERT INTO","UPDATE ","DELETE FROM")):raise AssertionError("direct DML in operations loader")
   fixture="""INSERT INTO plataforma.roles(code,name) VALUES('phase6-ops','Phase 6 ops');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='phase6-ops' AND p.code IN('catalog.categories.write','catalog.categories.read','catalog.products.write','catalog.products.read','catalog.inventory.write','catalog.inventory.read','operations.nodes.write','operations.nodes.read','transport.drivers.write','transport.drivers.read','transport.drivers.assign','administration.parties.read','administration.parties.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00000000-0000-0000-0000-000000000003','phase6-ops@example.invalid','Phase 6 Ops');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00000000-0000-0000-0000-000000000001','phase6-ops','phase6-ops','Phase 6 Ops','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) SELECT '00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003',id,'active' FROM plataforma.roles WHERE code='phase6-ops';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00000000-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code IN('erp.catalog','erp.operations','erp.transport','erp.finance');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','Phase 6','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status) VALUES('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','NODE1','Node 1','warehouse','US','active');"""
   docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","-c",fixture)
   for filename,sql in(("catalog.sql",catalog_sql),("customers.sql",customers_sql),("operations.sql",operations_sql),("drivers.sql",drivers_sql)):
    path=work/filename;path.write_text(sql);docker("cp",str(path),f"{name}:/tmp/{filename}");docker("exec",name,"psql","-U","postgres","-f",f"/tmp/{filename}")
   docker("exec",name,"psql","-U","postgres","-f","/tmp/operations.sql")
   docker("exec",name,"psql","-U","postgres","-f","/tmp/drivers.sql")
   docker("exec",name,"psql","-U","postgres","-f","/tmp/customers.sql")
   counts=docker("exec",name,"psql","-U","postgres","-qAt","-c","SELECT (SELECT count(*) FROM operaciones.nodos),(SELECT count(*) FROM catalogo.inventarios),(SELECT count(*) FROM catalogo.movimientos_inventario),(SELECT count(*) FROM transporte.repartidores),(SELECT count(*) FROM transporte.repartidor_nodos),(SELECT count(*) FROM catalogo.terceros),(SELECT count(*) FROM administracion.perfiles_tercero),(SELECT count(*) FROM auditoria.events WHERE actor_user_id='00000000-0000-0000-0000-000000000003');").stdout.strip()
   if counts!="1|1|1|1|1|1|1|8":raise AssertionError(counts)
   print(json.dumps({"nodes_inventory":plan,"drivers":drivers_plan,"customers":customers_plan,"applied_twice":True,"counts":counts,"effective_role":"mastererp_app","remote_writes":False},indent=2,sort_keys=True))
 finally:
  if created:docker("rm","--force",name,check=False)


if __name__=="__main__":main()
