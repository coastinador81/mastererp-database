"""Validate repository structure without accessing AWS or executing SQL."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[1]
platform = root.name == "mastererp-platform"
infra = root.name == "mastererp-infrastructure"
bases = [root / "frontend/modules", root / "backend/modules"] if platform else [root / "modules"]
errors = []
sets = []
for base in bases:
    paths = set()
    for folder in sorted(base.rglob("*")):
        if not folder.is_dir() or not re.match(r"^\d", folder.name):
            continue
        relative = folder.relative_to(base).as_posix()
        paths.add(relative)
        if not (folder / "README.md").is_file():
            errors.append(f"{relative}: falta README.md")
        if infra and not (folder / "resources.yml").is_file():
            errors.append(f"{relative}: falta resources.yml")
        if "1.2-ai" in relative or "1.2.2-uonify" in relative:
            errors.append(f"{relative}: ubicación antigua; usar 0-uonify")
    if not paths:
        errors.append(f"{base}: no hay módulos numerados")
    sets.append(paths)
if platform and sets[0] != sets[1]:
    errors.append("frontend/backend: las rutas numeradas no coinciden")
if infra:
    for name in ("README.md", "resources.yml"):
        if not (root / "modules" / name).is_file():
            errors.append(f"modules: falta {name}")
for name in ("AGENTS.md", "CONTRIBUTING.md", "docs/FOLDER_STANDARD.md"):
    if not (root / name).is_file():
        errors.append(f"Falta {name}")
if errors:
    print("ADVERTENCIA: estructura incompatible con el estándar")
    print("\n".join(errors))
    print("Recomendación: corregir las rutas y archivos indicados antes de integrar.")
    sys.exit(1)
print("OK: estructura básica válida. Revisar correspondencias entre repositorios y propiedad de recursos en el PR.")
