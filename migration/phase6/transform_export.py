"""Transform an offline Tu Mandadito DynamoDB JSONL export into a canonical bundle.

The tool never connects to AWS or PostgreSQL. Outputs are deterministic and are
safe inputs for review/reconciliation before an explicitly authorized loader.
"""

import argparse
import hashlib
import json
import re
import unicodedata
import uuid
from collections import Counter, defaultdict
from decimal import Decimal
from pathlib import Path


KINDS = ("categories", "products", "customers", "nodes", "inventories", "drivers", "orders", "order_items", "routes", "stores")
TYPE_TO_KIND = {
    "PRODUCT": "products", "NODE": "nodes", "DRIVER": "drivers",
    "CUSTOMER": "customers", "ORDER": "orders", "ORDER_ITEM": "order_items", "ROUTE": "routes",
}
NAMESPACE = uuid.UUID("21449f35-58fa-42ee-b9cd-c403b5998482")


def category_slug(value):
    raw = str(value or "otros").strip().lower()
    ascii_value = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_value).strip("-") or "otros"


def _decode(value):
    if not isinstance(value, dict) or len(value) != 1:
        return value
    key, raw = next(iter(value.items()))
    if key == "S": return raw
    if key == "N": return Decimal(raw)
    if key == "BOOL": return raw
    if key == "NULL": return None
    if key == "M": return {name: _decode(item) for name, item in raw.items()}
    if key == "L": return [_decode(item) for item in raw]
    if key in {"SS", "NS"}: return [_decode({key[0]: item}) for item in raw]
    return value


def decode_export(line):
    raw = json.loads(line, parse_float=Decimal)
    item = raw.get("Item", raw)
    return {name: _decode(value) for name, value in item.items()}


def stable_id(tenant_id, kind, source_id):
    return str(uuid.uuid5(NAMESPACE, f"{tenant_id}:{kind}:{source_id}"))


def source_id(item, entity_type):
    fields = {"PRODUCT": "productId", "NODE": "nodeId", "DRIVER": "driverId", "CUSTOMER": "customerId", "ORDER": "orderId", "ORDER_ITEM": "itemId", "ROUTE": "routeId"}
    value = item.get(fields.get(entity_type, ""))
    if value is None and entity_type == "INVENTORY":
        value = item.get("productId") or str(item.get("PK", "")).rsplit("#PRODUCT#", 1)[-1]
    return str(value or "").strip()


def normalized_type(item):
    entity_type = str(item.get("entityType") or "").upper()
    if entity_type:
        return entity_type
    sk = str(item.get("SK") or "")
    pk = str(item.get("PK") or "")
    if sk == "INVENTORY" and "#PRODUCT#" in pk: return "INVENTORY"
    if sk.startswith("ITEM#") and "#ORDER#" in pk: return "ORDER_ITEM"
    return ""


def _number(value, default=0):
    return str(Decimal(str(value if value is not None else default)))


