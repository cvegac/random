#!/usr/bin/env bash
# Lists the transactions slower than a threshold, with the time split between the mngr (proxy) and the
# adapter, and every ESB step. A transaction is listed when total_ms or adapter_ms is over the threshold.
#
# Usage: ./slow_transactions.sh [-c cluster] [-s service] [-t ms] "<start>" "<end>"
#   -c  ws cluster, e.g. productsws (default: all)
#   -s  ESB service, e.g. ConsultaProductos (exact name)
#   -t  threshold in ms (default 1000)
#   start/end: "YYYY-MM-DD HH:MM:SS", Colombia time (UTC-5)
# Output: results/<service|cluster|all>_<start>-<end>/<same name>.csv, slowest first
#
# Columns:
#   total_ms         sum of the mngr ESB step times; empty when the mngr logged no step (adapter timeouts)
#   adapter_ms       adapter AUDIT RESP time - AUDIT REQ time for the same X-RqUid
#   adapter_late_ms  how long after the mngr's last step the adapter answered (the mngr didn't wait for it)
#   proxy_ms         total_ms - adapter_ms; empty when adapter_late_ms is set
#   adapter_error    error from the RESP body and/or GenericExceptionMapper, cut at the first "."
#   mngr_error       text after [ERROR ...] in the mngr lines, first 200 chars
#   adapter_audit    full AUDIT REQ/RESP records joined with " || " (customer data, can be very long)
# Times are taken from the date at the start of each message, not from @timestamp.
#
# Env: AWS_REGION, OUT_BASE, DEBUG (0/1/2), THRESHOLD_MS/CLUSTER/SERVICE (defaults for -t/-c/-s),
#      BATCH_SIZE (100), CHUNK_MINUTES (60), MAX_PARALLEL (10), CACHE (1), CACHE_DIR, CACHE_DAYS (7)
# Results are cached by query + log groups + range; ranges ending in the last 15 min are not cached.
# A slow transaction split across two CHUNK_MINUTES slices can be missed if neither half is over the threshold.
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

# same log groups as cloudwatch/Nexus.json
MNGR_GROUPS_ALL=(
  /aws/ecs/srv/accountsws-mngr /aws/ecs/srv/acquiringws-mngr /aws/ecs/srv/clientsws-mngr
  /aws/ecs/srv/credit-cardsws-mngr /aws/ecs/srv/insurancesws-mngr /aws/ecs/srv/investmentsws-mngr
  /aws/ecs/srv/loansws-mngr /aws/ecs/srv/paymentsws-mngr /aws/ecs/srv/productsws-mngr
  /aws/ecs/srv/remittancesws-mngr /aws/ecs/srv/securityws-mngr
)
ADAPTER_GROUPS_ALL=(
  /aws/ecs/srv/accountsws-iseries-adapter /aws/ecs/srv/accountsws-stratus-adapter
  /aws/ecs/srv/acquiringws-stratus-adapter /aws/ecs/srv/clientsws-stratus-adapter
  /aws/ecs/srv/credit-cardsws-iseries-adapter /aws/ecs/srv/credit-cardsws-postilion-adapter
  /aws/ecs/srv/credit-cardsws-stratus-adapter /aws/ecs/srv/insurancesws-stratus-adapter
  /aws/ecs/srv/investmentsws-stratus-adapter /aws/ecs/srv/loansws-stratus-adapter
  /aws/ecs/srv/paymentsws-iseries-adapter /aws/ecs/srv/paymentsws-stratus-adapter
  /aws/ecs/srv/productsws-stratus-adapter /aws/ecs/srv/remittancesws-stratus-adapter
  /aws/ecs/srv/securityws-stratus-adapter
)

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

# cw_submit <query> <start> <end> <log group>...  -> query id
# retries on the concurrent query quota and on StartQuery throttling (shared with every open dashboard)
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

