#!/usr/bin/env python3
"""Real-process OS-level E2E runner driven by Dev Workbench + declarative assertions.

Executes `tool/dev_workbench/catalog/os_e2e_flows.json` against a real compiled
Linux GTK debug binary (under isolated Xvfb) or Android KVM AVD (`adb`),
evaluating declarative assertions (`zero_uncaught_errors`, `process_alive`,
`route_*`, `element_*`, `snapshot_field`, `clipboard_equals`, `file_exists`)
and exiting non-zero on any failure.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.assertions import AssertionResult, evaluate_assertions
from dev_workbench.recorders.android_recorder import (
    ANDROID_ACTIVITY,
    ANDROID_PKG,
    DEFAULT_AVD,
    _adb,
    _execute_android_step,
    _launch_app,
    build_and_install_dev_apk,
    ensure_emulator_running,
)
from dev_workbench.recorders.common import (
    ManagedWorkbenchServer,
    REPO_ROOT,
    WorkbenchClient,
)
from dev_workbench.recorders.linux_recorder import (
    DEFAULT_LINUX_BUNDLE_EXE,
    _LinuxDevSession,
    _execute_linux_action,
    _find_free_display,
)

OS_E2E_FLOWS_PATH = REPO_ROOT / "tool" / "dev_workbench" / "catalog" / "os_e2e_flows.json"


def load_os_e2e_flows(
    path: Path = OS_E2E_FLOWS_PATH,
    *,
    platform: str,
    smoke_only: bool = False,
    flow_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    flows = list(data.get("flows") or [])
    selected: list[dict[str, Any]] = []
    for flow in flows:
        if flow_ids is not None and flow["id"] not in flow_ids:
            continue
        if smoke_only and not flow.get("smoke", False):
            continue
        rule = str((flow.get("platforms") or {}).get(platform, "not_applicable:missing"))
        if rule == "required":
            selected.append(flow)
    return selected


def _start_linux_pid_session(
    wb: WorkbenchClient,
    *,
    exe_path: Path,
    display: str,
    workbench_url: str,
    token: str,
    dev_root: Path,
    profile_name: str,
    fresh_onboarding: bool = False,
) -> tuple[_LinuxDevSession, str]:
    sess = _LinuxDevSession(
        exe_path=exe_path,
        display=display,
        workbench_url=workbench_url,
        token=token,
        dev_root=dev_root,
        profile_name=profile_name,
        fresh_onboarding=fresh_onboarding,
    )
    sess.dev_root.mkdir(parents=True, exist_ok=True)
    args = [
        str(sess.exe_path),
        f"--dev-profile={sess.profile_name}",
        "--source=loopback",
        f"--loopback={sess.workbench_url}",
        f"--workbench-url={sess.workbench_url}",
        f"--workbench-token={sess.token}",
    ]
    sess.proc = subprocess.Popen(
        args,
        cwd=str(sess.exe_path.parent),
        env=sess.env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    import threading
    from dev_workbench.recorders.linux_recorder import _drain_async

    threading.Thread(target=_drain_async, args=(sess.proc.stdout,), daemon=True).start()
    try:
        # Match exact PID suffix so cold_restart never attaches to a stale dying clientId.
        client = wb.wait_for_client(
            platform_prefix="linux",
            client_id_substring=f"-{sess.proc.pid}",
            timeout=45.0,
        )
        sess.wid = sess._find_window_id()
        return sess, str(client["clientId"])
    except BaseException:
        sess.stop()
        raise


def _run_linux_flows(
    flows: list[dict[str, Any]],
    *,
    linux_exe: Path,
) -> list[dict[str, Any]]:
    if not linux_exe.is_file():
        raise FileNotFoundError(
            f"Linux dev binary not found: {linux_exe}. "
            "Build it with: flutter build linux --debug -t lib/main_dev.dart"
        )

    results: list[dict[str, Any]] = []
    display = _find_free_display()
    xvfb = subprocess.Popen(
        [
            shutil.which("Xvfb") or "/usr/bin/Xvfb",
            display,
            "-screen",
            "0",
            "1440x900x24",
            "-ac",
            "+extension",
            "GLX",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.6)
    try:
        with ManagedWorkbenchServer(allow_emulator_host=False) as srv:
            wb = srv.client()
            with tempfile.TemporaryDirectory(prefix="parfait_os_e2e_linux_") as tmp_dir:
                dev_root = Path(tmp_dir) / "dev_root"
                profile_name = "os_e2e"
                sess, client_id = _start_linux_pid_session(
                    wb,
                    exe_path=linux_exe,
                    display=display,
                    workbench_url=srv.url,
                    token=srv.token,
                    dev_root=dev_root,
                    profile_name=profile_name,
                )
                try:
                    wb.send_command(
                        client_id, "resizeWindow", {"width": 1280, "height": 760}, timeout=15.0
                    )
                    time.sleep(0.35)
                    wb.send_command(client_id, "loopbackSignIn", {}, timeout=15.0)
                    time.sleep(0.6)

                    for flow in flows:
                        t0 = time.monotonic()
                        fid = flow["id"]
                        flow_error = ""
                        if not sess.is_alive():
                            sess.stop()
                            sess, client_id = _start_linux_pid_session(
                                wb,
                                exe_path=linux_exe,
                                display=display,
                                workbench_url=srv.url,
                                token=srv.token,
                                dev_root=dev_root,
                                profile_name=profile_name,
                            )
                            wb.send_command(client_id, "loopbackSignIn", {}, timeout=15.0)
                            time.sleep(0.5)

                        baseline_errors = 0
                        prior_error_delta = 0
                        snap: dict[str, Any] = {}
                        try:
                            wb.reset_faults()
                            snap0 = wb.snapshot(client_id, timeout=10.0)
                            baseline_errors = int(((snap0.get("errors") or {}).get("count")) or 0)
                            snap = snap0
                            for step in flow.get("steps", []):
                                stype = step["type"]
                                if stype == "write_clipboard":
                                    wb.send_command(
                                        client_id,
                                        "writeClipboard",
                                        {"text": str(step.get("text") or "")},
                                        timeout=10.0,
                                    )
                                    time.sleep(0.15)
                                elif stype == "cold_restart":
                                    pre_snap = wb.snapshot(client_id, timeout=10.0)
                                    pre_count = int(((pre_snap.get("errors") or {}).get("count")) or 0)
                                    prior_error_delta += max(0, pre_count - baseline_errors)
                                    sess.stop()
                                    time.sleep(0.4)
                                    # Relaunch with fresh_onboarding=True so DevWorkbenchHost will NOT
                                    # auto-bootstrap a synthetic loopback account if disk persistence failed.
                                    sess, client_id = _start_linux_pid_session(
                                        wb,
                                        exe_path=linux_exe,
                                        display=display,
                                        workbench_url=srv.url,
                                        token=srv.token,
                                        dev_root=dev_root,
                                        profile_name=profile_name,
                                        fresh_onboarding=True,
                                    )
                                    # New process starts with fresh in-memory error counter; pre-restart
                                    # errors stay tracked in prior_error_delta.
                                    baseline_errors = 0
                                    time.sleep(0.5)
                                    snap = wb.snapshot(client_id, timeout=10.0)
                                else:
                                    _execute_linux_action(
                                        wb,
                                        client_id,
                                        sess.env,
                                        sess.wid,
                                        snap,
                                        {"kind": "viewport_ratio", "x_ratio": 0.5, "y_ratio": 0.5},
                                        step,
                                    )
                                    if stype in ("navigate", "resize_window", "fault"):
                                        snap = wb.snapshot(client_id, timeout=10.0)
                            snap = wb.snapshot(client_id, timeout=10.0)
                        except Exception as exc:
                            flow_error = f"{type(exc).__name__}: {exc}"

                        if flow_error:
                            a_results = [
                                AssertionResult(
                                    id=str(a.get("id") or "step"),
                                    type=str(a.get("type") or "step"),
                                    passed=False,
                                    detail=f"aborted before assertion: {flow_error}",
                                )
                                for a in flow.get("assertions", [])
                            ]
                            passed = False
                        else:
                            passed, a_results = evaluate_assertions(
                                flow.get("assertions", []),
                                snapshot=snap,
                                baseline_error_count=baseline_errors,
                                prior_error_delta=prior_error_delta,
                                process_alive=sess.is_alive(),
                                process_exit_code=sess.proc.poll() if sess.proc is not None else None,
                                find_bounds=lambda k, q: wb.send_command(
                                    client_id, "findBounds", {"kind": k, "query": q}, timeout=8.0
                                ),
                                read_clipboard=lambda: wb.send_command(
                                    client_id, "readClipboard", {}, timeout=8.0
                                ).get("text"),
                                check_file=lambda rel: wb.send_command(
                                    client_id, "checkFile", {"relPath": rel}, timeout=8.0
                                ),
                                dev_root=dev_root / profile_name,
                            )

                        results.append({
                            "flow_id": fid,
                            "category": flow["category"],
                            "platform": "linux",
                            "passed": passed,
                            "duration_sec": round(time.monotonic() - t0, 2),
                            "error": flow_error or None,
                            "assertions": [r.to_dict() for r in a_results],
                        })
                finally:
                    sess.stop()
    finally:
        xvfb.terminate()
        try:
            xvfb.wait(timeout=4.0)
        except subprocess.TimeoutExpired:
            xvfb.kill()
    return results


def _ensure_android_app_focus(serial: str, *, max_attempts: int = 12) -> str:
    """Dismiss keyguard/system dialogs (e.g., ANR from heavy build) and focus MainActivity."""
    _adb(["shell", "svc", "power", "stayon", "true"], serial=serial, check=False)
    _adb(["shell", "input", "keyevent", "224"], serial=serial, check=False)
    _adb(["shell", "wm", "dismiss-keyguard"], serial=serial, check=False)
    _adb(["shell", "cmd", "statusbar", "collapse"], serial=serial, check=False)
    _adb(
        ["shell", "am", "broadcast", "-a", "android.intent.action.CLOSE_SYSTEM_DIALOGS"],
        serial=serial,
        check=False,
    )
    focus_line = ""
    for _ in range(max_attempts):
        out = _adb(["shell", "dumpsys", "window"], serial=serial, check=False).stdout
        matches = [ln.strip() for ln in out.splitlines() if "mCurrentFocus=" in ln]
        focus_line = matches[-1] if matches else ""
        if ANDROID_PKG in focus_line:
            return focus_line
        if "Application Not Responding" in focus_line or "Not Responding" in focus_line:
            # Dismiss ANR dialog ("Wait" / "Close app") and re-focus activity.
            _adb(["shell", "input", "keyevent", "4"], serial=serial, check=False)
            time.sleep(0.4)
        elif "NotificationShade" in focus_line or "Keyguard" in focus_line:
            _adb(["shell", "wm", "dismiss-keyguard"], serial=serial, check=False)
            _adb(["shell", "input", "keyevent", "82"], serial=serial, check=False)
            time.sleep(0.4)
        _adb(["shell", "am", "start", "-W", "-n", ANDROID_ACTIVITY], serial=serial, timeout=20.0, check=False)
        time.sleep(0.8)
    return focus_line


def _dump_android_diagnostics(serial: str) -> None:
    """Print concise process/window/logcat state when an AVD startup command fails."""
    pid = _adb(["shell", "pidof", ANDROID_PKG], serial=serial, check=False).stdout.strip()
    win = _adb(["shell", "dumpsys", "window"], serial=serial, check=False).stdout
    focus = [ln.strip() for ln in win.splitlines() if "mCurrentFocus=" in ln or "mFocusedApp=" in ln][-4:]
    logcat = _adb(
        ["logcat", "-d", "-t", "40", "-s", "flutter:V", "AndroidRuntime:E", "ActivityManager:W"],
        serial=serial,
        check=False,
    ).stdout
    print(f"Android AVD diagnostics: pid={pid!r} focus={focus}", flush=True)
    if logcat.strip():
        print(f"--- Android logcat (tail) ---\n{logcat[-2000:]}", flush=True)


def _run_android_flows(
    flows: list[dict[str, Any]],
    *,
    avd_name: str,
    rebuild_apk: bool,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    with ManagedWorkbenchServer(allow_emulator_host=True) as srv:
        wb = srv.client()
        serial = ensure_emulator_running(avd_name)
        _adb(["reverse", f"tcp:{srv.bound_port}", f"tcp:{srv.bound_port}"], serial=serial, check=False)
        build_and_install_dev_apk(
            serial,
            workbench_port=srv.bound_port,
            token=srv.token,
            rebuild=rebuild_apk,
        )
        client_id = _launch_app(wb, serial, clear_data=True)
        focus_info = _ensure_android_app_focus(serial)
        print(f"Android AVD focus after launch: {focus_info}", flush=True)
        try:
            wb.send_command(client_id, "loopbackSignIn", {}, timeout=30.0)
        except Exception:
            _dump_android_diagnostics(serial)
            raise
        time.sleep(0.7)

        for flow in flows:
            t0 = time.monotonic()
            fid = flow["id"]
            flow_error = ""
            baseline_errors = 0
            prior_error_delta = 0
            snap: dict[str, Any] = {}
            try:
                wb.reset_faults()
                snap0 = wb.snapshot(client_id, timeout=10.0)
                baseline_errors = int(((snap0.get("errors") or {}).get("count")) or 0)
                snap = snap0
                for step in flow.get("steps", []):
                    stype = step["type"]
                    if stype == "write_clipboard":
                        _ensure_android_app_focus(serial)
                        wb.send_command(
                            client_id,
                            "writeClipboard",
                            {"text": str(step.get("text") or "")},
                            timeout=10.0,
                        )
                        time.sleep(0.25)
                    elif stype == "adb_intent":
                        cmd = ["shell", "am", "start", "-a", str(step["action"])]
                        if step.get("data"):
                            cmd.extend(["-d", str(step["data"])])
                        if step.get("mime_type"):
                            cmd.extend(["-t", str(step["mime_type"])])
                        if step.get("extra_text"):
                            cmd.extend(["--es", "android.intent.extra.TEXT", str(step["extra_text"])])
                        cmd.extend(["-n", ANDROID_ACTIVITY])
                        _adb(cmd, serial=serial, check=True)
                        time.sleep(0.45)
                    elif stype == "cold_restart":
                        pre_snap = wb.snapshot(client_id, timeout=10.0)
                        pre_count = int(((pre_snap.get("errors") or {}).get("count")) or 0)
                        prior_error_delta += max(0, pre_count - baseline_errors)
                        client_id = _launch_app(wb, serial, clear_data=False)
                        baseline_errors = 0
                        time.sleep(0.6)
                        snap = wb.snapshot(client_id, timeout=10.0)
                    else:
                        _execute_android_step(
                            wb,
                            client_id,
                            serial,
                            snap,
                            {"kind": "viewport_ratio", "x_ratio": 0.5, "y_ratio": 0.5},
                            step,
                        )
                        if stype in ("navigate", "fault"):
                            snap = wb.snapshot(client_id, timeout=10.0)
                snap = wb.snapshot(client_id, timeout=10.0)
            except Exception as exc:
                flow_error = f"{type(exc).__name__}: {exc}"

            pid_out = _adb(["shell", "pidof", ANDROID_PKG], serial=serial, check=False).stdout.strip()
            if flow_error:
                a_results = [
                    AssertionResult(
                        id=str(a.get("id") or "step"),
                        type=str(a.get("type") or "step"),
                        passed=False,
                        detail=f"aborted before assertion: {flow_error}",
                    )
                    for a in flow.get("assertions", [])
                ]
                passed = False
            else:
                passed, a_results = evaluate_assertions(
                    flow.get("assertions", []),
                    snapshot=snap,
                    baseline_error_count=baseline_errors,
                    prior_error_delta=prior_error_delta,
                    process_alive=bool(pid_out),
                    find_bounds=lambda k, q: wb.send_command(
                        client_id, "findBounds", {"kind": k, "query": q}, timeout=8.0
                    ),
                    read_clipboard=lambda: wb.send_command(
                        client_id, "readClipboard", {}, timeout=8.0
                    ).get("text"),
                    check_file=lambda rel: wb.send_command(
                        client_id, "checkFile", {"relPath": rel}, timeout=8.0
                    ),
                )

            results.append({
                "flow_id": fid,
                "category": flow["category"],
                "platform": "android_avd",
                "passed": passed,
                "duration_sec": round(time.monotonic() - t0, 2),
                "error": flow_error or None,
                "assertions": [r.to_dict() for r in a_results],
            })
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run real-process OS E2E flows with declarative assertions.")
    parser.add_argument("--platform", choices=("linux", "android_avd"), required=True)
    parser.add_argument("--smoke", action="store_true", help="Run only flows tagged smoke=true")
    parser.add_argument("--flow-ids", nargs="*", help="Optional subset of flow IDs to execute")
    parser.add_argument("--linux-exe", type=Path, default=DEFAULT_LINUX_BUNDLE_EXE)
    parser.add_argument("--avd-name", default=DEFAULT_AVD)
    parser.add_argument("--no-rebuild-apk", action="store_true")
    parser.add_argument("--json-out", type=Path, help="Optional JSON report path")
    args = parser.parse_args(argv)

    flows = load_os_e2e_flows(
        platform=args.platform,
        smoke_only=args.smoke,
        flow_ids=set(args.flow_ids) if args.flow_ids else None,
    )
    if not flows:
        print(f"No OS E2E flows matched platform={args.platform} smoke={args.smoke}", file=sys.stderr)
        return 2

    t_start = time.monotonic()
    if args.platform == "linux":
        results = _run_linux_flows(flows, linux_exe=args.linux_exe)
    else:
        results = _run_android_flows(
            flows,
            avd_name=args.avd_name,
            rebuild_apk=not args.no_rebuild_apk,
        )
    total_sec = round(time.monotonic() - t_start, 2)

    all_passed = all(r["passed"] for r in results)
    report = {
        "platform": args.platform,
        "smoke": args.smoke,
        "passed": all_passed,
        "duration_sec": total_sec,
        "flows": results,
    }
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    for r in results:
        tag = "PASS" if r["passed"] else "FAIL"
        print(f"[{tag}] {r['flow_id']} ({r['category']}) in {r['duration_sec']}s")
        for a in r["assertions"]:
            atag = "ok" if a["passed"] else "FAIL"
            print(f"    {atag:4s} {a['id']}: {a['detail']}")
    passed_count = sum(1 for r in results if r["passed"])
    print(f"OS E2E ({args.platform}): {passed_count}/{len(results)} flows passed in {total_sec}s")
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
