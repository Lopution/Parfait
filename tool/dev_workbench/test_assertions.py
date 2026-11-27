"""Unit tests for the Dev Workbench declarative OS E2E assertion engine."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.assertions import evaluate_assertion, evaluate_assertions


class AssertionEngineTest(unittest.TestCase):
    def test_zero_uncaught_errors_uses_baseline_delta(self) -> None:
        snap_ok = {"errors": {"count": 2, "recent": []}}
        res_ok = evaluate_assertion(
            {"id": "err.ok", "type": "zero_uncaught_errors"},
            snapshot=snap_ok,
            baseline_error_count=2,
        )
        self.assertTrue(res_ok.passed, res_ok.detail)

        snap_bad = {"errors": {"count": 3, "recent": [{"message": "boom"}]}}
        res_bad = evaluate_assertion(
            {"id": "err.bad", "type": "zero_uncaught_errors"},
            snapshot=snap_bad,
            baseline_error_count=2,
        )
        self.assertFalse(res_bad.passed)
        self.assertIn("increased by 1", res_bad.detail)

        # Pre-restart errors must still fail even after a clean post-restart process resets count to 0.
        res_pre = evaluate_assertion(
            {"id": "err.pre_restart", "type": "zero_uncaught_errors"},
            snapshot={"errors": {"count": 0, "recent": []}},
            baseline_error_count=0,
            prior_error_delta=1,
        )
        self.assertFalse(res_pre.passed)
        self.assertIn("pre_restart=1", res_pre.detail)

    def test_process_alive_and_clean_exit(self) -> None:
        r1 = evaluate_assertion(
            {"id": "proc.up", "type": "process_alive", "expected": True},
            snapshot={},
            process_alive=True,
        )
        self.assertTrue(r1.passed)

        r2 = evaluate_assertion(
            {"id": "proc.dead", "type": "process_alive", "expected": True},
            snapshot={},
            process_alive=False,
            process_exit_code=139,
        )
        self.assertFalse(r2.passed)
        self.assertIn("139", r2.detail)

        r3 = evaluate_assertion(
            {
                "id": "proc.exit0",
                "type": "process_alive",
                "expected": False,
                "expected_exit_code": 0,
            },
            snapshot={},
            process_alive=False,
            process_exit_code=0,
        )
        self.assertTrue(r3.passed)

        r4 = evaluate_assertion(
            {
                "id": "proc.exit_bad",
                "type": "process_alive",
                "expected": False,
                "expected_exit_code": 0,
            },
            snapshot={},
            process_alive=False,
            process_exit_code=1,
        )
        self.assertFalse(r4.passed)

    def test_route_and_element_assertions(self) -> None:
        snap = {"route": "/recommended/user/99"}
        self.assertTrue(
            evaluate_assertion(
                {"id": "r.eq", "type": "route_equals", "expected": "/recommended/user/99"},
                snapshot=snap,
            ).passed
        )
        self.assertTrue(
            evaluate_assertion(
                {"id": "r.pre", "type": "route_prefix", "prefix": "/recommended/user/"},
                snapshot=snap,
            ).passed
        )
        self.assertFalse(
            evaluate_assertion(
                {"id": "r.miss", "type": "route_equals", "expected": "/settings"},
                snapshot=snap,
            ).passed
        )

        def fake_find(kind: str, query: str) -> dict[str, object]:
            return {"found": kind == "text" and query == "Artist 99"}

        self.assertTrue(
            evaluate_assertion(
                {"id": "el.vis", "type": "element_visible", "kind": "text", "query": "Artist 99"},
                snapshot=snap,
                find_bounds=fake_find,
            ).passed
        )
        self.assertTrue(
            evaluate_assertion(
                {"id": "el.abs", "type": "element_absent", "kind": "text", "query": "Missing"},
                snapshot=snap,
                find_bounds=fake_find,
            ).passed
        )
        self.assertFalse(
            evaluate_assertion(
                {"id": "el.fail", "type": "element_visible", "kind": "text", "query": "Missing"},
                snapshot=snap,
                find_bounds=fake_find,
            ).passed
        )

    def test_snapshot_field_comparators_and_dot_paths(self) -> None:
        snap = {
            "isDevIsolated": True,
            "viewport": {"width": 1280.0, "height": 760.0},
            "storage": {"rootDir": "/tmp/dev/profile"},
        }
        all_ok, results = evaluate_assertions(
            [
                {"id": "s.eq", "type": "snapshot_field", "field": "isDevIsolated", "equals": True},
                {"id": "s.gte", "type": "snapshot_field", "field": "viewport.width", "gte": 1000},
                {"id": "s.contains", "type": "snapshot_field", "field": "storage.rootDir", "contains": "profile"},
                {"id": "s.nn", "type": "snapshot_field", "field": "storage.rootDir", "not_null": True},
                {"id": "s.neq", "type": "snapshot_field", "field": "viewport.height", "not_equals": 0},
            ],
            snapshot=snap,
        )
        self.assertTrue(all_ok, [r.to_dict() for r in results])

        missing = evaluate_assertion(
            {"id": "s.miss", "type": "snapshot_field", "field": "storage.nonexistent", "equals": 1},
            snapshot=snap,
        )
        self.assertFalse(missing.passed)
        self.assertIn("absent", missing.detail)

    def test_clipboard_and_file_exists_with_traversal_guard(self) -> None:
        self.assertTrue(
            evaluate_assertion(
                {"id": "cb.ok", "type": "clipboard_equals", "expected": "hello"},
                snapshot={},
                read_clipboard=lambda: "hello",
            ).passed
        )
        self.assertFalse(
            evaluate_assertion(
                {"id": "cb.bad", "type": "clipboard_equals", "expected": "hello"},
                snapshot={},
                read_clipboard=lambda: "other",
            ).passed
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "prefs.json").write_text('{"k": 1}', encoding="utf-8")
            self.assertTrue(
                evaluate_assertion(
                    {"id": "f.ok", "type": "file_exists", "rel_path": "prefs.json", "min_bytes": 2},
                    snapshot={},
                    dev_root=root,
                ).passed
            )
            esc = evaluate_assertion(
                {"id": "f.esc", "type": "file_exists", "rel_path": "../etc/passwd"},
                snapshot={},
                dev_root=root,
            )
            self.assertFalse(esc.passed)
            self.assertIn("escapes", esc.detail)

        via_bridge = evaluate_assertion(
            {"id": "f.bridge", "type": "file_exists", "rel_path": "prefs.json", "min_bytes": 4},
            snapshot={},
            check_file=lambda rel: {"exists": rel == "prefs.json", "bytes": 12},
        )
        self.assertTrue(via_bridge.passed)

    def test_unknown_assertion_type_fails_loudly(self) -> None:
        res = evaluate_assertion({"id": "bad", "type": "no_such_assertion"}, snapshot={})
        self.assertFalse(res.passed)
        self.assertIn("unknown assertion type", res.detail)

    def test_server_command_validation_for_os_e2e_commands(self) -> None:
        from dev_workbench.server import validate_command_payload

        self.assertEqual(
            validate_command_payload({"clientId": "c1", "type": "readClipboard", "args": {}}),
            ("c1", "readClipboard", {}),
        )
        self.assertEqual(
            validate_command_payload({
                "clientId": "c1",
                "type": "writeClipboard",
                "args": {"text": "abc"},
            }),
            ("c1", "writeClipboard", {"text": "abc"}),
        )
        self.assertEqual(
            validate_command_payload({
                "clientId": "c1",
                "type": "checkFile",
                "args": {"relPath": "shared_preferences.json"},
            }),
            ("c1", "checkFile", {"relPath": "shared_preferences.json"}),
        )
        with self.assertRaises(ValueError):
            validate_command_payload({
                "clientId": "c1",
                "type": "checkFile",
                "args": {"relPath": "../secret"},
            })


if __name__ == "__main__":
    unittest.main()
