"""Dependency-free stdlib unit tests for catalog and 3D completeness matrix verification."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.verify_catalog import (
    BRANCHES_DART,
    DEFAULT_CATALOG_DIR,
    ROUTES_DART,
    verify_catalog,
)


class CatalogMatrixTest(unittest.TestCase):
    def test_real_catalog_covers_all_routes_shells_and_audit_candidates(self) -> None:
        ok, errors, summary = verify_catalog()
        self.assertTrue(ok, f"Catalog verification failed: {errors}")
        self.assertEqual(summary["syntactic_goroutes"], 60)
        self.assertEqual(summary["canonical_routes"], 66)
        self.assertGreaterEqual(summary["catalog_items"], 65)
        self.assertEqual(
            summary["covered_audit_candidates"],
            ["SC-W1", "SC-W2", "SC-W3", "SC-W4", "SC-W5"],
        )
        self.assertGreaterEqual(summary["in_app_journeys"], 9)
        self.assertGreaterEqual(summary["seam_invariants"], 4)
        self.assertEqual(len(summary["os_boundary_categories"]), 6)
        self.assertEqual(summary["os_e2e_flows"], 6)
        self.assertGreaterEqual(summary["os_e2e_assertions"], 18)

    def test_3d_completeness_matrix_rejects_missing_test_or_os_category(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cat_dir = root / "catalog"
            shutil.copytree(DEFAULT_CATALOG_DIR, cat_dir)

            # 1. Broken Dart test name in completeness_matrix.json fails
            m_file = cat_dir / "completeness_matrix.json"
            m_data = json.loads(m_file.read_text(encoding="utf-8"))
            m_data["seam_invariants"][0]["test_name"] = "nonexistent seam case"
            m_file.write_text(json.dumps(m_data), encoding="utf-8")
            ok1, errs1, _ = verify_catalog(cat_dir)
            self.assertFalse(ok1)
            self.assertTrue(any("not declared in" in e for e in errs1), errs1)

            # 2. Restore matrix, drop an OS boundary flow category -> fails
            shutil.copy2(DEFAULT_CATALOG_DIR / "completeness_matrix.json", m_file)
            os_file = cat_dir / "os_e2e_flows.json"
            os_data = json.loads(os_file.read_text(encoding="utf-8"))
            os_data["flows"] = [
                f for f in os_data["flows"] if f["category"] != "os_cold_restart_persistence"
            ]
            os_file.write_text(json.dumps(os_data), encoding="utf-8")
            ok2, errs2, _ = verify_catalog(cat_dir)
            self.assertFalse(ok2)
            self.assertTrue(any("os_cold_restart_persistence" in e for e in errs2), errs2)

            # 3. Unknown assertion type in os_e2e_flows.json -> fails
            shutil.copy2(DEFAULT_CATALOG_DIR / "os_e2e_flows.json", os_file)
            os_data2 = json.loads(os_file.read_text(encoding="utf-8"))
            os_data2["flows"][0]["assertions"][0]["type"] = "bogus_assert"
            os_file.write_text(json.dumps(os_data2), encoding="utf-8")
            ok3, errs3, _ = verify_catalog(cat_dir)
            self.assertFalse(ok3)
            self.assertTrue(any("unknown type" in e for e in errs3), errs3)

    def test_rejects_unmapped_source_route_and_empty_na_reason(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cat_dir = root / "catalog"
            shutil.copytree(DEFAULT_CATALOG_DIR, cat_dir)

            # Case 1: unmapped GoRoute added to route_branches.dart
            mut_branches = root / "route_branches.dart"
            src = BRANCHES_DART.read_text(encoding="utf-8")
            marker = "GoRoute(\n      path: 'about',"
            self.assertIn(marker, src)
            mut_branches.write_text(
                src.replace(
                    marker,
                    "GoRoute(\n      path: 'unmapped_audit_hole',\n      pageBuilder: (c, s) => throw '',\n    ),\n    "
                    + marker,
                ),
                encoding="utf-8",
            )
            ok, errors, _ = verify_catalog(
                cat_dir,
                routes_path=ROUTES_DART,
                branches_path=mut_branches,
            )
            self.assertFalse(ok)
            self.assertTrue(any("unmapped_audit_hole" in err for err in errors), errors)

            # Case 2: empty not_applicable reason fails
            cat_file = cat_dir / "catalog.json"
            cat_json = json.loads(cat_file.read_text(encoding="utf-8"))
            cat_json["items"][0]["platforms"][
                "ios" if "ios" in cat_json["items"][0]["platforms"] else "iphone"
            ] = "not_applicable: "
            cat_file.write_text(json.dumps(cat_json), encoding="utf-8")
            ok2, errors2, _ = verify_catalog(cat_dir)
            self.assertFalse(ok2)
            self.assertTrue(any("empty justification" in err for err in errors2), errors2)


if __name__ == "__main__":
    unittest.main()
