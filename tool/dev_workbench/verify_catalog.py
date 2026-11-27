#!/usr/bin/env python3
"""Static route extraction & finite interactive catalog verifier.

Mechanically parses `lib/app/navigation/routes.dart` and
`lib/app/navigation/route_branches.dart` to extract every syntactic `GoRoute(`
declaration and expand all canonical route templates, then verifies zero
unmapped routes, valid `excluded_surfaces`, valid `not_applicable:<reason>`
justifications, 3-layer shell coverage, and `SC-W1 ~ SC-W5` audit items.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
ROUTES_DART = REPO_ROOT / "lib" / "app" / "navigation" / "routes.dart"
BRANCHES_DART = REPO_ROOT / "lib" / "app" / "navigation" / "route_branches.dart"
DEFAULT_CATALOG_DIR = REPO_ROOT / "tool" / "dev_workbench" / "catalog"

PLATFORMS = ("windows", "android_avd", "linux", "iphone", "ipad", "macos")
SHELL_LAYERS = ("DesktopWindowFrame", "DesktopCommandBar", "DesktopMenuBar", "HomeBranchStack")
AUDIT_CANDIDATES = ("SC-W1", "SC-W2", "SC-W3", "SC-W4", "SC-W5")
REQUIRED_OS_BOUNDARY_CATEGORIES = (
    "os_intent_and_share",
    "os_real_storage_and_downloads",
    "os_desktop_window_lifecycle",
    "os_clipboard_and_drop",
    "os_cold_restart_persistence",
    "os_external_links_and_oauth_callback",
)
VALID_OS_STEP_TYPES = frozenset({
    "adb_intent",
    "write_clipboard",
    "cold_restart",
})
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
_ADJ_SINGLE_STR_RE = re.compile(r"(?<!\\)'(?:\s*//[^\n]*)*\s*'")
_ADJ_DOUBLE_STR_RE = re.compile(r'(?<!\\)"(?:\s*//[^\n]*)*\s*"')
_DART_TEST_DECL_RE = re.compile(
    r"""\b(?:test|testWidgets|testE2e|testGoldens)\s*\(\s*(?:'([^'\n]+)'|"([^"\n]+)")"""
)
EXCLUDED_CATEGORIES = frozenset({
    "external_auth_captcha",
    "os_native_picker_or_share",
    "external_browser_handoff",
    "alias_redirect",
    "desktop_os_chrome_outside_frame",
})
VALID_ACTION_TYPES = frozenset({
    "tap",
    "click",
    "double_click",
    "right_click",
    "long_press",
    "context_action",
    "hover",
    "drag",
    "swipe",
    "scroll",
    "key",
    "type_text",
    "navigate",
    "history",
    "fault",
    "resize_window",
    "wait_ms",
    "assert_route",
})


@dataclasses.dataclass(frozen=True)
class ExtractedRoute:
    file: str
    line: int
    raw_path: str
    canonical_template: str


def _strip_comments_and_strings_keep_literals(source: str) -> str:
    """Return source with `//` comments replaced by spaces, preserving newlines."""
    out: list[str] = []
    i = 0
    n = len(source)
    in_str: str | None = None
    while i < n:
        ch = source[i]
        if in_str is not None:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch in ("'", '"'):
            in_str = ch
        out.append(ch)
        i += 1
    return "".join(out)


def _find_matching(text: str, open_idx: int, open_ch: str = "(", close_ch: str = ")") -> int:
    depth = 0
    i = open_idx
    n = len(text)
    in_str: str | None = None
    while i < n:
        ch = text[i]
        if in_str is not None:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_str = ch
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError(f"Unbalanced {open_ch!r} starting at offset {open_idx}")


def _split_top_level_elements(list_body: str) -> list[str]:
    items: list[str] = []
    cur: list[str] = []
    depth_paren = 0
    depth_brack = 0
    depth_brace = 0
    in_str: str | None = None
    i = 0
    while i < len(list_body):
        ch = list_body[i]
        if in_str is not None:
            cur.append(ch)
            if ch == "\\" and i + 1 < len(list_body):
                cur.append(list_body[i + 1])
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_str = ch
            cur.append(ch)
        elif ch == "(":
            depth_paren += 1
            cur.append(ch)
        elif ch == ")":
            depth_paren -= 1
            cur.append(ch)
        elif ch == "[":
            depth_brack += 1
            cur.append(ch)
        elif ch == "]":
            depth_brack -= 1
            cur.append(ch)
        elif ch == "{":
            depth_brace += 1
            cur.append(ch)
        elif ch == "}":
            depth_brace -= 1
            cur.append(ch)
        elif ch == "," and depth_paren == 0 and depth_brack == 0 and depth_brace == 0:
            elem = "".join(cur).strip()
            if elem:
                items.append(elem)
            cur = []
        else:
            cur.append(ch)
        i += 1
    tail = "".join(cur).strip()
    if tail:
        items.append(tail)
    return items


