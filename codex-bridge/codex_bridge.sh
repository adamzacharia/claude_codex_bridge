#!/usr/bin/env bash
# codex_bridge.sh — drive Codex headlessly so Claude Code can run a genuine,
# multi-round consult <-> implement <-> review discussion with zero manual
# copy-paste. Codex shares its own ideas/critiques back in every reply.
#
# Portable: drop this folder into any repo (it has no project-specific paths).
#
# Usage (prompt comes from stdin):
#   bash codex-bridge/codex_bridge.sh consult < plan.md            # read-only second opinion (new thread)
#   bash codex-bridge/codex_bridge.sh build   < spec.md            # Codex edits files (workspace-write, new thread)
#   bash codex-bridge/codex_bridge.sh consult --resume < reply.md  # CONTINUE the last thread (Codex remembers)
#   bash codex-bridge/codex_bridge.sh build   --resume < reply.md  # continue the thread and let it edit
#   bash codex-bridge/codex_bridge.sh build   --full   < spec.md   # workspace-write + network/full access
#
# Model/effort/speed are taken from the environment (so codex_loop.sh can pass
# them through; override per-call by exporting before invoking):
#   CODEX_MODEL           (default gpt-5.5)
#   CODEX_EFFORT          (default xhigh)   -> -c model_reasoning_effort=<effort>
#   CODEX_FAST            (default unset)   -> when non-empty, -c service_tier=priority
#   CODEX_TIMEOUT_SECS    (default 0 = none) kill a hung codex call after N seconds
#   CODEX_HEARTBEAT_SECS  (default 30)      progress line cadence during long calls
#   CODEX_BRIDGE_NO_JSON  (default unset)   set to force the legacy log-scrape path
#
# --resume keeps the conversation going: Codex recalls the previous rounds, so
# Claude can react to Codex's ideas and Codex can build on Claude's, both ways.
#
# Output: the agent's FINAL message prints to stdout (and $CODEX_BRIDGE_DIR/
# last_message.md); the machine-readable event stream goes to $CODEX_BRIDGE_DIR/
# run.jsonl and the human log to run.log, so neither floods the caller.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Token accounting + JSONL parsing helpers (best-effort; never fatal).
# shellcheck source=usage_lib.sh
. "$SELF_DIR/usage_lib.sh" 2>/dev/null || true

MODE="${1:-}"; shift || true
case "$MODE" in
  consult) SANDBOX="read-only" ;;
  build)   SANDBOX="workspace-write" ;;
  *) echo "usage: codex_bridge.sh <consult|build> [--resume] [--full] < prompt" >&2; exit 2 ;;
esac

RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) RESUME=1; shift ;;
    --full)   SANDBOX="danger-full-access"; shift ;;
    *) break ;;
  esac
done

DIR="${CODEX_BRIDGE_DIR:-tmp/codex}"
mkdir -p "$DIR"
LAST="$DIR/last_message.md"
LOG="$DIR/run.log"
JSONL="$DIR/run.jsonl"
PROMPT_FILE="$DIR/prompt.md"
: > "$LAST"
: > "$LOG"
rm -f "$JSONL" 2>/dev/null || true

MODEL="${CODEX_MODEL:-gpt-5.5}"
EFFORT="${CODEX_EFFORT:-xhigh}"
FAST_ARGS=()
[ -n "${CODEX_FAST:-}" ] && FAST_ARGS=(-c service_tier="priority")

# Capture the prompt to a file so the exact text is auditable afterwards and
# the backgrounded codex child never depends on inherited-stdin subtleties.
cat > "$PROMPT_FILE"
if [ ! -s "$PROMPT_FILE" ]; then
  echo "codex_bridge: empty prompt on stdin" >&2
  exit 2
fi

# Prefer the machine-readable event stream over scraping human logs: --json
# gives us thread.started (exact resume id), turn.completed (real token usage),
# and turn.failed (typed errors). Feature-detect so older CLIs still work.
JSON_OK=1
[ -n "${CODEX_BRIDGE_NO_JSON:-}" ] && JSON_OK=0
if [ "$JSON_OK" -eq 1 ] && ! codex exec --help 2>/dev/null | grep -q -- '--json'; then
  JSON_OK=0
fi

# windows.sandbox=unelevated: the "elevated" mode needs a logon-user setup that
# isn't provisioned on this box (CreateProcessWithLogonW fails), so Codex can't
# run verification commands; "unelevated" (restricted token + network) works.
# (On non-Windows hosts this -c override is simply ignored.)
# NOTE: `codex exec` (fresh) takes the sandbox via -s; `codex exec resume` REJECTS
# -s and must receive it via `-c sandbox_mode=...`. Keep BASE sandbox-free.
BASE=(-m "$MODEL" -c model_reasoning_effort="$EFFORT" -c windows.sandbox="unelevated" "${FAST_ARGS[@]}" -o "$LAST")
[ "$JSON_OK" -eq 1 ] && BASE+=(--json)
SESSION_FILE="$DIR/session_id"

