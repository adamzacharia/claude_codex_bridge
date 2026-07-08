#!/usr/bin/env bash
# claude_usage.sh — record the INTERACTIVE Claude Code session's token usage
# into a task's ledger, closing the "Claude here = your interactive session
# (not bridge-measured)" gap in build/guard summaries.
#
# How: Claude Code writes every session transcript to
#   ~/.claude/projects/<repo-path-slug>/*.jsonl
# and each assistant message line carries a message.usage object. We snapshot
# per-file byte offsets at `begin`, then at `end` parse only what was appended
# since and sum the usage into one ledger row (side=claude, label=interactive).
#
#   bash codex-bridge/claude_usage.sh begin  <task-id>            # snapshot (loop auto-runs this)
#   bash codex-bridge/claude_usage.sh end    <task-id> [label]    # record delta + consume snapshot
#   bash codex-bridge/claude_usage.sh status <task-id>            # show delta, record nothing
#
# The live Claude session should run `end` when it declares the task done (the
# PROTOCOL says so), capturing planning + reconciliation turns, not just the
# window while codex_loop.sh happened to be running.
set -uo pipefail

CMD="${1:-}"
TASK="${2:-}"
LABEL="${3:-interactive}"

case "$CMD" in begin|end|status) ;; *)
  echo "usage: claude_usage.sh <begin|end|status> <task-id> [label]" >&2; exit 2 ;;
esac
[ -n "$TASK" ] || { echo "claude_usage: task id required" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TASK_DIR="$ROOT/tmp/codex/tasks/$TASK"
MARKER="$TASK_DIR/claude_ui.offsets.tsv"
LEDGER="$TASK_DIR/usage.tsv"
mkdir -p "$TASK_DIR"

PY="$(command -v python 2>/dev/null || command -v py 2>/dev/null || true)"
if [ -z "$PY" ]; then
  echo "claude_usage: python not found — cannot parse Claude Code transcripts" >&2
  exit 1
fi

if [ "$CMD" = "begin" ] && [ -f "$MARKER" ]; then
  echo "claude_usage: snapshot already exists for task $TASK (keeping the earlier begin)" >&2
  exit 0
fi

"$PY" - "$CMD" "$ROOT" "$MARKER" "$LEDGER" "$LABEL" <<'PYEOF'
import glob, json, os, re, sys, time

cmd, root, marker, ledger, label = sys.argv[1:6]

# Claude Code project-dir slug: the repo's native path with every
# non-alphanumeric character replaced by '-'
# (C:\Users\me\repo -> C--Users-me-repo, /home/me/repo -> -home-me-repo).
native_root = os.path.abspath(root)
slug = re.sub(r"[^A-Za-z0-9]", "-", native_root)
proj = os.path.join(os.path.expanduser("~"), ".claude", "projects", slug)
if not os.path.isdir(proj):
    sys.stderr.write("claude_usage: no Claude Code transcripts at %s\n" % proj)
    sys.exit(1)

def transcripts():
    return sorted(glob.glob(os.path.join(proj, "*.jsonl")))

if cmd == "begin":
    with open(marker, "w", encoding="utf-8") as f:
        for p in transcripts():
            f.write("%d\t%s\n" % (os.path.getsize(p), os.path.basename(p)))
    print("claude_usage: snapshot taken (%d transcript file(s))" % len(transcripts()))
    sys.exit(0)

# end / status: parse everything appended since the snapshot.
if not os.path.isfile(marker):
    sys.stderr.write(
        "claude_usage: no begin-snapshot for this task — run "
        "'claude_usage.sh begin <task>' first (codex_loop.sh does this "
        "automatically at task start)\n")
    sys.exit(1)

offsets = {}
for line in open(marker, encoding="utf-8"):
    line = line.rstrip("\n")
    if "\t" in line:
        size, name = line.split("\t", 1)
        offsets[name] = int(size)

inp = cached = out = 0
msgs = 0
model = ""
for p in transcripts():
    start = offsets.get(os.path.basename(p), 0)
    if os.path.getsize(p) <= start:
        continue
    with open(p, encoding="utf-8", errors="replace") as f:
        f.seek(start)
        # The snapshot may have landed mid-line; drop the partial first line.
        if start > 0:
            f.readline()
        for raw in f:
            try:
                d = json.loads(raw)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            m = d.get("message") or {}
            u = m.get("usage") or {}
            if not u:
                continue
            def g(k):
                try:
                    return int(u.get(k, 0) or 0)
                except Exception:
                    return 0
            inp += g("input_tokens")
            cached += g("cache_read_input_tokens") + g("cache_creation_input_tokens")
            out += g("output_tokens")
            msgs += 1
            model = m.get("model") or model

total = inp + cached + out
print("claude_usage: interactive delta since begin: %d assistant msgs, "
      "in=%d cached=%d out=%d total=%d%s"
      % (msgs, inp, cached, out, total, (" model=" + model) if model else ""))

if cmd == "end":
    if total == 0:
        sys.stderr.write("claude_usage: nothing new since begin — no row recorded\n")
        sys.exit(0)
    row = "\t".join([
        str(int(time.time())),
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "claude", model or "session", label,
        str(total), str(inp), str(cached), str(out), "0",
    ])
    with open(ledger, "a", encoding="utf-8") as f:
        f.write(row + "\n")
    os.remove(marker)  # consume: a second `end` cannot double-record
    print("claude_usage: recorded to %s (label=%s)" % (ledger, label))
PYEOF
