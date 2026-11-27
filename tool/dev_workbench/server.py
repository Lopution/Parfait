"""Hardened localhost-only Web Workbench & Pixiv Loopback Gateway server."""

from __future__ import annotations

import argparse
import base64
import binascii
import collections
import hmac
import html
import json
import mimetypes
import os
import re
import secrets
import signal
import socket
import sys
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.pixiv_fixtures import PixivLoopbackState
from dev_workbench.redaction import redact_headers, redact_text, redact_value

ALLOWED_FAULT_MODES = frozenset({
    "none",
    "delay_2s",
    "rate_limit_429",
    "server_500",
    "empty",
    "offline",
})

ALLOWED_COMMANDS = frozenset({
    "snapshot",
    "navigate",
    "history",
    "setSourceMode",
    "resizeWindow",
    "findBounds",
    "frameProbe",
    "loopbackSignIn",
    "captureScreenshot",
    "readClipboard",
    "writeClipboard",
    "checkFile",
})

_WEB_DIR = Path(__file__).resolve().parent / "web"


def is_valid_internal_route(path: str) -> bool:
    if not isinstance(path, str) or not path.startswith("/") or len(path) > 256:
        return False
    if "://" in path or "\\" in path or any(ch.isspace() for ch in path):
        return False
    parsed = urllib.parse.urlsplit(path)
    segments = [seg for seg in parsed.path.split("/") if seg]
    return ".." not in segments and "." not in segments


def is_allowed_loopback_origin(raw: str) -> bool:
    try:
        parsed = urllib.parse.urlsplit(raw)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "http" and host in ("127.0.0.1", "localhost", "::1", "10.0.2.2")


