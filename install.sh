#!/usr/bin/env bash
# install.sh — install or update the codex-bridge kit into the CURRENT repo.
#
# From a local checkout of this repo:
#   bash /path/to/claude_codex_bridge/install.sh            # install into cwd repo
#   bash /path/to/claude_codex_bridge/install.sh --update   # overwrite an older copy
#
# Straight from GitHub (set the repo you host the kit in):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh \
#     | bash -s -- --repo <owner>/<repo> [--update]
#
# What it does: copies codex-bridge/ in (VERSION-checked), idempotently appends
# the runtime dirs to .gitignore, and prints the CLAUDE.md snippet to paste.
set -uo pipefail

REPO=""
REF="main"
UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2 ;;
    --ref)    REF="$2"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "install.sh: $*" >&2; exit 1; }

TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run from inside the git repo you want to install into"
DEST="$TARGET/codex-bridge"

# Source: prefer a kit sitting next to this script (local mode), else download.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
SRC=""
CLEANUP=""
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/codex-bridge/codex_bridge.sh" ]; then
  SRC="$SELF_DIR/codex-bridge"
else
  [ -n "$REPO" ] || die "not running from a local checkout — pass --repo <owner>/<repo> to download"
  command -v curl >/dev/null 2>&1 || die "curl is required for --repo mode"
  TMP="$(mktemp -d)"
  CLEANUP="$TMP"
  echo "downloading $REPO@$REF ..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" \
    | tar -xz -C "$TMP" || die "download/extract failed"
  SRC="$(find "$TMP" -maxdepth 2 -type d -name codex-bridge | head -1)"
  [ -n "$SRC" ] && [ -f "$SRC/codex_bridge.sh" ] || die "codex-bridge/ not found in the downloaded archive"
fi

SRC_VER="$(cat "$SRC/VERSION" 2>/dev/null || echo '?')"
if [ -d "$DEST" ]; then
  DEST_VER="$(cat "$DEST/VERSION" 2>/dev/null || echo 'pre-0.2 (no VERSION)')"
  if [ "$UPDATE" -ne 1 ]; then
    echo "codex-bridge already installed (installed: $DEST_VER, available: $SRC_VER)."
    echo "re-run with --update to overwrite. Diff preview:"
    diff -rq "$DEST" "$SRC" 2>/dev/null | grep -v '/tmp/' || echo "  (no differences)"
    exit 1
  fi
  echo "updating codex-bridge: $DEST_VER -> $SRC_VER"
else
  echo "installing codex-bridge $SRC_VER into $DEST"
fi

mkdir -p "$DEST"
# Copy the kit, excluding any runtime scratch a source copy might carry.
(cd "$SRC" && tar -cf - --exclude='./tmp' .) | (cd "$DEST" && tar -xf -) || die "copy failed"
[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"

# Idempotently git-ignore the runtime dirs (the kit itself is meant to be
# committed so the whole team gets it; see README).
GI="$TARGET/.gitignore"
touch "$GI"
for line in 'tmp/codex/' 'codex-bridge/tmp/'; do
  grep -qxF "$line" "$GI" || printf '%s\n' "$line" >> "$GI"
done
echo "gitignore: ensured tmp/codex/ + codex-bridge/tmp/"

echo
echo "== next steps =="
echo "1. Validate the toolchain (free):   bash codex-bridge/doctor.sh"
echo "2. Paste the snippet from codex-bridge/CLAUDE.md.example into your repo's CLAUDE.md"
echo "3. Try it:  \"Add input validation to the config loader. @cx-build\""
