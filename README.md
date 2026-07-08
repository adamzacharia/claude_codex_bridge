# codex-bridge — Claude ↔ Codex collaboration kit

A drop-in folder that makes **Claude Code** and **Codex (OpenAI CLI)**
pressure-test each other's work automatically: one model plans/reviews while the
other implements, with real multi-round discussion and **zero manual
copy-paste**.

## 🚀 Don't want to read anything? Let Claude install it for you

Download (or clone) this repo, open **Claude Code**, fill in the two paths, and
paste this prompt — Claude does the entire setup and verifies it:

```text
I downloaded the claude_codex_bridge repo to:  <PATH-TO-THE-DOWNLOADED-FOLDER>
Install the Claude↔Codex bridge into my repo:  <PATH-TO-MY-REPO>

Do the complete setup:
1. Copy the codex-bridge/ folder from the downloaded repo into the ROOT of my
   repo (overwrite any older copy of the kit's files; do NOT copy tmp/, tests/,
   or .github/ — those are not part of the kit).
2. Add the collaboration section to my repo's CLAUDE.md (create the file if
   missing) using codex-bridge/CLAUDE.md.example as the template (drop the
   template's comment header). Detect my repo's default branch — if it is not
   "main", add a bold line saying to ALWAYS pass --base <that-branch>.
3. Append the lines from codex-bridge/.gitignore.example to my repo's
   .gitignore (idempotently). Ask me whether I want the codex-bridge/ folder
   itself committed (team-friendly) or gitignored (local-only), and wire it.
4. Check ~/.codex/config.toml against codex-bridge/SETUP.md section 4 — on
   Windows make sure it has [windows] sandbox = "unelevated" — and fix it.
5. Run: bash codex-bridge/doctor.sh   and fix anything that FAILs.
6. Finish with a free smoke test from my repo root:
   printf 'smoke test' | bash codex-bridge/codex_loop.sh --mode build --dry-run
   Then show me, in 5 lines, how I trigger @cx-build, @cx-guard and @cx-duel.
```

That's it — from then on you just end any request with `@cx-build`,
`@cx-guard`, or `@cx-duel`.

## What you get

- **Three collaboration modes**, triggered by a keyword you append to a request:
  - `@cx-build` — Codex implements; Claude reviews the diff.
  - `@cx-guard` — Claude implements; Codex reviews over threaded rounds.
  - `@cx-duel` — mutual-critique debate: both answer the same task and critique
    each other every round until they converge.
- **Hands-off orchestration** — Claude drives Codex headlessly for you.
- **Automatic token accounting** — per-call Codex/Claude usage in every summary.

## 60-second install

1. Copy this whole `codex-bridge/` folder into the root of your repo.
2. Add these lines to your repo's `CLAUDE.md` (create it if missing) so Claude
   loads the protocol every session — a ready-to-paste version is in
   [`CLAUDE.md.example`](CLAUDE.md.example):

   > Claude ↔ Codex collaboration is enabled via `codex-bridge/`. Read
   > `codex-bridge/PROTOCOL.md` and follow it for all non-trivial work.

3. Git-ignore the runtime dir (see [`.gitignore.example`](.gitignore.example)):

   ```
   codex-bridge/tmp/
   tmp/codex/
   ```

4. Read [`SETUP.md`](SETUP.md) for prerequisites (Codex CLI, `~/.codex/config.toml`,
   the Windows sandbox fix) and a smoke test.

Then just try it: *"Add input validation to the config loader. @cx-build"*

## Files

| File | What it is |
|---|---|
| `PROTOCOL.md` | The full working agreement — read this first. |
| `SETUP.md` | Prerequisites, Codex config, smoke test. |
| `CLAUDE.md.example` | Generic snippet to paste into your repo's `CLAUDE.md`. |
| `codex_bridge.sh` | Low-level single Codex call (`consult` / `build`, threaded via `--resume`). |
| `codex_loop.sh` | Hands-off orchestrator for `build` / `guard` / `duel` modes. |
| `usage_lib.sh` | Shared token-accounting helpers. |
| `usage_report.sh` | Print recorded Codex/Claude token usage. |

## Requirements

Each person who uses this needs the following on **their own machine** — the
folder alone can't set these up:

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
- The two scripts locate each other automatically, so the folder can live
  anywhere in your repo as long as the scripts stay together.

## License

MIT — do whatever you like; no warranty.
