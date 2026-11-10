"""Owner-approved DEV access: one Cognito identity reads Finanzas in Tumandaito.

Privileged and DEV-only, invoked explicitly through the official migration Lambda,
never HTTP. Issuer, subject, email and correlation arrive in the event; no personal
data lives in code. An identity is never linked to an internal user because an
email matches, and synthetic QA identities never enter this real space. The space
has a single reader seat: once one identity holds it, any other one is refused.
Ownership, roles, role grants, other memberships, tenant modules and business data
are never changed. Any existing state that differs from the expected one stops the
action without writing. inspect is read-only; apply is idempotent.
"""
import json
import re
from uuid import NAMESPACE_URL, UUID, uuid5

from dev_validation import ISSUER, _dev_guard

TENANT_CODE = "tumandaito"
FINANCE_MODULE = "erp.finance"
# Allow-list, not a role: the membership keeps role_id NULL (as dev_validation.configure and
# party_validation do) and holds only these true overrides. 006 has_current_tenant_permission
# then answers false for any other code, so no role grant, present or future (for example to
# the shared 047 tenant.finance_admin), can widen this read-only access.
READ_PERMISSIONS = ("administration.parties.read", "administration.purchases.read", "administration.read")
OVERRIDE = {code: True for code in READ_PERMISSIONS}
EVENT_FIELDS = {"action", "issuer", "subject", "email", "tenant_code", "permissions", "correlation_id", "operation"}
DISPLAY_NAME = "Uonify Finance member"
AUDIT_ACTION = "dev.finance.member.provisioned"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]{1,64}@(?:[A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,24}")
QA_REFUSED = "Synthetic QA identities never enter the real Tumandaito space"
LOCK_SCOPE = "mastererp-dev:business:" + TENANT_CODE  # Same lock as bootstrap_tumandaito.


def _request(event):
    """Validate the explicit contract before any database read or write."""
    if set(event) != EVENT_FIELDS:
        raise ValueError("Event fields must be exactly: " + ",".join(sorted(EVENT_FIELDS)))
    if event["issuer"] != ISSUER:
        raise ValueError("Explicit Cognito issuer required")
    if event["tenant_code"] != TENANT_CODE:
        raise ValueError("Only the approved Tumandaito space is accepted")
    permissions = event["permissions"]
    if not isinstance(permissions, list) or sorted(permissions, key=str) != sorted(READ_PERMISSIONS):
        raise ValueError("Exact Finanzas read-only permission manifest required")
    if event["operation"] not in ("inspect", "apply"):
        raise ValueError("Operation must be inspect or apply")
    email = event["email"]
    if not isinstance(email, str) or len(email) > 254 or not EMAIL.fullmatch(email):
        raise ValueError("Valid email required")
    local, domain = email.lower().rsplit("@", 1)
    if local.startswith("qa-") or domain.endswith(".invalid"):  # Repository QA convention.
        raise ValueError(QA_REFUSED)
    subject = str(event["subject"])
    if str(UUID(subject)) != subject:
        raise ValueError("Canonical Cognito subject required")
    correlation = str(UUID(str(event["correlation_id"])))
    return subject, email.lower(), correlation


def _scope(connection):
    """Unique active space, active Finanzas module, read permissions and active companies/branches."""
    tenants = connection.run("""SELECT id,code,status,deleted_at IS NULL FROM plataforma.tenants
        WHERE lower(code)=:code OR lower(slug)=:code OR lower(name)=:code""", code=TENANT_CODE)
    if len(tenants) != 1 or list(tenants[0][1:]) != [TENANT_CODE, "active", True]:
        raise ValueError("Exactly one active Tumandaito space is required")
    tenant = str(tenants[0][0])
    if not connection.run("""SELECT 1 FROM plataforma.tenant_modules tm JOIN plataforma.modules m ON m.id=tm.module_id
        WHERE tm.tenant_id=:tenant AND m.code=:module AND m.status='active' AND tm.status='active'
        AND (tm.expires_at IS NULL OR tm.expires_at>now())""", tenant=tenant, module=FINANCE_MODULE):
        raise ValueError("Finanzas module is not active in the space; tenant modules are not changed here")
    known = connection.run("SELECT count(*) FROM plataforma.permissions WHERE code=ANY(CAST(:codes AS text[]))",
                           codes=list(READ_PERMISSIONS))[0][0]
    if known != len(READ_PERMISSIONS):
        raise ValueError("Finanzas read permission catalogue missing")
    companies = [str(row[0]) for row in connection.run("""SELECT id FROM organizacion.companies
        WHERE tenant_id=:tenant AND status='active' ORDER BY id""", tenant=tenant)]
    if not companies:
        raise ValueError("The space has no active company")
    # Model 007/048: no per-user company or branch ACL exists. Read access requires the
    # company and, for sales rows, the branch to be active and contained in the tenant.
    branches = [(str(row[0]), str(row[1])) for row in connection.run("""SELECT b.company_id,b.id
        FROM organizacion.branches b JOIN organizacion.companies c ON c.id=b.company_id AND c.tenant_id=b.tenant_id
        WHERE b.tenant_id=:tenant AND b.status='active' AND c.status='active' ORDER BY b.id""", tenant=tenant)]
    return tenant, companies, branches


def _identity(connection, subject, email):
    """Reuse the active identity for issuer+sub; otherwise plan a new one. Never match by email."""
    rows = connection.run("""SELECT e.user_id,e.status,u.status,u.email=CAST(:email AS citext),
        u.display_name ILIKE 'qa-%' FROM plataforma.external_identities e JOIN plataforma.users u ON u.id=e.user_id
        WHERE e.issuer=:issuer AND e.subject=:subject""", email=email, issuer=ISSUER, subject=subject)
    if rows:
        if rows[0][4]:
            raise ValueError(QA_REFUSED)
        if list(rows[0][1:4]) != ["active", "active", True]:
            raise ValueError("Existing identity is inactive or registered with another email; preserved unchanged")
        return str(rows[0][0]), "existing"
    actor = str(uuid5(NAMESPACE_URL, ISSUER + "|" + subject))
    if connection.run("SELECT 1 FROM plataforma.users WHERE email=CAST(:email AS citext)", email=email):
        raise ValueError("Email already belongs to an internal user; identities are never linked by email")
    if connection.run("SELECT 1 FROM plataforma.users WHERE id=:actor", actor=actor):
        raise ValueError("Derived user exists without this identity; explicit reconciliation required")
    return actor, "absent"


def _membership(connection, tenant, actor):
    """An existing membership is accepted only when it already is exactly the approved allow-list."""
    rows = connection.run("""SELECT role_id,status,permissions_override FROM plataforma.user_tenants
        WHERE tenant_id=:tenant AND user_id=:actor""", tenant=tenant, actor=actor)
    if not rows:
        return "absent"
    if list(rows[0]) != [None, "active", OVERRIDE]:
        raise ValueError("Existing membership differs in role, status or overrides; preserved unchanged")
    return "existing"


def _seat(connection, tenant, actor):
    """Single seat: an allow-list membership or an earlier provisioning audit of another identity stops it."""
    holders = connection.run("""SELECT user_id FROM plataforma.user_tenants WHERE tenant_id=:tenant
        AND role_id IS NULL AND permissions_override=CAST(:override AS jsonb)
        UNION SELECT actor_user_id FROM auditoria.events WHERE tenant_id=:tenant AND action=:action""",
        tenant=tenant, override=json.dumps(OVERRIDE), action=AUDIT_ACTION)
    if any(str(row[0]) != actor for row in holders):
        raise ValueError("The Tumandaito Finanzas reader seat belongs to another identity; preserved unchanged")


def _effective_access(connection, tenant, actor, correlation, companies, branches):
    """Evaluate the member exactly as the API does: mastererp_app with actor and tenant context."""
    connection.run("SET LOCAL ROLE mastererp_app")
    if connection.run("SELECT current_user")[0][0] != "mastererp_app":
        raise ValueError("Application role required")
    connection.run("""SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id','',true),
        set_config('app.correlation_id',:correlation,true)""", actor=actor, correlation=correlation)
    spaces = {str(row[0]) for row in connection.run("SELECT tenant_id FROM plataforma.list_current_user_spaces()")}
    connection.run("SELECT set_config('app.current_tenant_id',:tenant,true)", tenant=tenant)
    context = connection.run("SELECT plataforma.current_frontend_context()")[0][0]
    checks = [(code, company, None) for company in companies for code in READ_PERMISSIONS]
    checks += [("administration.read", company, branch) for company, branch in branches]
    denied = sum(connection.run(
        "SELECT plataforma.has_current_tenant_capability(:module,:code,:company,:branch) IS NOT TRUE",
        module=FINANCE_MODULE, code=code, company=company, branch=branch)[0][0] for code, company, branch in checks)
    connection.run("RESET ROLE")
    permissions = sorted(context["permissions"])
    visible = sorted(str(company["id"]) for company in context["companies"])
    if tenant not in spaces or FINANCE_MODULE not in context["modules"]:
        raise ValueError("Space or Finanzas module not visible to the member")
    if permissions != sorted(READ_PERMISSIONS):
        raise ValueError("Effective permissions differ from the approved read-only set: " + ",".join(permissions))
    if visible != companies or denied:
        raise ValueError("Company or branch read access is incomplete")
    return {"space_visible": True, "visible_companies": len(visible), "permissions": permissions}


def _rollback(connection):
    try:
        connection.run("ROLLBACK")
    except Exception:
        pass


def provision_finance_member(connection, event, context):
    """inspect reports the state read-only; apply creates only what is missing, verified, audited."""
    _dev_guard(context)
    subject, email, correlation = _request(event)
    operation, phase = event["operation"], "scope"
    connection.run("BEGIN READ ONLY" if operation == "inspect" else "BEGIN")
    try:
        if operation == "apply":
            connection.run("SELECT pg_advisory_xact_lock(hashtextextended(:scope,0))", scope=LOCK_SCOPE)
        tenant, companies, branches = _scope(connection)
        phase = "identity"
        actor, identity = _identity(connection, subject, email)
        phase = "membership"
        membership = "absent" if identity == "absent" else _membership(connection, tenant, actor)
        _seat(connection, tenant, actor)
        if operation == "apply" and identity == "absent":
            connection.run("""INSERT INTO plataforma.users(id,email,display_name,status,identity_provider,external_identity_id)
                VALUES(:actor,CAST(:email AS citext),:name,'active','cognito',:subject)""",
                actor=actor, email=email, name=DISPLAY_NAME, subject=subject)
            connection.run("""INSERT INTO plataforma.external_identities(issuer,subject,user_id,status)
                VALUES(:issuer,:subject,:actor,'active')""", issuer=ISSUER, subject=subject, actor=actor)
            identity = "created"
        if operation == "apply" and membership == "absent":
            # role_id is deliberately left NULL: the allow-list override is the whole grant.
            member = str(connection.run("""INSERT INTO plataforma.user_tenants
                (tenant_id,user_id,status,permissions_override,joined_at)
                VALUES(:tenant,:actor,'active',CAST(:override AS jsonb),transaction_timestamp()) RETURNING id""",
                tenant=tenant, actor=actor, override=json.dumps(OVERRIDE, sort_keys=True))[0][0])
            membership = "created"
        phase = "verification"
        access = {"space_visible": False, "visible_companies": 0, "permissions": []}
        if membership != "absent":
            access = _effective_access(connection, tenant, actor, correlation, companies, branches)
        changed = membership == "created"  # A created identity always comes with a created membership.
        if changed:
            phase = "audit"
            connection.run("""INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,
                action,correlation_id,metadata) VALUES(:tenant,:actor,'1.1-tenant-onboarding','membership',:member,
                :action,:correlation,jsonb_build_object('resultado','succeeded','role',CAST(NULL AS text),
                'identity',CAST(:identity AS text),'permissions',CAST(:permissions AS jsonb),
                'explicit_owner_binding',true))""", tenant=tenant, actor=actor, member=member, action=AUDIT_ACTION,
                correlation=correlation, identity=identity, permissions=json.dumps(access["permissions"]))
        phase = "commit" if changed else "finish"
        connection.run("COMMIT" if changed else "ROLLBACK")
        return {"status": "succeeded", "operation": operation, "identity": identity, "membership": membership,
                "role": None, "module": FINANCE_MODULE, "companies": len(companies),
                "branches": len(branches), **access, "changed": changed}
    except ValueError:
        _rollback(connection)
        raise
    except Exception as error:
        _rollback(connection)
        detail = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        raise RuntimeError("Finance member provisioning failed; phase=" + phase
                           + "; sqlstate=" + str(detail.get("C", "unknown"))) from None
