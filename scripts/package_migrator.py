"""Package only the official reviewed migration manifest, deterministically."""
import argparse
import ast
import pathlib
import zipfile


def package(destination, dependencies):
    root = pathlib.Path(__file__).resolve().parents[1]
    handler = root / "migrations/lambda/handler.py"
    tree = ast.parse(handler.read_text(encoding="utf-8-sig"))
    manifest = {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body
                if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id in ("SCHEMA_FILES", "SEED_FILES", "TEST_FILES")}
    files = {"handler.py": handler, "dev_validation.py": handler.with_name("dev_validation.py")}
    for key, folder in (("SCHEMA_FILES", "schema"), ("SEED_FILES", "seeds"), ("TEST_FILES", "tests")):
        for name in manifest[key]:
            if "sql/" + name in files:
                raise ValueError("SQL basename collision")
            files["sql/" + name] = root / folder / name
    files["business_samples.py"] = handler.with_name("business_samples.py")
    files["party_validation.py"] = handler.with_name("party_validation.py")
    files["administration_validation.py"] = handler.with_name("administration_validation.py")
    for source in (root / "tests/administration").glob("*.sql"):
        files["administration_tests/" + source.name] = source
    allowed = {"pg8000", "scramp", "asn1crypto", "dateutil", "six.py"}
    for source in dependencies.rglob("*"):
        path = source.relative_to(dependencies)
        if source.is_file() and (path.parts[0] in allowed or path.parts[0].endswith(".dist-info")) and "__pycache__" not in path.parts:
            files[path.as_posix()] = source
    with zipfile.ZipFile(destination, "w") as archive:
        for name, source in sorted(files.items()):
            item = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.create_system = 3
            item.external_attr = 0o100644 << 16
            archive.writestr(item, source.read_bytes())
    print("Packaged manifest: " + ", ".join(manifest["SCHEMA_FILES"] + manifest["SEED_FILES"] + manifest["TEST_FILES"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--dependencies", type=pathlib.Path, required=True)
    args = parser.parse_args()
    package(args.destination, args.dependencies)
