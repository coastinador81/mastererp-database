"""Unit tests for the read-only Phase 6 inspection contract."""

import importlib.util
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "migrations/lambda"))
spec = importlib.util.spec_from_file_location(
    "phase6_validation", Path(__file__).resolve().parents[1] / "migrations/lambda/phase6_validation.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class Phase6ValidationTest(unittest.TestCase):
    context = SimpleNamespace(invoked_function_arn=(
        "arn:aws:lambda:us-west-1:277352717693:function:mastererp-dev-database-migrator"))

    def test_requires_exact_contract_before_query(self):
        connection = MagicMock()
        with patch.dict(os.environ, {"ENVIRONMENT": "dev", "DB_NAME": "mastererp"}), self.assertRaisesRegex(ValueError, "Exact Phase 6"):
            module.inspect_phase6(connection, {"name": "Other"}, self.context)
        connection.run.assert_not_called()

    def test_read_only_snapshot_is_rolled_back(self):
        connection = MagicMock()
        def execute(sql, **_params):
            if sql.startswith("SELECT t.id,c.id"):
                return [("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002")]
            if "SELECT slug,estado" in sql: return [("food", "ACTIVE")]
            return []
        connection.run.side_effect = execute
        event = {"name": "Tumandaito", "source_sha256": module.SOURCE_SHA256}
        with patch.dict(os.environ, {"ENVIRONMENT": "dev", "DB_NAME": "mastererp"}):
            result = module.inspect_phase6(connection, event, self.context)
        self.assertTrue(result["read_only"]); self.assertEqual(result["counts"]["categories"], 1)
        self.assertEqual(connection.run.call_args_list[0].args[0], "BEGIN READ ONLY")
        self.assertEqual(connection.run.call_args_list[-1].args[0], "ROLLBACK")


if __name__ == "__main__": unittest.main()
