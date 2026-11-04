"""Validate completed Route replay twice in disposable PostgreSQL."""
import json,subprocess,tempfile,time,uuid
from pathlib import Path
from migration.phase6.catalog_loader import render_sql as render_catalog
from migration.phase6.customers_loader import render_sql as render_customers
from migration.phase6.routes_loader import render_sql as render_routes
from migration.phase6.transform_export import write_bundle
ROOT=Path(__file__).resolve().parents[1];IMAGE="public.ecr.aws/docker/library/postgres:17.9-alpine"


def main():
 name="mastererp-phase6-routes-"+uuid.uuid4().hex[:10];created=False
 def docker(*args,check=True):
  result=subprocess.run(["docker",*args],capture_output=True,text=True)
  if check and result.returncode:raise RuntimeError(result.stderr[-2500:])
  return result
 try:
  docker("image","inspect",IMAGE);docker("run","--detach","--rm","--network","none","--name",name,"-e","POSTGRES_HOST_AUTH_METHOD=trust",IMAGE);created=True
  for _ in range(80):
   if docker("exec",name,"pg_isready","-U","postgres",check=False).returncode==0:time.sleep(.5);break
   time.sleep(.25)
  else:raise RuntimeError("PostgreSQL not ready")
  for folder in("schema","seeds"):
   docker("cp",str(ROOT/folder),f"{name}:/tmp/{folder}")
   for path in sorted((ROOT/folder).glob("*.sql")):docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","--single-transaction","-f",f"/tmp/{folder}/{path.name}")
  with tempfile.TemporaryDirectory()as temp:
   work=Path(temp);source=work/"source.jsonl";config=work/"config.json";bundle=work/"bundle";items=[{"entityType":"CUSTOMER","tenantId":"T001","customerId":"C1","name":"Customer","status":"ACTIVE"},{"entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","price":2,"categoryId":"food","status":"ACTIVE"},{"entityType":"NODE","tenantId":"T001","nodeId":"N1","status":"ACTIVE","acceptsOrders":True},{"entityType":"INVENTORY","tenantId":"T001","productId":"P1","nodeId":"N1","stock":10,"reserved":0},{"entityType":"DRIVER","tenantId":"T001","driverId":"D1","name":"Driver","phone":"04140000000","status":"AVAILABLE","accessStatus":"LINKED"},{"entityType":"NODE_DRIVER","tenantId":"T001","nodeId":"N1","driverId":"D1"},{"entityType":"ORDER","tenantId":"T001","orderId":"O1","customerId":"C1","customerSnapshot":{"name":"Customer"},"nodeId":"N1","routeId":"R1","status":"DELIVERED","inventoryCommitted":False,"currency":"USD","subtotal":2,"deliveryFee":0,"paymentSnapshot":{"method":"cash","status":"PENDING_COLLECTION"}},{"entityType":"ORDER_ITEM","tenantId":"T001","orderId":"O1","itemId":"1","productId":"P1","productName":"Rice","quantity":1,"unitPrice":2},{"entityType":"ROUTE","tenantId":"T001","routeId":"R1","nodeId":"N1","driverId":"D1","deliveryDate":"2026-11-04","status":"COMPLETED","orderIds":["O1"]}]
   source.write_text("".join(json.dumps(item)+"\n"for item in items));settings={"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{"N1":"00000000-0000-0000-0000-000000000004"}};config.write_text(json.dumps(settings));report=write_bundle(source,config,bundle);catalog_sql,_=render_catalog(bundle,report["source_sha256"],config);customers_sql,_=render_customers(bundle,report["source_sha256"],config);routes_sql,plan=render_routes(bundle,report["source_sha256"],config)
   if any(token in routes_sql for token in("INSERT INTO","UPDATE ","DELETE FROM")):raise AssertionError("direct DML in Routes loader")
   fixture="""INSERT INTO plataforma.roles(code,name) VALUES('phase6-routes','Phase 6 routes');INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='phase6-routes' AND p.code IN('catalog.categories.write','catalog.categories.read','catalog.products.write','catalog.products.read','catalog.inventory.write','catalog.inventory.read','catalog.inventory.reserve','operations.nodes.write','operations.nodes.read','operations.orders.write','operations.orders.read','operations.preparation.write','operations.preparation.read','operations.routes.write','operations.routes.read','administration.parties.read','administration.parties.write','transport.drivers.write','transport.drivers.read','transport.drivers.assign');INSERT INTO plataforma.users(id,email,display_name) VALUES('00000000-0000-0000-0000-000000000003','phase6-routes@example.invalid','Phase 6 Routes');INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00000000-0000-0000-0000-000000000001','phase6-routes','phase6-routes','Phase 6 Routes','active');INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) SELECT '00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003',id,'active' FROM plataforma.roles WHERE code='phase6-routes';INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00000000-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code IN('erp.catalog','erp.operations','erp.finance','erp.transport');INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','Phase 6','US','USD','UTC');INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status) VALUES('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','N1','Node 1','warehouse','US','active');""";docker("exec",name,"psql","-U","postgres","-v","ON_ERROR_STOP=1","-c",fixture)
   for filename,sql in(("catalog.sql",catalog_sql),("customers.sql",customers_sql),("routes.sql",routes_sql)):
    path=work/filename;path.write_text(sql);docker("cp",str(path),f"{name}:/tmp/{filename}");docker("exec",name,"psql","-U","postgres","-f",f"/tmp/{filename}")
   docker("exec",name,"psql","-U","postgres","-f","/tmp/routes.sql");counts=docker("exec",name,"psql","-U","postgres","-qAt","-c","SELECT (SELECT count(*) FROM operaciones.rutas),(SELECT estado FROM operaciones.rutas),(SELECT estado FROM operaciones.ruta_paradas),(SELECT estado FROM operaciones.pedidos),(SELECT disponibilidad FROM transporte.repartidores),(SELECT existencia||'|'||reservado FROM catalogo.inventarios);").stdout.strip()
   if counts!="1|COMPLETED|DELIVERED|DELIVERED|AVAILABLE|10|0":raise AssertionError(counts)
   print(json.dumps({"routes":plan,"applied_twice":True,"counts":counts,"effective_role":"mastererp_app","remote_writes":False},indent=2,sort_keys=True))
 finally:
  if created:docker("rm","--force",name,check=False)


if __name__=="__main__":main()
