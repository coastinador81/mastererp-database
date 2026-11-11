"""Migration Lambda for the MasterERP DEV PostgreSQL database."""

import base64
import hashlib
import json
import os
import re
import ssl
from pathlib import Path

import boto3
import pg8000.native


def run_rollback_fixture(connection, path):
    """Keep rollback-only tests inside the caller transaction; check deferred FKs."""
    text = path.read_text(encoding="utf-8").strip()
    if not text.startswith("BEGIN;") or not text.endswith("ROLLBACK;"):
        raise ValueError("Rollback fixture boundaries required")
    connection.run(text[len("BEGIN;"):-len("ROLLBACK;")])
    connection.run("SET CONSTRAINTS ALL IMMEDIATE")
    connection.run("RESET ROLE")


SCHEMA_FILES = (
    "001_extensions_and_schemas.sql",
    "002_platform_core.sql",
    "003_tenant_onboarding.sql",
    "004_tenant_security.sql",
    "005_onboarding_authorization.sql",
    "006_shared_identity_permissions.sql",
    "007_foundation_boundaries.sql",
    "008_active_session_context.sql",
    "009_shared_master_references.sql",
    "010_administration_documents.sql",
    "011_administration_treasury.sql",
    "012_administration_portfolio_expenses.sql",
    "013_administration_integrity_security.sql",
    "014_administration_parties.sql",
    "015_frontend_context.sql",
    "016_operations_orders.sql",
    "017_catalog_products.sql",
    "018_operations_nodes.sql",
    "019_catalog_inventory.sql",
    "020_transport_drivers.sql",
    "021_catalog_categories.sql",
    "022_catalog_attributes.sql",
    "023_catalog_brands.sql",
    "024_catalog_suppliers.sql",
    "025_operations_preparation.sql",
    "026_operations_routes.sql",
    "027_digital_sales_ecommerce.sql",
    "028_catalog_migration_lookup.sql",
    "029_administration_migration_lookup.sql",
    "030_operations_migration_lookup.sql",
    "031_transport_migration_lookup.sql",
    "032_party_details.sql",
    "033_canonical_owner_permissions.sql",
    "034_zero_inventory_initialization.sql",
    "035_ves_currency_reference.sql",
    "036_usd_currency_reference.sql",
    "037_purchase_drafts.sql",
    "038_purchase_idempotency_binding.sql",
    "039_storefront_customer_identity.sql",
    "040_storefront_checkout.sql",
    "041_common_party_code.sql",
    "042_storefront_customer_portal.sql",
    "043_storefront_tenant_payments.sql",
    "044_customer_administration_profile.sql",
    "045_customer_legacy_contact_projection.sql",
    "046_sales_order_command.sql",
    "047_sales_confirmation_contract.sql",
    "048_sales_read_model.sql",
    "049_storefront_customer_payment_methods.sql",
    "050_storefront_store_payment_methods.sql",
    "051_operations_preparation_flow.sql",
    "052_operations_order_history_read.sql",
    "053_operations_order_cancellation_notes.sql",
    "054_finance_payment_review.sql",
)
CONFIRMED_BASELINE_SCHEMAS = (
    '015_frontend_context.sql',
    '016_operations_orders.sql',
    '017_catalog_products.sql',
    '018_operations_nodes.sql',
    '019_catalog_inventory.sql',
    '020_transport_drivers.sql',
    '021_catalog_categories.sql',
    '022_catalog_attributes.sql',
    '023_catalog_brands.sql',
    '024_catalog_suppliers.sql',
    '025_operations_preparation.sql',
    '026_operations_routes.sql',
    '027_digital_sales_ecommerce.sql',
    '028_catalog_migration_lookup.sql',
    '029_administration_migration_lookup.sql',
    '030_operations_migration_lookup.sql',
    '031_transport_migration_lookup.sql',
    '032_party_details.sql',
    '033_canonical_owner_permissions.sql',
    '034_zero_inventory_initialization.sql',
    '035_ves_currency_reference.sql',
    '036_usd_currency_reference.sql',
    '037_purchase_drafts.sql',
    '038_purchase_idempotency_binding.sql',
)
SEED_FILES = ("001_module_catalog.sql",)
TEST_FILES = (
    "onboarding_model_test.sql",
    "onboarding_authorization_test.sql",
    "shared_identity_permissions_test.sql",
    "foundation_boundaries_test.sql",
    "active_session_context_test.sql",
    "foundation_idempotency_test.sql",
    "administration_parties_test.sql",
    "frontend_context_test.sql",
    "operations_orders_test.sql",
    "catalog_products_test.sql",
    "operations_nodes_inventory_test.sql",
    "transport_drivers_test.sql",
    "catalog_categories_test.sql",
    "catalog_attributes_test.sql",
    "catalog_brands_suppliers_test.sql",
    "operations_fulfillment_ecommerce_test.sql",
    "party_details_test.sql",
    "canonical_owner_permissions_test.sql",
    "ves_currency_reference_test.sql",
    "usd_currency_reference_test.sql",
    "purchase_drafts_test.sql",
    "storefront_customer_identity_test.sql",
    "common_party_code_test.sql",
    "customer_administration_test.sql",
    "customer_legacy_contact_test.sql",
    "sales_order_command_test.sql",
    "sales_confirmation_contract_test.sql",
    "sales_read_test.sql",
    "storefront_customer_payment_methods_test.sql",
    "storefront_store_payment_methods_test.sql",
    "operations_preparation_flow_test.sql",
)
SQL_FILES = SCHEMA_FILES + SEED_FILES + TEST_FILES
PHASE6_SOURCE_SHA256 = "6a6d9c5030bd7c63070a91876b9114b0d8d36553cddf8c15bc103589084a212d"
PHASE6_ARTIFACTS = (
    ("catalog", "5f71a6bc3b340d057cdda6dae45ec639d9ab28ff06fbfbcb95201593f1d7a2a2"),
    ("customers", "2a6c2d3666f653a544b6fa8fb68389b8bdcc3dd99b0a2c502f2cbcfdb8a1dac0"),
    ("operations", "dce9404d080bfd4fa4d1bfef4bf158614ee7fff80c07ad4058c1c20e35f32ccb"),
    ("storefront", "dfbbf3b5f11773dd24c3853569f8d6b6ad064defc7707db2d9f3a804097a239e"),
)
PHASE6_SAFE_FAILURES = {
    "Customer not found", "Driver not found", "Inventory not found", "Node not found",
    "Driver unavailable", "Insufficient inventory", "Invalid node transition",
    "Invalid order transition", "Invalid preparation state", "Invalid route transition",
    "Invalid stop state", "Items pending", "Order not confirmed", "Order not preparing",
    "Order not route-ready", "Payment not ready", "Stock below reservations", "Stops pending",
    "Order not found", "Preparation item not found", "Preparation not found",
    "Product not found", "Reservation not found", "Route not found", "Stop not found",
}


