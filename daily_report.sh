#!/usr/bin/env bash
# Daily Nexus status report: the KPIs of the NexusGeneral dashboard (API Gateway, adapters, mngr/channel)
# plus the error transactions grouped by (msgRespuesta, channel, nombreOperacion), rendered as plain text
# ready to paste into a chat. All queries are submitted at once and collected afterwards.
# Self-contained on purpose (copy-paste this single file). The log group lists below mirror the SOURCE
# lines of NexusGeneral.json; when the dashboard gains or drops a log group, update them here too.
#
# Usage:  ./daily_report.sh                                   # yesterday 17:00 -> now (Colombia time, UTC-5)
#         ./daily_report.sh "YYYY-MM-DD HH:MM:SS" ["YYYY-MM-DD HH:MM:SS"]   # explicit start [and end]
# Output: results/daily_<start>__<end>/report.txt (also printed to stdout) and one CSV per section
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, DEBUG (0/1/2),
#                    START_TIME   default window start, time of day yesterday (default 17:00)
#                    CHUNK_HOURS  slice size for the per-rqid error query, keeps each slice under the
#                                 10,000-row Insights limit (default 4)
#                    ERROR_PATTERN1, ERROR_PATTERN2   mngr error markers (default Error / ERROR)
#                    thresholds in %, yellow/red: WARN_5XX/CRIT_5XX (1/5), WARN_ADP_ERR/CRIT_ADP_ERR (1/5),
#                                                 WARN_REJECT/CRIT_REJECT (5/10)
#                    CACHE (1 = on [default], 0 = always query AWS), CACHE_DIR (default .daily_report_cache),
#                    CACHE_DAYS   cached results older than this are deleted at startup (default 7)
#
# Cache: every completed query result is stored under CACHE_DIR, keyed by query text + log groups + exact
# window, so editing a query never serves stale rows. A default run ends at "now", so its KPI queries
# never hit; what does: the error slices already closed (aligned to the window start), re-running an
# explicit past window (e.g. after changing thresholds), and retrying a failed run with the command it
# prints. A cached result is the snapshot taken when it was fetched (late-ingested logs are not added).
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
TZ_SECONDS=-18000
FLAT='.results[] | (map({(.field): .value}) | add)'   # Insights row [{field, value}...] -> {field: value}

API_GROUPS=(
  /aws/api/api_accountsws /aws/api/api_acquiringws /aws/api/api_clientsws /aws/api/api_creditcardsws
  /aws/api/api_insurancesws /aws/api/api_investmentsws /aws/api/api_loansws /aws/api/api_paymentsws
  /aws/api/api_productsws /aws/api/api_remittancesws /aws/api/api_securityws
)
ADAPTER_GROUPS=(
  /aws/ecs/srv/accountsws-iseries-adapter /aws/ecs/srv/accountsws-stratus-adapter
  /aws/ecs/srv/acquiringws-stratus-adapter /aws/ecs/srv/clientsws-stratus-adapter
  /aws/ecs/srv/credit-cardsws-iseries-adapter /aws/ecs/srv/credit-cardsws-postilion-adapter
  /aws/ecs/srv/credit-cardsws-stratus-adapter /aws/ecs/srv/insurancesws-stratus-adapter
  /aws/ecs/srv/investmentsws-stratus-adapter /aws/ecs/srv/loansws-stratus-adapter
  /aws/ecs/srv/paymentsws-iseries-adapter /aws/ecs/srv/paymentsws-stratus-adapter
  /aws/ecs/srv/productsws-stratus-adapter /aws/ecs/srv/remittancesws-stratus-adapter
  /aws/ecs/srv/securityws-stratus-adapter
)
MNGR_GROUPS=(
  /aws/ecs/srv/accountsws-mngr /aws/ecs/srv/acquiringws-mngr /aws/ecs/srv/clientsws-mngr
  /aws/ecs/srv/credit-cardsws-mngr /aws/ecs/srv/insurancesws-mngr /aws/ecs/srv/investmentsws-mngr
  /aws/ecs/srv/loansws-mngr /aws/ecs/srv/paymentsws-mngr /aws/ecs/srv/productsws-mngr
  /aws/ecs/srv/remittancesws-mngr /aws/ecs/srv/securityws-mngr
)

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

