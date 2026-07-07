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
