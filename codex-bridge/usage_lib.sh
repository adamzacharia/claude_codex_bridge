#!/usr/bin/env bash
# usage_lib.sh — shared token-accounting helpers for the Codex↔Claude bridge.
#
# Sourced by codex_bridge.sh, codex_loop.sh, and usage_report.sh. Every Codex or
# Claude invocation appends one row to a per-task ledger (TSV); the report
# renders a per-step breakdown plus per-model totals.
#
# Ledger row (tab-separated):
#   <epoch>  <iso-utc>  <side>  <label>  <total>  <in>  <out>  <rc>
# side ∈ {codex, claude}.  total = best single "tokens used" figure for the call
# (for Claude, in+out+cache).  in/out are split when known (Claude), else empty.

# Extract the integer Codex reports as "tokens used" from a raw codex exec log.
# Handles both "tokens used: 211,795" and "tokens used\n211,795" (with ANSI).
usage_extract_codex_tokens() {
  local log="$1" n
  [ -f "$log" ] || { printf ''; return; }
  n="$(grep -aiE -A1 'tokens used' "$log" 2>/dev/null \
        | grep -aoE '[0-9][0-9,]*' | tail -1 | tr -d ',')"
  printf '%s' "$n"
}

# Append one usage row.  Args: ledger side label total [in] [out] [rc]
usage_record() {
  local ledger="$1" side="$2" label="$3" total="${4:-}" in="${5:-}" out="${6:-}" rc="${7:-0}"
  [ -n "$ledger" ] || return 0
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s 2>/dev/null || echo 0)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
    "$side" "$label" "${total:-0}" "$in" "$out" "$rc" \
    >> "$ledger"
}

# Convenience: extract Codex tokens from a log and record them in one call.
usage_record_codex_from_log() {
  local ledger="$1" label="$2" log="$3" rc="${4:-0}" n
  n="$(usage_extract_codex_tokens "$log")"
  usage_record "$ledger" codex "$label" "${n:-0}" "" "" "$rc"
}

# Render a human-readable breakdown + totals from a ledger to stdout.
usage_report() {
  local ledger="$1"
  if [ ! -s "$ledger" ]; then
    echo "  (no token usage recorded)"
    return 0
  fi
  awk -F'\t' '
    {
      side=$3; label=$4; tot=$5+0;
      n++; s_side[n]=side; s_label[n]=label; s_tot[n]=tot; s_in[n]=$6; s_out[n]=$7;
      sum[side]+=tot; grand+=tot;
    }
    END {
      printf "  %-7s %-26s %12s  %s\n", "side", "step", "tokens", "(in/out)";
      for (i=1;i<=n;i++) {
        io = (s_in[i]!="" || s_out[i]!="") ? sprintf("(%s/%s)", s_in[i], s_out[i]) : "";
        printf "  %-7s %-26s %12d  %s\n", s_side[i], s_label[i], s_tot[i], io;
      }
      printf "  %s\n", "-------------------------------------------------------";
      printf "  Codex total:  %12d\n", sum["codex"]+0;
      printf "  Claude total: %12d  %s\n", sum["claude"]+0,
             (sum["claude"]+0==0 ? "(headless only; interactive Claude not counted — see note)" : "");
      printf "  Grand total:  %12d\n", grand+0;
    }
  ' "$ledger"
}
