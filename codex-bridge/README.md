# codex-bridge — Claude ↔ Codex collaboration kit

A drop-in folder that makes **Claude Code** and **Codex (OpenAI CLI)**
pressure-test each other's work automatically: one model plans/reviews while the
other implements, with real multi-round discussion and **zero manual
copy-paste**. Fully portable — no project-specific paths.

## What you get

- **Three collaboration modes**, triggered by a keyword you append to a request:
  - `@cx-build` — Codex implements; failing tests are fed back for bounded fix
    rounds; Claude cross-reviews the diff and Codex must fix-or-rebut each finding.
  - `@cx-guard` — Claude implements; Codex reviews over threaded rounds into a
    CX-NN findings ledger, then **verifies** Claude's fixes (`VERDICT: CLEAN|REOPEN`).
  - `@cx-duel` — mutual-critique debate: both answer the same task independently
    (round 0 is blind), critique each other every round, and a fresh-context
    arbiter rules on whatever doesn't converge.
- **Share-everything discussion** — every artifact (test logs, diffs, reviews,
  decisions) is fed verbatim into the other model's next prompt; each side must
  answer the other's numbered questions. See PROTOCOL.md → "Information sharing".
- **Persistent memory** — `tmp/codex/memory.md` keeps the FULL cross-task
  history forever; every fresh prompt gets a sliding window of the newest
  entries (default 10 KB) plus an instruction to read/grep the whole file
  whenever older context is needed. No run starts blind, nothing is ever lost.
- **Robust plumbing** — session ids, token usage, and errors come from the
  `codex --json` event stream (no log-scraping); heartbeats during long calls;
  optional timeouts; `--dry-run` previews every prompt for free.
- **Full token accounting** — Codex per call, headless Claude per call, and the
  interactive Claude Code session via `claude_usage.sh end <task>`.

## 60-second install

1. Copy this whole `codex-bridge/` folder into the root of your repo — or run
   [`install.sh`](../install.sh) from inside your repo.
2. Validate the toolchain (free, no model calls):

   ```bash
   bash codex-bridge/doctor.sh
   ```

3. Add these lines to your repo's `CLAUDE.md` (create it if missing) so Claude
   loads the protocol every session — a ready-to-paste version is in
   [`CLAUDE.md.example`](CLAUDE.md.example):

   > Claude ↔ Codex collaboration is enabled via `codex-bridge/`. Read
   > `codex-bridge/PROTOCOL.md` and follow it for all non-trivial work.

4. Git-ignore the runtime dirs (see [`.gitignore.example`](.gitignore.example)) —
   **commit the kit itself** so your whole team gets it:

   ```
   tmp/codex/
   codex-bridge/tmp/
   ```

   (Prefer the kit untracked? Add `codex-bridge/` too — just know teammates then
   have to install it themselves.)

5. Read [`SETUP.md`](SETUP.md) for prerequisites (Codex CLI, `~/.codex/config.toml`,
   the Windows sandbox fix) and a smoke test.

Then just try it: *"Add input validation to the config loader. @cx-build"*

## Files

| File | What it is |
|---|---|
| `PROTOCOL.md` | The full working agreement — read this first. |
| `SETUP.md` | Prerequisites, Codex config, doctor, smoke test. |
| `CLAUDE.md.example` | Generic snippet to paste into your repo's `CLAUDE.md`. |
| `codex_bridge.sh` | Low-level single Codex call (`consult` / `build`, threaded via `--resume`, JSONL-parsed, heartbeat + timeout). |
| `codex_loop.sh` | Hands-off orchestrator for `build` / `guard` / `duel` modes. |
| `doctor.sh` | Free toolchain validation (run before anything paid). |
| `claude_usage.sh` | Records the interactive Claude Code session's tokens per task. |
| `usage_lib.sh` | Shared token-accounting + `codex --json` parsing helpers. |
| `duel_lib.sh` | Pure helpers (convergence detection, truncation) — unit-tested. |
| `usage_report.sh` | Print recorded Codex/Claude token usage. |
| `VERSION` | Kit version stamp (printed in `--help` and every SUMMARY). |

## Requirements

Each person who uses this needs the following on **their own machine** — the
folder alone can't set these up (run `bash codex-bridge/doctor.sh` to check all
of it at once):

- **Claude Code** (the CLI).
- **Codex CLI**, installed and **signed in**, with access to your chosen model
  (default `gpt-5.5`). Verify with:

  ```bash
  codex --version
  codex login            # if you're not already signed in
  codex exec -m gpt-5.5 -s read-only "say hi"
  ```

- **A Codex config file** at `~/.codex/config.toml`. Minimum useful settings:

  ```toml
  model = "gpt-5.5"
  model_reasoning_effort = "xhigh"
  service_tier = "default"        # the --fast flag overrides this to "priority"

  # Windows only — lets Codex run commands (e.g. tests) itself:
  [windows]
  sandbox = "unelevated"          # "elevated" fails: CreateProcessWithLogonW error 2
  ```

- **bash** — Git Bash on Windows; native on macOS/Linux.

See [`SETUP.md`](SETUP.md) for the full walkthrough, the Windows sandbox fix, and
a smoke test.

## Notes

- The default review base branch is `main`. Override per run with
  `--base <branch>` (e.g. `--base develop`).
- The scripts locate each other automatically, so the folder can live anywhere
  in your repo as long as the files stay together.
- Environment knobs: `CODEX_TIMEOUT_SECS` (kill a hung call), `CODEX_HEARTBEAT_SECS`
  (progress cadence), `MEMORY_TAIL_BYTES` (how much memory each prompt sees),
  `CODEX_BRIDGE_NO_JSON` (force the legacy log-scrape path).

## License

MIT — do whatever you like; no warranty.
