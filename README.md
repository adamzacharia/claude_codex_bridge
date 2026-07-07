# claude_codex_bridge

Home of **[codex-bridge](codex-bridge/README.md)** — a drop-in kit that makes
**Claude Code** and **Codex (OpenAI CLI)** pressure-test each other's work:
one model plans/reviews while the other implements, with real multi-round
discussion, shared memory across tasks, and zero manual copy-paste.

- **Docs & install:** [codex-bridge/README.md](codex-bridge/README.md) → then
  [SETUP.md](codex-bridge/SETUP.md) and [PROTOCOL.md](codex-bridge/PROTOCOL.md)
- **Install into another repo:** run [`install.sh`](install.sh) from inside that
  repo (or just copy the `codex-bridge/` folder)
- **Health check (free):** `bash codex-bridge/doctor.sh`
- **Tests:** `bats tests/` (run by [CI](.github/workflows/ci.yml) with shellcheck)

License: MIT.
