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
#   CODEX_MODEL   (default gpt-5.5)
#   CODEX_EFFORT  (default xhigh)   -> -c model_reasoning_effort=<effort>
#   CODEX_FAST    (default unset)   -> when non-empty, -c service_tier=priority
#
# --resume keeps the conversation going: Codex recalls the previous rounds, so
# Claude can react to Codex's ideas and Codex can build on Claude's, both ways.
#
# Output: the agent's FINAL message prints to stdout (and $CODEX_BRIDGE_DIR/
# last_message.md); the full transcript goes to $CODEX_BRIDGE_DIR/run.log so it
# never floods the caller.
set -uo pipefail

# Token accounting (best-effort; never fatal).
# shellcheck source=/dev/null
. "$(dirname "$0")/usage_lib.sh" 2>/dev/null || true

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
: > "$LAST"

MODEL="${CODEX_MODEL:-gpt-5.5}"
EFFORT="${CODEX_EFFORT:-xhigh}"
FAST_ARGS=()
[ -n "${CODEX_FAST:-}" ] && FAST_ARGS=(-c service_tier="priority")

# windows.sandbox=unelevated: the "elevated" mode needs a logon-user setup that
# isn't provisioned on this box (CreateProcessWithLogonW fails), so Codex can't
# run verification commands; "unelevated" (restricted token + network) works.
# (On non-Windows hosts this -c override is simply ignored.)
# NOTE: `codex exec` (fresh) takes the sandbox via -s; `codex exec resume` REJECTS
# -s and must receive it via `-c sandbox_mode=...`. Keep BASE sandbox-free.
BASE=(-m "$MODEL" -c model_reasoning_effort="$EFFORT" -c windows.sandbox="unelevated" "${FAST_ARGS[@]}" -o "$LAST")
SESSION_FILE="$DIR/session_id"

if [ "$RESUME" -eq 1 ]; then
  # Resume the EXACT session id captured from the last fresh run. `--last` is
  # cwd-filtered and can grab the wrong session after concurrent/manual Codex use.
  SID="$(cat "$SESSION_FILE" 2>/dev/null || true)"
  if [ -n "$SID" ]; then
    codex exec resume "$SID" "${BASE[@]}" -c sandbox_mode="$SANDBOX" "$@" - > "$LOG" 2>&1
  else
    codex exec resume --last "${BASE[@]}" -c sandbox_mode="$SANDBOX" "$@" - > "$LOG" 2>&1
  fi
else
  codex exec "${BASE[@]}" -s "$SANDBOX" "$@" - > "$LOG" 2>&1
fi
RC=$?

# Capture this run's session id so a later `--resume` can target it explicitly.
SID_NEW="$(grep -m1 -oE 'session id: [0-9a-fA-F-]+' "$LOG" 2>/dev/null | awk '{print $3}')"
[ -n "$SID_NEW" ] && printf '%s\n' "$SID_NEW" > "$SESSION_FILE"

# Record Codex token usage to the per-task ledger before the next call overwrites
# this run.log. The loop sets CODEX_USAGE_LEDGER + CODEX_USAGE_LABEL; standalone
# use falls back to a ledger next to the bridge dir.
if command -v usage_record_codex_from_log >/dev/null 2>&1; then
  usage_record_codex_from_log \
    "${CODEX_USAGE_LEDGER:-$DIR/usage.tsv}" \
    "${CODEX_USAGE_LABEL:-$MODE${RESUME:+/resume}}" \
    "$LOG" "$RC" 2>/dev/null || true
fi

echo "codex_bridge: exit=$RC mode=$MODE sandbox=$SANDBOX resume=$RESUME model=$MODEL effort=$EFFORT fast=${CODEX_FAST:+on}"
echo "===== CODEX FINAL MESSAGE ====="
cat "$LAST" 2>/dev/null || true
if [ "$RC" -ne 0 ]; then
  echo "===== LOG TAIL (error) ====="
  tail -40 "$LOG" 2>/dev/null || true
fi
exit "$RC"