cw_collect() {
  local qid="$1" res status polls=0 t0=$SECONDS
  while :; do
    polls=$((polls + 1))
    res=$(aws_cli logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    debug "poll #$polls $qid status=$status"
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "query $qid ended with status $status" ;;
    esac
    sleep 2
  done
  log "  query $qid complete: $(jq '.results | length' <<<"$res" | tr -d '\r') rows in $((SECONDS - t0))s"
  printf '%s' "$res"
}

# cache key: query text + log groups + exact range
cache_file() {
  local key
  key=$({ printf '%s\n' "$1"; printf '%s\n' "${ALL_GROUPS[@]}"; } | cksum | cut -d' ' -f1)
  printf '%s/%s_%s_%s.json' "$CACHE_DIR" "$key" "$2" "$3"
}

# run_parallel <prefix>: runs the queued PQ_* queries MAX_PARALLEL at a time into $TMP/<prefix>_<i>.json
run_parallel() {
  local prefix="$1" n=${#PQ_QUERY[@]} i j hits=0 cf
  local -a qids=() cfs=()
  for ((i = 0; i < n; i += MAX_PARALLEL)); do
    for ((j = i; j < n && j < i + MAX_PARALLEL; j++)); do
      cfs[j]=""
      if [ "$CACHE" = 1 ] && [ "${PQ_END[j]}" -le $(( $(date +%s) - CACHE_FRESH_MIN * 60 )) ]; then
        cfs[j]=$(cache_file "${PQ_QUERY[j]}" "${PQ_START[j]}" "${PQ_END[j]}")
        if [ -s "${cfs[j]}" ]; then
          cp "${cfs[j]}" "$TMP/${prefix}_$j.json"; qids[j]=""; hits=$((hits + 1)); continue
        fi
      fi
      qids[j]=$(cw_submit "${PQ_QUERY[j]}" "${PQ_START[j]}" "${PQ_END[j]}" "${ALL_GROUPS[@]}") || die "start-query failed"
    done
    for ((j = i; j < n && j < i + MAX_PARALLEL; j++)); do
      if [ -n "${qids[j]}" ]; then
        cw_collect "${qids[j]}" > "$TMP/${prefix}_$j.json"
        cf=${cfs[j]}
        [ -z "$cf" ] || { cp "$TMP/${prefix}_$j.json" "$cf.part" && mv "$cf.part" "$cf"; }
      fi
      [ "$(jq '.results | length' < "$TMP/${prefix}_$j.json" | tr -d '\r')" -lt 10000 ] \
        || log "  WARNING: $prefix query $((j + 1)) hit 10,000 rows (truncated)"
    done
    log "  $prefix: $(( j < n ? j : n )) of $n queries done"
  done
  [ "$hits" -eq 0 ] || log "  $prefix: $hits of $n from the cache"
  PQ_QUERY=() PQ_START=() PQ_END=()
}
PQ_QUERY=() PQ_START=() PQ_END=()

OUT_BASE="${OUT_BASE:-results}"
THRESHOLD_MS="${THRESHOLD_MS:-1000}"
CLUSTER="${CLUSTER:-}"
SERVICE="${SERVICE:-}"
BATCH_SIZE="${BATCH_SIZE:-100}"
CHUNK_MINUTES="${CHUNK_MINUTES:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"
[[ "$CHUNK_MINUTES" =~ ^[1-9][0-9]*$ && "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ && "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] \
  || die "CHUNK_MINUTES, MAX_PARALLEL and BATCH_SIZE must be positive whole numbers"
CACHE="${CACHE:-1}"
CACHE_DIR="${CACHE_DIR:-.slow_transactions_cache}"
CACHE_DAYS="${CACHE_DAYS:-7}"
CACHE_FRESH_MIN=15
if [ "$CACHE" = 1 ]; then   # drop cached results older than CACHE_DAYS
  mkdir -p "$CACHE_DIR"
  for f in "$CACHE_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ $(( $(date +%s) - $(date -r "$f" +%s) )) -lt $((CACHE_DAYS * 86400)) ] || rm -f "$f"
  done
fi

USAGE="usage: $0 [-c cluster] [-s service] [-t ms] \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (Colombia time)"
while getopts ":c:s:t:h" opt; do
  case "$opt" in
    c) CLUSTER=$OPTARG ;;
    s) SERVICE=$OPTARG ;;
    t) THRESHOLD_MS=$OPTARG ;;
    h) echo "$USAGE"; exit 0 ;;
    :) die "-$OPTARG needs a value. $USAGE" ;;
    *) die "unknown option -$OPTARG. $USAGE" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || die "$USAGE"