def validate_command_payload(payload: Any) -> tuple[str, str, dict[str, Any]]:
    if not isinstance(payload, dict):
        raise ValueError("command body must be a JSON object")
    unknown_top = set(payload.keys()) - {"clientId", "type", "args"}
    if unknown_top:
        raise ValueError(f"unsupported top-level keys: {sorted(unknown_top)}")
    client_id = payload.get("clientId")
    cmd_type = payload.get("type")
    args = payload.get("args", {})
    if not isinstance(client_id, str) or not client_id.strip() or len(client_id) > 128:
        raise ValueError("clientId must be a non-empty string <= 128 chars")
    if not isinstance(cmd_type, str) or cmd_type not in ALLOWED_COMMANDS:
        raise ValueError(f"unsupported command type: {cmd_type!r}")
    if not isinstance(args, dict):
        raise ValueError("args must be a JSON object")

    if cmd_type == "navigate":
        if set(args.keys()) - {"path"}:
            raise ValueError("navigate allows only 'path'")
        path = args.get("path")
        if not isinstance(path, str) or not is_valid_internal_route(path):
            raise ValueError("invalid internal route path")
        return client_id.strip(), cmd_type, {"path": path}

    if cmd_type == "history":
        if set(args.keys()) - {"action"}:
            raise ValueError("history allows only 'action'")
        action = args.get("action")
        if action not in ("back", "forward"):
            raise ValueError("history action must be 'back' or 'forward'")
        return client_id.strip(), cmd_type, {"action": action}

    if cmd_type == "setSourceMode":
        if set(args.keys()) - {"mode", "loopbackOrigin"}:
            raise ValueError("setSourceMode allows only 'mode' and 'loopbackOrigin'")
        mode = args.get("mode")
        if mode not in ("live", "loopback"):
            raise ValueError("mode must be 'live' or 'loopback'")
        clean: dict[str, Any] = {"mode": mode}
        origin = args.get("loopbackOrigin")
        if origin is not None:
            if not isinstance(origin, str) or (origin and not is_allowed_loopback_origin(origin)):
                raise ValueError("loopbackOrigin must be an http loopback URL")
            if origin:
                clean["loopbackOrigin"] = origin
        return client_id.strip(), cmd_type, clean

    if cmd_type == "resizeWindow":
        if set(args.keys()) - {"width", "height"}:
            raise ValueError("resizeWindow allows only 'width' and 'height'")
        w = args.get("width")
        h = args.get("height")
        if (
            isinstance(w, bool)
            or isinstance(h, bool)
            or not isinstance(w, (int, float))
            or not isinstance(h, (int, float))
        ):
            raise ValueError("width and height must be numbers")
        if not (320 <= w <= 3840) or not (320 <= h <= 2160):
            raise ValueError("viewport bounds must be within 320..3840 x 320..2160")
        return client_id.strip(), cmd_type, {"width": int(w), "height": int(h)}

    if cmd_type == "findBounds":
        unknown = set(args.keys()) - {"kind", "query", "key", "semantics", "text"}
        if unknown:
            raise ValueError(f"findBounds unexpected keys: {sorted(unknown)}")
        if "kind" in args or "query" in args:
            kind = args.get("kind")
            query = args.get("query")
            if kind not in ("key", "semantics", "text"):
                raise ValueError("findBounds.kind must be key, semantics, or text")
            if not isinstance(query, str) or not query.strip() or len(query) > 128:
                raise ValueError("findBounds.query must be a non-empty string <= 128 chars")
            return client_id.strip(), cmd_type, {"kind": kind, "query": query}
        clean_fb: dict[str, Any] = {}
        for k in ("key", "semantics", "text"):
            if k in args and args[k] is not None:
                v = args[k]
                if not isinstance(v, str) or not v.strip() or len(v) > 128:
                    raise ValueError(f"findBounds.{k} must be non-empty <= 128 chars")
                clean_fb[k] = v
        if not clean_fb:
            raise ValueError("findBounds requires kind+query or key/semantics/text")
        return client_id.strip(), cmd_type, clean_fb

    if cmd_type == "frameProbe":
        if set(args.keys()) - {"action"}:
            raise ValueError("frameProbe allows only 'action'")
        action = args.get("action", "summary")
        if action not in ("start", "stop", "summary"):
            raise ValueError("frameProbe action must be start, stop, or summary")
        return client_id.strip(), cmd_type, {"action": action}

    if cmd_type == "snapshot":
        if set(args.keys()) - {"afterSeq"}:
            raise ValueError("snapshot allows only 'afterSeq'")
        clean_snap: dict[str, Any] = {}
        if "afterSeq" in args:
            seq = args["afterSeq"]
            if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
                raise ValueError("afterSeq must be non-negative int")
            clean_snap["afterSeq"] = seq
        return client_id.strip(), cmd_type, clean_snap

    if cmd_type in ("loopbackSignIn", "captureScreenshot", "readClipboard"):
        if args:
            raise ValueError(f"{cmd_type} accepts no arguments")
        return client_id.strip(), cmd_type, {}

    if cmd_type == "writeClipboard":
        if set(args.keys()) - {"text"}:
            raise ValueError("writeClipboard allows only 'text'")
        text = args.get("text")
        if not isinstance(text, str) or len(text) > 4096:
            raise ValueError("writeClipboard.text must be a string <= 4096 chars")
        return client_id.strip(), cmd_type, {"text": text}

    if cmd_type == "checkFile":
        if set(args.keys()) - {"relPath"}:
            raise ValueError("checkFile allows only 'relPath'")
        rel_path = args.get("relPath")
        if (
            not isinstance(rel_path, str)
            or not rel_path.strip()
            or len(rel_path) > 256
            or rel_path.startswith("/")
            or "\\" in rel_path
            or ".." in [seg for seg in rel_path.split("/") if seg]
        ):
            raise ValueError("checkFile.relPath must be a safe relative path")
        return client_id.strip(), cmd_type, {"relPath": rel_path.strip()}


def validate_fault_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("fault body must be a JSON object")
    if payload.get("reset") is True and set(payload.keys()) == {"reset"}:
        return {"reset": True}
    unknown = set(payload.keys()) - {"routePrefix", "mode"}
    if unknown:
        raise ValueError(f"unsupported fault keys: {sorted(unknown)}")
    prefix = payload.get("routePrefix")
    mode = payload.get("mode")
    if (
        not isinstance(prefix, str)
        or not prefix.startswith("/")
        or len(prefix) > 128
        or any(ch.isspace() for ch in prefix)
        or ".." in prefix
    ):
        raise ValueError("routePrefix must start with '/', <= 128 chars, without '..' or whitespace")
    if not isinstance(mode, str) or mode not in ALLOWED_FAULT_MODES:
        raise ValueError(f"unsupported fault mode: {mode!r}")
    return {"routePrefix": prefix, "mode": mode}


