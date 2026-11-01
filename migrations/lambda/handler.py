"""Migration Lambda for the MasterERP DEV PostgreSQL database."""

import json
import os
import ssl
from pathlib import Path

import boto3
import pg8000.native


SQL_FILES = (
    "001_extensions_and_schemas.sql",
    "002_platform_core.sql",
    "003_tenant_onboarding.sql",
    "004_tenant_security.sql",
    "001_module_catalog.sql",
    "onboarding_model_test.sql",
)


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
    del event
    correlation_id = getattr(context, "aws_request_id", "unknown")
    sql_dir = Path(__file__).parent / "sql"
    connection = _connection()
    try:
        connection.run("SELECT pg_advisory_lock(734561903)")
        for filename in SQL_FILES:
            connection.run((sql_dir / filename).read_text(encoding="utf-8"))
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
        raise RuntimeError("Database migration failed") from error
    finally:
        try:
            connection.run("SELECT pg_advisory_unlock(734561903)")
        except Exception:
            pass
        connection.close()
