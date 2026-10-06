#!/usr/bin/env bash
# Lists the transactions slower than THRESHOLD_MS end to end in the mngr, with the time split between the
# mngr itself (proxy) and the adapter it calls, plus every ESB step.
# Self-contained on purpose (copied as a single file to machines without this repo): no lib/, no dashboard
# JSON. The log group lists below mirror the SOURCE lines of NexusGeneral.json; keep them in sync.
#   total_ms   = sum of the mngr ESB step times ([rquid]...[paso][tiempo unidad] lines)
#   adapter_ms = adapter ::AUDIT::RESP:: time - ::AUDIT::REQ:: time (same X-RqUid); empty if no adapter call
#   proxy_ms   = total_ms - adapter_ms (negative = no ESB step wraps the adapter call)
#
# Step 1 aggregates per transaction inside CloudWatch and returns only the slow ones; step 2 fetches the
# steps, service and channel (adapter X-Name) of just those, in batches of rquids.
#
# Usage:  ./slow_transactions.sh [-c cluster] [-s service] [-t ms] "<start>" "<end>"
#           -c  only this ws cluster's log groups, e.g. productsws (default: all clusters)
#           -s  only transactions of this ESB service, e.g. ConsultaProductos (exact name, case-sensitive)
#           -t  minimum total time in ms (default 1000)
#           start/end: "YYYY-MM-DD HH:MM:SS", Colombia local time (UTC-5)
# Example: ./slow_transactions.sh -c productsws -s ConsultaProductos "2026-10-06 08:00:00" "2026-10-06 09:00:00"
# Output: results/<name>/<name>.csv, slowest first, where <name> = <service>_<start>-<end>
#         (e.g. ConsultaCuentasInscritas_20261003_0000-20261004_0000; the cluster, or "all", without -s)
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, DEBUG (0 = quiet, 1 = verbose [default], 2 = also set -x),
#                    THRESHOLD_MS / CLUSTER / SERVICE  defaults for -t / -c / -s
#                    BATCH_SIZE    rquids per step-2 query (default 100; query length limit 10,000 chars)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # stop Git Bash rewriting "/aws/ecs/..." as a path
export PYTHONWARNINGS="ignore:Unverified HTTPS request"   # silence urllib3's --no-verify-ssl warning
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli's bundled Python defaults to cp1252 on Windows
                                              # and crashes on log lines it can't map to that charset
# Side effect of MSYS2_ARG_CONV_EXCL: an absolute path passed as an ARGUMENT to a native Windows binary
# (jq.exe) reaches it unconverted (/d/... instead of D:\...). Always feed jq files through stdin.

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
TZ_OFFSET="-05:00"                       # Colombia (no DST)
FLAT='.results[] | (map({(.field): .value}) | add)'   # Insights row [{field, value}...] -> {field: value}

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

# "YYYY-MM-DD HH:MM:SS" in Colombia time -> epoch seconds
to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }

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

# cw_submit "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the query id
# Retries while the account is at its concurrent-query quota (LimitExceededException).
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

# cw_collect <query id>  -> polls until the query finishes, prints the results JSON
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

# run_query "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the results JSON
run_query() {
  local qid
  qid=$(cw_submit "$@") || die "start-query failed"
  cw_collect "$qid"
}

OUT_BASE="${OUT_BASE:-results}"
THRESHOLD_MS="${THRESHOLD_MS:-1000}"
CLUSTER="${CLUSTER:-}"
SERVICE="${SERVICE:-}"
BATCH_SIZE="${BATCH_SIZE:-100}"

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
# both end up inside a query regex / a path: plain names only
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

# <service>_<start>-<end>, e.g. ConsultaCuentasInscritas_20261003_0000-20261004_0000 (cluster or "all" without -s)
FILE_NAME="${SERVICE:-${CLUSTER:-all}}_$(to_label "$1")-$(to_label "$2")"
OUT_DIR="${OUT_BASE}/${FILE_NAME}"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"
OUT_CSV="$OUT_DIR/${FILE_NAME}.csv"
HEADER="trx,service,channel,total_ms,proxy_ms,adapter_ms,step_count,steps"

debug "region=$REGION window=$START..$END threshold=${THRESHOLD_MS}ms cluster=${CLUSTER:-all} service=${SERVICE:-all} out=$OUT_DIR"
if [ "$DEBUG" != 0 ]; then
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r')"
fi

# mngr ESB step line: ... [trace] [rquid][canal][/ESBService/<Service>:<version>]...[paso][tiempo unidad]
STEP_RE='/\[(?<mngrRqid>[a-f0-9\-]+)\].*\[(?<servicio>\/[^\]]+)\].*\[(?<Paso>[^\[\]]+)\]\[(?<Tiempo>[^\[\]]+)\]$/'

# ---------------------------------------------------------------- step 1: slow transactions (aggregated)

log "Step 1: transactions over ${THRESHOLD_MS} ms${SERVICE:+ of $SERVICE} in ${#MNGR_GROUPS[@]} mngr + ${#ADAPTER_GROUPS[@]} adapter log groups"
# Only numeric aggregates here (sum/min/max), which ignore lines without the field. A REQ/RESP time is
# replaced by a sentinel on every other line so min/max pick only the adapter's own AUDIT lines.
# The service filter can't drop lines (adapter AUDIT lines don't always name the service): it counts the
# trx's mngr steps of that service and keeps the trx if there is at least one.
SVC_PARSE="" SVC_FIELD="" SVC_STAT="" SVC_FILTER=""
if [ -n "$SERVICE" ]; then
  SVC_PARSE="
| parse @message /(?<svcMark>\/ESBService\/${SERVICE}[:\]])/"
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
| parse @message /(?<respMark>::AUDIT::RESP::)/${SVC_PARSE}
| fields coalesce(mngrRqid, adpRqid) as trx,
         if(isPresent(reqMark), toMillis(@timestamp), 99999999999999) as reqTs,
         if(isPresent(respMark), toMillis(@timestamp), 0) as respTs,
         if(isPresent(stepMs), 1, 0) as isStep${SVC_FIELD}
| filter isPresent(trx)
| stats sum(stepMs) as totalMs, sum(isStep) as stepCount, min(reqTs) as adpReq, max(respTs) as adpResp${SVC_STAT} by trx
| filter stepCount > 0 and totalMs > ${THRESHOLD_MS}${SVC_FILTER}
| sort totalMs desc
| limit 10000"

run_query "$q1" "$START" "$END" "${ALL_GROUPS[@]}" > "$TMP/1_slow.json"
n1=$(jq '.results | length' < "$TMP/1_slow.json" | tr -d '\r')
[ "$n1" -lt 10000 ] || log "  WARNING: step 1 hit 10,000 rows (truncated). Use a shorter window, -c or -s."

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
# TSV -> JSON array via stdin (never a jq path argument, see the MSYS note at the top)
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
