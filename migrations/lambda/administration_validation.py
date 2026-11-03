"""DEV-only rollback validation. No arbitrary SQL accepted from invocations."""
import re
from pathlib import Path
from uuid import uuid4, uuid5, NAMESPACE_URL
from dev_validation import _dev_guard


def validate(connection, event, context):
    _dev_guard(context)
    run = "adm-qa-" + uuid4().hex
    folder = Path(__file__).parent / "administration_tests"
    fixtures = (folder / "fixtures.sql").read_text(encoding="utf-8-sig")
    texts = [fixtures] + [(folder / f).read_text(encoding="utf-8-sig") for f in
                        ("access_test.sql", "integrity_test.sql", "positive_test.sql")]
    mapping = {value: str(uuid5(NAMESPACE_URL, run + value)) for value in
               set(re.findall(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", "\n".join(texts)))}
    def transform(text):
        for old, new in mapping.items():
            text = text.replace(old, new)
        return text.replace("adm-", run + "-").replace("tenant.owner", run)
    phase = "catalog"
    results = []
    try:
        connection.run("BEGIN")
        tables = connection.run("""SELECT n.nspname,c.relname,c.relrowsecurity,
            has_table_privilege('mastererp_app',c.oid,'SELECT'),
            has_table_privilege('mastererp_app',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname IN ('administracion','catalogo') AND c.relkind='r' ORDER BY 1,2""")
        assert len(tables) == 33 and all(r[2] and r[3] and not r[4] for r in tables)
        assert not connection.run("""SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
            WHERE n.nspname IN ('administracion','catalogo') AND NOT c.convalidated""")
        assert not connection.run("""SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('administracion','catalogo')
            AND NOT i.indisvalid""")
        assert not connection.run("SELECT 1 FROM pg_roles WHERE rolname='mastererp_app' AND (rolsuper OR rolbypassrls)")
        results.append({"case":"33_tables_rls_readonly_constraints_indexes", "result":"passed"})
        phase = "fixtures"
        # Dedicated synthetic role: never grant permissions to an existing role.
        connection.run("INSERT INTO plataforma.roles(code,name) VALUES(:code,'Temporary Administration SQL QA')", code=run)
        fixture_sql = transform(fixtures).strip()
        fixture_sql = re.sub(r"^BEGIN;", "", fixture_sql)
        fixture_sql = re.sub(r"COMMIT;\s*$", "", fixture_sql)
        # Reference currencies are inserted only when absent, never updated.
        fixture_sql = fixture_sql.replace("('EUR','Fixture euro',2);", "('EUR','Fixture euro',2) ON CONFLICT DO NOTHING;")
        connection.run(fixture_sql)
        assert connection.run("SELECT count(*) FROM catalogo.monedas WHERE codigo IN ('USD','EUR') AND decimales=2")[0][0] == 2
        for filename in ("access_test.sql", "integrity_test.sql", "positive_test.sql"):
            phase = filename
            connection.run("SAVEPOINT suite")
            connection.run("SET CONSTRAINTS ALL DEFERRED")
            body = transform((folder / filename).read_text(encoding="utf-8-sig")).strip()
            body = re.sub(r"^BEGIN;", "", body)
            body = body.replace(r"\ir helpers.sql", (folder / "helpers.sql").read_text(encoding="utf-8-sig"))
            body = re.sub(r"ROLLBACK;\s*$", "", body)
            connection.run(body)
            connection.run("ROLLBACK TO SAVEPOINT suite")
            connection.run("RELEASE SAVEPOINT suite")
            results.append({"case": filename, "result":"passed"})
        connection.run("ROLLBACK")
        # Rollback, rather than deletion, removes only the synthetic test changes.
        assert connection.run("SELECT count(*) FROM plataforma.roles WHERE code=:code",code=run)[0][0] == 0
        return {"status":"succeeded", "run":run, "tests":results, "cleanup":"transaction_rolled_back",
                "effective_role":"mastererp_app_asserted_by_access_suite",
                "shared_balance_concurrency":"pending_remote; tested_in_disposable_postgresql",
                "correlation_id":getattr(context,"aws_request_id","unknown")}
    except Exception as error:
        connection.run("ROLLBACK")
        details = error.args[0] if error.args and isinstance(error.args[0],dict) else {}
        raise RuntimeError("administration_validation phase=" + phase + "; sqlstate=" + details.get("C","unknown")) from None


def concurrency(connection, context, factory):
    """Two real writers on an unused mutable condition; clean only our UUIDs."""
    from concurrent.futures import ThreadPoolExecutor
    _dev_guard(context)
    run="adm-race-"+uuid4().hex
    actor,tenant,company,condition=[str(uuid4()) for _ in range(4)]
    def scope(c):
        c.run("BEGIN")
        c.run("SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id',:tenant,true),set_config('app.correlation_id',:correlation,true)",actor=actor,tenant=tenant,correlation=str(uuid4()))
    committed=False
    try:
        scope(connection)
        connection.run("INSERT INTO plataforma.users(id,email,display_name) VALUES(:id,:email,'Administration race fixture')",id=actor,email=run+'@example.invalid')
        connection.run("INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES(:id,:code,:code,'Administration race fixture','active')",id=tenant,code=run)
        connection.run("INSERT INTO plataforma.user_tenants(tenant_id,user_id,status) VALUES(:tenant,:actor,'active')",tenant=tenant,actor=actor)
        connection.run("INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES(:id,:tenant,'Administration race fixture','US','USD','UTC')",id=company,tenant=tenant)
        connection.run("INSERT INTO administracion.condiciones_comerciales(id,tenant_id,empresa_id,codigo,descripcion,dias_plazo) VALUES(:id,:tenant,:company,'race','Fixture',0)",id=condition,tenant=tenant,company=company)
        connection.run("COMMIT");committed=True
        def writer(label):
            c=factory()
            try:
                scope(c)
                c.run("UPDATE administracion.condiciones_comerciales SET descripcion=:label,version=2 WHERE id=:id",label=label,id=condition)
                c.run("SELECT pg_sleep(0.5)");c.run("COMMIT")
                return 'committed'
            except Exception as error:
                c.run("ROLLBACK")
                details=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
                return details.get('C','unknown')
            finally:c.close()
        with ThreadPoolExecutor(max_workers=2) as pool:outcomes=list(pool.map(writer,['writer-a','writer-b']))
        assert sorted(outcomes)==['40001','committed']
        return {'status':'succeeded','case':'concurrent_stale_version','outcomes':outcomes,'cleanup':'own_fixture_UUIDs_deleted','run':run}
    finally:
        connection.run('ROLLBACK')
        if committed:
            scope(connection)
            connection.run('DELETE FROM administracion.condiciones_comerciales WHERE id=:id AND tenant_id=:tenant AND empresa_id=:company',id=condition,tenant=tenant,company=company)
            connection.run('SET CONSTRAINTS ALL IMMEDIATE')
            connection.run('DELETE FROM auditoria.events WHERE tenant_id=:tenant',tenant=tenant)
            connection.run('DELETE FROM organizacion.companies WHERE id=:id AND tenant_id=:tenant',id=company,tenant=tenant)
            connection.run('DELETE FROM plataforma.user_tenants WHERE tenant_id=:tenant AND user_id=:actor',tenant=tenant,actor=actor)
            connection.run('DELETE FROM plataforma.tenants WHERE id=:tenant AND code=:code',tenant=tenant,code=run)
            connection.run('DELETE FROM plataforma.users WHERE id=:actor AND email=:email',actor=actor,email=run+'@example.invalid')
            connection.run('COMMIT')
