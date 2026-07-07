#!/usr/bin/env bash
# codex_loop.sh — hands-off orchestrator for Claude <-> Codex collaboration.
# Portable: lives next to codex_bridge.sh; run from the root of ANY git repo.
#
#   bash codex-bridge/codex_loop.sh --mode <build|guard|duel> \
#        [--task <id>] [--base <branch>] [--test '<cmd>'] [--spec <file>] \
#        [--model <m>] [--effort <low|medium|high|xhigh>] [--fast] \
#        [--fix-rounds N] [--claude-review] [--dry-run] [--teardown]
#
# Modes:
#   build   Codex implements (consult -> build -> test/fix loop -> review ->
#           optional Claude cross-review + Codex response); Claude reviews the diff.
#   guard   Claude already edited the tree; Codex reviews it over threaded rounds;
#           then '--step verify' has Codex re-check Claude's fixes on the SAME thread.
#   duel    Mutual-critique DEBATE loop: Claude and Codex answer the same task and
#           critique each other every round until they converge (me-driven by
#           default; --auto for an unattended claude -p <-> Codex loop).
#
# Discussion discipline: the two models SHARE EVERYTHING. Every artifact (specs,
# critiques, build notes, test output, reviews, reconciliations, verdicts) is a
# file under tmp/codex/tasks/<id>/ and is fed verbatim (byte-capped) into the
# other side's next prompt. A per-task journal.md records each step, and a
# persistent tmp/codex/memory.md carries decisions across tasks so neither
# model ever starts blind.
set -uo pipefail

# Resolve the kit's own directory so the sibling scripts are found no matter
# the repo, folder name, or cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE="$SCRIPT_DIR/codex_bridge.sh"
KIT_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo '?')"

# Token accounting + pure duel helpers (best-effort; never fatal).
# shellcheck source=usage_lib.sh
. "$SCRIPT_DIR/usage_lib.sh" 2>/dev/null || true
# shellcheck source=duel_lib.sh
. "$SCRIPT_DIR/duel_lib.sh" 2>/dev/null || true

GUARD_LINE='Do NOT read or print generated files (.next/, dist/, build/, node_modules/, coverage/, *.min.*, compiled CSS). Reason about source only; never cat build output.'
SHARE_LINE='Share EVERYTHING relevant with your counterpart: every file you changed and why, every command you ran and its outcome, test results verbatim (tail if long), every assumption you made, and anything you are unsure about. End with two sections: "NOTES FOR CLAUDE" (facts/decisions the other side must know) and "OPEN QUESTIONS" (numbered; write "none" if empty).'

MODE="build"
BASE="main"
TASK_ID=""
SPEC_FILE=""
SPEC_CONTENT=""
TEST_CMD=""
TEST_CMD_SET=0
TEARDOWN=0
DRY_RUN=0
FIX_ROUNDS=2
CLAUDE_REVIEW=0
ARBITER=1

# duel-debate state (mode=duel only; harmless defaults for build/guard)
AUTO=0
ROUNDS=4
CODE=0
SEED_FILE=""
PROMPT_FILE=""
BUDGET_USD=""
MAX_BYTES=60000
CONV_TOKEN="CONVERGED"
STEP=""               # duel: init|codex|finalize (empty -> init); guard: verify
CLAUDE_MODEL=""       # claude-side model; empty => omit --model (inherit session model)

# Flags that must survive across separate --step invocations are persisted in
# $TASK_DIR/duel.env at init; *_SET tracks "explicitly passed this run" so a
# CLI flag always beats the persisted value.
TASK_SET=0; CODE_SET=0; ROUNDS_SET=0; BASE_SET=0; MAXB_SET=0
MODEL_SET=0; EFFORT_SET=0; FAST_SET=0; CLMODEL_SET=0; BUDGET_SET=0

# Codex model / reasoning effort / speed — overridable per run; passed through
# to the bridge (via env) and to `codex exec review`.
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_EFFORT="${CODEX_EFFORT:-xhigh}"
CODEX_FAST="${CODEX_FAST:-}"

OVERALL_RESULT="PASS"
TEST_RESULT="NOT RUN"
FAILING_COMMAND=""
FIX_USED=0

usage() {
  cat >&2 <<USAGE
codex-bridge v$KIT_VERSION
usage: bash codex-bridge/codex_loop.sh --mode <build|guard|duel> [--task <id>]
       [--base <branch>] [--test '<cmd>'] [--spec <file>]
       [--model <m>] [--effort <low|medium|high|xhigh>] [--fast]
       [--dry-run] [--teardown]
       build: [--fix-rounds N] [--claude-review]
       guard: [--spec <file>] [--step verify]
       duel:  [--auto] [--rounds N] [--code] [--seed <file>] [--prompt <file>]
              [--step init|codex|finalize] [--claude-model <m>] [--budget-usd <amt>]
              [--max-bytes N] [--no-arbiter]

Modes:
  build   Codex implements, tests are fed back for bounded fix rounds
          (--fix-rounds, default 2), Codex self-reviews, and --claude-review
          adds a headless-Claude cross-review + a Codex fix-or-rebut round.
  guard   Claude already edited; Codex reviews hard over threaded rounds and
          emits a CX-NN findings ledger. After you write reconciliation.md,
          '--task <id> --step verify' makes Codex re-check every fix/waiver
          on the SAME thread and rule VERDICT: CLEAN or REOPEN.
  duel    Mutual-critique DEBATE loop with an INDEPENDENT round 0 (no
          cross-feed), convergence only after a real exchange, and a
          fresh-context arbiter on non-convergence. Default is me-driven
          (the live Claude debates; step it with --step; flags persist in
          duel.env so later steps only need --task). --auto runs unattended
          and REQUIRES --seed. --code lets Codex edit in a worktree ONLY
          (never the main tree; never auto-merged).

Model/speed:
  --model <m>     Codex model id (default gpt-5.5)
  --effort <e>    reasoning effort: low|medium|high|xhigh (default xhigh; the
                  claude side has no xhigh and is clamped to high)
  --fast          priority service tier (faster turnaround, same model/effort)

Other:
  --dry-run       write every prompt to the task dir and print the commands
                  that WOULD run, without any paid model call
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
    --mode)          require_value "$@"; MODE="$2"; shift 2 ;;
    --task)          require_value "$@"; TASK_ID="$2"; TASK_SET=1; shift 2 ;;
    --base)          require_value "$@"; BASE="$2"; BASE_SET=1; shift 2 ;;
    --test)          require_value "$@"; TEST_CMD="$2"; TEST_CMD_SET=1; shift 2 ;;
    --spec)          require_value "$@"; SPEC_FILE="$2"; shift 2 ;;
    --model)         require_value "$@"; CODEX_MODEL="$2"; MODEL_SET=1; shift 2 ;;
    --effort)        require_value "$@"; CODEX_EFFORT="$2"; EFFORT_SET=1; shift 2 ;;
    --fast)          CODEX_FAST=1; FAST_SET=1; shift ;;
    --fix-rounds)    require_value "$@"; FIX_ROUNDS="$2"; shift 2 ;;
    --claude-review) CLAUDE_REVIEW=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --teardown)      TEARDOWN=1; shift ;;
    --auto)          AUTO=1; shift ;;
    --rounds)        require_value "$@"; ROUNDS="$2"; ROUNDS_SET=1; shift 2 ;;
    --code)          CODE=1; CODE_SET=1; shift ;;
    --no-arbiter)    ARBITER=0; shift ;;
    --seed)          require_value "$@"; SEED_FILE="$2"; shift 2 ;;
    --prompt)        require_value "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --budget-usd)    require_value "$@"; BUDGET_USD="$2"; BUDGET_SET=1; shift 2 ;;
    --max-bytes)     require_value "$@"; MAX_BYTES="$2"; MAXB_SET=1; shift 2 ;;
    --claude-model)  require_value "$@"; CLAUDE_MODEL="$2"; CLMODEL_SET=1; shift 2 ;;
    --step)          require_value "$@"; STEP="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; die "unknown argument: $1" ;;
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

case "$FIX_ROUNDS" in
  *[!0-9]*|"") die "--fix-rounds must be an integer >= 0" ;;
esac

case "$MAX_BYTES" in
  ""|*[!0-9]*) die "--max-bytes must be a positive integer" ;;
  *) [ "$MAX_BYTES" -ge 1 ] || die "--max-bytes must be >= 1" ;;
esac

