#!/usr/bin/env bash
# Daily Nexus status report from Dynatrace (Grail) as plain text for the team chat: adapter KPIs, top 5
# services by error % with their channels and main errors, error % per service, backend latency per
# adapter, mapping errors, 504 timeouts and other technical errors.
# Same report as cloudwatch/scripts/daily_report.sh, without the API Gateway (its logs are not in Dynatrace).
# Counts come from the custom.nexus.log.* ingest metrics; error detail from the bck-nexus-error-log bucket.
#
# Usage: ./daily_report.sh                yesterday 17:00 -> today 08:00 (Colombia time, UTC-5)
#        ./daily_report.sh -w             on Monday: Friday 17:00 -> today 08:00
#        ./daily_report.sh -wl            on Tuesday after a Monday holiday: Friday 17:00 -> today 08:00
#        ./daily_report.sh "<start>" ["<end>"]
# Output: results/dt_daily_<start>__<end>/report.txt (also printed) and one CSV per section
#
# Auth (one of the two), with scopes storage:logs:read storage:metrics:read storage:buckets:read:
#   DT_TOKEN                                         platform token (dt0s16...)
#   DT_CLIENT_ID, DT_CLIENT_SECRET, DT_ACCOUNT_URN   OAuth client (urn:dtaccount:<uuid>)
# Env: DT_ENV_URL (https://<environment>.apps.dynatrace.com), DT_INSECURE (0; 1 = skip TLS verification),
#      OUT_BASE, DEBUG (0/1), START_TIME (17:00), END_TIME (08:00), WARN_ADP_ERR/CRIT_ADP_ERR (5/10),
#      TOP_MIN_RESPONSES (50), CACHE (1), CACHE_DIR (.daily_report_cache), CACHE_DAYS (7)
# Results are cached per query + window, so running it again for the same window makes no Dynatrace calls.
set -euo pipefail
shopt -s inherit_errexit   # a failed call inside $(...) stops the script too

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: keep arguments as they are

DEBUG="${DEBUG:-1}"
TZ_OFFSET="-05:00"                       # Colombia (no DST)
TZ_SECONDS=-18000
MAX_ROWS=10000
SSO_URL="https://sso.dynatrace.com/sso/oauth2/token"
SCOPES="storage:logs:read storage:metrics:read storage:buckets:read"

log()   { echo "[$(date +%H:%M:%S)] $*" >&2; }
debug() { if [ "$DEBUG" != 0 ]; then log "DEBUG: $*"; fi; }
die()   { echo "Error: $*" >&2; exit 1; }

to_epoch() { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "invalid date: '$1'"; }
# cot_fmt <epoch> <format>: Colombia time without needing a tz database
cot_fmt()  { date -u -d "@$(($1 + TZ_SECONDS))" "+$2"; }
iso_utc()  { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

OUT_BASE="${OUT_BASE:-results}"
START_TIME="${START_TIME:-17:00}"
END_TIME="${END_TIME:-08:00}"
WARN_ADP_ERR="${WARN_ADP_ERR:-5}" CRIT_ADP_ERR="${CRIT_ADP_ERR:-10}"
TOP_MIN_RESPONSES="${TOP_MIN_RESPONSES:-50}"
CACHE="${CACHE:-1}"
CACHE_DIR="${CACHE_DIR:-.daily_report_cache}"
CACHE_DAYS="${CACHE_DAYS:-7}"
DT_INSECURE="${DT_INSECURE:-0}"
DT_ENV_URL="${DT_ENV_URL:-}"
DT_ENV_URL="${DT_ENV_URL%/}"

# -w / -wl start the window on Friday instead of yesterday
DAYS_BACK=1 MODE=""
case "${1:-}" in
  -w)  DAYS_BACK=3 MODE="-w (fin de semana)"; shift ;;
  -wl) DAYS_BACK=4 MODE="-wl (fin de semana con lunes festivo)"; shift ;;
