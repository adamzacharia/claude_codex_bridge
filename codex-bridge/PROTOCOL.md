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
id under the per-task scratch dir and resumes THAT exact id, so the two models
actually discuss across rounds instead of firing one-shots.

## Mode keywords (the human ends a prompt with one)

The human selects how heavily to lean on Codex by ending their request with a
trailing keyword. Claude maps it to a `codex_loop.sh` mode and runs it hands-off.
**No keyword → Claude picks** (`build` for non-trivial work, inline for trivial)
and states which it chose.

| Keyword | Mode | Who implements / who reviews |
|---|---|---|
| `@cx-build` | **build** | Codex implements (consult → build → self-review → fix); **Claude reviews** the diff. Maximizes Codex's share of the work. |
| `@cx-duel`  | **duel**  | **Mutual-critique debate.** Claude and Codex independently answer the SAME task, then critique each other **both directions** round after round and converge on one cross-checked answer. Works for plain reasoning/research (no code) AND for code. Read-only by default. |
| `@cx-guard` | **guard** | **Claude implements**; Codex reviews the diff over threaded rounds; Claude reconciles findings. |

> **duel is the exception to the "who implements / who reviews" framing above:**
> there is no fixed implementer or reviewer — both models critique each other
> every round. See "What each mode runs" for how the loop works.

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

- **build**: consult (Codex critiques the spec) → build (Codex edits, threaded) →
  review (`codex exec review --uncommitted`, advisory) → optional `--test`.
- **guard**: gate on `git status --porcelain` → round 1 review (fresh consult,
  Codex inspects the uncommitted diff) → round 2 deeper findings (threaded
  `--resume`).
- **duel**: a continuous mutual-critique **debate loop** (replaces the old
  implement-alone-and-compare). Both sides answer the same task, **share findings,
  critique each other every round, and converge.** Two ways to run it:
  - **default (me-driven)**: the live Claude session IS the Claude debater (full
    repo + chat context). Step it: `--step init` (sets up + writes `prompt.md`),
    then each round write your turn to `claude_latest.md` and run `--step codex`
    (threads one Codex turn, appends `transcript.md`), read `codex_latest.md`,
    repeat; finish with `--step finalize` and author `final.md`.
  - **`--auto`**: fully unattended symmetric loop — `claude -p` (threaded by a
    fixed session id) ↔ Codex. **Requires `--seed <file>`**: a context bundle the
    live Claude writes (its research + relevant repo/chat context) so neither side
    starts blind. Converges when both sides emit `CONVERGED` in the same round,
    else stops at `--rounds`; `final.md` always lists any UNRESOLVED points.
  Read-only by default — works for a plain question (Claude runs `plan` +
  Read/Grep/Glob/WebSearch/WebFetch; Codex runs `consult`). `--code` opts into
  edits with a **single writer**: Codex edits in a `git worktree`, Claude reviews
  the diff read-only; the script never auto-merges to main. `--teardown` (same
  `--task`) removes the worktree, branch, and session files.

## Artifacts & discipline

- Every run writes to `tmp/codex/tasks/<task-id>/` (consult.md, build.md,
  review.md, findings.md, status.md, logs) with a per-task `bridge/` scratch dir
  so concurrent runs never cross sessions. **duel** adds `prompt.md`, `seed.md`,
  `transcript.md` (the full debate), `rounds/NN-{claude,codex}.{md,log}`, and
  `final.md` (the converged answer).
- **Never let Codex read or print generated files** (`.next/`, `dist/`, `build/`,
  `node_modules/`, compiled CSS, minified assets, logs). Reason on source only;
  never `cat` build output. This guard line is injected into every prompt.

## Token accounting (automatic)

Every `codex_loop.sh` run records token usage per call and prints a `TOKENS`
breakdown in its SUMMARY, plus writes `tmp/codex/tasks/<id>/usage.md`. Raw rows
go to `tmp/codex/tasks/<id>/usage.tsv` (`epoch  iso  side  label  total  in  out  rc`).

- **Codex** is captured per call (consult / build / review / duel rounds) — Codex
  reports `tokens used` and the bridge harvests it from its run log before the next
  call overwrites it. (`review` may read 0 if `codex exec review` omits the line.)
- **Claude** is captured only for **headless `claude -p`** turns in `--auto` duels
  (via `--output-format json` + a python parse). In **build/guard** the Claude side
  is your *interactive* Claude Code session and is **not** measurable here — the
  report states this; use Claude Code `/cost` for that figure.
- Report anytime, across runs:
  ```bash
  bash codex-bridge/usage_report.sh            # every task + grand total
  bash codex-bridge/usage_report.sh <task-id>  # one task
  ```
  Helpers live in `codex-bridge/usage_lib.sh`. After any `@cx` task, summarize the
  Codex-vs-Claude split for the user (the SUMMARY already prints it).

## Workflow for any change

1. Claude drafts the spec (exact files, behavior, acceptance criteria, tests).
2. Consult the other model on the plan; incorporate or explicitly rebut feedback.
3. Implement per the mode keyword — default to handing the heavy editing to Codex
   (`build`) so Codex spends its own tokens while Claude plans and reviews; the
   *other* model always reviews the diff.
4. Verify: run the relevant tests and adversarially check the risky logic.
5. Prefer threaded `--resume` rounds over fresh one-shots so the models discuss.
