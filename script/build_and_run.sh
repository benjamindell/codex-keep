#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
Packaging/make_app.sh
pkill -x CodexKeep >/dev/null 2>&1 || true
APP_BUNDLE="$ROOT_DIR/.build/release/Codex Keep.app"
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/CodexKeep" ;;
  --logs|--telemetry)
    open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "CodexKeep"'
    ;;
  --verify)
    open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x CodexKeep >/dev/null
    ;;
  run) open -n "$APP_BUNDLE" ;;
esac
