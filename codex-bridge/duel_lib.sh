#!/usr/bin/env bash
# duel_lib.sh — pure, side-effect-free helpers shared by codex_loop.sh and the
# test suite. Keep these free of globals other than CONV_TOKEN so they stay
# unit-testable with bats (tests/duel_lib.bats).

rr() { printf '%02d' "$1"; }     # zero-padded round label

# Byte-safe truncation guard so a pathological message cannot balloon the next
# prompt. head -c / wc -c are present in git-bash.
truncate_bytes() {
  local src="$1" cap="$2"
  [ -f "$src" ] || return 0
  if [ "$(wc -c <"$src")" -gt "$cap" ]; then
    head -c "$cap" "$src"
    printf '\n...[truncated at %s bytes]...\n' "$cap"
  else
    cat "$src"
  fi
}

# Last-N-bytes variant for append-only files (memory, journals): the newest
# content is at the END, so tail instead of head.
tail_bytes() {
  local src="$1" cap="$2"
  [ -f "$src" ] || return 0
  if [ "$(wc -c <"$src")" -gt "$cap" ]; then
    printf '...[older entries trimmed; showing last %s bytes]...\n' "$cap"
    tail -c "$cap" "$src"
  else
    cat "$src"
  fi
}

# Converged ONLY if the last non-empty line, stripped of surrounding list/quote/
# emphasis markers and trailing punctuation, EXACTLY equals the token. Tolerates
# **CONVERGED**, `CONVERGED`, "- CONVERGED", "CONVERGED."; rejects substrings in
# prose like "not CONVERGED yet". CRLF-safe: the \r is stripped BEFORE awk's NF
# test so a Windows file ending "CONVERGED\r\n\r\n" still converges (a lone \r
# line would otherwise count as non-empty and mask the token).
converged_side() {
  local file="$1" last
  [ -f "$file" ] || return 1
  last="$(awk '{ sub(/\r$/, "") } NF { l = $0 } END { print l }' "$file")"
  last="$(printf '%s' "$last" | sed -e 's/^[[:space:]>*_`#-]*//' -e 's/[[:space:]*_`.!]*$//')"
  [ "$last" = "${CONV_TOKEN:-CONVERGED}" ]
}

# Mint a Claude session UUID up front so we NEVER parse claude output to thread.
# Group both branches before `tr` (| binds tighter than ||) and strip CR/LF.
mint_claude_sid() {
  { python -c 'import uuid,sys;sys.stdout.write(str(uuid.uuid4()))' 2>/dev/null \
    || powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString()" 2>/dev/null; } \
    | tr -d '\r\n'
}
