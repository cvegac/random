#!/usr/bin/env bash
# Dumps raw CloudWatch Logs of one or more log groups over a date range, fetched in time chunks.
# Nothing is parsed or grouped: one CSV per log group, named <log-group>_<start>__<end>.csv.
#
# Chunking exists because Logs Insights returns at most 10,000 rows per query. If a chunk hits
# that limit it is split in half automatically (recursively) so no logs are lost.
#
# Usage:  ./fetch_logs.sh "2026-09-20 00:00:00" "2026-09-20 06:00:00" /aws/ecs/srv/productsws-mngr [more log groups...]
#         (times are Colombia local time, UTC-5)
# Output: logs_output/aws_ecs_srv_productsws-mngr_20260920_000000__20260920_060000.csv  (colombia_time,message)
#
# Requires: aws cli v2 (with active credentials/profile: AWS_PROFILE), jq, gawk/awk, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, CHUNK_MINUTES (default 30),
#                    MESSAGE_FILTER (Insights "like" text, e.g. ERROR; default: no filter = all logs),
#                    DEBUG (0 = quiet, 1 = verbose [default], 2 = also set -x)
set -euo pipefail

# Git Bash on Windows rewrites "/aws/ecs/..." into a C:\... path; this prevents it.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

# We run with --no-verify-ssl, so urllib3 warns on every call: silence it (aws_cli also filters stderr).
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
# The Python bundled with the aws cli defaults to cp1252 ('charmap') on Windows and crashes when a
# log line has a character it cannot map. Force UTF-8.
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

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
# epoch -> Colombia wall clock (for logs only)
fmt_local() { date -u -d "@$(( $1 + TZ_OFFSET_SECONDS ))" '+%Y-%m-%d %H:%M:%S'; }
# epoch -> UTC wall clock (what the CloudWatch console shows)
fmt_utc()   { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "start time must be before end time"
LABEL="$(to_label "$1")__$(to_label "$2")"
shift 2
LOG_GROUPS=("$@")
CHUNK=$((CHUNK_MINUTES * 60))

TMP="${OUT_BASE}/_intermediate"
mkdir -p "$TMP"
SEEN_FILE="$TMP/boundary_ptrs.json"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION window=$START..$END chunk=${CHUNK_MINUTES}m filter='${MESSAGE_FILTER}' out=$OUT_BASE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

# ---------------------------------------------------------------- helpers

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

# run_query "<query>" <start_epoch> <end_epoch> <log group>...   -> prints the results JSON
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

# Query: raw logs, oldest first. The optional filter is the only thing that is not "everything".
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

# jq: results[] -> CSV rows "colombia_time,message", skipping rows whose @ptr was already written
# at the boundary of the previous piece (Insights time ranges are inclusive on both ends).
ROWS_JQ='
  def col: (.[0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime + $off | strftime("%Y-%m-%d %H:%M:%S")) + .[19:];
  .results[] | (map({(.field): .value}) | add)
  | select((.["@ptr"] // "") as $p | $p == "" or ($seen | any(. == $p) | not))
  | [ (.["@timestamp"] | col), (.["@message"] | gsub("[\r\n]+"; " ")) ] | @csv'

# jq: @ptr of the rows in the last 2 seconds of a piece -> remembered to de-duplicate the next piece
SEEN_JQ='
  [ .results[] | (map({(.field): .value}) | add)
    | select((.["@timestamp"][0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= ($e - 2))
    | (.["@ptr"] // empty) ]'

TOTAL=0

# write_piece <end_epoch>   (reads $TMP/piece.json, appends to $OUT_FILE)
write_piece() {
  local e="$1" written
  jq -r --argjson off "$TZ_OFFSET_SECONDS" --argjson seen "$(<"$SEEN_FILE")" "$ROWS_JQ" \
     < "$TMP/piece.json" | tr -d '\r' > "$TMP/piece.csv"
  written=$(awk 'END {print NR}' "$TMP/piece.csv")
  tr -d '\r' < "$TMP/piece.csv" >> "$OUT_FILE"
  jq -c --argjson e "$e" "$SEEN_JQ" < "$TMP/piece.json" | tr -d '\r' > "$SEEN_FILE"
  TOTAL=$((TOTAL + written))
  log "    wrote $written rows (total for this log group: $TOTAL)"
}

# fetch_range <start_epoch> <end_epoch>   (uses $LG and $OUT_FILE). Splits in half if the limit is hit.
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
  echo 'colombia_time,message' > "$OUT_FILE"
  echo '[]' > "$SEEN_FILE"
  TOTAL=0
  log "Log group $LG -> $OUT_FILE ($N_CHUNKS chunks of ${CHUNK_MINUTES}m)"

  k=0
  for ((s = START; s < END; s += CHUNK)); do
    k=$((k + 1))
    e=$((s + CHUNK)); [ "$e" -le "$END" ] || e="$END"
    log "  chunk $k/$N_CHUNKS: $(fmt_local "$s") .. $(fmt_local "$e") Colombia  =  $(fmt_utc "$s") .. $(fmt_utc "$e") UTC"
    fetch_range "$s" "$e"
  done
  log "Done $LG: $TOTAL rows -> $OUT_FILE"
done
