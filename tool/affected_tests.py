#!/usr/bin/env python3
"""Select Flutter test files affected by a set of changed repo paths.

Replaces grep-based direct-import matching in `tool/gate.sh` with a full
Dart `import` / `export` / `part` / `part of` reverse-dependency graph plus
explicit non-Dart asset and subdirectory `flutter_test_config.dart` triggers.

Usage:
  python3 tool/affected_tests.py --base REF [--json] [--include-architecture]
  python3 tool/affected_tests.py --changed-list FILE [--json] [--include-architecture]
  python3 tool/affected_tests.py --files PATH ... [--json] [--include-architecture]
  python3 tool/affected_tests.py --self-test

Plain stdout format:
  - `WHOLE_SUITE:<reason>` when a global trigger changed (dependencies,
    `analysis_options.yaml`, root `test/flutter_test_config.dart`).
  - `SKIP_DART` when no Dart, l10n, asset, or test-fixture file changed.
  - Otherwise, one repo-relative `test/**/*_test.dart` path per line.
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from collections import defaultdict, deque
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DIRECTIVE_STMT_RE = re.compile(
    r"""^\s*(import|export|part\s+of|part)\s+([^;]+);""",
    re.MULTILINE,
)
QUOTED_URI_RE = re.compile(r"""['"]([^'"]+)['"]""")
PACKAGE_NAME_RE = re.compile(r"^name:\s*(\S+)", re.MULTILINE)
FIXTURE_REF_RE = re.compile(r"""['"](test/fixtures/[^'"]+)['"]""")

WHOLE_SUITE_FILES = frozenset({
    "pubspec.yaml",
    "pubspec.lock",
    "analysis_options.yaml",
    "dart_test.yaml",
    "l10n.yaml",
    "test/flutter_test_config.dart",
})

ARB_TESTS = (
    "test/architecture/l10n_and_errors_test.dart",
)
ICON_FONT_TESTS = (
    "test/icon_font_test.dart",
    "test/architecture/ui_conventions_test.dart",
)
SPEC_BACKTICK_RE = re.compile(r"`([^`\n]+)`")


def _glob_to_regex(glob: str) -> re.Pattern[str]:
    out = ""
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif glob.startswith("**", i):
            out += ".*"
            i += 2
        elif glob[i] == "*":
            out += "[^/]*"
            i += 1
        elif glob[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return re.compile(out)


def _code_token_matches(token: str, path: str) -> bool:
    clean = token.lstrip("./").rstrip("/")
    if not clean:
        return False
    if "*" in clean or "?" in clean:
        return bool(_glob_to_regex(clean).fullmatch(path))
    return path == clean or path.startswith(clean + "/")


def spec_check_tests_for(repo: Path, changed_paths: list[str], existing: set[str]) -> set[str]:
    """Return `test/**/*_test.dart` files anchored on spec rules whose Code: covers changed_paths."""
    lib_changed = [p for p in changed_paths if p.startswith("lib/")]
    if not lib_changed:
        return set()
    spec_root = repo / ".trellis" / "spec"
    if not spec_root.is_dir():
        return set()

    selected: set[str] = set()
    for md in sorted(spec_root.rglob("*.md")):
        if md.name == "index.md":
            continue
        lines = md.read_text(encoding="utf-8", errors="ignore").splitlines()
        cur_check = ""
        cur_code = ""
        active: str | None = None
        fenced = False

        def flush_rule() -> None:
            nonlocal cur_check, cur_code, active
            if cur_check and cur_code:
                code_tokens = SPEC_BACKTICK_RE.findall(cur_code)
                if any(
                    _code_token_matches(tok, ch)
                    for tok in code_tokens
                    for ch in lib_changed
                ):
                    for tok in SPEC_BACKTICK_RE.findall(cur_check):
                        t = tok.lstrip("./").rstrip("/")
                        if t.startswith("test/") and t.endswith("_test.dart") and t in existing:
                            selected.add(t)
            cur_check = ""
            cur_code = ""
            active = None

        for line in lines:
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if fenced:
                continue
            if line.startswith("### ") or line.startswith("## "):
                flush_rule()
                continue
            if line.startswith("- **Check:**"):
                active = "Check"
                cur_check = line[len("- **Check:**"):].strip()
            elif line.startswith("- **Code:**"):
                active = "Code"
                cur_code = line[len("- **Code:**"):].strip()
            elif line.startswith("- **"):
                active = None
            elif active == "Check" and line.startswith("  "):
                cur_check += " " + line.strip()
            elif active == "Code" and line.startswith("  "):
                cur_code += " " + line.strip()
            else:
                active = None
        flush_rule()
    return selected


def read_package_name(repo: Path) -> str:
    pubspec = repo / "pubspec.yaml"
    if not pubspec.is_file():
        raise RuntimeError(f"missing {pubspec}")
    match = PACKAGE_NAME_RE.search(pubspec.read_text(encoding="utf-8"))
    if not match:
        raise RuntimeError(f"cannot find package name in {pubspec}")
    return match.group(1)


def resolve_dart_uri(from_file: str, uri: str, pkg: str) -> str | None:
    prefix = f"package:{pkg}/"
    if uri.startswith(prefix):
        return posixpath.normpath("lib/" + uri[len(prefix):])
    if uri.startswith(("package:", "dart:")):
        return None
    base = posixpath.dirname(from_file)
    resolved = posixpath.normpath(posixpath.join(base, uri))
    if resolved.startswith("../") or resolved == "..":
        return None
    return resolved


def discover_dart_files(repo: Path) -> list[str]:
    files: list[str] = []
    for top in ("lib", "test"):
        root = repo / top
        if not root.is_dir():
            continue
        for path in root.rglob("*.dart"):
            rel = path.relative_to(repo).as_posix()
            files.append(rel)
    files.sort()
    return files


def build_reverse_graph(
    repo: Path,
    pkg: str,
    dart_files: list[str],
) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Return `(rev_graph, fixture_refs)`.

    `rev_graph[target]` holds every Dart file that depends on `target` via
    `import`, `export`, or bidirectional `part` / `part of`.
    `fixture_refs[fixture_path]` holds every Dart file under `test/` whose
    source mentions that `test/fixtures/...` literal.
    """
    rev: dict[str, set[str]] = defaultdict(set)
    fixture_refs: dict[str, set[str]] = defaultdict(set)

    for rel in dart_files:
        text = (repo / rel).read_text(encoding="utf-8", errors="ignore")
        for match in DIRECTIVE_STMT_RE.finditer(text):
            kind = " ".join(match.group(1).split())
            body = match.group(2)
            # Capture primary URI and any conditional `if (...) 'alt.dart'` URIs.
            uris = QUOTED_URI_RE.findall(body)
            if kind in ("part", "part of"):
                uris = uris[:1]
            for uri in uris:
                target = resolve_dart_uri(rel, uri, pkg)
                if target is None:
                    continue
                if kind in ("import", "export"):
                    # Keep edge even if target was deleted so tests importing a
                    # deleted file are still selected.
                    rev[target].add(rel)
                elif kind in ("part", "part of"):
                    # Parts and their owning library share one compilation unit:
                    # editing any part marks the owning library (and every sibling
                    # part and importer) dirty.
                    rev[target].add(rel)
                    rev[rel].add(target)

        if rel.startswith("test/"):
            for fmatch in FIXTURE_REF_RE.finditer(text):
                fixture_refs[fmatch.group(1)].add(rel)
            if "lib/l10n/" in text:
                fixture_refs["__l10n_arb__"].add(rel)

    return rev, fixture_refs


