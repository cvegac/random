#!/usr/bin/env bash
# Queries CloudWatch Logs Insights for ESB step-timing traces and aggregates them into one row
# per transaction (rquid + servicio), with all 9 pipeline step times as columns. Replaces
# consultaNexusPasoPaso.sh — fixed its TZ, 10k-row-cap, and chunk-boundary bugs (see git log).
#
# No chunk size to pick: starts with the whole range in one query and only splits a window when it
# hits the 10,000-row cap. Windows are fetched in parallel and cached to disk, so a re-run after a
# crash or AWS hiccup only fetches what's still missing (details inline near the relevant code).
#
# Usage:  ./query_nexus_traces.sh <log-group> "<start>" "<end>" [output.csv]
#         (start/end are local time, offset TZ_OFFSET below; default -05:00 = Bogota)
# Arg order differs from consultaNexusPasoPaso.sh: no more $4 interval-minutes, $4 is output file.
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, TZ_OFFSET (default -05:00; +00:00 for UTC input), PARALLEL
#                    (default 6; AWS's account-wide concurrent-query cap is 100), CACHE_DIR
#                    (default .query_nexus_cache; grows unbounded, nothing prunes it), BAR_WIDTH
#                    (default 50), PROGRESS_STEP (default 1), DEBUG (0/1/2, default 1)
set -euo pipefail
set -m   # each backgrounded query gets its own process group, so `kill -- -$pid` (see trap below)
         # takes its children down too — plain `kill $pid` does not

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # stop Git Bash rewriting "/aws/ecs/..." as a path
export PYTHONWARNINGS="ignore:Unverified HTTPS request"   # silence urllib3's --no-verify-ssl warning
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # aws cli's bundled Python defaults to cp1252 on Windows
                                              # and crashes on log lines it can't map to that charset

DEBUG="${DEBUG:-1}"
[ "$DEBUG" != 2 ] || { export PS4='+ ${LINENO}: '; set -x; }

