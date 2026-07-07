#!/usr/bin/env bash
# codex_loop.sh — hands-off orchestrator for Claude <-> Codex collaboration.
# Portable: lives next to codex_bridge.sh; run from the root of ANY git repo.
#
#   bash codex-bridge/codex_loop.sh --mode <build|guard|duel> \
#        [--task <id>] [--base <branch>] [--test '<cmd>'] [--spec <file>] \
#        [--model <m>] [--effort <low|medium|high|xhigh>] [--fast] [--teardown]
#
# Modes:
#   build   Codex implements (consult -> build -> review); Claude reviews the diff.
#   guard   Claude already edited the tree; Codex reviews it over threaded rounds.
#   duel    Mutual-critique DEBATE loop: Claude and Codex answer the same task and
#           critique each other every round until they converge (me-driven by
#           default; --auto for an unattended claude -p <-> Codex loop).
set -uo pipefail

# Resolve the kit's own directory so the sibling bridge is found no matter the
# repo, folder name, or cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE="$SCRIPT_DIR/codex_bridge.sh"

# Token accounting helpers (best-effort; never fatal).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/usage_lib.sh" 2>/dev/null || true

GUARD_LINE='Do NOT read or print generated files (.next/, dist/, build/, node_modules/, coverage/, *.min.*, compiled CSS). Reason about source only; never cat build output.'

MODE="build"
BASE="main"
TASK_ID=""
SPEC_FILE=""
SPEC_CONTENT=""
TEST_CMD=""
TEST_CMD_SET=0
TEARDOWN=0

# duel-debate state (mode=duel only; harmless defaults for build/guard)
AUTO=0
ROUNDS=4
CODE=0
SEED_FILE=""
PROMPT_FILE=""
BUDGET_USD=""
MAX_BYTES=60000
CONV_TOKEN="CONVERGED"
DUEL_STEP=""          # me-driven subcommand: init|codex|finalize (empty -> init)
CLAUDE_MODEL=""       # claude-side model; empty => omit --model (inherit session model)

# Codex model / reasoning effort / speed — overridable per run; passed through to
# the bridge (via env) and to `codex exec review`.
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_EFFORT="${CODEX_EFFORT:-xhigh}"
CODEX_FAST="${CODEX_FAST:-}"

OVERALL_RESULT="PASS"
TEST_RESULT="NOT RUN"
FAILING_COMMAND=""

usage() {
  cat >&2 <<'USAGE'
usage: bash codex-bridge/codex_loop.sh --mode <build|guard|duel> [--task <id>]
       [--base <branch>] [--test '<cmd>'] [--spec <file>]
       [--model <m>] [--effort <low|medium|high|xhigh>] [--fast] [--teardown]
       duel: [--auto] [--rounds N] [--code] [--seed <file>] [--prompt <file>]
             [--step init|codex|finalize] [--claude-model <m>] [--budget-usd <amt>]
             [--max-bytes N]

Modes:
  build   Codex implements, then Codex reviews the diff for Claude.
  guard   Claude already edited; Codex reviews hard over threaded rounds.
  duel    Mutual-critique DEBATE loop: Claude and Codex answer the SAME task,
          critique each other every round, and converge. Read-only by default
          (works for plain questions). Default is me-driven (the live Claude is
          the debater; step it with --step). --auto runs an unattended
          claude -p <-> Codex loop and REQUIRES --seed. --code lets Codex edit
          in a worktree while Claude reviews read-only (never auto-merged).

Model/speed:
  --model <m>     Codex model id (default gpt-5.5)
  --effort <e>    reasoning effort: low|medium|high|xhigh (default xhigh; the
                  claude side has no xhigh and is clamped to high)
  --fast          priority service tier (faster turnaround, same model/effort)
USAGE
}

die() {
  echo "codex_loop: $*" >&2
  exit 2
}

require_value() {
  [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      require_value "$@"
      MODE="$2"
      shift 2
      ;;
    --task)
      require_value "$@"
      TASK_ID="$2"
      shift 2
      ;;
    --base)
      require_value "$@"
      BASE="$2"
      shift 2
      ;;
    --test)
      require_value "$@"
      TEST_CMD="$2"
      TEST_CMD_SET=1
      shift 2
      ;;
    --spec)
      require_value "$@"
      SPEC_FILE="$2"
      shift 2
      ;;
    --model)
      require_value "$@"
      CODEX_MODEL="$2"
      shift 2
      ;;
    --effort)
      require_value "$@"
      CODEX_EFFORT="$2"
      shift 2
      ;;
    --fast)
      CODEX_FAST=1
      shift
      ;;
    --teardown)
      TEARDOWN=1
      shift
      ;;
    --auto)
      AUTO=1
      shift
      ;;
    --rounds)
      require_value "$@"
      ROUNDS="$2"
      shift 2
      ;;
    --code)
      CODE=1
      shift
      ;;
    --seed)
      require_value "$@"
      SEED_FILE="$2"
      shift 2
      ;;
    --prompt)
      require_value "$@"
      PROMPT_FILE="$2"
      shift 2
      ;;
    --budget-usd)
      require_value "$@"
      BUDGET_USD="$2"
      shift 2
      ;;
    --max-bytes)
      require_value "$@"
      MAX_BYTES="$2"
      shift 2
      ;;
    --claude-model)
      require_value "$@"
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --step)
      require_value "$@"
      DUEL_STEP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  build|guard|duel) ;;
  *) die "--mode must be build, guard, or duel" ;;
esac

case "$CODEX_EFFORT" in
  low|medium|high|xhigh) ;;
  *) die "--effort must be low, medium, high, or xhigh" ;;
esac

case "$ROUNDS" in
  ""|*[!0-9]*) die "--rounds must be a positive integer" ;;
  *) [ "$ROUNDS" -ge 1 ] || die "--rounds must be >= 1" ;;
esac

case "$MAX_BYTES" in
  ""|*[!0-9]*) die "--max-bytes must be a positive integer" ;;
  *) [ "$MAX_BYTES" -ge 1 ] || die "--max-bytes must be >= 1" ;;
esac

if [ -n "$DUEL_STEP" ]; then
  case "$DUEL_STEP" in
    init|codex|finalize) ;;
    *) die "--step must be init, codex, or finalize" ;;
  esac
fi

if [ "$TEST_CMD_SET" -eq 1 ] && [ -z "$TEST_CMD" ]; then
  die "--test cannot be empty"