if [ -n "$STEP" ]; then
  case "$MODE:$STEP" in
    duel:init|duel:codex|duel:finalize|guard:verify) ;;
    *) die "--step $STEP is not valid for --mode $MODE (duel: init|codex|finalize; guard: verify)" ;;
  esac
  # Auto-minted task ids embed THIS process's PID, so a later step can never
  # find the earlier task's state — require the explicit id.
  if [ "$STEP" != "init" ] && [ "$TASK_SET" -eq 0 ]; then
    die "--step $STEP requires --task <id> (task ids are minted per invocation)"
  fi
fi

if [ "$TEST_CMD_SET" -eq 1 ] && [ -z "$TEST_CMD" ]; then
  die "--test cannot be empty"
fi

[ -f "$BRIDGE" ] || die "bridge not found next to this script: $BRIDGE"

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
PROMPTS_DIR="$TASK_DIR/prompts"
JOURNAL="$TASK_DIR/journal.md"
DUEL_ENV="$TASK_DIR/duel.env"
DUEL_BRANCH="codex/duel-$TASK_ID"
DUEL_WORKTREE="../codex-duel-$TASK_ID"

# Persistent cross-task memory: decisions, changes, and open points from prior
# runs, injected into every fresh-context prompt so no model starts blind.
MEMORY_FILE="$REPO_ROOT/tmp/codex/memory.md"
MEMORY_TAIL_BYTES="${MEMORY_TAIL_BYTES:-10000}"

if [ "$TEARDOWN" -eq 1 ]; then
  [ "$MODE" = "duel" ] || die "--teardown is only valid with --mode duel"
  # Without the original --task the minted id (contains THIS pid) names a
  # nonexistent worktree/branch and the teardown would silently no-op.
  [ "$TASK_SET" -eq 1 ] || die "--teardown requires --task <id> (the id printed at init)"
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

# ---------------------------------------------------------------------------
# Duel config persistence: every --step call is a separate process, so without
# this, flags silently reset to defaults mid-debate (--code flips Codex to
# read-only, --rounds reverts to 4, a resumed session switches model, ...).
# init writes duel.env; later steps load it; explicit CLI flags still win.
# ---------------------------------------------------------------------------
save_duel_env() {
  {
    printf 'CODE=%q\n'         "$CODE"
    printf 'ROUNDS=%q\n'       "$ROUNDS"
    printf 'BASE=%q\n'         "$BASE"
    printf 'MAX_BYTES=%q\n'    "$MAX_BYTES"
    printf 'CODEX_MODEL=%q\n'  "$CODEX_MODEL"
    printf 'CODEX_EFFORT=%q\n' "$CODEX_EFFORT"
    printf 'CODEX_FAST=%q\n'   "$CODEX_FAST"
    printf 'CLAUDE_MODEL=%q\n' "$CLAUDE_MODEL"
    printf 'BUDGET_USD=%q\n'   "$BUDGET_USD"
    printf 'CONV_TOKEN=%q\n'   "$CONV_TOKEN"
  } > "$DUEL_ENV" 2>/dev/null || true
}

load_duel_env() {
  [ -f "$DUEL_ENV" ] || return 0
  # Values were written with %q by save_duel_env, so a prefixed eval is safe.
  eval "$(sed 's/^/P_/' "$DUEL_ENV")"
  [ "$CODE_SET"   -eq 0 ] && CODE="${P_CODE:-$CODE}"
  [ "$ROUNDS_SET" -eq 0 ] && ROUNDS="${P_ROUNDS:-$ROUNDS}"
  [ "$BASE_SET"   -eq 0 ] && BASE="${P_BASE:-$BASE}"
  [ "$MAXB_SET"   -eq 0 ] && MAX_BYTES="${P_MAX_BYTES:-$MAX_BYTES}"
  [ "$MODEL_SET"  -eq 0 ] && CODEX_MODEL="${P_CODEX_MODEL:-$CODEX_MODEL}"
  [ "$EFFORT_SET" -eq 0 ] && CODEX_EFFORT="${P_CODEX_EFFORT:-$CODEX_EFFORT}"
  [ "$FAST_SET"   -eq 0 ] && CODEX_FAST="${P_CODEX_FAST:-}"
  [ "$CLMODEL_SET" -eq 0 ] && CLAUDE_MODEL="${P_CLAUDE_MODEL:-}"
  [ "$BUDGET_SET" -eq 0 ] && BUDGET_USD="${P_BUDGET_USD:-}"
  CONV_TOKEN="${P_CONV_TOKEN:-$CONV_TOKEN}"
  # A CLI override on a later step becomes the new persisted truth.
  save_duel_env
  return 0
}

if [ "$MODE" = "duel" ] && [ -n "$STEP" ] && [ "$STEP" != "init" ]; then
  load_duel_env
fi

# Pass model/effort/speed to the bridge child processes (after duel.env load so
# a resumed thread keeps its original model/effort).
export CODEX_MODEL CODEX_EFFORT CODEX_FAST

git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base not found: $BASE"
mkdir -p "$TASK_DIR" "$BRIDGE_DIR" "$PROMPTS_DIR" || die "cannot create task directories"

# --- Token accounting setup ------------------------------------------------
# Per-task ledger; the bridge appends Codex rows, the loop appends review +
# headless-Claude rows, and each SUMMARY renders the breakdown.
CODEX_USAGE_LEDGER="$TASK_DIR/usage.tsv"
export CODEX_USAGE_LEDGER
# JSON parser for Claude headless --output-format json (python preferred).
CLAUDE_USAGE_PY="$(command -v python 2>/dev/null || command -v py 2>/dev/null || true)"
# Truncate on a fresh start; APPEND across me-driven duel steps and guard
# verify so the per-task total spans the whole conversation.
_usage_fresh=1
if [ "$MODE" = "duel" ] && [ "${AUTO:-0}" -ne 1 ]; then
  case "${STEP:-init}" in init|"") _usage_fresh=1 ;; *) _usage_fresh=0 ;; esac
fi
if [ "$MODE" = "guard" ] && [ "$STEP" = "verify" ]; then _usage_fresh=0; fi
[ "$_usage_fresh" -eq 1 ] && : > "$CODEX_USAGE_LEDGER"

# Snapshot the INTERACTIVE Claude Code session's transcript offsets so
# `claude_usage.sh end <task>` can record the UI-side tokens for this task
# (idempotent: keeps an earlier manual `begin`).
if [ "$DRY_RUN" -eq 0 ] && [ "$_usage_fresh" -eq 1 ]; then
  bash "$SCRIPT_DIR/claude_usage.sh" begin "$TASK_ID" >/dev/null 2>&1 || true
fi

# --- Journal + memory (the "never blind" layer) ------------------------------
journal() {
  printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')" "$*" >> "$JOURNAL" 2>/dev/null || true
}

memory_section() {
  if [ -s "$MEMORY_FILE" ]; then
    printf '=== BRIDGE MEMORY (decisions & changes from PRIOR tasks in this repo — do not redo or contradict them without saying why) ===\n'
    printf '(sliding window: only the LAST %s bytes of the full append-only history at %s. If a past decision, change, or task you need is not visible below, READ or grep that file directly — you have read access to it.)\n\n' \
      "$MEMORY_TAIL_BYTES" "$MEMORY_FILE"
    tail_bytes "$MEMORY_FILE" "$MEMORY_TAIL_BYTES"
    printf '\n\n'
  fi
}

journal_section() {
  if [ -s "$JOURNAL" ]; then
    printf '=== TASK JOURNAL (everything that already happened in THIS task) ===\n'
    tail_bytes "$JOURNAL" "$MAX_BYTES"
    printf '\n\n'
  fi
}

