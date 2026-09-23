#!/usr/bin/env bash
# Finds error transactions across the 11 *-mngr log groups (rqid, nombreOperacion, msgRespuesta),
# then for each rqid found, searches its detail trace across all 22 log groups (11 *-mngr + their
# *-stratus-adapter companions) for X-Name. Groups the result by (msgRespuesta, X-Name,
# nombreOperacion) and lists which rqids matched each group.
#
# Usage:  ./summarize_errors.sh "2026-09-23 08:00:00" "2026-09-23 09:00:00"
#         (times are Colombia local time, UTC-5)
# Output: results/<start>__<end>/summary.csv
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, BATCH_SIZE, ERROR_PATTERN1, ERROR_PATTERN2,
#                    DEBUG (0 = quiet, 1 = verbose [default], 2 = also set -x)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # stop Git Bash rewriting "/aws/ecs/..." as a path
export PYTHONWARNINGS="ignore:Unverified HTTPS request"   # silence urllib3's --no-verify-ssl warning
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli's bundled Python defaults to cp1252 on Windows
                                              # and crashes on log lines it can't map to that charset

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
OUT_BASE="${OUT_BASE:-results}"
BATCH_SIZE="${BATCH_SIZE:-100}"          # rqids per query in step 2 (query length limit: 10,000 chars)
ERROR_PATTERN1="${ERROR_PATTERN1:-Error}"
ERROR_PATTERN2="${ERROR_PATTERN2:-ERROR}"
TZ_OFFSET="-05:00"                       # Colombia

MNGR_GROUPS=(
  /aws/ecs/srv/productsws-mngr
  /aws/ecs/srv/accountsws-mngr
  /aws/ecs/srv/acquiringws-mngr
  /aws/ecs/srv/clientsws-mngr
  /aws/ecs/srv/credit-cardsws-mngr
  /aws/ecs/srv/insurancesws-mngr
  /aws/ecs/srv/investmentsws-mngr
  /aws/ecs/srv/loansws-mngr
  /aws/ecs/srv/paymentsws-mngr
  /aws/ecs/srv/remittancesws-mngr
  /aws/ecs/srv/securityws-mngr
)
ALL_GROUPS=()
for g in "${MNGR_GROUPS[@]}"; do ALL_GROUPS+=("$g" "${g%-mngr}-stratus-adapter"); done

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

# Every AWS call goes through here: applies --no-verify-ssl, strips urllib3 warning noise from
# stderr (real errors still print and log to $TMP/aws_errors.log).
aws_cli() {
  local errfile rc=0 real
  errfile=$(mktemp)
  aws --no-verify-ssl "$@" 2> "$errfile" || rc=$?
  real=$(awk '!/InsecureRequestWarning/ && !/^[[:space:]]*warnings\.warn\(/' "$errfile" | tr -d '\r')
  rm -f "$errfile"
  if [ -n "$real" ]; then
    echo "$real" >&2
    echo "[$(date +%T)] aws ${1:-} ${2:-} (exit $rc): $real" >> "$TMP/aws_errors.log"
  fi
  if [ "$rc" -ne 0 ]; then
    log "aws ${1:-} ${2:-} FAILED (exit code $rc)"
    case "$real" in
      *charmap*) log "  hint: encoding problem in the aws cli output; check the DEBUG output and PYTHONIOENCODING=$PYTHONIOENCODING" ;;
    esac
  fi
  return "$rc"
}

# run_query "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the results JSON
run_query() {
  local query="$1" start="$2" end="$3"; shift 3
  local qid res status polls=0 t0=$SECONDS
  qid=$(aws_cli logs start-query --region "$REGION" \
          --start-time "$start" --end-time "$end" \
          --query-string "$query" --log-group-names "$@" \
          --query queryId --output text | tr -d '\r')
  debug "query id: $qid"
  while :; do
    polls=$((polls + 1))
    res=$(aws_cli logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    debug "poll #$polls status=$status matched=$(jq -r '.statistics.recordsMatched // "?"' <<<"$res" | tr -d '\r') scanned=$(jq -r '.statistics.recordsScanned // "?"' <<<"$res" | tr -d '\r')"
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "query $qid ended with status $status" ;;
    esac
    sleep 2
  done
  log "  query $qid complete: $(jq '.results | length' <<<"$res" | tr -d '\r') rows in $((SECONDS - t0))s"
  printf '%s' "$res"
}

[ $# -eq 2 ] || die "usage: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"

to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
to_label() { date -d "$1" +%Y%m%d_%H%M%S; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/$(to_label "$1")__$(to_label "$2")"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION window=$START..$END batch=$BATCH_SIZE out=$OUT_DIR"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

FLAT='.results[] | (map({(.field): .value}) | add)'
F_ERRORS="$TMP/1_errors.tsv"
F_DETAILS="$TMP/2_details.tsv"

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
# TSV -> JSON array, each via stdin redirection (never a jq path argument, see aws_cli's block above)
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