def _find_top_level_named_arg(call_body: str, arg_name: str) -> str | None:
    """Return the RHS expression of top-level `arg_name: <expr>` in *call_body*."""
    depth_paren = 0
    depth_brack = 0
    depth_brace = 0
    in_str: str | None = None
    i = 0
    n = len(call_body)
    target = f"{arg_name}:"
    while i < n:
        ch = call_body[i]
        if in_str is not None:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_str = ch
            i += 1
            continue
        if depth_paren == 0 and depth_brack == 0 and depth_brace == 0:
            prev_ok = i == 0 or not (call_body[i - 1].isalnum() or call_body[i - 1] == "_")
            if prev_ok and call_body.startswith(target, i):
                val_start = i + len(target)
                while val_start < n and call_body[val_start].isspace():
                    val_start += 1
                # Scan until top-level comma or end
                j = val_start
                dp = db = dc = 0
                s: str | None = None
                while j < n:
                    c2 = call_body[j]
                    if s is not None:
                        if c2 == "\\" and j + 1 < n:
                            j += 2
                            continue
                        if c2 == s:
                            s = None
                        j += 1
                        continue
                    if c2 in ("'", '"'):
                        s = c2
                    elif c2 == "(":
                        dp += 1
                    elif c2 == ")":
                        dp -= 1
                    elif c2 == "[":
                        db += 1
                    elif c2 == "]":
                        db -= 1
                    elif c2 == "{":
                        dc += 1
                    elif c2 == "}":
                        dc -= 1
                    elif c2 == "," and dp == 0 and db == 0 and dc == 0:
                        break
                    j += 1
                return call_body[val_start:j].strip()
        if ch == "(":
            depth_paren += 1
        elif ch == ")":
            depth_paren -= 1
        elif ch == "[":
            depth_brack += 1
        elif ch == "]":
            depth_brack -= 1
        elif ch == "{":
            depth_brace += 1
        elif ch == "}":
            depth_brace -= 1
        i += 1
    return None


def _join_route(parent: str, child: str) -> str:
    if child.startswith("/"):
        return child
    base = parent.rstrip("/")
    return f"{base}/{child}" if base else f"/{child}"


def _extract_list_literal_goroutes(
    list_expr: str,
    prefix: str,
    file_label: str,
    base_offset: int,
    full_source: str,
    seen_offsets: set[tuple[str, int]],
) -> list[ExtractedRoute]:
    out: list[ExtractedRoute] = []
    trimmed = list_expr.strip()
    if not trimmed.startswith("[") or not trimmed.endswith("]"):
        return out
    inner = trimmed[1:-1]
    inner_offset = base_offset + list_expr.find("[") + 1
    pos = 0
    for elem in _split_top_level_elements(inner):
        elem_idx = inner.find(elem, pos)
        elem_abs = inner_offset + max(0, elem_idx)
        pos = max(0, elem_idx) + len(elem)
        if re.match(r"^GoRoute\s*\(", elem):
            seen_offsets.add((file_label, elem_abs))
            open_idx = elem.find("(")
            close_idx = _find_matching(elem, open_idx)
            body = elem[open_idx + 1 : close_idx]
            path_expr = _find_top_level_named_arg(body, "path") or ""
            m_lit = re.match(r"^'([^']*)'$", path_expr)
            if not m_lit:
                raise ValueError(f"Unsupported non-literal path {path_expr!r} in {file_label}")
            raw_path = m_lit.group(1)
            full_path = _join_route(prefix, raw_path.replace("${prefix}", ""))
            line = full_source[:elem_abs].count("\n") + 1
            out.append(ExtractedRoute(file_label, line, raw_path, full_path))
            nested = _find_top_level_named_arg(body, "routes")
            if nested:
                nested_idx = body.find(nested)
                nested_abs = elem_abs + open_idx + 1 + max(0, nested_idx)
                out.extend(
                    _extract_list_literal_goroutes(
                        nested,
                        full_path,
                        file_label,
                        nested_abs,
                        full_source,
                        seen_offsets,
                    )
                )
    return out