changed_files_list() {
  if [ "$MODE" = "duel" ] && [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    { git -C "$DUEL_WORKTREE" diff --name-only "$BASE" -- 2>/dev/null
      git -C "$DUEL_WORKTREE" ls-files --others --exclude-standard 2>/dev/null; } | sort -u
  else
    { git diff --name-only "$BASE" -- 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
  fi
}

# Append a compact digest of this run to the persistent memory so FUTURE tasks
# (both models) know what changed and what was decided.
memory_append_run() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$(dirname "$MEMORY_FILE")" 2>/dev/null || true
  {
    printf '\n## %s — task %s (mode %s, %s/%s) — %s\n' \
      "$(date -u +%Y-%m-%d 2>/dev/null || echo '-')" "$TASK_ID" "$MODE" \
      "$CODEX_MODEL" "$CODEX_EFFORT" "$OVERALL_RESULT"
    if [ -n "$SPEC_CONTENT" ]; then
      printf 'intent: %s\n' "$(printf '%s' "$SPEC_CONTENT" | head -2 | tr '\n' ' ')"
    fi
    printf 'changed files:\n'
    changed_files_list | head -30 | sed 's/^/- /'
    for f in review.md findings.md verify.md claude_review.md codex_response.md final.md arbiter.md; do
      if [ -s "$TASK_DIR/$f" ]; then
        printf 'from %s:\n' "$f"
        head -c 1000 "$TASK_DIR/$f" | sed 's/^/  /'
        printf '\n'
      fi
    done
    printf '(full artifacts: %s/)\n' "$TASK_DIR_REL"
  } >> "$MEMORY_FILE" 2>/dev/null || true
}

# --- Spec / prompt builders --------------------------------------------------
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
  printf 'You are planning a change TOGETHER with Claude (who drafted the spec below). Critique it before any edits: identify risks, edge cases, missing tests, and better alternatives — and propose concrete improvements, do not just approve. Do not modify files.\n\n'
  printf 'End with two sections: "PROPOSED SPEC CHANGES" (what you would amend and why) and "OPEN QUESTIONS FOR CLAUDE" (numbered; write "none" if empty).\n\n'
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  memory_section
  printf 'SPEC:\n%s\n' "$SPEC_CONTENT"
}

prompt_build() {
  printf 'Implement the spec AND address your own critique above. Where you raised OPEN QUESTIONS, adopt the most reasonable answer and STATE which you chose. Edit only source files.\n\n'
  printf '%s\n\n' "$SHARE_LINE"
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  printf 'SPEC:\n%s\n' "$SPEC_CONTENT"
}

prompt_fix() {
  printf 'The test command FAILED after your implementation. Diagnose from the output below and FIX the code so it passes. Do not weaken, skip, or delete tests to make them pass — fix the code (or say explicitly why the test itself is wrong).\n\n'
  printf '%s\n\n' "$SHARE_LINE"
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  printf 'COMMAND: %s\n\n=== TEST OUTPUT (tail) ===\n' "$TEST_CMD"
  tail -c "$MAX_BYTES" "$TASK_DIR/test.log" 2>/dev/null || printf '(no test log)\n'
}

prompt_guard_review() {
  printf 'Review the UNCOMMITTED changes in this repo. Run `git status` to list them, `git diff %s` to see MODIFIED files, and read any NEW/untracked files in full (plain `git diff` does not show untracked content). Report correctness bugs, missing tests, and risky edge cases with concrete file:line references. Also ask numbered "QUESTIONS FOR CLAUDE" about anything whose intent is unclear. Do not modify files.\n\n' "$BASE"
  if [ -n "$SPEC_CONTENT" ]; then
    printf '=== INTENT (what this change is SUPPOSED to do — judge the diff against it) ===\n%s\n\n' "$SPEC_CONTENT"
    printf 'Flag both: requirements NOT implemented, and implemented behavior that was NOT required.\n\n'
  fi
  memory_section
  printf '=== CHANGE INVENTORY (computed by the bridge) ===\n'
  { git status --porcelain 2>/dev/null; echo; git diff --stat "$BASE" -- 2>/dev/null; } | head -c "$MAX_BYTES"
  printf '\n\n%s\n' "$GUARD_LINE"
}

prompt_guard_findings() {
  printf 'Go deeper: enumerate EVERY concrete finding for the diff vs %s (correctness bugs, race/edge cases, missing tests) as a RECONCILIATION LEDGER with EXACTLY this grammar, one line per finding:\n' "$BASE"
  printf -- '- [ ] CX-01 | BLOCKER|MAJOR|MINOR | <file>:<line> | <one-line summary>\n'
  printf '(supporting detail may follow indented under each line; number findings sequentially).\nEnd with the single line: TOTAL: <n>\n\n'
  printf '%s\n' "$GUARD_LINE"
}

prompt_guard_verify() {
  printf 'Claude has reconciled your findings. Below are your findings ledger and Claude'\''s reconciliation. For EACH finding: if marked FIXED, verify the fix in the CURRENT uncommitted diff yourself (re-run `git status` / `git diff %s`, read the files) and cite file:line evidence; if marked WAIVED, reply AGREE or CONTEST with one concrete reason. Also flag any NEW regression the fixes introduced. Be adversarial — do not rubber-stamp.\n\n' "$BASE"
  printf 'End with the single line:  VERDICT: CLEAN\nor:                         VERDICT: REOPEN CX-.. CX-..   (every finding that is not settled)\n\n'
  printf '%s\n\n' "$GUARD_LINE"
  printf '=== YOUR FINDINGS ===\n'
  truncate_bytes "$TASK_DIR/findings.md" "$MAX_BYTES"
  printf '\n=== CLAUDE RECONCILIATION ===\n'
  truncate_bytes "$TASK_DIR/reconciliation.md" "$MAX_BYTES"
  printf '\n'
  journal_section
}

build_claude_review_prompt() {
  printf 'You are CLAUDE, cross-reviewing code that CODEX (a GPT model) just wrote against the spec below. You have Read/Grep/Glob tools — read the changed files for full context; the diff below may be truncated. Report ONLY defects that matter: correctness bugs, spec violations, missing/weak tests, risky edge cases.\n\n'
  printf 'Use EXACTLY this grammar, one line per finding:\n- [ ] CX-01 | BLOCKER|MAJOR|MINOR | <file>:<line> | <one-line summary>\nEnd with the single line: FINDINGS TOTAL: <n>   (0 if the diff is clean)\n\n'
  memory_section
  printf '=== SPEC ===\n%s\n\n' "$SPEC_CONTENT"
  printf '=== CODEX BUILD NOTES (what Codex says it did) ===\n'
  truncate_bytes "$TASK_DIR/build.md" "$MAX_BYTES"
  printf '\n=== DIFF vs %s (may be truncated) ===\n' "$BASE"
  git diff "$BASE" -- 2>/dev/null | head -c "$MAX_BYTES"
  printf '\n=== UNTRACKED (new) FILES — read them in full ===\n'
  git ls-files --others --exclude-standard 2>/dev/null
  if [ "$TEST_CMD_SET" -eq 1 ]; then
    printf '\n=== TEST RESULT ===\ncommand: %s\nresult: %s\n' "$TEST_CMD" "$TEST_RESULT"
    [ -f "$TASK_DIR/test.log" ] && { printf 'output tail:\n'; tail -c 4000 "$TASK_DIR/test.log" 2>/dev/null; }
  fi
  printf '\n'
  journal_section
}

prompt_codex_response() {
  printf 'Claude cross-reviewed your work; its findings are below. For EACH finding: FIX it (edit the files) if valid, or REBUT it with a concrete reason if not. Do not silently skip any. Then summarize per finding on one line each: CX-NN -> FIXED (what you changed) | REBUTTED (why).\n\n'
  printf '%s\n\n' "$SHARE_LINE"
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  printf '=== CLAUDE REVIEW ===\n'
  truncate_bytes "$TASK_DIR/claude_review.md" "$MAX_BYTES"
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
  # Persist the fully-assembled prompt as a task artifact (it is the single most
  # useful debugging record of what each side actually saw). Calling the bridge
  # by ABSOLUTE path so duel mode (cwd = worktree) still runs THIS kit's bridge.
  local _label; _label="$(basename "$dest")"; _label="${_label%.*}"
  local pfile="$PROMPTS_DIR/${_label}.prompt.md"
  "$prompt_fn" > "$pfile"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run: bash codex-bridge/codex_bridge.sh $bridge_mode $* (model=$CODEX_MODEL effort=$CODEX_EFFORT fast=${CODEX_FAST:+on})"
    echo "DRY-RUN: prompt persisted at $pfile"
    printf '(dry run — no codex call was made)\n' > "$dest"
    journal "DRY-RUN $_label (prompt at prompts/${_label}.prompt.md)"
    return 0
  fi
  CODEX_USAGE_LABEL="$_label" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$bridge_mode" "$@" < "$pfile" > "$log" 2>&1
  rc=$?
  copy_last_message "$dest"
  journal "codex $_label rc=$rc -> $(basename "$dest")"
  return "$rc"
}

run_review() {
  out="$1"
  log="$2"

  : > "$out"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run: codex exec review --uncommitted -m $CODEX_MODEL (effort=$CODEX_EFFORT)"
    printf '(dry run)\n' > "$out"
    return 0
  fi
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
  command -v usage_record_codex >/dev/null 2>&1 \
    && usage_record_codex "$CODEX_USAGE_LEDGER" review "" "$log" "$rc" "$CODEX_MODEL" 2>/dev/null || true
  journal "codex self-review rc=$rc -> review.md"
  return "$rc"
}

