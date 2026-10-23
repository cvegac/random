#!/usr/bin/env bash
# Dumps the raw logs of one or more log groups over a date range, one CSV per log group.
# Insights returns at most 10,000 rows per query, so the range goes in chunks and a chunk that
# hits the limit is split in half until it fits.
#
# Usage: ./fetch_logs.sh "2026-09-20 00:00:00" "2026-09-20 06:00:00" /aws/ecs/srv/productsws-mngr [...]
#        times are Colombia time (UTC-5)
# Output: logs_output/<log-group>_<start>__<end>.csv (colombia_time,message)
# Env: AWS_REGION, OUT_BASE, CHUNK_MINUTES (30), MESSAGE_FILTER (Insights "like" text), DEBUG (0/1/2)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: don't turn /aws/... args into Windows paths
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli on Windows defaults to cp1252 and fails on some log lines

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
OUT_BASE="${OUT_BASE:-logs_output}"
CHUNK_MINUTES="${CHUNK_MINUTES:-30}"
MESSAGE_FILTER="${MESSAGE_FILTER:-}"
MAX_ROWS=10000                           # Logs Insights hard limit per query
TZ_OFFSET="-05:00"                       # Colombia
TZ_OFFSET_SECONDS=-18000

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\" <log-group> [<log-group>...]  (Colombia time)"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
[[ "$CHUNK_MINUTES" =~ ^[0-9]+$ ]] && [ "$CHUNK_MINUTES" -gt 0 ] || die "CHUNK_MINUTES must be a positive integer"

to_epoch()  { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
to_label()  { date -d "$1" +%Y%m%d_%H%M%S; }
fmt_local() { date -u -d "@$(( $1 + TZ_OFFSET_SECONDS ))" '+%Y-%m-%d %H:%M:%S'; }
fmt_utc()   { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }   # what the CloudWatch console shows

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"
LABEL="$(to_label "$1")__$(to_label "$2")"
shift 2
LOG_GROUPS=("$@")
CHUNK=$((CHUNK_MINUTES * 60))

TMP="${OUT_BASE}/_intermediate"
mkdir -p "$TMP"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION window=$START..$END chunk=${CHUNK_MINUTES}m filter='${MESSAGE_FILTER}' out=$OUT_BASE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

# ---------------------------------------------------------------- helpers

# aws wrapper: --no-verify-ssl and drop the urllib3 warnings from stderr
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

# run_query <query> <start> <end> <log group>...  -> results JSON
run_query() {
  local query="$1" start="$2" end="$3"; shift 3
  local qid res status polls=0 t0=$SECONDS
  debug "start-query: $(fmt_local "$start") .. $(fmt_local "$end") on $*"
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
  printf '%s' "$res"
}

if [ -n "$MESSAGE_FILTER" ]; then
  QUERY="fields @timestamp, @message
| filter @message like '${MESSAGE_FILTER}'
| sort @timestamp asc
| limit ${MAX_ROWS}"
else
  QUERY="fields @timestamp, @message
| sort @timestamp asc
| limit ${MAX_ROWS}"
fi

# the same row can come back more than once (between chunks and even inside one result),
# so @ptr is kept and the rows are deduplicated once at the end
ROWS_JQ='
  .results[] | (map({(.field): .value}) | add)
  | {ts: .["@timestamp"], ptr: (.["@ptr"] // null), message: .["@message"]}'

FINAL_JQ='
  def col: (.[0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime + $off | strftime("%Y-%m-%d %H:%M:%S")) + .[19:];
  unique_by(.ptr) | sort_by(.ts) | .[]
  | [ (.ts | col), (.message | gsub("[\r\n]+"; " ")) ] | @csv'

TOTAL=0

write_piece() {
  local n
  jq -c "$ROWS_JQ" < "$TMP/piece.json" | tr -d '\r' >> "$RAW_FILE"
  n=$(jq '.results | length' < "$TMP/piece.json" | tr -d '\r')
  TOTAL=$((TOTAL + n))
  log "    wrote $n rows (total for this log group: $TOTAL, before de-duplication)"
}

# fetch_range <start> <end>  (uses $LG and $RAW_FILE), splits in half when the limit is hit
fetch_range() {
  local s="$1" e="$2" n mid
  run_query "$QUERY" "$s" "$e" "$LG" > "$TMP/piece.json"
  n=$(jq '.results | length' < "$TMP/piece.json" | tr -d '\r')
  if [ "$n" -eq 0 ]; then
    log "    WARNING: 0 rows from $LG (recordsScanned=$(jq -r '.statistics.recordsScanned // "?"' < "$TMP/piece.json" | tr -d '\r'))."
    log "    scanned=0 means that log group has NO events in $(fmt_utc "$s") .. $(fmt_utc "$e") UTC. Input times are read as Colombia (UTC-5):"
    log "    if you copied them from the CloudWatch console (UTC), subtract 5 hours, and double check the log group name."
  fi
  if [ "$n" -ge "$MAX_ROWS" ]; then
    if [ $((e - s)) -gt 1 ]; then
      mid=$(( (s + e) / 2 ))
      log "    $n rows = query limit, splitting: $(fmt_local "$s") | $(fmt_local "$mid") | $(fmt_local "$e")"
      fetch_range "$s" "$mid"
      fetch_range "$mid" "$e"
      return 0
    fi
    log "    WARNING: $n rows within 1 second ($(fmt_local "$s")); logs beyond the limit are lost"
  fi
  write_piece "$e"
}

# ---------------------------------------------------------------- main

N_CHUNKS=$(( (END - START + CHUNK - 1) / CHUNK ))

for LG in "${LOG_GROUPS[@]}"; do
  safe=$(printf '%s' "${LG#/}" | tr -c 'A-Za-z0-9_.\n-' '_')
  OUT_FILE="${OUT_BASE}/${safe}_${LABEL}.csv"
  RAW_FILE="$TMP/raw_${safe}.ndjson"
  : > "$RAW_FILE"
  TOTAL=0
  log "Log group $LG -> $OUT_FILE ($N_CHUNKS chunks of ${CHUNK_MINUTES}m)"

  k=0
  for ((s = START; s < END; s += CHUNK)); do
    k=$((k + 1))
    e=$((s + CHUNK)); [ "$e" -le "$END" ] || e="$END"
    log "  chunk $k/$N_CHUNKS: $(fmt_local "$s") .. $(fmt_local "$e") Colombia  =  $(fmt_utc "$s") .. $(fmt_utc "$e") UTC"
    fetch_range "$s" "$e"
  done

  echo 'colombia_time,message' > "$OUT_FILE"
  jq -s -r --argjson off "$TZ_OFFSET_SECONDS" "$FINAL_JQ" < "$RAW_FILE" | tr -d '\r' >> "$OUT_FILE"
  final=$(($(awk 'END{print NR}' "$OUT_FILE") - 1))
  log "Done $LG: $TOTAL rows fetched, $final unique -> $OUT_FILE"
done
