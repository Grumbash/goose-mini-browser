#!/usr/bin/env bash
# Builds Tusk: the Rust platform layer (../platform) and the Goose program that
# drives it. Needs cargo and a goose compiler built from the pinned commit
# (docs/adr/0001).
set -euo pipefail
cd "$(dirname "$0")"

GOOSE_BIN="${GOOSE_BIN:-goose}"
GOOSE_PIN=cce94b9
if ! "$GOOSE_BIN" --version 2>/dev/null | grep -q "$GOOSE_PIN"; then
  echo "error: need goose at commit $GOOSE_PIN (set GOOSE_BIN=/path/to/goose)" >&2
  exit 1
fi

(cd ../platform && cargo build --release)
cp ../platform/target/release/libtusk_platform.dylib .
"$GOOSE_BIN" build tusk.goose

echo "built app/tusk; run ./app/tusk, or ./app/tusk --wake-test"
