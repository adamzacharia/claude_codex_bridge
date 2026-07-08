# codex-bridge — Claude ↔ Codex collaboration kit

A drop-in folder that makes **Claude Code** and **Codex (OpenAI CLI)**
pressure-test each other's work automatically: one model plans/reviews while the
other implements, with real multi-round discussion and **zero manual
copy-paste**. Fully portable — no project-specific paths.

## What you get

- **Three collaboration modes**, triggered by a keyword you append to a request:
  - `@cx-build` — Codex implements behind a Claude **plan gate** (and optional
    Claude-authored acceptance tests); failing tests feed back with stall
    detection + cross-model diagnosis; spec-aware self-review and Claude
    cross-review run in parallel; Codex must fix-or-rebut every finding and the
    reviewer then **verifies** the fixes (`VERDICT: CLEAN|REOPEN`).
  - `@cx-guard` — Claude implements; tests run before review as ground truth;
    Codex reviews into a linted CX-NN findings ledger, then **verifies** every
    fix/waiver against the actual red/green transition.
  - `@cx-duel` — mutual-critique debate with a machine-checked disagreement
    ledger and mechanically verified citations: parallel blind round 0, a
    mandatory red-team attack before convergence stands, and an anonymized
    two-model arbiter panel for whatever remains.
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

## Install: exactly what to copy, exactly what to edit

### 1. COPY — one folder, nothing else

| Copy into your repo? | What | Why |
|---|---|---|
| ✅ **YES — the whole `codex-bridge/` folder** | every `.sh` script, every `.md` doc, `VERSION`, `.gitignore.example` | the kit is self-contained; the scripts find each other automatically |
| ❌ no | `tmp/`, `tmp/codex/` | runtime artifacts (task logs, memory, ledgers) — never copy these between repos |
| ❌ no | `tests/`, `.github/` (from the kit's home repo) | kit development only |
| optional | `install.sh` (from the kit's home repo) | does the copy + gitignore wiring for you: run it from inside your repo |

Put the folder at your **repo root** (`your-repo/codex-bridge/`). Don't rename
files inside it.

### 2. EDIT — two files in your repo, one on your machine

| File | What to do | Template |
|---|---|---|
| `your-repo/CLAUDE.md` | Paste the whole section from the template (create `CLAUDE.md` at the repo root if missing; delete the template's `#`-comment header). This is what makes Claude load the protocol every session — without it the kit is never triggered. **Adapt one thing**: if your default branch is not `main`, add a line telling Claude to always pass `--base <your-branch>`. | [`CLAUDE.md.example`](CLAUDE.md.example) |
| `your-repo/.gitignore` | Append the two runtime lines. **Recommended:** commit the `codex-bridge/` folder itself so teammates get it via `git pull`; if you prefer it untracked, also add a `codex-bridge/` line. | [`.gitignore.example`](.gitignore.example) |
| `~/.codex/config.toml` (machine-level, once) | Model/effort defaults + the **Windows sandbox fix** (`[windows] sandbox = "unelevated"`). | [`SETUP.md`](SETUP.md) §4 |

Do **not** edit `PROTOCOL.md`, `SETUP.md`, or the scripts per-repo — they are
generic on purpose, so updating the kit later stays a plain folder overwrite.

### 3. VERIFY (free, no model calls)

```bash
bash codex-bridge/doctor.sh        # validates codex login, config, python, everything
bash codex-bridge/codex_loop.sh --help
```

Then just try it: *"Add input validation to the config loader. @cx-build"*

## Updating an OLD copy of the kit in a repo

1. **Overwrite every kit file**: delete the old `.sh`/`.md`/`VERSION` files inside
   that repo's `codex-bridge/` and copy the new ones in. Keep any local-only
   files YOU added there (they are not part of the kit).
2. **Re-paste the `CLAUDE.md` section** from the NEW
   [`CLAUDE.md.example`](CLAUDE.md.example) — the mode semantics change between
   versions (plan gate, DX ledger, verify steps…), and a stale section makes
   Claude drive the new scripts with old assumptions. Re-apply your one
   adaptation (`--base <branch>`).
3. **Re-check `.gitignore`** has `tmp/codex/` and `codex-bridge/tmp/`.
4. Run `bash codex-bridge/doctor.sh`. The installed version shows in `--help`
   and every SUMMARY line (`codex-bridge vX.Y.Z`).

Runtime state (`tmp/codex/` memory + task history) is untouched by updates —
the new kit keeps reading the same memory file.

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