# "YYYY-MM-DD HH:MM:SS" in Colombia time -> epoch seconds
to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
# cot_fmt <epoch> <date format>  -> that instant formatted in Colombia time, without needing a tz database
cot_fmt()  { date -u -d "@$(($1 + TZ_SECONDS))" "+$2"; }

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
      *charmap*) log "  hint: encoding problem in the aws cli output; check the DEBUG output and PYTHONIOENCODING=$PYTHONIOENCODING" ;;
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
    debug "poll #$polls $qid status=$status matched=$(jq -r '.statistics.recordsMatched // "?"' <<<"$res" | tr -d '\r') scanned=$(jq -r '.statistics.recordsScanned // "?"' <<<"$res" | tr -d '\r')"
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "query $qid ended with status $status" ;;
    esac
    sleep 2
  done
  log "  query $qid complete: $(jq '.results | length' <<<"$res" | tr -d '\r') rows in $((SECONDS - t0))s"
  printf '%s' "$res"
}

OUT_BASE="${OUT_BASE:-results}"
START_TIME="${START_TIME:-17:00}"
CHUNK_HOURS="${CHUNK_HOURS:-4}"
ERROR_PATTERN1="${ERROR_PATTERN1:-Error}"
ERROR_PATTERN2="${ERROR_PATTERN2:-ERROR}"
WARN_5XX="${WARN_5XX:-1}"         CRIT_5XX="${CRIT_5XX:-5}"
WARN_ADP_ERR="${WARN_ADP_ERR:-1}" CRIT_ADP_ERR="${CRIT_ADP_ERR:-5}"
WARN_REJECT="${WARN_REJECT:-5}"   CRIT_REJECT="${CRIT_REJECT:-10}"
CACHE="${CACHE:-1}"
CACHE_DIR="${CACHE_DIR:-.daily_report_cache}"
CACHE_DAYS="${CACHE_DAYS:-7}"

[ $# -le 2 ] || die "usage: $0 [\"YYYY-MM-DD HH:MM:SS\" [\"YYYY-MM-DD HH:MM:SS\"]]  (Colombia time)"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"

# ---------------------------------------------------------------- window

NOW=$(date +%s)
if [ $# -ge 1 ]; then
  START=$(to_epoch "$1")
else
  START=$(to_epoch "$(cot_fmt "$((NOW - 86400))" %F) ${START_TIME}:00")
fi
if [ $# -ge 2 ]; then END=$(to_epoch "$2"); else END=$NOW; fi
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/daily_$(cot_fmt "$START" %Y%m%d_%H%M)__$(cot_fmt "$END" %Y%m%d_%H%M)"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"

declare -A QID=() CACHE_OF=()   # "=()" matters: under set -u a never-assigned array is unbound

# a failure (in submit or collect) must not leave started queries running (and billing) in AWS;
# stopping one that already completed just fails quietly
stop_submitted() {
  local n stopped=0
  for n in "${!QID[@]}"; do
    [ -n "${QID[$n]}" ] || continue   # a failed submit is assigned an empty id
    aws_cli logs stop-query --region "$REGION" --query-id "${QID[$n]}" >/dev/null 2>&1 || true
    stopped=$((stopped + 1))
  done
  if [ "$stopped" -gt 0 ]; then log "  sent stop to $stopped started quer(y/ies)"; fi
}

# on any failure: stop what's running, then print how to retry this exact window reusing the cache
RETRY_CMD="$0 \"$(cot_fmt "$START" '%F %T')\" \"$(cot_fmt "$END" '%F %T')\""
on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] || return 0
  stop_submitted
  if [ "$CACHE" = 1 ]; then log "Retry this same window (completed queries come from the cache): $RETRY_CMD"; fi
}
trap on_exit EXIT

if [ "$CACHE" = 1 ]; then
  mkdir -p "$CACHE_DIR"
  for f in "$CACHE_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ $((NOW - $(date -r "$f" +%s))) -lt $((CACHE_DAYS * 86400)) ] || rm -f "$f"
  done
fi

log "Window $(cot_fmt "$START" '%F %H:%M') -> $(cot_fmt "$END" '%F %H:%M') COT | ${#API_GROUPS[@]} api, ${#ADAPTER_GROUPS[@]} adapter, ${#MNGR_GROUPS[@]} mngr log groups"
debug "region=$REGION out=$OUT_DIR"
if [ "$DEBUG" != 0 ]; then
  debug "$(aws --version 2>&1 | tr -d '\r') | jq $(jq --version | tr -d '\r') | PYTHONIOENCODING=$PYTHONIOENCODING PYTHONUTF8=$PYTHONUTF8"
fi

# ---------------------------------------------------------------- queries (same logic as the General dashboard widgets)

API_BASE='fields @timestamp, @log, resourcePath, responseLatency, status, httpMethod
| filter isPresent(httpMethod) AND isPresent(status)'

ADP_RESP='fields @timestamp, @message, @log
| filter @message like "::AUDIT::RESP::"
| parse @message /::HTTPCODE::(?<codigo>\d+)/
| parse @message /::HTTPCODE::(?<ok>2\d\d)\b/
| parse @message /::HTTPCODE::(?<negocio>412)\b/'

declare -A Q_TEXT Q_KIND Q_RANGE      # Q_RANGE only for queries that don't span the whole window
add_query() { Q_KIND[$1]=$2; Q_TEXT[$1]=$3; }

add_query api_kpi api "$API_BASE
| stats count(*) as total, sum(status >= 200 AND status < 300) as s2xx, sum(status >= 400 AND status < 500) as s4xx,
    sum(status >= 500) as s5xx, pct(responseLatency, 95) as p95"

add_query api_by_api api "$API_BASE
| parse @log /api_(?<API>[A-Za-z0-9-]+)\$/
| stats count(*) as total, sum(status >= 400 and status < 500) as s4xx, sum(status >= 500) as s5xx,
    pct(responseLatency, 95) as p95 by API
| sort s5xx desc, s4xx desc
| limit 100"

add_query adp_kpi adapter "$ADP_RESP
| stats count(*) as total, count(ok) as ok_2xx, count(negocio) as negocio_412"

add_query adp_by_service adapter "$ADP_RESP
| parse @message /X-Name=(?<canal>[^,\]]+)/
| parse @message /X-Referer=[^-,]+-[^-,]+-[^-,]+-(?<servicio>[^-,\]]+)/
| stats count(*) as total, (count(*) - count(ok) - count(negocio)) as error by servicio, canal
| sort error desc
| limit 200"

