"""Android KVM AVD (`parfait_api35`) native touch & screenrecord automated driver."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from ..assertions import evaluate_assertions
from .common import (
    CommandTimeoutError,
    REPO_ROOT,
    TargetNotFoundError,
    WorkbenchClient,
    load_catalog,
    split_catalog_phases,
)
from .encoder import transcode_video_segment
from .manifest import storyboard_record_fields

ANDROID_PKG = "io.github.lopution.parfait.dev"
ANDROID_ACTIVITY = "io.github.lopution.parfait.dev/io.github.lopution.parfait.MainActivity"
DEFAULT_ADB = "/opt/android-sdk/platform-tools/adb"
DEFAULT_EMULATOR = "/opt/android-sdk/emulator/emulator"
DEFAULT_AVD = "parfait_api35"
DEFAULT_APK = REPO_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-github-debug.apk"

_ANDROID_KEYCODES = {
    "Escape": "111",   # KEYCODE_ESCAPE
    "Back": "4",       # KEYCODE_BACK
    "Alt+Left": "4",   # KEYCODE_BACK
    "Left": "21",
    "Right": "22",
    "Space": "62",
    "PageDown": "93",
    "PageUp": "92",
}


def _adb_bin() -> str:
    return shutil.which("adb") or DEFAULT_ADB


def _adb(args: list[str], *, serial: str | None = None, timeout: float = 20.0, check: bool = True) -> subprocess.CompletedProcess[str]:
    cmd = [_adb_bin()]
    if serial:
        cmd.extend(["-s", serial])
    cmd.extend(args)
    return subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=check,
    )


def ensure_emulator_running(avd_name: str = DEFAULT_AVD, *, timeout: float = 90.0) -> str:
    """Return online emulator serial (`emulator-...`), booting headless KVM AVD if absent."""
    res = _adb(["devices"], check=True)
    for line in res.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith("emulator-") and parts[1] == "device":
            return parts[0]

    emulator_bin = os.environ.get("PARFAIT_ANDROID_EMULATOR", DEFAULT_EMULATOR)
    if not Path(emulator_bin).is_file():
        raise FileNotFoundError(f"Android emulator binary not found: {emulator_bin}")
    subprocess.Popen(
        [
            emulator_bin,
            "-avd",
            avd_name,
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            "-gpu",
            "swiftshader_indirect",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + timeout
    serial = ""
    while time.time() < deadline:
        dev_out = _adb(["devices"], check=False).stdout
        for line in dev_out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("emulator-") and parts[1] == "device":
                serial = parts[0]
                break
        if serial:
            boot = _adb(["shell", "getprop", "sys.boot_completed"], serial=serial, check=False).stdout.strip()
            if boot == "1":
                _adb(["shell", "wm", "dismiss-keyguard"], serial=serial, check=False)
                _adb(["shell", "input", "keyevent", "82"], serial=serial, check=False)
                return serial
        time.sleep(1.5)
    raise TimeoutError(f"Timed out waiting for KVM AVD {avd_name} to boot")


def build_and_install_dev_apk(
    serial: str,
    *,
    workbench_port: int,
    token: str,
    rebuild: bool = True,
) -> Path:
    if rebuild:
        flutter = os.environ.get("FLUTTER_BIN") or shutil.which("flutter") or "/opt/flutter-3.47.9/bin/flutter"
        env = os.environ.copy()
        extra_paths = [p for p in ("/opt/flutter-3.47.9/bin", "/opt/android-sdk/platform-tools") if Path(p).is_dir()]
        if extra_paths:
            env["PATH"] = f"{':'.join(extra_paths)}:{env.get('PATH', '')}"
        origin = f"http://10.0.2.2:{workbench_port}"
        flutter_cmd = [
            flutter,
            "build",
            "apk",
            "--debug",
            "--flavor",
            "github",
            "-t",
            "lib/main_dev.dart",
            "--dart-define=PARFAIT_DEV_APP_ID=true",
            "--dart-define=PARFAIT_DEV_SHELL=false",
            "--dart-define=PARFAIT_DEV_FRESH_ONBOARDING=true",
            "--dart-define=PARFAIT_DEV_PROFILE_NAME=avd_rec",
            "--dart-define=PARFAIT_DEV_SOURCE=loopback",
            f"--dart-define=PARFAIT_DEV_LOOPBACK_URL={origin}",
            f"--dart-define=PARFAIT_WORKBENCH_URL={origin}",
            f"--dart-define=PARFAIT_WORKBENCH_TOKEN={token}",
        ]
        use_scope = False
        if shutil.which("systemd-run") and os.environ.get("CI") != "true":
            probe = subprocess.run(
                ["systemd-run", "--scope", "--quiet", "-p", "MemoryMax=6G", "true"],
                capture_output=True,
                check=False,
            )
            use_scope = probe.returncode == 0
        cmd = (
            ["systemd-run", "--scope", "--quiet", "-p", "MemoryMax=6G", "-p", "MemorySwapMax=0", *flutter_cmd]
            if use_scope
            else flutter_cmd
        )
        res = subprocess.run(cmd, cwd=str(REPO_ROOT), env=env, capture_output=True, text=True, timeout=600.0)
        if res.returncode != 0:
            raise RuntimeError(f"Android dev APK build failed:\n{res.stdout[-1500:]}\n{res.stderr[-1500:]}")
    if not DEFAULT_APK.is_file():
        raise FileNotFoundError(f"Missing dev APK: {DEFAULT_APK}")
    inst = _adb(["install", "-r", "-d", str(DEFAULT_APK)], serial=serial, timeout=90.0, check=False)
    if inst.returncode != 0:
        raise RuntimeError(f"adb install failed: {inst.stdout}\n{inst.stderr}")
    return DEFAULT_APK


def _physical_display_size(serial: str) -> tuple[int, int]:
    out = _adb(["shell", "wm", "size"], serial=serial, check=False).stdout
    m = re.search(r"Physical size:\s*(\d+)x(\d+)", out)
    if m:
        return int(m.group(1)), int(m.group(2))
    return 1080, 2400


def _launch_app(wb: WorkbenchClient, serial: str, *, clear_data: bool) -> str:
    _adb(["shell", "am", "force-stop", ANDROID_PKG], serial=serial, check=False)
    if clear_data:
        _adb(["shell", "pm", "clear", ANDROID_PKG], serial=serial, check=False)
    _adb(["shell", "am", "start", "-n", ANDROID_ACTIVITY], serial=serial, check=True)
    app_pid = ""
    for _ in range(15):
        out = _adb(["shell", "pidof", ANDROID_PKG], serial=serial, check=False).stdout.strip()
        if out:
            app_pid = out.split()[0]
            break
        time.sleep(0.3)
    client = wb.wait_for_client(
        platform_prefix="android",
        client_id_substring=f"-{app_pid}" if app_pid else None,
        timeout=50.0,
    )
    return str(client["clientId"])


def _execute_android_step(
    wb: WorkbenchClient,
    client_id: str,
    serial: str,
    snap: dict[str, Any],
    base_target: dict[str, Any],
    step: dict[str, Any],
) -> None:
    stype = step["type"]
    step_target = step.get("target") or base_target

    if stype == "wait_ms":
        time.sleep(max(0.05, float(step.get("ms", 300)) / 1000.0))
        return
    if stype == "navigate":
        wb.navigate(client_id, str(step["path"]), settle_sec=0.55)
        return
    if stype == "fault":
        if step.get("reset"):
            wb.reset_faults()
        else:
            wb.set_fault(str(step["routePrefix"]), str(step["mode"]))
        return
    if stype == "key":
        kc = _ANDROID_KEYCODES.get(str(step.get("key", "")))
        if kc:
            _adb(["shell", "input", "keyevent", kc], serial=serial, check=False)
            time.sleep(0.3)
        return
    if stype == "type_text":
        raw = str(step.get("text", "")).replace(" ", "%s")
        _adb(["shell", "input", "text", raw], serial=serial, check=False)
        time.sleep(0.3)
        return

    try:
        override = (
            float(step["offset_x_ratio"]) if "offset_x_ratio" in step else float(step_target.get("offset_x_ratio", 0.5)),
            float(step["offset_y_ratio"]) if "offset_y_ratio" in step else float(step_target.get("offset_y_ratio", 0.5)),
        )
        pt = wb.resolve_target(client_id, step_target, snap, override_offsets=override)
    except TargetNotFoundError:
        if stype == "scroll" and step.get("target") is None:
            pt = wb.resolve_target(client_id, {"kind": "viewport_ratio", "x_ratio": 0.5, "y_ratio": 0.55}, snap)
        elif step.get("optional"):
            return
        else:
            raise

    px, py = int(pt["px"]), int(pt["py"])
    disp_w, disp_h = _physical_display_size(serial)
    px = max(2, min(disp_w - 2, px))
    py = max(2, min(disp_h - 2, py))

    if stype in ("tap", "click"):
        _adb(["shell", "input", "tap", str(px), str(py)], serial=serial, check=False)
    elif stype == "double_click":
        _adb(["shell", "input", "tap", str(px), str(py)], serial=serial, check=False)
        time.sleep(0.08)
        _adb(["shell", "input", "tap", str(px), str(py)], serial=serial, check=False)
    elif stype in ("long_press", "context_action"):
        _adb(["shell", "input", "swipe", str(px), str(py), str(px), str(py), "650"], serial=serial, check=False)
    elif stype == "scroll":
        dy = float(step.get("dy", -240)) * float(pt["dpr"])
        ey = max(8, min(disp_h - 8, int(round(py + dy))))
        _adb(["shell", "input", "swipe", str(px), str(py), str(px), str(ey), "320"], serial=serial, check=False)
    elif stype in ("drag", "swipe"):
        dx = float(step.get("dx_ratio", 0.0)) * float(pt["vw"]) * float(pt["dpr"])
        dy = float(step.get("dy_ratio", 0.0)) * float(pt["vh"]) * float(pt["dpr"])
        dur = max(120, int(step.get("duration_ms", 320)))
        ex = max(2, min(disp_w - 2, int(round(px + dx))))
        ey = max(2, min(disp_h - 2, int(round(py + dy))))
        _adb(["shell", "input", "swipe", str(px), str(py), str(ex), str(ey), str(dur)], serial=serial, check=False)
    time.sleep(0.25)


def run_android_recording(
    wb: WorkbenchClient,
    workbench_port: int,
    token: str,
    run_dir: Path,
    *,
    avd_name: str = DEFAULT_AVD,
    rebuild_apk: bool = True,
    catalog_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    serial = ensure_emulator_running(avd_name)
    _adb(["reverse", f"tcp:{workbench_port}", f"tcp:{workbench_port}"], serial=serial, check=False)
    build_and_install_dev_apk(serial, workbench_port=workbench_port, token=token, rebuild=rebuild_apk)

    items = load_catalog()
    if catalog_ids is not None:
        items = [it for it in items if it["id"] in catalog_ids]

    pre_items, signed_items, na_items = split_catalog_phases(items, platform="android_avd")
    records: list[dict[str, Any]] = []
    for it in na_items:
        records.append({
            "catalog_id": it["id"],
            "module": it.get("module"),
            "route_template": it.get("route_template"),
            "shell_layer": it.get("shell_layer"),
            "audit_candidate": it.get("audit_candidate"),
            "direction": it.get("direction"),
            "platform": "android_avd",
            "evidence_kind": "not_applicable",
            "capture_mode": "not_applicable",
            "status": "not_applicable",
            "artifact_relpath": None,
            "decode_verified": False,
            "diagnostics": {"reason": it["platforms"]["android_avd"]},
            "known_blind_spots": [],
        })

    with tempfile.TemporaryDirectory(prefix="parfait_avd_rec_") as tmp_dir:
        tmp_root = Path(tmp_dir)

        def _run_batch(batch: list[dict[str, Any]], *, clear_data: bool, sign_in: bool) -> None:
            if not batch:
                return
            client_id = _launch_app(wb, serial, clear_data=clear_data)
            if sign_in:
                wb.send_command(client_id, "loopbackSignIn", {}, timeout=15.0)
                time.sleep(0.7)

            guide_completed_sent = False
            remote_mp4 = "/sdcard/parfait_rec_item.mp4"
            for it in batch:
                cid = it["id"]
                rt = it.get("route_template")
                if clear_data and rt in ("/login", "/user-agreement", "/login/web", "/login/callback") and not guide_completed_sent:
                    wb.navigate(client_id, "/welcome/language", settle_sec=0.4)
                    snap_tmp = wb.snapshot(client_id)
                    try:
                        btn = wb.resolve_target(client_id, {"kind": "any_text", "queries": ["下一步", "Next"]}, snap_tmp)
                        _adb(["shell", "input", "tap", str(btn["px"]), str(btn["py"])], serial=serial, check=False)
                        time.sleep(0.6)
                        guide_completed_sent = True
                    except Exception:
                        pass

                wb.reset_faults()
                route_before = ""
                route_after = ""
                anomaly_reason = ""
                assertion_results: list[dict[str, Any]] = []
                assertions_passed = True
                baseline_error_count = 0
                snap: dict[str, Any] = {}
                snap_after: dict[str, Any] = {}
                try:
                    if not (clear_data and rt == "/splash"):
                        wb.navigate(client_id, str(it["route"]), settle_sec=0.65)
                except Exception as exc:
                    anomaly_reason = f"{type(exc).__name__}: {exc}"

                _adb(["shell", "rm", "-f", remote_mp4], serial=serial, check=False)
                rec_proc = subprocess.Popen(
                    [_adb_bin(), "-s", serial, "shell", "screenrecord", "--time-limit", "20", "--bit-rate", "6000000", remote_mp4],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(0.45)
                t0 = time.monotonic()
                try:
                    snap = wb.snapshot(client_id)
                    route_before = str(snap.get("route") or "")
                    baseline_error_count = int(((snap.get("errors") or {}).get("count")) or 0)
                    for step in it.get("actions", []):
                        if time.monotonic() - t0 > 15.0:
                            anomaly_reason = "item action sequence exceeded 15s cap"
                            break
                        _execute_android_step(wb, client_id, serial, snap, it["target"], step)
                        if step.get("type") in ("navigate", "fault"):
                            try:
                                snap = wb.snapshot(client_id)
                            except Exception:
                                pass
                    time.sleep(0.35)
                except (CommandTimeoutError, TargetNotFoundError, Exception) as exc:
                    anomaly_reason = f"{type(exc).__name__}: {exc}"
                finally:
                    # Graceful SIGINT inside Android shell so moov atom flushes cleanly
                    _adb(["shell", "pkill", "-INT", "screenrecord"], serial=serial, check=False)
                    try:
                        rec_proc.wait(timeout=4.0)
                    except subprocess.TimeoutExpired:
                        rec_proc.kill()
                    time.sleep(0.25)
                    wb.reset_faults()
                    try:
                        snap_after = wb.snapshot(client_id, timeout=5.0)
                        route_after = str(snap_after.get("route") or "")
                    except Exception:
                        route_after = route_before

                item_assertions = it.get("assertions")
                if isinstance(item_assertions, list) and item_assertions:
                    pid_out = _adb(["shell", "pidof", ANDROID_PKG], serial=serial, check=False).stdout.strip()
                    ok_a, res_a = evaluate_assertions(
                        item_assertions,
                        snapshot=snap_after or snap,
                        baseline_error_count=baseline_error_count,
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
                    assertions_passed = ok_a
                    assertion_results = [r.to_dict() for r in res_a]

                local_raw = tmp_root / f"{cid}.raw.mp4"
                pull = _adb(["pull", remote_mp4, str(local_raw)], serial=serial, check=False)
                _adb(["shell", "rm", "-f", remote_mp4], serial=serial, check=False)
                if pull.returncode != 0 or not local_raw.is_file() or local_raw.stat().st_size <= 0:
                    records.append({
                        "catalog_id": cid,
                        "module": it.get("module"),
                        "route_template": rt,
                        "shell_layer": it.get("shell_layer"),
                        "audit_candidate": it.get("audit_candidate"),
                        "direction": it.get("direction"),
                        "platform": "android_avd",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "adb_screenrecord",
                        "status": "failed",
                        "artifact_relpath": None,
                        "decode_verified": False,
                        "route_before": route_before,
                        "route_after": route_after,
                        "diagnostics": {"error": anomaly_reason or f"adb pull failed: {pull.stderr.strip()}"},
                        "known_blind_spots": [],
                    })
                    continue

                fmt = str(it.get("format", "gif"))
                rel = f"android_avd/{cid}.{fmt}"
                out_path = run_dir / rel
                sheet_dir = run_dir / "sheets" / "android_avd" / cid
                dur_total = max(0.8, time.monotonic() - t0)
                try:
                    art = transcode_video_segment(
                        local_raw,
                        out_path,
                        fmt,
                        start_sec=0.35,
                        duration_sec=dur_total,
                        sheet_dir=sheet_dir,
                        direction=str(it.get("direction") or "one_way"),
                    )
                except Exception as enc_exc:
                    records.append({
                        "catalog_id": cid,
                        "module": it.get("module"),
                        "route_template": rt,
                        "shell_layer": it.get("shell_layer"),
                        "audit_candidate": it.get("audit_candidate"),
                        "direction": it.get("direction"),
                        "platform": "android_avd",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": "adb_screenrecord",
                        "status": "failed",
                        "artifact_relpath": None,
                        "decode_verified": False,
                        "route_before": route_before,
                        "route_after": route_after,
                        "diagnostics": {"error": f"{anomaly_reason}; encode={enc_exc}".strip("; ")},
                        "known_blind_spots": [],
                    })
                    continue
                st = "ok"
                if not art.decode_verified or not assertions_passed:
                    st = "failed"
                elif anomaly_reason:
                    st = "recorded_with_anomaly"
                records.append({
                    "catalog_id": cid,
                    "module": it.get("module"),
                    "route_template": rt,
                    "shell_layer": it.get("shell_layer"),
                    "audit_candidate": it.get("audit_candidate"),
                    "direction": it.get("direction"),
                    "platform": "android_avd",
                    "evidence_kind": "native_os_recording",
                    "capture_mode": "adb_screenrecord",
                    "status": st,
                    "artifact_relpath": rel,
                    "format": fmt,
                    "width": art.width,
                    "height": art.height,
                    "bytes": art.bytes,
                    "duration_ms": art.duration_ms,
                    "decode_verified": art.decode_verified,
                    "route_before": route_before,
                    "route_after": route_after,
                    "diagnostics": {
                        **({"anomaly": anomaly_reason} if anomaly_reason else {}),
                        **({"decode_error": art.decode_error} if art.decode_error else {}),
                        **({"assertions": assertion_results} if assertion_results else {}),
                    },
                    "known_blind_spots": [],
                    **storyboard_record_fields(art.sheet_paths, art.motion_metrics, run_dir),
                })

        _run_batch(pre_items, clear_data=True, sign_in=False)
        _run_batch(signed_items, clear_data=True, sign_in=True)

    return records
