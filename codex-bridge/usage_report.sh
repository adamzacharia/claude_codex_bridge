#!/usr/bin/env bash
# usage_report.sh — print Codex/Claude token usage recorded by the bridge.
#
#   bash codex-bridge/usage_report.sh                 # every task + grand totals
#   bash codex-bridge/usage_report.sh build-01-rag    # one task's breakdown
#
# Reads the per-task ledgers at tmp/codex/tasks/<id>/usage.tsv. (Codex figures are
# captured per call; Claude figures are captured only for headless `claude -p`
# turns in --auto duels — interactive Claude in build/guard isn't measurable here.)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/usage_lib.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TASKS_DIR="$ROOT/tmp/codex/tasks"

if [ "${1:-}" != "" ]; then
  led="$TASKS_DIR/$1/usage.tsv"
  echo "== token usage: task $1 =="
  usage_report "$led"
  exit 0
fi

[ -d "$TASKS_DIR" ] || { echo "no tasks found under $TASKS_DIR"; exit 0; }

ALL="$(mktemp)"
trap 'rm -f "$ALL"' EXIT
found=0
for d in "$TASKS_DIR"/*/; do
  led="$d/usage.tsv"
  [ -s "$led" ] || continue
  found=1
  task="$(basename "$d")"
  echo "== task $task =="
  usage_report "$led"
  echo
  cat "$led" >> "$ALL"
done

if [ "$found" -eq 0 ]; then
  echo "no usage ledgers recorded yet."
  exit 0
fi

echo "================= GRAND TOTAL (all tasks) ================="
usage_report "$ALL"