esac
[ -z "$MODE" ] || [ $# -eq 0 ] || die "-w / -wl can't be combined with explicit dates"
[ $# -le 2 ] || die "usage: $0 [-w | -wl | \"YYYY-MM-DD HH:MM:SS\" [\"YYYY-MM-DD HH:MM:SS\"]]  (Colombia time)"
command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# ---------------------------------------------------------------- window

NOW=$(date +%s)
if [ $# -ge 1 ]; then
  START=$(to_epoch "$1")
else
  START=$(to_epoch "$(cot_fmt "$((NOW - DAYS_BACK * 86400))" %F) ${START_TIME}:00")
fi
if [ -n "$MODE" ] && [ "$(cot_fmt "$START" %u)" != 5 ]; then   # %u: 5 = Friday
  log "WARNING: $MODE starts on $(cot_fmt "$START" '%A %F'), not a Friday (-w is meant for Monday, -wl for Tuesday)"
fi
if [ $# -ge 2 ]; then
  END=$(to_epoch "$2")
elif [ $# -eq 1 ]; then
  END=$NOW
else
  END=$(to_epoch "$(cot_fmt "$NOW" %F) ${END_TIME}:00")
  [ "$END" -le "$NOW" ] || END=$NOW   # before END_TIME the window ends now
fi
[ "$START" -lt "$END" ] || die "start time must be before end time"

OUT_DIR="${OUT_BASE}/dt_daily_$(cot_fmt "$START" %Y%m%d_%H%M)__$(cot_fmt "$END" %Y%m%d_%H%M)"
TMP="${OUT_DIR}/_intermediate"
mkdir -p "$TMP"
AUTH_HEADER="$TMP/.auth_header"   # the token goes to curl in a file, never on the command line

declare -A TOKEN=() CACHE_OF=()   # =() is needed under set -u

# ---------------------------------------------------------------- Dynatrace API

# dt_curl <method> <url> [json body] -> response body; dies on HTTP errors with Dynatrace's message
dt_curl() {
  local method="$1" url="$2" body="${3:-}" out code rc=0 msg
  local args=(-sS -X "$method" -H @"$AUTH_HEADER" -H "Accept: application/json" -w '%{http_code}')
  [ "$DT_INSECURE" != 1 ] || args+=(-k)
  [ -z "$body" ] || args+=(-H "Content-Type: application/json" --data-binary @-)
  out="$TMP/.response"
  code=$(printf '%s' "$body" | curl "${args[@]}" -o "$out" "$url") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      60|35) die "TLS error talking to Dynatrace (curl exit $rc); behind a proxy that inspects TLS, run with DT_INSECURE=1" ;;
      *)     die "curl failed (exit $rc) on $method $url" ;;
    esac
  fi
  if [ "$code" -ge 400 ]; then
    msg=$(jq -r '[.error.message, .error.details.errorMessage] | map(select(. != null)) | join(": ")' < "$out" 2>/dev/null | tr -d '\r')
    case "$code" in
      401) die "HTTP 401: the token is invalid or expired ($msg)" ;;
      403) die "HTTP 403: the token lacks a scope ($SCOPES) or the bucket permission ($msg)" ;;
      *)   die "HTTP $code from Dynatrace: ${msg:-$(head -c 500 "$out")}" ;;
    esac
  fi
  tr -d '\r' < "$out"
}

authenticate() {
  [ -n "$DT_ENV_URL" ] || die "set DT_ENV_URL (https://<environment>.apps.dynatrace.com)"
  case "$DT_ENV_URL" in
    *.apps.dynatrace.com*) ;;
    *) log "WARNING: DT_ENV_URL should be the platform URL (https://<environment>.apps.dynatrace.com)" ;;
  esac
  local token
  ( umask 077; : > "$AUTH_HEADER" )
  if [ -n "${DT_TOKEN:-}" ]; then
    token="$DT_TOKEN"
    debug "auth: platform token"
  elif [ -n "${DT_CLIENT_ID:-}" ] && [ -n "${DT_CLIENT_SECRET:-}" ] && [ -n "${DT_ACCOUNT_URN:-}" ]; then
    debug "auth: OAuth client $DT_CLIENT_ID"
    local args=(-sS -X POST "$SSO_URL" --data-urlencode "grant_type=client_credentials"
                --data-urlencode "client_id=$DT_CLIENT_ID" --data-urlencode "client_secret=$DT_CLIENT_SECRET"
                --data-urlencode "scope=$SCOPES" --data-urlencode "resource=$DT_ACCOUNT_URN")
    [ "$DT_INSECURE" != 1 ] || args+=(-k)
    token=$(curl "${args[@]}" | tr -d '\r' | jq -r '.access_token // empty') || true
    [ -n "$token" ] || die "could not get an OAuth token from $SSO_URL (check client id, secret, account URN and scopes)"
  else
    die "set DT_TOKEN, or DT_CLIENT_ID + DT_CLIENT_SECRET + DT_ACCOUNT_URN"
  fi
  printf 'Authorization: Bearer %s\n' "$token" > "$AUTH_HEADER"
}

