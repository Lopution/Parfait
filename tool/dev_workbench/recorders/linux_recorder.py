"""Linux GTK automated dynamic recorder running under an isolated Xvfb display."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
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
from .encoder import encode_frames_to_media
from .manifest import storyboard_record_fields

DEFAULT_LINUX_BUNDLE_EXE = REPO_ROOT / "build" / "linux" / "x64" / "debug" / "bundle" / "parfait"

_XDOTOOL_KEYS = {
    "Escape": "Escape",
    "F11": "F11",
    "Left": "Left",
    "Right": "Right",
    "Space": "space",
    "PageDown": "Page_Down",
    "PageUp": "Page_Up",
    "Ctrl+K": "ctrl+k",
    "Ctrl+R": "ctrl+r",
    "Alt+Left": "alt+Left",
    "Back": "alt+Left",
}


def _find_free_display(start: int = 91, end: int = 120) -> str:
    for num in range(start, end + 1):
        lock = Path(f"/tmp/.X{num}-lock")
        sock = Path(f"/tmp/.X11-unix/X{num}")
        if not lock.exists() and not sock.exists():
            return f":{num}"
    raise RuntimeError("No free Xvfb display number in :91..:120")


def _drain_async(pipe: Any) -> None:
    try:
        for _ in pipe:
            pass
    except Exception:
        pass


class _X11FrameCapturer:
    """Samples PNG frames from the isolated Xvfb display while actions run."""

    def __init__(self, env: dict[str, str], wid: str, *, fps: int = 12) -> None:
        self.env = env
        self.wid = wid
        self.interval = 1.0 / max(1, fps)
        self.frames: list[bytes] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        import_bin = shutil.which("import") or "/usr/bin/import"
        while not self._stop.is_set():
            t0 = time.monotonic()
            try:
                res = subprocess.run(
                    [import_bin, "-window", self.wid or "root", "-silent", "png:-"],
                    env=self.env,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    timeout=3.0,
                )
                if res.returncode == 0 and res.stdout.startswith(b"\x89PNG"):
                    self.frames.append(res.stdout)
            except Exception:
                pass
            elapsed = time.monotonic() - t0
            rem = self.interval - elapsed
            if rem > 0:
                self._stop.wait(rem)

    def stop(self) -> list[bytes]:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=4.0)
        return self.frames


class _LinuxDevSession:
    def __init__(
        self,
        *,
        exe_path: Path,
        display: str,
        workbench_url: str,
        token: str,
        dev_root: Path,
        profile_name: str,
        fresh_onboarding: bool,
    ) -> None:
        self.exe_path = exe_path
        self.display = display
        self.workbench_url = workbench_url
        self.token = token
        self.dev_root = dev_root
        self.profile_name = profile_name
        self.fresh_onboarding = fresh_onboarding
        self.proc: subprocess.Popen[str] | None = None
        self.env = os.environ.copy()
        self.env["DISPLAY"] = display
        self.env["GDK_BACKEND"] = "x11"
        self.env["XDG_SESSION_TYPE"] = "x11"
        self.env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        self.env.pop("WAYLAND_DISPLAY", None)
        self.env["PARFAIT_DEV_PROFILE"] = "1"
        self.env["PARFAIT_DEV_INSTANCE"] = "1"
        self.env["PARFAIT_DEV_ROOT"] = str(dev_root)
        self.env["PARFAIT_APP_ID"] = "io.github.lopution.parfait.dev"
        self.env["PARFAIT_DEV_SHELL"] = "true"
        self.wid: str = "root"

    def start(self, wb: WorkbenchClient) -> str:
        self.dev_root.mkdir(parents=True, exist_ok=True)
        args = [
            str(self.exe_path),
            f"--dev-profile={self.profile_name}",
            "--source=loopback",
            f"--loopback={self.workbench_url}",
            f"--workbench-url={self.workbench_url}",
            f"--workbench-token={self.token}",
        ]
        if self.fresh_onboarding:
            args.append("--fresh-onboarding")
        self.proc = subprocess.Popen(
            args,
            cwd=str(self.exe_path.parent),
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        threading.Thread(target=_drain_async, args=(self.proc.stdout,), daemon=True).start()
        client = wb.wait_for_client(
            platform_prefix="linux",
            client_id_substring=self.profile_name,
            timeout=45.0,
        )
        self.wid = self._find_window_id()
        return str(client["clientId"])

    def _find_window_id(self) -> str:
        if self.proc is None:
            return "root"
        xdotool = shutil.which("xdotool") or "/usr/bin/xdotool"
        for _ in range(10):
            res = subprocess.run(
                [xdotool, "search", "--onlyvisible", "--pid", str(self.proc.pid)],
                env=self.env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=3.0,
            )
            wins = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
            if wins:
                # Focus & pick last mapped window
                wid = wins[-1]
                subprocess.run([xdotool, "windowfocus", wid], env=self.env, capture_output=True, timeout=3.0)
                return wid
            time.sleep(0.25)
        return "root"

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=4.0)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None


def _xdotool(env: dict[str, str], *args: str) -> None:
    bin_path = shutil.which("xdotool") or "/usr/bin/xdotool"
    subprocess.run(
        [bin_path, *args],
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=5.0,
        check=False,
    )


def _execute_linux_action(
    wb: WorkbenchClient,
    client_id: str,
    env: dict[str, str],
    wid: str,
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
    if stype == "resize_window":
        wb.send_command(client_id, "resizeWindow", {"width": step["width"], "height": step["height"]}, timeout=10.0)
        time.sleep(0.35)
        return
    if stype == "key":
        kname = _XDOTOOL_KEYS.get(str(step.get("key", "")), str(step.get("key", "")))
        if wid != "root":
            _xdotool(env, "windowfocus", wid)
        _xdotool(env, "key", "--clearmodifiers", kname)
        time.sleep(0.25)
        return
    if stype == "type_text":
        _xdotool(env, "type", "--delay", "25", str(step.get("text", "")))
        time.sleep(0.25)
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

    sx = str(int(round(pt["x"])))
    sy = str(int(round(pt["y"])))
    warg = ["--window", wid] if wid != "root" else []
    if stype in ("tap", "click"):
        _xdotool(env, "mousemove", *warg, sx, sy)
        time.sleep(0.06)
        _xdotool(env, "click", "1")
    elif stype == "double_click":
        _xdotool(env, "mousemove", *warg, sx, sy)
        _xdotool(env, "click", "--repeat", "2", "--delay", "80", "1")
    elif stype in ("right_click", "context_action"):
        _xdotool(env, "mousemove", *warg, sx, sy)
        _xdotool(env, "click", "3")
    elif stype == "hover":
        _xdotool(env, "mousemove", *warg, sx, sy)
        time.sleep(max(0.15, float(step.get("duration_ms", 500)) / 1000.0))
    elif stype == "scroll":
        _xdotool(env, "mousemove", *warg, sx, sy)
        dy = float(step.get("dy", -240))
        btn = "5" if dy < 0 else "4"
        ticks = max(2, min(10, round(abs(dy) / 60.0)))
        for _ in range(ticks):
            _xdotool(env, "click", btn)
            time.sleep(0.03)
    elif stype in ("drag", "swipe"):
        dx = float(step.get("dx_ratio", 0.0)) * float(pt["vw"])
        dy = float(step.get("dy_ratio", 0.0)) * float(pt["vh"])
        steps = 10
        ex = int(round(pt["x"] + dx))
        ey = int(round(pt["y"] + dy))
        _xdotool(env, "mousemove", *warg, sx, sy)
        _xdotool(env, "mousedown", "1")
        for i in range(1, steps + 1):
            ix = str(int(round(pt["x"] + dx * i / steps)))
            iy = str(int(round(pt["y"] + dy * i / steps)))
            _xdotool(env, "mousemove", *warg, ix, iy)
            time.sleep(0.03)
        _xdotool(env, "mousemove", *warg, str(ex), str(ey))
        _xdotool(env, "mouseup", "1")
    time.sleep(0.15)


def run_linux_recording(
    wb: WorkbenchClient,
    workbench_url: str,
    token: str,
    run_dir: Path,
    *,
    linux_exe: Path = DEFAULT_LINUX_BUNDLE_EXE,
    catalog_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    if not linux_exe.is_file():
        raise FileNotFoundError(f"Linux dev binary not found: {linux_exe}")

    items = load_catalog()
    if catalog_ids is not None:
        items = [it for it in items if it["id"] in catalog_ids]

    pre_items, signed_items, na_items = split_catalog_phases(items, platform="linux")
    records: list[dict[str, Any]] = []
    for it in na_items:
        records.append({
            "catalog_id": it["id"],
            "module": it.get("module"),
            "route_template": it.get("route_template"),
            "shell_layer": it.get("shell_layer"),
            "audit_candidate": it.get("audit_candidate"),
            "direction": it.get("direction"),
            "platform": "linux",
            "evidence_kind": "not_applicable",
            "capture_mode": "not_applicable",
            "status": "not_applicable",
            "artifact_relpath": None,
            "decode_verified": False,
            "diagnostics": {"reason": it["platforms"]["linux"]},
            "known_blind_spots": [],
        })

    display = _find_free_display()
    xvfb = subprocess.Popen(
        [shutil.which("Xvfb") or "/usr/bin/Xvfb", display, "-screen", "0", "1440x900x24", "-ac", "+extension", "GLX"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.6)
    with tempfile.TemporaryDirectory(prefix="parfait_linux_rec_") as tmp_dir:
        tmp_root = Path(tmp_dir)
        try:
            def _run_batch(batch: list[dict[str, Any]], *, fresh: bool, sign_in: bool) -> None:
                if not batch:
                    return
                launch_seq = 0

                def _open_sess() -> tuple[_LinuxDevSession, str]:
                    nonlocal launch_seq
                    launch_seq += 1
                    prof_base = "rec_onboard" if fresh else "rec_main"
                    prof_name = f"{prof_base}_{launch_seq}"
                    s_obj = _LinuxDevSession(
                        exe_path=linux_exe,
                        display=display,
                        workbench_url=workbench_url,
                        token=token,
                        dev_root=tmp_root / prof_name,
                        profile_name=prof_name,
                        fresh_onboarding=fresh,
                    )
                    cid_str = s_obj.start(wb)
                    try:
                        wb.send_command(cid_str, "resizeWindow", {"width": 1280, "height": 760}, timeout=15.0)
                        time.sleep(0.4)
                        # Collapse DEV SHELL banner if compiled with PARFAIT_DEV_SHELL=true so app layout starts cleanly at y=0
                        try:
                            snap0 = wb.snapshot(cid_str, timeout=5.0)
                            cbtn = wb.resolve_target(cid_str, {"kind": "key", "query": "dev-shell-collapse-btn"}, snap0)
                            _xdotool(s_obj.env, "mousemove", "--window", s_obj.wid, str(int(cbtn["x"])), str(int(cbtn["y"])))
                            _xdotool(s_obj.env, "click", "1")
                            time.sleep(0.25)
                        except Exception:
                            pass
                        if sign_in:
                            wb.send_command(cid_str, "loopbackSignIn", {}, timeout=12.0)
                            time.sleep(0.6)
                        return s_obj, cid_str
                    except BaseException:
                        s_obj.stop()
                        raise

                sess, client_id = _open_sess()
                try:
                    guide_completed_sent = False
                    for it in batch:
                        if not sess.is_alive():
                            sess.stop()
                            sess, client_id = _open_sess()
                            guide_completed_sent = False

                        cid = it["id"]
                        rt = it.get("route_template")
                        route_before = ""
                        route_after = ""
                        anomaly_reason = ""
                        hard_error = ""
                        blind_spots: list[str] = []
                        frames: list[bytes] = []
                        assertion_results: list[dict[str, Any]] = []
                        assertions_passed = True
                        baseline_error_count = 0
                        snap_after: dict[str, Any] = {}
                        capturer = _X11FrameCapturer(sess.env, sess.wid, fps=10)
                        cap_t0 = 0.0
                        cap_t1 = 0.0
                        try:
                            # Pre-home login routes require guideCompleted=true while still signed out
                            if fresh and rt in ("/login", "/user-agreement", "/login/web", "/login/callback") and not guide_completed_sent:
                                # Advance Welcome -> Language -> Next to persist guideCompleted naturally
                                wb.navigate(client_id, "/welcome/language", settle_sec=0.4)
                                snap_tmp = wb.snapshot(client_id)
                                try:
                                    btn = wb.resolve_target(client_id, {"kind": "any_text", "queries": ["下一步", "Next"]}, snap_tmp)
                                    _xdotool(sess.env, "mousemove", "--window", sess.wid, str(int(btn["x"])), str(int(btn["y"])))
                                    _xdotool(sess.env, "click", "1")
                                    time.sleep(0.5)
                                    guide_completed_sent = True
                                except Exception:
                                    pass

                            wb.reset_faults()
                            if not (fresh and rt == "/splash"):
                                wb.navigate(client_id, str(it["route"]), settle_sec=0.55)
                            snap = wb.snapshot(client_id)
                            route_before = str(snap.get("route") or "")
                            baseline_error_count = int(((snap.get("errors") or {}).get("count")) or 0)
                            cap_t0 = time.monotonic()
                            capturer.start()
                            time.sleep(0.15)
                            t_start = time.monotonic()
                            for step in it.get("actions", []):
                                if time.monotonic() - t_start > 15.0:
                                    anomaly_reason = "item action sequence exceeded 15s cap"
                                    break
                                _execute_linux_action(wb, client_id, sess.env, sess.wid, snap, it["target"], step)
                                if step.get("type") in ("navigate", "resize_window", "fault") or step.get("key") == "F11":
                                    try:
                                        snap = wb.snapshot(client_id)
                                        if step.get("key") == "F11" and not bool(snap.get("isFullScreen")):
                                            if "xvfb_without_ewmh_wm_fullscreen_noop" not in blind_spots:
                                                blind_spots.append("xvfb_without_ewmh_wm_fullscreen_noop")
                                    except Exception:
                                        pass
                            time.sleep(0.25)
                        except (CommandTimeoutError, TargetNotFoundError, Exception) as exc:
                            anomaly_reason = f"{type(exc).__name__}: {exc}"
                        finally:
                            frames = capturer.stop()
                            cap_t1 = time.monotonic()
                            wb.reset_faults()
                            if sess.is_alive():
                                try:
                                    snap_after = wb.snapshot(client_id, timeout=5.0)
                                    route_after = str(snap_after.get("route") or "")
                                    vp_after = snap_after.get("viewport") or {}
                                    vw_after = float(vp_after.get("width", 0) or 0)
                                    vh_after = float(vp_after.get("height", 0) or 0)
                                    if snap_after.get("isFullScreen"):
                                        try:
                                            _xdotool(sess.env, "key", "--window", sess.wid, "F11")
                                            time.sleep(0.15)
                                        except Exception:
                                            pass
                                    if (
                                        snap_after.get("isFullScreen")
                                        or snap_after.get("isMaximized")
                                        or any(s.get("type") == "resize_window" for s in it.get("actions", []))
                                        or abs(vw_after - 1280.0) > 2.0
                                        or abs(vh_after - 760.0) > 2.0
                                    ):
                                        try:
                                            wb.send_command(client_id, "resizeWindow", {"width": 1280, "height": 760}, timeout=8.0)
                                            time.sleep(0.2)
                                        except Exception:
                                            pass
                                except Exception:
                                    route_after = route_before

                        item_assertions = it.get("assertions")
                        if isinstance(item_assertions, list) and item_assertions:
                            ok_a, res_a = evaluate_assertions(
                                item_assertions,
                                snapshot=snap_after or snap,
                                baseline_error_count=baseline_error_count,
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
                            )
                            assertions_passed = ok_a
                            assertion_results = [r.to_dict() for r in res_a]

                        if not frames:
                            # No X11 frames captured; record failed item without aborting batch.
                            hard_error = anomaly_reason or "no X11 frames captured"
                            records.append({
                                "catalog_id": cid,
                                "module": it.get("module"),
                                "route_template": rt,
                                "shell_layer": it.get("shell_layer"),
                                "audit_candidate": it.get("audit_candidate"),
                                "direction": it.get("direction"),
                                "platform": "linux",
                                "evidence_kind": "native_os_recording",
                                "capture_mode": "x11_window_capture",
                                "status": "failed",
                                "artifact_relpath": None,
                                "decode_verified": False,
                                "route_before": route_before,
                                "route_after": route_after,
                                "diagnostics": {"error": hard_error},
                                "known_blind_spots": [],
                            })
                            continue

                        fmt = str(it.get("format", "gif"))
                        rel = f"linux/{cid}.{fmt}"
                        out_path = run_dir / rel
                        sheet_dir = run_dir / "sheets" / "linux" / cid
                        actual_elapsed = max(0.2, (cap_t1 - cap_t0) if cap_t0 > 0 else 1.0)
                        measured_fps = max(1, min(10, round(len(frames) / actual_elapsed)))
                        try:
                            art = encode_frames_to_media(
                                frames,
                                out_path,
                                fmt,
                                fps=measured_fps,
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
                                "platform": "linux",
                                "evidence_kind": "native_os_recording",
                                "capture_mode": "x11_window_capture",
                                "status": "failed",
                                "artifact_relpath": None,
                                "decode_verified": False,
                                "route_before": route_before,
                                "route_after": route_after,
                                "diagnostics": {"error": f"{anomaly_reason}; encode={enc_exc}".strip("; ")},
                                "known_blind_spots": blind_spots,
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
                            "platform": "linux",
                            "evidence_kind": "native_os_recording",
                            "capture_mode": "x11_window_capture",
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
                                "frame_count": len(frames),
                            },
                            "known_blind_spots": blind_spots,
                            **storyboard_record_fields(art.sheet_paths, art.motion_metrics, run_dir),
                        })
                finally:
                    sess.stop()

            _run_batch(pre_items, fresh=True, sign_in=False)
            _run_batch(signed_items, fresh=False, sign_in=True)
        finally:
            xvfb.terminate()
            try:
                xvfb.wait(timeout=4.0)
            except subprocess.TimeoutExpired:
                xvfb.kill()

    return records
