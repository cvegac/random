#!/usr/bin/env bash
# Queries CloudWatch Logs Insights for ESB step-timing traces and aggregates them into one row
# per transaction (rquid + servicio), with all 9 pipeline step times as columns.
#
# Replaces consultaNexusPasoPaso.sh. Fixes 3 bugs a teammate found in it:
#
#   1. Dates were converted with TZ="America/Bogota", which needs the IANA zoneinfo database.
#      Whether that's available is inconsistent across machines/Git-Bash installs (we saw both
#      behaviors while testing in the same conversation), so input could silently be read as UTC
#      while the "local" printout still claimed Bogota. Fix: convert with fixed-offset arithmetic
#      (no zoneinfo dependency at all) and print both local and UTC for every window, so a
#      mismatch is visible immediately instead of silent.
#
#   2. A chunk silently stopped at 10,000 aggregated rows (the Logs Insights hard cap) with no
#      warning and no further splitting: rows beyond 10,000 were lost.
#      Fix: detect the cap and bisect the time window automatically.
#
#   3. Aggregating with `stats ... by rquid, servicio` separately inside each fixed time chunk
#      split any transaction that straddled a chunk boundary into two incomplete/duplicate rows
#      (each chunk only ever saw part of that transaction's steps).
#      Fix: fetch raw (unaggregated) matching lines first, across auto-split chunks, de-duplicate
#      boundary lines by @ptr, and aggregate ONCE in jq over the complete dataset. A transaction
#      can no longer be cut by a chunk boundary, because chunking no longer touches the
#      aggregation — it only touches how the raw lines are fetched.
#
# You no longer pick a chunk/interval size: it starts with the whole range in one query and only
# splits when a window actually hits the 10,000-row cap.
#
# Usage:  ./query_nexus_traces.sh <log-group> "<start>" "<end>" [output.csv]
#         (start/end are local time, offset TZ_OFFSET below; default -05:00 = Bogota)
#
# BREAKING CHANGE vs consultaNexusPasoPaso.sh: there is no more $4 interval-minutes argument
# (chunking is automatic now) — the old $5 output file is $4 here.
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, TZ_OFFSET (default -05:00; use +00:00 to type UTC times, e.g.
#                    copied straight from the CloudWatch console), DEBUG (0 = quiet, 1 = verbose
#                    [default], 2 = also set -x)
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
MAX_ROWS=10000                           # Logs Insights hard limit per query; keep in sync with the
                                          # "| limit 10000" literal in QUERY below (jq can't see env vars there).
TZ_OFFSET="${TZ_OFFSET:--05:00}"         # Bogota, no DST. Does not need any zoneinfo database.

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <log-group> \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\" [output.csv]  (local time, offset ${TZ_OFFSET})"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
[[ "$TZ_OFFSET" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "TZ_OFFSET must look like -05:00 or +00:00 (got '$TZ_OFFSET')"

LOG_GROUP="$1"

# Pure arithmetic offset: does NOT touch the system zoneinfo database, so it can't be silently
# ignored the way TZ="America/Bogota" can be on a machine without that zone installed.
tzo="${TZ_OFFSET#[+-]}"; tzsign=1; [ "${TZ_OFFSET:0:1}" = "-" ] && tzsign=-1
TZ_OFFSET_SECONDS=$(( tzsign * (10#${tzo%%:*} * 3600 + 10#${tzo##*:} * 60) ))

to_epoch()  { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
to_label()  { date -d "$1 ${TZ_OFFSET}" +%Y%m%d_%H%M%S 2>/dev/null || die "invalid date: '$1'"; }
fmt_local() { date -u -d "@$(( $1 + TZ_OFFSET_SECONDS ))" '+%Y-%m-%d %H:%M:%S'; }   # epoch -> local wall clock
fmt_utc()   { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }                              # epoch -> UTC (what the console shows)

START=$(to_epoch "$2")
END=$(to_epoch "$3")
[ "$START" -lt "$END" ] || die "start time must be before end time"
safe=$(printf '%s' "${LOG_GROUP#/}" | tr -c 'A-Za-z0-9_.\n-' '_')
OUTPUT_FILE="${4:-${safe}_$(to_label "$2")__$(to_label "$3").csv}"

CSV_HEADER='horaprimeratrx,horaultimatrx,rquid,servicio,ValidateServiceInformation,SignatureValidationStep,BodyManipulatorStep,XsdValidationStep,DataBlockExtractorStep,XmlToJsonConverterStep,BackendHttpAdapter,ResponseSigningStep,ResponseBuilderStep'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/raw.ndjson"
: > "$RAW"
echo '[]' > "$TMP/seen_ptrs.json"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION offset=$TZ_OFFSET window=$START..$END out=$OUTPUT_FILE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi
log "Window: $(fmt_local "$START") .. $(fmt_local "$END")  (offset $TZ_OFFSET)  =  $(fmt_utc "$START") .. $(fmt_utc "$END") UTC"

# ---------------------------------------------------------------- aws helpers

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
      *charmap*) log "  hint: encoding problem in the aws cli output; check DEBUG output and PYTHONIOENCODING=$PYTHONIOENCODING" ;;
    esac
  fi
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

# ---------------------------------------------------------------- step 1: raw fetch, no aggregation here

# Same parsing rule as consultaNexusPasoPaso.sh (rquid/servicio/Paso/Tiempo field names kept
# identical on purpose, since downstream tooling may already expect them). Unlike that script,
# there is NO `stats ... by` here: this only fetches raw matching lines, unaggregated.
read -r -d '' QUERY <<'EOF' || true
fields @timestamp, @ptr, @message
| parse @message /\[(?<rquid>[a-f0-9\-]+)\].*\[(?<servicio>\/[^\]]+)\].*\[(?<Paso>[^\[\]]+)\]\[(?<Tiempo>[^\[\]]+)\]$/
| filter ispresent(rquid) and ispresent(Paso) and ispresent(Tiempo) and Tiempo != '-' and Tiempo != 'AuditLog'
| sort @timestamp asc
| limit 10000
EOF

ROWS_JQ='
  .results[] | (map({(.field): .value}) | add)
  | select((.["@ptr"] // "") as $p | $p == "" or ($seen | any(. == $p) | not))
  | {ts: .["@timestamp"], rqid: .rquid, servicio: .servicio, paso: .Paso, tiempo: .Tiempo}'

SEEN_JQ='
  [ .results[] | (map({(.field): .value}) | add)
    | select((.["@timestamp"][0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= ($e - 2))
    | (.["@ptr"] // empty) ]'

# fetch_range <start_epoch> <end_epoch>. Bisects automatically if a window hits MAX_ROWS, so no
# transaction is lost to the cap and no interval size needs to be chosen up front.
fetch_range() {
  local s="$1" e="$2" n mid
  run_query "$s" "$e" > "$TMP/piece.json"
  n=$(jq '.results | length' < "$TMP/piece.json" | tr -d '\r')
  if [ "$n" -ge "$MAX_ROWS" ]; then
    if [ $((e - s)) -gt 1 ]; then
      mid=$(( (s + e) / 2 ))
      log "  $n rows = query limit, splitting: $(fmt_local "$s") | $(fmt_local "$mid") | $(fmt_local "$e")"
      fetch_range "$s" "$mid"
      fetch_range "$mid" "$e"
      return 0
    fi
    log "  WARNING: $n rows within 1 second ($(fmt_local "$s")); rows beyond the limit are lost"
  fi
  jq -c --argjson seen "$(<"$TMP/seen_ptrs.json")" "$ROWS_JQ" < "$TMP/piece.json" | tr -d '\r' >> "$RAW"
  jq -c --argjson e "$e" "$SEEN_JQ" < "$TMP/piece.json" | tr -d '\r' > "$TMP/seen_ptrs.json"
  log "  wrote $n rows ($(awk 'END{print NR}' "$RAW") raw rows so far)"
}

log "Step 1: fetching raw matching lines (auto-splits any window that hits $MAX_ROWS rows)"
fetch_range "$START" "$END"
log "  -> $(awk 'END{print NR}' "$RAW") raw rows collected"

if [ ! -s "$RAW" ]; then
  log "No matching lines in this window. Writing an empty CSV."
  echo "$CSV_HEADER" > "$OUTPUT_FILE"
  exit 0
fi

# ---------------------------------------------------------------- step 2: aggregate ONCE, over everything

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
