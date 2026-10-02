#!/usr/bin/env bash
# Daily Nexus status report: the KPIs of the NexusGeneral dashboard (API Gateway, adapters, mngr/channel)
# plus the error transactions grouped by (msgRespuesta, channel, nombreOperacion), rendered as plain text
# ready to paste into a chat. All queries are submitted at once and collected afterwards.
#
# Usage:  ./daily_report.sh                                   # yesterday 17:00 -> now (Colombia time, UTC-5)
#         ./daily_report.sh "YYYY-MM-DD HH:MM:SS" ["YYYY-MM-DD HH:MM:SS"]   # explicit start [and end]
# Output: results/daily_<start>__<end>/report.txt (also printed to stdout) and one CSV per section
#
# Requires: aws cli v2 (active credentials/profile: AWS_PROFILE), jq, GNU date.
# Optional env vars: AWS_REGION, OUT_BASE, DASHBOARD_JSON, DEBUG (0/1/2),
#                    START_TIME   default window start, time of day yesterday (default 17:00)
#                    CHUNK_HOURS  slice size for the per-rqid error query, keeps each slice under the
#                                 10,000-row Insights limit (default 4)
#                    ERROR_PATTERN1, ERROR_PATTERN2   mngr error markers (default Error / ERROR)
#                    thresholds in %, yellow/red: WARN_5XX/CRIT_5XX (1/5), WARN_ADP_ERR/CRIT_ADP_ERR (1/5),
#                                                 WARN_REJECT/CRIT_REJECT (5/10)
set -euo pipefail

# shellcheck source=lib/cw.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/cw.sh"

OUT_BASE="${OUT_BASE:-results}"
START_TIME="${START_TIME:-17:00}"
CHUNK_HOURS="${CHUNK_HOURS:-4}"
ERROR_PATTERN1="${ERROR_PATTERN1:-Error}"
ERROR_PATTERN2="${ERROR_PATTERN2:-ERROR}"
WARN_5XX="${WARN_5XX:-1}"         CRIT_5XX="${CRIT_5XX:-5}"
WARN_ADP_ERR="${WARN_ADP_ERR:-1}" CRIT_ADP_ERR="${CRIT_ADP_ERR:-5}"
WARN_REJECT="${WARN_REJECT:-5}"   CRIT_REJECT="${CRIT_REJECT:-10}"

