"""Build a transactional, idempotent SQL loader for Categories and Products."""

import argparse
import hashlib
import json
import re
import uuid
from decimal import Decimal, InvalidOperation
from pathlib import Path


def sql_literal(value):
    if value is None: return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def read_jsonl(path):
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip(): continue
        item = json.loads(line)
        if not item.get("source_id") or not isinstance(item.get("payload"), dict):
            raise ValueError(f"invalid row {number} in {path.name}")
        rows.append(item)
    return rows


def verify_bundle(bundle, expected_source_sha256):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256): raise ValueError("invalid source SHA-256")
    manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("errors") != 0: raise ValueError("bundle contains transformation errors")
    if manifest.get("source_sha256") != expected_source_sha256: raise ValueError("source SHA-256 mismatch")
    for name in ("categories.jsonl", "products.jsonl"):
        actual = hashlib.sha256((bundle / name).read_bytes()).hexdigest()
        if manifest.get("output_sha256", {}).get(name) != actual: raise ValueError(f"bundle hash mismatch: {name}")
    categories, products = read_jsonl(bundle / "categories.jsonl"), read_jsonl(bundle / "products.jsonl")
    slugs = {row["payload"].get("slug") for row in categories}
    if None in slugs or len(slugs) != len(categories): raise ValueError("category slugs must be unique")
    for row in categories:
        payload = row["payload"]
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", str(payload.get("slug", ""))): raise ValueError("invalid category slug")
        if not str(payload.get("name") or "").strip(): raise ValueError("category name required")
    references = {row["payload"].get("category_ref") for row in products if row["payload"].get("category_ref")}
    missing = sorted(references - slugs)
    if missing: raise ValueError("product categories missing from bundle: " + ", ".join(missing))
    external = [row["payload"].get("external_reference") for row in products]
    if None in external or len(set(external)) != len(external): raise ValueError("product external references must be unique")
    for row in products:
        payload = row["payload"]
        if not str(payload.get("name") or "").strip(): raise ValueError("product name required")
        try: price = Decimal(str(payload.get("price")))
        except (InvalidOperation, ValueError): raise ValueError("invalid product price") from None
        if not price.is_finite() or price <= 0: raise ValueError("invalid product price")
        if payload.get("status", "ACTIVE") not in {"ACTIVE", "INACTIVE", "DRAFT", "DISCONTINUED"}: raise ValueError("invalid product status")
        if not isinstance(payload.get("attributes", {}), dict): raise ValueError("product attributes must be an object")
    return manifest, sorted(categories, key=lambda row: row["payload"]["slug"]), sorted(products, key=lambda row: row["source_id"])


def key(source_sha, kind, source_id):
    digest = hashlib.sha256(f"{source_sha}:{kind}:{source_id}".encode()).hexdigest()[:40]
    return f"phase6-catalog-{kind}-{digest}"


def render_sql(bundle, expected_source_sha256, config_path, batch_size=200):
    manifest, categories, products = verify_bundle(bundle, expected_source_sha256)
    if batch_size not in range(1, 1001): raise ValueError("batch size must be between 1 and 1000")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    tenant, actor = config.get("target_tenant_id"), config.get("actor_user_id")
    uuid.UUID(tenant); uuid.UUID(actor)
    correlation = str(uuid.uuid5(uuid.UUID("7ea7fd51-a261-4baa-b74a-ea18c8415969"), expected_source_sha256))
    def begin(batch):
        lock = f"phase6-catalog-{expected_source_sha256}-{batch}"
        return ["BEGIN;", f"SELECT pg_advisory_xact_lock(hashtextextended({sql_literal(lock)},0));", "SET LOCAL ROLE mastererp_app;", f"SELECT set_config('app.current_tenant_id',{sql_literal(tenant)},true);", f"SELECT set_config('app.current_user_id',{sql_literal(actor)},true);", f"SELECT set_config('app.correlation_id',{sql_literal(correlation)},true);"]
    statements = ["\\set ON_ERROR_STOP on", *begin("categories")]
    for row in categories:
        payload = row["payload"]
        statements.extend([
            "SELECT set_config('app.current_operation','catalog.categories.create',true);",
            "SELECT catalogo.categoria_crear(" + ",".join([
                sql_literal(payload["slug"]), sql_literal(payload["name"]), sql_literal(payload.get("description", "")),
                sql_literal(payload.get("parent_slug")), sql_literal(payload.get("image_url")),
                str(int(payload.get("sort_order", 0))), sql_literal(key(expected_source_sha256, "category", row["source_id"])),
            ]) + ");",
        ])
    statements.append("COMMIT;")
    batches = [products[index:index + batch_size] for index in range(0, len(products), batch_size)]
    for index, batch in enumerate(batches, 1):
        statements.extend(begin(f"products-{index}"))
        for row in batch:
            payload = row["payload"]
            statements.extend(["SELECT set_config('app.current_operation','catalog.products.create',true);", "SELECT catalogo.producto_crear(" + ",".join([sql_literal(payload["name"]), sql_literal(payload.get("description", "")), str(payload["price"]), sql_literal(payload.get("status", "ACTIVE")), sql_literal(payload.get("category_ref")), sql_literal(payload.get("image_url")), sql_literal(json.dumps(payload.get("attributes", {}), sort_keys=True, separators=(",", ":"))) + "::jsonb", sql_literal(payload["external_reference"]), sql_literal(key(expected_source_sha256, "product", row["source_id"]))]) + ");"])
        statements.append("COMMIT;")
    statements.append("")
    plan = {"wave": "catalog-categories-products", "source_sha256": manifest["source_sha256"], "categories": len(categories), "products": len(products), "batch_size": batch_size, "transactions": 1 + len(batches), "transactional_batches": True, "restartable": True, "idempotent": True, "direct_dml": False}
    return "\n".join(statements), plan


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-source-sha256", required=True)
    parser.add_argument("--batch-size", type=int, default=200)
    parser.add_argument("--emit-sql", type=Path)
    args = parser.parse_args()
    sql, plan = render_sql(args.bundle, args.expected_source_sha256, args.config, args.batch_size)
    print(json.dumps(plan, indent=2, sort_keys=True))
    if args.emit_sql:
        args.emit_sql.write_text(sql, encoding="utf-8")
        print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__ == "__main__": main()