def is_dart_or_asset_path(path: str) -> bool:
    if path in WHOLE_SUITE_FILES or path == "l10n.yaml":
        return True
    if path.endswith(".dart") and (path.startswith("lib/") or path.startswith("test/")):
        return True
    if path.startswith("lib/l10n/") and path.endswith(".arb"):
        return True
    if path.startswith("assets/") or path.startswith("test/fixtures/"):
        return True
    return False


def select_affected(
    repo: Path,
    changed: list[str],
    *,
    include_architecture: bool = False,
) -> dict:
    clean_changed = sorted({p.strip().replace("\\", "/") for p in changed if p.strip()})

    for path in clean_changed:
        if path in WHOLE_SUITE_FILES:
            return {
                "mode": "whole_suite",
                "reason": f"{path} changed",
                "run_dart_checks": True,
                "tests": [],
            }

    run_dart_checks = any(is_dart_or_asset_path(p) for p in clean_changed)
    if not run_dart_checks:
        return {
            "mode": "skip_dart",
            "reason": "no Dart, l10n, asset, or test fixture files changed",
            "run_dart_checks": False,
            "tests": [],
        }

    pkg = read_package_name(repo)
    dart_files = discover_dart_files(repo)
    existing = set(dart_files)
    all_tests = [f for f in dart_files if f.startswith("test/") and f.endswith("_test.dart")]
    arch_tests = [f for f in all_tests if f.startswith("test/architecture/")]
    rev, fixture_refs = build_reverse_graph(repo, pkg, dart_files)

    seeds: set[str] = set()
    direct_tests: set[str] = set()

    for path in clean_changed:
        if path.endswith(".dart") and (path.startswith("lib/") or path.startswith("test/")):
            seeds.add(path)
            if path.startswith("test/") and path.endswith("/flutter_test_config.dart"):
                subdir = posixpath.dirname(path) + "/"
                for t in all_tests:
                    if t.startswith(subdir):
                        direct_tests.add(t)
        elif path.startswith("lib/l10n/") and path.endswith(".arb"):
            for candidate in ARB_TESTS:
                if candidate in existing:
                    direct_tests.add(candidate)
            seeds.update(fixture_refs.get("__l10n_arb__", ()))
        elif path == "assets/icon.ttf":
            for candidate in ICON_FONT_TESTS:
                if candidate in existing:
                    direct_tests.add(candidate)
        elif path.startswith("test/fixtures/"):
            seeds.update(fixture_refs.get(path, ()))

    visited: set[str] = set(seeds)
    queue: deque[str] = deque(seeds)
    while queue:
        node = queue.popleft()
        for parent in rev.get(node, ()):
            if parent not in visited:
                visited.add(parent)
                queue.append(parent)

    selected = {
        f for f in visited
        if f.startswith("test/") and f.endswith("_test.dart") and f in existing
    }
    selected.update(t for t in direct_tests if t in existing)
    selected.update(spec_check_tests_for(repo, clean_changed, existing))
    if include_architecture:
        selected.update(arch_tests)

    return {
        "mode": "selected",
        "reason": "",
        "run_dart_checks": True,
        "tests": sorted(selected),
    }