# Run codex in the background with a heartbeat (and optional hard timeout) so a
# 10-minute xhigh call is distinguishable from a hang. Heartbeats try /dev/tty
# first (reaches a human terminal even when the caller captures our streams),
# falling back to stderr. Returns codex's exit code, or 124 on timeout.
run_codex_bg() {
  local out
  if [ "$JSON_OK" -eq 1 ]; then out="$JSONL"; else out="$LOG"; fi
  if [ "$JSON_OK" -eq 1 ]; then
    codex "$@" - < "$PROMPT_FILE" > "$out" 2> "$LOG" &
  else
    codex "$@" - < "$PROMPT_FILE" > "$out" 2>&1 &
  fi
  local pid=$! elapsed=0 last_hb=0 step=2
  local hb="${CODEX_HEARTBEAT_SECS:-30}" tmo="${CODEX_TIMEOUT_SECS:-0}"
  case "$hb"  in ''|*[!0-9]*) hb=30 ;; esac
  case "$tmo" in ''|*[!0-9]*) tmo=0 ;; esac
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$step"
    elapsed=$((elapsed + step))
    if [ "$tmo" -gt 0 ] && [ "$elapsed" -ge "$tmo" ]; then
      echo "codex_bridge: TIMEOUT after ${elapsed}s (CODEX_TIMEOUT_SECS=$tmo) — killing codex" >&2
      kill "$pid" 2>/dev/null
      sleep 2
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    if [ $((elapsed - last_hb)) -ge "$hb" ]; then
      last_hb=$elapsed
      local msg="codex_bridge: codex still running (${elapsed}s elapsed; mode=$MODE log=$LOG)"
      { printf '%s\n' "$msg" > /dev/tty; } 2>/dev/null || printf '%s\n' "$msg" >&2
    fi
  done
  wait "$pid"
}

T0=$(date +%s 2>/dev/null || echo 0)
if [ "$RESUME" -eq 1 ]; then
  # Resume the EXACT session id captured from the last fresh run. We deliberately
  # do NOT fall back to `codex exec resume --last`: --last is cwd-filtered and can
  # silently attach to the WRONG thread after concurrent or manual codex use,
  # which corrupts the whole discussion. Fail loudly instead.
  SID="$(cat "$SESSION_FILE" 2>/dev/null || true)"
  if [ -z "$SID" ]; then
    echo "codex_bridge: --resume requested but no session id is recorded at $SESSION_FILE." >&2
    echo "codex_bridge: refusing the --last fallback (it can attach to the wrong thread)." >&2
    echo "codex_bridge: re-run WITHOUT --resume to start a fresh thread for this task." >&2
    exit 3
  fi
  run_codex_bg exec resume "$SID" "${BASE[@]}" -c sandbox_mode="$SANDBOX" "$@"
else
  run_codex_bg exec "${BASE[@]}" -s "$SANDBOX" "$@"
fi
RC=$?
DUR=$(( $(date +%s 2>/dev/null || echo 0) - T0 ))

# Capture this run's session id so a later `--resume` can target it explicitly:
# JSONL thread.started first, legacy "session id:" header as fallback.
SID_NEW=""
command -v codex_jsonl_thread_id >/dev/null 2>&1 && SID_NEW="$(codex_jsonl_thread_id "$JSONL")"
if [ -z "$SID_NEW" ]; then
  SID_NEW="$(grep -m1 -ohsE 'session id: [0-9a-fA-F-]+' "$JSONL" "$LOG" 2>/dev/null | awk '{print $3}' | head -1)"
fi
[ -n "$SID_NEW" ] && printf '%s\n' "$SID_NEW" > "$SESSION_FILE"

# If -o produced nothing (some failure paths), recover the final agent message
# from the JSONL item.completed events so the caller still sees the reply.
if [ ! -s "$LAST" ] && [ -s "$JSONL" ]; then
  PY="$(command -v python 2>/dev/null || command -v py 2>/dev/null || true)"
  if [ -n "$PY" ]; then
    "$PY" - "$JSONL" "$LAST" <<'PYEOF' 2>/dev/null || true
import json, sys
src, dst = sys.argv[1], sys.argv[2]
text = None
for line in open(src, encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    item = d.get("item") or {}
    if d.get("type") == "item.completed" and item.get("type") == "agent_message":
        text = item.get("text") or text
if text:
    open(dst, "w", encoding="utf-8").write(text)
PYEOF
  fi
fi

# Record Codex token usage to the per-task ledger before the next call
# overwrites run.jsonl/run.log. The loop sets CODEX_USAGE_LEDGER +
# CODEX_USAGE_LABEL; standalone use falls back to a ledger in the bridge dir.
DEFAULT_LABEL="$MODE"
[ "$RESUME" -eq 1 ] && DEFAULT_LABEL="$MODE/resume"
if command -v usage_record_codex >/dev/null 2>&1; then
  usage_record_codex \
    "${CODEX_USAGE_LEDGER:-$DIR/usage.tsv}" \
    "${CODEX_USAGE_LABEL:-$DEFAULT_LABEL}" \
    "$JSONL" "$LOG" "$RC" "$MODEL" "$DUR" 2>/dev/null || true
fi

echo "codex_bridge: exit=$RC mode=$MODE sandbox=$SANDBOX resume=$RESUME model=$MODEL effort=$EFFORT fast=${CODEX_FAST:+on} json=$([ "$JSON_OK" -eq 1 ] && echo on || echo off)"
echo "===== CODEX FINAL MESSAGE ====="
cat "$LAST" 2>/dev/null || true
if [ "$RC" -ne 0 ]; then
  ERRMSG=""
  command -v codex_jsonl_error >/dev/null 2>&1 && ERRMSG="$(codex_jsonl_error "$JSONL")"
  if [ "$RC" -eq 124 ]; then
    echo "===== ERROR ====="
    echo "codex call timed out after CODEX_TIMEOUT_SECS=${CODEX_TIMEOUT_SECS:-0}s."
  elif [ -n "$ERRMSG" ]; then
    echo "===== CODEX ERROR (turn.failed) ====="
    echo "$ERRMSG"
  else
    echo "===== LOG TAIL (error) ====="
    tail -40 "$LOG" 2>/dev/null || true
  fi
fi
exit "$RC"
