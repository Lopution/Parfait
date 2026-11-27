"""Declarative assertion engine for Dev Workbench OS-level E2E flows."""

from __future__ import annotations

import dataclasses
from pathlib import Path
from typing import Any, Callable

VALID_ASSERTION_TYPES = frozenset({
    "zero_uncaught_errors",
    "process_alive",
    "route_equals",
    "route_prefix",
    "element_visible",
    "element_absent",
    "snapshot_field",
    "clipboard_equals",
    "file_exists",
})


@dataclasses.dataclass(frozen=True)
class AssertionResult:
    id: str
    type: str
    passed: bool
    detail: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "passed": self.passed,
            "detail": self.detail,
        }


def _lookup_dot_path(data: dict[str, Any], path: str) -> tuple[bool, Any]:
    cur: Any = data
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return False, None
    return True, cur


def evaluate_assertion(
    spec: dict[str, Any],
    *,
    snapshot: dict[str, Any],
    baseline_error_count: int = 0,
    process_alive: bool = True,
    process_exit_code: int | None = None,
    find_bounds: Callable[[str, str], dict[str, Any]] | None = None,
    read_clipboard: Callable[[], str | None] | None = None,
    check_file: Callable[[str], dict[str, Any]] | None = None,
    dev_root: Path | None = None,
) -> AssertionResult:
    """Evaluate one declarative assertion against live process state & snapshot."""
    aid = str(spec.get("id") or "unnamed")
    atype = str(spec.get("type") or "")

    if atype not in VALID_ASSERTION_TYPES:
        return AssertionResult(aid, atype, False, f"unknown assertion type: {atype!r}")

    if atype == "zero_uncaught_errors":
        err_block = snapshot.get("errors") if isinstance(snapshot.get("errors"), dict) else {}
        cur_count = int(err_block.get("count", 0) or 0)
        delta = cur_count - baseline_error_count
        if delta <= 0:
            return AssertionResult(aid, atype, True, f"errors={cur_count} (delta={delta})")
        recent = err_block.get("recent") or []
        return AssertionResult(
            aid,
            atype,
            False,
            f"uncaught errors increased by {delta} (total={cur_count}, recent={recent[-3:]})",
        )

    if atype == "process_alive":
        expected = bool(spec.get("expected", True))
        if expected:
            return AssertionResult(
                aid,
                atype,
                process_alive,
                "process alive" if process_alive else f"process exited unexpectedly (rc={process_exit_code})",
            )
        clean_rc = spec.get("expected_exit_code")
        if process_alive:
            return AssertionResult(aid, atype, False, "expected process exit, but still alive")
        if clean_rc is not None and process_exit_code != int(clean_rc):
            return AssertionResult(
                aid,
                atype,
                False,
                f"exited with rc={process_exit_code}, expected {clean_rc}",
            )
        return AssertionResult(aid, atype, True, f"process exited cleanly (rc={process_exit_code})")

    if atype == "route_equals":
        actual = str(snapshot.get("route") or "")
        expected = str(spec.get("expected") or "")
        ok = actual == expected
        return AssertionResult(aid, atype, ok, f"route={actual!r}, expected={expected!r}")

    if atype == "route_prefix":
        actual = str(snapshot.get("route") or "")
        prefix = str(spec.get("prefix") or "")
        ok = actual.startswith(prefix)
        return AssertionResult(aid, atype, ok, f"route={actual!r}, prefix={prefix!r}")

    if atype in ("element_visible", "element_absent"):
        if find_bounds is None:
            return AssertionResult(aid, atype, False, "find_bounds callback not provided")
        kind = str(spec.get("kind") or "text")
        query = str(spec.get("query") or "")
        res = find_bounds(kind, query)
        found = bool(res.get("found"))
        want = atype == "element_visible"
        ok = found == want
        return AssertionResult(
            aid,
            atype,
            ok,
            f"locator ({kind}={query!r}) found={found}, expected={want}",
        )

    if atype == "snapshot_field":
        field = str(spec.get("field") or "")
        exists, val = _lookup_dot_path(snapshot, field)
        if not exists:
            return AssertionResult(aid, atype, False, f"field {field!r} absent in snapshot")
        if "equals" in spec:
            ok = val == spec["equals"]
            return AssertionResult(aid, atype, ok, f"{field}={val!r}, expected={spec['equals']!r}")
        if "not_equals" in spec:
            ok = val != spec["not_equals"]
            return AssertionResult(aid, atype, ok, f"{field}={val!r}, not_equals={spec['not_equals']!r}")
        if spec.get("not_null"):
            ok = val is not None and val != ""
            return AssertionResult(aid, atype, ok, f"{field}={val!r}, expected non-empty")
        if "gte" in spec:
            try:
                ok = float(val) >= float(spec["gte"])
            except (TypeError, ValueError):
                ok = False
            return AssertionResult(aid, atype, ok, f"{field}={val!r}, expected >= {spec['gte']!r}")
        if "contains" in spec:
            ok = str(spec["contains"]) in str(val)
            return AssertionResult(aid, atype, ok, f"{field}={val!r}, expected contains {spec['contains']!r}")
        return AssertionResult(aid, atype, False, f"{field}: no comparator specified")

    if atype == "clipboard_equals":
        if read_clipboard is None:
            return AssertionResult(aid, atype, False, "read_clipboard callback not provided")
        actual = read_clipboard()
        expected = str(spec.get("expected") or "")
        ok = actual == expected
        return AssertionResult(aid, atype, ok, f"clipboard={actual!r}, expected={expected!r}")

    if atype == "file_exists":
        rel = str(spec.get("rel_path") or "")
        min_bytes = int(spec.get("min_bytes", 1))
        if check_file is not None:
            res = check_file(rel)
            exists = bool(res.get("exists"))
            size = int(res.get("bytes", 0) or 0)
            ok = exists and size >= min_bytes
            return AssertionResult(
                aid,
                atype,
                ok,
                f"checkFile({rel!r}) exists={exists} bytes={size} (min={min_bytes})",
            )
        if dev_root is not None:
            target = (dev_root / rel).resolve()
            if not target.is_relative_to(dev_root.resolve()):
                return AssertionResult(aid, atype, False, f"rel_path escapes dev_root: {rel!r}")
            exists = target.is_file()
            size = target.stat().st_size if exists else 0
            ok = exists and size >= min_bytes
            return AssertionResult(
                aid,
                atype,
                ok,
                f"file({rel!r}) exists={exists} bytes={size} (min={min_bytes})",
            )
        return AssertionResult(aid, atype, False, "neither check_file nor dev_root provided")

    return AssertionResult(aid, atype, False, "unhandled assertion type")


def evaluate_assertions(
    specs: list[dict[str, Any]],
    **kwargs: Any,
) -> tuple[bool, list[AssertionResult]]:
    results = [evaluate_assertion(spec, **kwargs) for spec in specs]
    return all(r.passed for r in results), results