def _apply_phase6(connection, event, correlation_id):
    """Apply only the reviewed phase-6 artifacts identified by exact hashes."""
    if (os.environ.get("ENVIRONMENT") != "dev" or os.environ.get("DB_NAME") != "mastererp"
            or event.get("source_sha256") != PHASE6_SOURCE_SHA256):
        raise ValueError("Phase 6 DEV guard rejected")
    supplied = event.get("artifacts")
    if not isinstance(supplied, dict) or set(supplied) != {name for name, _ in PHASE6_ARTIFACTS}:
        raise ValueError("Exact phase 6 artifact set required")
    applied = []
    for name, expected_hash in PHASE6_ARTIFACTS:
        try:
            body = base64.b64decode(supplied[name], validate=True)
            if len(body) > 150_000 or hashlib.sha256(body).hexdigest() != expected_hash:
                raise ValueError("Phase 6 artifact rejected: " + name)
            sql = body.decode("utf-8")
            sql = "\n".join(line for line in sql.splitlines() if not line.startswith("\\set"))
            upper = sql.upper()
            if any(token in upper for token in ("INSERT INTO", "UPDATE ", "DELETE FROM", "TRUNCATE ", "DROP ")):
                raise ValueError("Direct DML/DDL rejected: " + name)
            connection.run(sql)
            applied.append({"name": name, "sha256": expected_hash})
        except Exception as error:
            try:
                connection.run("ROLLBACK")
            except Exception:
                pass
            details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
            reason = details.get("M", "unknown")
            if reason not in PHASE6_SAFE_FAILURES:
                reason = "unknown"
            constraint = str(details.get("n", "unknown"))
            if not re.fullmatch(r"[a-z0-9_]{1,100}", constraint):
                constraint = "unknown"
            raise RuntimeError("Phase 6 load failed; artifact=" + name + "; sqlstate="
                               + details.get("C", "unknown") + "; reason=" + reason
                               + "; constraint=" + constraint) from None
    return {"status": "succeeded", "source_sha256": PHASE6_SOURCE_SHA256,
            "artifacts": applied, "correlation_id": correlation_id}