run_test() {
  log="$1"
  : > "$log"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run test: $TEST_CMD"
    TEST_RESULT="NOT RUN (dry run)"
    return 0
  fi
  bash -c "$TEST_CMD" > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    TEST_RESULT="PASS"
  else
    TEST_RESULT="FAIL"
    OVERALL_RESULT="FAIL (test)"
    FAILING_COMMAND="$TEST_CMD"
    echo "--- test output tail ---"
    tail -n 20 "$log" 2>/dev/null || true
  fi
  journal "test '$TEST_CMD' -> $TEST_RESULT"
  return "$rc"
}

write_status() {
  # Capture git's OWN exit code first (a command substitution ending in
  # `sort -u` would report sort's rc and silently mask a git failure).
  git diff --name-only "$BASE" -- >/dev/null 2>&1
  changed_rc=$?
  changed_files="$(changed_files_list)"

  {
    printf 'kit: codex-bridge v%s\n' "$KIT_VERSION"
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
    if [ "$FIX_USED" -gt 0 ]; then
      printf 'fix rounds used: %s\n' "$FIX_USED"
    fi
    if [ -n "$FAILING_COMMAND" ]; then
      printf 'failing command: %s\n' "$FAILING_COMMAND"
    fi
  } > "$TASK_DIR/status.md"
}

# Render the per-task token breakdown to stdout (in every SUMMARY) and to
# $TASK_DIR/usage.md. The INTERACTIVE Claude session is recorded separately:
# run `claude_usage.sh end <task>` when the task is done.
emit_token_summary() {
  {
    echo "# Token usage — task $TASK_ID"
    echo
    echo '```'
    usage_report "$CODEX_USAGE_LEDGER"
    echo '```'
    if [ "$MODE" = build ] || [ "$MODE" = guard ]; then
      echo
      echo "_Note: the interactive Claude Code session records itself via_"
      echo "_\`bash codex-bridge/claude_usage.sh end $TASK_ID\` — run it when the task is done._"
    fi
  } > "$TASK_DIR/usage.md" 2>/dev/null || true
  echo ""
  echo "TOKENS (task $TASK_ID):"
  usage_report "$CODEX_USAGE_LEDGER"
  if [ "$MODE" = build ] || [ "$MODE" = guard ]; then
    echo "  note: record the interactive Claude session with: bash codex-bridge/claude_usage.sh end $TASK_ID"
  fi
}

print_build_summary() {
  echo "SUMMARY (codex-bridge v$KIT_VERSION)"
  echo "mode: $MODE  model: $CODEX_MODEL  effort: $CODEX_EFFORT  fast: ${CODEX_FAST:+on}"
  [ "$DRY_RUN" -eq 1 ] && echo "DRY RUN — no model calls were made; prompts are under $TASK_DIR_REL/prompts/"
  echo "artifacts: $TASK_DIR_REL"
  echo "status: $OVERALL_RESULT"
  [ "$FIX_USED" -gt 0 ] && echo "fix rounds used: $FIX_USED"
  if [ -n "$FAILING_COMMAND" ]; then
    echo "failing command: $FAILING_COMMAND"
  fi
  if [ -s "$TASK_DIR/claude_review.md" ]; then
    echo "cross-review: $TASK_DIR_REL/claude_review.md (Codex's fix-or-rebut: codex_response.md)"
  fi
  if [ -s "$TASK_DIR/review.md" ]; then
    echo "NEXT: Claude reviews \`git diff $BASE\` and adjudicates Codex findings in $TASK_DIR_REL/review.md"
  else
    echo "NEXT: build did not reach review — see $TASK_DIR_REL/status.md and *.log for the failure"
  fi
  emit_token_summary
}

print_guard_summary() {
  echo "SUMMARY (codex-bridge v$KIT_VERSION)"
  echo "mode: guard  model: $CODEX_MODEL  effort: $CODEX_EFFORT  fast: ${CODEX_FAST:+on}"
  [ "$DRY_RUN" -eq 1 ] && echo "DRY RUN — no model calls were made; prompts are under $TASK_DIR_REL/prompts/"
  echo "artifacts: $TASK_DIR_REL"
  echo "status: $OVERALL_RESULT"
  if [ -n "$FAILING_COMMAND" ]; then
    echo "failing command: $FAILING_COMMAND"
  fi
  if [ "$STEP" = "verify" ]; then
    if [ -s "$TASK_DIR/verify.md" ]; then
      VERDICT_LINE="$(grep -aoE 'VERDICT: *[A-Z][^\r]*' "$TASK_DIR/verify.md" 2>/dev/null | tail -1)"
      echo "verify: ${VERDICT_LINE:-no VERDICT line found — read $TASK_DIR_REL/verify.md}"
      case "$VERDICT_LINE" in
        *REOPEN*) echo "NEXT: fix the reopened findings, update reconciliation.md, and re-run --step verify" ;;
        *CLEAN*)  echo "NEXT: done — declare the task finished and run: bash codex-bridge/claude_usage.sh end $TASK_ID" ;;
        *)        echo "NEXT: read $TASK_DIR_REL/verify.md and settle the remaining points" ;;
      esac
    fi
  else
    echo "NEXT: 1) write $TASK_DIR_REL/reconciliation.md — one line per finding:"
    echo "         CX-NN: FIXED — <what you changed>   |   CX-NN: WAIVED — <reason>"
    echo "      2) then have Codex verify your fixes on the same thread:"
    echo "         bash codex-bridge/codex_loop.sh --mode guard --task $TASK_ID --step verify"
  fi
  emit_token_summary
}

print_duel_summary() {
  echo "SUMMARY (codex-bridge v$KIT_VERSION)"
  echo "mode: duel  auto: $([ "$AUTO" -eq 1 ] && echo on || echo off)  code: $([ "$CODE" -eq 1 ] && echo on || echo off)"
  echo "codex: $CODEX_MODEL/$CODEX_EFFORT${CODEX_FAST:+/fast}   claude: ${CLAUDE_MODEL:-session}/$(claude_effort)"
  echo "artifacts: $TASK_DIR_REL  (transcript.md = full debate, final.md = answer)"
  echo "rounds run: $(cat "$ROUND_FILE" 2>/dev/null || echo 0)/$ROUNDS   end: $END_REASON"
  echo "status: $OVERALL_RESULT"
  [ -s "$TASK_DIR/arbiter.md" ] && echo "arbiter: fresh-context ruling in $TASK_DIR_REL/arbiter.md"
  if [ "$AUTO" -eq 1 ]; then
    if [ -s "$TASK_DIR/final.md" ]; then
      echo "NEXT: read $TASK_DIR_REL/final.md (converged answer); full debate in transcript.md"
    else
      echo "NEXT: debate did not finalize — see $TASK_DIR_REL/status.md and rounds/*.log"
    fi
    [ "$CODE" -eq 1 ] && echo "Codex edits live in worktree $DUEL_WORKTREE (git -C $DUEL_WORKTREE diff $BASE). Claude did NOT auto-merge."
  else
    echo "me-driven step '${STEP:-init}' done. Loop: write claude_latest.md -> --step codex -> read codex_latest.md; then --step finalize."
  fi
  emit_token_summary
}

run_consult_build() {
  echo "=== consult (Codex critiques the plan) ==="
  if ! run_bridge consult "$TASK_DIR/consult.md" "$TASK_DIR/consult.log" prompt_consult; then
    OVERALL_RESULT="FAIL (consult)"
    FAILING_COMMAND="codex_bridge.sh consult"
    return 1
  fi

  echo "=== build (Codex implements, threaded) ==="
  if ! run_bridge build "$TASK_DIR/build.md" "$TASK_DIR/build.log" prompt_build --resume; then
    OVERALL_RESULT="FAIL (build)"
    FAILING_COMMAND="codex_bridge.sh build --resume"
    return 1
  fi

  return 0
}