def map_item(item, config):
    entity_type = normalized_type(item)
    kind = "inventories" if entity_type == "INVENTORY" else TYPE_TO_KIND.get(entity_type)
    if not kind:
        return None
    tenant = str(item.get("tenantId") or "")
    if tenant != config["source_tenant_id"]:
        raise ValueError("tenant mismatch")
    external = source_id(item, entity_type)
    if not external:
        raise ValueError(f"{entity_type} identifier missing")
    target = stable_id(config["target_tenant_id"], kind, external)
    common = {"source_id": external, "target_id": target, "source_updated_at": item.get("updatedAt")}
    if kind == "products":
        category = category_slug(item.get("categoryId"))
        payload = {"code": str(item.get("sku") or external), "name": item.get("name"), "description": item.get("description") or "", "price": _number(item.get("price")), "status": item.get("status") or "ACTIVE", "category_ref": category, "image_url": item.get("imageUrl"), "attributes": item.get("attributes") or {}, "external_reference": external}
        return kind, {**common, "payload": payload}, category
    if kind == "customers":
        name = str(item.get("name") or "").strip()
        if not name:
            name = " ".join(value for value in (str(item.get("givenName") or "").strip(), str(item.get("familyName") or "").strip()) if value)
        payload = {"code": external, "name": name or external, "status": str(item.get("status") or "ACTIVE").upper(), "email": item.get("email"), "phone": item.get("phone"), "identity_reference": item.get("cognitoSub"), "external_reference": external}
        return kind, {**common, "payload": payload}, None
    if kind == "nodes":
        branch = config.get("node_map", {}).get(external)
        if not branch: raise ValueError(f"node mapping missing: {external}")
        payload = {"branch_id": branch, "status": item.get("status") or "DRAFT", "accepts_orders": bool(item.get("acceptsOrders", item.get("status") == "ACTIVE")), "coverage_radius_km": _number(item.get("coverageRadiusKm")), "daily_capacity": int(item.get("dailyCapacity") or 0), "minimum_order": _number(item.get("minimumOrder")), "delivery_fee": _number(item.get("deliveryFee")), "opening_time": item.get("openingTime"), "closing_time": item.get("closingTime"), "location": {key: item.get(key) for key in ("state", "municipality", "parish", "sector", "address", "reference", "latitude", "longitude") if item.get(key) is not None}, "external_reference": external}
        return kind, {**common, "target_id": branch, "payload": payload}, None
    if kind == "inventories":
        node = str(item.get("nodeId") or config.get("default_source_node_id") or "")
        branch = config.get("node_map", {}).get(node)
        if not branch: raise ValueError(f"inventory node mapping missing: {node}")
        payload = {"node_id": branch, "product_id": stable_id(config["target_tenant_id"], "products", external), "stock": _number(item.get("stock")), "reserved": _number(item.get("reserved", item.get("reservedStock", 0))), "sales_enabled": bool(item.get("salesEnabled", True))}
        return kind, {**common, "payload": payload}, None
    if kind == "drivers":
        nodes = [config.get("node_map", {}).get(str(node)) for node in item.get("nodeIds", [])]
        vehicle = item.get("vehicle") if isinstance(item.get("vehicle"), dict) else {"description": item.get("vehicle")} if item.get("vehicle") else {}
        if item.get("plate"): vehicle["plate"] = item["plate"]
        access = {"ACTIVE": "LINKED", "ERROR": "ERROR", "DISABLED": "DISABLED"}.get(str(item.get("accessStatus") or ""), "PENDING")
        payload = {"code": str(item.get("code") or external), "name": item.get("name"), "phone": item.get("phone"), "email": item.get("email"), "status": "ACTIVE" if item.get("status") != "OFFLINE" else "INACTIVE", "availability": item.get("status") or "OFFLINE", "access_status": access, "vehicle": vehicle, "license": item.get("license") if isinstance(item.get("license"), dict) else {}, "node_ids": [node for node in nodes if node], "route_external_id": item.get("routeId"), "external_reference": external}
        return kind, {**common, "payload": payload}, None
    if kind == "orders":
        status = {"RECEIVED":"PENDING","PREPARED":"READY","IN_ROUTE":"OUT_FOR_DELIVERY"}.get(item.get("status"), item.get("status"))
        node = config.get("node_map", {}).get(str(item.get("nodeId") or config.get("default_source_node_id") or ""))
        payload = {"company_id": config["target_company_id"], "node_id": node, "customer_external_id": item.get("customerId"), "customer_snapshot": item.get("customerSnapshot") or {}, "number": item.get("orderNumber") or external, "status": status, "inventory_committed": bool(item.get("inventoryCommitted", status in {"PENDING","CONFIRMED","PREPARING"})), "currency": item.get("currency") or config.get("currency", "USD"), "subtotal": _number(item.get("subtotal")), "delivery_fee": _number(item.get("deliveryFee")), "delivery_address_snapshot": item.get("deliveryAddressSnapshot") or {}, "payment_snapshot": item.get("paymentSnapshot") or item.get("payment") or {}, "delivery_window_ref": item.get("deliveryWindowId") or "legacy", "delivery_method": item.get("deliveryMethod") or "scheduled", "route_external_id": item.get("routeId"), "external_reference": external}
        return kind, {**common, "payload": payload}, None
    if kind == "order_items":
        order = str(item.get("orderId") or str(item.get("PK", "")).rsplit("#ORDER#", 1)[-1])
        payload = {"order_external_id": order, "order_id": stable_id(config["target_tenant_id"], "orders", order), "position": int(str(item.get("SK") or "ITEM#1").split("#")[-1]), "product_external_id": str(item.get("productId") or ""), "product_id": stable_id(config["target_tenant_id"], "products", str(item.get("productId"))), "product_name": item.get("productName"), "quantity": _number(item.get("quantity")), "unit_price": _number(item.get("unitPrice")), "preparation_status": item.get("preparationStatus") or "PENDING"}
        return kind, {**common, "target_id": stable_id(config["target_tenant_id"], kind, f"{order}:{external}"), "payload": payload}, None
    if kind == "routes":
        node = config.get("node_map", {}).get(str(item.get("nodeId") or config.get("default_source_node_id") or ""))
        payload = {"company_id": config["target_company_id"], "node_id": node, "driver_external_id": str(item.get("driverId")) if item.get("driverId") else None, "date": item.get("deliveryDate"), "status": item.get("status") or "PLANNED", "delivery_window_ref": item.get("deliveryWindowId"), "order_external_ids": [str(value) for value in item.get("orderIds", [])], "external_reference": external}
        return kind, {**common, "payload": payload}, None
    raise ValueError(f"unsupported kind: {kind}")


