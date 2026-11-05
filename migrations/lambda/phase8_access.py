"""Owner-approved DEV access provisioning for the Phase 8 acceptance test."""
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from dev_validation import ISSUER, _dev_guard

APPROVED_EMAIL = "andrea.madriz@eticayservicios.com"


def provision(connection, event, context):
    _dev_guard(context)
    subject = str(UUID(str(event.get("subject", ""))))
    if event.get("issuer") != ISSUER or event.get("email") != APPROVED_EMAIL:
        raise ValueError("Explicit approved identity required")
    actor = str(uuid5(NAMESPACE_URL, ISSUER + "|" + subject))
    tenant_rows = connection.run("""SELECT id FROM plataforma.tenants
        WHERE code='tumandaito' AND status='active'""")
    if len(tenant_rows) != 1:
        raise ValueError("Active Tumandaito tenant must be unique")
    tenant = str(tenant_rows[0][0])
    identity = connection.run("""SELECT e.user_id,e.status,u.email,u.status
        FROM plataforma.external_identities e JOIN plataforma.users u ON u.id=e.user_id
        WHERE e.issuer=:issuer AND e.subject=:subject""", issuer=ISSUER, subject=subject)
    candidates = connection.run("""SELECT DISTINCT t.id,t.nombre,p.empresa_id,t.codigo,p.datos_comerciales,p.creado_en,
          (SELECT count(*) FROM operaciones.pedidos o WHERE o.tenant_id=t.tenant_id AND o.cliente_id=t.id)
        FROM catalogo.terceros t JOIN administracion.perfiles_tercero p
          ON p.tenant_id=t.tenant_id AND p.tercero_id=t.id
        WHERE t.tenant_id=:tenant AND p.rol='cliente' AND lower(t.nombre) LIKE '%andrea%'
        ORDER BY t.nombre""", tenant=tenant)
    if event.get("operation") == "inspect":
        memberships = [] if not identity else connection.run("""SELECT r.code,ut.status
            FROM plataforma.user_tenants ut JOIN plataforma.roles r ON r.id=ut.role_id
            WHERE ut.tenant_id=:tenant AND ut.user_id=:actor""", tenant=tenant, actor=str(identity[0][0]))
        return {"status":"succeeded","actor_found":bool(identity),"memberships":[list(x) for x in memberships],
                "customers":[{"id":str(x[0]),"name":x[1],"company_id":str(x[2]),"code":x[3],
                              "details":x[4],"created_at":x[5].isoformat(),"orders":x[6]} for x in candidates]}
    if event.get("operation") == "invite":
        customer = str(UUID(str(event.get("customer_id", ""))))
        selected = [x for x in candidates if str(x[0]) == customer and x[6] > 0]
        if len(identity) != 1 or len(selected) != 1:
            raise ValueError("Active identity and historical customer required")
        actor = str(identity[0][0]); company = str(selected[0][2])
        membership = connection.run("""SELECT 1 FROM plataforma.user_tenants ut JOIN plataforma.roles r ON r.id=ut.role_id
            WHERE ut.tenant_id=:tenant AND ut.user_id=:actor AND ut.status='active' AND r.code='tenant.owner'""",
            tenant=tenant, actor=actor)
        stores = connection.run("""SELECT id FROM ventas_digitales.tiendas
            WHERE tenant_id=:tenant AND empresa_id=:company AND estado='ACTIVE'""", tenant=tenant, company=company)
        if len(membership) != 1 or len(stores) != 1: raise ValueError("Owner and active store must be unique")
        token = secrets.token_urlsafe(32); digest = hashlib.sha256(token.encode()).hexdigest(); correlation = str(uuid4())
        connection.run("BEGIN")
        try:
            connection.run("SET LOCAL ROLE mastererp_app")
            connection.run("""SELECT set_config('app.current_user_id',:actor,true),
                set_config('app.current_tenant_id',:tenant,true),set_config('app.correlation_id',:correlation,true),
                set_config('app.current_operation','digital_sales.storefront.invitation.create',true)""",
                actor=actor, tenant=tenant, correlation=correlation)
            invitation = connection.run("""SELECT ventas_digitales.cliente_invitacion_crear(
                :company,:store,:customer,:digest,:expires)""", company=company, store=str(stores[0][0]),
                customer=customer, digest=digest, expires=datetime.now(timezone.utc)+timedelta(hours=24))[0][0]
            connection.run("COMMIT")
            return {"status":"succeeded","token":token,"invitation":invitation}
        except Exception:
            connection.run("ROLLBACK"); raise
    correlation = str(uuid4())
    connection.run("BEGIN")
    try:
        connection.run("SELECT pg_advisory_xact_lock(hashtextextended('phase8:andrea-access',0))")
        if identity:
            if len(identity) != 1 or list(identity[0][1:]) != ['active', APPROVED_EMAIL, 'active']:
                raise ValueError("Existing identity differs")
            actor = str(identity[0][0])
        else:
            if connection.run("SELECT 1 FROM plataforma.users WHERE email=:email", email=APPROVED_EMAIL):
                raise ValueError("Email requires identity reconciliation")
            connection.run("""INSERT INTO plataforma.users(id,email,display_name,status)
                VALUES(:actor,:email,'Andrea Madriz','active')""", actor=actor, email=APPROVED_EMAIL)
            connection.run("""INSERT INTO plataforma.external_identities(issuer,subject,user_id,status)
                VALUES(:issuer,:subject,:actor,'active')""", issuer=ISSUER, subject=subject, actor=actor)
        role = connection.run("SELECT id FROM plataforma.roles WHERE code='tenant.owner'")
        if len(role) != 1: raise ValueError("Owner role must be unique")
        existing = connection.run("""SELECT role_id,status FROM plataforma.user_tenants
            WHERE tenant_id=:tenant AND user_id=:actor""", tenant=tenant, actor=actor)
        if not existing:
            connection.run("""INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status,joined_at)
                VALUES(:tenant,:actor,:role,'active',transaction_timestamp())""",
                tenant=tenant, actor=actor, role=str(role[0][0]))
        elif len(existing) != 1 or str(existing[0][0]) != str(role[0][0]) or existing[0][1] != 'active':
            raise ValueError("Existing membership differs")
        connection.run("""INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,
            entity_id,action,correlation_id,metadata) VALUES(:tenant,:actor,'1.1-tenant-onboarding','tenant',
            :tenant,'dev.phase8.owner.provisioned',:correlation,
            jsonb_build_object('approved_email',CAST(:email AS text)))""",
            tenant=tenant, actor=actor, correlation=correlation, email=APPROVED_EMAIL)
        connection.run("COMMIT")
        return {"status":"succeeded","tenant_id":tenant,"actor_id":actor}
    except Exception:
        connection.run("ROLLBACK")
        raise