def _extract_fn_return_list(clean_src: str, fn_name: str) -> tuple[str, int]:
    m = re.search(rf"\b(?:List<RouteBase>|GoRoute)\s+{re.escape(fn_name)}\s*\(", clean_src)
    if not m:
        raise ValueError(f"Function {fn_name} not found")
    # Find function block `{` after parameter list
    paren_end = _find_matching(clean_src, m.end() - 1)
    brace_start = clean_src.find("{", paren_end)
    brace_end = _find_matching(clean_src, brace_start, "{", "}")
    fn_body = clean_src[brace_start : brace_end + 1]
    rm = re.search(r"\b(?:final\s+routes\s*=\s*<RouteBase>|return)\s*\[", fn_body)
    if not rm:
        raise ValueError(f"Route list not found in {fn_name}")
    list_start = brace_start + rm.end() - 1
    list_end = _find_matching(clean_src, list_start, "[", "]")
    return clean_src[list_start : list_end + 1], list_start


def extract_all_routes(
    routes_path: Path = ROUTES_DART,
    branches_path: Path = BRANCHES_DART,
) -> tuple[int, list[ExtractedRoute]]:
    """Extract syntactic `GoRoute(` count and expanded canonical route templates."""
    routes_raw = routes_path.read_text(encoding="utf-8")
    branches_raw = branches_path.read_text(encoding="utf-8")
    routes_clean = _strip_comments_and_strings_keep_literals(routes_raw)
    branches_clean = _strip_comments_and_strings_keep_literals(branches_raw)

    routes_matches = [m.start() for m in re.finditer(r"\bGoRoute\s*\(", routes_clean)]
    branches_matches = [m.start() for m in re.finditer(r"\bGoRoute\s*\(", branches_clean)]
    syntactic_goroute_count = len(routes_matches) + len(branches_matches)
    seen_offsets: set[tuple[str, int]] = set()

    extracted: list[ExtractedRoute] = []

    # 1. Extract GoRouter(routes: [ ... ]) direct GoRoute entries & overlays & shell branches
    gm = re.search(r"\bGoRouter\s*\(", routes_clean)
    if not gm:
        raise ValueError("GoRouter( not found in routes.dart")
    g_open = routes_clean.find("(", gm.start())
    g_close = _find_matching(routes_clean, g_open)
    g_body = routes_clean[g_open + 1 : g_close]
    top_routes_expr = _find_top_level_named_arg(g_body, "routes")
    if not top_routes_expr:
        raise ValueError("GoRouter.routes not found in routes.dart")
    top_abs = g_open + 1 + g_body.find(top_routes_expr)
    top_inner = top_routes_expr[1:-1]
    top_inner_abs = top_abs + 1

    shell_branch_paths: list[str] = []
    pos = 0
    for elem in _split_top_level_elements(top_inner):
        idx = top_inner.find(elem, pos)
        elem_abs = top_inner_abs + max(0, idx)
        pos = max(0, idx) + len(elem)
        if re.match(r"^GoRoute\s*\(", elem):
            extracted.extend(
                _extract_list_literal_goroutes(
                    f"[{elem}]",
                    "",
                    "lib/app/navigation/routes.dart",
                    elem_abs - 1,
                    routes_clean,
                    seen_offsets,
                )
            )
        elif re.match(r"^_overlayRoute\s*\(", elem):
            pm = re.match(r"^_overlayRoute\s*\(\s*'([^']+)'", elem)
            if not pm:
                raise ValueError(f"Failed to parse _overlayRoute call: {elem[:60]}")
            ov_path = pm.group(1)
            line = routes_clean[:elem_abs].count("\n") + 1
            extracted.append(ExtractedRoute("lib/app/navigation/routes.dart", line, ov_path, ov_path))
        elif re.match(r"^StatefulShellRoute\s*\(", elem):
            s_open = elem.find("(")
            s_close = _find_matching(elem, s_open)
            s_body = elem[s_open + 1 : s_close]
            branches_expr = _find_top_level_named_arg(s_body, "branches")
            if not branches_expr:
                raise ValueError("StatefulShellRoute.branches not found")
            for b_elem in _split_top_level_elements(branches_expr.strip()[1:-1]):
                b_open = b_elem.find("(")
                b_close = _find_matching(b_elem, b_open)
                b_body = b_elem[b_open + 1 : b_close]
                p_expr = _find_top_level_named_arg(b_body, "path") or ""
                pm = re.match(r"^'([^']+)'$", p_expr)
                if not pm:
                    raise ValueError(f"Unsupported branch path {p_expr!r}")
                b_path = pm.group(1)
                shell_branch_paths.append(b_path)
                b_abs = elem_abs + s_open + 1 + max(0, s_body.find(b_elem))
                line = routes_clean[:b_abs].count("\n") + 1
                extracted.append(ExtractedRoute("lib/app/navigation/routes.dart", line, b_path, b_path))

    # Account for the 2 wrapper factory `GoRoute(` declarations inside `_overlayRoute` & `_branch`
    for fn_name in ("_overlayRoute", "_branch"):
        fm = re.search(rf"\b(?:GoRoute|StatefulShellBranch)\s+{fn_name}\s*\(", branches_clean)
        if fm:
            gm_inner = re.search(r"\bGoRoute\s*\(", branches_clean[fm.start():])
            if gm_inner:
                seen_offsets.add(("lib/app/navigation/route_branches.dart", fm.start() + gm_inner.start()))

    # 2. _searchRoutes under /search
    search_list, search_abs = _extract_fn_return_list(branches_clean, "_searchRoutes")
    extracted.extend(
        _extract_list_literal_goroutes(
            search_list,
            "/search",
            "lib/app/navigation/route_branches.dart",
            search_abs,
            branches_clean,
            seen_offsets,
        )
    )

    # 3. _commonBranchRoutes canonically represented under first home branch (/recommended)
    common_list, common_abs = _extract_fn_return_list(branches_clean, "_commonBranchRoutes")
    canonical_branch_base = shell_branch_paths[0] if shell_branch_paths else "/recommended"
    extracted.extend(
        _extract_list_literal_goroutes(
            common_list,
            canonical_branch_base,
            "lib/app/navigation/route_branches.dart",
            common_abs,
            branches_clean,
            seen_offsets,
        )
    )
    common_fn_m = re.search(r"if\s*\(includeAppPages\)\s*\{.*?routes\.addAll\s*\(\s*(\[.*?\])\s*\)", branches_clean, re.DOTALL)
    if common_fn_m:
        app_pages_expr = common_fn_m.group(1)
        app_pages_abs = common_fn_m.start(1)
        extracted.extend(
            _extract_list_literal_goroutes(
                app_pages_expr,
                canonical_branch_base,
                "lib/app/navigation/route_branches.dart",
                app_pages_abs,
                branches_clean,
                seen_offsets,
            )
        )

    # 4. _settingsSubRoutes under /settings
    settings_list, settings_abs = _extract_fn_return_list(branches_clean, "_settingsSubRoutes")
    extracted.extend(
        _extract_list_literal_goroutes(
            settings_list,
            "/settings",
            "lib/app/navigation/route_branches.dart",
            settings_abs,
            branches_clean,
            seen_offsets,
        )
    )

    if len(seen_offsets) != syntactic_goroute_count:
        all_offsets = {
            ("lib/app/navigation/routes.dart", o) for o in routes_matches
        } | {
            ("lib/app/navigation/route_branches.dart", o) for o in branches_matches
        }
        unparsed = sorted(all_offsets - seen_offsets)
        details = [
            f"{fn}:{ (routes_clean if fn.endswith('routes.dart') else branches_clean)[:off].count(chr(10)) + 1 }"
            for fn, off in unparsed
        ]
        raise ValueError(
            f"Syntactic GoRoute( mismatch: traversed {len(seen_offsets)}/{syntactic_goroute_count}; unparsed={details}"
        )

    return syntactic_goroute_count, extracted