REGION="${AWS_REGION:-us-east-1}"
MAX_ROWS=10000                    # Logs Insights hard cap; keep in sync with "| limit 10000" in QUERY
TZ_OFFSET="${TZ_OFFSET:--05:00}"  # Bogota, no DST

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <log-group> \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\" [output.csv]  (local time, offset ${TZ_OFFSET})"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
[[ "$TZ_OFFSET" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "TZ_OFFSET must look like -05:00 or +00:00 (got '$TZ_OFFSET')"

LOG_GROUP="$1"

# Arithmetic offset, not TZ="America/Bogota": needs no zoneinfo database, so it can't be silently
# ignored on a machine that doesn't have that zone installed (bit us once — see git log).
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
# Kill any query still in flight before removing $TMP, on any exit. Otherwise an orphaned job
# writes into $TMP after it's gone ("No such file or directory"), long after the real error above it.
trap 'for _p in $(jobs -p); do kill -- "-$_p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
RAW="$TMP/raw.ndjson"          # final, de-duplicated dataset (step 1's output, step 2's input)
JOBDIR="$TMP/jobs"; mkdir -p "$JOBDIR"

# ---- coverage progress bar -------------------------------------------------------------------
# Shows WHICH parts of the range are already fetched, not just an overall %: eighth-of-a-character
# blocks give enough resolution that a lone 10-minute leaf inside a 24h request still shows up.
# Plain new log lines, no \r redraw / ANSI cursor movement — kept simple and portable.
BAR_WIDTH="${BAR_WIDTH:-50}"
PROGRESS_STEP="${PROGRESS_STEP:-1}"   # only reprint once coverage advances by this many points
TOTAL_SECONDS=$((END - START))
COVERED_FILE="$TMP/covered.tsv"
: > "$COVERED_FILE"
LAST_PROGRESS_PCT=-100
BLOCKS=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')

fmt_hms() { local s="$1"; printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); }

# Records a resolved leaf window (fresh fetch or cache hit); reprints the bar once coverage has
# advanced by at least PROGRESS_STEP points since the last time.
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

# Cache dir survives across runs (unlike $TMP), keyed below by log group + exact query text +
# window start/end, so editing the parsing rule can't serve stale rows from an old cache.
CACHE_DIR="${CACHE_DIR:-.query_nexus_cache}"

if [ "$DEBUG" != 0 ]; then
  debug "region=$REGION offset=$TZ_OFFSET window=$START..$END out=$OUTPUT_FILE"
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi
log "Window: $(fmt_local "$START") .. $(fmt_local "$END")  (offset $TZ_OFFSET)  =  $(fmt_utc "$START") .. $(fmt_utc "$END") UTC"

# ---------------------------------------------------------------- aws helpers

# Every AWS call goes through here: applies --no-verify-ssl, strips urllib3 warning noise from
# stderr (real errors still print and log to $TMP/aws_errors.log), and retries transient errors
# (ServiceUnavailableException, throttling...) with backoff — more common now that several queries
# run at once, and the CLI's own retrying ("reached max retries: 2") isn't enough on its own.
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

# Same parsing rule as consultaNexusPasoPaso.sh (field names kept for downstream compatibility),
# but no `stats ... by` here — this only fetches raw matching lines, aggregated once in step 2.
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

# Reads piece.json on stdin, never as a jq path argument (MSYS_NO_PATHCONV=1 breaks that for a
# native jq.exe). Keeps @ptr so duplicate boundary rows can be de-duplicated later, in one pass.
ROWS_JQ='
  .results[] | (map({(.field): .value}) | add)
  | {ts: .["@timestamp"], ptr: (.["@ptr"] // null),
     rqid: .rquid, servicio: .servicio, paso: .Paso, tiempo: .Tiempo}'

# ---- upfront cache inventory: consume whatever's already known before touching AWS at all ----
# Walks the same tree shape through local cache files only (zero AWS calls): a cached leaf feeds
# its data into the dataset and the bar; a cached split recurses into its children; anything not
# cached yet is left in $QUEUE for the real fetch loop below.
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
  QUEUE+=("$s:$e")   # not cached (yet) -> genuinely needs a live AWS call
}

log "Checking the local cache before fetching anything from AWS..."
QUEUE=()
scan_cache "$START" "$END"
if [ "$LAST_PROGRESS_PCT" = "-100" ]; then
  log "  nothing usable cached yet for this exact range"
elif awk -v p="$LAST_PROGRESS_PCT" 'BEGIN{exit !(p>=99.95)}'; then
  log "  already have the full range cached from a previous run — nothing to fetch"
else
  log "  already have ${LAST_PROGRESS_PCT}% cached from a previous run — fetching the rest now"
fi

# ---- bounded-concurrency work queue --------------------------------------------------------
# A window too big for one query (>= MAX_ROWS) is only discovered by querying it, so "probe" and
# "real fetch" are the same job: it either writes final rows or queues two smaller windows.
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
    return 0   # doesn't touch INFLIGHT/PARALLEL at all, it's instant
  fi
  if [ -f "$split_file" ]; then
    # known to overflow from a previous run (split point is deterministic) -> queue its children
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
      : > "$CACHE_KEY_DIR/${s}_${e}.split"   # remember: overflows, don't re-probe it next time
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
# force one final render, unless the last real leaf already landed on ~100% on its own
awk -v p="$LAST_PROGRESS_PCT" 'BEGIN{exit !(p<99.95)}' && PROGRESS_STEP=0 mark_covered "$START" "$START"

if [ ! -s "$RAW.dup" ]; then
  log "No matching lines in this window. Writing an empty CSV."
  echo "$CSV_HEADER" > "$OUTPUT_FILE"
  exit 0
fi

# boundary duplicates (Insights ranges are inclusive on both ends) removed once, exactly, by @ptr
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