def map_stores(item, config):
    tenant=str(item.get("tenantId")or"")
    if tenant!=config["source_tenant_id"]:raise ValueError("tenant mismatch")
    merchant=str(item.get("merchantId")or"").strip()
    mappings=config.get("store_map",{}).get(merchant)
    if not merchant or not isinstance(mappings,list)or not mappings:raise ValueError(f"store mapping missing: {merchant}")
    records=[]
    for mapping in mappings:
        source_node=str(mapping.get("source_node_id")or"");node=config.get("node_map",{}).get(source_node);domain=str(mapping.get("domain")or"").lower().strip()
        if not node or not domain:raise ValueError(f"store node/domain mapping missing: {merchant}")
        external=f"{merchant}:{source_node}:{domain}";configuration={name:item.get(name)for name in("phone","address","currency","deliveryFee","minOrder","route1Close","route1Window","route2Close","route2Window","payments","deliverySlots")if item.get(name)is not None}
        records.append({"source_id":external,"target_id":stable_id(config["target_tenant_id"],"stores",external),"source_updated_at":item.get("updatedAt"),"payload":{"node_id":node,"domain":domain,"name":mapping.get("name")or item.get("name")or merchant,"status":mapping.get("status","ACTIVE"),"branding":{"logo":item.get("logo")or""},"configuration":configuration,"modules":mapping.get("modules",[]),"external_reference":external}})
    return records


def validate_config(config):
    for field in ("source_tenant_id", "target_tenant_id", "target_company_id", "actor_user_id"):
        if not config.get(field): raise ValueError(f"config field required: {field}")
    for field in ("target_tenant_id", "target_company_id", "actor_user_id"):
        uuid.UUID(config[field])
    for value in config.get("node_map", {}).values(): uuid.UUID(value)


def write_bundle(source, config_path, output):
    config = json.loads(config_path.read_text(encoding="utf-8"))
    validate_config(config)
    records, errors, ignored, source_counts, categories = defaultdict(list), [], [], Counter(), set()
    ignored_counts = Counter()
    decoded = [(number, decode_export(line)) for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1) if line.strip()]
    scoped_inventory_products = {
        str(item.get("productId") or "") for _, item in decoded
        if normalized_type(item) == "INVENTORY" and item.get("nodeId")
    }
    driver_nodes = defaultdict(list)
    for _, item in decoded:
        if normalized_type(item) == "NODE_DRIVER" and str(item.get("tenantId") or "") == config["source_tenant_id"]:
            driver_nodes[str(item.get("driverId") or "")].append(str(item.get("nodeId") or ""))
    for number, item in decoded:
        entity_type = normalized_type(item)
        try:
            if (entity_type == "INVENTORY" and not item.get("nodeId")
                    and str(item.get("productId") or "") in scoped_inventory_products):
                ignored_counts["legacy_global_inventory_shadowed_by_node"] += 1
                ignored.append({"line": number, "entity_type": entity_type,
                                "source_id": source_id(item, entity_type),
                                "reason": "legacy_global_inventory_shadowed_by_node"})
                continue
            if entity_type == "ROUTE" and not item.get("orderIds"):
                ignored_counts["empty_route_without_orders"] += 1
                ignored.append({"line": number, "entity_type": entity_type,
                                "source_id": source_id(item, entity_type),
                                "reason": "empty_route_without_orders",
                                "status": item.get("status")})
                continue
            if entity_type == "MERCHANT":
                stores=map_stores(item,config);records["stores"].extend(stores);source_counts["stores"]+=len(stores);continue
            if entity_type == "DRIVER" and driver_nodes.get(str(item.get("driverId") or "")):
                item = {**item, "nodeIds": sorted(set(driver_nodes[str(item.get("driverId"))]))}
            mapped = map_item(item, config)
            if not mapped: continue
            kind, record, category = mapped
            source_counts[kind] += 1
            records[kind].append(record)
            if category: categories.add(category)
        except (ValueError, TypeError, ArithmeticError) as error:
            errors.append({"line": number, "entity_type": entity_type, "source_id": source_id(item, entity_type), "error": str(error)})
    records["categories"] = [{"source_id": slug, "target_id": stable_id(config["target_tenant_id"], "categories", slug), "payload": {"slug": slug, "name": slug.replace("-", " ").title(), "status": "ACTIVE"}} for slug in categories]
    output.mkdir(parents=True, exist_ok=True)
    hashes, output_counts = {}, {}
    for kind in KINDS:
        path = output / f"{kind}.jsonl"
        body = "".join(json.dumps(item, sort_keys=True, separators=(",", ":"), default=str) + "\n" for item in sorted(records[kind], key=lambda value: (value["source_id"], value["target_id"])))
        path.write_text(body, encoding="utf-8")
        hashes[path.name] = hashlib.sha256(body.encode()).hexdigest()
        output_counts[kind] = len(records[kind])
    (output / "errors.json").write_text(json.dumps(errors, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output / "ignored.json").write_text(json.dumps(ignored, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report = {"mode": "offline-transform", "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "config_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(), "source_counts": dict(sorted(source_counts.items())), "output_counts": output_counts, "ignored_counts": dict(sorted(ignored_counts.items())), "errors": len(errors), "output_sha256": hashes, "remote_reads": False, "database_writes": False}
    (output / "manifest.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = write_bundle(args.source, args.config, args.output)
    print(json.dumps(report, indent=2, sort_keys=True))
    if report["errors"]: raise SystemExit(2)


if __name__ == "__main__": main()