QUERY_API="$DT_ENV_URL/platform/storage/query/v1"

# dt_submit <query> -> request token, or "done:<file>" when Dynatrace answered right away
dt_submit() {
  local body res state
  body=$(jq -n -c --arg q "$1" --arg s "$(iso_utc "$START")" --arg e "$(iso_utc "$END")" --argjson max "$MAX_ROWS" \
    '{query: $q, defaultTimeframeStart: $s, defaultTimeframeEnd: $e, timezone: "UTC", locale: "en_US",
      maxResultRecords: $max, requestTimeoutMilliseconds: 1000}')
  res=$(dt_curl POST "$QUERY_API/query:execute" "$body")
  state=$(jq -r .state <<<"$res")
  case "$state" in
    SUCCEEDED) jq -c '{records: .result.records}' <<<"$res" > "$TMP/.done"; printf 'done' ;;
    RUNNING|NOT_STARTED) jq -r .requestToken <<<"$res" ;;
    *) die "query rejected with state $state: $(jq -c . <<<"$res" | head -c 500)" ;;
  esac
}

# dt_collect <request token> -> {records: [...]}
dt_collect() {
  local token="$1" res state polls=0 t0=$SECONDS enc
  enc=$(jq -rn --arg t "$token" '$t | @uri')
  while :; do
    polls=$((polls + 1))
    res=$(dt_curl GET "$QUERY_API/query:poll?request-token=$enc&request-timeout-milliseconds=30000")
    state=$(jq -r .state <<<"$res")
    debug "poll #$polls state=$state progress=$(jq -r '.progress // "?"' <<<"$res")"
    case "$state" in
      SUCCEEDED) break ;;
      RUNNING|NOT_STARTED) ;;
      *) die "query ended with state $state: $(jq -c '.error // .' <<<"$res" | head -c 500)" ;;
    esac
  done
  log "  query complete: $(jq '.result.records | length' <<<"$res") rows in $((SECONDS - t0))s"
  jq -c '{records: .result.records}' <<<"$res"
}

# don't leave queries running (and billing) in Grail after a failure
cancel_running() {
  local n enc cancelled=0
  for n in "${!TOKEN[@]}"; do
    [ -n "${TOKEN[$n]}" ] && [ "${TOKEN[$n]}" != done ] || continue
    enc=$(jq -rn --arg t "${TOKEN[$n]}" '$t | @uri')
    curl -sS -X POST -H @"$AUTH_HEADER" $([ "$DT_INSECURE" != 1 ] || echo -k) \
      "$QUERY_API/query:cancel?request-token=$enc" -o /dev/null 2>/dev/null || true
    cancelled=$((cancelled + 1))
  done
  if [ "$cancelled" -gt 0 ]; then log "  sent cancel to $cancelled quer(y/ies)"; fi
}

RETRY_CMD="$0 \"$(cot_fmt "$START" '%F %T')\" \"$(cot_fmt "$END" '%F %T')\""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -s "$AUTH_HEADER" ]; then cancel_running; fi
  rm -f "$AUTH_HEADER" "$TMP/.response" "$TMP/.done"
  if [ "$rc" -ne 0 ] && [ "$CACHE" = 1 ]; then log "Retry this same window (completed queries come from the cache): $RETRY_CMD"; fi
}
trap on_exit EXIT

if [ "$CACHE" = 1 ]; then
  mkdir -p "$CACHE_DIR"
  for f in "$CACHE_DIR"/dt_*.json; do
    [ -e "$f" ] || continue
    [ $((NOW - $(date -r "$f" +%s))) -lt $((CACHE_DAYS * 86400)) ] || rm -f "$f"
  done
fi

