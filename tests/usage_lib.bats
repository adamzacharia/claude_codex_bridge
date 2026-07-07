#!/usr/bin/env bats
# Unit tests for codex-bridge/usage_lib.sh (JSONL parsers + ledger + report).

setup() {
  load_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "$load_dir/codex-bridge/usage_lib.sh"
  TMP="$BATS_TEST_TMPDIR"
}

# --- codex --json parsers -----------------------------------------------------

@test "codex_jsonl_thread_id: extracts the id from thread.started" {
  cat > "$TMP/run.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"0198aaaa-bbbb-cccc-dddd-eeeeffff0000"}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5}}
EOF
  [ "$(codex_jsonl_thread_id "$TMP/run.jsonl")" = "0198aaaa-bbbb-cccc-dddd-eeeeffff0000" ]
}

@test "codex_jsonl_thread_id: empty when absent" {
  printf '{"type":"other"}\n' > "$TMP/run.jsonl"
  [ -z "$(codex_jsonl_thread_id "$TMP/run.jsonl")" ]
}

@test "codex_jsonl_usage: sums in/cached/out over turn.completed events" {
  cat > "$TMP/run.jsonl" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":2,"output_tokens":3}}
EOF
  [ "$(codex_jsonl_usage "$TMP/run.jsonl")" = "101 42 10" ]
}

@test "codex_jsonl_usage: empty when no usage events" {
  printf '{"type":"thread.started","thread_id":"x"}\n' > "$TMP/run.jsonl"
  [ -z "$(codex_jsonl_usage "$TMP/run.jsonl")" ]
}

@test "codex_jsonl_error: extracts turn.failed message" {
  printf '{"type":"turn.failed","error":{"message":"usage limit reached, try later"}}\n' > "$TMP/run.jsonl"
  [ "$(codex_jsonl_error "$TMP/run.jsonl")" = "usage limit reached, try later" ]
}

# --- v1 fallback ---------------------------------------------------------------

@test "usage_extract_codex_tokens: same-line format with commas" {
  printf 'blah\ntokens used: 211,795\n' > "$TMP/run.log"
  [ "$(usage_extract_codex_tokens "$TMP/run.log")" = "211795" ]
}

@test "usage_extract_codex_tokens: two-line format" {
  printf 'Tokens used\n1,234\n' > "$TMP/run.log"
  [ "$(usage_extract_codex_tokens "$TMP/run.log")" = "1234" ]
}

# --- ledger + report -------------------------------------------------------------

@test "usage_record_codex: prefers JSONL split over log grep" {
  cat > "$TMP/run.jsonl" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":25}}
EOF
  printf 'tokens used: 999999\n' > "$TMP/run.log"
  usage_record_codex "$TMP/ledger.tsv" consult "$TMP/run.jsonl" "$TMP/run.log" 0 gpt-5.5
  row="$(cat "$TMP/ledger.tsv")"
  [[ "$row" == *"codex	gpt-5.5	consult	175	100	50	25	0"* ]]
}

@test "usage_record_codex: falls back to log grep without JSONL" {
  printf 'tokens used: 4,242\n' > "$TMP/run.log"
  usage_record_codex "$TMP/ledger.tsv" review "" "$TMP/run.log" 0 gpt-5.5
  row="$(cat "$TMP/ledger.tsv")"
  [[ "$row" == *"codex	gpt-5.5	review	4242	"* ]]
}

@test "usage_report: renders v2 rows with per-side totals" {
  usage_record "$TMP/ledger.tsv" codex gpt-5.5 consult 175 100 50 25 0
  usage_record "$TMP/ledger.tsv" claude session review 60 10 40 10 0
  run usage_report "$TMP/ledger.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex total:"*"175"* ]]
  [[ "$output" == *"Claude total:"*"60"* ]]
  [[ "$output" == *"Grand total:"*"235"* ]]
}

@test "usage_report: still renders old v1 (8-column) rows" {
  printf '1700000000\t2023-11-14T00:00:00Z\tcodex\tconsult\t500\t\t\t0\n' > "$TMP/old.tsv"
  run usage_report "$TMP/old.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex total:"*"500"* ]]
}

@test "usage_report: empty ledger says so" {
  : > "$TMP/none.tsv"
  run usage_report "$TMP/none.tsv"
  [[ "$output" == *"no token usage recorded"* ]]
}