[[ "$THRESHOLD_MS" =~ ^[0-9]+$ ]] || die "-t must be a whole number of milliseconds"
# both go into a query regex and a path
[[ -z "$CLUSTER" || "$CLUSTER" =~ ^[a-z-]+$ ]] || die "-c must be a cluster name like productsws or credit-cardsws"
[[ -z "$SERVICE" || "$SERVICE" =~ ^[A-Za-z0-9_]+$ ]] || die "-s must be a service name like ConsultaProductos"
[ -z "$SERVICE" ] || [ -n "$CLUSTER" ] || log "Tip: add -c <cluster> with -s, or every cluster is scanned for one service"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"

in_cluster() { if [ -n "$CLUSTER" ]; then grep "^/aws/ecs/srv/${CLUSTER}-" || true; else cat; fi; }
mapfile -t MNGR_GROUPS < <(printf '%s\n' "${MNGR_GROUPS_ALL[@]}" | in_cluster)
mapfile -t ADAPTER_GROUPS < <(printf '%s\n' "${ADAPTER_GROUPS_ALL[@]}" | in_cluster)
if [ "${#MNGR_GROUPS[@]}" -eq 0 ]; then
  die "unknown cluster '$CLUSTER'; valid: $(printf '%s\n' "${MNGR_GROUPS_ALL[@]}" | sed 's|/aws/ecs/srv/||; s|-mngr$||' | tr '\n' ' ')"
fi
ALL_GROUPS=("${MNGR_GROUPS[@]}" "${ADAPTER_GROUPS[@]}")

