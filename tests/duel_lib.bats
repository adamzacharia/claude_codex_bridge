#!/usr/bin/env bats
# Unit tests for the pure helpers in codex-bridge/duel_lib.sh.

setup() {
  load_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "$load_dir/codex-bridge/duel_lib.sh"
  TMP="$BATS_TEST_TMPDIR"
}

# --- converged_side ---------------------------------------------------------

@test "converged_side: plain token" {
  printf 'answer here\nCONVERGED\n' > "$TMP/a.md"
  converged_side "$TMP/a.md"
}

@test "converged_side: bold token" {
  printf 'answer\n**CONVERGED**\n' > "$TMP/a.md"
  converged_side "$TMP/a.md"
}

@test "converged_side: backtick + list marker + trailing period" {
  printf 'answer\n- `CONVERGED`.\n' > "$TMP/a.md"
  converged_side "$TMP/a.md"
}

@test "converged_side: CRLF line endings with trailing blank line" {
  printf 'answer\r\nCONVERGED\r\n\r\n' > "$TMP/a.md"
  converged_side "$TMP/a.md"
}

@test "converged_side: rejects token inside prose" {
  printf 'we have not CONVERGED yet\n' > "$TMP/a.md"
  ! converged_side "$TMP/a.md"
}

@test "converged_side: rejects token mid-file" {
  printf 'CONVERGED\nbut actually more to say\n' > "$TMP/a.md"
  ! converged_side "$TMP/a.md"
}

@test "converged_side: missing file returns non-zero" {
  ! converged_side "$TMP/nope.md"
}

@test "converged_side: custom CONV_TOKEN" {
  CONV_TOKEN="DONE_DEAL"
  printf 'x\nDONE_DEAL\n' > "$TMP/a.md"
  converged_side "$TMP/a.md"
  unset CONV_TOKEN
}

# --- truncate_bytes / tail_bytes ---------------------------------------------

@test "truncate_bytes: passes small files through unchanged" {
  printf 'hello world\n' > "$TMP/s.md"
  run truncate_bytes "$TMP/s.md" 1000
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "truncate_bytes: caps large files and marks truncation" {
  head -c 500 /dev/zero | tr '\0' 'x' > "$TMP/big.md"
  run truncate_bytes "$TMP/big.md" 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"...[truncated at 100 bytes]..."* ]]
  [ "${#lines[0]}" -le 200 ]
}

@test "tail_bytes: keeps the END of the file" {
  printf 'OLD-OLD-OLD-OLD-OLD-NEWEST' > "$TMP/m.md"
  run tail_bytes "$TMP/m.md" 6
  [[ "$output" == *"NEWEST"* ]]
  [[ "$output" != *"OLD-OLD-OLD-OLD-OLD"* ]]
}

# --- rr / mint_claude_sid -----------------------------------------------------

@test "rr: zero-pads" {
  [ "$(rr 3)" = "03" ]
  [ "$(rr 12)" = "12" ]
}