add_query adp_peak adapter "$ADP_RESP
| filter codigo not like /^2/ and codigo != \"412\"
| stats count(*) as errores by datefloor(@timestamp, 1h) as hora
| sort errores desc
| limit 1"

# errorMsg stops at the first "." on purpose: what follows is raw backend data with customer PII
add_query adp_exceptions adapter 'fields @message
| filter @message like /GenericExceptionMapper/ and @message like /HttpCode::/
| parse @message /Exception:\s*(?<code>\d+)\s*::\s*(?<errorMsg>[^.]*[^.\s])/
| parse @message /3=(?<field>[A-Za-z0-9_.]+)\s*::HEAD::/
| parse @message /X-Referer=[^-,]+-[^-,]+-[^-,]+-(?<service>[^-,\]]+)/
| parse @message /X-Name=(?<channel>[^,\]]+)/
| stats count(*) as total by code, errorMsg, field, service, channel
| sort total desc
| limit 10000'

add_query adp_latency adapter 'fields @timestamp, @message, @logStream, @log
| filter @message like "RSIN"
| parse @message "RSIN *:*,3=*" as adaptador, temp1, rsinadpstratus
| parse @message "RSIN *:*, 1=*" as adaptador1, temp, rsinloaniseris
| parse @log /\/aws\/ecs\/srv\/(?<Adaptador>\S+)$/
| display coalesce(rsinadpstratus, rsinloaniseris) as TiempoAdp, Adaptador
| stats count(*) as calls, pct(TiempoAdp, 95) as p95 by Adaptador
| sort p95 desc
| limit 100'

add_query mngr_reject_pct mngr 'fields @message
| filter @message like "<caracterAceptacion>"
| parse @message /<caracterAceptacion>(?<rechazo>M)<\/caracterAceptacion>/
| stats count(*) as total, count(rechazo) as rejected'

