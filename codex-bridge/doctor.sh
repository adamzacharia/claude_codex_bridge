#!/usr/bin/env bash
# doctor.sh — validate the whole Claude ↔ Codex toolchain for FREE, before any
# paid model call. Run this as the first setup step and whenever a bridge call
# fails mysteriously.
#
#   bash codex-bridge/doctor.sh           # all free checks
#   bash codex-bridge/doctor.sh --paid    # + one real (cheap) codex smoke call
#
# Exit code: 0 if no FAIL, 1 otherwise (WARNs don't fail the doctor).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PAID=0
[ "${1:-}" = "--paid" ] && PAID=1

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

VER="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo '?')"
echo "codex-bridge doctor (kit version $VER)"
echo "---------------------------------------"

# bash
if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  pass "bash ${BASH_VERSION}"
else
  warn "bash ${BASH_VERSION:-unknown} — bash >= 4 recommended (arrays/expansions in the kit assume it)"
fi

# git repo
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  pass "inside a git repository ($(git rev-parse --show-toplevel))"
else
  fail "not inside a git repository — codex_loop.sh requires one"
fi

# codex CLI
if command -v codex >/dev/null 2>&1; then
  pass "codex CLI: $(codex --version 2>/dev/null | head -1)"

  if codex login status >/dev/null 2>&1; then
    pass "codex login: $(codex login status 2>&1 | head -1)"
  else
    fail "codex is not logged in — run: codex login"
  fi

  if codex exec --help 2>/dev/null | grep -q -- '--json'; then
    pass "codex exec supports --json (robust session-id/token/error parsing)"
  else
    warn "codex exec lacks --json — the kit falls back to log-scraping (upgrade codex for reliability)"
  fi
else
  fail "codex CLI not found — install it and run: codex login"
fi

# codex config
CODEX_CFG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CFG" ]; then
  pass "codex config exists: $CODEX_CFG"
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if grep -Eq '^\s*sandbox\s*=\s*"unelevated"' "$CODEX_CFG" 2>/dev/null; then
        pass 'windows sandbox = "unelevated" configured'
      else
        warn 'Windows: add [windows] sandbox = "unelevated" to ~/.codex/config.toml — "elevated" fails with CreateProcessWithLogonW error 2 (see SETUP.md)'
      fi
      ;;
  esac
else
  warn "no $CODEX_CFG — codex will use defaults (see SETUP.md for the recommended settings)"
fi

# claude CLI (needed for --auto duels, --claude-review, and headless turns)
if command -v claude >/dev/null 2>&1; then
  pass "claude CLI: $(claude --version 2>/dev/null | head -1)"
else
  warn "claude CLI not found — --auto duels and --claude-review will not work"
fi

# python (JSONL fallbacks, claude token accounting, UUID minting)
if command -v python >/dev/null 2>&1 || command -v py >/dev/null 2>&1; then
  pass "python available (claude token capture + JSONL recovery enabled)"
else
  warn "python not found — interactive-Claude token capture and some JSONL recovery paths are disabled"
fi

# runtime dir writable
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if mkdir -p "$ROOT/tmp/codex" 2>/dev/null && [ -w "$ROOT/tmp/codex" ]; then
  pass "runtime dir writable: $ROOT/tmp/codex"
else
  fail "cannot create/write $ROOT/tmp/codex"
fi

# kit files present together
MISSING=""
for f in codex_bridge.sh codex_loop.sh usage_lib.sh duel_lib.sh; do
  [ -f "$SCRIPT_DIR/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass "kit scripts present next to each other"
else
  fail "missing kit files:$MISSING (the scripts must stay together)"
fi

if [ "$PAID" -eq 1 ]; then
  echo "--- paid smoke test (one small codex call) ---"
  if printf 'Reply only: BRIDGE_OK\n' | bash "$SCRIPT_DIR/codex_bridge.sh" consult; then
    pass "codex bridge round-trip"
  else
    fail "codex bridge smoke test failed — see output above"
  fi
fi

echo "---------------------------------------"
if [ "$FAILS" -eq 0 ]; then
  echo "doctor: all checks passed (warnings above, if any, are non-fatal)"
  exit 0
else
  echo "doctor: $FAILS check(s) FAILED"
  exit 1
fi
