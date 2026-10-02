#!/usr/bin/env bash
# Finds error transactions across the *-mngr log groups (rqid, nombreOperacion, msgRespuesta),
# then for each rqid found, searches its detail trace across the *-mngr and *-adapter log groups
# for X-Name. Groups the result by (msgRespuesta, X-Name, nombreOperacion) and lists which rqids
# matched each group. Log groups come from NexusGeneral.json (see cw_groups in lib/cw.sh).
#
# Usage:  ./summarize_errors.sh "2026-09-23 08:00:00" "2026-09-23 09:00:00"
#         (times are Colombia local time, UTC-5)
# Output: results/<start>__<end>/summary.csv and exceptions_summary.csv (adapter exceptions, step 0)
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, BATCH_SIZE, ERROR_PATTERN1, ERROR_PATTERN2, DASHBOARD_JSON,
#                    DEBUG (0 = quiet, 1 = verbose [default], 2 = also set -x)
set -euo pipefail

# shellcheck source=lib/cw.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/cw.sh"

OUT_BASE="${OUT_BASE:-results}"
BATCH_SIZE="${BATCH_SIZE:-100}"          # rqids per query in step 2 (query length limit: 10,000 chars)
ERROR_PATTERN1="${ERROR_PATTERN1:-Error}"
ERROR_PATTERN2="${ERROR_PATTERN2:-ERROR}"

[ $# -eq 2 ] || die "usage: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
cw_require_tools

mapfile -t MNGR_GROUPS < <(cw_groups mngr)
mapfile -t ADAPTER_GROUPS < <(cw_groups adapter)
[ "${#MNGR_GROUPS[@]}" -gt 0 ] && [ "${#ADAPTER_GROUPS[@]}" -gt 0 ] || die "no log groups found in $DASHBOARD_JSON"
ALL_GROUPS=("${MNGR_GROUPS[@]}" "${ADAPTER_GROUPS[@]}")

to_label() { date -d "$1" +%Y%m%d_%H%M%S; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/$(to_label "$1")__$(to_label "$2")"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"

debug "region=$REGION window=$START..$END batch=$BATCH_SIZE out=$OUT_DIR"
cw_debug_env

F_ERRORS="$TMP/1_errors.tsv"
F_DETAILS="$TMP/2_details.tsv"

# ---------------------------------------------------------------- step 0: adapter HTTP exceptions
# The REST->SOAP adaptation always answers HTTP 200, so the real backend error only shows up here.

log "Step 0: searching GenericExceptionMapper exceptions in ${#ADAPTER_GROUPS[@]} log groups"
read -r -d '' q0 <<'EOF' || true
fields @message
| filter @message like /GenericExceptionMapper/ and @message like /HttpCode::/
| parse @message /Exception:\s*(?<code>\d+)\s*::\s*(?<errorMsg>[^.]*[^.\s])/
| parse @message /3=(?<field>[A-Za-z0-9_.]+)\s*::HEAD::/
| parse @message /X-Referer=[^-,]+-[^-,]+-[^-,]+-(?<service>[^-,\]]+)/
| parse @message /X-Name=(?<channel>[^,\]]+)/
| stats count(*) as total by code, errorMsg, field, service, channel
| sort total desc
| limit 10000
EOF
# errorMsg stops at the first "." on purpose: what follows (".RESPONSE: ... 1=...") is raw backend data with
# customer PII, and it is unique per request, so grouping by it would count every exception separately.

run_query "$q0" "$START" "$END" "${ADAPTER_GROUPS[@]}" > "$TMP/0_exceptions.json"
{
  echo "count,code,error_message,field,service,channel"
  jq -r "$FLAT"' | [(.total|tonumber), .code, .errorMsg, .field, .service, .channel] | @csv' \
    < "$TMP/0_exceptions.json"
} | tr -d '\r' > "$OUT_DIR/exceptions_summary.csv"
log "  -> $OUT_DIR/exceptions_summary.csv ($(($(awk 'END{print NR}' "$OUT_DIR/exceptions_summary.csv") - 1)) group(s))"

# ---------------------------------------------------------------- step 1: find errors

