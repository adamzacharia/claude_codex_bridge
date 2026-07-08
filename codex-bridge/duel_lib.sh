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

# ---------------------------------------------------------------------------
# DX disagreement-ledger parsers (duel). Ledger grammar, one line per point:
#   - DX-01 | OPEN|AGREED|CONCEDED-CLAUDE|CONCEDED-CODEX | <one-line> | evidence: <path:line or URL>
# ending with 'TOTAL OPEN: <n>'. Tolerant of **bold**/`backtick` markers and CRLF.
# ---------------------------------------------------------------------------

# All DX ledger lines, CR-stripped, bullets/markdown markers removed.
dx_lines() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | grep -aE '^[[:space:]]*[-*][[:space:]]*(\*\*|`)?DX-[0-9]+' \
    | sed -e 's/[*`]//g' -e 's/^[[:space:]]*[-*][[:space:]]*//'
}

# Unique DX ids in a file; optional 2nd arg filters by status field.
dx_ids() {
  if [ -n "${2:-}" ]; then
    dx_lines "$1" | grep -E "\|[[:space:]]*${2}[[:space:]]*\|" | grep -oE '^DX-[0-9]+'
  else
    dx_lines "$1" | grep -oE '^DX-[0-9]+'
  fi | sort -u
}

dx_open_count() { dx_ids "$1" OPEN | grep -c . || true; }

# Ids that were OPEN in $1 (previous turn) but VANISHED entirely from $2
# (current turn) — points silently dropped without a terminal status.
dx_vanished() {
  local prev="$1" cur="$2" id
  [ -f "$prev" ] || return 0
  for id in $(dx_ids "$prev" OPEN); do
    dx_ids "$cur" | grep -qx "$id" || echo "$id"
  done
}

# ---------------------------------------------------------------------------
# CX findings-ledger lint (guard/build reviews). Expected grammar per line:
#   - [ ] CX-NN | BLOCKER|MAJOR|MINOR | <file>:<line> | <one-line summary>
# ending with 'TOTAL: <n>'. Prints one violation per line; silent when clean.
# ---------------------------------------------------------------------------
lint_findings() {
  local f="$1" root="${2:-.}" n=0
  [ -f "$f" ] || { echo "findings file missing: $f"; return 0; }
  local line id nfields sev loc path lno flen
  while IFS= read -r line; do
    line="${line%$'\r'}"
    printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]*\[.\][[:space:]]*(\*\*|`)?CX-[0-9]+' || continue
    n=$((n + 1))
    id="$(printf '%s' "$line" | grep -oE 'CX-[0-9]+' | head -1)"
    nfields="$(printf '%s' "$line" | awk -F'|' '{print NF}')"
    if [ "$nfields" -lt 4 ]; then
      echo "$id: expected 4 pipe-separated fields (id | severity | file:line | summary)"
      continue
    fi
    sev="$(printf '%s' "$line" | awk -F'|' '{gsub(/[* `]/, "", $2); print $2}')"
    case "$sev" in
      BLOCKER|MAJOR|MINOR) ;;
      *) echo "$id: severity '$sev' is not BLOCKER|MAJOR|MINOR" ;;
    esac
    loc="$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ ]+|[ ]+$/, "", $3); gsub(/[*`]/, "", $3); print $3}')"
    path="${loc%%:*}"
    lno="${loc##*:}"
    if [ -n "$path" ]; then
      if [ ! -f "$root/$path" ]; then
        echo "$id: file not found: $path"
      elif [ "$lno" != "$loc" ] && printf '%s' "$lno" | grep -qE '^[0-9]+$'; then
        flen="$(wc -l < "$root/$path" 2>/dev/null || echo 0)"
        [ "$lno" -le "$((flen + 1))" ] || echo "$id: line $lno beyond end of $path ($flen lines)"
      fi
    fi
  done < "$f"
  local total
  total="$(tr -d '\r' < "$f" | grep -aoE 'TOTAL: *[0-9]+' | tail -1 | grep -oE '[0-9]+')"
  if [ -z "$total" ]; then
    echo "missing 'TOTAL: <n>' line"
  elif [ "$total" -ne "$n" ]; then
    echo "TOTAL says $total but $n CX line(s) found"
  fi
}

# CX ids present in the findings ledger ($1) but missing a ruling in the
# reconciliation file ($2) — the completeness gate for guard verify.
recon_missing() {
  local findings="$1" recon="$2" id
  [ -f "$findings" ] || return 0
  for id in $(tr -d '\r' < "$findings" 2>/dev/null | grep -oE 'CX-[0-9]+' | sort -u); do
    tr -d '\r' < "$recon" 2>/dev/null | grep -qE "${id}([^0-9]|\$)" || echo "$id"
  done
}