def _extract_dart_test_names(path: Path) -> set[str]:
    raw = path.read_text(encoding="utf-8")
    joined = _ADJ_SINGLE_STR_RE.sub("", raw)
    joined = _ADJ_DOUBLE_STR_RE.sub("", joined)
    joined = joined.replace("\\'", "'").replace('\\"', '"')
    return {
        m.group(1) if m.group(1) is not None else m.group(2)
        for m in _DART_TEST_DECL_RE.finditer(joined)
    }


def _verify_os_e2e_and_completeness_matrix(
    catalog_dir: Path,
    repo_root: Path,
    errors: list[str],
) -> dict[str, Any]:
    """Verify `os_e2e_flows.json` and 3D `completeness_matrix.json` when present."""
    stats: dict[str, Any] = {
        "os_e2e_flows": 0,
        "os_e2e_assertions": 0,
        "in_app_journeys": 0,
        "seam_invariants": 0,
        "os_boundary_categories": [],
    }
    os_file = catalog_dir / "os_e2e_flows.json"
    matrix_file = catalog_dir / "completeness_matrix.json"
    if not os_file.is_file():
        errors.append(f"Missing OS E2E flows file: {os_file}")
        return stats
    if not matrix_file.is_file():
        errors.append(f"Missing 3D completeness matrix file: {matrix_file}")
        return stats

    os_data = json.loads(os_file.read_text(encoding="utf-8"))
    flows = os_data.get("flows")
    if not isinstance(flows, list) or not flows:
        errors.append("os_e2e_flows.json must contain a non-empty 'flows' list")
        flows = []

    flow_ids: set[str] = set()
    assertion_ids: set[str] = set()
    flow_categories: dict[str, set[str]] = {}
    flow_assertions_by_cat: dict[str, set[str]] = {}
    all_step_types = VALID_ACTION_TYPES | VALID_OS_STEP_TYPES

    for idx, flow in enumerate(flows):
        if not isinstance(flow, dict):
            errors.append(f"os_e2e_flows.flows[{idx}] must be an object")
            continue
        fid = flow.get("id")
        if not isinstance(fid, str) or not fid.strip():
            errors.append(f"os_e2e_flows.flows[{idx}] missing non-empty string 'id'")
            continue
        if fid in flow_ids:
            errors.append(f"Duplicate OS E2E flow id: {fid}")
            continue
        flow_ids.add(fid)

        cat = flow.get("category")
        if cat not in REQUIRED_OS_BOUNDARY_CATEGORIES:
            errors.append(f"{fid}: invalid OS boundary category {cat!r}")
        else:
            flow_categories.setdefault(cat, set()).add(fid)

        plats = flow.get("platforms")
        if not isinstance(plats, dict) or set(plats.keys()) != set(PLATFORMS):
            errors.append(f"{fid}: platforms must define exactly {list(PLATFORMS)}")
        else:
            has_required = False
            for p_name, p_val in plats.items():
                if p_val == "required":
                    has_required = True
                elif isinstance(p_val, str) and p_val.startswith("not_applicable:") and p_val.split(":", 1)[1].strip():
                    continue
                else:
                    errors.append(f"{fid}: invalid platform rule {p_name}={p_val!r}")
            if not has_required:
                errors.append(f"{fid}: must have at least one 'required' platform")

        steps = flow.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append(f"{fid}: steps must be a non-empty list")
        else:
            for s_idx, step in enumerate(steps):
                if not isinstance(step, dict) or step.get("type") not in all_step_types:
                    errors.append(f"{fid}: invalid step at index {s_idx}: {step!r}")

        assertions = flow.get("assertions")
        if not isinstance(assertions, list) or not assertions:
            errors.append(f"{fid}: assertions must be a non-empty list")
        else:
            for a_idx, spec in enumerate(assertions):
                if not isinstance(spec, dict):
                    errors.append(f"{fid}: assertion[{a_idx}] must be an object")
                    continue
                aid = spec.get("id")
                atype = spec.get("type")
                if not isinstance(aid, str) or not aid.strip():
                    errors.append(f"{fid}: assertion[{a_idx}] missing non-empty 'id'")
                    continue
                if aid in assertion_ids:
                    errors.append(f"Duplicate OS E2E assertion id: {aid}")
                    continue
                if atype not in VALID_ASSERTION_TYPES:
                    errors.append(f"{fid}: assertion {aid!r} has unknown type {atype!r}")
                    continue
                assertion_ids.add(aid)
                if isinstance(cat, str):
                    flow_assertions_by_cat.setdefault(cat, set()).add(aid)

    for req_cat in REQUIRED_OS_BOUNDARY_CATEGORIES:
        if req_cat not in flow_categories:
            errors.append(f"os_e2e_flows.json missing required OS boundary category: {req_cat}")

    # Validate 3D completeness_matrix.json
    matrix = json.loads(matrix_file.read_text(encoding="utf-8"))
    dart_cache: dict[str, set[str]] = {}

    def _check_dart_entries(section: str, min_count: int) -> int:
        entries = matrix.get(section)
        if not isinstance(entries, list) or len(entries) < min_count:
            errors.append(f"completeness_matrix.{section} must have at least {min_count} entries")
            return 0
        seen_ids: set[str] = set()
        for idx, entry in enumerate(entries):
            if not isinstance(entry, dict):
                errors.append(f"completeness_matrix.{section}[{idx}] must be an object")
                continue
            eid = entry.get("id")
            if not isinstance(eid, str) or not eid.strip() or eid in seen_ids:
                errors.append(f"completeness_matrix.{section}[{idx}] invalid or duplicate id {eid!r}")
                continue
            seen_ids.add(eid)
            rel_file = entry.get("file")
            test_name = entry.get("test_name")
            if not isinstance(rel_file, str) or not isinstance(test_name, str) or not test_name.strip():
                errors.append(f"completeness_matrix.{section}.{eid}: missing file or test_name")
                continue
            target_file = repo_root / rel_file
            if not target_file.is_file():
                errors.append(f"completeness_matrix.{section}.{eid}: missing test file {rel_file!r}")
                continue
            if rel_file not in dart_cache:
                dart_cache[rel_file] = _extract_dart_test_names(target_file)
            if test_name not in dart_cache[rel_file]:
                errors.append(
                    f"completeness_matrix.{section}.{eid}: test {test_name!r} not declared in {rel_file!r}"
                )
        return len(seen_ids)

    journeys_count = _check_dart_entries("in_app_journeys", 9)
    seams_count = _check_dart_entries("seam_invariants", 4)

    os_cats = matrix.get("os_boundary_categories")
    seen_matrix_cats: set[str] = set()
    if not isinstance(os_cats, list) or not os_cats:
        errors.append("completeness_matrix.os_boundary_categories must be a non-empty list")
    else:
        for idx, entry in enumerate(os_cats):
            if not isinstance(entry, dict):
                errors.append(f"completeness_matrix.os_boundary_categories[{idx}] must be an object")
                continue
            cat = entry.get("category")
            if cat not in REQUIRED_OS_BOUNDARY_CATEGORIES:
                errors.append(f"completeness_matrix.os_boundary_categories[{idx}]: unknown category {cat!r}")
                continue
            seen_matrix_cats.add(cat)
            fids = entry.get("flow_ids") or []
            aids = entry.get("assertion_ids") or []
            if not fids or not aids:
                errors.append(f"completeness_matrix.os_boundary_categories.{cat}: needs flow_ids and assertion_ids")
                continue
            for fid in fids:
                if fid not in flow_categories.get(cat, set()):
                    errors.append(
                        f"completeness_matrix.os_boundary_categories.{cat}: flow {fid!r} not in os_e2e_flows.json"
                    )
            for aid in aids:
                if aid not in flow_assertions_by_cat.get(cat, set()):
                    errors.append(
                        f"completeness_matrix.os_boundary_categories.{cat}: assertion {aid!r} not in os_e2e_flows.json"
                    )
    for req_cat in REQUIRED_OS_BOUNDARY_CATEGORIES:
        if req_cat not in seen_matrix_cats:
            errors.append(f"completeness_matrix.os_boundary_categories missing required category: {req_cat}")

    stats.update({
        "os_e2e_flows": len(flow_ids),
        "os_e2e_assertions": len(assertion_ids),
        "in_app_journeys": journeys_count,
        "seam_invariants": seams_count,
        "os_boundary_categories": sorted(seen_matrix_cats),
    })
    return stats


