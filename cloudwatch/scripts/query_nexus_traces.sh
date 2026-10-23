#!/usr/bin/env bash
# Fetches the ESB step-timing lines of a mngr log group and writes one row per transaction
# (rquid + servicio) with the 9 pipeline step times as columns.
# The range is queried whole and only split where a query hits 10,000 rows. Queries run in parallel
# and are cached on disk, so running it again only fetches what is missing.
#
# Usage: ./query_nexus_traces.sh <log-group> "<start>" "<end>" [output.csv]
#        start/end in local time (TZ_OFFSET, default -05:00)
# Env: AWS_REGION, TZ_OFFSET (+00:00 for UTC input), PARALLEL (6), CACHE_DIR (.query_nexus_cache,
#      never pruned), BAR_WIDTH (50), PROGRESS_STEP (1), DEBUG (0/1/2)
set -euo pipefail
set -m   # one process group per job, so the exit trap can kill the job and its children

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: don't turn /aws/... args into Windows paths
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli on Windows defaults to cp1252 and fails on some log lines

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
MAX_ROWS=10000                    # must match "limit" in QUERY
TZ_OFFSET="${TZ_OFFSET:--05:00}"  # Bogota, no DST

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <log-group> \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\" [output.csv]  (local time, offset ${TZ_OFFSET})"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
[[ "$TZ_OFFSET" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "TZ_OFFSET must look like -05:00 or +00:00 (got '$TZ_OFFSET')"

LOG_GROUP="$1"

# fixed offset instead of TZ=America/Bogota, which silently fails without the zoneinfo database
tzo="${TZ_OFFSET#[+-]}"; tzsign=1; [ "${TZ_OFFSET:0:1}" = "-" ] && tzsign=-1
TZ_OFFSET_SECONDS=$(( tzsign * (10#${tzo%%:*} * 3600 + 10#${tzo##*:} * 60) ))

to_epoch()  { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
to_label()  { date -d "$1 ${TZ_OFFSET}" +%Y%m%d_%H%M%S 2>/dev/null || die "invalid date: '$1'"; }
fmt_local() { date -u -d "@$(( $1 + TZ_OFFSET_SECONDS ))" '+%Y-%m-%d %H:%M:%S'; }
fmt_utc()   { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }   # what the CloudWatch console shows

START=$(to_epoch "$2")
END=$(to_epoch "$3")
[ "$START" -lt "$END" ] || die "start time must be before end time"
safe=$(printf '%s' "${LOG_GROUP#/}" | tr -c 'A-Za-z0-9_.\n-' '_')
OUTPUT_FILE="${4:-${safe}_$(to_label "$2")__$(to_label "$3").csv}"

CSV_HEADER='horaprimeratrx,horaultimatrx,rquid,servicio,ValidateServiceInformation,SignatureValidationStep,BodyManipulatorStep,XsdValidationStep,DataBlockExtractorStep,XmlToJsonConverterStep,BackendHttpAdapter,ResponseSigningStep,ResponseBuilderStep'

PARALLEL="${PARALLEL:-6}"
TMP=$(mktemp -d)
# kill running queries before removing $TMP, or they keep writing into it
trap 'for _p in $(jobs -p); do kill -- "-$_p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
RAW="$TMP/raw.ndjson"
JOBDIR="$TMP/jobs"; mkdir -p "$JOBDIR"

# ---- progress bar: which parts of the range are done, in 1/8 character blocks
BAR_WIDTH="${BAR_WIDTH:-50}"
PROGRESS_STEP="${PROGRESS_STEP:-1}"   # reprint every N points of coverage
TOTAL_SECONDS=$((END - START))
COVERED_FILE="$TMP/covered.tsv"
: > "$COVERED_FILE"
LAST_PROGRESS_PCT=-100
BLOCKS=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')

fmt_hms() { local s="$1"; printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); }

mark_covered() {
  local s="$1" e="$2" out levels_csv pct bar lvl
  printf '%s\t%s\n' "$s" "$e" >> "$COVERED_FILE"
  out=$(awk -v start="$START" -v total="$TOTAL_SECONDS" -v w="$BAR_WIDTH" -v file="$COVERED_FILE" '
    BEGIN {
      bw = total / w
      while ((getline line < file) > 0) {
        split(line, a, "\t")
        ws = a[1] - start; we = a[2] - start
        if (we > ws) covered_total += (we - ws)
        b0 = int(ws / bw); b1 = int((we - 0.0001) / bw)
        if (b1 >= w) b1 = w - 1
        for (b = b0; b <= b1; b++) {
          bs = b * bw; be = (b + 1) * bw
          lo = (ws > bs) ? ws : bs
          hi = (we < be) ? we : be
          if (hi > lo) cov[b] += (hi - lo)
        }
      }
      close(file)
      line = ""
      for (b = 0; b < w; b++) {
        frac = (bw > 0) ? cov[b] / bw : 0
        if (frac > 1) frac = 1
        line = line int(frac * 8 + 0.5) ","
      }
      pct = (total > 0) ? covered_total / total * 100 : 100
      printf "%s;%.1f;%d\n", line, pct, covered_total
    }')
  IFS=';' read -r levels_csv pct covered_total <<< "$out"
  awk -v p="$pct" -v last="$LAST_PROGRESS_PCT" -v step="$PROGRESS_STEP" 'BEGIN{exit !(p-last>=step || p>=99.95)}' || return 0
  local -a levels; IFS=',' read -ra levels <<< "$levels_csv"
  bar=""
  for lvl in "${levels[@]}"; do [ -n "$lvl" ] && bar+="${BLOCKS[$lvl]}"; done
  log "  Progress [$bar] ${pct}%  ($(fmt_hms "$covered_total") / $(fmt_hms "$TOTAL_SECONDS"))"
  LAST_PROGRESS_PCT="$pct"
}

# cache key: log group + query text + window
CACHE_DIR="${CACHE_DIR:-.query_nexus_cache}"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION offset=$TZ_OFFSET window=$START..$END out=$OUTPUT_FILE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi
log "Window: $(fmt_local "$START") .. $(fmt_local "$END")  (offset $TZ_OFFSET)  =  $(fmt_utc "$START") .. $(fmt_utc "$END") UTC"

# ---------------------------------------------------------------- aws helpers

# aws wrapper: --no-verify-ssl, drops the urllib3 warnings and retries throttling/transient errors
aws_cli() {
  local errfile outfile rc=0 real attempt max=4
  for ((attempt = 1; attempt <= max; attempt++)); do
    errfile=$(mktemp); outfile=$(mktemp)
    aws --no-verify-ssl "$@" > "$outfile" 2> "$errfile"
    rc=$?
    real=$(awk '!/InsecureRequestWarning/ && !/^[[:space:]]*warnings\.warn\(/' "$errfile" | tr -d '\r')
    rm -f "$errfile"
    if [ "$rc" -eq 0 ]; then
      cat "$outfile"; rm -f "$outfile"
      return 0
    fi
    rm -f "$outfile"
    if [ -n "$real" ]; then
      echo "$real" >&2
      echo "[$(date +%T)] aws ${1:-} ${2:-} (exit $rc, attempt $attempt/$max): $real" >> "$TMP/aws_errors.log"
    fi
    case "$real" in
      *ServiceUnavailableException*|*ThrottlingException*|*TooManyRequestsException*|*RequestLimitExceeded*|*InternalServerError*|*InternalFailure*)
        if [ "$attempt" -lt "$max" ]; then
          log "  transient AWS error on attempt $attempt/$max, retrying in $((attempt * 3))s"
          sleep $((attempt * 3))
          continue
        fi ;;
    esac
    break
  done
  log "aws ${1:-} ${2:-} FAILED (exit code $rc, attempt $attempt/$max)"
  case "$real" in
    *charmap*) log "  hint: encoding problem in the aws cli output; check DEBUG output and PYTHONIOENCODING=$PYTHONIOENCODING" ;;
  esac
  return "$rc"
}

run_query() {
  local start="$1" end="$2" qid res status polls=0 t0=$SECONDS
  debug "start-query: $(fmt_local "$start") .. $(fmt_local "$end")"
  qid=$(aws_cli logs start-query --region "$REGION" \
          --start-time "$start" --end-time "$end" \
          --query-string "$QUERY" --log-group-names "$LOG_GROUP" \
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

# ---------------------------------------------------------------- step 1: raw lines

read -r -d '' QUERY <<'EOF' || true
fields @timestamp, @ptr, @message
| parse @message /\[(?<rquid>[a-f0-9\-]+)\].*\[(?<servicio>\/[^\]]+)\].*\[(?<Paso>[^\[\]]+)\]\[(?<Tiempo>[^\[\]]+)\]$/
| filter ispresent(rquid) and ispresent(Paso) and ispresent(Tiempo) and Tiempo != '-' and Tiempo != 'AuditLog'
| sort @timestamp asc
| limit 10000
EOF

CACHE_KEY_DIR="$CACHE_DIR/$(printf '%s' "${LOG_GROUP#/}" | tr -c 'A-Za-z0-9_.\n-' '_')/$(printf '%s' "$QUERY" | cksum | cut -d' ' -f1)"
mkdir -p "$CACHE_KEY_DIR"
debug "cache: $CACHE_KEY_DIR"

# @ptr is kept to drop the rows repeated at window boundaries
ROWS_JQ='
  .results[] | (map({(.field): .value}) | add)
  | {ts: .["@timestamp"], ptr: (.["@ptr"] // null),
     rqid: .rquid, servicio: .servicio, paso: .Paso, tiempo: .Tiempo}'

# load what is already cached; whatever is missing goes to QUEUE
scan_cache() {
  local s="$1" e="$2" cache_file split_file mid
  cache_file="$CACHE_KEY_DIR/${s}_${e}.ndjson"
  split_file="$CACHE_KEY_DIR/${s}_${e}.split"
  if [ -f "$cache_file" ]; then
    cat "$cache_file" >> "$RAW.dup"
    mark_covered "$s" "$e"
    return 0
  fi
  if [ -f "$split_file" ]; then
    mid=$(( (s + e) / 2 ))
    scan_cache "$s" "$mid"
    scan_cache "$mid" "$e"
    return 0
  fi
  QUEUE+=("$s:$e")
}

log "Checking the local cache before fetching anything from AWS..."
QUEUE=()
scan_cache "$START" "$END"
if [ "$LAST_PROGRESS_PCT" = "-100" ]; then
  log "  nothing usable cached yet for this exact range"
elif awk -v p="$LAST_PROGRESS_PCT" 'BEGIN{exit !(p>=99.95)}'; then
  log "  full range already cached, nothing to fetch"
else
  log "  ${LAST_PROGRESS_PCT}% already cached, fetching the rest"
fi

# a window over MAX_ROWS is only known after querying it; then its two halves are queued
declare -A INFLIGHT=()   # pid -> "piece_file:s:e"
n_jobs=0

launch_next() {
  local item="${QUEUE[0]}" s e piece cache_file split_file mid n
  QUEUE=("${QUEUE[@]:1}")
  s="${item%%:*}"; e="${item##*:}"
  cache_file="$CACHE_KEY_DIR/${s}_${e}.ndjson"
  split_file="$CACHE_KEY_DIR/${s}_${e}.split"
  if [ -f "$cache_file" ]; then
    n=$(awk 'END{print NR}' "$cache_file")
    cat "$cache_file" >> "$RAW.dup"
    log "  cache hit: $(fmt_local "$s") .. $(fmt_local "$e") ($n rows, no AWS call)"
    mark_covered "$s" "$e"
    return 0
  fi
  if [ -f "$split_file" ]; then
    mid=$(( (s + e) / 2 ))
    log "  split cache hit: $(fmt_local "$s") .. $(fmt_local "$e") (known to overflow, no AWS call)"
    QUEUE+=("$s:$mid" "$mid:$e")
    return 0
  fi
  n_jobs=$((n_jobs + 1))
  piece="$JOBDIR/p${n_jobs}.json"
  run_query "$s" "$e" > "$piece" &
  INFLIGHT[$!]="$piece:$s:$e"
}

log "Step 1: fetching raw matching lines, up to $PARALLEL at a time (auto-splits any window that hits $MAX_ROWS rows)"
while [ "${#QUEUE[@]}" -gt 0 ] || [ "${#INFLIGHT[@]}" -gt 0 ]; do
  while [ "${#INFLIGHT[@]}" -lt "$PARALLEL" ] && [ "${#QUEUE[@]}" -gt 0 ]; do
    launch_next
  done
  [ "${#INFLIGHT[@]}" -gt 0 ] || break
  wait -n || true   # exit status is checked per job below
  for pid in "${!INFLIGHT[@]}"; do
    kill -0 "$pid" 2>/dev/null && continue   # still running
    info="${INFLIGHT[$pid]}"; unset 'INFLIGHT[$pid]'
    piece="${info%%:*}"; rest="${info#*:}"; s="${rest%%:*}"; e="${rest##*:}"
    wait "$pid"; rc=$?
    [ "$rc" -eq 0 ] || die "background query for $(fmt_local "$s") .. $(fmt_local "$e") failed (exit $rc); see $TMP/aws_errors.log"
    n=$(jq '.results | length' < "$piece" | tr -d '\r')
    if [ "$n" -ge "$MAX_ROWS" ] && [ $((e - s)) -gt 1 ]; then
      mid=$(( (s + e) / 2 ))
      log "  $n rows = query limit, splitting: $(fmt_local "$s") | $(fmt_local "$mid") | $(fmt_local "$e")"
      : > "$CACHE_KEY_DIR/${s}_${e}.split"
      QUEUE+=("$s:$mid" "$mid:$e")
    else
      [ "$n" -lt "$MAX_ROWS" ] || log "  WARNING: $n rows within 1 second ($(fmt_local "$s")); rows beyond the limit are lost"
      jq -c "$ROWS_JQ" < "$piece" | tr -d '\r' | tee -a "$RAW.dup" > "$CACHE_KEY_DIR/${s}_${e}.ndjson"
      log "  wrote $n rows ($(fmt_local "$s") .. $(fmt_local "$e"))"
      mark_covered "$s" "$e"
    fi
    rm -f "$piece"
  done
done
awk -v p="$LAST_PROGRESS_PCT" 'BEGIN{exit !(p<99.95)}' && PROGRESS_STEP=0 mark_covered "$START" "$START"

if [ ! -s "$RAW.dup" ]; then
  log "No matching lines in this window. Writing an empty CSV."
  echo "$CSV_HEADER" > "$OUTPUT_FILE"
  exit 0
fi

# Insights ranges include both ends, so boundary rows come twice
jq -s -c 'unique_by(.ptr) | .[]' < "$RAW.dup" | tr -d '\r' > "$RAW"
log "  -> $(awk 'END{print NR}' "$RAW.dup") rows fetched, $(awk 'END{print NR}' "$RAW") unique after de-duplicating boundary overlaps"

# ---------------------------------------------------------------- step 2: aggregate

log "Step 2: aggregating by rquid+servicio over the full dataset -> $OUTPUT_FILE"
echo "$CSV_HEADER" > "$OUTPUT_FILE"

jq -s -r --argjson off "$TZ_OFFSET_SECONDS" '
  def col: (.[0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime + $off | strftime("%Y-%m-%d %H:%M:%S")) + .[19:];
  sort_by(.ts)
  | group_by([.rqid, .servicio])
  | map(
      (reduce .[] as $r ({}; . + {($r.paso): $r.tiempo})) as $steps
      | {
          horaprimeratrx: (map(.ts) | min | col),
          horaultimatrx:  (map(.ts) | max | col),
          rquid: .[0].rqid,
          servicio: .[0].servicio
        } + $steps
    )
  | sort_by(.horaultimatrx)
  | .[]
  | [ .horaprimeratrx, .horaultimatrx, .rquid, .servicio,
      .ValidateServiceInformation, .SignatureValidationStep, .BodyManipulatorStep,
      .XsdValidationStep, .DataBlockExtractorStep, .XmlToJsonConverterStep,
      .BackendHttpAdapter, .ResponseSigningStep, .ResponseBuilderStep ] | @csv
' < "$RAW" | tr -d '\r' >> "$OUTPUT_FILE"

log "Done: $(($(awk 'END{print NR}' "$OUTPUT_FILE") - 1)) transactions -> $OUTPUT_FILE"
