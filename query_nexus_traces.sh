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
# Windows are fetched in parallel (PARALLEL below), not one at a time: each Logs Insights query
# spends most of its wall-clock time waiting on AWS (start + poll every 2s), not on local work, so
# running several at once is the biggest speed lever here — much bigger than how the splitting
# itself works. A window too big to fetch in one query is only discovered by querying it, so a
# "probe" and a "real fetch" are the same job: it either yields final rows, or two new (smaller)
# windows to queue. Because jobs finish in no particular order, boundary duplicates (Insights
# ranges are inclusive on both ends) can no longer be filtered with the old "remember the previous
# chunk's tail" trick — instead every row keeps its @ptr and gets de-duplicated exactly, once, over
# the whole collected dataset (simpler and more exact than the old 2-second-window heuristic).
#
# Every window is cached to disk under CACHE_DIR (keyed by log group + the exact query text + that
# window's start/end), and this survives across runs (unlike the temp dir, which is always cleaned
# up) — BOTH kinds of window get cached, not just the ones with final data: a "leaf" that returned
# rows under the cap, AND a window that overflowed and had to be split (recorded as a marker, since
# the split point is always the same deterministic midpoint). Caching the split decision too is
# what makes a re-run actually cheap: caching leaves alone would still force re-walking and
# re-probing the ENTIRE tree of "did this overflow?" queries from the top on every retry, even with
# every leaf's data already sitting on disk — for a wide, busy range that walk alone can be many
# minutes of AWS calls before a single cache hit is even reached. With both cached, a full re-run
# after everything was already discovered replays the whole tree from local files, no AWS calls at
# all. If AWS throws a transient error partway through a fetch — more likely now that several
# queries run at once — the script retries a few times with backoff before giving up, and only
# re-fetches whatever wasn't already cached when it's run again. If the script does die, any OTHER
# windows still being fetched in the background are killed outright (not left running as orphans
# that fail later, confusingly, once the temp dir they were writing into is already gone).
#
# Usage:  ./query_nexus_traces.sh <log-group> "<start>" "<end>" [output.csv]
#         (start/end are local time, offset TZ_OFFSET below; default -05:00 = Bogota)
#
# BREAKING CHANGE vs consultaNexusPasoPaso.sh: there is no more $4 interval-minutes argument
# (chunking is automatic now) — the old $5 output file is $4 here.
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, TZ_OFFSET (default -05:00; use +00:00 to type UTC times, e.g.
#                    copied straight from the CloudWatch console), PARALLEL (default 6 — concurrent
#                    Insights queries; AWS's account-wide cap is 100 as of March 2026, shared with
#                    dashboards and scheduled queries, so this defaults well under it), CACHE_DIR
#                    (default .query_nexus_cache — delete it to force a full re-fetch, or point it
#                    elsewhere; it grows unbounded, nothing prunes it), DEBUG (0 = quiet, 1 = verbose
#                    [default], 2 = also set -x)
set -euo pipefail
set -m   # job control on: each backgrounded query gets its own process group, so a killed job's
         # own children (the aws process itself, and anything it spawns) die with it — see trap below

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

PARALLEL="${PARALLEL:-6}"
TMP=$(mktemp -d)
# On ANY exit (success, die, Ctrl-C) kill whatever background queries are still running before
# removing $TMP. Without this, a job still in flight when the script dies keeps running orphaned,
# and its next write into $TMP fails ("No such file or directory") since it's already gone by
# then — that stray failure, printed after the shell prompt has already come back, is what makes
# a real error look like two confusing, unrelated ones.
trap 'for _p in $(jobs -p); do kill -- "-$_p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
RAW="$TMP/raw.ndjson"          # final, de-duplicated dataset (step 1's output, step 2's input)
JOBDIR="$TMP/jobs"; mkdir -p "$JOBDIR"

# Local cache of already-fetched leaf windows, keyed by log group + the exact query text (so
# editing the parsing rule can't silently serve stale rows) + the window's own start/end. Survives
# across runs (unlike $TMP): if the script dies partway (AWS hiccup, Ctrl-C, power loss), re-running
# the exact same command skips every window already fetched instead of re-downloading everything.
CACHE_DIR="${CACHE_DIR:-.query_nexus_cache}"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION offset=$TZ_OFFSET window=$START..$END out=$OUTPUT_FILE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi
log "Window: $(fmt_local "$START") .. $(fmt_local "$END")  (offset $TZ_OFFSET)  =  $(fmt_utc "$START") .. $(fmt_utc "$END") UTC"

# ---------------------------------------------------------------- aws helpers

# Every AWS call goes through here so --no-verify-ssl is always applied.
# stderr is captured: urllib3 warning noise is dropped, real errors are shown and also
# appended to $TMP/aws_errors.log. stdout passes through untouched.
# Transient AWS errors (ServiceUnavailableException, throttling, ...) are retried with backoff:
# running several queries at once makes these noticeably more common than one-at-a-time ever did,
# and the AWS CLI's own built-in retrying ("reached max retries: 2" in the error text) is not
# enough on its own to ride out a burst of them.
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

CACHE_KEY_DIR="$CACHE_DIR/$(printf '%s' "${LOG_GROUP#/}" | tr -c 'A-Za-z0-9_.\n-' '_')/$(printf '%s' "$QUERY" | cksum | cut -d' ' -f1)"
mkdir -p "$CACHE_KEY_DIR"
debug "cache: $CACHE_KEY_DIR"

# Reads piece.json on stdin (never as a path argument to jq): with MSYS_NO_PATHCONV=1 (needed for
# the log group names above), a native jq.exe can't resolve a bare Unix path passed as an argument.
# Keeps @ptr so duplicate boundary rows can be removed later, in one exact global pass (see below).
ROWS_JQ='
  .results[] | (map({(.field): .value}) | add)
  | {ts: .["@timestamp"], ptr: (.["@ptr"] // null),
     rqid: .rquid, servicio: .servicio, paso: .Paso, tiempo: .Tiempo}'

# ---- bounded-concurrency work queue --------------------------------------------------------
# A window too big to fetch in one query (>= MAX_ROWS) is only discovered by querying it, so a
# "probe" and a "real fetch" are the same job: on completion it either writes final rows, or
# queues two new (smaller) windows. Up to PARALLEL jobs run at once.
QUEUE=("$START:$END")
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
    return 0   # doesn't touch INFLIGHT/PARALLEL at all, it's instant
  fi
  if [ -f "$split_file" ]; then
    # this window is already KNOWN (from a previous run) to overflow — split is deterministic
    # (same s,e -> same mid always), so re-probing it would just waste an AWS call to re-learn
    # what's already on disk. Queue its two children directly instead.
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
  wait -n || true   # a failing job's own exit status must not trip `set -e` here; handled below
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
      : > "$CACHE_KEY_DIR/${s}_${e}.split"   # remember: this window overflows, don't re-probe it later
      QUEUE+=("$s:$mid" "$mid:$e")
    else
      [ "$n" -lt "$MAX_ROWS" ] || log "  WARNING: $n rows within 1 second ($(fmt_local "$s")); rows beyond the limit are lost"
      # tee also writes the cache file for this exact window (fresh — a cache hit above always
      # skips getting here for the same s:e), so a later re-run can skip it entirely.
      jq -c "$ROWS_JQ" < "$piece" | tr -d '\r' | tee -a "$RAW.dup" > "$CACHE_KEY_DIR/${s}_${e}.ndjson"
      log "  wrote $n rows ($(fmt_local "$s") .. $(fmt_local "$e"))"
    fi
    rm -f "$piece"
  done
done

if [ ! -s "$RAW.dup" ]; then
  log "No matching lines in this window. Writing an empty CSV."
  echo "$CSV_HEADER" > "$OUTPUT_FILE"
  exit 0
fi

# Parallel jobs have no ordering, so boundary duplicates (Insights ranges are inclusive on both
# ends) are removed here, once, exactly, by @ptr — instead of during collection.
jq -s -c 'unique_by(.ptr) | .[]' < "$RAW.dup" | tr -d '\r' > "$RAW"
log "  -> $(awk 'END{print NR}' "$RAW.dup") rows fetched, $(awk 'END{print NR}' "$RAW") unique after de-duplicating boundary overlaps"

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