def verify_catalog(
    catalog_dir: Path = DEFAULT_CATALOG_DIR,
    *,
    routes_path: Path = ROUTES_DART,
    branches_path: Path = BRANCHES_DART,
    repo_root: Path = REPO_ROOT,
) -> tuple[bool, list[str], dict[str, Any]]:
    errors: list[str] = []
    catalog_file = catalog_dir / "catalog.json"
    map_file = catalog_dir / "route_coverage_map.json"

    if not catalog_file.is_file():
        return False, [f"Missing catalog file: {catalog_file}"], {}
    if not map_file.is_file():
        return False, [f"Missing route coverage map: {map_file}"], {}

    catalog_data = json.loads(catalog_file.read_text(encoding="utf-8"))
    map_data = json.loads(map_file.read_text(encoding="utf-8"))

    syntactic_count, extracted = extract_all_routes(routes_path, branches_path)
    source_templates = [r.canonical_template for r in extracted]
    if len(source_templates) != len(set(source_templates)):
        dups = [t for t in set(source_templates) if source_templates.count(t) > 1]
        errors.append(f"Duplicate canonical templates extracted from source: {sorted(dups)}")
    source_set = set(source_templates)

    # Validate catalog items
    items = catalog_data.get("items")
    if not isinstance(items, list) or not items:
        errors.append("catalog.json must contain a non-empty 'items' list")
        items = []

    items_by_id: dict[str, dict[str, Any]] = {}
    covered_shells: set[str] = set()
    covered_audits: set[str] = set()
    directions_seen: set[str] = set()

    for idx, item in enumerate(items):
        if not isinstance(item, dict):
            errors.append(f"catalog.items[{idx}] must be an object")
            continue
        cid = item.get("id")
        if not isinstance(cid, str) or not cid.strip():
            errors.append(f"catalog.items[{idx}] missing non-empty string 'id'")
            continue
        if cid in items_by_id:
            errors.append(f"Duplicate catalog id: {cid}")
            continue
        items_by_id[cid] = item

        for req_field in ("module", "direction", "route", "target", "actions", "states", "format", "platforms"):
            if req_field not in item:
                errors.append(f"{cid}: missing required field '{req_field}'")

        direction = item.get("direction")
        if direction not in ("one_way", "two_way"):
            errors.append(f"{cid}: direction must be 'one_way' or 'two_way', got {direction!r}")
        else:
            directions_seen.add(direction)

        fmt = item.get("format")
        if fmt not in ("gif", "mp4"):
            errors.append(f"{cid}: format must be 'gif' or 'mp4', got {fmt!r}")

        route_tmpl = item.get("route_template")
        if not isinstance(route_tmpl, str) or not route_tmpl:
            errors.append(f"{cid}: missing required non-empty route_template")
        elif route_tmpl not in source_set:
            errors.append(f"{cid}: route_template {route_tmpl!r} is not in source routes")

        shell_layer = item.get("shell_layer")
        if isinstance(shell_layer, str):
            if shell_layer not in SHELL_LAYERS:
                errors.append(f"{cid}: invalid shell_layer {shell_layer!r}")
            else:
                covered_shells.add(shell_layer)

        audit = item.get("audit_candidate")
        if isinstance(audit, str):
            if audit not in AUDIT_CANDIDATES:
                errors.append(f"{cid}: unknown audit_candidate {audit!r}")
            else:
                covered_audits.add(audit)

        actions = item.get("actions")
        if not isinstance(actions, list) or not actions:
            errors.append(f"{cid}: actions must be a non-empty list")
        else:
            for step_idx, step in enumerate(actions):
                if not isinstance(step, dict) or step.get("type") not in VALID_ACTION_TYPES:
                    errors.append(f"{cid}: invalid action step at index {step_idx}: {step!r}")

        states = item.get("states")
        if not isinstance(states, list) or not states:
            errors.append(f"{cid}: states must be a non-empty list")

        plats = item.get("platforms")
        if not isinstance(plats, dict):
            errors.append(f"{cid}: platforms must be an object")
        else:
            if set(plats.keys()) != set(PLATFORMS):
                errors.append(
                    f"{cid}: platforms must define exactly {list(PLATFORMS)}, got {sorted(plats.keys())}"
                )
            for p_name, p_val in plats.items():
                if p_val == "required":
                    continue
                if isinstance(p_val, str) and (
                    p_val.startswith("not_applicable:") or p_val.startswith("foreground_opt_in:")
                ):
                    reason = p_val.split(":", 1)[1].strip()
                    if not reason:
                        errors.append(f"{cid}: {p_name} has empty justification: {p_val!r}")
                    if p_val.startswith("foreground_opt_in:") and p_name != "windows":
                        errors.append(f"{cid}: foreground_opt_in is only valid on windows, not {p_name}")
                    continue
                errors.append(
                    f"{cid}: {p_name} invalid matrix value {p_val!r} "
                    "(must be 'required', 'foreground_opt_in:<reason>', or 'not_applicable:<reason>')"
                )

    for layer in SHELL_LAYERS:
        if layer not in covered_shells:
            errors.append(f"Shell layer missing from catalog items: {layer}")
    for candidate in AUDIT_CANDIDATES:
        if candidate not in covered_audits:
            errors.append(f"Audit candidate missing from catalog items: {candidate}")
    if directions_seen != {"one_way", "two_way"}:
        errors.append("Catalog must include both 'one_way' and 'two_way' interactions")

    # Validate route_coverage_map.json
    canonical_map = map_data.get("canonical_routes")
    if not isinstance(canonical_map, dict):
        errors.append("route_coverage_map.json must contain 'canonical_routes' dict")
        canonical_map = {}

    map_keys = set(canonical_map.keys())
    missing_from_map = sorted(source_set - map_keys)
    stale_in_map = sorted(map_keys - source_set)
    if missing_from_map:
        errors.append(f"Routes in source missing from route_coverage_map.json: {missing_from_map}")
    if stale_in_map:
        errors.append(f"Stale routes in route_coverage_map.json absent from source: {stale_in_map}")

    referenced_ids: set[str] = set()
    for tmpl, mapping in sorted(canonical_map.items()):
        if not isinstance(mapping, dict):
            errors.append(f"Mapping for {tmpl!r} must be a dict")
            continue
        cids = mapping.get("catalog_ids")
        excl = mapping.get("excluded")
        if cids is not None:
            if not isinstance(cids, list) or not cids:
                errors.append(f"Route {tmpl!r} catalog_ids must be a non-empty list")
            else:
                for ref_id in cids:
                    if ref_id not in items_by_id:
                        errors.append(f"Route {tmpl!r} references unknown catalog id {ref_id!r}")
                    else:
                        referenced_ids.add(ref_id)
                        item_rt = items_by_id[ref_id].get("route_template")
                        if item_rt != tmpl:
                            errors.append(
                                f"Route {tmpl!r} maps {ref_id!r}, whose route_template is {item_rt!r}"
                            )
        elif excl is not None:
            if not isinstance(excl, str) or excl not in EXCLUDED_CATEGORIES:
                errors.append(f"Route {tmpl!r} invalid excluded category {excl!r}")
            reason = mapping.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                errors.append(f"Excluded route {tmpl!r} requires a non-empty reason")
        else:
            errors.append(f"Route {tmpl!r} must define either 'catalog_ids' or 'excluded'")

    unreferenced_items = sorted(set(items_by_id.keys()) - referenced_ids)
    if unreferenced_items:
        errors.append(f"Catalog items not referenced in route_coverage_map.json: {unreferenced_items}")

    excluded_surfaces = map_data.get("excluded_surfaces")
    if not isinstance(excluded_surfaces, list) or not excluded_surfaces:
        errors.append("route_coverage_map.json must declare non-empty 'excluded_surfaces'")
    else:
        seen_cats: set[str] = set()
        for idx, surf in enumerate(excluded_surfaces):
            if not isinstance(surf, dict):
                errors.append(f"excluded_surfaces[{idx}] must be a dict")
                continue
            cat = surf.get("category")
            if cat not in EXCLUDED_CATEGORIES:
                errors.append(f"excluded_surfaces[{idx}] invalid category {cat!r}")
            else:
                seen_cats.add(cat)
            if not isinstance(surf.get("reason"), str) or not surf["reason"].strip():
                errors.append(f"excluded_surfaces[{idx}] missing non-empty reason")
        for req_cat in (
            "external_auth_captcha",
            "os_native_picker_or_share",
            "external_browser_handoff",
            "desktop_os_chrome_outside_frame",
        ):
            if req_cat not in seen_cats:
                errors.append(f"excluded_surfaces missing required boundary category: {req_cat}")

    matrix_stats = _verify_os_e2e_and_completeness_matrix(catalog_dir, repo_root, errors)

    summary = {
        "syntactic_goroutes": syntactic_count,
        "canonical_routes": len(source_set),
        "catalog_items": len(items_by_id),
        "covered_shells": sorted(covered_shells),
        "covered_audit_candidates": sorted(covered_audits),
        "excluded_routes": [k for k, v in canonical_map.items() if isinstance(v, dict) and "excluded" in v],
        "excluded_surfaces_count": len(excluded_surfaces) if isinstance(excluded_surfaces, list) else 0,
        **matrix_stats,
    }
    return len(errors) == 0, errors, summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify finite interactive catalog completeness.")
    parser.add_argument("--catalog-dir", type=Path, default=DEFAULT_CATALOG_DIR)
    parser.add_argument("--dump-routes", action="store_true", help="Print extracted routes and exit 0")
    parser.add_argument("--json", action="store_true", help="Output summary JSON")
    args = parser.parse_args(argv)

    if args.dump_routes:
        count, routes = extract_all_routes()
        print(f"Syntactic GoRoute( count: {count}")
        print(f"Canonical route templates ({len(routes)}):")
        for r in routes:
            print(f"  {r.canonical_template:45s} <- {r.file}:{r.line}")
        return 0

    ok, errors, summary = verify_catalog(args.catalog_dir)
    if args.json:
        print(json.dumps({"ok": ok, "errors": errors, "summary": summary}, ensure_ascii=False, indent=2))
    else:
        if ok:
            print(
                f"OK: {summary['syntactic_goroutes']} syntactic GoRoute( calls -> "
                f"{summary['canonical_routes']} canonical templates mapped cleanly to "
                f"{summary['catalog_items']} catalog items "
                f"(shells={summary['covered_shells']}, audits={summary['covered_audit_candidates']}, "
                f"excluded_routes={summary['excluded_routes']}, excluded_surfaces={summary['excluded_surfaces_count']}); "
                f"3D matrix: {summary['in_app_journeys']} journeys, {summary['seam_invariants']} seams, "
                f"{len(summary['os_boundary_categories'])} OS categories "
                f"({summary['os_e2e_flows']} flows / {summary['os_e2e_assertions']} assertions)."
            )
        else:
            print("FAILED catalog verification:", file=sys.stderr)
            for err in errors:
                print(f"  - {err}", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
