"""DEV-only fixture using existing synthetic Cognito actors, never real customer rows."""
from pathlib import Path
from uuid import uuid4, uuid5, NAMESPACE_URL
import re
from dev_validation import _dev_guard


def execute(c, event, context):
    _dev_guard(context)
    run, identity, operation = event.get("run", ""), event.get("identity_run", ""), event.get("operation")
    if not re.fullmatch(r"qa-sales-http-[0-9a-f]{12}", run) or not re.fullmatch(r"qa-identity-[0-9a-f]{12}", identity):
        raise ValueError("Identified synthetic fixture required")
    if operation not in ("prepare", "prepare_read", "read_denied", "inspect", "deny", "module_disabled", "membership_inactive", "restore", "archive"):
        raise ValueError("Unknown fixture operation")
    actor_rows = c.run("SELECT id::text FROM plataforma.users WHERE email=:email AND status='active'",
                       email=identity + "-admin-a@example.invalid")
    if len(actor_rows) != 1:
        raise ValueError("Existing synthetic actor required")
    actor = actor_rows[0][0]
    text = (Path(__file__).parent / "sql/sales_order_command_test.sql").read_text()
    setup = text.split("SET LOCAL ROLE mastererp_app;")[0][len("BEGIN;"):]
    ids = {v: str(uuid5(NAMESPACE_URL, run + v)) for v in set(re.findall(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", setup))}
    ids["00014601-0000-0000-0000-000000000001"] = actor
    tenant = ids["00014602-0000-0000-0000-000000000001"]
    company = ids["00014603-0000-0000-0000-000000000001"]
    order = ids["00014608-0000-0000-0000-000000000001"]
    orders = [order, str(uuid5(NAMESPACE_URL, run + "order2")), str(uuid5(NAMESPACE_URL, run + "order3"))]
    other_company = str(uuid5(NAMESPACE_URL, run + ":read-other-company"))
    foreign_tenant = str(uuid5(NAMESPACE_URL, run + ":read-foreign-tenant"))
    foreign_company = str(uuid5(NAMESPACE_URL, run + ":read-foreign-company"))
    c.run("BEGIN")
    try:
        if operation == "prepare":
            assert c.run("SELECT count(*) FROM plataforma.roles WHERE code='tenant.finance_admin'")[0][0] == 1
            setup = setup[setup.index("INSERT INTO plataforma.users"):]
            setup = re.sub(r"INSERT INTO plataforma.users.*?;\n", "", setup, count=1, flags=re.S)
            for old, new in ids.items():
                setup = setup.replace(old, new)
            setup = setup.replace("qa-sales-046-sql", "tenant.finance_admin").replace("qa-sales-046", run)
            setup = setup.replace("sales-046-order-key", run + "-order1")
            c.run(setup)
            for index, target in enumerate(orders[1:], 2):
                key, reserve = run + "-order" + str(index), str(uuid5(NAMESPACE_URL, run + "reserve" + str(index)))
                c.run("""INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
                    VALUES(:key,:actor,'operations.orders.create',:tenant,repeat('a',64))""", key=key, actor=actor, tenant=tenant)
                c.run("""INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
                    SELECT :id,tenant_id,empresa_id,nodo_id,:target,:key,creado_por FROM catalogo.reservas_inventario
                    WHERE tenant_id=:tenant LIMIT 1""", id=reserve, target=target, key=key, tenant=tenant)
                c.run("""INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
                    cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key,creado_por)
                    SELECT :id,tenant_id,empresa_id,sucursal_id,cliente_id,:number,'PENDING',moneda,subtotal,
                    cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,:reserve,:key,creado_por
                    FROM operaciones.pedidos WHERE id=:source""", id=target, number=run + "-" + str(index), reserve=reserve, key=key, source=order)
                c.run("""INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
                    SELECT tenant_id,empresa_id,:id,posicion,producto_id,producto_nombre,cantidad,precio_unitario
                    FROM operaciones.pedido_lineas WHERE pedido_id=:source""", id=target, source=order)
                c.run("""INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
                    VALUES(:tenant,:company,:id,'PENDING','STOREFRONT_CHECKOUT',:actor,:correlation)""",
                    tenant=tenant, company=company, id=target, actor=actor, correlation=str(uuid4()))
        else:
            assert c.run("SELECT count(*) FROM plataforma.tenants WHERE id=:id AND code=:code", id=tenant, code=run)[0][0] == 1
            if operation == "prepare_read":
                assert c.run("SELECT count(*) FROM administracion.ventas_origen WHERE tenant_id=:tenant", tenant=tenant)[0][0] == 3
                c.run("UPDATE plataforma.tenants SET status='active' WHERE id=:tenant", tenant=tenant)
                c.run("UPDATE plataforma.user_tenants SET status='active',permissions_override='{}' WHERE tenant_id=:tenant AND user_id=:actor", tenant=tenant, actor=actor)
                c.run("INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES(:id,:tenant,'Sales read QA empty company','US','USD','UTC') ON CONFLICT(id) DO NOTHING", id=other_company, tenant=tenant)
                c.run("INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES(:id,:code,:code,'Sales read QA foreign','active') ON CONFLICT(id) DO NOTHING", id=foreign_tenant, code=run + "-read-foreign")
                c.run("INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES(:id,:tenant,'Sales read QA foreign company','US','USD','UTC') ON CONFLICT(id) DO NOTHING", id=foreign_company, tenant=foreign_tenant)
            if operation == "read_denied":
                c.run("UPDATE plataforma.user_tenants SET permissions_override=CAST(:value AS jsonb) WHERE tenant_id=:tenant AND user_id=:actor",
                      value='{"administration.read":false}', tenant=tenant, actor=actor)
            if operation in ("deny", "restore"):
                c.run("UPDATE plataforma.user_tenants SET permissions_override=CAST(:value AS jsonb) WHERE tenant_id=:tenant AND user_id=:actor",
                      value='{"administration.sales.write":false}' if operation == "deny" else '{}', tenant=tenant, actor=actor)
            if operation in ("module_disabled", "restore"):
                c.run("UPDATE plataforma.tenant_modules SET status=:status WHERE tenant_id=:tenant AND module_id IN(SELECT id FROM plataforma.modules WHERE code='erp.finance')",
                      status="suspended" if operation == "module_disabled" else "active", tenant=tenant)
            if operation in ("membership_inactive", "restore", "archive"):
                c.run("UPDATE plataforma.user_tenants SET status=:status WHERE tenant_id=:tenant AND user_id=:actor",
                      status="active" if operation == "restore" else "inactive", tenant=tenant, actor=actor)
            if operation == "archive":
                c.run("UPDATE plataforma.tenants SET status='suspended' WHERE id=:id AND code=:code", id=tenant, code=run)
                c.run("UPDATE plataforma.tenants SET status='suspended' WHERE id=:id AND code=:code", id=foreign_tenant, code=run + "-read-foreign")
        rows = c.run("""SELECT v.pedido_id::text,v.venta_id::text,v.estado,d.total::text,d.cerrado FROM administracion.ventas_origen v
            JOIN administracion.documentos d ON d.id=v.venta_id WHERE v.tenant_id=:tenant ORDER BY v.pedido_id""", tenant=tenant)
        order_states = c.run("SELECT id::text,estado,version FROM operaciones.pedidos WHERE tenant_id=:tenant ORDER BY id", tenant=tenant)
        audit_sales = c.run("SELECT count(*) FROM auditoria.events WHERE tenant_id=:tenant AND actor_user_id=:actor AND action='administracion.documento.venta.crear' AND correlation_id IS NOT NULL", tenant=tenant, actor=actor)[0][0]
        audit_orders = c.run("SELECT count(*) FROM auditoria.events WHERE tenant_id=:tenant AND actor_user_id=:actor AND action='operations.orders.transition' AND correlation_id IS NOT NULL", tenant=tenant, actor=actor)[0][0]
        tenant_status = c.run("SELECT status FROM plataforma.tenants WHERE id=:tenant", tenant=tenant)[0][0]
        c.run("SET CONSTRAINTS ALL IMMEDIATE")
        c.run("COMMIT")
        return {"status": "succeeded", "tenant": tenant, "company": company, "orders": orders,
                "other_company": other_company, "foreign_tenant": foreign_tenant, "foreign_company": foreign_company,
                "sales": rows, "order_states": order_states, "audit_sales": audit_sales,
                "audit_orders": audit_orders, "tenant_status": tenant_status, "operation": operation,
                "archive_note": "Immutable QA sale history retained in inactive DEV fixture tenant" if operation == "archive" else None}
    except Exception as error:
        c.run("ROLLBACK")
        details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        raise RuntimeError("Sales HTTP fixture failed; operation=" + str(operation)
                           + "; sqlstate=" + details.get("C", "unknown")) from None
