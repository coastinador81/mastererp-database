"""Fixed DEV candidate races; isolated function schema and UUID-scoped fixtures."""
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from uuid import uuid4, uuid5, NAMESPACE_URL
from dev_validation import _dev_guard


def concurrency(c, context, factory):
    _dev_guard(context)
    run = 'qa_code_' + uuid4().hex
    schema = run  # Generated identifier, never input from caller.
    sql = Path(__file__).parent / 'sql'
    fixture = (sql / 'common_party_code_test.sql').read_text().split('DO $$')[0]
    ids = {v:str(uuid5(NAMESPACE_URL,run+v)) for v in set(re.findall(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',fixture))}
    def transform(text):
        for old,new in ids.items(): text=text.replace(old,new)
        return text.replace('qa-parties-sql',run).replace('qa-parties-local',run).replace('qa-party-details-foreign',run+'foreign')
    tenant=ids['00008002-0000-0000-0000-000000000001']
    other=ids['00008002-0000-0000-0000-000000000002']
    actor=ids['00008001-0000-0000-0000-000000000001']
    company=ids['00008003-0000-0000-0000-000000000001']
    def scope(conn,operation):
        conn.run('SET LOCAL ROLE mastererp_app')
        assert conn.run('SELECT current_user')[0][0]=='mastererp_app'
        for key,value in {'app.current_user_id':actor,'app.current_tenant_id':tenant,'app.current_operation':operation,'app.correlation_id':str(uuid4())}.items():
            conn.run('SELECT set_config(:key,:value,true)',key=key,value=value)
    prepared=False
    try:
        c.run('BEGIN')
        c.run('CREATE SCHEMA '+schema)
        candidate=(sql/'041_common_party_code.sql').read_text()
        candidate=candidate.replace('FUNCTION administracion.party_write(', 'FUNCTION '+schema+'.party_write(').replace('FUNCTION administracion.party_write_v2(', 'FUNCTION '+schema+'.party_write_v2(')
        c.run(candidate)
        c.run('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA '+schema+' FROM PUBLIC')
        c.run('GRANT USAGE ON SCHEMA '+schema+' TO mastererp_app')
        c.run('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA '+schema+' TO mastererp_app')
        c.run(transform(fixture).replace('BEGIN;','',1))
        scope(c,'administration.proveedor.create')
        party=c.run("SELECT administracion.party_write_v2(:company,'proveedor','create',NULL,'QA-RACE','QA race',NULL,:key,'{}',NULL,NULL)",company=company,key=run)[0][0]
        party_id=party['id']
        scope(c,'administration.cliente.create')
        c.run("SELECT administracion.party_write_v2(:company,'cliente','create',:id,NULL,NULL,NULL,:key,'{}',NULL,NULL)",company=company,id=party_id,key=run+'client')
        c.run('SET CONSTRAINTS ALL IMMEDIATE');c.run('COMMIT');prepared=True
        results=[]
        for index,roles in enumerate([('proveedor','catalog'),('cliente','proveedor'),('proveedor','proveedor')]):
            versions=c.run('SELECT t.version,s.version FROM catalogo.terceros t JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id) WHERE t.id=:id',id=party_id)[0]
            barrier=Barrier(2)
            def writer(spec):
                number,role=spec;conn=factory()
                try:
                    conn.run('BEGIN');conn.run("SET LOCAL lock_timeout='8s'")
                    scope(conn,'catalog.suppliers.update' if role=='catalog' else 'administration.'+role+'.update')
                    barrier.wait(timeout=15)
                    if role=='catalog':
                        conn.run("SELECT catalogo.proveedor_actualizar(:id,:version,'{\"name\":\"QA catalog race\"}'::jsonb)",id=party_id,version=versions[1])
                    else:
                        details='{"contactos":[{"nombre":"QA race contact","principal":false}]}' if role=='proveedor' else '{}'
                        conn.run("SELECT "+schema+".party_write_v2(:company,:role,'update',:id,:code,'QA race',:version,NULL,CAST(:details AS jsonb),NULL,:catalog_version)",company=company,role=role,id=party_id,code='QA-RACE-'+str(index)+'-'+str(number),version=versions[0],details=details,catalog_version=versions[1] if role=='proveedor' else None)
                    conn.run('SET CONSTRAINTS ALL IMMEDIATE');conn.run('COMMIT');return 'committed'
                except Exception as error:
                    conn.run('ROLLBACK')
                    detail=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
                    if detail.get('C')=='40001': return 'stale'
                    raise RuntimeError('Race sqlstate='+detail.get('C','unknown')) from None
                finally: conn.close()
            with ThreadPoolExecutor(2) as pool: outcomes=list(pool.map(writer,enumerate(roles)))
            assert sorted(outcomes)==['committed','stale']
            state=c.run('SELECT t.codigo,s.codigo,t.version,s.version FROM catalogo.terceros t JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id) WHERE t.id=:id',id=party_id)[0]
            assert state[0]==state[1] and state[2]==versions[0]+1 and state[3]==versions[1]+1
            results.append({'roles':roles,'outcomes':outcomes,'codes_equal':True,'single_version_increment':True})
        return {'status':'succeeded','tests':results,'candidate_isolated_schema':True,'production_functions_changed':False,'run':run,'cleanup':'completed_if_returned'}
    finally:
        c.run('ROLLBACK')
        if prepared:
            c.run('BEGIN')
            # Only generated tenant UUIDs belonging to this invocation are touched.
            assert c.run('SELECT count(*) FROM plataforma.tenants WHERE id=:id AND code=:code',id=tenant,code=run)[0][0]==1
            for table,column in [('auditoria.events','tenant_id'),('plataforma.idempotency_keys','request_tenant_id'),('administracion.perfiles_tercero','tenant_id'),('catalogo.proveedores_catalogo','tenant_id'),('catalogo.roles_tercero','tenant_id'),('catalogo.terceros','tenant_id'),('organizacion.companies','tenant_id'),('plataforma.tenant_modules','tenant_id'),('plataforma.user_tenants','tenant_id')]:
                c.run('DELETE FROM '+table+' WHERE '+column+' IN (:a,:b)',a=tenant,b=other)
            c.run('DELETE FROM plataforma.tenants WHERE id IN (:a,:b)',a=tenant,b=other)
            c.run('DELETE FROM plataforma.users WHERE id=:id',id=actor)
            c.run('DELETE FROM plataforma.role_permissions WHERE role_id IN (SELECT id FROM plataforma.roles WHERE code=:code)',code=run)
            c.run('DELETE FROM plataforma.roles WHERE code=:code',code=run)
            c.run('DROP SCHEMA '+schema+' CASCADE')
            c.run('SET CONSTRAINTS ALL IMMEDIATE');c.run('COMMIT')
