#!/usr/bin/env bash
# For every Stratus adapter response with HTTP 504 (backend timeout) in the window, checks whether the adapter
# also logged "Se notifico la respuesta de stratus para la transaccion X-RqUID=<rquid>, txId=..., receiveTime=...,
# tiempo total de espera de stratus: <n> ms" for that transaction: did Stratus answer late, or never answer?
# Self-contained on purpose (copied as a single file to machines without this repo): no lib/.
#
# Step 1 lists the ::AUDIT::RESP:: ... ::HTTPCODE::504 lines (one per transaction); step 2 looks for the
# notification of just those transactions, in batches of rquids, from 1 min before their 504 up to
# NOTIFY_MINUTES after it (Stratus may answer after the adapter gave up).
#
# Usage:  ./stratus_504_replies.sh [-c cluster] "<start>" "<end>"
#           -c  only this ws cluster's Stratus adapter, e.g. loansws (default: all of them)
#           start/end: "YYYY-MM-DD HH:MM:SS", Colombia local time (UTC-5)
# Example: ./stratus_504_replies.sh -c loansws "2026-10-06 00:00:00" "2026-10-06 18:00:00"
# Output: results/<name>/<name>.csv, by 504 time, where <name> = stratus504_<cluster|all>_<start>-<end>
#   resp_time          time of the 504 (date written at the start of the message, Colombia time)
#   stratus_replied    yes / no: whether the notification line exists for that transaction
#   reply_time         time of the notification line
#   stratus_wait_ms    "tiempo total de espera de stratus" from that line
#   reply_after_504_ms reply_time - resp_time (positive = Stratus answered after the adapter gave up)
#
# Requires: aws cli v2 (credentials from the environment), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE (default results), DEBUG (0 = quiet, 1 = verbose [default], 2 = set -x),
#                    CHUNK_MINUTES (step-1 slice, default 60), MAX_PARALLEL (queries at once, default 10),
#                    BATCH_SIZE (rquids per step-2 query, default 100), NOTIFY_MINUTES (default 10)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # stop Git Bash rewriting "/aws/ecs/..." as a path
export PYTHONWARNINGS="ignore:Unverified HTTPS request"   # silence urllib3's --no-verify-ssl warning
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli's bundled Python defaults to cp1252 on Windows
# Side effect of MSYS2_ARG_CONV_EXCL: never pass a file path as an argument to jq.exe; feed it through stdin.

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
TZ_OFFSET="-05:00"                       # Colombia (no DST)
TZ_SECONDS=-18000
FLAT='.results[] | (map({(.field): .value}) | add)'   # Insights row [{field, value}...] -> {field: value}

STRATUS_GROUPS_ALL=(
  /aws/ecs/srv/accountsws-stratus-adapter /aws/ecs/srv/acquiringws-stratus-adapter
  /aws/ecs/srv/clientsws-stratus-adapter /aws/ecs/srv/credit-cardsws-stratus-adapter
  /aws/ecs/srv/insurancesws-stratus-adapter /aws/ecs/srv/investmentsws-stratus-adapter
  /aws/ecs/srv/loansws-stratus-adapter /aws/ecs/srv/paymentsws-stratus-adapter
  /aws/ecs/srv/productsws-stratus-adapter /aws/ecs/srv/remittancesws-stratus-adapter
  /aws/ecs/srv/securityws-stratus-adapter
)

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

# "YYYY-MM-DD HH:MM:SS" in Colombia time -> epoch seconds
to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }

# Every AWS call goes through here: applies --no-verify-ssl and strips urllib3 warning noise from stderr.
aws_cli() {
  local errfile rc=0 real
  errfile=$(mktemp)
  aws --no-verify-ssl "$@" 2> "$errfile" || rc=$?
  real=$(awk '!/InsecureRequestWarning/ && !/^[[:space:]]*warnings\.warn\(/' "$errfile" | tr -d '\r')
  rm -f "$errfile"
  [ -z "$real" ] || echo "$real" >&2
  [ "$rc" -eq 0 ] || log "aws ${1:-} ${2:-} FAILED (exit code $rc)"
  return "$rc"
}

