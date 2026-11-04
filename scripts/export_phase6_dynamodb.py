"""Export one tenant from DynamoDB DEV to deterministic phase-6 JSONL."""

import argparse
import hashlib
import json
from pathlib import Path

import boto3


def scalar(item, name):
    value = item.get(name, {})
    return value.get("S") if isinstance(value, dict) else None


def belongs_to_tenant(item, tenant):
    if scalar(item, "tenantId") == tenant:
        return True
    partition = scalar(item, "PK") or ""
    prefix = f"TENANT#{tenant}"
    return partition == prefix or partition.startswith(prefix + "#")


def export(args):
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    identity = session.client("sts").get_caller_identity()
    if identity["Account"] != args.expected_account:
        raise ValueError("source account guard rejected")
    dynamodb = session.client("dynamodb")
    table = dynamodb.describe_table(TableName=args.table)["Table"]
    if table["TableStatus"] != "ACTIVE" or table["TableArn"].split(":")[3] != args.region:
        raise ValueError("source table guard rejected")
    description = dynamodb.describe_backup(BackupArn=args.backup_arn)["BackupDescription"]
    backup = description["BackupDetails"]
    if backup["BackupStatus"] != "AVAILABLE" or description["SourceTableDetails"]["TableName"] != args.table:
        raise ValueError("source backup guard rejected")

    items, scanned, start = [], 0, None
    while True:
        request = {"TableName": args.table, "ConsistentRead": True}
        if start:
            request["ExclusiveStartKey"] = start
        page = dynamodb.scan(**request)
        scanned += page["ScannedCount"]
        items.extend(item for item in page.get("Items", []) if belongs_to_tenant(item, args.tenant))
        start = page.get("LastEvaluatedKey")
        if not start:
            break
    items.sort(key=lambda item: (scalar(item, "PK") or "", scalar(item, "SK") or ""))
    body = "".join(json.dumps({"Item": item}, sort_keys=True, separators=(",", ":")) + "\n" for item in items)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(body, encoding="utf-8")
    report = {
        "account": identity["Account"], "region": args.region, "table": args.table,
        "tenant": args.tenant, "backup_arn": args.backup_arn, "scanned": scanned,
        "selected": len(items), "sha256": hashlib.sha256(body.encode()).hexdigest(),
    }
    manifest = args.output.with_suffix(args.output.suffix + ".manifest.json")
    manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--expected-account", required=True)
    parser.add_argument("--table", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--backup-arn", required=True)
    parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(export(parser.parse_args()), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