def git_changed_files(repo: Path, base: str) -> list[str]:
    merge_base = subprocess.run(
        ["git", "merge-base", "HEAD", base],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    cmds = [
        ["git", "diff", "--name-only", "-z", f"{merge_base}...HEAD"],
        ["git", "diff", "--name-only", "-z", "HEAD"],
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
    ]
    paths: set[str] = set()
    for cmd in cmds:
        out = subprocess.run(cmd, cwd=repo, check=True, capture_output=True, text=True).stdout
        for entry in out.split("\0"):
            if entry:
                paths.add(entry)
    return sorted(paths)


def _write(root: Path, rel: str, content: str) -> None:
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="affected-tests-") as tmp:
        root = Path(tmp)
        _write(root, "pubspec.yaml", "name: demo\n")
        _write(root, "lib/core/leaf.dart", "const leaf = 1;\n")
        _write(root, "lib/core/leaf_io.dart", "const leaf = 2;\n")
        _write(
            root,
            "lib/core/barrel.dart",
            "export 'leaf.dart' if (dart.library.io) 'leaf_io.dart';\n",
        )
        _write(
            root,
            "lib/feature/parent.dart",
            "import '../core/barrel.dart';\npart 'part_a.dart';\npart 'part_b.dart';\n",
        )
        _write(root, "lib/feature/part_a.dart", "part of 'parent.dart';\n")
        _write(root, "lib/feature/part_b.dart", "part of 'parent.dart';\n")
        _write(root, "lib/unrelated.dart", "const x = 0;\n")

        _write(root, "test/helpers/world.dart", "import 'package:demo/feature/parent.dart';\n")
        _write(root, "test/feature_test.dart", "import 'helpers/world.dart';\n")
        _write(root, "test/deleted_ref_test.dart", "import 'package:demo/core/gone.dart';\n")
        _write(root, "test/unrelated_test.dart", "import 'package:demo/unrelated.dart';\n")
        _write(root, "test/sub/flutter_test_config.dart", "// sub config\n")
        _write(root, "test/sub/sub_a_test.dart", "// sub a\n")
        _write(root, "test/sub/sub_b_test.dart", "// sub b\n")
        _write(root, "test/architecture/l10n_and_errors_test.dart", "// arb+font check\n")
        _write(root, "test/architecture/ui_conventions_test.dart", "// ui check\n")
        _write(root, "test/icon_font_test.dart", "// icon font\n")
        _write(
            root,
            "test/fixture_consumer_test.dart",
            "final s = File('test/fixtures/sample/page.html');\n",
        )

        # 1. Transitive export (including conditional `if (...)` URI) + helper hop
        res = select_affected(root, ["lib/core/leaf.dart"])
        assert res["mode"] == "selected", res
        assert res["tests"] == ["test/feature_test.dart"], res
        res = select_affected(root, ["lib/core/leaf_io.dart"])
        assert res["tests"] == ["test/feature_test.dart"], res

        # 2. Bidirectional part-of propagation
        res = select_affected(root, ["lib/feature/part_a.dart"])
        assert res["tests"] == ["test/feature_test.dart"], res

        # 3. Deleted lib file still selects importing test
        res = select_affected(root, ["lib/core/gone.dart"])
        assert res["tests"] == ["test/deleted_ref_test.dart"], res

        # 4. Global whole-suite triggers
        for trigger in ("pubspec.yaml", "dart_test.yaml", "l10n.yaml", "test/flutter_test_config.dart"):
            res = select_affected(root, [trigger])
            assert res["mode"] == "whole_suite", (trigger, res)

        # 5. Subdir flutter_test_config.dart selects only that subdir
        res = select_affected(root, ["test/sub/flutter_test_config.dart"])
        assert res["tests"] == ["test/sub/sub_a_test.dart", "test/sub/sub_b_test.dart"], res

        # 6. Non-Dart assets (.arb, icon.ttf, fixtures)
        res = select_affected(root, ["lib/l10n/app_en.arb"])
        assert res["tests"] == ["test/architecture/l10n_and_errors_test.dart"], res
        res = select_affected(root, ["assets/icon.ttf"])
        assert set(res["tests"]) == {
            "test/architecture/ui_conventions_test.dart",
            "test/icon_font_test.dart",
        }, res
        res = select_affected(root, ["test/fixtures/sample/page.html"])
        assert res["tests"] == ["test/fixture_consumer_test.dart"], res

        # 7. Pure docs/workflow change skips Dart checks and runs 0 tests
        res = select_affected(root, ["README.md", ".github/workflows/ci.yml", ".trellis/spec/a.md"])
        assert res["mode"] == "skip_dart" and not res["run_dart_checks"] and res["tests"] == [], res

        # 8. include_architecture appends architecture tests for Dart changes only
        res = select_affected(root, ["lib/unrelated.dart"], include_architecture=True)
        assert set(res["tests"]) == {
            "test/architecture/l10n_and_errors_test.dart",
            "test/architecture/ui_conventions_test.dart",
            "test/unrelated_test.dart",
        }, res

        # 9. Spec rule Code: -> Check: selects indirect spec-anchored test files
        _write(root, "test/spec_e2e_test.dart", "// no direct import of unrelated.dart\n")
        _write(
            root,
            ".trellis/spec/frontend/demo.md",
            "---\nprefix: DEMO\napplies_to:\n  - lib/**\nreviewed: 2026-11-28\n---\n"
            "### DEMO-01 Indirect contract\n"
            "- **Rule:** Demo.\n"
            "- **Why:** Demo.\n"
            "- **Check:** `test/spec_e2e_test.dart` \"indirect\"\n"
            "- **Code:** `lib/unrelated.dart`\n",
        )
        res = select_affected(root, ["lib/unrelated.dart"])
        assert set(res["tests"]) == {
            "test/unrelated_test.dart",
            "test/spec_e2e_test.dart",
        }, res

    print("affected_tests self-test passed (9/9 scenarios)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="git ref to diff against (uses merge-base with HEAD)")
    parser.add_argument("--changed-list", type=Path, help="file containing newline-separated repo-relative paths")
    parser.add_argument("--files", nargs="*", help="explicit repo-relative changed paths")
    parser.add_argument("--include-architecture", action="store_true", help="include test/architecture/*_test.dart when Dart/assets changed")
    parser.add_argument("--json", action="store_true", help="output JSON summary")
    parser.add_argument("--self-test", action="store_true", help="run unit self-tests in a temporary workspace")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    changed: list[str] = []
    if args.changed_list is not None:
        changed.extend(args.changed_list.read_text(encoding="utf-8").splitlines())
    if args.files:
        changed.extend(args.files)
    if args.base:
        changed.extend(git_changed_files(REPO, args.base))
    if not (args.changed_list or args.files or args.base):
        parser.error("provide --base, --changed-list, --files, or --self-test")

    result = select_affected(REPO, changed, include_architecture=args.include_architecture)
    if args.json:
        print(json.dumps(result))
    elif result["mode"] == "whole_suite":
        print(f"WHOLE_SUITE:{result['reason']}")
    elif result["mode"] == "skip_dart":
        print("SKIP_DART")
    else:
        for path in result["tests"]:
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
