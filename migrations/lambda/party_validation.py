"""DEV HTTP fixtures only. Derived UUIDs, existing synthetic actors, bounded cleanup."""
import re
from uuid import uuid5, NAMESPACE_URL, uuid4
from dev_validation import _dev_guard


def fixture(c, event, context):
    _dev_guard(context)
    run, identity = event.get('run', ''), event.get('identity_run', '')
    action = event.get('operation')
    if not re.fullmatch(r'qa-parties-[0-9a-f]{12}', run) or not re.fullmatch(r'qa-identity-[0-9a-f]{12}', identity):
        raise ValueError('Invalid fixture identifier')
    if action not in ('prepare', 'inspect', 'restore', 'deny', 'module_disabled', 'membership_inactive', 'tenant_inactive', 'cleanup'):
        raise ValueError('Invalid fixture operation')
    ids = {name: str(uuid5(NAMESPACE_URL, run+':'+name)) for name in ('tenant_a','tenant_b','company_a','company_a2','company_b','role')}
    def scope(actor, tenant):
        c.run("SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id',:tenant,true),set_config('app.correlation_id',:correlation,true)", actor=actor, tenant=tenant, correlation=str(uuid4()))
    c.run('BEGIN')
    try:
        actors = {}
        for key, suffix in [('admin_a','admin-a'),('admin_b','admin-b'),('member_a','member-a')]:
            rows = c.run("SELECT id FROM plataforma.users WHERE email=:email AND status='active'",email=identity+'-'+suffix+'@example.invalid')
            if len(rows) != 1: raise ValueError('Existing synthetic actor missing')
            actors[key] = str(rows[0][0])
        if action == 'prepare':
            c.run("INSERT INTO plataforma.roles(id,code,name) VALUES(:id,:code,'Administration HTTP QA fixture')",id=ids['role'],code=run)
            c.run("INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT :id,code FROM plataforma.permissions WHERE code IN ('administration.parties.read','administration.parties.write','administration.purchases.read','administration.purchases.write')",id=ids['role'])
            for suffix in ('a','b'):
                tenant=ids['tenant_'+suffix]
                c.run("INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES(:id,:code,:code,'Administration HTTP QA','active')",id=tenant,code=run+'-'+suffix)
                c.run("INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) VALUES(:tenant,:actor,:role,'active')",tenant=tenant,actor=actors['admin_'+suffix],role=ids['role'])
                c.run("INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT :tenant,id,'active' FROM plataforma.modules WHERE code='erp.finance'",tenant=tenant)
            c.run("INSERT INTO plataforma.user_tenants(tenant_id,user_id,status) VALUES(:tenant,:actor,'active')",tenant=ids['tenant_a'],actor=actors['member_a'])
            for key, tenant in [('company_a','tenant_a'),('company_a2','tenant_a'),('company_b','tenant_b')]:
                c.run("INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES(:id,:tenant,'Administration HTTP QA','US','USD','UTC')",id=ids[key],tenant=ids[tenant])
        else:
            for suffix in ('a','b'):
                if c.run('SELECT count(*) FROM plataforma.tenants WHERE id=:id AND code=:code',id=ids['tenant_'+suffix],code=run+'-'+suffix)[0][0] != 1:
                    raise ValueError('Own fixtures not uniquely identified')
            if action == 'inspect':
                counts = {}
                for table in ('catalogo.terceros','administracion.perfiles_tercero','administracion.documentos','administracion.detalles_documento','plataforma.idempotency_keys','auditoria.events'):
                    column = 'request_tenant_id' if table.endswith('idempotency_keys') else 'tenant_id'
                    counts[table] = c.run('SELECT count(*) FROM '+table+' WHERE '+column+' IN (:a,:b)',a=ids['tenant_a'],b=ids['tenant_b'])[0][0]
                audit = c.run("SELECT count(*) FROM auditoria.events WHERE tenant_id=:tenant AND entity_type='tercero' AND actor_user_id=:actor AND correlation_id IS NOT NULL AND metadata->>'empresa_id' IS NOT NULL AND metadata->>'resultado'='succeeded'",tenant=ids['tenant_a'],actor=actors['admin_a'])[0][0]
                purchase_audit=c.run("SELECT count(*) FROM auditoria.events WHERE tenant_id=:tenant AND entity_type='documento' AND action LIKE 'administration.purchase.%' AND actor_user_id=:actor AND correlation_id IS NOT NULL AND metadata->>'empresa_id' IS NOT NULL AND metadata->>'resultado'='succeeded'",tenant=ids['tenant_a'],actor=actors['admin_a'])[0][0]
                c.run('ROLLBACK')
                return {'status':'succeeded','ids':ids,'counts':counts,'valid_party_audit_events':audit,'valid_purchase_audit_events':purchase_audit}
            # Restore ONLY our fresh fixture rows, never an existing user's state.
            c.run("UPDATE plataforma.tenants SET status='active' WHERE id IN (:a,:b)",a=ids['tenant_a'],b=ids['tenant_b'])
            c.run("UPDATE plataforma.user_tenants SET status='active',permissions_override='{}'::jsonb WHERE tenant_id IN (:a,:b)",a=ids['tenant_a'],b=ids['tenant_b'])
            c.run("UPDATE plataforma.tenant_modules SET status='active' WHERE tenant_id IN (:a,:b)",a=ids['tenant_a'],b=ids['tenant_b'])
            if action == 'deny':
                c.run("UPDATE plataforma.user_tenants SET permissions_override=jsonb_build_object('administration.parties.write',false,'administration.purchases.write',false) WHERE tenant_id=:tenant AND user_id=:actor",tenant=ids['tenant_a'],actor=actors['admin_a'])
            elif action == 'module_disabled':
                c.run("UPDATE plataforma.tenant_modules SET status='suspended' WHERE tenant_id=:tenant",tenant=ids['tenant_a'])
            elif action == 'membership_inactive':
                c.run("UPDATE plataforma.user_tenants SET status='inactive' WHERE tenant_id=:tenant AND user_id=:actor",tenant=ids['tenant_a'],actor=actors['admin_a'])
            elif action == 'tenant_inactive':
                c.run("UPDATE plataforma.tenants SET status='suspended' WHERE id=:tenant",tenant=ids['tenant_a'])
            elif action == 'cleanup':
                for suffix in ('a','b'):
                    tenant=ids['tenant_'+suffix]
                    scope(actors['admin_'+suffix],tenant)
                    c.run('SET CONSTRAINTS ALL DEFERRED')
                    c.run('DELETE FROM administracion.detalles_documento WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM administracion.documentos WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM administracion.perfiles_tercero WHERE tenant_id=:tenant',tenant=tenant)
                    # Only the fresh, guarded QA tenants; preserve real Tumandaito fixtures.
                    c.run('DELETE FROM administracion.descuentos_pronto_pago WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM administracion.condiciones_comerciales WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM catalogo.producto_proveedores WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM catalogo.proveedores_catalogo WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM catalogo.roles_tercero WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM catalogo.terceros WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM plataforma.idempotency_keys WHERE request_tenant_id=:tenant',tenant=tenant)
                    c.run('SET CONSTRAINTS ALL IMMEDIATE')
                    c.run('DELETE FROM auditoria.events WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM organizacion.companies WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM plataforma.tenant_modules WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM plataforma.user_tenants WHERE tenant_id=:tenant',tenant=tenant)
                    c.run('DELETE FROM plataforma.tenants WHERE id=:tenant',tenant=tenant)
                c.run('DELETE FROM plataforma.role_permissions WHERE role_id=:id',id=ids['role'])
                c.run('DELETE FROM plataforma.roles WHERE id=:id AND code=:code',id=ids['role'],code=run)
        c.run('COMMIT')
        return {'status':'succeeded','operation':action,'ids':ids,'actors':actors}
    except Exception as error:
        c.run('ROLLBACK')
        detail=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
        raise RuntimeError('Party fixture failed; operation='+str(action)+'; sqlstate='+detail.get('C','unknown')) from None
