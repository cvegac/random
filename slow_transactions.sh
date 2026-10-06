#!/usr/bin/env bash
# Lists the transactions slower than THRESHOLD_MS end to end in the mngr, with the time split between the
# mngr itself (proxy) and the adapter it calls, plus every ESB step. Log groups come from NexusGeneral.json
# (see cw_groups in lib/cw.sh).
#   total_ms   = sum of the mngr ESB step times ([rquid]...[paso][tiempo unidad] lines)
#   adapter_ms = adapter ::AUDIT::RESP:: time - ::AUDIT::REQ:: time (same X-RqUid); empty if no adapter call
#   proxy_ms   = total_ms - adapter_ms (negative = no ESB step wraps the adapter call)
#
# Step 1 aggregates per transaction inside CloudWatch and returns only the slow ones; step 2 fetches the
# steps, service and channel (adapter X-Name) of just those, in batches of rquids.
#
# Usage:  ./slow_transactions.sh "2026-10-06 08:00:00" "2026-10-06 09:00:00"
#         (times are Colombia local time, UTC-5)
# Output: results/slow_<start>__<end>/slow_transactions.csv, slowest first
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, DASHBOARD_JSON, DEBUG (0/1/2),
#                    THRESHOLD_MS  minimum total time to list a transaction (default 1000)
#                    CLUSTER       only this ws cluster's log groups, e.g. productsws (default: all)
#                    BATCH_SIZE    rquids per step-2 query (default 100; query length limit 10,000 chars)
set -euo pipefail

# shellcheck source=lib/cw.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/cw.sh"

OUT_BASE="${OUT_BASE:-results}"
THRESHOLD_MS="${THRESHOLD_MS:-1000}"
CLUSTER="${CLUSTER:-}"
BATCH_SIZE="${BATCH_SIZE:-100}"

