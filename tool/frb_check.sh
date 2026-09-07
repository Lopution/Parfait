#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

plugin="$root/plugins/rhttp/rhttp"
lock_root="$root/pubspec.lock"
lock_plugin="$plugin/pubspec.lock"
yaml_plugin="$plugin/pubspec.yaml"
generated="$plugin/lib/src/rust/frb_generated.dart"
cargo_toml="$plugin/rust/Cargo.toml"
cargo_lock="$plugin/rust/Cargo.lock"

fail() {
  echo "mismatch: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || fail "$label unparsable (missing $path)"
}

lock_version() {
  local file="$1"
  awk '
    $0 == "  flutter_rust_bridge:" { p = 1; next }
    p && /^  [^ ]/ { exit }
    p && $1 == "version:" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$file"
}

yaml_version() {
  local raw
  raw="$(grep -E '^[[:space:]]*flutter_rust_bridge:[[:space:]]+' "$1" | head -n1 | sed -E 's/^[[:space:]]*flutter_rust_bridge:[[:space:]]+//' | tr -d "\"'")"
  [[ -n "$raw" ]] || return 0
  if [[ "$raw" == ^* ]]; then
    fail "plugin pubspec.yaml must be exact (no ^), got $raw"
  fi
  printf '%s\n' "$raw"
}

codegen_version() {
  sed -n "s/.*codegenVersion => '\\([^']*\\)'.*/\\1/p" "$1" | head -n1
}

cargo_toml_version() {
  sed -n 's/^flutter_rust_bridge *= *{ *version *= *"=\?\([^"]*\)".*/\1/p' "$1" | head -n1
}

cargo_lock_version() {
  awk '
    $0 == "name = \"flutter_rust_bridge\"" { p = 1; next }
    p && $1 == "version" && $2 == "=" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$1"
}

codegen_bin_version() {
  flutter_rust_bridge_codegen --version | awk '{ print $NF }'
}

require_file "$lock_root" "root pubspec.lock"
require_file "$lock_plugin" "plugin pubspec.lock"
require_file "$yaml_plugin" "plugin pubspec.yaml"
require_file "$generated" "frb_generated.dart"
require_file "$cargo_toml" "Cargo.toml"
require_file "$cargo_lock" "Cargo.lock"

v_lock_root="$(lock_version "$lock_root")"
v_lock_plugin="$(lock_version "$lock_plugin")"
v_yaml="$(yaml_version "$yaml_plugin")"
v_codegen="$(codegen_version "$generated")"
v_cargo_toml="$(cargo_toml_version "$cargo_toml")"
v_cargo_lock="$(cargo_lock_version "$cargo_lock")"

[[ -n "$v_lock_root" ]] || fail "root pubspec.lock unparsable"
[[ -n "$v_lock_plugin" ]] || fail "plugin pubspec.lock unparsable"
[[ -n "$v_yaml" ]] || fail "plugin pubspec.yaml unparsable"
[[ -n "$v_codegen" ]] || fail "frb_generated.dart codegenVersion unparsable"
[[ -n "$v_cargo_toml" ]] || fail "Cargo.toml pin unparsable"
[[ -n "$v_cargo_lock" ]] || fail "Cargo.lock unparsable"

echo "root pubspec.lock: $v_lock_root"
echo "plugin pubspec.lock: $v_lock_plugin"
echo "plugin pubspec.yaml: $v_yaml"
echo "codegenVersion: $v_codegen"
echo "Cargo.toml: $v_cargo_toml"
echo "Cargo.lock: $v_cargo_lock"

expected="$v_lock_root"
for pair in \
  "plugin pubspec.lock:$v_lock_plugin" \
  "plugin pubspec.yaml:$v_yaml" \
  "codegenVersion:$v_codegen" \
  "Cargo.toml:$v_cargo_toml" \
  "Cargo.lock:$v_cargo_lock"; do
  label="${pair%%:*}"
  value="${pair#*:}"
  [[ "$value" == "$expected" ]] || fail "$label is $value, expected $expected"
done

if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  v_bin="$(codegen_bin_version)"
  [[ -n "$v_bin" ]] || fail "flutter_rust_bridge_codegen --version unparsable"
  echo "flutter_rust_bridge_codegen: $v_bin"
  [[ "$v_bin" == "$expected" ]] || fail "flutter_rust_bridge_codegen is $v_bin, expected $expected"
else
  echo "codegen binary not found, skipping"
fi

echo "frb triplet OK $expected"