@dataclass
class ClientSession:
    client_id: str
    platform: str
    last_seen: float
    ack_seq: int = 0
    snapshot: dict[str, Any] = field(default_factory=dict)
    pending_commands: list[dict[str, Any]] = field(default_factory=list)


class WorkbenchState:
    def __init__(self, token: str, artifacts_dir: Path | None = None) -> None:
        self.token = token
        self.artifacts_dir = artifacts_dir.resolve() if artifacts_dir else None
        self.lock = threading.Lock()
        self.pixiv = PixivLoopbackState()
        self.clients: dict[str, ClientSession] = {}
        self.logs: collections.deque[dict[str, Any]] = collections.deque(maxlen=600)
        self.gateway_traces: collections.deque[dict[str, Any]] = collections.deque(maxlen=300)
        self.command_results: collections.deque[dict[str, Any]] = collections.deque(maxlen=150)
        self.screenshots: collections.OrderedDict[str, bytes] = collections.OrderedDict()
        self.faults: dict[str, str] = {}
        self.gateway_count = 0
        self._trace_seq = 0

    def enqueue_command(self, client_id: str, cmd_type: str, args: dict[str, Any]) -> str:
        cmd_id = uuid.uuid4().hex[:12]
        with self.lock:
            session = self.clients.get(client_id)
            if session is None:
                raise KeyError(f"unknown clientId: {client_id}")
            session.pending_commands.append({
                "id": cmd_id,
                "type": cmd_type,
                "args": args,
            })
        return cmd_id

    def set_fault(self, payload: dict[str, Any]) -> dict[str, str]:
        with self.lock:
            if payload.get("reset") is True:
                self.faults.clear()
            else:
                prefix = str(payload["routePrefix"])
                mode = str(payload["mode"])
                if mode == "none":
                    self.faults.pop(prefix, None)
                else:
                    self.faults[prefix] = mode
            return dict(self.faults)

    def match_fault(self, path: str) -> str:
        with self.lock:
            best_len = -1
            matched = "none"
            for prefix, mode in self.faults.items():
                if path.startswith(prefix) and len(prefix) > best_len:
                    best_len = len(prefix)
                    matched = mode
            return matched

    def record_heartbeat(self, payload: dict[str, Any]) -> tuple[int, list[dict[str, Any]]]:
        client_id = str(payload.get("clientId", "")).strip()
        if not client_id:
            raise ValueError("missing clientId")
        platform = redact_text(str(payload.get("platform", "unknown")))
        snapshot = redact_value(payload.get("snapshot", {}))
        if not isinstance(snapshot, dict):
            snapshot = {}
        raw_logs = payload.get("logs", [])
        now = time.time()
        with self.lock:
            session = self.clients.get(client_id)
            if session is None:
                session = ClientSession(
                    client_id=client_id,
                    platform=platform,
                    last_seen=now,
                )
                self.clients[client_id] = session
            session.platform = platform
            session.last_seen = now
            session.snapshot = snapshot
            max_seq = session.ack_seq
            if isinstance(raw_logs, list):
                for entry in raw_logs:
                    if not isinstance(entry, dict):
                        continue
                    clean_entry = redact_value(entry)
                    seq = clean_entry.get("seq")
                    if isinstance(seq, int) and seq > max_seq:
                        max_seq = seq
                    clean_entry["clientId"] = client_id
                    self.logs.append(clean_entry)
            session.ack_seq = max_seq
            commands = list(session.pending_commands)
            session.pending_commands.clear()
            return max_seq, commands

    def record_command_result(self, payload: dict[str, Any]) -> None:
        if not isinstance(payload, dict):
            raise ValueError("command-result must be JSON object")
        sanitized_payload = dict(payload)
        raw_result = sanitized_payload.get("result")
        stored_shot: tuple[str, bytes] | None = None
        if isinstance(raw_result, dict) and "pngBase64" in raw_result:
            result_copy = dict(raw_result)
            raw_b64 = result_copy.pop("pngBase64", None)
            if isinstance(raw_b64, str) and raw_b64:
                try:
                    png_bytes = base64.b64decode(raw_b64, validate=False)
                except (binascii.Error, ValueError):
                    result_copy["screenshotDecodeError"] = True
                else:
                    raw_id = str(sanitized_payload.get("id") or "")
                    safe_id = re.sub(r"[^A-Za-z0-9_-]", "", raw_id)[:32]
                    shot_id = safe_id or uuid.uuid4().hex[:12]
                    stored_shot = (shot_id, png_bytes)
                    result_copy["screenshotUrl"] = f"/api/screenshots/{shot_id}.png"
                    result_copy["bytes"] = len(png_bytes)
            sanitized_payload["result"] = result_copy
        clean = redact_value(sanitized_payload)
        if not isinstance(clean, dict):
            raise ValueError("command-result must be JSON object")
        clean["receivedAt"] = time.time()
        with self.lock:
            if stored_shot is not None:
                shot_id, png_bytes = stored_shot
                if shot_id in self.screenshots:
                    self.screenshots.move_to_end(shot_id)
                self.screenshots[shot_id] = png_bytes
                while len(self.screenshots) > 20:
                    self.screenshots.popitem(last=False)
            self.command_results.appendleft(clean)

    def get_screenshot(self, shot_id: str) -> bytes | None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", shot_id):
            return None
        with self.lock:
            return self.screenshots.get(shot_id)

    def record_gateway_trace(
        self,
        *,
        method: str,
        target_host: str,
        path: str,
        query: str,
        status: int,
        fault: str,
        headers: dict[str, str],
    ) -> None:
        clean_query = redact_text(f"?{query}")[1:] if query else ""
        with self.lock:
            self._trace_seq += 1
            self.gateway_count += 1
            self.gateway_traces.append({
                "seq": self._trace_seq,
                "ts": time.time(),
                "method": method,
                "targetHost": redact_text(target_host),
                "path": redact_text(path),
                "query": clean_query,
                "status": status,
                "fault": fault,
                "headers": redact_headers(headers),
            })

    def list_artifacts(self) -> list[dict[str, Any]]:
        if self.artifacts_dir is None or not self.artifacts_dir.exists():
            return []
        items: list[dict[str, Any]] = []
        allowed_ext = {".gif", ".mp4", ".webm", ".png", ".jpg", ".webp"}
        for path in sorted(self.artifacts_dir.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            resolved = path.resolve()
            if not resolved.is_relative_to(self.artifacts_dir):
                continue
            if resolved.suffix.lower() not in allowed_ext:
                continue
            rel = resolved.relative_to(self.artifacts_dir).as_posix()
            items.append({
                "name": rel,
                "size": resolved.stat().st_size,
                "url": f"/artifacts/{urllib.parse.quote(rel)}",
                "ext": resolved.suffix.lower(),
            })
        return items

    def _safe_artifact_root_json(self, filename: str) -> Any | None:
        if self.artifacts_dir is None or not self.artifacts_dir.exists():
            return None
        candidate = self.artifacts_dir / filename
        if candidate.is_symlink() or not candidate.is_file():
            latest = self.artifacts_dir / "latest"
            if latest.is_dir():
                candidate = latest.resolve() / filename
        if not candidate.is_file() or candidate.is_symlink():
            return None
        resolved = candidate.resolve()
        root_res = self.artifacts_dir.resolve()
        if not resolved.is_relative_to(root_res):
            return None
        try:
            return json.loads(resolved.read_text(encoding="utf-8"))
        except Exception:
            return None

    def catalog_manifest_payload(self) -> dict[str, Any]:
        manifest = self._safe_artifact_root_json("manifest.json")
        report = self._safe_artifact_root_json("coverage_report.json")
        prefix = ""
        if self.artifacts_dir is not None and not (self.artifacts_dir / "manifest.json").is_file():
            latest = self.artifacts_dir / "latest"
            if latest.is_dir():
                try:
                    prefix = latest.resolve().relative_to(self.artifacts_dir.resolve()).as_posix().rstrip("/") + "/"
                except ValueError:
                    prefix = ""
        records_out: list[dict[str, Any]] = []
        raw_records = manifest.get("records") if isinstance(manifest, dict) else None
        if isinstance(raw_records, list):
            for rec in raw_records:
                if not isinstance(rec, dict):
                    continue
                copy = dict(rec)
                rel = copy.get("artifact_relpath")
                if isinstance(rel, str) and rel:
                    copy["artifactUrl"] = f"/artifacts/{urllib.parse.quote(prefix + rel)}"
                sheet_rels = copy.get("sheet_relpaths")
                if isinstance(sheet_rels, list) and sheet_rels:
                    copy["sheetUrls"] = [
                        f"/artifacts/{urllib.parse.quote(prefix + s)}"
                        for s in sheet_rels
                        if isinstance(s, str) and s
                    ]
                records_out.append(copy)
        return {
            "hasManifest": isinstance(manifest, dict),
            "runId": manifest.get("run_id") if isinstance(manifest, dict) else None,
            "gitHead": manifest.get("git_head") if isinstance(manifest, dict) else None,
            "generatedAt": manifest.get("generated_at") if isinstance(manifest, dict) else None,
            "records": records_out,
            "report": report,
        }

    def public_state(self, port: int) -> dict[str, Any]:
        now = time.time()
        with self.lock:
            clients_out = [
                {
                    "clientId": c.client_id,
                    "platform": c.platform,
                    "ageSeconds": round(max(0.0, now - c.last_seen), 1),
                    "online": (now - c.last_seen) < 10.0,
                    "pendingCount": len(c.pending_commands),
                    "snapshot": redact_value(c.snapshot),
                }
                for c in self.clients.values()
            ]
            return {
                "server": {
                    "host": "127.0.0.1",
                    "port": port,
                    "loopbackOrigin": f"http://127.0.0.1:{port}",
                    "gatewayCount": self.gateway_count,
                },
                "clients": clients_out,
                "faults": dict(self.faults),
                "logs": list(self.logs)[-150:],
                "traces": list(self.gateway_traces)[-100:],
                "commandResults": list(self.command_results)[:40],
                "artifacts": self.list_artifacts(),
            }


class ParfaitWorkbenchServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(
        self,
        port: int,
        state: WorkbenchState,
        *,
        allow_emulator_host: bool = False,
    ) -> None:
        self.wb_state = state
        self.allow_emulator_host = allow_emulator_host
        super().__init__(("127.0.0.1", port), _WorkbenchHandler)
        self.bound_port = int(self.server_address[1])


class _WorkbenchHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        return  # Keep stdout/stderr clean for tooling; traces live in memory ring.

    @property
    def _wb(self) -> WorkbenchState:
        return self.server.wb_state  # type: ignore[attr-defined]

    @property
    def _port(self) -> int:
        return self.server.bound_port  # type: ignore[attr-defined]

    def _allowed_hosts(self) -> set[str]:
        hosts = {f"127.0.0.1:{self._port}", f"localhost:{self._port}"}
        if self._port == 80:
            hosts.update({"127.0.0.1", "localhost"})
        return hosts

    def _allowed_origins(self) -> set[str]:
        origins = {
            f"http://127.0.0.1:{self._port}",
            f"http://localhost:{self._port}",
        }
        if self._port == 80:
            origins.update({"http://127.0.0.1", "http://localhost"})
        return origins

    def _check_host_and_cors(self) -> bool:
        host = (self.headers.get("Host") or "").strip().lower()
        sec_fetch = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
        origin = (self.headers.get("Origin") or "").strip()
        emulator_hosts = {f"10.0.2.2:{self._port}"}
        if self._port == 80:
            emulator_hosts.add("10.0.2.2")
        if host not in self._allowed_hosts():
            allow_emu = (
                getattr(self.server, "allow_emulator_host", False)
                and host in emulator_hosts
                and not origin
                and not sec_fetch
            )
            if not allow_emu:
                self._send_json(HTTPStatus.FORBIDDEN, {"error": "forbidden host"})
                return False
        if sec_fetch == "cross-site":
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "cross-site request blocked"})
            return False
        if origin and origin not in self._allowed_origins():
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "cross-origin request blocked"})
            return False
        return True

    def _require_control_auth(self) -> bool:
        ctype = (self.headers.get("Content-Type") or "").strip().lower()
        if not ctype.startswith("application/json"):
            self._send_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Content-Type must be application/json"})
            return False
        supplied = (self.headers.get("X-Parfait-Workbench-Token") or "").strip()
        if not supplied or not hmac.compare_digest(supplied, self._wb.token):
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid workbench token"})
            return False
        return True

    def _read_body(self, limit: int = 2 * 1024 * 1024) -> bytes:
        transfer_encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in transfer_encoding:
            buf = bytearray()
            while True:
                line = self.rfile.readline(65536)
                if not line:
                    raise ValueError("unexpected EOF in chunked body")
                size_str = line.split(b";", 1)[0].strip()
                chunk_size = int(size_str, 16)
                if chunk_size < 0:
                    raise ValueError("negative chunk size")
                if chunk_size == 0:
                    while True:
                        trailer = self.rfile.readline(65536)
                        if trailer in (b"\r\n", b"\n", b""):
                            break
                    break
                if len(buf) + chunk_size > limit:
                    raise ValueError("request body too large")
                buf.extend(self.rfile.read(chunk_size))
                eol = self.rfile.readline(4)
                if eol not in (b"\r\n", b"\n"):
                    raise ValueError("malformed chunk terminator")
            return bytes(buf)
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return b""
        if length > limit:
            raise ValueError("request body too large")
        return self.rfile.read(length)

    def _send_security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )

    def _send_bytes(self, status: int, content_type: str, data: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self._send_security_headers()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _send_json(self, status: int, obj: object) -> None:
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", raw)

    def _gateway_target(self, raw_path: str) -> tuple[bool, str, str]:
        header_host = (self.headers.get("X-Parfait-Target-Host") or "").strip().lower()
        if raw_path.startswith("/__pixiv__/"):
            rest = raw_path[len("/__pixiv__/") :]
            if "/" in rest:
                host, subpath = rest.split("/", 1)
                return True, header_host or host.lower(), "/" + subpath
            return True, header_host or rest.lower(), "/"
        if header_host:
            return True, header_host, raw_path
        return False, "", raw_path

    def do_OPTIONS(self) -> None:
        if not self._check_host_and_cors():
            return
        self._send_bytes(HTTPStatus.METHOD_NOT_ALLOWED, "text/plain; charset=utf-8", b"OPTIONS disabled")

    def do_GET(self) -> None:
        if not self._check_host_and_cors():
            return
        split = urllib.parse.urlsplit(self.path)
        is_gw, target_host, gw_path = self._gateway_target(split.path)
        if is_gw:
            self._handle_gateway("GET", target_host, gw_path, split.query, b"")
            return
        if split.path == "/" or split.path == "/index.html":
            raw = (_WEB_DIR / "index.html").read_text(encoding="utf-8")
            injected = raw.replace(
                "{{WORKBENCH_TOKEN}}",
                html.escape(self._wb.token, quote=True),
            )
            self._send_bytes(200, "text/html; charset=utf-8", injected.encode("utf-8"))
            return
        if split.path in ("/app.js", "/app.css"):
            target = _WEB_DIR / split.path.lstrip("/")
            if not target.is_file():
                self._send_json(404, {"error": "asset not found"})
                return
            mime = "application/javascript; charset=utf-8" if split.path.endswith(".js") else "text/css; charset=utf-8"
            self._send_bytes(200, mime, target.read_bytes())
            return
        if split.path == "/api/state":
            self._send_json(200, self._wb.public_state(self._port))
            return
        if split.path == "/api/artifacts":
            self._send_json(200, {"artifacts": self._wb.list_artifacts()})
            return
        if split.path == "/api/catalog-manifest":
            self._send_json(200, self._wb.catalog_manifest_payload())
            return
        if split.path.startswith("/api/screenshots/"):
            name = split.path[len("/api/screenshots/") :]
            if not name.endswith(".png") or "/" in name:
                self._send_json(404, {"error": "screenshot not found"})
                return
            data = self._wb.get_screenshot(name[:-4])
            if data is None:
                self._send_json(404, {"error": "screenshot not found"})
                return
            self._send_bytes(200, "image/png", data)
            return
        if split.path.startswith("/artifacts/"):
            self._serve_artifact(split.path[len("/artifacts/") :])
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if not self._check_host_and_cors():
            return
        split = urllib.parse.urlsplit(self.path)
        is_gw, target_host, gw_path = self._gateway_target(split.path)
        if is_gw:
            try:
                body = self._read_body()
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            self._handle_gateway("POST", target_host, gw_path, split.query, body)
            return

        if split.path not in (
            "/api/commands",
            "/api/command",
            "/api/faults",
            "/api/fault",
            "/api/client/heartbeat",
            "/api/client/command-result",
        ):
            self._send_json(404, {"error": "not found"})
            return

        if not self._require_control_auth():
            return

        try:
            body_limit = (
                16 * 1024 * 1024
                if split.path == "/api/client/command-result"
                else 2 * 1024 * 1024
            )
            body = self._read_body(limit=body_limit)
            payload = json.loads(body.decode("utf-8")) if body else {}
        except Exception as exc:
            self.close_connection = True
            self._send_json(400, {"error": f"invalid json: {exc}"})
            return

        if split.path in ("/api/commands", "/api/command"):
            try:
                client_id, cmd_type, args = validate_command_payload(payload)
                cmd_id = self._wb.enqueue_command(client_id, cmd_type, args)
            except KeyError as exc:
                self._send_json(404, {"error": str(exc)})
                return
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            self._send_json(200, {"ok": True, "id": cmd_id})
            return

        if split.path in ("/api/faults", "/api/fault"):
            try:
                rule = validate_fault_payload(payload)
                faults = self._wb.set_fault(rule)
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            self._send_json(200, {"ok": True, "faults": faults})
            return

        if split.path == "/api/client/heartbeat":
            try:
                ack_seq, commands = self._wb.record_heartbeat(payload)
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            self._send_json(200, {"ok": True, "ackSeq": ack_seq, "commands": commands})
            return

        if split.path == "/api/client/command-result":
            try:
                self._wb.record_command_result(payload)
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            self._send_json(200, {"ok": True})

    def do_PUT(self) -> None:
        self._reject_disallowed_method()

    def do_DELETE(self) -> None:
        self._reject_disallowed_method()

    def _reject_disallowed_method(self) -> None:
        if not self._check_host_and_cors():
            return
        if not self._require_control_auth():
            return
        self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "method not allowed"})

    def _serve_artifact(self, raw_rel: str) -> None:
        root = self._wb.artifacts_dir
        if root is None:
            self._send_json(404, {"error": "artifacts dir not configured"})
            return
        rel = urllib.parse.unquote(raw_rel).lstrip("/")
        candidate = (root / rel).resolve()
        if not candidate.is_relative_to(root) or candidate.is_symlink() or not candidate.is_file():
            self._send_json(403, {"error": "forbidden artifact path"})
            return
        mime, _ = mimetypes.guess_type(str(candidate))
        self._send_bytes(200, mime or "application/octet-stream", candidate.read_bytes())

    def _handle_gateway(
        self,
        method: str,
        target_host: str,
        path: str,
        query: str,
        body: bytes,
    ) -> None:
        fault = self._wb.match_fault(path)
        hdrs = {k: v for k, v in self.headers.items()}
        if fault == "delay_2s":
            time.sleep(2.0)
        elif fault == "offline":
            self._wb.record_gateway_trace(
                method=method,
                target_host=target_host,
                path=path,
                query=query,
                status=0,
                fault=fault,
                headers=hdrs,
            )
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            return
        elif fault == "rate_limit_429":
            status, ctype, resp = (
                429,
                "application/json; charset=utf-8",
                json.dumps({"error": {"message": "429 fault injected", "reason": ""}}).encode("utf-8"),
            )
            self._wb.record_gateway_trace(
                method=method,
                target_host=target_host,
                path=path,
                query=query,
                status=status,
                fault=fault,
                headers=hdrs,
            )
            self._send_bytes(status, ctype, resp)
            return
        elif fault == "server_500":
            status, ctype, resp = (
                500,
                "application/json; charset=utf-8",
                json.dumps({"error": {"message": "500 fault injected", "reason": ""}}).encode("utf-8"),
            )
            self._wb.record_gateway_trace(
                method=method,
                target_host=target_host,
                path=path,
                query=query,
                status=status,
                fault=fault,
                headers=hdrs,
            )
            self._send_bytes(status, ctype, resp)
            return
        elif fault == "empty":
            empty_body = json.dumps({
                "illusts": [],
                "novels": [],
                "user_previews": [],
                "comments": [],
                "spotlight_articles": [],
                "trend_tags": [],
                "next_url": None,
            }).encode("utf-8")
            self._wb.record_gateway_trace(
                method=method,
                target_host=target_host,
                path=path,
                query=query,
                status=200,
                fault=fault,
                headers=hdrs,
            )
            self._send_bytes(200, "application/json; charset=utf-8", empty_body)
            return

        status, ctype, resp = self._wb.pixiv.handle_request(
            method, target_host, path, query, body
        )
        self._wb.record_gateway_trace(
            method=method,
            target_host=target_host,
            path=path,
            query=query,
            status=status,
            fault=fault,
            headers=hdrs,
        )
        self._send_bytes(status, ctype, resp)