to_label() { date -d "$1" +%Y%m%d_%H%M; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"

FILE_NAME="${SERVICE:-${CLUSTER:-all}}_$(to_label "$1")-$(to_label "$2")"
OUT_DIR="${OUT_BASE}/${FILE_NAME}"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"
OUT_CSV="$OUT_DIR/${FILE_NAME}.csv"
HEADER="trx,start_time,service,channel,total_ms,proxy_ms,adapter_ms,adapter_late_ms,http_code,adapter_error,mngr_error,step_count,steps,adapter_audit"

debug "region=$REGION window=$START..$END threshold=${THRESHOLD_MS}ms cluster=${CLUSTER:-all} service=${SERVICE:-all} out=$OUT_DIR"
if [ "$DEBUG" != 0 ]; then
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r')"
fi

# mngr step line: ... [rquid][canal][/ESBService/<Service>:<version>]...[paso][tiempo unidad]
STEP_RE='/\[(?<mngrRqid>[a-f0-9\-]+)\].*\[(?<servicio>\/[^\]]+)\].*\[(?<Paso>[^\[\]]+)\]\[(?<Tiempo>[^\[\]]+)\]$/'

# msgTs: epoch ms of the date written in the message. Insights can't parse dates, so the difference
# between the message time of day and @timestamp's (wrapped to +-12 h) is added to @timestamp.
tz_ms=$(( (10#${TZ_OFFSET:1:2} * 60 + 10#${TZ_OFFSET:4:2}) * 60000 ))
if [ "${TZ_OFFSET:0:1}" = "-" ]; then TZ_SHIFT="- $tz_ms"; else TZ_SHIFT="+ $tz_ms"; fi
MSG_TIME="
| parse @message /^\d{4}-\d\d-\d\d (?<msgH>\d\d):(?<msgM>\d\d):(?<msgS>\d\d)[.,](?<msgMilli>\d{3})/
| fields ((msgH * 60 + msgM) * 60 + msgS) * 1000 + msgMilli - (toMillis(@timestamp) ${TZ_SHIFT}) % 86400000 as msgDrift
| fields coalesce(toMillis(@timestamp) + if(msgDrift > 43200000, msgDrift - 86400000,
           if(msgDrift + 43200000 < 0, msgDrift + 86400000, msgDrift)), toMillis(@timestamp)) as msgTs"

# ---------------------------------------------------------------- step 1: slow transactions (aggregated)

log "Step 1: transactions over ${THRESHOLD_MS} ms${SERVICE:+ of $SERVICE} in ${#MNGR_GROUPS[@]} mngr + ${#ADAPTER_GROUPS[@]} adapter log groups"
# Non-AUDIT lines get a sentinel REQ/RESP time so min/max only see the adapter AUDIT lines.
# -s can't drop lines (AUDIT lines don't always name the service), so it counts the lines that do.
SVC_PARSE="" SVC_FIELD="" SVC_STAT="" SVC_FILTER=""
if [ -n "$SERVICE" ]; then
  SVC_PARSE="
| parse @message /(?<svcMark>\/ESBService\/${SERVICE}[:\]]|X-Referer=[^,\]]*-${SERVICE}-)/"
  SVC_FIELD=",
         if(isPresent(svcMark), 1, 0) as isSvc"
  SVC_STAT=", sum(isSvc) as svcLines"
  SVC_FILTER=" and svcLines > 0"
fi
q1="fields @timestamp, @message
| filter @message like \"[/\" or @message like \"::AUDIT::REQ::\" or @message like \"::AUDIT::RESP::\"
| parse @message ${STEP_RE}
| parse Tiempo /^(?<stepMs>[\d.]+)/
| parse @message /X-RqUid=(?<adpRqid>[0-9a-f\-]{36})/
| parse @message /(?<reqMark>::AUDIT::REQ::)/
| parse @message /(?<respMark>::AUDIT::RESP::)/${SVC_PARSE}${MSG_TIME}
| fields coalesce(mngrRqid, adpRqid) as trx,
         if(isPresent(reqMark), msgTs, 99999999999999) as reqTs,
         if(isPresent(respMark), msgTs, 0) as respTs,
         if(isPresent(stepMs), msgTs, 0) as stepTs,
         if(isPresent(stepMs), 1, 0) as isStep${SVC_FIELD}
| filter isPresent(trx)
| stats sum(stepMs) as totalMs, sum(isStep) as stepCount, min(reqTs) as adpReq, max(respTs) as adpResp,
    max(respTs) - min(reqTs) as adpSpan, max(stepTs) as mngrLast,
    min(msgTs) as firstTs, max(msgTs) as lastTs${SVC_STAT} by trx
| filter ((stepCount > 0 and totalMs > ${THRESHOLD_MS}) or adpSpan > ${THRESHOLD_MS})${SVC_FILTER}
| sort totalMs desc
| limit 10000"

chunk=$((CHUNK_MINUTES * 60))
for ((s = START; s < END; s += chunk)); do
  e=$((s + chunk - 1)); [ $((s + chunk)) -lt "$END" ] || e=$END
  PQ_QUERY+=("$q1") PQ_START+=("$s") PQ_END+=("$e")
done
log "  ${#PQ_QUERY[@]} slice(s) of ${CHUNK_MINUTES} min, up to ${MAX_PARALLEL} at a time"
n_slices=${#PQ_QUERY[@]}
run_parallel 1_slow

# a transaction cut by a slice boundary shows up in both slices, merge them
# trx, total, steps, adapter_ms, firstTs, lastTs, adapter_late_ms
for ((j = 0; j < n_slices; j++)); do jq -c "$FLAT" < "$TMP/1_slow_$j.json"; done | tr -d '\r' | jq -s -r '
  group_by(.trx) | map({trx: .[0].trx,
      total: (map(.totalMs | tonumber) | add), steps: (map(.stepCount | tonumber) | add),
      req: (map(.adpReq | tonumber) | min), resp: (map(.adpResp | tonumber) | max),
      mngr_last: (map(.mngrLast | tonumber) | max),
      first: (map(.firstTs | tonumber) | min), last: (map(.lastTs | tonumber) | max)})
  | .[] | [.trx, .total, .steps, (if .resp > 0 and .req < 99999999999999 then .resp - .req else "" end),
           .first, .last,
           (if .steps > 0 and .resp > .mngr_last then .resp - .mngr_last else "" end)] | @tsv' > "$TMP/1_slow.tsv"

n1=$(awk 'END{print NR}' "$TMP/1_slow.tsv")
log "  -> $n1 transaction(s) over ${THRESHOLD_MS} ms"
[ "$n1" -gt 0 ] || { echo "$HEADER" > "$OUT_CSV"; log "Nothing slow in the window. Done -> $OUT_CSV"; exit 0; }

# ---------------------------------------------------------------- step 2: steps, service and channel

log "Step 2: steps, service and channel of those transactions"
# batches of transactions close in time, each one only scans its own range +-60 s
# <start>\t<end>\t<trx|trx|...>
jq -R -s -r --argjson n "$BATCH_SIZE" --argjson ws "$START" --argjson we "$END" '
  split("\n") | map(select(length > 0) | split("\t") | {trx: .[0], first: (.[4] | tonumber), last: (.[5] | tonumber)})
  | sort_by(.first) | [range(0; length; $n) as $i | .[$i:$i + $n]] | .[]
  | ([(map(.first) | min) / 1000 | floor - 60, $ws] | max) as $s
  | ([(map(.last) | max) / 1000 | ceil + 60, $we] | min) as $e
  | [(if $s < $e then $s else $ws end), (if $s < $e then $e else $we end), (map(.trx) | join("|"))]
  | @tsv' < "$TMP/1_slow.tsv" | tr -d '\r' > "$TMP/2_batches.tsv"

while IFS=$'\t' read -r s e regex; do
  PQ_QUERY+=("fields @timestamp, @message
| filter @message like /${regex}/ and (@message like \"[/\" or @message like \"X-Name=\"
    or @message like \"GenericExceptionMapper\" or @message like \"[ERROR\")
| parse @message ${STEP_RE}
| parse Tiempo /^(?<stepMs>[\d.]+)/
| parse @message /X-RqUid=(?<adpRqid>[0-9a-f\-]{36})/
| parse @message /X-Name=(?<xname>[^,\]]+)/
| parse @message /X-Referer=[^-,]+-[^-,]+-[^-,]+-(?<refService>[^-,\]]+)/
| parse @message /::HTTPCODE::\s*(?<httpCode>\d+)/
| parse @message /\"error\":\{[^}]*\"code\":\"(?<errCode>[^\"]*)\"/
| parse @message /\"error\":\{[^}]*\"message\":\"(?<errMsg>[^\"]*)\"/
| parse @message /\"error\":\{[^}]*\"system\":\"(?<errSystem>[^\"]*)\"/
| parse @message /HttpCode::\s*(?<mapCode>\d+)::Exception:\s*(?<mapExc>[^.]*)/
| parse @message /\[(?<errRqid>[a-f0-9\-]{36})\].*\[ERROR[^\]]*\]\s*(?<mngrErr>[\s\S]*)/
| parse @message /(?<adpAudit>::AUDIT::.*)/${MSG_TIME}
| fields coalesce(mngrRqid, adpRqid, errRqid) as trx
| filter isPresent(trx)
| display msgTs, trx, Paso, stepMs, servicio, xname, refService, httpCode, errCode, errMsg, errSystem,
    mapCode, mapExc, mngrErr, adpAudit
| sort msgTs asc
| limit 10000")
  PQ_START+=("$s") PQ_END+=("$e")
done < "$TMP/2_batches.tsv"
log "  ${#PQ_QUERY[@]} batch(es) of up to ${BATCH_SIZE} transactions, up to ${MAX_PARALLEL} at a time"
n_batches=${#PQ_QUERY[@]}
run_parallel 2_batch
for ((j = 0; j < n_batches; j++)); do jq -c "$FLAT" < "$TMP/2_batch_$j.json"; done | tr -d '\r' > "$TMP/2_details.ndjson"

# ---------------------------------------------------------------- step 3: CSV

log "Step 3: building $OUT_CSV"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
          | {trx: .[0], total: (.[1] | tonumber), step_count: (.[2] | tonumber),
             adapter: (if .[3] == "" then null else (.[3] | tonumber) end),
             first: (.[4] | tonumber),
             late: (if .[6] == "" then null else (.[6] | tonumber) end)})' < "$TMP/1_slow.tsv" > "$TMP/slow.json"
jq -s '.' < "$TMP/2_details.ndjson" > "$TMP/details.json"

tz_s=$((tz_ms / 1000)); [ "${TZ_OFFSET:0:1}" != "-" ] || tz_s=$((-tz_s))
cat "$TMP/slow.json" "$TMP/details.json" | jq -s -r --arg header "$HEADER" --argjson tz "$tz_s" '
  def ms: . * 100 | round / 100;
  # epoch ms -> "YYYY-MM-DD HH:MM:SS.mmm" in TZ_OFFSET
  def local_time: ((. / 1000 | floor) + $tz | strftime("%Y-%m-%d %H:%M:%S")) + "." + ("00\(. % 1000)" | .[-3:]);
  # steps logged in the same ms are ordered by their position in the pipeline
  (["ValidateServiceInformation", "SignatureValidationStep", "BodyManipulatorStep", "XsdValidationStep",
    "DataBlockExtractorStep", "XmlToJsonConverterStep", "BackendHttpAdapter", "ResponseSigningStep",
    "ResponseBuilderStep"] | to_entries | map({(.value): .key}) | add) as $pipeline
  |
  (.[1] | group_by(.trx) | map({key: .[0].trx, value: .}) | from_entries) as $detail
  | .[0]
  # no mngr steps (e.g. adapter timeout): ranked by adapter time, service taken from X-Referer
  | map(. + {has_steps: (.step_count > 0)}) | sort_by(-([(if .has_steps then .total else 0 end), (.adapter // 0)] | max))
  | ($header | split(",")),
    (.[] | ($detail[.trx] // []) as $rows
     | [ .trx,
         ([.first, ($rows[] | .msgTs // empty | tonumber)] | min | local_time),
         (([$rows[] | .servicio // empty] | first | values | ltrimstr("/ESBService/") | split(":")[0])
          // ([$rows[] | .refService // empty] | first) // ""),
         ([$rows[] | .xname // empty] | first // ""),
         (if .has_steps then (.total | ms) else "" end),
         (if .adapter == null or (.has_steps | not) or .late != null then "" else (.total - .adapter | ms) end),
         (if .adapter == null then "" else .adapter end),
         (if .late == null then "" else .late end),
         ([$rows[] | .httpCode // empty] | first // ""),
         ([$rows[] | select(.errCode != null or .errMsg != null)
           | "\(.errSystem // "?") \(.errCode // "?"): \(.errMsg // "")"]
          + [$rows[] | select(.mapExc != null) | "HttpCode \(.mapCode): \(.mapExc | sub("\\s+$"; ""))"]
          | unique | join(" | ")),
         ([$rows[] | .mngrErr // empty | gsub("\\s+"; " ") | sub(" $"; "")] | unique | join(" | ") | .[0:200]),
         .step_count,
         ([$rows[] | select(.stepMs != null)]
          | sort_by((.msgTs // "0" | tonumber), ($pipeline[.Paso] // 99))
          | map("\(.Paso): \(.stepMs) ms") | join("; ")),
         ([$rows[] | select(.adpAudit != null)] | sort_by(.msgTs // "0" | tonumber)
          | map(.adpAudit | ltrimstr("::AUDIT::")) | join(" || ")) ])
  | @csv' | tr -d '\r' > "$OUT_CSV"

log "Done -> $OUT_CSV ($(($(awk 'END{print NR}' "$OUT_CSV") - 1)) transaction(s))"
