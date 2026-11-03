"""Apply the generated catalog loader twice in disposable PostgreSQL."""

import json
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from migration.phase6.catalog_loader import render_sql
from migration.phase6.transform_export import write_bundle


ROOT = Path(__file__).resolve().parents[1]
IMAGE = "public.ecr.aws/docker/library/postgres:17.9-alpine"


def main():
    name = "mastererp-phase6-catalog-" + uuid.uuid4().hex[:10]
    created = False
    def docker(*args, check=True):
        result = subprocess.run(["docker", *args], capture_output=True, text=True)
        if check and result.returncode: raise RuntimeError(result.stderr[-2000:])
        return result
    try:
        docker("image", "inspect", IMAGE)
        docker("run", "--detach", "--rm", "--network", "none", "--name", name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", IMAGE)
        created = True
        for _ in range(80):
            if docker("exec", name, "pg_isready", "-U", "postgres", check=False).returncode == 0: break
            time.sleep(.25)
        else: raise RuntimeError("PostgreSQL not ready")
        for folder in ("schema", "seeds"):
            docker("cp", str(ROOT / folder), f"{name}:/tmp/{folder}")
            for path in sorted((ROOT / folder).glob("*.sql")):
                docker("exec", name, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-f", f"/tmp/{folder}/{path.name}")
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp); source = work / "source.jsonl"; config = work / "config.json"; bundle = work / "bundle"
            item = {"PK":"TENANT#T001#PRODUCT#P1","SK":"META","entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","description":"One kg","price":2.5,"categoryId":"food","status":"ACTIVE","attributes":{"unit":"kg"}}
            source.write_text(json.dumps(item) + "\n")
            settings = {"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{}}
            config.write_text(json.dumps(settings)); report = write_bundle(source, config, bundle)
            sql, plan = render_sql(bundle, report["source_sha256"], config)
            if "INSERT INTO" in sql or "UPDATE " in sql or "DELETE FROM" in sql: raise AssertionError("direct DML in generated loader")
            loader = work / "loader.sql"; loader.write_text(sql)
            fixture = """INSERT INTO plataforma.roles(code,name) VALUES('phase6-loader','Phase 6 loader');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='phase6-loader' AND p.code IN('catalog.categories.write','catalog.categories.read','catalog.products.write','catalog.products.read');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00000000-0000-0000-0000-000000000003','phase6@example.invalid','Phase 6');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00000000-0000-0000-0000-000000000001','phase6','phase6','Phase 6','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) SELECT '00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003',id,'active' FROM plataforma.roles WHERE code='phase6-loader';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00000000-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.catalog';"""
            docker("exec", name, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-c", fixture)
            docker("cp", str(loader), f"{name}:/tmp/loader.sql")
            first = docker("exec", name, "psql", "-U", "postgres", "-f", "/tmp/loader.sql")
            second = docker("exec", name, "psql", "-U", "postgres", "-f", "/tmp/loader.sql")
            counts = docker("exec", name, "psql", "-U", "postgres", "-qAt", "-c", "SELECT (SELECT count(*) FROM catalogo.categorias),(SELECT count(*) FROM catalogo.productos WHERE referencia_externa='P1'),(SELECT count(*) FROM auditoria.events WHERE actor_user_id='00000000-0000-0000-0000-000000000003');").stdout.strip()
            if counts != "1|1|2": raise AssertionError(counts)
            result = {**plan, "applied_twice": True, "counts": counts, "effective_role": "mastererp_app", "remote_writes": False, "first_ok": first.returncode == 0, "second_ok": second.returncode == 0}
            print(json.dumps(result, indent=2, sort_keys=True))
    finally:
        if created: docker("rm", "--force", name, check=False)


if __name__ == "__main__": main()