log "Window $(cot_fmt "$START" '%F %H:%M') -> $(cot_fmt "$END" '%F %H:%M') COT${MODE:+ [$MODE]}"
debug "environment=$DT_ENV_URL out=$OUT_DIR | $(curl --version | head -1 | tr -d '\r') | jq $(jq --version | tr -d '\r')"

# ---------------------------------------------------------------- queries

ERRORS_BUCKET='dt.system.bucket == "bck-nexus-error-log"'

declare -A Q_TEXT
add_query() { Q_TEXT[$1]=$2; }

# outcome: ok_2xx, business_412, error (a code that is neither 2xx nor 412), unknown (no code parsed)
add_query adp_kpi "$(cat <<'EOF'
timeseries r = sum(custom.nexus.log.adapter.responses, default: 0), by: { outcome }
| fieldsAdd n = arraySum(r)
| summarize total = sum(n), ok_2xx = sum(if(outcome == "ok_2xx", n, else: 0)),
    business_412 = sum(if(outcome == "business_412", n, else: 0)), error = sum(if(outcome == "error", n, else: 0))
EOF
)"

add_query adp_by_service "$(cat <<'EOF'
timeseries r = sum(custom.nexus.log.adapter.responses, default: 0), by: { service, channel, outcome }
| fieldsAdd n = arraySum(r)
| summarize total = sum(n), error = sum(if(outcome == "error", n, else: 0)), by: { service, channel }
| sort error desc
| limit 1000
EOF
)"

add_query adp_peak "fetch logs
| filter $ERRORS_BUCKET and nexus.kind == \"audit_resp\" and nexus.outcome == \"error\"
| summarize errors = count(), by: { hour = bin(timestamp, 1h) }
| sort errors desc
| limit 1"

add_query adp_errors "fetch logs
| filter $ERRORS_BUCKET and nexus.kind == \"audit_resp\" and nexus.outcome == \"error\"
$(cat <<'EOF'
| parse content, "LD '\"system\":\"' LD:error_system '\"'"
| parse content, "LD '\"message\":\"' LD:error_message '\"'"
| summarize total = count(),
    by: { http_code = nexus.http_code, error_system, error_message, service = nexus.service, channel = nexus.channel }
| sort total desc
| limit 1000
EOF
)"