run_build_mode() {
  read_spec
  journal "build task started; spec ${#SPEC_CONTENT} chars; codex $CODEX_MODEL/$CODEX_EFFORT; test: ${TEST_CMD:-none}"

  if ! run_consult_build; then
    write_status
    print_build_summary
    return 1
  fi

  # Test + bounded repair loop: a red test is the strongest ground-truth signal
  # the kit produces — feed it back into the SAME Codex thread instead of
  # discarding it.
  if [ "$TEST_CMD_SET" -eq 1 ]; then
    echo "=== test ==="
    if ! run_test "$TASK_DIR/test.log"; then
      i=1
      while [ "$i" -le "$FIX_ROUNDS" ]; do
        echo "=== fix round $i/$FIX_ROUNDS (test output fed back to Codex) ==="
        if ! run_bridge build "$TASK_DIR/fix-r$i.md" "$TASK_DIR/fix-r$i.log" prompt_fix --resume; then
          OVERALL_RESULT="FAIL (fix round $i)"
          FAILING_COMMAND="codex_bridge.sh build --resume (fix)"
          write_status
          print_build_summary
          return 1
        fi
        FIX_USED=$((FIX_USED + 1))
        echo "=== re-test (after fix round $i) ==="
        TEST_RESULT="NOT RUN"; OVERALL_RESULT="PASS"; FAILING_COMMAND=""
        run_test "$TASK_DIR/test.log" && break
        i=$((i + 1))
      done
      if [ "$TEST_RESULT" = "FAIL" ]; then
        OVERALL_RESULT="FAIL (test, after $FIX_USED fix round(s))"
        FAILING_COMMAND="$TEST_CMD"
      fi
    fi
  fi

  echo "=== review (codex self-review, advisory) ==="
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

  # Cross-review: PROTOCOL says the OTHER model reviews the diff. The self-review
  # above shares Codex's blind spots; a scripted headless-Claude review does not
  # (and finally records Claude-side tokens in build mode). Findings go BACK to
  # the same Codex thread for a fix-or-rebut round: nothing is silently dropped.
  if [ "$CLAUDE_REVIEW" -eq 1 ]; then
    echo "=== cross-review (headless Claude reviews Codex's diff) ==="
    if run_claude_once "$TASK_DIR/claude_review.md" "$TASK_DIR/claude_review.log" build_claude_review_prompt claude-review; then
      nfind="$(grep -aoE 'FINDINGS TOTAL: *[0-9]+' "$TASK_DIR/claude_review.md" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)"
      if [ -z "$nfind" ]; then
        nfind="$(grep -acE '^- \[ \] CX-[0-9]+' "$TASK_DIR/claude_review.md" 2>/dev/null || true)"
      fi
      nfind="${nfind:-0}"
      journal "claude cross-review findings: $nfind"
      if [ "$nfind" -gt 0 ] 2>/dev/null; then
        echo "=== codex response round (fix-or-rebut Claude's $nfind finding(s)) ==="
        if ! run_bridge build "$TASK_DIR/codex_response.md" "$TASK_DIR/codex_response.log" prompt_codex_response --resume; then
          OVERALL_RESULT="FAIL (codex response)"
          FAILING_COMMAND="codex_bridge.sh build --resume (response)"
          write_status
          print_build_summary
          return 1
        fi
        if [ "$TEST_CMD_SET" -eq 1 ]; then
          echo "=== final re-test (after response round) ==="
          TEST_RESULT="NOT RUN"
          run_test "$TASK_DIR/test.log" || OVERALL_RESULT="FAIL (test after response round)"
        fi
      fi
    else
      echo "codex_loop: WARNING: claude cross-review failed; see $TASK_DIR_REL/claude_review.log" >&2
    fi
  fi

  write_status
  memory_append_run
  print_build_summary
  case "$OVERALL_RESULT" in PASS*) return 0 ;; *) return 1 ;; esac
}

run_guard_verify() {
  [ -s "$TASK_DIR/findings.md" ] || die "no findings.md for task $TASK_ID — run the guard review first"
  [ -s "$TASK_DIR/reconciliation.md" ] || die "write $TASK_DIR_REL/reconciliation.md first: one line per finding, 'CX-NN: FIXED — <what>' or 'CX-NN: WAIVED — <reason>'"

  echo "=== verify (threaded — Codex re-checks Claude's fixes and waivers) ==="
  if ! run_bridge consult "$TASK_DIR/verify.md" "$TASK_DIR/verify.log" prompt_guard_verify --resume; then
    OVERALL_RESULT="FAIL (verify)"
    FAILING_COMMAND="codex_bridge.sh consult --resume (guard verify)"
    write_status
    print_guard_summary
    return 1
  fi
  write_status
  memory_append_run
  print_guard_summary
  return 0
}

run_guard_mode() {
  if [ "$STEP" = "verify" ]; then
    run_guard_verify
    return $?
  fi

  # Optional intent seeding: a reviewer who knows what the change was SUPPOSED
  # to do catches spec-violation bugs an intent-blind reviewer cannot.
  if [ -n "$SPEC_FILE" ]; then
    read_spec
    journal "guard intent loaded from $SPEC_FILE (${#SPEC_CONTENT} chars)"
  fi

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
  # later rounds' --resume thread off THIS review rather than a stale prior
  # session (a direct `codex exec review` bypasses the bridge and never records
  # a session).
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
# Duel = continuous mutual-critique DEBATE loop. Claude and Codex answer the
# SAME task, share findings, critique each other every round, and converge.
#   round 0 is INDEPENDENT (no cross-feed) so the two answers are uncorrelated;
#   cross-critique starts at round 1; CONVERGED counts only from round 1 on;
#   a fresh-context ARBITER rules on any disagreement left at the end.
# Two ways to run: default (me-driven, the LIVE Claude session debates, stepped
# by --step; config persists in duel.env) or --auto (unattended claude -p <->
# Codex, both pre-seeded so neither side starts blind). Read-only by default;
# --code lets Codex edit in a worktree ONLY (never auto-merged).
# ===========================================================================

ROUNDS_DIR="$TASK_DIR/rounds"
TRANSCRIPT="$TASK_DIR/transcript.md"
PROMPT_STORE="$TASK_DIR/prompt.md"
SEED_STORE="$TASK_DIR/seed.md"
CLAUDE_LATEST="$TASK_DIR/claude_latest.md"
CODEX_LATEST="$TASK_DIR/codex_latest.md"
ROUND_FILE="$TASK_DIR/round.txt"        # stores the COMPLETED round count
SID_FILE="$TASK_DIR/claude_session_id"
END_REASON="round-cap"

# Persona injected into every headless Claude turn (no apostrophes -> safe to
# keep single-quoted).
CLAUDE_PERSONA='You are the CLAUDE participant in a two-model mutual-critique debate with Codex (a GPT model). Each round: (1) share ALL new findings/evidence with file:line or URLs — hold nothing back, your counterpart must see everything you saw; (2) critique the SPECIFIC claims Codex made and say why; (3) revise your own position and concede what you got wrong; (4) give your current best answer. Be terse and concrete. End every turn with the line "DISAGREEMENTS REMAINING: <n>" listing n concrete points. If nothing material remains to add AND n=0, output the single line CONVERGED as the very last line.'

# A headless `claude -p` aborts with a nesting guard when CLAUDECODE et al. are
# inherited from this live session. Stripping these (verified on this box) lets
# the child launch cleanly.
claude_headless() {
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude "$@"
}

claude_perm()   { [ "$CODE" -eq 1 ] && echo acceptEdits || echo plan; }
claude_effort() { local e="$CODEX_EFFORT"; [ "$e" = xhigh ] && e=high; echo "$e"; }   # claude has no xhigh

# Split a `claude -p --output-format json` payload: write the reply text to $2
# and append a v2 Claude usage row (label $3) to the ledger $4. Returns non-zero
# if the JSON can't be parsed (caller falls back). Uses python (CLAUDE_USAGE_PY).
claude_json_split() {
  local jf="$1" of="$2" label="$3" ledger="$4" model="${5:-${CLAUDE_MODEL:-session}}"
  [ -n "$CLAUDE_USAGE_PY" ] || return 1
  local res
  res="$("$CLAUDE_USAGE_PY" - "$jf" "$of" "$ledger" "$label" "$model" <<'PYEOF'
import json, sys, time
jf, of, ledger, label, model = sys.argv[1:6]
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
inp = g("input_tokens")
cached = g("cache_read_input_tokens") + g("cache_creation_input_tokens")
out = g("output_tokens")
try:
    with open(ledger, "a", encoding="utf-8") as f:
        f.write("\t".join([str(int(time.time())),
                           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           "claude", model, label,
                           str(inp + cached + out), str(inp), str(cached), str(out),
                           "0"]) + "\n")
except Exception:
    pass
print("ok")
PYEOF
)"
  [ "$res" = "ok" ]
}

