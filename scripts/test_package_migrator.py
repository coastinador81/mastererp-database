"""Verify required migration modules are present in the deterministic artifact."""

import tempfile
import unittest
import zipfile
from pathlib import Path

from package_migrator import package


class PackageMigratorTest(unittest.TestCase):
    def test_phase6_validation_is_packaged(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / "function.zip"; dependencies = root / "deps"
            dependencies.mkdir(); package(destination, dependencies)
            with zipfile.ZipFile(destination) as archive:
                self.assertIn("phase6_validation.py", archive.namelist())

    def test_uonify_access_is_packaged(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / "function.zip"; dependencies = root / "deps"
            dependencies.mkdir(); package(destination, dependencies)
            with zipfile.ZipFile(destination) as archive:
                self.assertIn("uonify_access.py", archive.namelist())


if __name__ == "__main__": unittest.main()
