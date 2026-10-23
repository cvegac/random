#!/usr/bin/env bash
# Finds the rqids with errors in the mngr log groups, looks up the X-Name (channel) of each one in the
# mngr and adapter logs, and groups them by (msgRespuesta, X-Name, nombreOperacion).
#
# Usage: ./summarize_errors.sh "2026-09-23 08:00:00" "2026-09-23 09:00:00"   (Colombia time, UTC-5)
# Output: results/<start>__<end>/summary.csv and exceptions_summary.csv (adapter exceptions)
# Env: AWS_REGION, OUT_BASE, BATCH_SIZE, ERROR_PATTERN1, ERROR_PATTERN2, DEBUG (0/1/2)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: don't turn /aws/... args into Windows paths
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli on Windows defaults to cp1252 and fails on some log lines
# side effect: jq.exe gets absolute path arguments unconverted, so files go to jq through stdin

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
TZ_OFFSET="-05:00"                       # Colombia (no DST)
FLAT='.results[] | (map({(.field): .value}) | add)'   # Insights row -> {field: value}

MNGR_GROUPS=(
  /aws/ecs/srv/accountsws-mngr /aws/ecs/srv/acquiringws-mngr /aws/ecs/srv/clientsws-mngr
  /aws/ecs/srv/credit-cardsws-mngr /aws/ecs/srv/insurancesws-mngr /aws/ecs/srv/investmentsws-mngr
  /aws/ecs/srv/loansws-mngr /aws/ecs/srv/paymentsws-mngr /aws/ecs/srv/productsws-mngr
  /aws/ecs/srv/remittancesws-mngr /aws/ecs/srv/securityws-mngr
)
ADAPTER_GROUPS=(
  /aws/ecs/srv/accountsws-iseries-adapter /aws/ecs/srv/accountsws-stratus-adapter
  /aws/ecs/srv/acquiringws-stratus-adapter /aws/ecs/srv/clientsws-stratus-adapter
  /aws/ecs/srv/credit-cardsws-iseries-adapter /aws/ecs/srv/credit-cardsws-postilion-adapter
  /aws/ecs/srv/credit-cardsws-stratus-adapter /aws/ecs/srv/insurancesws-stratus-adapter
  /aws/ecs/srv/investmentsws-stratus-adapter /aws/ecs/srv/loansws-stratus-adapter
  /aws/ecs/srv/paymentsws-iseries-adapter /aws/ecs/srv/paymentsws-stratus-adapter
  /aws/ecs/srv/productsws-stratus-adapter /aws/ecs/srv/remittancesws-stratus-adapter
  /aws/ecs/srv/securityws-stratus-adapter
)
ALL_GROUPS=("${MNGR_GROUPS[@]}" "${ADAPTER_GROUPS[@]}")

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }

# aws wrapper: --no-verify-ssl and drop the urllib3 warnings from stderr
aws_cli() {
  local errfile rc=0 real
  errfile=$(mktemp)
  aws --no-verify-ssl "$@" 2> "$errfile" || rc=$?
  real=$(awk '!/InsecureRequestWarning/ && !/^[[:space:]]*warnings\.warn\(/' "$errfile" | tr -d '\r')
  rm -f "$errfile"
  if [ -n "$real" ]; then
    echo "$real" >&2
    if [ -n "${TMP:-}" ]; then echo "[$(date +%T)] aws ${1:-} ${2:-} (exit $rc): $real" >> "$TMP/aws_errors.log"; fi
  fi
  if [ "$rc" -ne 0 ]; then
    log "aws ${1:-} ${2:-} FAILED (exit code $rc)"
    case "$real" in
      *charmap*) log "  hint: encoding problem in the aws cli output; check PYTHONIOENCODING=$PYTHONIOENCODING" ;;
    esac
  fi
  return "$rc"
}

# cw_submit <query> <start> <end> <log group>...  -> query id; retries while over the concurrent query quota
cw_submit() {
  local query="$1" start="$2" end="$3"; shift 3
  local qid errfile attempt
  errfile=$(mktemp)
  for attempt in 1 2 3 4 5 6; do
    if qid=$(aws_cli logs start-query --region "$REGION" \
               --start-time "$start" --end-time "$end" \
               --query-string "$query" --log-group-names "$@" \
               --query queryId --output text 2> "$errfile" | tr -d '\r'); then
      rm -f "$errfile"
      debug "query id: $qid"
      printf '%s' "$qid"
      return 0
    fi
    case "$(< "$errfile")" in
      *LimitExceeded*) log "  concurrent query quota reached, retrying in $((attempt * 10))s"; sleep $((attempt * 10)) ;;
      *) cat "$errfile" >&2; rm -f "$errfile"; return 1 ;;
    esac
  done
  rm -f "$errfile"
  die "start-query still throttled after $attempt attempts"
}

cw_collect() {
  local qid="$1" res status polls=0 t0=$SECONDS
  while :; do
    polls=$((polls + 1))
    res=$(aws_cli logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    debug "poll #$polls $qid status=$status matched=$(jq -r '.statistics.recordsMatched // "?"' <<<"$res" | tr -d '\r') scanned=$(jq -r '.statistics.recordsScanned // "?"' <<<"$res" | tr -d '\r')"
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "query $qid ended with status $status" ;;
    esac
    sleep 2
  done
  log "  query $qid complete: $(jq '.results | length' <<<"$res" | tr -d '\r') rows in $((SECONDS - t0))s"
  printf '%s' "$res"
}

# run_query <query> <start> <end> <log group>...  -> results JSON
run_query() {
  local qid
  qid=$(cw_submit "$@") || die "start-query failed"
  cw_collect "$qid"
}

OUT_BASE="${OUT_BASE:-results}"
BATCH_SIZE="${BATCH_SIZE:-100}"          # rqids per query in step 2 (query length limit: 10,000 chars)
ERROR_PATTERN1="${ERROR_PATTERN1:-Error}"
ERROR_PATTERN2="${ERROR_PATTERN2:-ERROR}"

[ $# -eq 2 ] || die "usage: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"

to_label() { date -d "$1" +%Y%m%d_%H%M%S; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/$(to_label "$1")__$(to_label "$2")"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"

debug "region=$REGION window=$START..$END batch=$BATCH_SIZE out=$OUT_DIR"
if [ "$DEBUG" != 0 ]; then
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

F_ERRORS="$TMP/1_errors.tsv"
F_DETAILS="$TMP/2_details.tsv"

# ---------------------------------------------------------------- step 0: adapter HTTP exceptions
# the SOAP side always answers HTTP 200, the real backend error only shows up here

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
# errorMsg stops at the first ".": after it comes backend data with customer info, unique per request

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

# one row per rqid with its first non-empty nombreOperacion/msgRespuesta
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

XNAME_BY_RQID="$TMP/xname_by_rqid.tsv"
awk -F'\t' '!seen[$1]++' "$F_DETAILS" > "$XNAME_BY_RQID"
log "  -> X-Name found for $(awk 'END{print NR}' "$XNAME_BY_RQID") of $n_rqids rqid(s)"

# ---------------------------------------------------------------- step 3: group

log "Step 3: grouping by (msgRespuesta, X-Name, nombreOperacion) -> $OUT_DIR/summary.csv"
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