# cw_submit "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the query id
# Retries while the account is at its concurrent-query quota or over the StartQuery request rate.
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
      *Throttling*|*"Rate exceeded"*) log "  StartQuery rate exceeded, retrying in $((attempt * 3))s"; sleep $((attempt * 3)) ;;
      *) cat "$errfile" >&2; rm -f "$errfile"; return 1 ;;
    esac
  done
  rm -f "$errfile"
  die "start-query still throttled after $attempt attempts"
}

# cw_collect <query id>  -> polls until the query finishes, prints the results JSON
cw_collect() {
  local qid="$1" res status t0=$SECONDS
  while :; do
    res=$(aws_cli logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "query $qid ended with status $status" ;;
    esac
    sleep 2
  done
  log "  query $qid complete: $(jq '.results | length' <<<"$res" | tr -d '\r') rows in $((SECONDS - t0))s"
  printf '%s' "$res"
}

# run_parallel <prefix>  -> runs the queries queued in PQ_QUERY/PQ_START/PQ_END against LOG_GROUPS,
# MAX_PARALLEL at a time (submit a wave, then collect it), into $TMP/<prefix>_<i>.json. Clears the queue.
run_parallel() {
  local prefix="$1" n=${#PQ_QUERY[@]} i j
  local -a qids=()
  for ((i = 0; i < n; i += MAX_PARALLEL)); do
    for ((j = i; j < n && j < i + MAX_PARALLEL; j++)); do
      qids[j]=$(cw_submit "${PQ_QUERY[j]}" "${PQ_START[j]}" "${PQ_END[j]}" "${LOG_GROUPS[@]}") || die "start-query failed"
    done
    for ((j = i; j < n && j < i + MAX_PARALLEL; j++)); do
      cw_collect "${qids[j]}" > "$TMP/${prefix}_$j.json"
      [ "$(jq '.results | length' < "$TMP/${prefix}_$j.json" | tr -d '\r')" -lt 10000 ] \
        || log "  WARNING: $prefix query $((j + 1)) hit 10,000 rows (truncated)"
    done
    log "  $prefix: $(( j < n ? j : n )) of $n queries done"
  done
  PQ_QUERY=() PQ_START=() PQ_END=()
}
PQ_QUERY=() PQ_START=() PQ_END=()

OUT_BASE="${OUT_BASE:-results}"
CLUSTER="${CLUSTER:-}"
CHUNK_MINUTES="${CHUNK_MINUTES:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"
BATCH_SIZE="${BATCH_SIZE:-100}"
NOTIFY_MINUTES="${NOTIFY_MINUTES:-10}"
[[ "$CHUNK_MINUTES" =~ ^[1-9][0-9]*$ && "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ && "$BATCH_SIZE" =~ ^[1-9][0-9]*$ \
   && "$NOTIFY_MINUTES" =~ ^[0-9]+$ ]] \
  || die "CHUNK_MINUTES, MAX_PARALLEL, BATCH_SIZE and NOTIFY_MINUTES must be whole numbers"

USAGE="usage: $0 [-c cluster] \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
while getopts ":c:h" opt; do
  case "$opt" in
    c) CLUSTER=$OPTARG ;;
    h) echo "$USAGE"; exit 0 ;;
    :) die "-$OPTARG needs a value. $USAGE" ;;
    *) die "unknown option -$OPTARG. $USAGE" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || die "$USAGE"
[[ -z "$CLUSTER" || "$CLUSTER" =~ ^[a-z-]+$ ]] || die "-c must be a cluster name like loansws or credit-cardsws"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"

if [ -n "$CLUSTER" ]; then
  mapfile -t LOG_GROUPS < <(printf '%s\n' "${STRATUS_GROUPS_ALL[@]}" | grep "^/aws/ecs/srv/${CLUSTER}-" || true)
  [ "${#LOG_GROUPS[@]}" -gt 0 ] || die "no Stratus adapter for cluster '$CLUSTER'; valid: $(printf '%s\n' \
    "${STRATUS_GROUPS_ALL[@]}" | sed 's|/aws/ecs/srv/||; s|-stratus-adapter$||' | tr '\n' ' ')"