def _connection():
    secret_arn = os.environ["DB_SECRET_ARN"]
    secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
    settings = json.loads(secret["SecretString"])
    return pg8000.native.Connection(
        user=settings["username"],
        password=settings["password"],
        host=os.environ["DB_HOST"],
        port=int(settings.get("port", 5432)),
        database=os.environ.get("DB_NAME", "mastererp"),
        ssl_context=ssl.create_default_context(),
    )


def lambda_handler(event, context):
    """Apply the packaged database model only after an explicit invocation."""
    correlation_id = getattr(context, "aws_request_id", "unknown")
    sql_dir = Path(__file__).parent / "sql"
    connection = _connection()
    if event.get("action") == "sales_http_fixture":
        from sales_http_fixture import execute
        try:
            return execute(connection, event, context)
        finally:
            connection.close()
    if event.get("action") in ("inspect_sales_candidate", "validate_sales_candidate", "apply_sales_model", "concurrency_sales", "validate_sales_regressions"):
        from sales_validation import execute
        try:
            return execute(connection, event, context, _connection)
        finally:
            connection.close()
    if event.get("action") == "inspect_common_party_code":
        from dev_validation import _dev_guard
        _dev_guard(context)
        try:
            connection.run("BEGIN READ ONLY")
            rows = connection.run("SELECT t.tenant_id::text,t.id::text,t.codigo,s.codigo,o.tercero_id::text FROM catalogo.terceros t JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id) LEFT JOIN catalogo.proveedores_catalogo o ON o.tenant_id=t.tenant_id AND o.codigo=t.codigo AND o.tercero_id<>t.id WHERE s.codigo IS DISTINCT FROM t.codigo ORDER BY t.tenant_id,t.id")
            definitions = connection.run("SELECT p.proname,md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE (n.nspname='administracion' AND p.proname IN ('party_write','party_write_v2')) OR (n.nspname='catalogo' AND p.proname='proveedor_actualizar') ORDER BY 1")
            return {"status":"succeeded","read_only":True,"discrepancies":rows,"routine_hashes":definitions,"fixture_runs":[r[0] for r in connection.run("SELECT code FROM plataforma.tenants WHERE code ~ '^qa_code_[0-9a-f]{32}$'")]}
        finally:
            connection.run("ROLLBACK")
            connection.close()
    if event.get("action") == "common_code_http_fixture":
        from common_code_validation import http_fixture
        try:
            return http_fixture(connection,event,context)
        finally:
            connection.close()
    if event.get("action") == "cleanup_common_party_code":
        from common_code_validation import cleanup
        try:
            return cleanup(connection,context,event.get("run",""))
        finally:
            connection.close()
    if event.get("action") == "concurrency_common_party_code":
        from common_code_validation import concurrency
        try:
            return concurrency(connection, context, _connection)
        finally:
            connection.close()

    if event.get("action") in ("validate_party_details_candidate", "validate_purchase_drafts_candidate"):
        from dev_validation import _dev_guard
        _dev_guard(context)
        try:
            connection.run("BEGIN")
            purchase_candidate = event["action"] == "validate_purchase_drafts_candidate"
            candidate=(sql_dir / ("038_purchase_idempotency_binding.sql" if purchase_candidate else "032_party_details.sql")).read_text(encoding="utf-8")
            connection.run(candidate)
            connection.run((sql_dir / ("purchase_drafts_test.sql" if purchase_candidate else "party_details_test.sql")).read_text(encoding="utf-8"))
            return {"status":"succeeded","validation_only":True,"tests":"passed","committed":False}
        except Exception as error:
            details=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
            # This action only parses our bundled static SQL; never return row DETAIL or credentials.
            return {"status":"failed","validation_only":True,"committed":False,
                "sqlstate":details.get("C","unknown"),"position":details.get("P"),
                "parser_message":str(details.get("M","candidate validation failed"))[:160],
                "parser_context":str(details.get("W",""))[:160]}
        finally:
            connection.run("ROLLBACK")
            connection.close()
    if event.get("action") == "seed_tumandaito_suppliers":
        from business_samples import seed
        try:
            return seed(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "apply_phase6":
        try:
            return _apply_phase6(connection, event, correlation_id)
        finally:
            connection.close()
    if event.get("action") == "bootstrap_tumandaito_branches":
        from dev_validation import bootstrap_tumandaito_branches
        try:
            return bootstrap_tumandaito_branches(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "bootstrap_tumandaito":
        from dev_validation import bootstrap_tumandaito
        try:
            return bootstrap_tumandaito(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "inspect_business_tenant":
        from dev_validation import inspect_business_tenant
        try:
            return inspect_business_tenant(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "inspect_phase6":
        from phase6_validation import inspect_phase6
        try:
            return inspect_phase6(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "party_fixture":
        from party_validation import fixture
        try:
            return fixture(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "provision_phase8_owner":
        from phase8_access import provision
        try:
            return provision(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "provision_uonify_finance_member":
        from uonify_access import provision_finance_member
        try:
            return provision_finance_member(connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "validate_administration":
        from administration_validation import validate, concurrency
        try:
            if event.get("mode") == "concurrency":
                return concurrency(connection, context, _connection)
            return validate(connection, event, context)
        finally:
            connection.close()
    if event.get("action") in ("configure_dev_validation", "verify_dev_identity", "qa_membership_state", "qa_foundation_state", "inspect_foundation", "qa_dual_tenant", "qa_phase8_membership"):
        from dev_validation import configure, verify, membership_state, foundation_state, inspect_foundation, dual_tenant, phase8_membership
        try:
            actions = {"configure_dev_validation": configure, "verify_dev_identity": verify,
                       "qa_membership_state": membership_state, "qa_foundation_state": foundation_state,
                       "inspect_foundation": inspect_foundation, "qa_dual_tenant": dual_tenant,
                       "qa_phase8_membership": phase8_membership}
            return actions[event["action"]](connection, event, context)
        finally:
            connection.close()
    if event.get("action") == "configure_dev_storefront_payments":
        from storefront_validation import configure_payments
        try:
            return configure_payments(connection, event, context)
        finally:
            connection.close()
    if event.get("action", "apply_model") not in ("apply_model", "validate_common_party_code_candidate", "validate_customer_admin_candidate", "apply_operations_model", "validate_operations_candidate"):
        connection.close()
        raise ValueError("Unsupported migration action")
    phase = "lock"
    filename = "none"
    committed_passes = 0
    # Fixed reviewed manifests; no event can supply arbitrary SQL filenames.
    applied_schema = ("051_operations_preparation_flow.sql", "052_operations_order_history_read.sql",
                      "053_operations_order_cancellation_notes.sql", "054_finance_payment_review.sql")
    operations = event.get("action") in ("apply_operations_model", "validate_operations_candidate")
    selected_schema = applied_schema[1:] if operations else applied_schema[:1]
    selected_tests = (("operations_orders_test.sql", "operations_fulfillment_ecommerce_test.sql") if operations else
        ("operations_preparation_flow_test.sql", "operations_orders_test.sql", "operations_fulfillment_ecommerce_test.sql", "storefront_store_payment_methods_test.sql", "storefront_customer_payment_methods_test.sql", "customer_legacy_contact_test.sql", "customer_administration_test.sql", "common_party_code_test.sql", "administration_parties_test.sql", "party_details_test.sql", "catalog_brands_suppliers_test.sql"))
    if connection.run("SELECT to_regclass('administracion.perfiles_tercero') IS NOT NULL AND to_regclass('catalogo.proveedores_catalogo') IS NOT NULL AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ventas_digitales' AND p.proname='checkout_crear') AND to_regprocedure('administracion.party_write_v2(uuid,text,text,uuid,text,text,bigint,text,jsonb,bigint,bigint)') IS NOT NULL AND NOT has_table_privilege('mastererp_app','catalogo.terceros','UPDATE')")[0][0] is not True:
        connection.close()
        raise RuntimeError("Compatible 001-040 baseline required; no automatic bootstrap")
    try:
        connection.run("SELECT pg_advisory_lock(734561903)")
        # Validate this candidate and effective-app tests in a transaction BEFORE committing DDL.
        # The trusted test has a terminal ROLLBACK; it also undoes the candidate schema.
        phase = "preflight"
        connection.run("BEGIN")
        try:
            for filename in selected_schema:
                connection.run((sql_dir / filename).read_text(encoding="utf-8"))
            for filename in selected_tests:
                run_rollback_fixture(connection, sql_dir / filename)
        finally:
            connection.run("ROLLBACK")
        if event.get("action") in ("validate_common_party_code_candidate", "validate_customer_admin_candidate", "validate_operations_candidate"):
            return {"status":"succeeded","tests":"passed","validation_only":True,
                    "committed_passes":0,"files_applied":list(selected_schema),
                    "schemas":[],"table_count":None,"correlation_id":correlation_id}
        # Commit the model independently of rollback-only fixtures. A second
        # application exercises repeatability before checking effective ACLs.
        for _ in range(2):
            phase = "schema" if committed_passes == 0 else "reapply"
            connection.run("BEGIN")
            try:
                for filename in selected_schema:
                    connection.run((sql_dir / filename).read_text(encoding="utf-8"))
                connection.run("COMMIT")
                committed_passes += 1
            except Exception:
                connection.run("ROLLBACK")
                raise
        for filename in selected_tests:
            phase = "tests"
            connection.run("BEGIN")
            try:
                run_rollback_fixture(connection, sql_dir / filename)
            finally:
                connection.run("ROLLBACK")
        schemas = [row[0] for row in connection.run(
            "SELECT nspname FROM pg_namespace "
            "WHERE nspname IN ('plataforma', 'organizacion', 'auditoria', 'catalogo', 'administracion', 'operaciones', 'transporte', 'ventas_digitales') ORDER BY nspname"
        )]
        table_count = connection.run(
            "SELECT count(*) FROM information_schema.tables "
            "WHERE table_type = 'BASE TABLE' "
            "AND table_schema IN ('plataforma', 'organizacion', 'auditoria', 'catalogo', 'administracion', 'operaciones', 'transporte', 'ventas_digitales')"
        )[0][0]
        return {
            "status": "succeeded",
            "files_applied": list(selected_schema + selected_tests),
            "schemas": schemas,
            "table_count": table_count,
            "tests": "passed",
            "model_passes": committed_passes,
            "correlation_id": correlation_id,
        }
    except Exception as error:
        details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        sqlstate = details.get("C", "unknown")
        message = re.sub(r"[^A-Za-z0-9 _-]", "", str(details.get("M", "migration failed")))[:160]
        return {"status":"failed","tests":"failed","phase":phase,"file":filename,
                "sqlstate":sqlstate,"constraint":re.sub(r'[^A-Za-z0-9_]','',str(details.get('n','unknown'))),
                "candidate_message":message,"committed_passes":committed_passes,
                "correlation_id":correlation_id}
    finally:
        try:
            connection.run("SELECT pg_advisory_unlock(734561903)")
        except Exception:
            pass
        connection.close()
