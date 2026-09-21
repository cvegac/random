#!/usr/bin/env bash
# Extracts the full transactions (by RQID) that had an ERROR in CloudWatch Logs,
# grouped by service, into one CSV per service.
#
#   Step 1: in the 11 *-mngr log groups, filter @message like 'ERROR' and extract RQID + @log.
#   Step 2: for each @log, fetch ALL the lines of those RQIDs, querying only its own log group
#           (and its *-stratus-adapter companion, if it exists).
#   Step 3: classify each RQID by service and write one CSV per service.
#
# Usage:  ./extract_error_traces.sh "2026-09-21 15:00:00" "2026-09-21 15:30:00"
#         (times are Colombia local time, UTC-5)
# Output: results/<startdate>_<starttime>__<enddate>_<endtime>/<service>.csv
#
# Requires: aws cli v2 (with active credentials/profile: AWS_PROFILE), jq, gawk/awk, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, BATCH_SIZE, PAD_SECONDS, ERROR_PATTERN,
#                    SERVICE_REGEX, OPERATION_REGEX, DEBUG (0 = quiet, 1 = verbose [default], 2 = also set -x)
set -euo pipefail

# Git Bash on Windows rewrites "/aws/ecs/..." into a C:\... path; this prevents it.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

# We run with --no-verify-ssl, so urllib3 warns on every call: silence it (aws_cli also filters stderr).
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
# The Python bundled with the aws cli defaults to cp1252 ('charmap') on Windows and crashes when a
# log line has a character it cannot map. Force UTF-8.
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

DEBUG="${DEBUG:-1}"                      # 0 = quiet, 1 = verbose logs + raw batch JSONs (default), 2 = also set -x
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
OUT_BASE="${OUT_BASE:-results}"
BATCH_SIZE="${BATCH_SIZE:-100}"          # RQIDs per query in step 2 (query length limit: 10,000 chars)
PAD_SECONDS="${PAD_SECONDS:-300}"        # margin before/after the window for step 2
ERROR_PATTERN="${ERROR_PATTERN:-ERROR}"
# How the "service" of each RQID is determined (tried in order over ALL the lines of the RQID):
SERVICE_REGEX="${SERVICE_REGEX:-/ESBService/([A-Za-z0-9_]+)}"
OPERATION_REGEX="${OPERATION_REGEX:-<nombreOperacion>([^<]+)</nombreOperacion>}"
TZ_OFFSET="-05:00"                       # Colombia
TZ_OFFSET_SECONDS=-18000