[ $# -le 2 ] || die "usage: $0 [\"YYYY-MM-DD HH:MM:SS\" [\"YYYY-MM-DD HH:MM:SS\"]]  (Colombia time)"
cw_require_tools

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

mapfile -t API_GROUPS < <(cw_groups api)
mapfile -t ADAPTER_GROUPS < <(cw_groups adapter)
mapfile -t MNGR_GROUPS < <(cw_groups mngr)
[ "${#API_GROUPS[@]}" -gt 0 ] && [ "${#ADAPTER_GROUPS[@]}" -gt 0 ] && [ "${#MNGR_GROUPS[@]}" -gt 0 ] \
  || die "missing log groups in $DASHBOARD_JSON"

log "Window $(cot_fmt "$START" '%F %H:%M') -> $(cot_fmt "$END" '%F %H:%M') COT | ${#API_GROUPS[@]} api, ${#ADAPTER_GROUPS[@]} adapter, ${#MNGR_GROUPS[@]} mngr log groups"
debug "region=$REGION out=$OUT_DIR dashboard=$DASHBOARD_JSON"
cw_debug_env

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
| stats count(*) as total, count(ok) as ok, count(negocio) as negocio"

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
| fields rqid, coalesce(tag, '') as canalTag, coalesce(op, '') as opName, coalesce(msg, '') as msgText
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

log "Submitting ${#Q_TEXT[@]} queries"
declare -A QID
for name in "${!Q_TEXT[@]}"; do
  read -r qs qe <<<"${Q_RANGE[$name]:-$START $END}"
  mapfile -t groups < <(groups_of "${Q_KIND[$name]}")
  QID[$name]=$(cw_submit "${Q_TEXT[$name]}" "$qs" "$qe" "${groups[@]}") || die "could not start query '$name'"
  debug "$name -> ${QID[$name]}"
done

log "Collecting results"
TRUNCATED=0
for name in "${!QID[@]}"; do
  cw_collect "${QID[$name]}" > "$TMP/$name.json"
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
    def fmt: (num | round | tostring) as $s | ($s | length) as $n     # 1234567 -> "1,234,567"
      | [range(0; $n) | $s[.:. + 1] + (if ($n - . - 1) > 0 and (($n - . - 1) % 3) == 0 then "," else "" end)] | join("");
    def pct(a; b): if b > 0 then (a * 1000 / b | round) / 10 else 0 end;
    def light(v; w; c): if v >= c then "🔴" elif v >= w then "🟡" else "🟢" end;
    def cut(n): (. // "") | if length > n then .[0:n - 1] + "…" else . end;
    def orNone: if length == 0 then ["none"] else . end;

    ($d.meta.th) as $th
  | ($d.api_kpi[0] // {}) as $a | ($a.total | num) as $at
  | pct($a.s5xx | num; $at) as $p5
  | ($d.adp_kpi[0] // {}) as $r | ($r.total | num) as $rt
  | (($rt - ($r.ok | num) - ($r.negocio | num))) as $rerr | pct($rerr; $rt) as $pe
  | ($d.mngr_reject_pct[0] // {}) as $m | pct($m.rejected | num; $m.total | num) as $pm
  | [light($p5; $th.w5; $th.c5), light($pe; $th.wa; $th.ca), light($pm; $th.wr; $th.cr)] as $lights
  | (if any($lights[]; . == "🔴") then "🔴" elif any($lights[]; . == "🟡") then "🟡" else "🟢" end) as $overall
  | ($d.adp_exceptions | map(select(.code == "504"))) as $timeouts
  | ($d.adp_exceptions | map(select(.code != "504"))) as $mapping
  | $d.errors as $e
  | [
    "📊 Nexus daily status \($overall)",
    "🕔 \($d.meta.from) → \($d.meta.to) (COT)",
    "",
    "🌐 API Gateway \($lights[0])",
    "• \($at | fmt) requests | 2xx \(pct($a.s2xx | num; $at))% | 4xx \(pct($a.s4xx | num; $at))% | 5xx \($p5)% | p95 \($a.p95 | fmt) ms",
    "• Most errors: " + ([$d.api_by_api[] | select((.s4xx | num) + (.s5xx | num) > 0)][0:3]
        | map("\(.API) 5xx \(.s5xx | fmt) / 4xx \(.s4xx | fmt) of \(.total | fmt)") | orNone | join(" · ")),
    "",
    "🔌 Adapters \($lights[1])",
    "• \($rt | fmt) responses | OK \(pct($r.ok | num; $rt))% | 412 business \(pct($r.negocio | num; $rt))% | error \($pe)%",
    "• Most errors: " + ([$d.adp_by_service[] | select((.error | num) > 0)][0:3]
        | map("\(.servicio // "-")/\(.canal // "-") \(.error | fmt)") | orNone | join(" · ")),
    "• Timeouts 504: \([$timeouts[].total | num] | add // 0 | fmt)" + (if ($timeouts | length) > 0 then " — top: " +
        ($timeouts | group_by([.service, .channel]) | map({k: "\(.[0].service // "-")/\(.[0].channel // "-")", n: ([.[].total | num] | add)})
         | sort_by(-.n) | .[0:3] | map("\(.k) (\(.n | fmt))") | join(" · ")) else "" end),
    "• Mapping errors: \([$mapping[].total | num] | add // 0 | fmt)" + (if ($mapping | length) > 0 then " — top: " +
        ($mapping[0:3] | map("\(.code) \(.errorMsg | cut(50)) [\(.field // "-")] \(.service // "-")/\(.channel // "-") (\(.total | fmt))") | join(" · ")) else "" end),
    "• Slowest p95: " + ($d.adp_latency[0:3] | map("\(.Adaptador) \(.p95 | fmt) ms") | orNone | join(" · ")),
    "• Peak error hour: " + (if $d.meta.peak == "" then "none" else "\($d.meta.peak) (\($d.adp_peak[0].errores | fmt) errors)" end),
    "",
    "📡 Channel (mngr) \($lights[2])",
    "• Rejected (M): \($pm)% of \($m.total | fmt) responses",
    "• Top rejections: " + ($d.mngr_rejects[0:3]
        | map("\(.nombreOperacion // "-") · \(.msgRespuesta // "-" | cut(50)) · canal \(.canal // "-") (\(.rejected | fmt))") | orNone | join(" | ")),
    "• Error transactions: \($e.rqids | fmt) rqids in \($e.groups | length) groups (channel found for \($e.with_canal | fmt))"
  ]
  + ($e.groups[0:5] | to_entries | map("  \(.key + 1). \(.value.msg | if . == "" then "(no msgRespuesta)" else cut(60) end) | canal \(.value.canal | if . == "" then "?" else . end) | \(.value.op | if . == "" then "-" else . end) — \(.value.count | fmt)"))
  + (if $d.meta.truncated == 1 then ["", "⚠️ Some queries hit the 10,000-row limit; counts may be low (lower CHUNK_HOURS)."] else [] end)
  | .[]' | tr -d '\r' > "$OUT_DIR/report.txt"

log "Done -> $OUT_DIR/report.txt"
echo
cat "$OUT_DIR/report.txt"
