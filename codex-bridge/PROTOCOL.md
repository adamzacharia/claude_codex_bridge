# Claude ↔ Codex collaboration protocol

A drop-in kit that makes **Claude Code** and **Codex (OpenAI CLI)** pressure-test
each other's work automatically — one model plans/reviews while the other
implements, with real multi-round discussion and zero manual copy-paste.

This file is generic. To reproduce it in your own repo, see [SETUP.md](SETUP.md).

---

## Principle

For any non-trivial change, **get an independent second opinion from the other
model before and/or during the work.** Deliberately mix models so each plan is
challenged by the other before code lands. Treat the other model's feedback as
input to weigh, not gospel — reconcile disagreements explicitly and state the
final call. Persist the other model's findings so they can't be silently skipped:
fix or explicitly waive each before declaring done.

## Information sharing (share EVERYTHING)

The two models are collaborators, not oracles queried in isolation. The bridge
enforces an aggressive sharing discipline:

- **Every artifact is a file** under `tmp/codex/tasks/<id>/` — specs, critiques,
  build notes, test output, reviews, reconciliations, verify verdicts, arbiter
  rulings — and each is fed **verbatim** (byte-capped at `--max-bytes`, default
  60000, with explicit truncation markers) into the other side's next prompt.
  Nothing is summarized away or silently dropped.
- **Codex is instructed in every working prompt** to report every file it
  changed and why, every command it ran and its outcome, test results verbatim,
  every assumption, and to end with `NOTES FOR CLAUDE` + numbered
  `OPEN QUESTIONS`. Claude (live or headless) answers those questions in its
  next turn — a real two-way conversation, not fire-and-forget.
- **A per-task `journal.md`** records every step (who ran, result, artifact) and
  its tail is embedded into later same-task prompts, so a step never starts
  blind about what already happened.
- **The exact prompts are kept**: everything sent to either model persists under
  `prompts/` (or `rounds/NN-*.prompt.md` in duels) for audit and debugging.

## Persistent memory (never start blind)

`tmp/codex/memory.md` is an append-only, cross-task memory — the FULL history is
kept forever (it is never trimmed; delete the file to reset it). At the end of
every run the loop appends a compact digest: date, task, mode, result, changed
files, and the head of each key artifact (findings, reviews, verdicts, final
answers).

What prompts see is a **sliding window**: the tail (last `MEMORY_TAIL_BYTES`,
default 10000) is injected into every fresh-context prompt — Codex consults,
guard reviews, duel round 0, arbiter, Claude cross-reviews — under a
`BRIDGE MEMORY` heading, so both models know what was recently changed, decided,
or waived. The heading also states the full file's path and instructs the model
to **read or grep the whole file on demand** whenever the window isn't enough
(an older decision, a task that scrolled out) — old entries age out of the
default view, never out of reach.

The live Claude should also **read `tmp/codex/memory.md` at task start** and may
append `## Note` entries for decisions worth remembering that no run recorded.

## The two entry points

```bash
# Low-level single calls (prompt on stdin):
bash codex-bridge/codex_bridge.sh consult < plan.md        # read-only second opinion (new thread)
bash codex-bridge/codex_bridge.sh build   < spec.md        # Codex edits files (workspace-write, new thread)
bash codex-bridge/codex_bridge.sh consult --resume < q.md  # CONTINUE the same thread (Codex remembers)
bash codex-bridge/codex_bridge.sh build   --full   < spec.md  # + network/full access when needed

# Full hands-off orchestrator:
bash codex-bridge/codex_loop.sh --mode <build|guard|duel> [options]
```

`--resume` threads the conversation: the bridge records each fresh run's session
id (from the `codex --json` event stream) under the per-task scratch dir and
resumes THAT exact id, so the two models actually discuss across rounds instead
of firing one-shots. If the recorded id is missing, the bridge **fails loudly**
instead of guessing at `--last` (which can attach to the wrong thread).

Health check anytime (free): `bash codex-bridge/doctor.sh`. Preview what any
mode would send without paying for a call: add `--dry-run` (prompts are written
to the task dir and the exact commands printed).

## Mode keywords (the human ends a prompt with one)

The human selects how heavily to lean on Codex by ending their request with a
trailing keyword. Claude maps it to a `codex_loop.sh` mode and runs it hands-off.
**No keyword → Claude picks** (`build` for non-trivial work, inline for trivial)
and states which it chose.

| Keyword | Mode | Who implements / who reviews |
|---|---|---|
| `@cx-build` | **build** | Codex implements (consult → build → test/fix loop → self-review → optional Claude cross-review + fix-or-rebut); **Claude reviews** the diff. Maximizes Codex's share of the work. |
| `@cx-duel`  | **duel**  | **Mutual-critique debate.** Claude and Codex independently answer the SAME task (round 0 is blind), then critique each other **both directions** round after round and converge; a fresh-context **arbiter** rules on anything left. Works for plain reasoning/research (no code) AND for code. Read-only by default. |
| `@cx-guard` | **guard** | **Claude implements**; Codex reviews the diff over threaded rounds into a CX-NN findings ledger; Claude reconciles each finding; then `--step verify` makes Codex re-check every fix/waiver and rule `VERDICT: CLEAN` or `REOPEN`. |

