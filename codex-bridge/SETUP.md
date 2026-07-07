# Setup — reproduce the Claude ↔ Codex bridge in your repo

Share this whole `codex-bridge/` folder with anyone. It is self-contained and has
no project-specific paths. Follow the steps, then paste the prompt at the bottom
into Claude Code.

---

## 1. Prerequisites

- **Claude Code** (the CLI you're reading this in).
- **Codex CLI** installed and signed in, with access to your chosen model
  (default `gpt-5.5`). Check: `codex --version` and `codex login status`.
- **bash** to run the scripts. On Windows use **Git Bash** (ships with Git for
  Windows); macOS/Linux work out of the box.
- **python** (recommended): enables interactive-Claude token capture and the
  JSONL recovery paths.

## 2. Drop in the folder

Copy `codex-bridge/` to the root of your repo (or run `install.sh` from inside
the repo). The scripts find each other automatically, so the folder can be named
or placed anywhere as long as the files stay together.

## 3. Git-ignore the runtime dirs

Runtime artifacts (per-task scratch, logs, token ledgers, memory) land in
`tmp/codex/`. Add to your `.gitignore` (see `.gitignore.example`):

```
tmp/codex/
codex-bridge/tmp/
```

**Recommended: commit the `codex-bridge/` folder itself** so every teammate
gets the kit (and its fixes) with a plain `git pull`. If you prefer to keep
tooling untracked, also add `codex-bridge/` — the trade-off is that each
teammate must install and update it by hand.

## 4. Codex config

Codex reads `~/.codex/config.toml`. Minimum useful settings:

```toml
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
service_tier = "default"        # the --fast flag overrides this to "priority"
```

**Windows only — sandbox fix** (so Codex can run commands like tests itself):

```toml
[windows]
sandbox = "unelevated"          # "elevated" fails: CreateProcessWithLogonW error 2
```

If `codex exec` errors with `CreateProcessWithLogonW failed`, also ensure
`codex-windows-sandbox-setup.exe` exists in the Codex `bin` dir (copy it from
`~/.codex/packages/standalone/releases/<ver>/codex-resources/` if missing).

## 5. Doctor (free — run this first)

```bash
bash codex-bridge/doctor.sh
```

Validates everything above without a single paid call: codex install + login,
`--json` support, config.toml (including the Windows sandbox line), claude CLI,
python, writable runtime dir. Fix any FAIL before continuing.

## 6. Smoke test (one small paid call)

```bash
bash codex-bridge/doctor.sh --paid
# or directly:
printf 'Reply only: BRIDGE_OK\n' | bash codex-bridge/codex_bridge.sh consult
bash codex-bridge/codex_loop.sh --help
```

Want to see exactly what a mode would send before spending tokens? Every mode
supports `--dry-run` — prompts are written under `tmp/codex/tasks/<id>/prompts/`
and the exact commands are printed.

---

## Prompt to paste into Claude Code

Copy this into a fresh Claude Code session in your repo (or add it to your
`CLAUDE.md` so it loads every session):

> **Claude ↔ Codex collaboration is enabled in this repo via `codex-bridge/`.**
> Read `codex-bridge/PROTOCOL.md` and follow it for all non-trivial work.
>
> For every feature, fix, refactor, or design decision, get an independent second
> opinion from Codex before and/or during the work, and have the *other* model
> review the diff. Drive Codex hands-off via `bash codex-bridge/codex_loop.sh`
> (or the low-level `codex-bridge/codex_bridge.sh`) — never make me copy-paste.
> Read `tmp/codex/memory.md` at task start; share everything with Codex per the
> PROTOCOL's "Information sharing" section; answer its OPEN QUESTIONS each round.
>
> When I end a request with a mode keyword, run the matching loop:
> - `@cx-build` → `--mode build` (Codex implements with a test/fix loop; add
>   `--claude-review` so you cross-review and Codex must fix-or-rebut)
> - `@cx-guard` → `--mode guard` (you implement; Codex reviews into a CX-NN
>   ledger; you write reconciliation.md; then `--step verify` until VERDICT: CLEAN)
> - `@cx-duel`  → `--mode duel` (mutual-critique debate; round 0 independent;
>   me-driven by default, `--auto` needs `--seed`; arbiter on non-convergence)
>
> I can append a model, reasoning effort, and/or `fast` after the keyword, e.g.
> `@cx-build gpt5.5 xhigh fast` → `--model gpt-5.5 --effort xhigh --fast`.
> Normalize `gpt5.5`→`gpt-5.5`. Effort is one of low|medium|high|xhigh. `fast`
> sets the priority service tier. No keyword → you pick (build for non-trivial,
> inline for trivial) and tell me which.
>
> Persist Codex's findings and fix or explicitly waive each before declaring
> done — then let Codex VERIFY the reconciliation. When a task ends, run
> `bash codex-bridge/claude_usage.sh end <task-id>` so your own tokens are
> recorded, and report the Codex-vs-Claude split.
> Never let Codex read or print generated files (`.next/`, `dist/`, `build/`,
> `node_modules/`, compiled CSS) — reason on source only.

That's it. Try: *"Add input validation to the config loader. @cx-build gpt5.5 xhigh fast"*
