"""Official DEV-only, fixed-manifest sales validation. No arbitrary SQL input."""
from pathlib import Path
import hashlib
from dev_validation import _dev_guard


SCHEMA = "048_sales_read_model.sql"
TEST = "sales_read_test.sql"


def inspect(c):
    c.run("BEGIN READ ONLY")
    try:
        objects = c.run("""SELECT to_regclass('administracion.ventas_origen')::text,
            to_regprocedure('administracion.venta_desde_pedido(uuid,uuid,bigint,character varying,date,numeric,date,text)')::text,
            to_regprocedure('operaciones.pedido_transicionar(uuid,uuid,bigint,text,text,text)')::text,
            to_regprocedure('administracion.party_write_v2(uuid,text,text,uuid,text,text,bigint,text,jsonb,bigint,bigint)')::text""")[0]
        ledgers = c.run("""SELECT table_schema||'.'||table_name FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog','information_schema')
            AND (table_name ILIKE '%migration%' OR table_name IN ('schema_version','alembic_version'))""")
        return {"status": "succeeded", "read_only": True, "sales_relation": objects[0],
                "sales_command": objects[1], "order_transition": objects[2],
                "customer_command": objects[3], "migration_ledgers": [r[0] for r in ledgers],
                "finance_roles": c.run("SELECT id::text,code,name FROM plataforma.roles WHERE code ILIKE '%financ%' OR name ILIKE '%finanz%' ORDER BY code"),
                "concurrency_fixture_tenants_remaining": c.run("SELECT count(*) FROM plataforma.tenants WHERE code ~ '^qa_sales_[0-9a-f]{32}$'")[0][0]}
    finally:
        c.run("ROLLBACK")


def fixture(c, text):
    text = text.strip()
    if not text.startswith("BEGIN;") or not text.endswith("ROLLBACK;"):
        raise ValueError("Rollback fixture boundaries required")
    c.run("SAVEPOINT sales_case")
    try:
        c.run(text[len("BEGIN;"):-len("ROLLBACK;")])
        c.run("SET CONSTRAINTS ALL IMMEDIATE")
    finally:
        c.run("ROLLBACK TO SAVEPOINT sales_case")
        c.run("RELEASE SAVEPOINT sales_case")


def execute(c, event, context, factory):
    _dev_guard(context)
    action = event["action"]
    if action == "inspect_sales_candidate":
        return inspect(c)
    if action == "concurrency_sales":
        from sales_concurrency import validate
        return validate(c, context, factory)
    folder = Path(__file__).parent / "sql"
    if action == "validate_sales_regressions":
        results = []
        for name in ("customer_administration_test.sql", "common_party_code_test.sql",
                     "storefront_customer_identity_test.sql", "operations_orders_test.sql"):
            c.run("BEGIN")
            try:
                fixture(c, (folder / name).read_text(encoding="utf-8"))
                results.append({"file": name, "status": "passed"})
            except Exception as error:
                details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
                return {"status": "failed", "tests": "failed", "phase": "regression", "file": name,
                        "sqlstate": details.get("C", "validation_error"), "results": results,
                        "candidate_message": str(details.get("M", "Regression failed"))[:180],
                        "schema_applied": False, "correlation_id": context.aws_request_id}
            finally:
                c.run("ROLLBACK")
        return {"status": "succeeded", "tests": "passed", "results": results,
                "schema_applied": False, "correlation_id": context.aws_request_id}
    candidate = (folder / SCHEMA).read_text(encoding="utf-8")
    test = (folder / TEST).read_text(encoding="utf-8")
    phase, filename, passes = "baseline", SCHEMA, 0
    result = {"files_applied": [SCHEMA], "schema_sha256": hashlib.sha256(candidate.encode()).hexdigest(),
              "correlation_id": context.aws_request_id}
    try:
        c.run("SELECT pg_advisory_lock(734561903)")
        baseline = inspect(c)
        if not baseline["order_transition"] or not baseline["customer_command"] or not baseline["sales_relation"]:
            raise ValueError("Compatible DEV baseline required")
        phase = "preflight"
        c.run("BEGIN")
        try:
            c.run(candidate)
            filename = TEST
            fixture(c, test)
            filename = "sales_confirmation_contract_test.sql"
            fixture(c, (folder / filename).read_text(encoding="utf-8"))
            filename = "sales_order_command_test.sql"
            fixture(c, (folder / filename).read_text(encoding="utf-8"))
        finally:
            c.run("ROLLBACK")
        if action == "apply_sales_model":
            for phase in ("schema", "reapply"):
                filename = SCHEMA
                c.run("BEGIN")
                try:
                    c.run(candidate)
                    c.run("SET CONSTRAINTS ALL IMMEDIATE")
                    c.run("COMMIT")
                    passes += 1
                except Exception:
                    c.run("ROLLBACK")
                    raise
            phase, filename = "tests", TEST
            c.run("BEGIN")
            try:
                fixture(c, test)
                filename = "sales_confirmation_contract_test.sql"
                fixture(c, (folder / filename).read_text(encoding="utf-8"))
                filename = "sales_order_command_test.sql"
                fixture(c, (folder / filename).read_text(encoding="utf-8"))
            finally:
                c.run("ROLLBACK")
        return dict(result, status="succeeded", tests="passed", schemas=["administracion"],
                    table_count=None, committed_passes=passes, validation_only=passes == 0,
                    effective_role="mastererp_app", test_files=[TEST,"sales_confirmation_contract_test.sql","sales_order_command_test.sql"])
    except Exception as error:
        c.run("ROLLBACK")
        details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        # Return fixed phase/file and SQLSTATE only: never SQL DETAIL, values or query text.
        return dict(result, status="failed", tests="failed", phase=phase, file=filename,
                    sqlstate=details.get("C", "validation_error"), position=details.get("P"),
                    constraint=details.get("n"), committed_passes=passes,
                    candidate_message=str(details.get("M", "Candidate validation failed"))[:180])
    finally:
        c.run("SELECT pg_advisory_unlock(734561903)")
