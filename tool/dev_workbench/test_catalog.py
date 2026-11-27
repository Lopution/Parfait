"""Unit & negative tests for finite catalog verification, manifest rules, and encoder."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.pixiv_fixtures import make_png_bytes
from dev_workbench.recorders.common import load_catalog, split_catalog_phases
from dev_workbench.recorders.encoder import encode_frames_to_media
from dev_workbench.recorders.manifest import (
    APPLE_REQUIRED_BLIND_SPOTS,
    build_coverage_report,
    render_coverage_markdown,
    validate_manifest_data,
)
from dev_workbench.verify_catalog import BRANCHES_DART, DEFAULT_CATALOG_DIR, ROUTES_DART, verify_catalog


class CatalogAndManifestTest(unittest.TestCase):
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
            os_data["flows"] = [f for f in os_data["flows"] if f["category"] != "os_cold_restart_persistence"]
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
            cat_json["items"][0]["platforms"]["ios" if "ios" in cat_json["items"][0]["platforms"] else "iphone"] = "not_applicable: "
            cat_file.write_text(json.dumps(cat_json), encoding="utf-8")
            ok2, errors2, _ = verify_catalog(cat_dir)
            self.assertFalse(ok2)
            self.assertTrue(any("empty justification" in err for err in errors2), errors2)

    def test_manifest_enforces_simulation_labels_and_rejects_spoofing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            sim_file = run_dir / "macos" / "test.item.sim.gif"
            sim_file.parent.mkdir(parents=True, exist_ok=True)
            sim_file.write_bytes(b"GIF89a_nonempty")
            real_file = run_dir / "windows" / "test.item.gif"
            real_file.parent.mkdir(parents=True, exist_ok=True)
            real_file.write_bytes(b"GIF89a_nonempty")

            valid_manifest = {
                "schema_version": 1,
                "run_id": "test-run",
                "git_head": "abc1234",
                "generated_at": "2026-11-16T21:00:00+08:00",
                "records": [
                    {
                        "catalog_id": "test.item",
                        "platform": "macos",
                        "evidence_kind": "widget_tester_simulation",
                        "capture_mode": "flutter_test_film_recorder",
                        "status": "ok",
                        "artifact_relpath": "macos/test.item.sim.gif",
                        "decode_verified": True,
                        "known_blind_spots": list(APPLE_REQUIRED_BLIND_SPOTS),
                    },
                    {
                        "catalog_id": "test.item",
                        "platform": "windows",
                        "audit_candidate": "SC-W1",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "win32_hidden_desktop",
                        "status": "recorded_with_anomaly",
                        "artifact_relpath": "windows/test.item.gif",
                        "decode_verified": True,
                        "diagnostics": {"nchittest_name": "HTTOP"},
                        "known_blind_spots": [],
                    },
                ],
            }
            ok, errors = validate_manifest_data(valid_manifest, run_dir)
            self.assertTrue(ok, errors)
            rep = build_coverage_report(valid_manifest)
            self.assertEqual(rep["anomalies_count"], 1)
            self.assertIn("SC-W1", render_coverage_markdown(rep))

            # Spoofed Apple record claiming native_os_recording MUST fail
            spoofed = json.loads(json.dumps(valid_manifest))
            spoofed["records"][0]["evidence_kind"] = "native_os_recording"
            ok_spoof, errs_spoof = validate_manifest_data(spoofed, run_dir)
            self.assertFalse(ok_spoof)
            self.assertTrue(any("widget_tester_simulation" in e for e in errs_spoof), errs_spoof)

            # Simulated artifact missing .sim. suffix MUST fail
            bad_name = json.loads(json.dumps(valid_manifest))
            (run_dir / "macos" / "test.item.gif").write_bytes(b"GIF89a")
            bad_name["records"][0]["artifact_relpath"] = "macos/test.item.gif"
            ok_name, errs_name = validate_manifest_data(bad_name, run_dir)
            self.assertFalse(ok_name)
            self.assertTrue(any(".sim." in e for e in errs_name), errs_name)

            # Real OS target claiming simulated capture_mode MUST fail
            (run_dir / "windows").mkdir(exist_ok=True)
            (run_dir / "windows" / "win.item.gif").write_bytes(b"GIF89a")
            bad_real_mode = {
                "schema_version": 1,
                "run_id": "test",
                "records": [{
                    "catalog_id": "win.item",
                    "platform": "windows",
                    "evidence_kind": "native_os_recording",
                    "capture_mode": "flutter_test_film_recorder",
                    "status": "ok",
                    "artifact_relpath": "windows/win.item.gif",
                    "decode_verified": True,
                    "known_blind_spots": [],
                }],
            }
            ok_real, errs_real = validate_manifest_data(bad_real_mode, run_dir)
            self.assertFalse(ok_real)
            self.assertTrue(any("capture_mode" in e for e in errs_real), errs_real)

    def test_split_catalog_phases_orders_prehome_and_close_last(self) -> None:
        items = load_catalog()
        pre, post, skipped = split_catalog_phases(items, platform="windows", include_foreground_opt_in=False)
        self.assertGreaterEqual(len(pre), 5)
        self.assertEqual(pre[0]["route_template"], "/splash")
        self.assertEqual(post[-1]["id"], "shell.win_caption.close_top_edge_unmax")
        self.assertEqual(sum(1 for it in skipped if it["platforms"]["windows"].startswith("foreground_opt_in:")), 3)

    def test_encoder_outputs_decodable_mp4_and_gif(self) -> None:
        frames = [make_png_bytes(160, 120, (30 * i % 250, 90, 200)) for i in range(1, 7)]
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            mp4_art = encode_frames_to_media(frames, out_dir / "sample.mp4", "mp4", fps=12)
            gif_art = encode_frames_to_media(frames, out_dir / "sample.gif", "gif", fps=12)
            self.assertTrue(mp4_art.decode_verified, mp4_art.decode_error)
            self.assertTrue(gif_art.decode_verified, gif_art.decode_error)
            self.assertGreater(mp4_art.bytes, 0)
            self.assertGreater(gif_art.bytes, 0)
            self.assertEqual((mp4_art.width, mp4_art.height), (160, 120))

    def test_server_catalog_manifest_endpoint(self) -> None:
        import http.client
        import threading
        from dev_workbench.server import ParfaitWorkbenchServer, WorkbenchState

        with tempfile.TemporaryDirectory() as tmp:
            art_dir = Path(tmp)
            (art_dir / "macos").mkdir()
            (art_dir / "macos" / "demo.sim.gif").write_bytes(b"GIF89a")
            (art_dir / "manifest.json").write_text(
                json.dumps({
                    "schema_version": 1,
                    "run_id": "demo-run",
                    "git_head": "deadbeef",
                    "generated_at": "2026-11-16T21:00:00+08:00",
                    "records": [{
                        "catalog_id": "demo.item",
                        "platform": "macos",
                        "evidence_kind": "widget_tester_simulation",
                        "capture_mode": "flutter_test_film_recorder",
                        "status": "ok",
                        "artifact_relpath": "macos/demo.sim.gif",
                        "decode_verified": True,
                        "known_blind_spots": ["os_native_window_border"],
                    }],
                }),
                encoding="utf-8",
            )
            state = WorkbenchState(token="t" * 32, artifacts_dir=art_dir)
            srv = ParfaitWorkbenchServer(0, state)
            port = srv.bound_port
            th = threading.Thread(target=srv.serve_forever, daemon=True)
            th.start()
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                try:
                    conn.request("GET", "/api/catalog-manifest")
                    resp = conn.getresponse()
                    self.assertEqual(resp.status, 200)
                    payload = json.loads(resp.read().decode("utf-8"))
                    self.assertTrue(payload["hasManifest"])
                    self.assertEqual(payload["runId"], "demo-run")
                    self.assertEqual(
                        payload["records"][0]["artifactUrl"],
                        "/artifacts/macos/demo.sim.gif",
                    )
                finally:
                    conn.close()
            finally:
                srv.shutdown()
                srv.server_close()

    def test_server_serves_nested_latest_symlink_artifacts(self) -> None:
        import http.client
        import os
        import threading
        from dev_workbench.server import ParfaitWorkbenchServer, WorkbenchState

        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            run_dir = base / "runs" / "baseline-demo"
            (run_dir / "windows").mkdir(parents=True)
            (run_dir / "windows" / "clip.gif").write_bytes(b"GIF89a_win")
            (run_dir / "manifest.json").write_text(
                json.dumps({
                    "schema_version": 1,
                    "run_id": "baseline-demo",
                    "git_head": "deadbeef",
                    "generated_at": "2026-11-16T21:00:00+08:00",
                    "records": [{
                        "catalog_id": "shell.win_caption.close_top_edge_unmax",
                        "platform": "windows",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "win32_hidden_desktop",
                        "status": "recorded_with_anomaly",
                        "artifact_relpath": "windows/clip.gif",
                        "decode_verified": True,
                        "known_blind_spots": [],
                    }],
                }),
                encoding="utf-8",
            )
            os.symlink(run_dir, base / "latest")
            state = WorkbenchState(token="t" * 32, artifacts_dir=base)
            srv = ParfaitWorkbenchServer(0, state)
            port = srv.bound_port
            th = threading.Thread(target=srv.serve_forever, daemon=True)
            th.start()
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                try:
                    conn.request("GET", "/api/catalog-manifest")
                    r1 = conn.getresponse()
                    self.assertEqual(r1.status, 200)
                    payload = json.loads(r1.read().decode("utf-8"))
                    art_url = payload["records"][0]["artifactUrl"]
                    self.assertEqual(art_url, "/artifacts/runs/baseline-demo/windows/clip.gif")

                    conn.request("GET", art_url)
                    r2 = conn.getresponse()
                    self.assertEqual(r2.status, 200)
                    self.assertEqual(r2.read(), b"GIF89a_win")
                finally:
                    conn.close()
            finally:
                srv.shutdown()
                srv.server_close()

    def test_windows_agent_source_contains_restore_and_invalidation(self) -> None:
        from unittest import mock
        from dev_workbench.recorders import windows_recorder

        self.assertIn('cmd == "RESTORE"', windows_recorder._WIN_AGENT_CS)
        self.assertIn("ShowWindow", windows_recorder._WIN_AGENT_CS)

        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            exe = stage / "win_agent.exe"
            cs = stage / "win_agent.cs"

            # Fresh cache hit skips recompilation
            exe.write_bytes(b"MZ")
            cs.write_text(windows_recorder._WIN_AGENT_CS, encoding="utf-8")
            with mock.patch.object(windows_recorder.subprocess, "run") as run_mock:
                out = windows_recorder._compile_win_agent(stage)
                self.assertEqual(out, exe)
                run_mock.assert_not_called()

            # Stale source rewrites win_agent.cs and triggers recompilation
            cs.write_text("// stale source", encoding="utf-8")
            fake_ok = mock.MagicMock(returncode=0, stdout="", stderr="")
            with (
                mock.patch.object(windows_recorder, "to_windows_path", side_effect=str),
                mock.patch.object(windows_recorder.subprocess, "run", return_value=fake_ok) as run_mock,
            ):
                out = windows_recorder._compile_win_agent(stage)
                self.assertEqual(out, exe)
                run_mock.assert_called_once()
                self.assertEqual(cs.read_text(encoding="utf-8"), windows_recorder._WIN_AGENT_CS)

    def test_storyboard_sheets_motion_flags_and_extract(self) -> None:
        from dev_workbench.recorders.storyboard import (
            attach_sheets_to_run,
            build_storyboard_from_frame_bytes,
            extract_media_frames,
        )

        # 1. Static sequence -> zero_change; spike sequence -> single_frame_spike
        blue = make_png_bytes(160, 120, (20, 60, 180))
        red = make_png_bytes(160, 120, (220, 30, 30))
        green = make_png_bytes(160, 120, (30, 200, 70))
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            _, zero_metrics = build_storyboard_from_frame_bytes(
                [blue] * 5,
                run_dir / "sheets" / "zero",
                fps=10,
                direction="one_way",
            )
            self.assertIn("zero_change", zero_metrics["motion_flags"])

            # 10 frames with an isolated 1-frame flash at index 4
            spike_seq = [blue] * 4 + [red] + [blue] * 5
            sheets_sp, sp_metrics = build_storyboard_from_frame_bytes(
                spike_seq,
                run_dir / "sheets" / "spike",
                fps=10,
                direction="two_way",
            )
            self.assertTrue(sheets_sp and sheets_sp[0].is_file())
            self.assertIn("single_frame_spike", sp_metrics["motion_flags"])
            self.assertEqual(sp_metrics["spike_frames"], [4])

            # 2. Encoder + attach_sheets_to_run + two_way_not_restored + frame extraction
            mp4_art = encode_frames_to_media(
                [blue, blue, green, green],
                run_dir / "windows" / "demo.item.mp4",
                "mp4",
                fps=4,
                sheet_dir=run_dir / "sheets" / "windows" / "demo.item",
                direction="two_way",
            )
            self.assertTrue(mp4_art.decode_verified)
            self.assertTrue(mp4_art.sheet_paths and mp4_art.sheet_paths[0].is_file())
            self.assertIn("two_way_not_restored", mp4_art.motion_metrics["motion_flags"])

            gif_art = encode_frames_to_media(
                [blue, red, blue],
                run_dir / "linux" / "demo.gif.gif",
                "gif",
                fps=6,
            )
            self.assertTrue(gif_art.decode_verified)

            manifest = {
                "schema_version": 1,
                "run_id": "sb-test",
                "git_head": "deadbeef",
                "generated_at": "2026-11-17T10:55:00+08:00",
                "records": [
                    {
                        "catalog_id": "demo.item",
                        "platform": "windows",
                        "direction": "two_way",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "win32_hidden_desktop",
                        "status": "ok",
                        "artifact_relpath": "windows/demo.item.mp4",
                        "decode_verified": True,
                        "known_blind_spots": [],
                    },
                    {
                        "catalog_id": "demo.gif",
                        "platform": "linux",
                        "direction": "two_way",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "x11_window_capture",
                        "status": "ok",
                        "artifact_relpath": "linux/demo.gif.gif",
                        "decode_verified": True,
                        "known_blind_spots": [],
                    },
                ],
            }
            summary = attach_sheets_to_run(run_dir, manifest, force=True)
            self.assertEqual(summary["processed"], 2)
            self.assertEqual(summary["errors"], [])

            ok, errs = validate_manifest_data(manifest, run_dir)
            self.assertTrue(ok, errs)
            rep = build_coverage_report(manifest)
            self.assertEqual(rep["motion_anomalies_count"], 1)
            self.assertIn("Motion Review Signals", render_coverage_markdown(rep))

            # Escaping sheet_relpath MUST fail manifest validation
            bad_man = json.loads(json.dumps(manifest))
            bad_man["records"][0]["sheet_relpaths"] = ["../escape.png"]
            ok_bad, errs_bad = validate_manifest_data(bad_man, run_dir)
            self.assertFalse(ok_bad)
            self.assertTrue(any("escapes run_dir" in e for e in errs_bad), errs_bad)

            extracted = extract_media_frames(
                run_dir / "linux" / "demo.gif.gif",
                run_dir / "frames" / "linux" / "demo.gif",
            )
            self.assertGreaterEqual(len(extracted), 3)

    def test_server_exposes_sheet_urls_with_latest_symlink(self) -> None:
        import http.client
        import os
        import threading
        from dev_workbench.server import ParfaitWorkbenchServer, WorkbenchState

        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            run_dir = base / "runs" / "r1"
            (run_dir / "windows").mkdir(parents=True)
            (run_dir / "sheets" / "windows" / "clip").mkdir(parents=True)
            (run_dir / "windows" / "clip.gif").write_bytes(b"GIF89a")
            (run_dir / "sheets" / "windows" / "clip" / "sheet-00.png").write_bytes(make_png_bytes(60, 40, (1, 2, 3)))
            (run_dir / "manifest.json").write_text(
                json.dumps({
                    "schema_version": 1,
                    "run_id": "r1",
                    "git_head": "deadbeef",
                    "generated_at": "2026-11-17T10:55:00+08:00",
                    "records": [{
                        "catalog_id": "clip",
                        "platform": "windows",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "win32_hidden_desktop",
                        "status": "ok",
                        "artifact_relpath": "windows/clip.gif",
                        "sheet_relpaths": ["sheets/windows/clip/sheet-00.png"],
                        "decode_verified": True,
                        "known_blind_spots": [],
                    }],
                }),
                encoding="utf-8",
            )
            os.symlink(run_dir, base / "latest")
            state = WorkbenchState(token="t" * 32, artifacts_dir=base)
            srv = ParfaitWorkbenchServer(0, state)
            th = threading.Thread(target=srv.serve_forever, daemon=True)
            th.start()
            try:
                conn = http.client.HTTPConnection("127.0.0.1", srv.bound_port, timeout=5)
                try:
                    conn.request("GET", "/api/catalog-manifest")
                    resp = conn.getresponse()
                    self.assertEqual(resp.status, 200)
                    payload = json.loads(resp.read().decode("utf-8"))
                    sheet_url = payload["records"][0]["sheetUrls"][0]
                    self.assertEqual(sheet_url, "/artifacts/runs/r1/sheets/windows/clip/sheet-00.png")

                    conn.request("GET", sheet_url)
                    sresp = conn.getresponse()
                    self.assertEqual(sresp.status, 200)
                    self.assertTrue(sresp.read().startswith(b"\x89PNG"))
                finally:
                    conn.close()
            finally:
                srv.shutdown()
                srv.server_close()


if __name__ == "__main__":
    unittest.main()
