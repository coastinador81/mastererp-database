"""Tests for deterministic Phase 6 DEV reconciliation."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "reconcile_dev_snapshot",
    Path(__file__).resolve().parents[1] / "migration/phase6/reconcile_dev_snapshot.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class ReconcileDevSnapshotTest(unittest.TestCase):
    def test_reports_exact_match_and_difference(self):
        values = {name: [] for name in module.KINDS}; values["products"] = [{"source_id": "P1"}]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); bundle = root / "bundle"; bundle.mkdir(); snapshot = root / "snapshot.json"
            (bundle / "manifest.json").write_text(json.dumps({"source_sha256": "a" * 64}))
            snapshot.write_text(json.dumps({"source_sha256": "a" * 64}))
            with patch.object(module, "_expected", return_value=values), patch.object(module, "_actual", return_value=values):
                self.assertTrue(module.reconcile(bundle, snapshot)["ok"])
            changed = {name: list(rows) for name, rows in values.items()}; changed["products"] = []
            with patch.object(module, "_expected", return_value=values), patch.object(module, "_actual", return_value=changed):
                report = module.reconcile(bundle, snapshot)
            self.assertFalse(report["ok"]); self.assertIn("products", report["differences"])


if __name__ == "__main__": unittest.main()
