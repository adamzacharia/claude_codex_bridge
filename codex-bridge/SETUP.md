# Setup — reproduce the Claude ↔ Codex bridge in your repo

Share this whole `codex-bridge/` folder with anyone. It is self-contained and has
no project-specific paths. Follow the 4 steps, then paste the prompt at the bottom
into Claude Code.

---

## 1. Prerequisites

- **Claude Code** (the CLI you're reading this in).
- **Codex CLI** installed and signed in, with access to your chosen model
  (default `gpt-5.5`). Check: `codex --version` and `codex exec -m gpt-5.5 -s read-only "say hi"`.
- **bash** to run the scripts. On Windows use **Git Bash** (ships with Git for
  Windows); macOS/Linux work out of the box.

## 2. Drop in the folder

Copy `codex-bridge/` to the root of your repo. The two scripts find each other
automatically, so the folder can be named or placed anywhere as long as both
scripts stay together.

## 3. Keep it local (untracked)

This is build-time tooling — it should not be committed to your project. Add to
your `.gitignore`:

```
codex-bridge/
tmp/codex/
```

(Runtime artifacts land in `tmp/codex/`; the kit itself lives in `codex-bridge/`.)

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

## 5. Smoke test

```bash
printf 'Reply only: BRIDGE_OK\n' | bash codex-bridge/codex_bridge.sh consult
bash codex-bridge/codex_loop.sh --help
```

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
>
> When I end a request with a mode keyword, run the matching loop:
> - `@cx-build` → `--mode build` (Codex implements; you review the diff)
> - `@cx-guard` → `--mode guard` (you implement; Codex reviews over threaded rounds)
> - `@cx-duel`  → `--mode duel` (mutual-critique debate loop: both answer the same task and critique each other every round until they converge; me-driven by default, `--auto` for an unattended `claude -p` ↔ Codex loop)
>
> I can append a model, reasoning effort, and/or `fast` after the keyword, e.g.
> `@cx-build gpt5.5 xhigh fast` → `--model gpt-5.5 --effort xhigh --fast`.
> Normalize `gpt5.5`→`gpt-5.5`. Effort is one of low|medium|high|xhigh. `fast`
> sets the priority service tier. No keyword → you pick (build for non-trivial,
> inline for trivial) and tell me which.
>
> Persist Codex's findings and fix or explicitly waive each before declaring done.
> Never let Codex read or print generated files (`.next/`, `dist/`, `build/`,
> `node_modules/`, compiled CSS) — reason on source only.

That's it. Try: *"Add input validation to the config loader. @cx-build gpt5.5 xhigh fast"*
