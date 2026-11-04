"""Validate Database manifest, tests, non-destructive SQL and source size."""

import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = tuple(f"{number:03d}_" for number in range(15, 35))
TESTS = (
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
)


def require(condition, message):
    if not condition:
        raise SystemExit("ERROR: " + message)


def manifest_constants(path):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in {"SCHEMA_FILES", "TEST_FILES", "CONFIRMED_BASELINE_SCHEMAS"}:
                values[node.targets[0].id] = ast.literal_eval(node.value)
    assignments=[node for node in ast.walk(tree) if isinstance(node,ast.Assign) and isinstance(node.targets[0],ast.Name) and node.targets[0].id=='applied_schema']
    require(len(assignments)==1,'one explicit applied_schema upgrade manifest required')
    values['applied_schema']=ast.literal_eval(assignments[0].value)
    return values


def main():
    handler = ROOT / "migrations/lambda/handler.py"
    constants = manifest_constants(handler)
    baseline=constants.get('CONFIRMED_BASELINE_SCHEMAS',())
    upgrade=constants['applied_schema']
    require(not set(baseline)&set(upgrade),'confirmed baseline must not be reapplied')
    require(len(baseline)==len(set(baseline)) and len(upgrade)==len(set(upgrade)),'duplicate migration in application partition')
    require(set(baseline)|set(upgrade)<=set(constants['SCHEMA_FILES']),'unknown file in application partition')
    require(bool(upgrade),'explicit nonempty upgrade required')
    schema_paths = []
    for prefix in SCHEMAS:
        matches = list((ROOT / "schema").glob(prefix + "*.sql"))
        require(len(matches) == 1, f"one schema file required for {prefix}")
        name = matches[0].name
        require(name in constants["SCHEMA_FILES"], f"SCHEMA_FILES missing {name}")
        require(name in baseline or name in upgrade, f"migration missing from confirmed baseline or current upgrade: {name}")
        sql = matches[0].read_text(encoding="utf-8").upper()
        require("DROP TABLE" not in sql and "TRUNCATE " not in sql, f"destructive SQL forbidden: {name}")
        require(len(sql.splitlines()) <= 500, f"schema exceeds 500 lines: {name}")
        schema_paths.append(name)
    for name in TESTS:
        path = ROOT / "tests" / name
        require(path.is_file(), f"SQL test missing: {name}")
        require(name in constants["TEST_FILES"], f"TEST_FILES missing {name}")
        require("SET LOCAL ROLE mastererp_app" in path.read_text(), f"effective app role missing: {name}")
        require(len(path.read_text().splitlines()) <= 500, f"test exceeds 500 lines: {name}")
    print(f"OK: Phase 5 Database gates passed for {len(schema_paths)} schemas and {len(TESTS)} tests.")


if __name__ == "__main__":
    main()
