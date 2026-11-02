"""Migration Lambda for the MasterERP DEV PostgreSQL database."""

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
)
SEED_FILES = ("001_module_catalog.sql",)
TEST_FILES = (
    "onboarding_model_test.sql",
    "onboarding_authorization_test.sql",
    "shared_identity_permissions_test.sql",
    "foundation_boundaries_test.sql",
)
SQL_FILES = SCHEMA_FILES + SEED_FILES + TEST_FILES


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
    if event.get("action") in ("configure_dev_validation", "verify_dev_identity", "qa_membership_state", "qa_foundation_state"):
        from dev_validation import configure, verify, membership_state, foundation_state
        try:
            actions = {"configure_dev_validation": configure, "verify_dev_identity": verify,
                       "qa_membership_state": membership_state, "qa_foundation_state": foundation_state}
            return actions[event["action"]](connection, event, context)
        finally:
            connection.close()
    if event.get("action", "apply_model") != "apply_model":
        connection.close()
        raise ValueError("Unsupported migration action")
    phase = "lock"
    filename = "none"
    committed_passes = 0
    try:
        connection.run("SELECT pg_advisory_lock(734561903)")
        # Commit the model independently of rollback-only fixtures. A second
        # application exercises repeatability before checking effective ACLs.
        for _ in range(2):
            phase = "schema" if committed_passes == 0 else "reapply"
            connection.run("BEGIN")
            try:
                for filename in SCHEMA_FILES + SEED_FILES:
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
            "WHERE nspname IN ('plataforma', 'organizacion', 'auditoria') ORDER BY nspname"
        )]
        table_count = connection.run(
            "SELECT count(*) FROM information_schema.tables "
            "WHERE table_type = 'BASE TABLE' "
            "AND table_schema IN ('plataforma', 'organizacion', 'auditoria')"
        )[0][0]
        return {
            "status": "succeeded",
            "files_applied": list(SQL_FILES),
            "schemas": schemas,
            "table_count": table_count,
            "tests": "passed",
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