else
  LOG_GROUPS=("${STRATUS_GROUPS_ALL[@]}")
fi

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

to_label() { date -d "$1" +%Y%m%d_%H%M; }
FILE_NAME="stratus504_${CLUSTER:-all}_$(to_label "$1")-$(to_label "$2")"
OUT_DIR="${OUT_BASE}/${FILE_NAME}"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"
OUT_CSV="$OUT_DIR/${FILE_NAME}.csv"
HEADER="trx,resp_time,adapter,service,channel,stratus_replied,reply_time,stratus_wait_ms,reply_after_504_ms,tx_id"

debug "region=$REGION window=$START..$END cluster=${CLUSTER:-all} notify_window=${NOTIFY_MINUTES}min out=$OUT_DIR"

# msgTs = epoch ms of the date at the start of the message. Insights can't parse a date string, so the
# message's time of day is compared with @timestamp's (in TZ_OFFSET) and the difference, wrapped to +-12 h,
# is added to @timestamp; that also gets the day right around midnight. Falls back to @timestamp.
tz_ms=$(( (10#${TZ_OFFSET:1:2} * 60 + 10#${TZ_OFFSET:4:2}) * 60000 ))
if [ "${TZ_OFFSET:0:1}" = "-" ]; then TZ_SHIFT="- $tz_ms"; else TZ_SHIFT="+ $tz_ms"; fi
MSG_TIME="
| parse @message /^\d{4}-\d\d-\d\d (?<msgH>\d\d):(?<msgM>\d\d):(?<msgS>\d\d)[.,](?<msgMilli>\d{3})/
| fields ((msgH * 60 + msgM) * 60 + msgS) * 1000 + msgMilli - (toMillis(@timestamp) ${TZ_SHIFT}) % 86400000 as msgDrift
| fields coalesce(toMillis(@timestamp) + if(msgDrift > 43200000, msgDrift - 86400000,
           if(msgDrift + 43200000 < 0, msgDrift + 86400000, msgDrift)), toMillis(@timestamp)) as msgTs"

# ---------------------------------------------------------------- step 1: the 504s

log "Step 1: adapter responses with HTTP 504 in ${#LOG_GROUPS[@]} Stratus adapter log group(s)"
q1="fields @timestamp, @message, @log
| filter @message like \"::AUDIT::RESP::\" and @message like \"::HTTPCODE::504\"
| parse @message /X-RqUid=(?<trx>[0-9a-f\-]{36})/
| parse @message /X-Name=(?<xname>[^,\]]+)/
| parse @message /X-Referer=[^-,]+-[^-,]+-[^-,]+-(?<refService>[^-,\]]+)/${MSG_TIME}
| filter isPresent(trx)
| display msgTs, trx, xname, refService, @log
| limit 10000"

chunk=$((CHUNK_MINUTES * 60))
for ((s = START; s < END; s += chunk)); do
  e=$((s + chunk - 1)); [ $((s + chunk)) -lt "$END" ] || e=$END
  PQ_QUERY+=("$q1") PQ_START+=("$s") PQ_END+=("$e")
done
n_slices=${#PQ_QUERY[@]}
log "  ${n_slices} slice(s) of ${CHUNK_MINUTES} min, up to ${MAX_PARALLEL} at a time"
run_parallel 1_504

# One row per transaction (earliest 504 if it repeats). @log is "<account>:<log group>": keep the adapter name.
# trx<TAB>resp_ms<TAB>channel<TAB>service<TAB>adapter
for ((j = 0; j < n_slices; j++)); do jq -c "$FLAT" < "$TMP/1_504_$j.json"; done | tr -d '\r' | jq -s -r '
  map(. + {resp: (.msgTs | tonumber)}) | group_by(.trx) | map(min_by(.resp)) | sort_by(.resp) | .[]
  | [.trx, .resp, (.xname // ""), (.refService // ""),
     ((.["@log"] // "") | sub("^[0-9]+:"; "") | ltrimstr("/aws/ecs/srv/"))] | @tsv' > "$TMP/1_504.tsv"

n504=$(awk 'END{print NR}' "$TMP/1_504.tsv")
log "  -> $n504 transaction(s) with 504"
[ "$n504" -gt 0 ] || { echo "$HEADER" > "$OUT_CSV"; log "No 504 in the window. Done -> $OUT_CSV"; exit 0; }

# ---------------------------------------------------------------- step 2: the Stratus notifications

log "Step 2: \"Se notifico la respuesta de stratus\" for those transactions (up to ${NOTIFY_MINUTES} min after the 504)"
# Batches of transactions close in time; each scans [first 504 - 60 s, last 504 + NOTIFY_MINUTES], never past now.
# Lines: <start epoch>\t<end epoch>\t<trx|trx|...>
jq -R -s -r --argjson n "$BATCH_SIZE" --argjson after "$((NOTIFY_MINUTES * 60))" --argjson now "$(date +%s)" '
  split("\n") | map(select(length > 0) | split("\t") | {trx: .[0], resp: (.[1] | tonumber)})
  | [range(0; length; $n) as $i | .[$i:$i + $n]] | .[]
  | [((map(.resp) | min) / 1000 | floor - 60), ([(map(.resp) | max) / 1000 | ceil + $after, $now] | min),
     (map(.trx) | join("|"))]
  | @tsv' < "$TMP/1_504.tsv" | tr -d '\r' > "$TMP/2_batches.tsv"

while IFS=$'\t' read -r s e regex; do
  PQ_QUERY+=("fields @timestamp, @message
| filter @message like \"Se notifico la respuesta de stratus\" and @message like /${regex}/
| parse @message /X-RqU[iI][dD]=(?<trx>[0-9a-f\-]{36})/
| parse @message /txId=(?<txId>[0-9]+)/
| parse @message /espera de stratus:\s*(?<waitMs>[0-9]+)/${MSG_TIME}
| filter isPresent(trx)
| display msgTs, trx, txId, waitMs
| limit 10000")
  PQ_START+=("$s") PQ_END+=("$e")
done < "$TMP/2_batches.tsv"
n_batches=${#PQ_QUERY[@]}
log "  ${n_batches} batch(es) of up to ${BATCH_SIZE} transactions, up to ${MAX_PARALLEL} at a time"
run_parallel 2_reply
for ((j = 0; j < n_batches; j++)); do jq -c "$FLAT" < "$TMP/2_reply_$j.json"; done | tr -d '\r' > "$TMP/2_replies.ndjson"

# ---------------------------------------------------------------- step 3: CSV

log "Step 3: building $OUT_CSV"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
          | {trx: .[0], resp: (.[1] | tonumber), channel: .[2], service: .[3], adapter: .[4]})' \
  < "$TMP/1_504.tsv" > "$TMP/504.json"
jq -s '.' < "$TMP/2_replies.ndjson" > "$TMP/replies.json"

cat "$TMP/504.json" "$TMP/replies.json" | jq -s -r --arg header "$HEADER" --argjson tz "$TZ_SECONDS" '
  # epoch ms -> "YYYY-MM-DD HH:MM:SS.mmm" in Colombia time
  def local_time: ((. / 1000 | floor) + $tz | strftime("%Y-%m-%d %H:%M:%S")) + "." + ("00\(. % 1000)" | .[-3:]);
  (.[1] | map(. + {ts: (.msgTs | tonumber)}) | group_by(.trx) | map({key: .[0].trx, value: min_by(.ts)})
   | from_entries) as $reply
  | ($header | split(",")),
    (.[0][] | $reply[.trx] as $r
     | [ .trx, (.resp | local_time), .adapter, .service, .channel,
         (if $r == null then "no" else "yes" end),
         (if $r == null then "" else ($r.ts | local_time) end),
         (if $r == null then "" else ($r.waitMs // "" | tonumber? // "") end),
         (if $r == null then "" else $r.ts - .resp end),
         (if $r == null then "" else ($r.txId // "") end) ])
  | @csv' | tr -d '\r' > "$OUT_CSV"

replied=$(awk -F'","' 'NR > 1 && $6 == "yes"' "$OUT_CSV" | awk 'END{print NR}')
log "Done -> $OUT_CSV: $n504 transaction(s) with 504, $replied with the Stratus notification, $((n504 - replied)) without"