def write_state_files(
    port: int,
    token: str,
    state_file: Path,
    *,
    allow_emulator_host: bool = False,
    artifacts_dir: Path | None = None,
) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "host": "127.0.0.1",
        "port": port,
        "url": f"http://127.0.0.1:{port}",
        "token": token,
        "pid": os.getpid(),
        "allow_emulator_host": allow_emulator_host,
        "artifacts_dir": str(artifacts_dir.resolve()) if artifacts_dir else None,
    }
    tmp = state_file.with_suffix(".json.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fp:
        json.dump(payload, fp, indent=2)
    os.replace(tmp, state_file)
    os.chmod(state_file, 0o600)

    token_file = state_file.parent / ".workbench-token"
    tfd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(tfd, "w", encoding="utf-8") as fp:
        fp.write(token)
    os.chmod(token_file, 0o600)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Parfait local Dev Workbench & Loopback Gateway")
    parser.add_argument("--port", type=int, default=18490, help="Loopback TCP port (default 18490)")
    parser.add_argument(
        "--state-file",
        type=Path,
        default=Path(".dart_tool/dev_workbench/session.json"),
        help="0600 JSON session file storing port and workbench token",
    )
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=None,
        help="Optional directory of dynamic recording artifacts for gallery preview",
    )
    parser.add_argument(
        "--allow-emulator-host",
        action="store_true",
        help="Allow non-browser Android AVD QEMU loopback Host 10.0.2.2:<port> while keeping bind 127.0.0.1",
    )
    args = parser.parse_args(argv)

    env_token = os.environ.get("PARFAIT_WORKBENCH_TOKEN", "").strip()
    token = env_token if len(env_token) >= 32 else secrets.token_urlsafe(32)
    state = WorkbenchState(token=token, artifacts_dir=args.artifacts_dir)
    server = ParfaitWorkbenchServer(
        args.port,
        state,
        allow_emulator_host=args.allow_emulator_host,
    )
    write_state_files(
        server.bound_port,
        token,
        args.state_file,
        allow_emulator_host=args.allow_emulator_host,
        artifacts_dir=args.artifacts_dir,
    )

    stop_event = threading.Event()

    def _handle_sig(_sig: int, _frame: Any) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)

    print(
        json.dumps({
            "event": "workbench_ready",
            "url": f"http://127.0.0.1:{server.bound_port}",
            "stateFile": str(args.state_file),
        }),
        flush=True,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