add_query mngr_rejects mngr 'fields @timestamp, @message
| filter @message like /<caracterAceptacion>|<canal>/
| parse @message /\] \[(?<rquid>[a-f0-9\-]{36})\]\[INFO/
| parse @message /<Request>.*<canal>(?<canalReq>[^<]+)<\/canal>/
| parse @message /<Response>.*<nombreOperacion>(?<operacion>[^<]+)<\/nombreOperacion>/
| parse @message /<caracterAceptacion>(?<aceptacion>[^<]+)<\/caracterAceptacion>/
| parse @message /<codMsgRespuesta>(?<codMsg>[^<]+)<\/codMsgRespuesta>/
| parse @message /<msgRespuesta>(?<msg>[^<]+)<\/msgRespuesta>/
| stats latest(canalReq) as canal, latest(operacion) as nombreOperacion, latest(aceptacion) as resultado,
    latest(codMsg) as codMsgRespuesta, latest(msg) as msgRespuesta by rquid
| filter resultado = "M"
| stats count(*) as rejected by canal, nombreOperacion, codMsgRespuesta, msgRespuesta
| sort rejected desc
| limit 100'

# Per-rqid error detail. The channel is the [rqid][channel] tag of the mngr line (same value as the
# adapter X-Name), which replaces summarize_errors.sh's step 2 re-scan. Some lines carry the log level
# in that slot ([rqid][ERROR ...]); those values are discarded when grouping.
Q_ERRORS="fields @timestamp, @message
| filter (@message like '${ERROR_PATTERN1}' or @message like '${ERROR_PATTERN2}')
| parse @message /\[(?<rqid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/
| parse @message /\[[0-9a-f-]{36}\]\[(?<tag>[^\]]*)\]/
| parse @message /<nombreOperacion>(?<op>[^<]+)<\/nombreOperacion>/
| parse @message /<msgRespuesta>(?<msg>[^<]+)<\/msgRespuesta>/
| filter ispresent(rqid)
| fields coalesce(tag, '') as canalTag, coalesce(op, '') as opName, coalesce(msg, '') as msgText
| stats count(*) as lines by rqid, canalTag, opName, msgText
| limit 10000"

ERROR_CHUNKS=()
chunk=$((CHUNK_HOURS * 3600))
for ((s = START, i = 0; s < END; s += chunk, i++)); do
  e=$((s + chunk - 1)); [ "$e" -le "$END" ] || e=$END
  ERROR_CHUNKS+=("errors_$i")
  Q_KIND[errors_$i]=mngr; Q_TEXT[errors_$i]=$Q_ERRORS; Q_RANGE[errors_$i]="$s $e"
done

groups_of() {
  case "$1" in
    api)     printf '%s\n' "${API_GROUPS[@]}" ;;
    adapter) printf '%s\n' "${ADAPTER_GROUPS[@]}" ;;
    mngr)    printf '%s\n' "${MNGR_GROUPS[@]}" ;;
  esac
}

# ---------------------------------------------------------------- submit all, then collect

# cache_file <name> <start> <end>  -> where that query's result for that exact window is cached
cache_file() {
  local key
  key=$({ printf '%s\n' "${Q_TEXT[$1]}"; groups_of "${Q_KIND[$1]}"; } | cksum | cut -d' ' -f1)
  printf '%s/%s_%s_%s.json' "$CACHE_DIR" "$key" "$2" "$3"
}

hits=0
for name in "${!Q_TEXT[@]}"; do
  read -r qs qe <<<"${Q_RANGE[$name]:-$START $END}"
  if [ "$CACHE" = 1 ]; then
    CACHE_OF[$name]=$(cache_file "$name" "$qs" "$qe")
    if [ -s "${CACHE_OF[$name]}" ]; then
      cp "${CACHE_OF[$name]}" "$TMP/$name.json"
      hits=$((hits + 1))
      debug "$name -> cache hit"
      continue
    fi
  fi
  mapfile -t groups < <(groups_of "${Q_KIND[$name]}")
  QID[$name]=$(cw_submit "${Q_TEXT[$name]}" "$qs" "$qe" "${groups[@]}") || die "could not start query '$name'"
  debug "$name -> ${QID[$name]}"
done
log "${#Q_TEXT[@]} queries: $hits from the cache, ${#QID[@]} sent to AWS"

if [ "${#QID[@]}" -gt 0 ]; then log "Collecting results"; fi
for name in "${!QID[@]}"; do
  cw_collect "${QID[$name]}" > "$TMP/$name.json"
  if [ "$CACHE" = 1 ]; then   # write-then-rename: an interrupted copy never leaves a half file behind
    cp "$TMP/$name.json" "${CACHE_OF[$name]}.part" && mv "${CACHE_OF[$name]}.part" "${CACHE_OF[$name]}"
  fi
done

TRUNCATED=0
for name in "${!Q_TEXT[@]}"; do
  rows=$(jq '.results | length' < "$TMP/$name.json" | tr -d '\r')
  if [ "$rows" -ge 10000 ]; then
    TRUNCATED=1
    log "  WARNING: '$name' hit 10,000 rows (truncated). Lower CHUNK_HOURS."
  fi
done

# ---------------------------------------------------------------- CSVs