# GenericExceptionMapper lines look like
#   Exception: 400 :: <errorMsg> .<DIRECTION>: <rule with %1 %2 %3>. 1=<p1>, 2=<p2>, 3=<p3> ::HEAD::
# The pipeline already sets kind (timeout_504 / mapping_error / technical_error), direction, rule and field;
# ex1..ex3 fill the rule for the example.
add_query adp_exceptions "fetch logs
| filter $ERRORS_BUCKET and in(nexus.kind, array(\"timeout_504\", \"mapping_error\", \"technical_error\"))
$(cat <<'EOF'
| parse content, "LD 'Exception:' SPACE? INT:exc_code SPACE? '::' SPACE? LD:error_msg '.'"
| parse content, "LD '. 1=' LD:params SPACE? '::HEAD::'"
| fieldsAdd args = splitString(params, ", ")
| fieldsAdd p1 = args[0], p2 = substring(args[1], from: 2), p3 = substring(args[2], from: 2)
| summarize total = count(), ex1 = takeFirst(p1), ex2 = takeFirst(p2), ex3 = takeFirst(p3),
    by: { kind = nexus.kind, http_code = nexus.http_code, exc_code, error_msg = trim(error_msg),
          direction = nexus.mapping.direction, rule = nexus.mapping.rule, field = nexus.mapping.field,
          adapter = nexus.component, service = nexus.service }
| sort total desc
| limit 10000
EOF
)"

add_query adp_latency "$(cat <<'EOF'
timeseries c = sum(custom.nexus.log.adapter.backend_calls, default: 0), by: { component, latency_bucket }
| fieldsAdd n = arraySum(c)
| summarize calls = sum(n), slow_1s = sum(if(in(latency_bucket, array("1-5s", "5s+")), n, else: 0)),
    slow_5s = sum(if(latency_bucket == "5s+", n, else: 0)), by: { component }
| lookup [
    timeseries total_ms = sum(custom.nexus.log.adapter.backend_ms, default: 0),
        max_ms = max(custom.nexus.log.adapter.backend_ms), by: { component }
    | fieldsAdd total_ms = arraySum(total_ms), max_ms = arrayMax(max_ms)
  ], sourceField: component, lookupField: component, fields: { total_ms, max_ms }
| fieldsAdd avg_ms = if(calls > 0, total_ms / calls)
| sort slow_1s desc
| limit 100
EOF
)"

# ---------------------------------------------------------------- submit all, then collect

# cache key: query text + exact window
cache_file() {
  printf '%s/dt_%s_%s_%s.json' "$CACHE_DIR" "$(printf '%s' "${Q_TEXT[$1]}" | cksum | cut -d' ' -f1)" "$START" "$END"
}

hits=0 sent=0
for name in "${!Q_TEXT[@]}"; do
  if [ "$CACHE" = 1 ]; then
    CACHE_OF[$name]=$(cache_file "$name")
    if [ -s "${CACHE_OF[$name]}" ]; then
      cp "${CACHE_OF[$name]}" "$TMP/$name.json"
      hits=$((hits + 1))
      debug "$name -> cache hit"
      continue
    fi
  fi
  [ -s "$AUTH_HEADER" ] || authenticate
  TOKEN[$name]=$(dt_submit "${Q_TEXT[$name]}")
  [ "${TOKEN[$name]}" != done ] || mv "$TMP/.done" "$TMP/$name.json"
  sent=$((sent + 1))
  debug "$name -> submitted"
done
log "${#Q_TEXT[@]} queries: $hits from the cache, $sent sent to Dynatrace"

for name in "${!TOKEN[@]}"; do
  if [ "${TOKEN[$name]}" != done ]; then
    log "Collecting $name"
    dt_collect "${TOKEN[$name]}" > "$TMP/$name.json"
    TOKEN[$name]=done
  fi
  if [ "$CACHE" = 1 ]; then
    cp "$TMP/$name.json" "${CACHE_OF[$name]}.part" && mv "${CACHE_OF[$name]}.part" "${CACHE_OF[$name]}"
  fi
done

TRUNCATED=0
for name in "${!Q_TEXT[@]}"; do
  rows=$(jq '.records | length' < "$TMP/$name.json" | tr -d '\r')
  if [ "$rows" -ge "$MAX_ROWS" ]; then
    TRUNCATED=1
    log "  WARNING: '$name' hit $MAX_ROWS rows (truncated)."
  fi
done

# ---------------------------------------------------------------- CSVs

to_csv() {   # header = every field seen
  jq -r '[.records[]] | if length == 0 then empty else
           (reduce (.[] | keys_unsorted[]) as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)) as $k
           | ($k | @csv), (.[] | [.[$k[]] | if type == "object" or type == "array" then tojson else . end] | @csv) end' \
    | tr -d '\r'
}
for name in adp_by_service adp_errors adp_exceptions adp_latency; do
  to_csv < "$TMP/$name.json" > "$OUT_DIR/$name.csv"
done

# ---------------------------------------------------------------- report

