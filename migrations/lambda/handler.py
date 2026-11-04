"""Migration Lambda for the MasterERP DEV PostgreSQL database."""

import base64
import hashlib
import json
import os
import ssl
from pathlib import Path

import boto3
import pg8000.native


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
)
SQL_FILES = SCHEMA_FILES + SEED_FILES + TEST_FILES
PHASE6_SOURCE_SHA256 = "6a6d9c5030bd7c63070a91876b9114b0d8d36553cddf8c15bc103589084a212d"
PHASE6_ARTIFACTS = (
    ("catalog", "5f71a6bc3b340d057cdda6dae45ec639d9ab28ff06fbfbcb95201593f1d7a2a2"),
    ("customers", "2a6c2d3666f653a544b6fa8fb68389b8bdcc3dd99b0a2c502f2cbcfdb8a1dac0"),
    ("operations", "fb2a134e379b8966e2244f5e247031cccf775d5b7a855a2ddc3b5434f29c49a1"),
    ("storefront", "dfbbf3b5f11773dd24c3853569f8d6b6ad064defc7707db2d9f3a804097a239e"),
)


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
            raise RuntimeError("Phase 6 load failed; artifact=" + name + "; sqlstate=" + details.get("C", "unknown")) from None
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
    if event.get("action") == "validate_party_details_candidate":
        from dev_validation import _dev_guard
        _dev_guard(context)
        try:
            connection.run("BEGIN")
            candidate=(sql_dir / "032_party_details.sql").read_text(encoding="utf-8")
            connection.run(candidate)
            connection.run((sql_dir / "party_details_test.sql").read_text(encoding="utf-8"))
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
    if event.get("action") == "party_fixture":
        from party_validation import fixture
        try:
            return fixture(connection, event, context)
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
    if event.get("action") in ("configure_dev_validation", "verify_dev_identity", "qa_membership_state", "qa_foundation_state", "inspect_foundation", "qa_dual_tenant"):
        from dev_validation import configure, verify, membership_state, foundation_state, inspect_foundation, dual_tenant
        try:
            actions = {"configure_dev_validation": configure, "verify_dev_identity": verify,
                       "qa_membership_state": membership_state, "qa_foundation_state": foundation_state, "inspect_foundation": inspect_foundation, "qa_dual_tenant": dual_tenant}
            return actions[event["action"]](connection, event, context)
        finally:
            connection.close()
    if event.get("action", "apply_model") != "apply_model":
        connection.close()
        raise ValueError("Unsupported migration action")
    phase = "lock"
    filename = "none"
    committed_passes = 0
    # 001-031 confirmed by the successful DEV workflow; do not replay their grants for this upgrade.
    applied_schema = ("032_party_details.sql", "033_canonical_owner_permissions.sql")
    if connection.run("SELECT to_regclass('administracion.perfiles_tercero') IS NOT NULL AND to_regclass('catalogo.proveedores_catalogo') IS NOT NULL")[0][0] is not True:
        connection.close()
        raise RuntimeError("Reconciled 001-031 baseline required; no automatic bootstrap")
    try:
        connection.run("SELECT pg_advisory_lock(734561903)")
        # Commit the model independently of rollback-only fixtures. A second
        # application exercises repeatability before checking effective ACLs.
        for _ in range(2):
            phase = "schema" if committed_passes == 0 else "reapply"
            connection.run("BEGIN")
            try:
                for filename in applied_schema:
                    connection.run((sql_dir / filename).read_text(encoding="utf-8"))
                connection.run("COMMIT")
                committed_passes += 1
            except Exception:
                connection.run("ROLLBACK")
                raise
        for filename in TEST_FILES:
            phase = "tests"
            try:
                connection.run((sql_dir / filename).read_text(encoding="utf-8"))
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
            "files_applied": list(applied_schema + TEST_FILES),
            "schemas": schemas,
            "table_count": table_count,
            "tests": "passed",
            "model_passes": committed_passes,
            "correlation_id": correlation_id,
        }
    except Exception as error:
        details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        sqlstate = details.get("C", "unknown")
        raise RuntimeError(
            f"phase={phase}; file={filename}; sqlstate={sqlstate}; "
            f"committed_passes={committed_passes}; correlation_id={correlation_id}"
        ) from None
    finally:
        try:
            connection.run("SELECT pg_advisory_unlock(734561903)")
        except Exception:
            pass
        connection.close()
