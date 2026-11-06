"""Real independent DEV sessions; competing sales are rolled back, not persisted."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from time import monotonic, sleep
from uuid import uuid4, uuid5, NAMESPACE_URL
import re
from dev_validation import _dev_guard


def validate(c, context, factory):
    _dev_guard(context)
    run = "qa_sales_" + uuid4().hex
    text = (Path(__file__).parent / "sql/sales_order_command_test.sql").read_text()
    setup = text.split("SET LOCAL ROLE mastererp_app;")[0][len("BEGIN;"):]
    ids = {v: str(uuid5(NAMESPACE_URL, run + v)) for v in
           set(re.findall(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", setup))}
    for old, new in ids.items():
        setup = setup.replace(old, new)
    setup = setup.replace("qa-sales-046-sql", run).replace("qa-sales-046", run)
    setup = setup.replace("sales-046-order-key", run + "-order")
    tenant = ids["00014602-0000-0000-0000-000000000001"]
    actor = ids["00014601-0000-0000-0000-000000000001"]
    company = ids["00014603-0000-0000-0000-000000000001"]
    order = ids["00014608-0000-0000-0000-000000000001"]

    def scope(conn, app=True):
        if app:
            conn.run("SET LOCAL ROLE mastererp_app")
            assert conn.run("SELECT current_user")[0][0] == "mastererp_app"
        for key, value in {"app.current_user_id": actor, "app.current_tenant_id": tenant,
                           "app.current_operation": "administracion.documento.venta.crear",
                           "app.correlation_id": str(uuid4())}.items():
            conn.run("SELECT set_config(:key,:value,true)", key=key, value=value)

    prepared = False
    try:
        c.run("BEGIN")
        c.run(setup)
        c.run("SET CONSTRAINTS ALL IMMEDIATE")
        c.run("COMMIT")
        prepared = True
        results = []
        for same_key in (True, False):
            ready, competing = Event(), Event()
            def writer(first):
                conn = factory()
                try:
                    conn.run("BEGIN")
                    conn.run("SET LOCAL lock_timeout='8s'")
                    scope(conn)
                    if not first:
                        if not ready.wait(10):
                            raise RuntimeError("First writer unavailable")
                        competing.set()
                    start = monotonic()
                    key = run + ("-same" if same_key else ("-a" if first else "-b"))
                    result = conn.run("""SELECT administracion.venta_desde_pedido(
                        :company,:order,1,:key,DATE '2026-11-06')""",
                        company=company, order=order, key=key)[0][0]
                    conn.run("SET CONSTRAINTS ALL IMMEDIATE")
                    elapsed = monotonic() - start
                    if first:
                        ready.set()
                        if not competing.wait(10):
                            raise RuntimeError("Second writer unavailable")
                        sleep(0.6)
                    return {"status": result["estado"], "wait_seconds": round(elapsed, 3)}
                finally:
                    conn.run("ROLLBACK")
                    conn.close()
            with ThreadPoolExecutor(max_workers=2) as pool:
                a, b = pool.submit(writer, True), pool.submit(writer, False)
                left, right = a.result(timeout=30), b.result(timeout=30)
            assert left["status"] == right["status"] == "ACTIVE"
            assert right["wait_seconds"] >= 0.4, "Competing writer did not serialize"
            assert c.run("SELECT count(*) FROM administracion.ventas_origen WHERE tenant_id=:tenant", tenant=tenant)[0][0] == 0
            results.append({"scenario": "same_key" if same_key else "different_key_same_order",
                            "effective_role": "mastererp_app", "second_wait_seconds": right["wait_seconds"],
                            "first": "rolled_back", "second": "succeeded_then_rolled_back"})
        return {"status": "succeeded", "tests": "passed", "results": results,
                "scope": "rollback contention; committed replay covered by SQL transaction test, not this race",
                "correlation_id": context.aws_request_id}
    finally:
        if prepared:
            c.run("BEGIN")
            try:
                assert c.run("SELECT count(*) FROM plataforma.tenants WHERE id=:tenant AND code=:code", tenant=tenant, code=run)[0][0] == 1
                scope(c, False)
                for table, column in (("operaciones.pedido_eventos", "tenant_id"),
                        ("operaciones.pedido_lineas", "tenant_id"), ("operaciones.pedidos", "tenant_id"),
                        ("catalogo.reservas_inventario", "tenant_id"), ("operaciones.nodos", "tenant_id"),
                        ("administracion.perfiles_tercero", "tenant_id"), ("catalogo.roles_tercero", "tenant_id"),
                        ("catalogo.terceros", "tenant_id"), ("catalogo.productos", "tenant_id"),
                        ("organizacion.branches", "tenant_id"), ("auditoria.events", "tenant_id"),
                        ("plataforma.idempotency_keys", "request_tenant_id"),
                        ("organizacion.companies", "tenant_id"), ("plataforma.tenant_modules", "tenant_id"),
                        ("plataforma.user_tenants", "tenant_id")):
                    c.run("DELETE FROM " + table + " WHERE " + column + "=:tenant", tenant=tenant)
                c.run("DELETE FROM plataforma.tenants WHERE id=:tenant AND code=:code", tenant=tenant, code=run)
                c.run("DELETE FROM plataforma.users WHERE id=:actor", actor=actor)
                c.run("DELETE FROM plataforma.role_permissions WHERE role_id IN (SELECT id FROM plataforma.roles WHERE code=:code)", code=run)
                c.run("DELETE FROM plataforma.roles WHERE code=:code", code=run)
                c.run("SET CONSTRAINTS ALL IMMEDIATE")
                c.run("COMMIT")
            except Exception:
                c.run("ROLLBACK")
                raise