{
  for name in adp_kpi adp_by_service adp_errors adp_peak adp_exceptions adp_latency; do
    jq -c --arg n "$name" '{($n): .records}' < "$TMP/$name.json"
  done
  jq -n -c \
    --arg from "$(cot_fmt "$START" '%d/%m %H:%M')" --arg to "$(cot_fmt "$END" '%d/%m %H:%M')" \
    --argjson truncated "$TRUNCATED" --argjson tz "$TZ_SECONDS" \
    --argjson wa "$WARN_ADP_ERR" --argjson ca "$CRIT_ADP_ERR" --argjson minr "$TOP_MIN_RESPONSES" \
    '{meta: {$from, $to, $truncated, $tz, th: {$wa, $ca, $minr}}}'
} | tr -d '\r' | jq -s -r 'add | . as $d
  | def num: (. // 0) | tonumber;
    def fmt: (num | round | tostring) as $s | ($s | length) as $n     # 1234567 -> "1.234.567" (es-CO)
      | [range(0; $n) | $s[.:. + 1] + (if ($n - . - 1) > 0 and (($n - . - 1) % 3) == 0 then "." else "" end)] | join("");
    def pct(a; b): if b > 0 then (a * 1000 / b | round) / 10 else 0 end;
    def pc: tostring | sub("\\."; ",");                                 # 97.2 -> "97,2" (es-CO)
    def light(v; w; c): if v >= c then "🔴" elif v >= w then "🟡" else "🟢" end;
    def why(v; w; c): if v >= c then "≥ \(c | pc)%" elif v >= w then "≥ \(w | pc)%" else "< \(w | pc)%" end;
    def lit(what; v; w; c): "\(light(v; w; c)) \(what) \(v | pc)% \(why(v; w; c))";
    def band(w; c): "🟢 menos de \(w | pc)%, 🟡 de \(w | pc)% a \(c | pc)%, 🔴 \(c | pc)% o más";
    def cut(n): (. // "") | if length > n then .[0:n - 1] + "…" else . end;
    # a parameter can be a whole backend record: keep its start and length
    def short(n): gsub("\\s+"; " ") | if length > n then .[0:n] + "… (\(length) caracteres)" else . end;
    def svc: if (. // "") == "" then "(sin servicio)" else . end;
    def chan: if (. // "") == "" then "(sin canal)" else . end;
    def sumby(f): group_by(f) | map(.[0] + {total: (map(.total | num) | add)}) | sort_by(-.total);
    def total_of(xs): [xs | .[].total | num] | add // 0;

    ($d.meta.th) as $th
  | ($d.adp_kpi[0] // {}) as $r | ($r.total | num) as $rt
  | ($r.error | num) as $rerr | pct($rerr; $rt) as $pe
  | light($pe; $th.wa; $th.ca) as $overall
  | (if $overall == "🟢" then "todo bajo los umbrales" else "Adaptadores con error \($pe | pc)% (\(why($pe; $th.wa; $th.ca)))" end) as $reason
  | ($d.adp_peak[0] // null) as $pk
  | (if $pk == null or ($pk.hour // null) == null then null
     else $pk.hour | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | . + $d.meta.tz | strftime("%d/%m %H:00") end) as $peak
  | ($d.adp_by_service | group_by(.service // "")
     | map({service: (.[0].service // ""), total: (map(.total | num) | add), error: (map(.error | num) | add)})
     | map(. + {pct: pct(.error; .total)})) as $svcs
  # services under minr responses only fill the top 5 when there are not enough others
  | ($svcs | map(select(.error > 0) | . + {low: (.total < $th.minr)})
     | sort_by(.low, -.pct, -.error) | .[0:5]) as $top
  | ($d.adp_exceptions | map(select(.kind == "timeout_504")) | sumby(.service // "")) as $timeouts
  # mapping errors without channel; the example comes from the biggest row
  | ($d.adp_exceptions | map(select(.kind == "mapping_error"))
     | group_by([.direction, .rule, .field, .adapter, .service])
     | map(max_by(.total | num) + {total: (map(.total | num) | add)}) | sort_by(-.total)) as $mapping
  | ($d.adp_exceptions | map(select(.kind == "technical_error"))
     | sumby([.http_code, .exc_code, .error_msg, .service])) as $other_exc
  | ($d.adp_latency | map(. + {calls: (.calls | num), slow_1s: (.slow_1s | num), slow_5s: (.slow_5s | num)})
     | map(select(.calls > 0) | . + {p1: pct(.slow_1s; .calls), p5: pct(.slow_5s; .calls)})
     | sort_by(-.p1, -.calls)) as $lat
  | [
    "📊 Estado diario Nexus \($overall)",
    "Motivo: \($reason)",
    "🕔 \($d.meta.from) → \($d.meta.to) (hora Colombia)",
    "",
    "🚦 Umbrales",
    "   - Error de adaptadores y de cada servicio: \(band($th.wa; $th.ca))",
    "",
    "📈 Resumen",
    "• Adaptadores: \(lit("error"; $pe; $th.wa; $th.ca))",
    "   - Respuestas: \($rt | fmt)",
    "   - OK (2xx): \(pct($r.ok_2xx | num; $rt) | pc)%",
    "   - Negocio (412): \(pct($r.business_412 | num; $rt) | pc)%",
    "   - Error: \($pe | pc)% (\($rerr | fmt))",
    "• Hora pico de errores: " + (if $peak == null then "ninguna" else "\($peak) (\($pk.errors | fmt) errores)" end),
    "",
    "🔥 Top 5 servicios por % de error"
  ]
  + (if ($top | length) == 0 then ["• ninguno"] else
      ($top | to_entries | map(.key as $i | .value as $s
        | ["\($i + 1). \(light($s.pct; $th.wa; $th.ca)) \($s.service | svc): \($s.pct | pc)% de error (\($s.error | fmt) de \($s.total | fmt))"
           + (if $s.low then ", poco volumen" else "" end)]
          # worst 3 channels
          + ([$d.adp_by_service[] | select((.service // "") == $s.service)
              | {channel: (.channel // ""), total: (.total | num), error: (.error | num)}]
             | map(select(.error > 0) | . + {pct: pct(.error; .total)}) | sort_by(-.error) | .[0:3]
             | map("   - Canal \(.channel | chan): \(light(.pct; $th.wa; $th.ca)) \(.pct | pc)% de error (\(.error | fmt) de \(.total | fmt))"))
          # top 2 errors and their channels
          + ([$d.adp_errors[] | select((.service // "") == $s.service)]
             | group_by([.http_code, .error_system, .error_message])
             | map({row: .[0], total: (map(.total | num) | add),
                    chans: (group_by(.channel // "") | map({channel: (.[0].channel // ""), n: (map(.total | num) | add)}) | sort_by(-.n))})
             | sort_by(-.total) | .[0:2]
             | map("   - Error \(.row.http_code // "-") \(.row.error_system // "-"): \(.row.error_message // "(sin mensaje)" | cut(80)) (\(.total | fmt); "
                   + (.chans[0:3] | map("canal \(.channel | chan): \(.n | fmt)") | join(", ")) + ")")))
       | add) end)
  + ["", "📋 Error por servicio"]
  + (if ($svcs | length) == 0 then ["• sin datos"] else
      ($svcs | sort_by(-.total)
       | map("• \(light(.pct; $th.wa; $th.ca)) \(.service | svc): error \(.pct | pc)% (\(.total | fmt) respuestas)")) end)
  + ["", "⏱️ Latencia del backend por adaptador (los 5 con más llamadas de más de 1 s)"]
  + (if ($lat | length) == 0 then ["• sin datos"] else
      ($lat[0:5] | map("• \(.component // "-"): \(.p1 | pc)% de más de 1 s, \(.p5 | pc)% de más de 5 s, "
                       + "promedio \(if .avg_ms == null then "-" else "\(.avg_ms | fmt) ms" end), "
                       + "máximo \(if .max_ms == null then "-" else "\(.max_ms | fmt) ms" end) (\(.calls | fmt) llamadas)")) end)
  + ["", "🧩 Errores de mapeo: \(total_of($mapping) | fmt)"]
  + ($mapping[0:5] | to_entries | map(.key as $i | .value as $x
      | ["\($i + 1). \($x.field // "-") (\($x.direction // "-")): \($x.total | fmt)",
         "   - Servicio: \($x.service | svc), adaptador \($x.adapter // "-")"]
        + (if ($x.rule // "") != "" then
            ["   - Regla: \($x.rule)",
             "   - Ej: " + ($x.rule | gsub("%1"; $x.ex1 // "%1" | short(25)) | gsub("%2"; $x.ex2 // "%2" | short(40))
                            | gsub("%3"; $x.ex3 // "%3" | short(40)) | cut(200))]
          else [] end)) | add // [])
  + ["", "⏳ Timeouts 504: \(total_of($timeouts) | fmt)"]
  + ($timeouts[0:3] | map("   - \(.service | svc): \(.total | fmt)"))
  + ["", "⚙️ Otros errores técnicos: \(total_of($other_exc) | fmt)"]
  + ($other_exc[0:3] | map("   - HTTP \(.http_code // "-"), código \(.exc_code // "-"): \(.error_msg // "(sin mensaje)" | cut(60)) en \(.service | svc) (\(.total | fmt))"))
  + (if $d.meta.truncated == 1 then ["", "⚠️ Algunas consultas llegaron al límite de 10.000 filas; los conteos pueden quedar cortos."] else [] end)
  | .[]' | tr -d '\r' > "$OUT_DIR/report.txt"

log "Done -> $OUT_DIR/report.txt"
echo
cat "$OUT_DIR/report.txt"
