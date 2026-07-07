#!/usr/bin/env bash
# usage_lib.sh — shared token-accounting + codex JSONL helpers for the bridge.
#
# Sourced by codex_bridge.sh, codex_loop.sh, usage_report.sh, claude_usage.sh.
# Every Codex or Claude invocation appends one row to a per-task ledger (TSV);
# the report renders a per-step breakdown plus per-side and per-model totals.
#
# Ledger v2 row (tab-separated, 10 columns):
#   <epoch>  <iso-utc>  <side>  <model>  <label>  <total>  <in>  <cached>  <out>  <rc>
# side ∈ {codex, claude}.  When the in/cached/out split is known, total is their
# sum; otherwise total is the best single "tokens used" figure for the call and
# the split columns are empty.  Ledgers written by older kit versions use the
# 8-column v1 layout (no <model>/<cached>); usage_report renders both.

# ---------------------------------------------------------------------------
# codex --json (JSONL event stream) parsers.
# `codex exec --json` emits one JSON event per line on stdout:
#   {"type":"thread.started","thread_id":"<uuid>"}          -> exact resume id
#   {"type":"turn.completed","usage":{"input_tokens":N,
#        "cached_input_tokens":N,"output_tokens":N}}        -> real usage
#   {"type":"turn.failed","error":{"message":"..."}}        -> typed failure
# These replace the old fragile greps ("session id: ..." header, "last number
# after 'tokens used'"), which remain below only as fallbacks for CLIs
# predating --json.
# ---------------------------------------------------------------------------

# Print the thread id from the first thread.started event (empty if none).
codex_jsonl_thread_id() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  grep -a -m1 '"type":"thread\.started"' "$f" 2>/dev/null \
    | sed -n 's/.*"thread_id":"\([0-9a-fA-F-]*\)".*/\1/p'
}

# Print "in cached out" (space-separated) summed over ALL turn.completed events
# in the stream (a single exec run normally has one turn; resume runs report
# only the new turn). Empty output if no usage events were found.
codex_jsonl_usage() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  grep -a '"type":"turn\.completed"' "$f" 2>/dev/null | awk '
    {
      if (match($0, /"input_tokens":[0-9]+/))        inp += substr($0, RSTART+15, RLENGTH-15);
      if (match($0, /"cached_input_tokens":[0-9]+/)) cch += substr($0, RSTART+22, RLENGTH-22);
      if (match($0, /"output_tokens":[0-9]+/))       out += substr($0, RSTART+16, RLENGTH-16);
      n++;
    }
    END { if (n > 0) printf "%d %d %d", inp, cch, out }
  '
}

# Print the error message from the last turn.failed event (empty if none).
# Best-effort: stops at the first unescaped quote, which covers real CLI
# messages ("usage limit reached...", "stream disconnected...").
codex_jsonl_error() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  grep -a '"type":"turn\.failed"' "$f" 2>/dev/null | tail -1 \
    | sed -n 's/.*"message":"\([^"]*\)".*/\1/p'
}

# ---------------------------------------------------------------------------
# v1 fallback: extract the integer Codex reports as "tokens used" from a raw
# human-oriented codex exec log. Handles both "tokens used: 211,795" and
# "tokens used\n211,795" (with ANSI). Known limitation (why JSONL is preferred):
# if the agent's MESSAGE contains the phrase "tokens used", this can grab a
# number from the message body instead.
# ---------------------------------------------------------------------------
usage_extract_codex_tokens() {
  local log="$1" n
  [ -f "$log" ] || { printf ''; return; }
  n="$(grep -aiE -A1 'tokens used' "$log" 2>/dev/null \
        | grep -aoE '[0-9][0-9,]*' | tail -1 | tr -d ',')"
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Ledger writers
# ---------------------------------------------------------------------------

# Append one v2 usage row.
# Args: ledger side model label total [in] [cached] [out] [rc]
usage_record() {
  local ledger="$1" side="$2" model="$3" label="$4" total="${5:-}" \
        in="${6:-}" cached="${7:-}" out="${8:-}" rc="${9:-0}"
  [ -n "$ledger" ] || return 0
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s 2>/dev/null || echo 0)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
    "$side" "${model:--}" "$label" "${total:-0}" "$in" "$cached" "$out" "$rc" \
    >> "$ledger"
}

# Record one Codex call: prefer the JSONL usage event, fall back to the v1
# "tokens used" log grep. Args: ledger label jsonl log rc model
usage_record_codex() {
  local ledger="$1" label="$2" jsonl="$3" log="$4" rc="${5:-0}" model="${6:-}"
  local split in cached out total
  split="$(codex_jsonl_usage "$jsonl")"
  if [ -n "$split" ]; then
    in="${split%% *}"; out="${split##* }"
    cached="${split#* }"; cached="${cached%% *}"
    total=$((in + cached + out))
    usage_record "$ledger" codex "$model" "$label" "$total" "$in" "$cached" "$out" "$rc"
  else
    total="$(usage_extract_codex_tokens "$log")"
    usage_record "$ledger" codex "$model" "$label" "${total:-0}" "" "" "" "$rc"
  fi
}

# Back-compat shim for the old call sites (v1 signature):
# Args: ledger label log rc
usage_record_codex_from_log() {
  usage_record_codex "$1" "$2" "" "$3" "${4:-0}" ""
}

# ---------------------------------------------------------------------------
# Render a human-readable breakdown + totals from a ledger to stdout.
# Accepts mixed v1 (8-col) and v2 (10-col) rows.
# ---------------------------------------------------------------------------
usage_report() {
  local ledger="$1"
  if [ ! -s "$ledger" ]; then
    echo "  (no token usage recorded)"
    return 0
  fi
  awk -F'\t' '
    {
      if (NF >= 10) { side=$3; model=$4; label=$5; tot=$6+0; inp=$7; cch=$8; out=$9 }
      else          { side=$3; model="-"; label=$4; tot=$5+0; inp=$6; cch="";  out=$7 }
      n++; s_side[n]=side; s_model[n]=model; s_label[n]=label;
      s_tot[n]=tot; s_in[n]=inp; s_cch[n]=cch; s_out[n]=out;
      sum[side]+=tot; grand+=tot;
      if (model != "-" && model != "") msum[model]+=tot;
    }
    END {
      printf "  %-7s %-14s %-24s %12s  %s\n", "side", "model", "step", "tokens", "(in/cached/out)";
      for (i=1;i<=n;i++) {
        io = "";
        if (s_in[i]!="" || s_out[i]!="")
          io = sprintf("(%s/%s/%s)", s_in[i], (s_cch[i]==""?"?":s_cch[i]), s_out[i]);
        printf "  %-7s %-14s %-24s %12d  %s\n", s_side[i], s_model[i], s_label[i], s_tot[i], io;
      }
      printf "  %s\n", "----------------------------------------------------------------------";
      for (m in msum) printf "  %-22s %12d\n", m " total:", msum[m];
      printf "  Codex total:  %12d\n", sum["codex"]+0;
      printf "  Claude total: %12d  %s\n", sum["claude"]+0,
             (sum["claude"]+0==0 ? "(none recorded — run claude_usage.sh end <task> for the interactive session)" : "");
      printf "  Grand total:  %12d\n", grand+0;
    }
  ' "$ledger"
}