@test "mint_claude_sid: produces a UUID when python is available" {
  command -v python >/dev/null 2>&1 || skip "python not installed"
  sid="$(mint_claude_sid)"
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# --- DX disagreement ledger --------------------------------------------------

@test "dx_ids: extracts ids, optionally filtered by status" {
  cat > "$TMP/turn.md" <<'EOF'
answer text
- DX-01 | OPEN | tabs vs spaces | evidence: style.md:3
- **DX-02** | AGREED | indent width | evidence: style.md:9
- DX-03 | CONCEDED-CODEX | quoting | evidence: cfg.py:12
TOTAL OPEN: 1
EOF
  [ "$(dx_ids "$TMP/turn.md" | tr '\n' ' ')" = "DX-01 DX-02 DX-03 " ]
  [ "$(dx_ids "$TMP/turn.md" OPEN)" = "DX-01" ]
}

@test "dx_open_count: counts OPEN lines, CRLF-tolerant" {
  printf -- '- DX-01 | OPEN | a | evidence: x:1\r\n- DX-02 | AGREED | b | evidence: y:2\r\n' > "$TMP/turn.md"
  [ "$(dx_open_count "$TMP/turn.md")" = "1" ]
}

@test "dx_open_count: zero when no ledger" {
  printf 'no ledger here\n' > "$TMP/turn.md"
  [ "$(dx_open_count "$TMP/turn.md")" = "0" ]
}

@test "dx_vanished: flags OPEN points that silently disappeared" {
  printf -- '- DX-01 | OPEN | a | evidence: x:1\n- DX-02 | OPEN | b | evidence: y:2\n' > "$TMP/prev.md"
  printf -- '- DX-02 | AGREED | b | evidence: y:2\n' > "$TMP/cur.md"
  [ "$(dx_vanished "$TMP/prev.md" "$TMP/cur.md")" = "DX-01" ]
}

@test "dx_vanished: nothing when points carried forward or resolved" {
  printf -- '- DX-01 | OPEN | a | evidence: x:1\n' > "$TMP/prev.md"
  printf -- '- DX-01 | CONCEDED-CLAUDE | a | evidence: x:1\n' > "$TMP/cur.md"
  [ -z "$(dx_vanished "$TMP/prev.md" "$TMP/cur.md")" ]
}

# --- CX findings lint + reconciliation gate -----------------------------------

@test "lint_findings: clean ledger produces no violations" {
  mkdir -p "$TMP/repo"; printf 'l1\nl2\nl3\n' > "$TMP/repo/app.py"
  cat > "$TMP/f.md" <<'EOF'
- [ ] CX-01 | MAJOR | app.py:2 | off-by-one in loop
TOTAL: 1
EOF
  [ -z "$(lint_findings "$TMP/f.md" "$TMP/repo")" ]
}

@test "lint_findings: catches bad severity, missing file, out-of-range line, TOTAL mismatch" {
  mkdir -p "$TMP/repo"; printf 'l1\n' > "$TMP/repo/app.py"
  cat > "$TMP/f.md" <<'EOF'
- [ ] CX-01 | HUGE | app.py:1 | bad severity
- [ ] CX-02 | MINOR | ghost.py:5 | missing file
- [ ] CX-03 | MINOR | app.py:99 | line too big
TOTAL: 5
EOF
  out="$(lint_findings "$TMP/f.md" "$TMP/repo")"
  [[ "$out" == *"CX-01: severity 'HUGE'"* ]]
  [[ "$out" == *"CX-02: file not found: ghost.py"* ]]
  [[ "$out" == *"CX-03: line 99 beyond end"* ]]
  [[ "$out" == *"TOTAL says 5 but 3"* ]]
}

@test "lint_findings: flags a missing TOTAL line" {
  mkdir -p "$TMP/repo"; printf 'l1\n' > "$TMP/repo/a.py"
  printf -- '- [ ] CX-01 | MINOR | a.py:1 | ok\n' > "$TMP/f.md"
  [[ "$(lint_findings "$TMP/f.md" "$TMP/repo")" == *"missing 'TOTAL:"* ]]
}

@test "recon_missing: set-diff of CX ids (CX-1 does not match CX-10)" {
  printf -- '- [ ] CX-1 | MINOR | a:1 | x\n- [ ] CX-10 | MINOR | a:1 | y\n' > "$TMP/f.md"
  printf 'CX-10: FIXED — done\n' > "$TMP/r.md"
  [ "$(recon_missing "$TMP/f.md" "$TMP/r.md")" = "CX-1" ]
}

@test "recon_missing: empty when every id is ruled" {
  printf -- '- [ ] CX-01 | MINOR | a:1 | x\n' > "$TMP/f.md"
  printf 'CX-01: WAIVED — intentional\n' > "$TMP/r.md"
  [ -z "$(recon_missing "$TMP/f.md" "$TMP/r.md")" ]
}