### Choosing the model / effort / speed inline

Append model, reasoning effort, and/or `fast` after the keyword. Claude maps the
words to flags:

```
@cx-build gpt5.5 xhigh fast
        │      │     └── --fast      (priority service tier: faster turnaround)
        │      └──────── --effort xhigh   (low | medium | high | xhigh)
        └─────────────── --model gpt-5.5  (normalize "gpt5.5" → "gpt-5.5")
```

Examples:
- `@cx-guard high` → `codex_loop.sh --mode guard --effort high`
- `@cx-build gpt-5.5 fast` → `codex_loop.sh --mode build --model gpt-5.5 --fast`
- `@cx-duel xhigh` → `codex_loop.sh --mode duel --effort xhigh`

Defaults when unspecified: model `gpt-5.5`, effort `xhigh`, fast off.

**Duel-only modifiers** (append after `@cx-duel`):
- `auto` → `--auto` (unattended `claude -p` ↔ Codex loop; **requires** a seed file)
- `code` → `--code` (allow edits; Codex writes in a worktree, Claude reviews read-only)
- a bare integer `N` → `--rounds N` (debate-round ceiling; default 4)

```
@cx-duel            → --mode duel                          (me-driven, read-only, 4 rounds)
@cx-duel auto 6 high→ --mode duel --auto --rounds 6 --effort high
@cx-duel code gpt5.5 xhigh fast → --mode duel --code --model gpt-5.5 --effort xhigh --fast
```

Effort applies to Codex as given; the **Claude side has no `xhigh`** and is
clamped to `high`.

## What each mode runs

- **build**: consult (Codex critiques the spec, proposes changes, asks Claude
  questions — with a repo map + spec-referenced file excerpts packed into the
  prompt) → **plan gate** (headless Claude answers every question and rules
  ACCEPT/REJECT on each spec change BEFORE any code exists; `--no-plan-gate`
  disables; `--author-tests` additionally has Claude write acceptance tests the
  implementation must pass unchanged) → build (Codex edits, threaded, following
  the rulings) → **test + fix loop** (`--test '<cmd>'`; up to `--fix-rounds N`,
  default 2, with a bonus cheap high-effort round for shallow error classes, an
  unchanged-failure **stall detector** that pulls an independent Claude
  diagnosis, and early stop when retrying is pointless) → **parallel reviews**:
  a spec-aware structured Codex self-review (custom instructions + CX grammar
  via `codex exec review - < …`) runs concurrently with the `--claude-review`
  headless-Claude cross-review → both findings lists (CX + SX) go BACK to the
  Codex thread for a **fix-or-rebut round** → the cross-reviewer then RESUMES
  its own session to refute each `FIXED` claim (`VERDICT: CLEAN|REOPEN`, one
  scoped reopen round) → final re-test. `--quick` merges consult+build into one
  call for small mechanical specs.
- **guard**: optional `--test` runs BEFORE the review (a red test is the
  reviewer's strongest lead; the result persists in `guard.env` as the
  regression baseline) → round 1 review (fresh consult; pass `--spec <file>`
  for the change INTENT) → round 2 findings as a **CX-NN reconciliation
  ledger**, mechanically LINTED (grammar, real file:line refs, TOTAL count; one
  reformat nudge on violations) → Claude writes `reconciliation.md` — the
  verify step REFUSES to run until every CX id has a ruling → **`--task <id>
  --step verify`**: the test re-runs (red/green transition shown to the
  verifier), Codex re-checks each fix on the SAME thread, AGREEs or CONTESTs
  each waiver, and ends `VERDICT: CLEAN` or `VERDICT: REOPEN CX-…` (one nudge
  if the verdict line is missing). Loop verify until CLEAN.
