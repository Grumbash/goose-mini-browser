#!/usr/bin/env bash
# Builds goosenet (Rust) and mini_browser (Goose), and wires them together.
# Needs: cargo/rustc, and a `goose` compiler on PATH or at $GOOSE_BIN
# (see README.md for how to build goose itself).
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building goosenet (Rust cdylib)"
(cd goosenet && cargo build --release)

case "$(uname -s)" in
  Linux)  EXT=so ;;
  Darwin) EXT=dylib ;;
  *)      EXT=dll ;;
esac

if [ "$EXT" = "dll" ]; then
  rm -f browser/goosenet.dll
  cp goosenet/target/release/goosenet.dll browser/
else
  # rm then cp, not cp -f: overwriting a mapped dylib's bytes in place while
  # keeping its inode makes the kernel's code-signing cache compare the new
  # content against a signature taken for the old one and SIGKILL any
  # process that maps it (cs_invalid_page). A fresh inode avoids that.
  rm -f "browser/libgoosenet.$EXT"
  cp "goosenet/target/release/libgoosenet.$EXT" browser/
  if [ "$EXT" = "dylib" ] && command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "browser/libgoosenet.$EXT" 2>/dev/null || true
  fi
fi

GOOSE_BIN="${GOOSE_BIN:-goose}"
if ! command -v "$GOOSE_BIN" >/dev/null 2>&1; then
  echo "error: no '$GOOSE_BIN' on PATH. Build it (see README.md #prerequisites)" \
       "or set GOOSE_BIN=/path/to/goose" >&2
  exit 1
fi

echo "==> Building mini_browser (Goose, AOT -- threads need a real C compiler)"
(cd browser && "$GOOSE_BIN" build mini_browser.goose)

echo "==> Done: browser/mini_browser"
echo "    ./browser/mini_browser \"https://example.com/\""