# ONE fresh headless-Claude call (no session threading): used for the build-mode
# cross-review. Prompt persists as a task artifact; usage lands in the ledger.
run_claude_once() {
  local out="$1" log="$2" builder="$3" label="$4" rc
  local pfile="$PROMPTS_DIR/${label}.prompt.md"
  "$builder" > "$pfile"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run headless claude ($label); prompt persisted at $pfile"
    printf '(dry run)\n' > "$out"
    return 0
  fi
  command -v claude >/dev/null 2>&1 || { echo "codex_loop: claude CLI not found — skipping $label" >&2; return 1; }
  local modelflag=();  [ -n "$CLAUDE_MODEL" ] && modelflag=(--model "$CLAUDE_MODEL")
  local budgetflag=(); [ -n "$BUDGET_USD" ]   && budgetflag=(--max-budget-usd "$BUDGET_USD")
  if [ -n "$CLAUDE_USAGE_PY" ]; then
    local jtmp; jtmp="$(mktemp)"
    claude_headless -p \
        --permission-mode plan \
        --tools "Read" "Grep" "Glob" \
        --effort "$(claude_effort)" \
        "${modelflag[@]}" "${budgetflag[@]}" \
        --output-format json \
        < "$pfile" > "$jtmp" 2>"$log"
    rc=$?
    [ "$rc" -eq 0 ] && claude_json_split "$jtmp" "$out" "$label" "$CODEX_USAGE_LEDGER"
    rm -f "$jtmp"
  else
    claude_headless -p \
        --permission-mode plan \
        --tools "Read" "Grep" "Glob" \
        --effort "$(claude_effort)" \
        "${modelflag[@]}" "${budgetflag[@]}" \
        --output-format text \
        < "$pfile" > "$out" 2>"$log"
    rc=$?
  fi
  journal "claude $label rc=$rc -> $(basename "$out")"
  [ "$rc" -ne 0 ] && return "$rc"
  [ -s "$out" ] || return 99
  return 0
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

# Round-0 Codex prompt (fresh thread). INDEPENDENT when no Claude message is
# passed: Codex must not be anchored on Claude's opening answer, or the two
# models' errors correlate and the debate loses its error-detection power.
build_codex_prompt() {
  local rnd="$1" claude_msg="$2"
  printf 'You and Claude independently solve the SAME task, then CRITIQUE each other every round to converge on ONE cross-checked answer. This is round %s of %s.\n\n' "$rnd" "$ROUNDS"
  if [ -n "$claude_msg" ] && [ -f "$claude_msg" ]; then
    printf 'Do your OWN reasoning first, then critique the latest Claude message below: name concrete errors, missed cases, better sources/approaches, AND anything Claude got right that you would adopt.\n'
  else
    printf 'This round is INDEPENDENT: you have NOT seen Claude'\''s answer and must not guess at it. Solve the task from scratch with your own reasoning and evidence; you will see and critique Claude from round 1.\n'
  fi
  printf 'Share ALL evidence you rely on (file:line, URLs, command results) — your counterpart must see everything you saw. End with (a) your current best answer, (b) a short "DISAGREEMENTS REMAINING" list (write "none yet" in an independent round), and if nothing material remains to add, the SINGLE line %s as the very last line.\n\n' "$CONV_TOKEN"
  printf '%s\n' "$GUARD_LINE"
  printf 'Do not run install commands, dev servers, or full builds.\n\n'
  memory_section
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
  printf 'Round %s of %s. Claude just replied below. Do your own check first, then critique it, adopt/fix as warranted, and give your updated best answer plus a short "DISAGREEMENTS REMAINING" list. Share ALL new evidence (file:line, URLs, command results). If nothing material remains AND the disagreement count is 0, output the SINGLE line %s as the very last line.\n\n' "$rnd" "$ROUNDS" "$CONV_TOKEN"
  printf '%s\n\n' "$GUARD_LINE"
  if [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    printf '=== CURRENT WORKTREE DIFF vs %s ===\n' "$BASE"
    ( git -C "$DUEL_WORKTREE" diff "$BASE" 2>/dev/null || true ) | head -c "$MAX_BYTES"
    printf '\n\n'
  fi
  printf '=== LATEST CLAUDE MESSAGE (round %s, may be truncated) ===\n' "$rnd"
  truncate_bytes "$claude_msg" "$MAX_BYTES"
}

# Run ONE Codex turn via the bridge (prompt persisted per round; no inline
# injection). In --code, run with cwd = the worktree so Codex edits land THERE.
# SAFETY: with --code the worktree MUST exist — otherwise 'build' mode would
# give Codex workspace-write on the user's MAIN tree.
# $1=round $2=resume(0|1) $3=path-to-latest-claude-message (empty = independent)
run_codex_turn() {
  local rnd="$1" resume="$2" claude_msg="$3" out log pfile rc
  out="$ROUNDS_DIR/$(rr "$rnd")-codex.md"
  log="$ROUNDS_DIR/$(rr "$rnd")-codex.log"
  pfile="$ROUNDS_DIR/$(rr "$rnd")-codex.prompt.md"
  if [ "$resume" -eq 1 ]; then
    build_codex_resume_prompt "$rnd" "$claude_msg" > "$pfile"
  else
    build_codex_prompt "$rnd" "$claude_msg" > "$pfile"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run one Codex duel turn (round $rnd, resume=$resume); prompt at $pfile"
    printf '(dry run)\n' > "$out"
    cp "$out" "$CODEX_LATEST" 2>/dev/null || true
    return 0
  fi
  if [ "$CODE" -eq 1 ] && [ ! -e "$DUEL_WORKTREE" ]; then
    die "--code is set but the duel worktree is missing ($DUEL_WORKTREE) — refusing to let Codex write to the main tree. Run '--step init' with --code, or drop --code."
  fi
  local resume_flag=()
  [ "$resume" -eq 1 ] && resume_flag=(--resume)
  local _clabel="duel-codex-r$rnd"
  if [ "$CODE" -eq 1 ] && [ -e "$DUEL_WORKTREE" ]; then
    ( cd "$DUEL_WORKTREE" && CODEX_USAGE_LABEL="$_clabel" CODEX_USAGE_LEDGER="$CODEX_USAGE_LEDGER" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$(codex_sandbox_mode)" "${resume_flag[@]}" < "$pfile" ) > "$log" 2>&1
  else
    CODEX_USAGE_LABEL="$_clabel" CODEX_BRIDGE_DIR="$BRIDGE_DIR" bash "$BRIDGE" "$(codex_sandbox_mode)" "${resume_flag[@]}" < "$pfile" > "$log" 2>&1
  fi
  rc=$?
  copy_last_message "$out"
  cp "$out" "$CODEX_LATEST" 2>/dev/null || true
  journal "duel codex round $rnd rc=$rc"
  return "$rc"
}

append_transcript() {
  local who="$1" rnd="$2" file="$3"
  { printf '\n## Round %s — %s\n\n' "$rnd" "$who"; cat "$file" 2>/dev/null; } >> "$TRANSCRIPT"
}

# Both sides of round r converged? (checks the per-round files, not the mutable
# *_latest.md copies, so me-driven consumption can't break detection)
round_converged() {
  local r="$1"
  converged_side "$ROUNDS_DIR/$(rr "$r")-claude.md" && converged_side "$ROUNDS_DIR/$(rr "$r")-codex.md"
}

# Run ONE headless Claude turn. Prompt persisted per round (NOT a pipe) so a
# writer-side SIGPIPE under pipefail cannot mask claude's real exit code.
# $1=round $2=set|resume $3=stdin-builder-fn
run_claude_turn() {
  local rnd="$1" idmode="$2" builder="$3" out log sid perm rc pfile
  out="$ROUNDS_DIR/$(rr "$rnd")-claude.md"
  log="$ROUNDS_DIR/$(rr "$rnd")-claude.log"
  pfile="$ROUNDS_DIR/$(rr "$rnd")-claude.prompt.md"
  sid="$(cat "$SID_FILE" 2>/dev/null)"
  [ -n "$sid" ] || { echo "codex_loop: missing claude session id" >&2; return 1; }

  # Claude is read-only in --code (Codex is the sole writer); force plan.
  perm="$(claude_perm)"
  [ "$CODE" -eq 1 ] && perm="plan"

  local idflag=(--session-id "$sid")
  [ "$idmode" = "resume" ] && idflag=(--resume "$sid")
  local modelflag=();  [ -n "$CLAUDE_MODEL" ] && modelflag=(--model "$CLAUDE_MODEL")
  local budgetflag=(); [ -n "$BUDGET_USD" ]   && budgetflag=(--max-budget-usd "$BUDGET_USD")

  "$builder" "$rnd" > "$pfile"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run one headless Claude duel turn (round $rnd); prompt at $pfile"
    printf '(dry run)\n' > "$out"
    cp "$out" "$CLAUDE_LATEST" 2>/dev/null || true
    return 0
  fi
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
        < "$pfile" > "$jtmp" 2>"$log"
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
        < "$pfile" > "$out" 2>"$log"
    rc=$?
  fi
  journal "duel claude round $rnd rc=$rc"
  [ "$rc" -ne 0 ] && return "$rc"
  [ -s "$out" ] || return 99
  cp "$out" "$CLAUDE_LATEST" 2>/dev/null || true
  return 0
}

claude_stdin_round0() {
  memory_section
  cat "$SEED_STORE" 2>/dev/null
  printf '\n\n=== TASK ===\n'
  cat "$PROMPT_STORE"
  printf '\n\n=== YOUR TURN (round %s of %s — INDEPENDENT) ===\nDo your own independent research and give your opening position. You have NOT seen Codex'\''s answer; you will see and critique it from round 1. Do not output %s in this round.\n' "$1" "$ROUNDS" "$CONV_TOKEN"
}

claude_stdin_resume() {
  local rnd="$1"
  printf 'Round %s of %s. Codex just replied below. Do your OWN check first, then critique its SPECIFIC claims, fix/adopt what is warranted, and give your updated best answer. Share ALL new evidence. End with "DISAGREEMENTS REMAINING: <n>"; if nothing material remains AND n=0, output the SINGLE line %s as the very last line.\n\n' "$rnd" "$ROUNDS" "$CONV_TOKEN"
  printf '=== CODEX LATEST (may be truncated) ===\n'
  truncate_bytes "$CODEX_LATEST" "$MAX_BYTES"
}

note_partial() { END_REASON="partial-failure-$1"; echo "codex_loop: partial failure ($1) at round $2 rc=$3; finalizing on partial output" >&2; }

write_duel_status() {
  local changed_files rounds_run
  changed_files="$(changed_files_list)"
  rounds_run="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
  {
    printf 'kit: codex-bridge v%s\n' "$KIT_VERSION"
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

# Fresh-context arbiter: a debate participant judging its own disagreements is
# anchored toward its own positions; on non-convergence a NEW Codex session
# (separate bridge dir — deliberately NOT --resume) rules on each remaining
# disagreement from the task + both final positions only.
ARB_CLAUDE_FILE=""
ARB_CODEX_FILE=""
prompt_arbiter() {
  printf 'You are a FRESH, INDEPENDENT arbiter. Claude and Codex debated the task below and did NOT fully converge. You did NOT participate and have no stake in either position. For EACH remaining disagreement: rule which position is correct (or that neither is), citing CHECKABLE evidence (a file:line you can read, or a URL). Do NOT split the difference. If the available evidence cannot settle a point, say exactly what evidence would.\n\n'
  printf '%s\n\n' "$GUARD_LINE"
  memory_section
  printf '=== TASK ===\n'
  cat "$PROMPT_STORE" 2>/dev/null
  printf '\n\n=== FINAL CLAUDE POSITION ===\n'
  truncate_bytes "$ARB_CLAUDE_FILE" "$MAX_BYTES"
  printf '\n\n=== FINAL CODEX POSITION ===\n'
  truncate_bytes "$ARB_CODEX_FILE" "$MAX_BYTES"
}

run_arbiter() {
  [ "$ARBITER" -eq 1 ] || return 0
  ARB_CLAUDE_FILE="$(ls "$ROUNDS_DIR"/*-claude.md 2>/dev/null | tail -1)"
  ARB_CODEX_FILE="$(ls "$ROUNDS_DIR"/*-codex.md 2>/dev/null | tail -1)"
  { [ -n "$ARB_CLAUDE_FILE" ] && [ -n "$ARB_CODEX_FILE" ]; } || return 0
  echo "=== arbiter (fresh-context Codex judge on the unresolved points) ==="
  local pfile="$PROMPTS_DIR/arbiter.prompt.md"
  prompt_arbiter > "$pfile"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would run a fresh-context arbiter consult; prompt at $pfile"
    return 0
  fi
  local adir="$TASK_DIR/bridge-arbiter" rc
  mkdir -p "$adir"
  CODEX_USAGE_LABEL="duel-arbiter" CODEX_BRIDGE_DIR="$adir" bash "$BRIDGE" consult < "$pfile" > "$TASK_DIR/arbiter.log" 2>&1
  rc=$?
  if [ -f "$adir/last_message.md" ]; then
    cp "$adir/last_message.md" "$TASK_DIR/arbiter.md"
  fi
  journal "duel arbiter rc=$rc -> arbiter.md"
  [ "$rc" -ne 0 ] && echo "codex_loop: WARNING: arbiter call failed (rc=$rc); see arbiter.log" >&2
  return 0
}

# A final resumed Claude turn synthesizes the converged answer (it holds the whole
# thread in-session). Runs even on non-convergence; enumerates UNRESOLVED points
# and weighs the fresh-context arbiter's rulings when present.
finalize_and_report() {
  [ "$END_REASON" = "both-converged" ] || run_arbiter
  if [ -f "$SID_FILE" ] && [ "$DRY_RUN" -eq 0 ]; then
    local sid pfile; sid="$(cat "$SID_FILE" 2>/dev/null)"
    if [ -n "$sid" ]; then
      local modelflag=();  [ -n "$CLAUDE_MODEL" ] && modelflag=(--model "$CLAUDE_MODEL")
      local budgetflag=(); [ -n "$BUDGET_USD" ]   && budgetflag=(--max-budget-usd "$BUDGET_USD")
      pfile="$PROMPTS_DIR/final.prompt.md"
      {
        printf 'The debate is over (end reason: %s). Produce the FINAL combined, cross-checked answer:\n' "$END_REASON"
        printf 'merge where you and Codex agree; for EACH remaining disagreement state both positions and your adjudication under a "## UNRESOLVED" heading. Output the answer only.\n'
        if [ -s "$TASK_DIR/arbiter.md" ]; then
          printf '\nAn INDEPENDENT fresh-context arbiter (no stake in the debate) ruled on the remaining disagreements — weigh its rulings seriously and say when you overrule one and why:\n=== ARBITER RULINGS ===\n'
          truncate_bytes "$TASK_DIR/arbiter.md" "$MAX_BYTES"
        fi
      } > "$pfile"
      local frc
      if [ -n "$CLAUDE_USAGE_PY" ]; then
        local fjtmp; fjtmp="$(mktemp)"
        claude_headless -p --resume "$sid" \
            --permission-mode plan \
            --tools "Read" "Grep" "Glob" "WebSearch" "WebFetch" \
            --effort "$(claude_effort)" \
            "${modelflag[@]}" "${budgetflag[@]}" \
            --output-format json \
            < "$pfile" > "$fjtmp" 2>"$TASK_DIR/final.log"
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
            < "$pfile" > "$TASK_DIR/final.md" 2>"$TASK_DIR/final.log"
        frc=$?
      fi
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
  memory_append_run
  print_duel_summary
}

# Fully unattended symmetric loop: claude -p (threaded by fixed UUID) <-> Codex.
run_duel_auto() {
  [ "$DRY_RUN" -eq 1 ] && die "--dry-run with --auto is not supported; preview prompts with '--mode duel --step init --dry-run' instead"
  mkdir -p "$ROUNDS_DIR" || die "cannot create rounds dir"
  read_prompt
  read_seed
  save_duel_env

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
  printf '# Duel debate — %s\n\nauto | code:%s | rounds:%s | codex:%s/%s | claude:%s\n\n(round 0 = INDEPENDENT: both sides answer without seeing each other; cross-critique starts at round 1)\n' \
    "$TASK_ID" "$([ "$CODE" -eq 1 ] && echo on || echo off)" "$ROUNDS" \
    "$CODEX_MODEL" "$CODEX_EFFORT" "$(claude_effort)" >> "$TRANSCRIPT"

  local r rc
  printf '0\n' > "$ROUND_FILE"

  # Round 0: both sides INDEPENDENT — no cross-feed, so their errors stay
  # uncorrelated and the critique rounds have real signal to work with.
  echo "=== round 0: claude (independent) ==="
  run_claude_turn 0 set claude_stdin_round0; rc=$?
  if [ "$rc" -ne 0 ]; then note_partial claude 0 "$rc"; finalize_and_report; return 1; fi
  append_transcript CLAUDE 0 "$ROUNDS_DIR/00-claude.md"

  echo "=== round 0: codex (independent) ==="
  run_codex_turn 0 0 ""; rc=$?
  if [ "$rc" -ne 0 ]; then note_partial codex 0 "$rc"; finalize_and_report; return 1; fi
  append_transcript CODEX 0 "$ROUNDS_DIR/00-codex.md"
  printf '1\n' > "$ROUND_FILE"
  # NOTE: no convergence check after round 0 — CONVERGED cannot mean anything
  # before the two sides have actually seen each other's positions.

  for r in $(seq 1 $((ROUNDS - 1))); do
    echo "=== round $r: claude ==="
    run_claude_turn "$r" resume claude_stdin_resume; rc=$?
    if [ "$rc" -ne 0 ]; then note_partial claude "$r" "$rc"; finalize_and_report; return 1; fi
    append_transcript CLAUDE "$r" "$ROUNDS_DIR/$(rr "$r")-claude.md"

    echo "=== round $r: codex ==="
    run_codex_turn "$r" 1 "$ROUNDS_DIR/$(rr "$r")-claude.md"; rc=$?
    if [ "$rc" -ne 0 ]; then note_partial codex "$r" "$rc"; finalize_and_report; return 1; fi
    append_transcript CODEX "$r" "$ROUNDS_DIR/$(rr "$r")-codex.md"
    printf '%s\n' "$((r + 1))" > "$ROUND_FILE"

    if round_converged "$r"; then
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

  [ -n "$STEP" ] || STEP="init"
  local r resume rc

  case "$STEP" in
    init)
      read_prompt
      read_seed
      # Clear per-debate state from any PREVIOUS debate on this task id: stale
      # claude_latest/codex_latest/rounds/session files would otherwise leak an
      # old debate's content (or a stale CONVERGED) into the new one.
      rm -f "$CLAUDE_LATEST" "$CODEX_LATEST" "$BRIDGE_DIR/session_id" 2>/dev/null || true
      rm -rf "$ROUNDS_DIR" 2>/dev/null || true
      mkdir -p "$ROUNDS_DIR" || die "cannot create rounds dir"
      printf '0\n' > "$ROUND_FILE"
      : > "$TRANSCRIPT"
      printf '# Duel debate — %s\n\nme-driven | code:%s | rounds:%s\n' \
        "$TASK_ID" "$([ "$CODE" -eq 1 ] && echo on || echo off)" "$ROUNDS" >> "$TRANSCRIPT"
      save_duel_env
      if [ "$CODE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "=== worktree (code mode) ==="
        git worktree add -b "$DUEL_BRANCH" "$DUEL_WORKTREE" "$BASE" > "$TASK_DIR/worktree.log" 2>&1 \
          || die "worktree add failed; clean with '--mode duel --task $TASK_ID --teardown' (see worktree.log)"
      fi
      journal "duel init (code:$CODE rounds:$ROUNDS base:$BASE)"
      printf 'me-driven duel ready (task: %s). Config persisted in %s/duel.env — later steps only need --task.\n' "$TASK_ID" "$TASK_DIR_REL"
      printf '  transcript: %s/transcript.md\n  prompt:     %s/prompt.md\n' "$TASK_DIR_REL" "$TASK_DIR_REL"
      printf 'Each round, you (live Claude) do:\n'
      printf '  1. Do your own research/critique; write your turn to %s/claude_latest.md\n' "$TASK_DIR_REL"
      printf '     (share ALL evidence — file:line, URLs, test results; end with "DISAGREEMENTS REMAINING: <n>")\n'
      printf '  2. Run one Codex turn:\n       bash codex-bridge/codex_loop.sh --mode duel --task %s --step codex\n' "$TASK_ID"
      printf '  3. Read %s/codex_latest.md; critique/adopt; repeat until converged or %s rounds.\n' "$TASK_DIR_REL" "$ROUNDS"
      printf '     When you agree with Codex and n=0, make the SINGLE line %s the LAST line of claude_latest.md.\n' "$CONV_TOKEN"
      printf '  4. Finish: bash codex-bridge/codex_loop.sh --mode duel --task %s --step finalize\n' "$TASK_ID"
      return 0
      ;;
    codex)
      [ -s "$PROMPT_STORE" ] || die "no prompt.md; run '--step init' first"
      [ -s "$CLAUDE_LATEST" ] || die "write your NEW turn to $CLAUDE_LATEST before '--step codex' (each successful step consumes it)"
      mkdir -p "$ROUNDS_DIR" 2>/dev/null || true
      r="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
      case "$r" in ""|*[!0-9]*) r=0 ;; esac
      [ "$r" -lt "$ROUNDS" ] || die "round cap ($ROUNDS) reached; run '--step finalize' (raise with --rounds N if you truly want more)"
      cp "$CLAUDE_LATEST" "$ROUNDS_DIR/$(rr "$r")-claude.md" 2>/dev/null || true

      resume=0; [ "$r" -gt 0 ] && resume=1
      echo "=== round $r: codex ==="
      run_codex_turn "$r" "$resume" "$ROUNDS_DIR/$(rr "$r")-claude.md"; rc=$?
      if [ "$rc" -ne 0 ]; then
        # Nothing was appended/advanced: a retry after fixing the failure will
        # not duplicate transcript entries or burn a round.
        OVERALL_RESULT="FAIL (codex r$r)"; FAILING_COMMAND="codex_bridge.sh $(codex_sandbox_mode)"
        write_duel_status; print_duel_summary; return 1
      fi
      append_transcript CLAUDE "$r" "$ROUNDS_DIR/$(rr "$r")-claude.md"
      append_transcript CODEX "$r" "$ROUNDS_DIR/$(rr "$r")-codex.md"
      printf '%s\n' "$((r + 1))" > "$ROUND_FILE"
      # Consume the Claude turn: an accidental repeat of '--step codex' must not
      # silently burn a round re-feeding Codex the same stale message.
      [ "$DRY_RUN" -eq 0 ] && rm -f "$CLAUDE_LATEST" 2>/dev/null

      echo "----- CODEX (round $r) -> $TASK_DIR_REL/codex_latest.md -----"
      cat "$CODEX_LATEST"
      if converged_side "$CODEX_LATEST"; then
        echo "----- Codex signalled $CONV_TOKEN. If you also converge, end your next claude_latest.md with the single line $CONV_TOKEN and run '--step finalize'. -----"
      fi
      if [ "$((r + 1))" -ge "$ROUNDS" ]; then
        echo "----- round cap ($ROUNDS) reached; run '--step finalize'. -----"
      fi
      return 0
      ;;
    finalize)
      [ -s "$PROMPT_STORE" ] || die "no prompt.md; run '--step init' first"
      local lastc lastx
      lastc="$(ls "$ROUNDS_DIR"/*-claude.md 2>/dev/null | tail -1)"
      lastx="$(ls "$ROUNDS_DIR"/*-codex.md 2>/dev/null | tail -1)"
      if [ -n "$lastc" ] && [ -n "$lastx" ] && converged_side "$lastc" && converged_side "$lastx"; then
        END_REASON="both-converged"
      else
        END_REASON="round-cap"
        run_arbiter
      fi
      write_duel_status
      memory_append_run
      print_duel_summary
      printf '\nNEXT (you, live Claude): author the converged, cross-checked answer to\n'
      printf '  %s/final.md  — merge where you and Codex agree; under "## UNRESOLVED"\n' "$TASK_DIR_REL"
      printf '  state both positions + your adjudication for each remaining disagreement.\n'
      if [ -s "$TASK_DIR/arbiter.md" ]; then
        printf '  A fresh-context arbiter ruled on the open points: weigh %s/arbiter.md and say when you overrule it.\n' "$TASK_DIR_REL"
      fi
      if [ "$CODE" -eq 1 ]; then
        printf '  Codex edits are in %s (git -C %s diff %s). Cherry-pick into main if desired;\n' "$DUEL_WORKTREE" "$DUEL_WORKTREE" "$BASE"
        printf '  the script does NOT auto-merge. Then run --teardown.\n'
      fi
      printf '  Record your interactive tokens: bash codex-bridge/claude_usage.sh end %s\n' "$TASK_ID"
      return 0
      ;;
  esac
}

case "$MODE" in
  build) run_build_mode; exit $? ;;
  guard) run_guard_mode; exit $? ;;
  duel) run_duel_mode; exit $? ;;
esac