[ $# -eq 2 ] || die "usage: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
[[ "$THRESHOLD_MS" =~ ^[0-9]+$ ]] || die "THRESHOLD_MS must be a whole number of milliseconds"
cw_require_tools

in_cluster() { if [ -n "$CLUSTER" ]; then grep "^/aws/ecs/srv/${CLUSTER}-" || true; else cat; fi; }
mapfile -t MNGR_GROUPS < <(cw_groups mngr | in_cluster)
mapfile -t ADAPTER_GROUPS < <(cw_groups adapter | in_cluster)
[ "${#MNGR_GROUPS[@]}" -gt 0 ] || die "no mngr log groups${CLUSTER:+ for cluster '$CLUSTER'} in $DASHBOARD_JSON"
ALL_GROUPS=("${MNGR_GROUPS[@]}" "${ADAPTER_GROUPS[@]}")

to_label() { date -d "$1" +%Y%m%d_%H%M%S; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/slow_$(to_label "$1")__$(to_label "$2")${CLUSTER:+_$CLUSTER}"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"
OUT_CSV="$OUT_DIR/slow_transactions.csv"
HEADER="trx,service,channel,total_ms,proxy_ms,adapter_ms,step_count,steps"

debug "region=$REGION window=$START..$END threshold=${THRESHOLD_MS}ms cluster=${CLUSTER:-all} out=$OUT_DIR"
cw_debug_env

# mngr ESB step line: ... [trace] [rquid][canal][/ESBService/<Service>:<version>]...[paso][tiempo unidad]
STEP_RE='/\[(?<mngrRqid>[a-f0-9\-]+)\].*\[(?<servicio>\/[^\]]+)\].*\[(?<Paso>[^\[\]]+)\]\[(?<Tiempo>[^\[\]]+)\]$/'

# ---------------------------------------------------------------- step 1: slow transactions (aggregated)

log "Step 1: transactions over ${THRESHOLD_MS} ms in ${#MNGR_GROUPS[@]} mngr + ${#ADAPTER_GROUPS[@]} adapter log groups"
# Only numeric aggregates here (sum/min/max), which ignore lines without the field. A REQ/RESP time is
# replaced by a sentinel on every other line so min/max pick only the adapter's own AUDIT lines.
q1="fields @timestamp, @message
| filter @message like \"[/\" or @message like \"::AUDIT::REQ::\" or @message like \"::AUDIT::RESP::\"
| parse @message ${STEP_RE}
| parse Tiempo /^(?<stepMs>[\d.]+)/
| parse @message /X-RqUid=(?<adpRqid>[0-9a-f\-]{36})/
| parse @message /(?<reqMark>::AUDIT::REQ::)/
| parse @message /(?<respMark>::AUDIT::RESP::)/
| fields coalesce(mngrRqid, adpRqid) as trx,
         if(isPresent(reqMark), toMillis(@timestamp), 99999999999999) as reqTs,
         if(isPresent(respMark), toMillis(@timestamp), 0) as respTs,
         if(isPresent(stepMs), 1, 0) as isStep
| filter isPresent(trx)
| stats sum(stepMs) as totalMs, sum(isStep) as stepCount, min(reqTs) as adpReq, max(respTs) as adpResp by trx
| filter stepCount > 0 and totalMs > ${THRESHOLD_MS}
| sort totalMs desc
| limit 10000"

run_query "$q1" "$START" "$END" "${ALL_GROUPS[@]}" > "$TMP/1_slow.json"
n1=$(jq '.results | length' < "$TMP/1_slow.json" | tr -d '\r')
[ "$n1" -lt 10000 ] || log "  WARNING: step 1 hit 10,000 rows (truncated). Use a shorter window or CLUSTER."

# trx<TAB>total<TAB>steps<TAB>adapter_ms ("" when the transaction has no adapter REQ+RESP pair)
jq -r "$FLAT"' | (.adpReq | tonumber) as $req | (.adpResp | tonumber) as $resp
       | [.trx, .totalMs, .stepCount, (if $resp > 0 and $req < 99999999999999 then $resp - $req else "" end)] | @tsv' \
  < "$TMP/1_slow.json" | tr -d '\r' > "$TMP/1_slow.tsv"

log "  -> $n1 transaction(s) over ${THRESHOLD_MS} ms"
[ "$n1" -gt 0 ] || { echo "$HEADER" > "$OUT_CSV"; log "Nothing slow in the window. Done -> $OUT_CSV"; exit 0; }

# ---------------------------------------------------------------- step 2: steps, service and channel

log "Step 2: steps, service and channel of those transactions"
: > "$TMP/2_details.ndjson"
mapfile -t trxs < <(cut -f1 "$TMP/1_slow.tsv")

for ((i = 0; i < ${#trxs[@]}; i += BATCH_SIZE)); do
  slice=("${trxs[@]:i:BATCH_SIZE}")
  regex=$(IFS='|'; printf '%s' "${slice[*]}")
  q2="fields @timestamp, @message
| filter @message like /${regex}/ and (@message like \"[/\" or @message like \"X-Name=\")
| parse @message ${STEP_RE}
| parse Tiempo /^(?<stepMs>[\d.]+)/
| parse @message /X-RqUid=(?<adpRqid>[0-9a-f\-]{36})/
| parse @message /X-Name=(?<xname>[^,\]]+)/
| fields coalesce(mngrRqid, adpRqid) as trx
| filter isPresent(trx)
| display @timestamp, trx, Paso, stepMs, servicio, xname
| sort @timestamp asc
| limit 10000"

  run_query "$q2" "$START" "$END" "${ALL_GROUPS[@]}" > "$TMP/2_batch.json"
  jq -c "$FLAT" < "$TMP/2_batch.json" | tr -d '\r' >> "$TMP/2_details.ndjson"

  n=$(jq '.results | length' < "$TMP/2_batch.json" | tr -d '\r')
  log "  batch $((i / BATCH_SIZE + 1)): ${#slice[@]} transactions -> $n detail rows"
  [ "$n" -lt 10000 ] || log "  WARNING: batch hit 10,000 rows (truncated). Lower BATCH_SIZE."
done

# ---------------------------------------------------------------- step 3: CSV

log "Step 3: building $OUT_CSV"
# TSV -> JSON array via stdin (never a jq path argument, see the note in lib/cw.sh)
jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
          | {trx: .[0], total: (.[1] | tonumber), step_count: (.[2] | tonumber),
             adapter: (if .[3] == "" then null else (.[3] | tonumber) end)})' < "$TMP/1_slow.tsv" > "$TMP/slow.json"
jq -s '.' < "$TMP/2_details.ndjson" > "$TMP/details.json"

cat "$TMP/slow.json" "$TMP/details.json" | jq -s -r --arg header "$HEADER" '
  def ms: . * 100 | round / 100;
  (.[1] | group_by(.trx) | map({key: .[0].trx, value: .}) | from_entries) as $detail
  | .[0]
  | sort_by(-.total)
  | ($header | split(",")),
    (.[] | ($detail[.trx] // []) as $rows
     | [ .trx,
         ([$rows[] | .servicio // empty] | first // "" | ltrimstr("/ESBService/") | split(":")[0]),
         ([$rows[] | .xname // empty] | first // ""),
         (.total | ms),
         (if .adapter == null then "" else (.total - .adapter | ms) end),
         (if .adapter == null then "" else .adapter end),
         .step_count,
         ([$rows[] | select(.stepMs != null) | "\(.Paso): \(.stepMs) ms"] | join("; ")) ])
  | @csv' | tr -d '\r' > "$OUT_CSV"

log "Done -> $OUT_CSV ($(($(awk 'END{print NR}' "$OUT_CSV") - 1)) transaction(s))"