- **duel**: a continuous mutual-critique **debate loop** with machine-checked
  honesty: both sides maintain a **DX disagreement ledger** (`- DX-NN |
  OPEN|AGREED|CONCEDED-* | point | evidence: …`) — convergence requires the
  `CONVERGED` token AND zero OPEN points, silently dropped points are nudged
  back, and identical OPEN sets two rounds running hand the debate to the
  arbiter early; every `EVIDENCE: <path>:<line> "<quote>"` citation is
  **mechanically verified** after each turn and failures are flagged to the
  counterpart as unproven. **Round 0 is INDEPENDENT and runs both sides in
  parallel**; cross-critique starts at round 1 (default cap: 3 rounds —
  research shows gains plateau by then). The FIRST convergence triggers one
  mandatory **red-team exchange** (attack the consensus; re-converging after a
  failed attack ends the debate as `converged-post-redteam`). Two ways to run:
  - **default (me-driven)**: the live Claude session IS the Claude debater (full
    repo + chat context). Step it: `--step init` (sets up, persists ALL flags to
    `duel.env` — later steps only need `--task <id>`), then each round write your
    turn to `claude_latest.md` (it is consumed per step; end with
    `DISAGREEMENTS REMAINING: <n>`) and run `--step codex`, read
    `codex_latest.md`, repeat; finish with `--step finalize` and author
    `final.md`. To converge, make the single line `CONVERGED` the LAST line of
    your `claude_latest.md`.
  - **`--auto`**: fully unattended symmetric loop — `claude -p` (threaded by a
    fixed session id) ↔ Codex. **Requires `--seed <file>`**: a context bundle the
    live Claude writes (its research + relevant repo/chat context) so neither side
    starts blind. Converges when both sides emit `CONVERGED` in the same round
    (round ≥ 1), else stops at `--rounds`.
  On non-convergence a **two-model arbiter PANEL** (fresh Codex + fresh Claude,
  no debate history, ruling in parallel on an ANONYMIZED docket — position
  labels only, since identity/verbosity measurably skew judges) rules on each
  remaining disagreement with checkable evidence; where the two rulings agree
  the synthesis treats them as binding, where they disagree the point lands
  under UNRESOLVED with both rulings shown (`--no-arbiter` disables).
  `final.md` always lists any UNRESOLVED points.
  Read-only by default — works for a plain question. `--code` opts into edits
  with a **single writer**: Codex edits in a `git worktree` ONLY (the loop
  refuses to run Codex writable outside it), Claude reviews the diff read-only;
  the script never auto-merges to main. `--teardown` (with the same `--task`,
  which is required) removes the worktree, branch, and session files.

## Artifacts & discipline

- Every run writes to `tmp/codex/tasks/<task-id>/` (consult.md, build.md,
  fix-rN.md, review.md, claude_review.md, codex_response.md, findings.md,
  reconciliation.md, verify.md, status.md, journal.md, prompts/, logs) with a
  per-task `bridge/` scratch dir so concurrent runs never cross sessions.
  **duel** adds `prompt.md`, `seed.md`, `duel.env`, `transcript.md` (the full
  debate), `rounds/NN-{claude,codex}.{md,log,prompt.md}`, `arbiter.md`, and
  `final.md` (the converged answer).
- **Never let Codex read or print generated files** (`.next/`, `dist/`, `build/`,
  `node_modules/`, compiled CSS, minified assets, logs). Reason on source only;
  never `cat` build output. This guard line is injected into every prompt.

## Token accounting (automatic)

Every `codex_loop.sh` run records token usage AND per-call wall-clock per call
and prints a `TOKENS` breakdown (with time totals) in its SUMMARY, plus writes
`tmp/codex/tasks/<id>/usage.md`. Raw rows go to `tmp/codex/tasks/<id>/usage.tsv`
(`epoch  iso  side  model  label  total  in  cached  out  rc  secs`).

- **Codex** is captured per call from the `--json` event stream
  (`turn.completed.usage`: real in/cached/out splits; older CLIs fall back to
  the log heuristic).
- **Headless Claude** turns (`--auto` duels, `--claude-review`) record
  themselves via `--output-format json`.
- **The INTERACTIVE Claude Code session** (the one you are reading this in) is
  captured by transcript snapshots: the loop runs
  `claude_usage.sh begin <task>` automatically at task start, and **you (live
  Claude) MUST run `bash codex-bridge/claude_usage.sh end <task-id>` when you
  declare the task done** — it parses the appended portion of this session's
  transcript under `~/.claude/projects/` and records one `interactive` row.
- Report anytime, across runs:
  ```bash
  bash codex-bridge/usage_report.sh            # every task + grand total
  bash codex-bridge/usage_report.sh <task-id>  # one task
  ```
  Helpers live in `codex-bridge/usage_lib.sh`. After any `@cx` task, summarize the
  Codex-vs-Claude split for the user (the SUMMARY already prints it).

## Workflow for any change

1. Read `tmp/codex/memory.md` (prior decisions) — then draft the spec (exact
   files, behavior, acceptance criteria, tests).
2. Consult the other model on the plan; ANSWER its numbered questions;
   incorporate or explicitly rebut its feedback.
3. Implement per the mode keyword — default to handing the heavy editing to Codex
   (`build`, with `--test` so the fix loop has ground truth) so Codex spends its
   own tokens while Claude plans and reviews; the *other* model always reviews
   the diff (`--claude-review` automates this in build mode).
4. Reconcile: fix or explicitly waive each CX-NN finding, then let the reviewer
   verify (`guard --step verify`) — done means `VERDICT: CLEAN`, not "I replied".
5. Prefer threaded `--resume` rounds over fresh one-shots so the models discuss.
6. Declare done: run `bash codex-bridge/claude_usage.sh end <task-id>`, report
   the token split, and check `memory.md` recorded the outcome.