log "Step 1: searching '${ERROR_PATTERN1}'/'${ERROR_PATTERN2}' in ${#MNGR_GROUPS[@]} log groups"
read -r -d '' q1 <<EOF || true
fields @timestamp, @message
| filter (@message like '${ERROR_PATTERN1}' or @message like '${ERROR_PATTERN2}')
| parse @message /\[(?<rqid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/
| parse @message /<nombreOperacion>(?<nombreOperacion>[^<]+)<\/nombreOperacion>/
| parse @message /<msgRespuesta>(?<msgRespuesta>[^<]+)<\/msgRespuesta>/
| filter ispresent(rqid)
| sort @timestamp desc
| limit 10000
EOF

run_query "$q1" "$START" "$END" "${MNGR_GROUPS[@]}" > "$TMP/1_errors.json"

# one row per rqid: first non-empty nombreOperacion/msgRespuesta seen for it
jq -r "$FLAT
  | {rqid, nombreOperacion: (.nombreOperacion // \"\"), msgRespuesta: (.msgRespuesta // \"\")}" \
  < "$TMP/1_errors.json" | tr -d '\r' \
  | jq -s -r '
      group_by(.rqid) | map(
        (map(select(.nombreOperacion != "")) | .[0].nombreOperacion // "") as $op
        | (map(select(.msgRespuesta != "")) | .[0].msgRespuesta // "") as $msg
        | [.[0].rqid, $op, $msg] | @tsv
      ) | .[]' > "$F_ERRORS"

n_rqids=$(awk 'END{print NR}' "$F_ERRORS")
log "  -> $n_rqids distinct rqid(s) with an error"
[ "$n_rqids" -gt 0 ] || { log "No errors in the window. Done."; echo "msgrespuesta,xname,nombreoperacion,rqid_count,rqids" > "$OUT_DIR/summary.csv"; exit 0; }

# ---------------------------------------------------------------- step 2: X-Name per rqid

log "Step 2: fetching X-Name for each rqid across all ${#ALL_GROUPS[@]} log groups"
: > "$F_DETAILS"
mapfile -t rqids < <(cut -f1 "$F_ERRORS")

for ((i = 0; i < ${#rqids[@]}; i += BATCH_SIZE)); do
  slice=("${rqids[@]:i:BATCH_SIZE}")
  regex=$(IFS='|'; printf '%s' "${slice[*]}")
  idsjson=$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s -c . | tr -d '\r')
  q2="fields @message
| filter @message like /${regex}/ and @message like 'X-Name='
| parse @message /X-Name=(?<xname>[^,\]]+)/
| filter ispresent(xname)
| sort @timestamp asc
| limit 10000"

  run_query "$q2" "$START" "$END" "${ALL_GROUPS[@]}" > "$TMP/2_batch.json"

  jq -r --argjson ids "$idsjson" "$FLAT"' as $r
        | $r["@message"] as $m
        | ($ids | map(select(. as $id | $m | contains($id))) | first) as $rq
        | select($rq != null)
        | [$rq, $r.xname] | @tsv' \
    < "$TMP/2_batch.json" | tr -d '\r' >> "$F_DETAILS"

  n=$(jq '.results | length' < "$TMP/2_batch.json" | tr -d '\r')
  log "  batch $((i / BATCH_SIZE + 1)): ${#slice[@]} rqids -> $n detail rows"
  [ "$n" -lt 10000 ] || log "  WARNING: batch hit 10,000 rows (truncated). Lower BATCH_SIZE."
done

# one row per rqid: first X-Name seen for it
XNAME_BY_RQID="$TMP/xname_by_rqid.tsv"
awk -F'\t' '!seen[$1]++' "$F_DETAILS" > "$XNAME_BY_RQID"
log "  -> X-Name found for $(awk 'END{print NR}' "$XNAME_BY_RQID") of $n_rqids rqid(s)"

# ---------------------------------------------------------------- step 3: group

log "Step 3: grouping by (msgRespuesta, X-Name, nombreOperacion) -> $OUT_DIR/summary.csv"
# TSV -> JSON array, each via stdin redirection (never a jq path argument, see the note in lib/cw.sh)
jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))' < "$F_ERRORS" > "$TMP/errors.json"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))' < "$XNAME_BY_RQID" > "$TMP/xnames.json"

cat "$TMP/errors.json" "$TMP/xnames.json" | jq -s -r '
  (.[1] | map({(.[0]): .[1]}) | add) as $xname_by_rqid
  | .[0]
  | map({rqid: .[0], nombreOperacion: .[1], msgRespuesta: .[2],
         xname: ($xname_by_rqid[.[0]] // "")})
  | group_by([.msgRespuesta, .xname, .nombreOperacion])
  | sort_by(-(length))
  | map({
      msgrespuesta: .[0].msgRespuesta, xname: .[0].xname, nombreoperacion: .[0].nombreOperacion,
      rqid_count: length, rqids: ([.[].rqid] | join("|"))
    })
  | (["msgrespuesta","xname","nombreoperacion","rqid_count","rqids"] | @csv),
    (.[] | [.msgrespuesta, .xname, .nombreoperacion, .rqid_count, .rqids] | @csv)
' | tr -d '\r' > "$OUT_DIR/summary.csv"

log "Done -> $OUT_DIR/summary.csv ($(($(awk 'END{print NR}' "$OUT_DIR/summary.csv") - 1)) group(s))"
