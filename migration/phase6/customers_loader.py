"""Build restartable SQL for Customer to Tercero/Cliente migration."""

import argparse
import hashlib
import json
import re
import uuid
from pathlib import Path

from migration.phase6.catalog_loader import key, sql_literal
from migration.phase6.operations_inventory_loader import begin, read_jsonl


def verify_bundle(bundle, expected_source_sha256):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256): raise ValueError("invalid source SHA-256")
    manifest = json.loads((bundle / "manifest.json").read_text())
    if manifest.get("errors") != 0: raise ValueError("bundle contains transformation errors")
    if manifest.get("source_sha256") != expected_source_sha256: raise ValueError("source SHA-256 mismatch")
    path = bundle / "customers.jsonl"
    if hashlib.sha256(path.read_bytes()).hexdigest() != manifest.get("output_sha256", {}).get(path.name): raise ValueError("bundle hash mismatch: customers.jsonl")
    customers = read_jsonl(path); references = set()
    for row in customers:
        payload = row["payload"]; reference = str(payload.get("external_reference") or "")
        if not reference or len(reference) > 80 or reference in references: raise ValueError("customer external references must be unique and at most 80 characters")
        references.add(reference)
        if not str(payload.get("name") or "").strip() or len(str(payload["name"])) > 200: raise ValueError("customer name required and at most 200 characters")
        if payload.get("status") != "ACTIVE": raise ValueError("inactive customers require an explicit target lifecycle policy")
    return manifest, sorted(customers, key=lambda row: row["source_id"])


def customer_block(company, source_sha, row):
    payload = row["payload"]
    return f"""DO $phase6$
DECLARE current jsonb;
BEGIN
 PERFORM set_config('app.current_operation','administration.cliente.create',true);
 current:=administracion.party_write({sql_literal(company)}::uuid,'cliente','create',NULL,
  {sql_literal(payload['external_reference'])},{sql_literal(payload['name'])},NULL,
  {sql_literal(key(source_sha,'customer',row['source_id']))});
 IF administracion.cliente_id_por_referencia_externa({sql_literal(company)}::uuid,
  {sql_literal(payload['external_reference'])}) IS DISTINCT FROM (current->>'id')::uuid THEN
  RAISE EXCEPTION 'Customer reconciliation failed';
 END IF;
END $phase6$;"""


def render_sql(bundle, expected_source_sha256, config_path, batch_size=200):
    config = json.loads(config_path.read_text())
    tenant, company, actor = (config.get(name) for name in ("target_tenant_id", "target_company_id", "actor_user_id"))
    for value in (tenant, company, actor): uuid.UUID(value)
    if batch_size not in range(1, 1001): raise ValueError("batch size must be between 1 and 1000")
    manifest, customers = verify_bundle(bundle, expected_source_sha256)
    correlation = str(uuid.uuid5(uuid.UUID("56f20840-55fa-4563-8f68-1db90488da46"), expected_source_sha256))
    statements = ["\\set ON_ERROR_STOP on"]
    batches = [customers[index:index + batch_size] for index in range(0, len(customers), batch_size)]
    for number, batch in enumerate(batches, 1):
        statements.extend(begin(tenant, actor, correlation, f"phase6-customers-{expected_source_sha256}-{number}"))
        statements.extend(customer_block(company, expected_source_sha256, row) for row in batch); statements.append("COMMIT;")
    statements.append("")
    return "\n".join(statements), {"wave":"customers","source_sha256":manifest["source_sha256"],"customers":len(customers),"batch_size":batch_size,"transactions":len(batches),"direct_dml":False,"restartable":True}


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--bundle",type=Path,required=True); parser.add_argument("--config",type=Path,required=True); parser.add_argument("--expected-source-sha256",required=True); parser.add_argument("--batch-size",type=int,default=200); parser.add_argument("--emit-sql",type=Path); args = parser.parse_args()
    sql, plan = render_sql(args.bundle,args.expected_source_sha256,args.config,args.batch_size); print(json.dumps(plan,indent=2,sort_keys=True))
    if args.emit_sql: args.emit_sql.write_text(sql); print(f"SQL loader written to {args.emit_sql}; not executed.")


if __name__ == "__main__": main()