LOG_GROUPS=(
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

# Companion log group of each *-mngr. ADJUST if the real name is different.
companion_group() { printf '%s-stratus-adapter' "${1%-mngr}"; }

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

# Every AWS call goes through here so --no-verify-ssl is always applied.
# stderr is captured: urllib3 warning noise is dropped, real errors are shown and also
# appended to $TMP/aws_errors.log. stdout passes through untouched.
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
  debug "region=$REGION window=$START..$END pad=${PAD_SECONDS}s batch=$BATCH_SIZE out=$OUT_DIR"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

F_RQIDS="$TMP/1_error_rqids.tsv"
F_TRACES="$TMP/2_traces.ndjson"
F_CLASSIFIED="$TMP/3_classified.ndjson"

# ---------------------------------------------------------------- helpers

# run_query "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the results JSON
run_query() {
  local query="$1" start="$2" end="$3"; shift 3
  local qid res status polls=0 t0=$SECONDS
  debug "start-query: ${#query} chars, $# log group(s): $*"
  debug "query head: ${query:0:300}"
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

group_exists() {
  local found
  found=$(aws_cli logs describe-log-groups --region "$REGION" --log-group-name-prefix "$1" \
            --query "logGroups[?logGroupName=='$1'].logGroupName" --output text | tr -d '\r')
  [ -n "$found" ]
}

# Converts Logs Insights results[] into {field: value} objects
FLAT='.results[] | (map({(.field): .value}) | add)'

# ---------------------------------------------------------------- step 1

step1_error_rqids() {
  log "Step 1: searching RQIDs with '${ERROR_PATTERN}' in ${#LOG_GROUPS[@]} log groups"
  local q1
  read -r -d '' q1 <<EOF || true
fields @timestamp, @message, @log
| filter @message like '${ERROR_PATTERN}'
| parse @message /\[(?<rqid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/
| filter ispresent(rqid)
| stats count(*) as occurrences by rqid, @log
| limit 10000
EOF
  run_query "$q1" "$START" "$END" "${LOG_GROUPS[@]}" > "$TMP/1_errors.json"

  jq -r "$FLAT | [.rqid, (.[\"@log\"] | sub(\"^[0-9]+:\"; \"\")), .occurrences] | @tsv" \
     < "$TMP/1_errors.json" | tr -d '\r' > "$F_RQIDS"

  local n; n=$(awk 'END {print NR}' "$F_RQIDS")
  [ "$n" -lt 10000 ] || log "WARNING: 10,000 rows, the result may be truncated. Narrow the time window."
  log "  -> $n (RQID, log group) pairs with errors"
  [ "$n" -gt 0 ] || { log "No errors in the window. Done."; exit 0; }
}

# ---------------------------------------------------------------- step 2

step2_full_transactions() {
  log "Step 2: fetching full transactions per log group"
  : > "$F_TRACES"
  local groups g comp targets ids i slice regex idsjson q n before after
  mapfile -t groups < <(cut -f2 "$F_RQIDS" | sort -u)

  for g in "${groups[@]}"; do
    targets=("$g")
    comp=$(companion_group "$g")
    if group_exists "$comp"; then targets+=("$comp"); else log "  (no companion: $comp, querying only $g)"; fi

    mapfile -t ids < <(awk -F'\t' -v g="$g" '$2 == g {print $1}' "$F_RQIDS")
    log "  $g: ${#ids[@]} RQIDs -> ${targets[*]}"

    for ((i = 0; i < ${#ids[@]}; i += BATCH_SIZE)); do
      slice=("${ids[@]:i:BATCH_SIZE}")
      regex=$(IFS='|'; printf '%s' "${slice[*]}")
      idsjson=$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s -c . | tr -d '\r')
      q="fields @timestamp, @log, @logStream, @message
| filter @message like /${regex}/
| sort @timestamp asc
| limit 10000"

      before=$(awk 'END {print NR}' "$F_TRACES")
      run_query "$q" "$((START - PAD_SECONDS))" "$((END + PAD_SECONDS))" "${targets[@]}" > "$TMP/2_batch.json"
      [ "$DEBUG" = 0 ] || cp "$TMP/2_batch.json" "$TMP/debug_batch_${g##*/}_$i.json"

      # Assigns to each line the RQID (from the list) contained in its message
      jq -c --argjson ids "$idsjson" "$FLAT"' as $r
            | $r["@message"] as $m
            | ($ids | map(select(. as $id | $m | contains($id))) | first) as $rq
            | select($rq != null)
            | {ts: $r["@timestamp"], rqid: $rq,
               log: ($r["@log"] | sub("^[0-9]+:"; "")),
               stream: $r["@logStream"], message: $m}' \
         < "$TMP/2_batch.json" | tr -d '\r' >> "$F_TRACES"

      n=$(jq '.results | length' < "$TMP/2_batch.json" | tr -d '\r')
      after=$(awk 'END {print NR}' "$F_TRACES")
      log "    batch $((i / BATCH_SIZE + 1)): ${#slice[@]} RQIDs -> $n rows returned, $((after - before)) matched to an RQID"
      [ "$n" -lt 10000 ] || log "  WARNING: batch hit 10,000 rows (truncated). Lower BATCH_SIZE."
    done
  done
  log "  -> $(awk 'END {print NR}' "$F_TRACES") trace lines collected"
}

# ---------------------------------------------------------------- step 3

step3_group_by_service() {
  log "Step 3: grouping by service -> $OUT_DIR"
  [ -s "$F_TRACES" ] || { log "No traces collected. Done."; exit 0; }

  # Service per RQID: SERVICE_REGEX, else OPERATION_REGEX, else NO_SERVICE
  jq -s -c --arg re1 "$SERVICE_REGEX" --arg re2 "$OPERATION_REGEX" '
    def first_match($re): [ .[] | .message | scan($re) | (if type == "array" then .[0] else . end) ] | first;
    group_by(.rqid)
    | map( (first_match($re1) // first_match($re2) // "NO_SERVICE") as $svc
           | map(. + {service: $svc}) )
    | add | .[]' < "$F_TRACES" | tr -d '\r' > "$F_CLASSIFIED"

  local services svc safe out
  mapfile -t services < <(jq -s -r '[.[].service] | unique | .[]' < "$F_CLASSIFIED" | tr -d '\r')

  for svc in "${services[@]}"; do
    safe=$(printf '%s' "$svc" | tr -c 'A-Za-z0-9_.\n-' '_')
    out="$OUT_DIR/${safe}.csv"
    {
      echo 'colombia_time,rqid,log_group,message'
      jq -s -r --arg s "$svc" --argjson off "$TZ_OFFSET_SECONDS" '
        def col: (.[0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime + $off | strftime("%Y-%m-%d %H:%M:%S")) + .[19:];
        [ .[] | select(.service == $s) ] | sort_by(.rqid, .ts) | .[]
        | [ (.ts | col), .rqid, .log, (.message | gsub("[\r\n]+"; " ")) ] | @csv' < "$F_CLASSIFIED"
    } | tr -d '\r' > "$out"
    log "  $(basename "$out")"
  done

  {
    echo 'service,rqids_with_error,lines'
    jq -s -r 'group_by(.service) | .[] | [.[0].service, (map(.rqid) | unique | length), length] | @csv' < "$F_CLASSIFIED"
  } | tr -d '\r' > "$OUT_DIR/_summary.csv"
}

step1_error_rqids
step2_full_transactions
step3_group_by_service

log "Done -> $OUT_DIR (summary in _summary.csv)"