fi

[ -f "$BRIDGE" ] || die "bridge not found next to this script: $BRIDGE"

# Pass model/effort/speed to the bridge child processes.
export CODEX_MODEL CODEX_EFFORT CODEX_FAST

REPO_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
REPO_ROOT="$(cd "$REPO_ROOT_RAW" 2>/dev/null && pwd -P)" || die "cannot resolve repo root"
CURRENT_DIR="$(pwd -P)"

if [ "$CURRENT_DIR" != "$REPO_ROOT" ]; then
  die "run from repo root: $REPO_ROOT"
fi

if [ -z "$TASK_ID" ]; then
  HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null)" || die "cannot resolve HEAD"
  TASK_ID="task-${HEAD_SHORT}-$$"
fi

case "$TASK_ID" in
  ""|*/*|*\\*|*..*|*[!A-Za-z0-9._-]*)
    die "--task must contain only letters, numbers, dot, underscore, or hyphen"
    ;;
esac

TASK_DIR_REL="tmp/codex/tasks/$TASK_ID"
TASK_DIR="$REPO_ROOT/$TASK_DIR_REL"
# Per-task bridge scratch dir isolates session_id/last_message.md so concurrent
# codex_loop runs (or a manual bridge call) can't cross-contaminate threads.
BRIDGE_DIR="$TASK_DIR/bridge"
DUEL_BRANCH="codex/duel-$TASK_ID"
DUEL_WORKTREE="../codex-duel-$TASK_ID"

if [ "$TEARDOWN" -eq 1 ]; then
  [ "$MODE" = "duel" ] || die "--teardown is only valid with --mode duel"
  echo "=== teardown ==="
  teardown_rc=0
  if [ -e "$DUEL_WORKTREE" ]; then
    git worktree remove --force "$DUEL_WORKTREE" || teardown_rc=$?
  fi
  # Clear stale admin entries even if the dir was removed out-of-band, else a
  # later `git worktree add` to the same path fails with "missing but registered".
  git worktree prune || teardown_rc=$?
  if git show-ref --verify --quiet "refs/heads/$DUEL_BRANCH"; then
    git branch -D "$DUEL_BRANCH" || teardown_rc=$?
  fi
  rm -f "$TASK_DIR/claude_session_id" "$BRIDGE_DIR/session_id" 2>/dev/null || true
  exit "$teardown_rc"
fi

git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base not found: $BASE"
mkdir -p "$TASK_DIR" "$BRIDGE_DIR" || die "cannot create task directories"

# --- Token accounting setup ------------------------------------------------
# Per-task ledger; the bridge appends Codex rows, the loop appends review +
# headless-Claude rows, and each SUMMARY renders the breakdown.
CODEX_USAGE_LEDGER="$TASK_DIR/usage.tsv"
export CODEX_USAGE_LEDGER
# JSON parser for Claude headless --output-format json (python preferred).
CLAUDE_USAGE_PY="$(command -v python 2>/dev/null || command -v py 2>/dev/null || true)"
# Truncate on a fresh start; append across me-driven duel steps so the per-task
# total spans the whole debate.
_usage_fresh=1
if [ "$MODE" = "duel" ] && [ "${AUTO:-0}" -ne 1 ]; then
  case "${DUEL_STEP:-init}" in init|"") _usage_fresh=1 ;; *) _usage_fresh=0 ;; esac
fi
[ "$_usage_fresh" -eq 1 ] && : > "$CODEX_USAGE_LEDGER"

read_spec() {
  if [ -n "$SPEC_FILE" ]; then
    [ -f "$SPEC_FILE" ] || die "spec file not found: $SPEC_FILE"
    SPEC_CONTENT="$(cat "$SPEC_FILE")" || die "cannot read spec file: $SPEC_FILE"
  else
    [ ! -t 0 ] || die "spec required via --spec <file> or stdin"
    SPEC_CONTENT="$(cat)" || die "cannot read spec from stdin"
  fi

  [ -n "$SPEC_CONTENT" ] || die "spec is empty"
}

prompt_consult() {
  printf 'Critique this implementation spec before any edits. Identify risks, edge cases, missing tests, and alternatives. Do not modify files.\n\n'
  printf '%s\n\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  printf 'SPEC:\n%s\n' "$SPEC_CONTENT"
}

prompt_build() {
  printf 'Implement the spec AND address your own critique above. Edit only source files.\n\n'
  printf '%s\n\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  printf 'SPEC:\n%s\n' "$SPEC_CONTENT"
}

prompt_guard_review() {
  printf 'Review the UNCOMMITTED changes in this repo. Run `git status` to list them, `git diff %s` to see MODIFIED files, and read any NEW/untracked files in full (plain `git diff` does not show untracked content). Report correctness bugs, missing tests, and risky edge cases with concrete file:line references. Do not modify files.\n\n' "$BASE"
  printf '%s\n' "$GUARD_LINE"
}

prompt_guard_findings() {
  printf 'Go deeper: name concrete correctness bugs, race/edge cases, and any missing test for the diff vs %s. List each as a checkbox finding.\n\n' "$BASE"
  printf '%s\n' "$GUARD_LINE"
}

copy_last_message() {
  dest="$1"
  if [ -f "$BRIDGE_DIR/last_message.md" ]; then
    cp "$BRIDGE_DIR/last_message.md" "$dest"
  else
    printf 'No %s/last_message.md was produced.\n' "$BRIDGE_DIR" > "$dest"
  fi
}

run_bridge() {
  bridge_mode="$1"
  dest="$2"
  log="$3"
  prompt_fn="$4"
  shift 4

  : > "$dest"
  # Write the prompt to a temp file instead of piping it in: under `set -o
  # pipefail` a writer-side SIGPIPE (141) would otherwise mask the bridge's real
  # exit code and fake a Codex failure. Call the bridge by ABSOLUTE path so duel
  # mode (cwd = worktree) still runs THIS kit's bridge, not a worktree copy.
  ptmp="$(mktemp)"
  "$prompt_fn" > "$ptmp"
  # Label the ledger row by step (consult/build/review/findings) from the dest name.
  local _label; _label="$(basename "$dest")"; _label="${_label%.*}"
  CODEX_USAGE_LABEL="$_label" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$bridge_mode" "$@" < "$ptmp" > "$log" 2>&1
  rc=$?
  rm -f "$ptmp"
  copy_last_message "$dest"
  return "$rc"
}

run_review() {
  out="$1"
  log="$2"

  : > "$out"
  # `codex exec review` REJECTS a custom PROMPT arg together with --uncommitted
  # /--base (clap conflict -> exit 2), so pass NO prompt. --uncommitted scopes the
  # review to staged+unstaged+UNTRACKED changes, so brand-new files Codex created
  # are covered (--base diffs vs a commit and misses untracked files entirely).
  review_fast=()
  [ -n "${CODEX_FAST:-}" ] && review_fast=(-c service_tier="priority")
  codex exec review --uncommitted \
    -c sandbox_mode=read-only \
    -c windows.sandbox=unelevated \
    -c model_reasoning_effort="$CODEX_EFFORT" \
    -m "$CODEX_MODEL" \
    "${review_fast[@]}" \
    -o "$out" > "$log" 2>&1
  local rc=$?
  # `codex exec review` bypasses the bridge, so record its tokens here.
  command -v usage_record_codex_from_log >/dev/null 2>&1 \
    && usage_record_codex_from_log "$CODEX_USAGE_LEDGER" review "$log" "$rc" 2>/dev/null || true
  return "$rc"
}

run_test() {
  log="$1"
  : > "$log"

  bash -lc "$TEST_CMD" > >(tee "$log" >/dev/null) 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    TEST_RESULT="PASS"
  else
    TEST_RESULT="FAIL"
    OVERALL_RESULT="FAIL (test)"
    FAILING_COMMAND="$TEST_CMD"
  fi
  return "$rc"
}

write_status() {
  # Union tracked diff with untracked-not-ignored files; `git diff --name-only`
  # alone omits brand-new files Codex created, under-reporting the audit trail.
  changed_files="$( { git diff --name-only "$BASE" --; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
  changed_rc=$?

  {
    printf 'mode: %s\n' "$MODE"
    printf 'base: %s\n' "$BASE"
    printf 'model: %s  effort: %s  fast: %s\n' "$CODEX_MODEL" "$CODEX_EFFORT" "${CODEX_FAST:+on}"
    printf 'result: %s\n' "$OVERALL_RESULT"
    printf '\nchanged files:\n'
    if [ "$changed_rc" -ne 0 ]; then
      printf -- '- (unable to compute git diff --name-only %s)\n' "$BASE"
    elif [ -n "$changed_files" ]; then
      while IFS= read -r changed_file; do
        printf -- '- %s\n' "$changed_file"
      done <<EOF_CHANGED
$changed_files
EOF_CHANGED
    else
      printf -- '- (none)\n'
    fi
    printf '\ntest result: %s\n' "$TEST_RESULT"
    if [ -n "$FAILING_COMMAND" ]; then
      printf 'failing command: %s\n' "$FAILING_COMMAND"
    fi
  } > "$TASK_DIR/status.md"
}

# Render the per-task token breakdown to stdout (in every SUMMARY) and to
# $TASK_DIR/usage.md. In build/guard the Claude side is the interactive session
# and is not measurable here — say so plainly.
emit_token_summary() {
  {
    echo "# Token usage — task $TASK_ID"
    echo
    echo '```'
    usage_report "$CODEX_USAGE_LEDGER"
    echo '```'
    if [ "$MODE" = build ] || [ "$MODE" = guard ]; then
      echo
      echo "_Note: in $MODE mode the Claude side is your interactive Claude Code session;_"
      echo "_its tokens are NOT captured here — see Claude Code \`/cost\` for that figure._"
    fi
  } > "$TASK_DIR/usage.md" 2>/dev/null || true
  echo ""
  echo "TOKENS (task $TASK_ID):"
  usage_report "$CODEX_USAGE_LEDGER"
  if [ "$MODE" = build ] || [ "$MODE" = guard ]; then
    echo "  note: Claude here = your interactive session (not bridge-measured); see Claude Code /cost."
  fi
}

print_build_summary() {
  echo "SUMMARY"
  echo "mode: $MODE  model: $CODEX_MODEL  effort: $CODEX_EFFORT  fast: ${CODEX_FAST:+on}"
  echo "artifacts: $TASK_DIR_REL"
  echo "status: $OVERALL_RESULT"
  if [ -n "$FAILING_COMMAND" ]; then
    echo "failing command: $FAILING_COMMAND"
  fi
  if [ -s "$TASK_DIR/review.md" ]; then
    echo "NEXT: Claude reviews \`git diff $BASE\` and adjudicates Codex findings in $TASK_DIR_REL/review.md"
  else
    echo "NEXT: build did not reach review — see $TASK_DIR_REL/status.md and *.log for the failure"
  fi
  emit_token_summary
}

print_guard_summary() {
  echo "SUMMARY"
  echo "mode: guard  model: $CODEX_MODEL  effort: $CODEX_EFFORT  fast: ${CODEX_FAST:+on}"
  echo "artifacts: $TASK_DIR_REL"
  echo "status: $OVERALL_RESULT"
  if [ -n "$FAILING_COMMAND" ]; then
    echo "failing command: $FAILING_COMMAND"
  fi
  echo "NEXT: Claude reconciles findings in $TASK_DIR_REL/findings.md, fixes or waives each with reason"
  emit_token_summary
}

print_duel_summary() {
  echo "SUMMARY"
  echo "mode: duel  auto: $([ "$AUTO" -eq 1 ] && echo on || echo off)  code: $([ "$CODE" -eq 1 ] && echo on || echo off)"
  echo "codex: $CODEX_MODEL/$CODEX_EFFORT${CODEX_FAST:+/fast}   claude: ${CLAUDE_MODEL:-session}/$(claude_effort)"
  echo "artifacts: $TASK_DIR_REL  (transcript.md = full debate, final.md = answer)"
  echo "rounds run: $(cat "$ROUND_FILE" 2>/dev/null || echo 0)/$ROUNDS   end: $END_REASON"
  echo "status: $OVERALL_RESULT"
  if [ "$AUTO" -eq 1 ]; then
    if [ -s "$TASK_DIR/final.md" ]; then
      echo "NEXT: read $TASK_DIR_REL/final.md (converged answer); full debate in transcript.md"
    else
      echo "NEXT: debate did not finalize — see $TASK_DIR_REL/status.md and rounds/*.log"
    fi
    [ "$CODE" -eq 1 ] && echo "Codex edits live in worktree $DUEL_WORKTREE (git -C $DUEL_WORKTREE diff $BASE). Claude did NOT auto-merge."
  else
    echo "me-driven step '${DUEL_STEP:-init}' done. Loop: write claude_latest.md -> --step codex -> read codex_latest.md; then --step finalize."
  fi
  emit_token_summary
}

run_consult_build() {
  echo "=== consult ==="
  if ! run_bridge consult "$TASK_DIR/consult.md" "$TASK_DIR/consult.log" prompt_consult; then
    OVERALL_RESULT="FAIL (consult)"
    FAILING_COMMAND="codex_bridge.sh consult"
    return 1
  fi

  echo "=== build ==="
  if ! run_bridge build "$TASK_DIR/build.md" "$TASK_DIR/build.log" prompt_build --resume; then
    OVERALL_RESULT="FAIL (build)"
    FAILING_COMMAND="codex_bridge.sh build --resume"
    return 1
  fi

  return 0
}

run_build_mode() {
  read_spec

  if ! run_consult_build; then
    write_status
    print_build_summary
    return 1
  fi

  echo "=== review ==="
  # Review is ADVISORY: `codex exec review` may exit non-zero simply because it
  # found issues (that is the point), so never abort the loop on a non-zero exit.
  # But distinguish "found issues" (review.md has content) from an infrastructure
  # failure (empty review.md) so a CLI/auth/model error can't masquerade as PASS.
  if ! run_review "$TASK_DIR/review.md" "$TASK_DIR/review.log"; then
    if [ -s "$TASK_DIR/review.md" ]; then
      echo "codex_loop: review reported findings (non-zero exit); see $TASK_DIR_REL/review.md" >&2
    else
      OVERALL_RESULT="PASS (review errored)"
      echo "codex_loop: WARNING: review produced no output and exited non-zero — likely a CLI/auth/model error, NOT a clean result; see $TASK_DIR_REL/review.log" >&2
    fi
  fi

  if [ "$TEST_CMD_SET" -eq 1 ]; then
    echo "=== test ==="
    if ! run_test "$TASK_DIR/test.log"; then
      write_status
      print_build_summary
      return 1
    fi
  fi

  write_status
  print_build_summary
  return 0
}

run_guard_mode() {
  # `git diff --quiet "$BASE"` returns 0 (no changes) when the only edits are NEW
  # untracked files, wrongly skipping the review. `git status --porcelain` sees
  # tracked AND untracked changes, so use it for the emptiness gate. Capture its
  # exit code so a git failure errors out instead of masquerading as "no changes".
  porcelain="$(git status --porcelain 2>/dev/null)"
  status_rc=$?
  [ "$status_rc" -eq 0 ] || die "cannot run git status (rc=$status_rc)"
  if [ -z "$porcelain" ]; then
    echo "guard mode: no changes to review" >&2
    return 2
  fi

  # Round 1 is a FRESH bridge consult (the bridge captures its session id), so
  # round 2's --resume threads off THIS review rather than a stale prior session
  # (a direct `codex exec review` bypasses the bridge and never records a session).
  echo "=== review (round 1) ==="
  if ! run_bridge consult "$TASK_DIR/review.md" "$TASK_DIR/review.log" prompt_guard_review; then
    OVERALL_RESULT="FAIL (review)"
    FAILING_COMMAND="codex_bridge.sh consult (guard review)"
    write_status
    print_guard_summary
    return 1
  fi

  echo "=== findings (round 2, threaded) ==="
  if ! run_bridge consult "$TASK_DIR/findings.md" "$TASK_DIR/findings.log" prompt_guard_findings --resume; then
    OVERALL_RESULT="FAIL (findings)"
    FAILING_COMMAND="codex_bridge.sh consult --resume (guard findings)"
    write_status
    print_guard_summary
    return 1
  fi

  write_status
  print_guard_summary
  return 0
}

# ===========================================================================
# Duel = continuous mutual-critique DEBATE loop (replaces the old
# implement-alone-and-compare). Claude and Codex answer the SAME task, share
# findings, critique each other every round, and converge. Two ways to run:
#   default (me-driven): the LIVE Claude session is the Claude debater; the
#     script runs only the Codex half each round, stepped by --step.
#   --auto:              fully unattended `claude -p` <-> Codex symmetric loop,
#     both pre-seeded so neither side starts blind.
# Read-only by default (works for plain questions); --code lets Codex edit in a
# worktree while Claude reviews read-only (the script never auto-merges to main).
# ===========================================================================

ROUNDS_DIR="$TASK_DIR/rounds"
TRANSCRIPT="$TASK_DIR/transcript.md"
PROMPT_STORE="$TASK_DIR/prompt.md"
SEED_STORE="$TASK_DIR/seed.md"
CLAUDE_LATEST="$TASK_DIR/claude_latest.md"
CODEX_LATEST="$TASK_DIR/codex_latest.md"
ROUND_FILE="$TASK_DIR/round.txt"
SID_FILE="$TASK_DIR/claude_session_id"
END_REASON="round-cap"

# Persona injected into every headless Claude turn (no apostrophes -> safe to
# keep single-quoted).
CLAUDE_PERSONA='You are the CLAUDE participant in a two-model mutual-critique debate with Codex (a GPT model). Each round: (1) share NEW findings/evidence with file:line or URLs, (2) critique the SPECIFIC claims Codex made and say why, (3) revise your own position and concede what you got wrong, (4) give your current best answer. Be terse and concrete. If nothing material remains to add, output the single line CONVERGED as the very last line.'

# A headless `claude -p` aborts with a nesting guard when CLAUDECODE et al. are
# inherited from this live session. Stripping these (verified on this box) lets
# the child launch cleanly.
claude_headless() {
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude "$@"
}

rr() { printf '%02d' "$1"; }     # zero-padded round label

# Mint a Claude session UUID up front so we NEVER parse claude output to thread.
# Group both branches before `tr` (| binds tighter than ||) and strip CR/LF.
mint_claude_sid() {
  { python -c 'import uuid,sys;sys.stdout.write(str(uuid.uuid4()))' 2>/dev/null \
    || powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString()" 2>/dev/null; } \
    | tr -d '\r\n'
}

# Byte-safe truncation guard so a pathological message cannot balloon the next
# prompt. head -c / wc -c are present in git-bash.
truncate_bytes() {
  local src="$1" cap="$2"
  [ -f "$src" ] || return 0
  if [ "$(wc -c <"$src")" -gt "$cap" ]; then
    head -c "$cap" "$src"
    printf '\n...[truncated at %s bytes]...\n' "$cap"
  else
    cat "$src"
  fi
}

# Converged ONLY if the last non-empty line, stripped of surrounding list/quote/
# emphasis markers and trailing punctuation, EXACTLY equals the token. Tolerates
# **CONVERGED**, `CONVERGED`, "- CONVERGED", "CONVERGED."; rejects substrings in
# prose like "not CONVERGED yet".
converged_side() {
  local file="$1" last
  [ -f "$file" ] || return 1
  last="$(awk 'NF{l=$0} END{print l}' "$file" | tr -d '\r')"
  last="$(printf '%s' "$last" | sed -e 's/^[[:space:]>*_`#-]*//' -e 's/[[:space:]*_`.!]*$//')"
  [ "$last" = "$CONV_TOKEN" ]
}

# Read the task prompt: --prompt > --spec (alias) > stdin. Not required to be code.
read_prompt() {
  if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"
    cat "$PROMPT_FILE" > "$PROMPT_STORE" || die "cannot read prompt file: $PROMPT_FILE"
  elif [ -n "$SPEC_FILE" ]; then
    [ -f "$SPEC_FILE" ] || die "spec file not found: $SPEC_FILE"
    cat "$SPEC_FILE" > "$PROMPT_STORE" || die "cannot read spec file: $SPEC_FILE"
  elif [ ! -t 0 ]; then
    cat > "$PROMPT_STORE" || die "cannot read prompt from stdin"
  else
    die "duel needs a task: --prompt <file>, --spec <file>, or stdin"
  fi
  [ -s "$PROMPT_STORE" ] || die "task prompt is empty"
}

# Store + validate the context-seed bundle. Hard error under --auto if absent
# (the headless side must not start blind).
read_seed() {
  if [ -n "$SEED_FILE" ]; then
    [ -f "$SEED_FILE" ] || die "seed file not found: $SEED_FILE"
    cat "$SEED_FILE" > "$SEED_STORE" || die "cannot read seed file: $SEED_FILE"
    [ -s "$SEED_STORE" ] || die "seed file is empty: $SEED_FILE"
  else
    [ "$AUTO" -eq 1 ] && die "--auto requires --seed <file> (the headless side must not start blind)"
    : > "$SEED_STORE"
  fi
}

codex_sandbox_mode() { [ "$CODE" -eq 1 ] && echo build || echo consult; }

# Round-0 Codex prompt (fresh thread): seed + task + latest Claude + critique ask.
build_codex_prompt() {
  local rnd="$1" claude_msg="$2"
  printf 'You and Claude independently solve the SAME task, then CRITIQUE each other every round to converge on ONE cross-checked answer. This is round %s of %s.\n\n' "$rnd" "$ROUNDS"
  printf 'Do your OWN reasoning first, then critique the latest Claude message below: name concrete errors, missed cases, better sources/approaches, AND anything Claude got right that you would adopt. End with (a) your current best answer and (b) a short "DISAGREEMENTS REMAINING" list. If nothing material remains to add, output the SINGLE line %s as the very last line.\n\n' "$CONV_TOKEN"
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  if [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    printf '=== CURRENT WORKTREE DIFF vs %s (you are the SOLE editor; edit files in this worktree) ===\n' "$BASE"
    ( git -C "$DUEL_WORKTREE" diff "$BASE" 2>/dev/null || true ) | head -c "$MAX_BYTES"
    printf '\n\n'
  fi
  printf '=== TASK ===\n'
  cat "$PROMPT_STORE"
  printf '\n\n=== SHARED CONTEXT SEED ===\n'
  if [ -s "$SEED_STORE" ]; then cat "$SEED_STORE"; else printf '(none)\n'; fi
  if [ -n "$claude_msg" ] && [ -f "$claude_msg" ]; then
    printf '\n\n=== LATEST CLAUDE MESSAGE (round %s, may be truncated) ===\n' "$rnd"
    truncate_bytes "$claude_msg" "$MAX_BYTES"
  fi
}

# Resume Codex prompt (rounds >= 1): Codex remembers prior rounds via its session,
# so feed ONLY the newest Claude message + the instruction.
build_codex_resume_prompt() {
  local rnd="$1" claude_msg="$2"
  printf 'Round %s of %s. Claude just replied below. Do your own check first, then critique it, adopt/fix as warranted, and give your updated best answer plus a short "DISAGREEMENTS REMAINING" list. If nothing material remains, output the SINGLE line %s as the very last line.\n\n' "$rnd" "$ROUNDS" "$CONV_TOKEN"
  printf '%s\n\n' "$GUARD_LINE"
  if [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    printf '=== CURRENT WORKTREE DIFF vs %s ===\n' "$BASE"
    ( git -C "$DUEL_WORKTREE" diff "$BASE" 2>/dev/null || true ) | head -c "$MAX_BYTES"
    printf '\n\n'
  fi
  printf '=== LATEST CLAUDE MESSAGE (round %s, may be truncated) ===\n' "$rnd"
  truncate_bytes "$claude_msg" "$MAX_BYTES"
}

# Run ONE Codex turn via the bridge (prebuilt prompt file; no inline injection).
# In --code, run with cwd = the worktree so Codex edits land THERE, not in main.
# $1=round $2=resume(0|1) $3=path-to-latest-claude-message
run_codex_turn() {
  local rnd="$1" resume="$2" claude_msg="$3" out log ptmp rc
  out="$ROUNDS_DIR/$(rr "$rnd")-codex.md"
  log="$ROUNDS_DIR/$(rr "$rnd")-codex.log"
  ptmp="$(mktemp)"
  if [ "$resume" -eq 1 ]; then
    build_codex_resume_prompt "$rnd" "$claude_msg" > "$ptmp"
  else
    build_codex_prompt "$rnd" "$claude_msg" > "$ptmp"
  fi
  local resume_flag=()
  [ "$resume" -eq 1 ] && resume_flag=(--resume)
  local _clabel="duel-codex-r$rnd"
  if [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    ( cd "$DUEL_WORKTREE" && CODEX_USAGE_LABEL="$_clabel" CODEX_USAGE_LEDGER="$CODEX_USAGE_LEDGER" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$(codex_sandbox_mode)" "${resume_flag[@]}" < "$ptmp" ) > "$log" 2>&1
  else
    CODEX_USAGE_LABEL="$_clabel" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$(codex_sandbox_mode)" "${resume_flag[@]}" < "$ptmp" > "$log" 2>&1
  fi
  rc=$?
  rm -f "$ptmp"
  copy_last_message "$out"
  cp "$out" "$CODEX_LATEST" 2>/dev/null || true
  return "$rc"
}

append_transcript() {
  local who="$1" rnd="$2" file="$3"
  { printf '\n## Round %s — %s\n\n' "$rnd" "$who"; cat "$file" 2>/dev/null; } >> "$TRANSCRIPT"
}

# --- Claude side (--auto only) --------------------------------------------
claude_perm()   { [ "$CODE" -eq 1 ] && echo acceptEdits || echo plan; }
claude_effort() { local e="$CODEX_EFFORT"; [ "$e" = xhigh ] && e=high; echo "$e"; }   # claude has no xhigh

# Split a `claude -p --output-format json` payload: write the reply text to $2 and
# append a Claude usage row (label $4) to the ledger $5. Returns non-zero if the
# JSON can't be parsed (caller falls back). Uses python (CLAUDE_USAGE_PY).
claude_json_split() {
  local jf="$1" of="$2" label="$3" ledger="$4"
  [ -n "$CLAUDE_USAGE_PY" ] || return 1
  local res
  res="$("$CLAUDE_USAGE_PY" - "$jf" "$of" "$ledger" "$label" <<'PYEOF'
import json, sys, time
jf, of, ledger, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    d = json.load(open(jf, encoding="utf-8"))
except Exception:
    sys.exit(2)
res = d.get("result")
if not isinstance(res, str):
    sys.exit(3)
open(of, "w", encoding="utf-8").write(res)
u = d.get("usage") or {}
def g(k):
    try: return int(u.get(k, 0) or 0)
    except Exception: return 0
inp = g("input_tokens") + g("cache_read_input_tokens") + g("cache_creation_input_tokens")
out = g("output_tokens")
try:
    with open(ledger, "a", encoding="utf-8") as f:
        f.write("\t".join([str(int(time.time())), "", "claude", label,
                           str(inp + out), str(inp), str(out), "0"]) + "\n")
except Exception:
    pass
print("ok")
PYEOF
)"
  [ "$res" = "ok" ]
}

# Run ONE headless Claude turn. Prompt comes from a temp file (NOT a pipe) so a
# writer-side SIGPIPE under pipefail cannot mask claude's real exit code.
# $1=round $2=set|resume $3=stdin-builder-fn
run_claude_turn() {
  local rnd="$1" idmode="$2" builder="$3" out log sid perm rc ptmp
  out="$ROUNDS_DIR/$(rr "$rnd")-claude.md"
  log="$ROUNDS_DIR/$(rr "$rnd")-claude.log"
  sid="$(cat "$SID_FILE" 2>/dev/null)"
  [ -n "$sid" ] || { echo "codex_loop: missing claude session id" >&2; return 1; }

  # Claude is read-only in --code (Codex is the sole writer); force plan.
  perm="$(claude_perm)"
  [ "$CODE" -eq 1 ] && perm="plan"

  local idflag=(--session-id "$sid")
  [ "$idmode" = "resume" ] && idflag=(--resume "$sid")
  local modelflag=();  [ -n "$CLAUDE_MODEL" ] && modelflag=(--model "$CLAUDE_MODEL")
  local budgetflag=(); [ -n "$BUDGET_USD" ]   && budgetflag=(--max-budget-usd "$BUDGET_USD")

  ptmp="$(mktemp)"
  "$builder" "$rnd" > "$ptmp"
  if [ -n "$CLAUDE_USAGE_PY" ]; then
    # Capture token usage: get JSON, split reply text -> $out, usage -> ledger.
    local jtmp; jtmp="$(mktemp)"
    claude_headless -p \
        "${idflag[@]}" \
        --permission-mode "$perm" \
        --tools "Read" "Grep" "Glob" "WebSearch" "WebFetch" \
        --append-system-prompt "$CLAUDE_PERSONA" \
        --effort "$(claude_effort)" \
        "${modelflag[@]}" "${budgetflag[@]}" \
        --output-format json \
        < "$ptmp" > "$jtmp" 2>"$log"
    rc=$?
    [ "$rc" -eq 0 ] && claude_json_split "$jtmp" "$out" "duel-claude-r$rnd" "$CODEX_USAGE_LEDGER"
    rm -f "$jtmp"
  else
    claude_headless -p \
        "${idflag[@]}" \
        --permission-mode "$perm" \
        --tools "Read" "Grep" "Glob" "WebSearch" "WebFetch" \
        --append-system-prompt "$CLAUDE_PERSONA" \
        --effort "$(claude_effort)" \
        "${modelflag[@]}" "${budgetflag[@]}" \
        --output-format text \
        < "$ptmp" > "$out" 2>"$log"
    rc=$?
  fi
  rm -f "$ptmp"
  [ "$rc" -ne 0 ] && return "$rc"
  [ -s "$out" ] || return 99
  cp "$out" "$CLAUDE_LATEST" 2>/dev/null || true
  return 0
}

claude_stdin_round0() {
  cat "$SEED_STORE" 2>/dev/null
  printf '\n\n=== TASK ===\n'
  cat "$PROMPT_STORE"
  printf '\n\n=== YOUR TURN (round %s of %s) ===\nDo your own independent research and give your opening position. You will see and critique Codex in later rounds.\n' "$1" "$ROUNDS"
}

claude_stdin_resume() {
  local rnd="$1"
  printf 'Round %s of %s. Codex just replied below. Do your OWN check first, then critique its SPECIFIC claims, fix/adopt what is warranted, and give your updated best answer. If nothing material remains to add, output the SINGLE line %s as the very last line.\n\n' "$rnd" "$ROUNDS" "$CONV_TOKEN"
  printf '=== CODEX LATEST (may be truncated) ===\n'
  truncate_bytes "$CODEX_LATEST" "$MAX_BYTES"
}

note_partial() { END_REASON="partial-failure-$1"; echo "codex_loop: partial failure ($1) at round $2 rc=$3; finalizing on partial output" >&2; }

write_duel_status() {
  local changed_files rounds_run
  changed_files="$( { git diff --name-only "$BASE" --; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
  rounds_run="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
  {
    printf 'mode: duel\n'
    printf 'auto: %s  code: %s\n' "$([ "$AUTO" -eq 1 ] && echo on || echo off)" "$([ "$CODE" -eq 1 ] && echo on || echo off)"
    printf 'base: %s\n' "$BASE"
    printf 'codex model: %s  effort: %s  fast: %s\n' "$CODEX_MODEL" "$CODEX_EFFORT" "${CODEX_FAST:+on}"
    printf 'claude model: %s  effort: %s\n' "${CLAUDE_MODEL:-(session default)}" "$(claude_effort)"
    printf 'rounds run: %s / %s\n' "$rounds_run" "$ROUNDS"
    printf 'end reason: %s\n' "$END_REASON"
    printf 'result: %s\n' "$OVERALL_RESULT"
    printf '\nchanged files:\n'
    if [ -n "$changed_files" ]; then
      printf '%s\n' "$changed_files" | while IFS= read -r f; do printf -- '- %s\n' "$f"; done
    else
      printf -- '- (none)\n'
    fi
  } > "$TASK_DIR/status.md"
}

# A final resumed Claude turn synthesizes the converged answer (it holds the whole
# thread in-session). Runs even on non-convergence; enumerates UNRESOLVED points.
finalize_and_report() {
  if [ -f "$SID_FILE" ]; then
    local sid ptmp; sid="$(cat "$SID_FILE" 2>/dev/null)"
    if [ -n "$sid" ]; then
      local modelflag=();  [ -n "$CLAUDE_MODEL" ] && modelflag=(--model "$CLAUDE_MODEL")
      local budgetflag=(); [ -n "$BUDGET_USD" ]   && budgetflag=(--max-budget-usd "$BUDGET_USD")
      ptmp="$(mktemp)"
      {
        printf 'The debate is over (end reason: %s). Produce the FINAL combined, cross-checked answer:\n' "$END_REASON"
        printf 'merge where you and Codex agree; for EACH remaining disagreement state both positions and your adjudication under a "## UNRESOLVED" heading. Output the answer only.\n'
      } > "$ptmp"
      local frc
      if [ -n "$CLAUDE_USAGE_PY" ]; then
        local fjtmp; fjtmp="$(mktemp)"
        claude_headless -p --resume "$sid" \
            --permission-mode plan \
            --tools "Read" "Grep" "Glob" "WebSearch" "WebFetch" \
            --effort "$(claude_effort)" \
            "${modelflag[@]}" "${budgetflag[@]}" \
            --output-format json \
            < "$ptmp" > "$fjtmp" 2>"$TASK_DIR/final.log"
        frc=$?
        [ "$frc" -eq 0 ] && claude_json_split "$fjtmp" "$TASK_DIR/final.md" "duel-claude-final" "$CODEX_USAGE_LEDGER"
        rm -f "$fjtmp"
      else
        claude_headless -p --resume "$sid" \
            --permission-mode plan \
            --tools "Read" "Grep" "Glob" "WebSearch" "WebFetch" \
            --effort "$(claude_effort)" \
            "${modelflag[@]}" "${budgetflag[@]}" \
            --output-format text \
            < "$ptmp" > "$TASK_DIR/final.md" 2>"$TASK_DIR/final.log"
        frc=$?
      fi
      rm -f "$ptmp"
      # The debate transcript is the real artifact; a failed synthesis call (e.g.
      # a usage-limit stub written to final.md) must NOT masquerade as a clean run.
      if [ "$frc" -ne 0 ]; then
        OVERALL_RESULT="PASS (debate complete; final synthesis failed rc=$frc — transcript.md is authoritative, see final.log)"
      fi
    fi
  fi
  [ -s "$TASK_DIR/final.md" ] || OVERALL_RESULT="PASS (no final synthesis; transcript.md is authoritative)"
  case "$END_REASON" in partial-failure-*) OVERALL_RESULT="FAIL ($END_REASON)" ;; esac
  write_duel_status
  print_duel_summary
}

# Fully unattended symmetric loop: claude -p (threaded by fixed UUID) <-> Codex.
run_duel_auto() {
  mkdir -p "$ROUNDS_DIR" || die "cannot create rounds dir"
  read_prompt
  read_seed

  if [ "$CODE" -eq 1 ]; then
    echo "=== worktree (code mode) ==="
    if ! git worktree add -b "$DUEL_BRANCH" "$DUEL_WORKTREE" "$BASE" > "$TASK_DIR/worktree.log" 2>&1; then
      OVERALL_RESULT="FAIL (worktree)"
      FAILING_COMMAND="git worktree add -b $DUEL_BRANCH $DUEL_WORKTREE $BASE"
      echo "codex_loop: worktree/branch may exist from a prior run; clean with '--mode duel --task $TASK_ID --teardown'." >&2
      write_duel_status; print_duel_summary; return 1
    fi
  fi

  local sid; sid="$(mint_claude_sid)"
  [ -n "$sid" ] || { OVERALL_RESULT="FAIL (uuid)"; write_duel_status; print_duel_summary; return 1; }
  printf '%s\n' "$sid" > "$SID_FILE"

  : > "$TRANSCRIPT"
  printf '# Duel debate — %s\n\nauto | code:%s | rounds:%s | codex:%s/%s | claude:%s\n\n(round 0 = independent research, no cross-feed yet)\n' \
    "$TASK_ID" "$([ "$CODE" -eq 1 ] && echo on || echo off)" "$ROUNDS" \
    "$CODEX_MODEL" "$CODEX_EFFORT" "$(claude_effort)" >> "$TRANSCRIPT"

  local r rc
  r=0; printf '%s\n' "$r" > "$ROUND_FILE"

  echo "=== round 0: claude ==="
  run_claude_turn 0 set claude_stdin_round0; rc=$?
  if [ "$rc" -ne 0 ]; then note_partial claude 0 "$rc"; finalize_and_report; return 1; fi
  append_transcript CLAUDE 0 "$ROUNDS_DIR/00-claude.md"

  echo "=== round 0: codex ==="
  run_codex_turn 0 0 "$ROUNDS_DIR/00-claude.md"; rc=$?
  if [ "$rc" -ne 0 ]; then note_partial codex 0 "$rc"; finalize_and_report; return 1; fi
  append_transcript CODEX 0 "$ROUNDS_DIR/00-codex.md"

  if converged_side "$CLAUDE_LATEST" && converged_side "$CODEX_LATEST"; then
    END_REASON="both-converged"; finalize_and_report; return 0
  fi

  for r in $(seq 1 $((ROUNDS - 1))); do
    printf '%s\n' "$r" > "$ROUND_FILE"

    echo "=== round $r: claude ==="
    run_claude_turn "$r" resume claude_stdin_resume; rc=$?
    if [ "$rc" -ne 0 ]; then note_partial claude "$r" "$rc"; finalize_and_report; return 1; fi
    append_transcript CLAUDE "$r" "$ROUNDS_DIR/$(rr "$r")-claude.md"

    echo "=== round $r: codex ==="
    run_codex_turn "$r" 1 "$ROUNDS_DIR/$(rr "$r")-claude.md"; rc=$?
    if [ "$rc" -ne 0 ]; then note_partial codex "$r" "$rc"; finalize_and_report; return 1; fi
    append_transcript CODEX "$r" "$ROUNDS_DIR/$(rr "$r")-codex.md"

    if converged_side "$CLAUDE_LATEST" && converged_side "$CODEX_LATEST"; then
      END_REASON="both-converged"; finalize_and_report; return 0
    fi
  done

  END_REASON="round-cap"
  finalize_and_report
  return 0
}

# Me-driven: the LIVE Claude session is the Claude debater; the script runs only
# the Codex half + bookkeeping, stepped by --step init|codex|finalize.
run_duel_mode() {
  if [ "$AUTO" -eq 1 ]; then
    run_duel_auto
    return $?
  fi

  mkdir -p "$ROUNDS_DIR" || die "cannot create rounds dir"
  [ -n "$DUEL_STEP" ] || DUEL_STEP="init"
  local r resume rc code_flag
  code_flag="$([ "$CODE" -eq 1 ] && printf ' --code')"

  case "$DUEL_STEP" in
    init)
      read_prompt
      read_seed
      printf '0\n' > "$ROUND_FILE"
      : > "$TRANSCRIPT"
      printf '# Duel debate — %s\n\nme-driven | code:%s | rounds:%s\n' \
        "$TASK_ID" "$([ "$CODE" -eq 1 ] && echo on || echo off)" "$ROUNDS" >> "$TRANSCRIPT"
      if [ "$CODE" -eq 1 ]; then
        echo "=== worktree (code mode) ==="
        git worktree add -b "$DUEL_BRANCH" "$DUEL_WORKTREE" "$BASE" > "$TASK_DIR/worktree.log" 2>&1 \
          || die "worktree add failed; clean with '--mode duel --task $TASK_ID --teardown' (see worktree.log)"
      fi
      printf 'me-driven duel ready (task: %s).\n' "$TASK_ID"
      printf '  transcript: %s/transcript.md\n  prompt:     %s/prompt.md\n' "$TASK_DIR_REL" "$TASK_DIR_REL"
      printf 'Each round, you (live Claude) do:\n'
      printf '  1. Do your own research/critique; write your turn to %s/claude_latest.md\n' "$TASK_DIR_REL"
      printf '  2. Run one Codex turn:\n       bash codex-bridge/codex_loop.sh --mode duel --task %s --step codex%s\n' "$TASK_ID" "$code_flag"
      printf '  3. Read %s/codex_latest.md; critique/adopt; repeat until CONVERGED or %s rounds.\n' "$TASK_DIR_REL" "$ROUNDS"
      printf '  4. Finish: bash codex-bridge/codex_loop.sh --mode duel --task %s --step finalize\n' "$TASK_ID"
      return 0
      ;;
    codex)
      [ -s "$PROMPT_STORE" ] || die "no prompt.md; run '--step init' first"
      [ -s "$CLAUDE_LATEST" ] || die "write your turn to $CLAUDE_LATEST before '--step codex'"
      r="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
      case "$r" in ""|*[!0-9]*) r=0 ;; esac
      [ "$r" -lt "$ROUNDS" ] || die "round cap ($ROUNDS) reached; run '--step finalize' (raise with --rounds N if you truly want more)"
      cp "$CLAUDE_LATEST" "$ROUNDS_DIR/$(rr "$r")-claude.md" 2>/dev/null || true
      append_transcript CLAUDE "$r" "$ROUNDS_DIR/$(rr "$r")-claude.md"

      resume=0; [ "$r" -gt 0 ] && resume=1
      echo "=== round $r: codex ==="
      run_codex_turn "$r" "$resume" "$ROUNDS_DIR/$(rr "$r")-claude.md"; rc=$?
      if [ "$rc" -ne 0 ]; then
        OVERALL_RESULT="FAIL (codex r$r)"; FAILING_COMMAND="codex_bridge.sh $(codex_sandbox_mode)"
        write_duel_status; print_duel_summary; return 1
      fi
      append_transcript CODEX "$r" "$ROUNDS_DIR/$(rr "$r")-codex.md"
      printf '%s\n' "$((r + 1))" > "$ROUND_FILE"

      echo "----- CODEX (round $r) -> $TASK_DIR_REL/codex_latest.md -----"
      cat "$CODEX_LATEST"
      if converged_side "$CODEX_LATEST"; then
        echo "----- Codex signalled CONVERGED. If you also converge, run '--step finalize'. -----"
      fi
      if [ "$((r + 1))" -ge "$ROUNDS" ]; then
        echo "----- round cap ($ROUNDS) reached; run '--step finalize'. -----"
      fi
      return 0
      ;;
    finalize)
      [ -s "$PROMPT_STORE" ] || die "no prompt.md; run '--step init' first"
      if converged_side "$CODEX_LATEST" && converged_side "$CLAUDE_LATEST"; then
        END_REASON="both-converged"
      else
        END_REASON="round-cap"
      fi
      write_duel_status
      print_duel_summary
      printf '\nNEXT (you, live Claude): author the converged, cross-checked answer to\n'
      printf '  %s/final.md  — merge where you and Codex agree; under "## UNRESOLVED"\n' "$TASK_DIR_REL"
      printf '  state both positions + your adjudication for each remaining disagreement.\n'
      if [ "$CODE" -eq 1 ]; then
        printf '  Codex edits are in %s (git -C %s diff %s). Cherry-pick into main if desired;\n' "$DUEL_WORKTREE" "$DUEL_WORKTREE" "$BASE"
        printf '  the script does NOT auto-merge. Then run --teardown.\n'
      fi
      return 0
      ;;
  esac
}

case "$MODE" in
  build) run_build_mode; exit $? ;;
  guard) run_guard_mode; exit $? ;;
  duel) run_duel_mode; exit $? ;;
esac
