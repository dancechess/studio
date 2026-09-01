#!/usr/bin/env bash
# Builds the Rust core and (re)generates the Swift bindings.
# Run standalone, or as an Xcode "Run Script" build phase (see project.yml).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
CORE="$ROOT/core"
GEN="$ROOT/app/Generated"

# Xcode injects a SDKROOT for the app target that breaks cargo's host build.
env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET \
  cargo build --manifest-path "$CORE/Cargo.toml" $([ "$CONFIG" = release ] && echo --release)

mkdir -p "$GEN"
# uniffi-bindgen looks up crate metadata from the cwd
(cd "$CORE" && env -u SDKROOT \
  cargo run --bin uniffi-bindgen -- \
  generate --library "$CORE/target/$CONFIG/libdancechess_core.dylib" \
  --language swift --out-dir "$GEN")

# Xcode wants a modulemap named module.modulemap inside an include dir
mkdir -p "$GEN/include"
mv -f "$GEN"/dancechess_coreFFI.h "$GEN/include/"
mv -f "$GEN"/dancechess_coreFFI.modulemap "$GEN/include/module.modulemap" 2>/dev/null || true

# the SPM dev harness consumes the same header through its C target
mkdir -p "$ROOT/app/FFI/include"
cp -f "$GEN/include/dancechess_coreFFI.h" "$ROOT/app/FFI/include/"

echo "core built: $CORE/target/$CONFIG/libdancechess_core.a"
echo "bindings:   $GEN/dancechess_core.swift"
