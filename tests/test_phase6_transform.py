import json
import tempfile
import unittest
from pathlib import Path

from migration.phase6.transform_export import write_bundle
from migration.phase6.transform_export import category_slug
from migration.phase6.reconcile_bundle import reconcile
from migration.phase6.catalog_loader import render_sql
from migration.phase6.operations_inventory_loader import render_sql as render_operations
from migration.phase6.customers_loader import render_sql as render_customers
from migration.phase6.orders_preflight import inspect_bundle
from migration.phase6.active_orders_loader import render_sql as render_active_orders
from migration.phase6.historical_orders_loader import render_sql as render_historical_orders
from migration.phase6.routes_loader import render_sql as render_routes
from migration.phase6.storefront_loader import render_sql as render_storefront


class Phase6TransformTest(unittest.TestCase):
    def test_category_slug_normalizes_unicode(self):
        self.assertEqual(category_slug("Panadería y Café"), "panaderia-y-cafe")

    def test_bundle_is_deterministic_and_scoped(self):
        items = [
            {"PK":"TENANT#T001#CUSTOMER#C1","SK":"META","entityType":"CUSTOMER","tenantId":"T001","customerId":"C1","name":"Customer One","status":"ACTIVE"},
            {"PK":"TENANT#T001#PRODUCT#P1","SK":"META","entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","price":2,"categoryId":"food","status":"ACTIVE"},
            {"PK":"TENANT#T001#PRODUCT#P1","SK":"INVENTORY","tenantId":"T001","productId":"P1","nodeId":"NODE-1","stock":10,"reserved":1},
            {"PK":"TENANT#T001","SK":"NODE#NODE-1","entityType":"NODE","tenantId":"T001","nodeId":"NODE-1","status":"ACTIVE"},
            {"PK":"TENANT#T001#ORDER#O1","SK":"META","entityType":"ORDER","tenantId":"T001","orderId":"O1","customerId":"C1","status":"PENDING","subtotal":2,"nodeId":"NODE-1"},
            {"PK":"TENANT#T001#ORDER#O1","SK":"ITEM#001","entityType":"ORDER_ITEM","tenantId":"T001","orderId":"O1","itemId":"001","productId":"P1","productName":"Rice","quantity":1,"unitPrice":2},
        ]
        config = {"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","default_source_node_id":"NODE-1","node_map":{"NODE-1":"00000000-0000-0000-0000-000000000004"}}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / "source.jsonl"; settings = root / "config.json"
            source.write_text("".join(json.dumps(item)+"\n" for item in items)); settings.write_text(json.dumps(config))
            first = write_bundle(source, settings, root / "one"); second = write_bundle(source, settings, root / "two")
            self.assertEqual(first["output_sha256"], second["output_sha256"])
            self.assertEqual(first["errors"], 0)
            self.assertEqual(first["output_counts"]["products"], 1)
            self.assertEqual(first["output_counts"]["categories"], 1)
            self.assertEqual(first["output_counts"]["customers"], 1)
            inventory = json.loads((root / "one/inventories.jsonl").read_text())
            self.assertEqual(inventory["payload"]["node_id"], config["node_map"]["NODE-1"])
            self.assertTrue(reconcile(root / "one", root / "two")["ok"])
            product = root / "two/products.jsonl"
            changed = json.loads(product.read_text())
            changed["payload"]["name"] = "Changed"
            product.write_text(json.dumps(changed) + "\n")
            self.assertEqual(reconcile(root / "one", root / "two")["mismatched"], ["products:P1"])
            sql, plan = render_sql(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", sql)
            self.assertIn("SET LOCAL ROLE mastererp_app", sql)
            self.assertEqual(plan["products"], 1)
            self.assertEqual(plan["transactions"], 2)
            with self.assertRaisesRegex(ValueError, "source SHA-256 mismatch"):
                render_sql(root / "one", "0" * 64, settings)
            with self.assertRaisesRegex(ValueError, "active reservations"):
                render_operations(root / "one", first["source_sha256"], settings)
            preflight = inspect_bundle(root / "one", first["source_sha256"], settings)
            self.assertTrue(preflight["reconciled"])
            self.assertEqual(preflight["active_with_reservation"], 1)
            active_sql, active_plan = render_active_orders(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", active_sql)
            self.assertEqual(active_plan["loaded_orders"], 1)
            historical_sql, historical_plan = render_historical_orders(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", historical_sql)
            self.assertEqual(historical_plan["loaded_historical"], 0)
            routes_sql, routes_plan = render_routes(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", routes_sql)
            self.assertEqual(routes_plan["routes"], 0)
            storefront_sql, storefront_plan = render_storefront(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", storefront_sql)
            self.assertEqual(storefront_plan["stores"], 0)
            customer_sql, customer_plan = render_customers(root / "one", first["source_sha256"], settings)
            self.assertNotIn("INSERT INTO", customer_sql)
            self.assertEqual(customer_plan["customers"], 1)

    def test_wrong_tenant_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / "source.jsonl"; settings = root / "config.json"
            source.write_text(json.dumps({"entityType":"PRODUCT","tenantId":"OTHER","productId":"P1"})+"\n")
            settings.write_text(json.dumps({"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{}}))
            report = write_bundle(source, settings, root / "out")
            self.assertEqual(report["errors"], 1)

    def test_orphan_inventory_is_audited_and_excluded(self):
        items = [
            {"entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","price":2},
            {"entityType":"INVENTORY","tenantId":"T001","productId":"P1","nodeId":"N1","stock":3},
            {"entityType":"INVENTORY","tenantId":"T001","productId":"ORPHAN","nodeId":"N1","stock":7},
        ]
        config={"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{"N1":"00000000-0000-0000-0000-000000000004"}}
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);source=root/"source.jsonl";settings=root/"config.json"
            source.write_text("".join(json.dumps(item)+"\n" for item in items));settings.write_text(json.dumps(config))
            report=write_bundle(source,settings,root/"bundle")
            self.assertEqual(report["output_counts"]["inventories"],1)
            self.assertEqual(report["ignored_counts"]["orphan_inventory_product_missing"],1)
            ignored=json.loads((root/"bundle/ignored.json").read_text())
            self.assertEqual(ignored[0]["source_id"],"ORPHAN")

    def test_reservation_mismatch_is_rejected(self):
        items = [
            {"entityType":"CUSTOMER","tenantId":"T001","customerId":"C1","name":"Customer","status":"ACTIVE"},
            {"entityType":"PRODUCT","tenantId":"T001","productId":"P1","name":"Rice","price":2},
            {"entityType":"INVENTORY","tenantId":"T001","productId":"P1","nodeId":"N1","stock":10,"reserved":1},
            {"entityType":"ORDER","tenantId":"T001","orderId":"O1","customerId":"C1","nodeId":"N1","status":"RECEIVED","inventoryCommitted":True},
            {"entityType":"ORDER_ITEM","tenantId":"T001","orderId":"O1","itemId":"1","productId":"P1","productName":"Rice","quantity":2,"unitPrice":2},
        ]
        config={"source_tenant_id":"T001","target_tenant_id":"00000000-0000-0000-0000-000000000001","target_company_id":"00000000-0000-0000-0000-000000000002","actor_user_id":"00000000-0000-0000-0000-000000000003","node_map":{"N1":"00000000-0000-0000-0000-000000000004"}}
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);source=root/"source.jsonl";settings=root/"config.json";source.write_text("".join(json.dumps(item)+"\n" for item in items));settings.write_text(json.dumps(config));report=write_bundle(source,settings,root/"bundle")
            with self.assertRaisesRegex(ValueError,"reservation reconciliation failed"):
                inspect_bundle(root/"bundle",report["source_sha256"],settings)


if __name__ == "__main__": unittest.main()
