"""Compare a restored DEV DynamoDB table with a deterministic Phase 8 export."""
import argparse
import hashlib
import json
from pathlib import Path

import boto3

from export_phase6_dynamodb import belongs_to_tenant, scalar


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--expected-account", required=True)
    parser.add_argument("--table", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    if session.client("sts").get_caller_identity()["Account"] != args.expected_account:
        raise ValueError("restore account guard rejected")
    dynamodb = session.client("dynamodb")
    table = dynamodb.describe_table(TableName=args.table)["Table"]
    if table["TableStatus"] != "ACTIVE" or not args.table.endswith("-rollback-drill-20261105"):
        raise ValueError("isolated rollback table guard rejected")

    items, start = [], None
    while True:
        request = {"TableName": args.table, "ConsistentRead": True}
        if start:
            request["ExclusiveStartKey"] = start
        page = dynamodb.scan(**request)
        items.extend(item for item in page.get("Items", []) if belongs_to_tenant(item, args.tenant))
        start = page.get("LastEvaluatedKey")
        if not start:
            break
    items.sort(key=lambda item: (scalar(item, "PK") or "", scalar(item, "SK") or ""))
    body = "".join(json.dumps({"Item": item}, sort_keys=True, separators=(",", ":")) + "\n" for item in items)
    expected = args.source.read_bytes()
    actual = body.encode()
    report = {"table": args.table, "tenant": args.tenant, "items": len(items),
              "expected_sha256": hashlib.sha256(expected).hexdigest(),
              "actual_sha256": hashlib.sha256(actual).hexdigest(),
              "matches": actual == expected}
    print(json.dumps(report, indent=2, sort_keys=True))
    if not report["matches"]:
        raise SystemExit(3)


if __name__ == "__main__":
    main()