to_csv() {   # Insights results JSON on stdin -> CSV; header = every field seen (Insights omits null fields)
  jq -r "[$FLAT] | if length == 0 then empty else
           (reduce (.[] | keys_unsorted[]) as \$x ([]; if any(.[]; . == \$x) then . else . + [\$x] end)) as \$k
           | (\$k | @csv), (.[] | [.[\$k[]]] | @csv) end" | tr -d '\r'
}
for name in api_by_api adp_by_service adp_exceptions adp_latency mngr_rejects; do
  to_csv < "$TMP/$name.json" > "$OUT_DIR/$name.csv"
done

# error rqids -> one row per rqid (first non-empty op/msg, first tag that isn't a log level) -> groups
for name in "${ERROR_CHUNKS[@]}"; do jq -c "$FLAT" < "$TMP/$name.json"; done | tr -d '\r' | jq -s '
  group_by(.rqid) | map(
    {rqid: .[0].rqid,
     op:    ([.[].opName   | select(. != "")] | .[0] // ""),
     msg:   ([.[].msgText  | select(. != "")] | .[0] // ""),
     canal: ([.[].canalTag | select(. != "" and (test("^(INFO|ERROR|WARN|WARNING|DEBUG|TRACE|FATAL)\\b") | not))]
             | .[0] // "")})
  | {rqids: length, with_canal: (map(select(.canal != "")) | length),
     groups: (group_by([.msg, .canal, .op]) | sort_by(-length)
              | map({msg: .[0].msg, canal: .[0].canal, op: .[0].op, count: length, rqids: (map(.rqid) | join("|"))}))}
' > "$TMP/errors.json"

jq -r '(["msgrespuesta","canal","nombreoperacion","rqid_count","rqids"] | @csv),
       (.groups[] | [.msg, .canal, .op, .count, .rqids] | @csv)' < "$TMP/errors.json" | tr -d '\r' \
  > "$OUT_DIR/errors_summary.csv"

# ---------------------------------------------------------------- report

peak_utc=$(jq -r "[$FLAT] | .[0].hora // empty" < "$TMP/adp_peak.json" | tr -d '\r')
peak_label=""
[ -z "$peak_utc" ] || peak_label=$(cot_fmt "$(date -u -d "${peak_utc%.*} UTC" +%s)" '%d/%m %H:00')

{
  for name in api_kpi api_by_api adp_kpi adp_by_service adp_peak adp_exceptions adp_latency mngr_reject_pct mngr_rejects; do
    jq -c --arg n "$name" "{(\$n): [$FLAT]}" < "$TMP/$name.json"
  done
  jq -c '{errors: .}' < "$TMP/errors.json"
  jq -n -c \
    --arg from "$(cot_fmt "$START" '%d/%m %H:%M')" --arg to "$(cot_fmt "$END" '%d/%m %H:%M')" \
    --arg peak "$peak_label" --argjson truncated "$TRUNCATED" \
    --argjson w5 "$WARN_5XX" --argjson c5 "$CRIT_5XX" \
    --argjson wa "$WARN_ADP_ERR" --argjson ca "$CRIT_ADP_ERR" \
    --argjson wr "$WARN_REJECT" --argjson cr "$CRIT_REJECT" \
    '{meta: {$from, $to, $peak, $truncated, th: {$w5, $c5, $wa, $ca, $wr, $cr}}}'
} | tr -d '\r' | jq -s -r 'add | . as $d
  | def num: (. // 0) | tonumber;
    def fmt: (num | round | tostring) as $s | ($s | length) as $n     # 1234567 -> "1.234.567" (es-CO)
      | [range(0; $n) | $s[.:. + 1] + (if ($n - . - 1) > 0 and (($n - . - 1) % 3) == 0 then "." else "" end)] | join("");
    def pct(a; b): if b > 0 then (a * 1000 / b | round) / 10 else 0 end;
    def pc: tostring | sub("\\."; ",");                                 # 97.2 -> "97,2" (es-CO)
    def light(v; w; c): if v >= c then "🔴" elif v >= w then "🟡" else "🟢" end;
    def cut(n): (. // "") | if length > n then .[0:n - 1] + "…" else . end;
    def orNone: if length == 0 then ["ninguno"] else . end;

    ($d.meta.th) as $th
  | ($d.api_kpi[0] // {}) as $a | ($a.total | num) as $at
  | pct($a.s5xx | num; $at) as $p5
  | ($d.adp_kpi[0] // {}) as $r | ($r.total | num) as $rt
  | (($rt - ($r.ok_2xx | num) - ($r.negocio_412 | num))) as $rerr | pct($rerr; $rt) as $pe
  | ($d.mngr_reject_pct[0] // {}) as $m | pct($m.rejected | num; $m.total | num) as $pm
  | [light($p5; $th.w5; $th.c5), light($pe; $th.wa; $th.ca), light($pm; $th.wr; $th.cr)] as $lights
  | (if any($lights[]; . == "🔴") then "🔴" elif any($lights[]; . == "🟡") then "🟡" else "🟢" end) as $overall
  | ($d.adp_exceptions | map(select(.code == "504"))) as $timeouts
  | ($d.adp_exceptions | map(select(.code != "504"))) as $mapping
  | $d.errors as $e
  | [
    "📊 Estado diario Nexus \($overall)",
    "🕔 \($d.meta.from) → \($d.meta.to) (hora Colombia)",
    "",
    "🌐 API Gateway \($lights[0])",
    "• \($at | fmt) peticiones | 2xx \(pct($a.s2xx | num; $at) | pc)% | 4xx \(pct($a.s4xx | num; $at) | pc)% | 5xx \($p5 | pc)% | p95 \($a.p95 | fmt) ms",
    "• Más errores: " + ([$d.api_by_api[] | select((.s4xx | num) + (.s5xx | num) > 0)][0:3]
        | map("\(.API) 5xx \(.s5xx | fmt) / 4xx \(.s4xx | fmt) de \(.total | fmt)") | orNone | join(" · ")),
    "",
    "🔌 Adaptadores \($lights[1])",
    "• \($rt | fmt) respuestas | OK \(pct($r.ok_2xx | num; $rt) | pc)% | 412 negocio \(pct($r.negocio_412 | num; $rt) | pc)% | error \($pe | pc)%",
    "• Más errores: " + ([$d.adp_by_service[] | select((.error | num) > 0)][0:3]
        | map("\(.servicio // "-")/\(.canal // "-") \(.error | fmt)") | orNone | join(" · ")),
    "• Timeouts 504: \([$timeouts[].total | num] | add // 0 | fmt)" + (if ($timeouts | length) > 0 then " — principales: " +
        ($timeouts | group_by([.service, .channel]) | map({k: "\(.[0].service // "-")/\(.[0].channel // "-")", n: ([.[].total | num] | add)})
         | sort_by(-.n) | .[0:3] | map("\(.k) (\(.n | fmt))") | join(" · ")) else "" end),
    "• Errores de mapeo: \([$mapping[].total | num] | add // 0 | fmt)" + (if ($mapping | length) > 0 then " — principales: " +
        ($mapping[0:3] | map("\(.code) \(.errorMsg | cut(50)) [\(.field // "-")] \(.service // "-")/\(.channel // "-") (\(.total | fmt))") | join(" · ")) else "" end),
    "• p95 más lento: " + ($d.adp_latency[0:3] | map("\(.Adaptador) \(.p95 | fmt) ms") | orNone | join(" · ")),
    "• Hora pico de errores: " + (if $d.meta.peak == "" then "ninguna" else "\($d.meta.peak) (\($d.adp_peak[0].errores | fmt) errores)" end),
    "",
    "📡 Canal (mngr) \($lights[2])",
    "• Rechazos (M): \($pm | pc)% de \($m.total | fmt) respuestas",
    "• Principales rechazos: " + ($d.mngr_rejects[0:3]
        | map("\(.nombreOperacion // "-") · \(.msgRespuesta // "-" | cut(50)) · canal \(.canal // "-") (\(.rejected | fmt))") | orNone | join(" | ")),
    "• Transacciones con error: \($e.rqids | fmt) rqids en \($e.groups | length) grupos (canal identificado en \($e.with_canal | fmt))"
  ]
  + ($e.groups[0:5] | to_entries | map("  \(.key + 1). \(.value.msg | if . == "" then "(sin msgRespuesta)" else cut(60) end) | canal \(.value.canal | if . == "" then "?" else . end) | \(.value.op | if . == "" then "-" else . end) — \(.value.count | fmt)"))
  + (if $d.meta.truncated == 1 then ["", "⚠️ Algunas consultas llegaron al límite de 10.000 filas; los conteos pueden quedar cortos (bajá CHUNK_HOURS)."] else [] end)
  | .[]' | tr -d '\r' > "$OUT_DIR/report.txt"

log "Done -> $OUT_DIR/report.txt"
echo
cat "$OUT_DIR/report.txt"
