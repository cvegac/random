#!/usr/bin/env bash
# Creates or deletes the Nexus CloudWatch metric filters, alarms and the NexusAlarmas dashboard.
# Alarms are created with actions disabled; enable them after reviewing the thresholds.
#
# Usage: ./nexus_alarms.sh create                 dry run (default): tests the patterns and prints the plan
#        DRY_RUN=0 ./nexus_alarms.sh create       applies it
#        DRY_RUN=0 ./nexus_alarms.sh filters      only the metric filters (alarm thresholds are kept)
#        DRY_RUN=0 ./nexus_alarms.sh dashboard    only the dashboard
#        DRY_RUN=0 ./nexus_alarms.sh delete       removes everything "create" made
#
# Works on the account of the AWS credentials in the environment; log groups missing there are skipped.
# Everything is named nexus-* under Nexus/*, so running it again overwrites instead of duplicating.
# The dashboard body has alarm ARNs, so it is built in memory and never saved to disk.
# Env: AWS_REGION, DRY_RUN (1)
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: don't turn /aws/... args into Windows paths
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

REGION="${AWS_REGION:-us-east-1}"
DRY_RUN="${DRY_RUN:-1}"
PREFIX="nexus-"
DASHBOARD="NexusAlarmas"

WS=(accountsws acquiringws clientsws credit-cardsws insurancesws investmentsws loansws paymentsws productsws remittancesws securityws)
API_GROUPS=(); MNGR_GROUPS=()
for w in "${WS[@]}"; do
  API_GROUPS+=("/aws/api/api_${w//-/}")          # the gateway group has no hyphen: api_creditcardsws
  MNGR_GROUPS+=("/aws/ecs/srv/${w}-mngr")
done
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

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

aws_cli() {
  local errfile rc=0 real
  errfile=$(mktemp)
  aws --no-verify-ssl "$@" 2> "$errfile" || rc=$?
  real=$(awk '!/InsecureRequestWarning/ && !/^[[:space:]]*warnings\.warn\(/' "$errfile" | tr -d '\r')
  rm -f "$errfile"
  [ -z "$real" ] || echo "$real" >&2
  return "$rc"
}

# in dry run the call is only logged
mutate() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then log "  [dry-run] $desc"; return 0; fi
  aws_cli "$@" > /dev/null
  log "  done: $desc"
}

# lab and prod don't have the same log groups
declare -A EXISTS=()
load_existing_groups() {
  local p lg
  for p in /aws/api/api_ /aws/ecs/srv/; do
    for lg in $(aws_cli logs describe-log-groups --region "$REGION" --log-group-name-prefix "$p" \
                  --query 'logGroups[].logGroupName' --output text | tr -d '\r'); do
      EXISTS[$lg]=1
    done
  done
}
keep_existing() {  # keep_existing <array name>
  local -n groups="$1"
  local kept=() lg
  for lg in "${groups[@]}"; do
    if [ -n "${EXISTS[$lg]:-}" ]; then kept+=("$lg"); else log "  $lg does not exist here, skipping it"; fi
  done
  groups=("${kept[@]}")
}

# ---------------------------------------------------------------- pattern self-test (read-only)

# expect <pattern> <1|0> <sample>
expect() {
  local pattern="$1" want="$2" sample="$3" got
  got=$(aws_cli logs test-metric-filter --region "$REGION" --filter-pattern "$pattern" \
          --log-event-messages "$sample" --query 'length(matches)' --output text | tr -d '\r')
  [ "$got" = "$want" ] || die "pattern '$pattern' gave $got match(es), expected $want. Nothing was created."
}

# sample lines with the same shape as the adapter and mngr logs
RQ="00000000-0000-0000-0000-000000000000"
S_REQ="2026-01-01 00:00:00.000000 INFO  [x.AuditFilter] (executor-thread-1) ::AUDIT::REQ::METHOD::POST::HEAD::[X-RqUid=$RQ,X-Name=37]::URI::/x::BODY::{}"
S_200="2026-01-01 00:00:00.000000 INFO  [x.AuditFilter] (executor-thread-1) ::AUDIT::RESP::HEAD::[X-RqUid=$RQ,X-Name=37]::BODY::{\"ok\":1}::HTTPCODE::200"
S_412="2026-01-01 00:00:00.000000 INFO  [x.AuditFilter] (executor-thread-1) ::AUDIT::RESP::HEAD::[X-RqUid=$RQ,X-Name=37]::BODY::{\"error\":{\"code\":\"1\",\"message\":\"x\",\"system\":\"STRATUS_NEXUS\"}}::HTTPCODE::412"
S_503="2026-01-01 00:00:00.000000 INFO  [x.AuditFilter] (executor-thread-1) ::AUDIT::RESP::HEAD::[X-RqUid=$RQ,X-Name=37]::BODY::{}::HTTPCODE::503"
S_206="2026-01-01 00:00:00.000000 INFO  [x.AuditFilter] (executor-thread-1) ::AUDIT::RESP::HEAD::[X-RqUid=$RQ,X-Name=37]::BODY::{\"ok\":1}::HTTPCODE::206"
S_MAP="2026-01-01 00:00:00.000000 WARN  [x.GenericExceptionMapper] (executor-thread-1) HttpCode:: 400::Exception: 400 :: Sample .RESPONSE: x ::HEAD::[X-RqUid=$RQ]"
S_TIMEOUT="2026-01-01 00:00:00.000000 WARN  [x.GenericExceptionMapper] (executor-thread-1) HttpCode:: 504::Exception: 504 :: Sample .RESPONSE: x ::HEAD::[X-RqUid=$RQ]"
S_MNGR_ERR="2026-01-01 00:00:00,000 ERROR [dt] [$RQ][ERROR !][ sample ]"
S_MNGR_INFO="2026-01-01 00:00:00,000 INFO [dt] [$RQ][INFO i][ Body= <msgRespuesta>ERROR EN LA VALIDACION</msgRespuesta> ][AuditLog]"
S_SOAP_M="2026-01-01 00:00:00,000 INFO [dt] [$RQ][INFO i][ Body= <Response><DataHeader><nombreOperacion>X</nombreOperacion><caracterAceptacion>M</caracterAceptacion><codMsgRespuesta>1</codMsgRespuesta></DataHeader></Response> ][AuditLog]"
S_SOAP_B="2026-01-01 00:00:00,000 INFO [dt] [$RQ][INFO i][ Body= <Response><DataHeader><nombreOperacion>X</nombreOperacion><caracterAceptacion>B</caracterAceptacion><codMsgRespuesta>0</codMsgRespuesta></DataHeader></Response> ][AuditLog]"

# CloudWatch allows at most 5 regex filter patterns per log group (4 used here)
P_RESP='%::AUDIT::RESP::%'
P_2XX='%::HTTPCODE::2[0-9][0-9]%'   # any 2xx is a success (e.g. 206 on payments)
P_412='%::HTTPCODE::412%'
P_5XX='%::HTTPCODE::5[0-9][0-9]%'
# a mapper 504 is a backend timeout, not a mapping error
P_MAP='"GenericExceptionMapper" "HttpCode::" -"HttpCode:: 504"'
P_TIMEOUT='"GenericExceptionMapper" "HttpCode:: 504"'
P_MNGR_ERR='"[ERROR"'   # the level can have an emoji after ERROR
# SOAP response to the channel: caracterAceptacion B = accepted, M = rejected (business or technical)
P_CANAL_RESP='"<caracterAceptacion>"'
P_CANAL_REJ='"<caracterAceptacion>M</caracterAceptacion>"'

test_log_patterns() {
  log "Testing adapter and mngr patterns against synthetic lines (read-only)"
  expect "$P_RESP" 1 "$S_200"; expect "$P_RESP" 1 "$S_412"; expect "$P_RESP" 0 "$S_REQ"
  expect "$P_2XX" 1 "$S_200"; expect "$P_2XX" 1 "$S_206"; expect "$P_2XX" 0 "$S_412"; expect "$P_2XX" 0 "$S_503"
  expect "$P_412" 1 "$S_412"; expect "$P_412" 0 "$S_200"
  expect "$P_5XX" 1 "$S_503"; expect "$P_5XX" 0 "$S_412"; expect "$P_5XX" 0 "$S_200"
  expect "$P_MAP" 1 "$S_MAP"; expect "$P_MAP" 0 "$S_TIMEOUT"; expect "$P_MAP" 0 "$S_200"
  expect "$P_TIMEOUT" 1 "$S_TIMEOUT"; expect "$P_TIMEOUT" 0 "$S_MAP"; expect "$P_TIMEOUT" 0 "$S_200"
  expect "$P_MNGR_ERR" 1 "$S_MNGR_ERR"; expect "$P_MNGR_ERR" 0 "$S_MNGR_INFO"
  expect "$P_CANAL_RESP" 1 "$S_SOAP_M"; expect "$P_CANAL_RESP" 1 "$S_SOAP_B"; expect "$P_CANAL_RESP" 0 "$S_MNGR_INFO"
  expect "$P_CANAL_REJ" 1 "$S_SOAP_M"; expect "$P_CANAL_REJ" 0 "$S_SOAP_B"
  log "  all patterns behave as expected"
}

# status can be a number or a string depending on the access log format, so read one recent event
# to pick the right comparison
GW_ENABLED=0; GW_LATENCY=0
learn_gateway_patterns() {
  local lg="" candidate start msg="" stype ltype s5 s2
  log "Learning the gateway access-log format from one recent event (read-only)"
  start=$(( ($(date +%s) - 86400) * 1000 ))
  for candidate in "${API_GROUPS[@]}"; do
    msg=$(aws_cli logs filter-log-events --region "$REGION" --log-group-name "$candidate" --start-time "$start" \
            --limit 1 --query 'events[0].message' --output text | tr -d '\r')
    if [ -n "$msg" ] && [ "$msg" != "None" ]; then lg="$candidate"; break; fi
  done
  if [ -z "$lg" ]; then
    log "  WARNING: no gateway traffic in the last 24h here: skipping gateway metric filters and alarms"
    return 0
  fi
  jq -e 'type == "object" and has("status")' <<<"$msg" > /dev/null 2>&1 \
    || die "$lg is not JSON with a status field; the gateway filters need a hand-written pattern"
  stype=$(jq -r '.status | type' <<<"$msg")
  if [ "$stype" = number ]; then
    P_GW_REQ='{ $.status >= 0 }';  P_GW_5XX='{ $.status >= 500 }'
  else
    P_GW_REQ='{ $.status = "*" }'; P_GW_5XX='{ $.status = "5*" }'
  fi
  s5=$(jq -c --arg t "$stype" '.status = (if $t == "number" then 503 else "503" end)' <<<"$msg")
  s2=$(jq -c --arg t "$stype" '.status = (if $t == "number" then 200 else "200" end)' <<<"$msg")
  expect "$P_GW_REQ" 1 "$msg"; expect "$P_GW_5XX" 1 "$s5"; expect "$P_GW_5XX" 0 "$s2"
  ltype=$(jq -r '.responseLatency | type' <<<"$msg")
  if [ "$ltype" = number ]; then
    P_GW_LAT='{ $.responseLatency >= 0 }'; expect "$P_GW_LAT" 1 "$msg"; GW_LATENCY=1
  else
    log "  WARNING: responseLatency is $ltype, not a number: skipping the gateway latency metric and alarm"
  fi
  GW_ENABLED=1
  log "  learned from $lg: status is a $stype; patterns chosen and tested"
}

# ---------------------------------------------------------------- create

put_filter() {  # put_filter <log-group> <filter-name> <pattern> <namespace> <metric> [value]
  local lg="$1" name="$PREFIX$2" pattern="$3" ns="$4" metric="$5" value="${6:-1}" extra=""
  [ "$value" != 1 ] || extra=",defaultValue=0"   # only counts default to 0
  mutate "metric filter $name on $lg" logs put-metric-filter --region "$REGION" --log-group-name "$lg" \
    --filter-name "$name" --filter-pattern "$pattern" \
    --metric-transformations "metricName=$metric,metricNamespace=$ns,metricValue=$value$extra"
}

alarm() {  # alarm <name> <description> <put-metric-alarm args...>
  local name="$PREFIX$1" desc="$2"; shift 2
  mutate "alarm $name (actions DISABLED)" cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name "$name" --alarm-description "$desc" --no-actions-enabled "$@"
}

sum_alarm() {  # sum_alarm <name> <description> <namespace> <metric> <threshold>
  alarm "$1" "$2" --namespace "$3" --metric-name "$4" --statistic Sum --period 300 \
    --evaluation-periods 3 --datapoints-to-alarm 2 --threshold "$5" \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
}

metric_stat() {  # metric_stat <id> <namespace> <metric>
  printf '{"Id":"%s","MetricStat":{"Metric":{"Namespace":"%s","MetricName":"%s"},"Period":300,"Stat":"Sum"},"ReturnData":false}' \
    "$1" "$2" "$3"
}

create_all() {
  create_filters
  create_alarms
  create_dashboard
  log "Done. Review in CloudWatch > Alarms (filter by \"$PREFIX\"); enable with: aws cloudwatch enable-alarm-actions --alarm-names <name>"
}

create_filters() {
  test_log_patterns
  learn_gateway_patterns

  if [ "$GW_ENABLED" = 1 ]; then
    log "Metric filters: gateway (${#API_GROUPS[@]} groups)"
    for lg in "${API_GROUPS[@]}"; do
      put_filter "$lg" gateway-requests "$P_GW_REQ" Nexus/Gateway GatewayRequests
      put_filter "$lg" gateway-5xx "$P_GW_5XX" Nexus/Gateway Gateway5xx
      [ "$GW_LATENCY" = 0 ] || put_filter "$lg" gateway-latency "$P_GW_LAT" Nexus/Gateway GatewayLatency '$.responseLatency'
    done
  fi

  log "Metric filters: adapters (${#ADAPTER_GROUPS[@]} groups)"
  for lg in "${ADAPTER_GROUPS[@]}"; do
    put_filter "$lg" adapter-responses "$P_RESP" Nexus/Adapters AdapterResponses
    # counts any 2xx, the "200" name stays so existing alarms keep working
    put_filter "$lg" adapter-responses-200 "$P_2XX" Nexus/Adapters AdapterResponses200
    put_filter "$lg" adapter-responses-412 "$P_412" Nexus/Adapters AdapterResponses412
    put_filter "$lg" adapter-responses-5xx "$P_5XX" Nexus/Adapters AdapterResponses5xx
    put_filter "$lg" adapter-mapping-errors "$P_MAP" Nexus/Adapters AdapterMappingErrors
    put_filter "$lg" adapter-timeouts "$P_TIMEOUT" Nexus/Adapters AdapterTimeouts
  done

  log "Metric filters: mngr (${#MNGR_GROUPS[@]} groups)"
  for lg in "${MNGR_GROUPS[@]}"; do
    put_filter "$lg" mngr-errors "$P_MNGR_ERR" Nexus/Mngr MngrErrors
    put_filter "$lg" channel-responses "$P_CANAL_RESP" Nexus/Mngr ChannelResponses
    put_filter "$lg" channel-rejections "$P_CANAL_REJ" Nexus/Mngr ChannelRejections
  done
}

# needs GW_ENABLED/GW_LATENCY from create_filters
create_alarms() {
  log "Alarms (all with actions disabled)"
  if [ "$GW_ENABLED" = 1 ]; then
    sum_alarm gateway-5xx "API Gateway 5XX across the ws APIs" Nexus/Gateway Gateway5xx 10
    if [ "$GW_LATENCY" = 1 ]; then
      alarm gateway-latency-p95 "API Gateway p95 latency (ms) across the ws APIs" \
        --namespace Nexus/Gateway --metric-name GatewayLatency --extended-statistic p95 --period 300 \
        --evaluation-periods 3 --datapoints-to-alarm 2 --threshold 3000 \
        --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
    fi
    # 3 of 3: the last period is usually incomplete and looks like a drop
    alarm gateway-traffic-drop "Gateway traffic below its anomaly band (the model needs ~2 weeks of data)" \
      --evaluation-periods 3 --datapoints-to-alarm 3 --comparison-operator LessThanLowerThreshold \
      --threshold-metric-id band --treat-missing-data breaching \
      --metrics "[$(metric_stat req Nexus/Gateway GatewayRequests | sed 's/"ReturnData":false/"ReturnData":true/'),{\"Id\":\"band\",\"Expression\":\"ANOMALY_DETECTION_BAND(req, 2)\",\"ReturnData\":true}]"
  fi
  alarm adapters-real-error-pct "% of adapter responses that are neither 2xx nor 412 (412 = business answer); only with >50 responses" \
    --evaluation-periods 3 --datapoints-to-alarm 2 --threshold 5 \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
    --metrics "[$(metric_stat total Nexus/Adapters AdapterResponses),$(metric_stat ok Nexus/Adapters AdapterResponses200),$(metric_stat biz Nexus/Adapters AdapterResponses412),{\"Id\":\"pct\",\"Expression\":\"IF(total > 50, (total - ok - biz) * 100 / total, 0)\",\"Label\":\"real error %\",\"ReturnData\":true}]"
  sum_alarm adapters-backend-5xx "Adapter responses with HTTP 5xx from the backend" Nexus/Adapters AdapterResponses5xx 5
  sum_alarm adapters-mapping-errors "GenericExceptionMapper errors in the adapters, 504 timeouts excluded" Nexus/Adapters AdapterMappingErrors 10
  sum_alarm adapters-timeouts "Backend timeouts (504) reported by the adapters' GenericExceptionMapper" Nexus/Adapters AdapterTimeouts 10
  sum_alarm mngr-errors "[ERROR lines in the ws mngr" Nexus/Mngr MngrErrors 20
  # M includes business answers, so its normal level is well above 0: check the
  # "% rechazo al canal (M)" widget before enabling it
  alarm channel-rejection-pct "% of SOAP responses to the channel with caracterAceptacion M; only with >50 responses" \
    --evaluation-periods 3 --datapoints-to-alarm 2 --threshold 40 \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
    --metrics "[$(metric_stat total Nexus/Mngr ChannelResponses),$(metric_stat rej Nexus/Mngr ChannelRejections),{\"Id\":\"pct\",\"Expression\":\"IF(total > 50, rej * 100 / total, 0)\",\"Label\":\"channel rejection %\",\"ReturnData\":true}]"
}

# alarm status on top, then one graph per alarm, 3 per row (nexus-ecs-* alarms are skipped)
create_dashboard() {
  local alarms body n
  log "Dashboard $DASHBOARD, from the $PREFIX* alarms that exist now"
  alarms=$(aws_cli cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "$PREFIX" \
             --query 'MetricAlarms[].{name: AlarmName, arn: AlarmArn}' --output json | tr -d '\r' \
           | jq -c --arg ecs "${PREFIX}ecs-" '[.[] | select(.name | startswith($ecs) | not)] | sort_by(.name)')
  n=$(jq length <<<"$alarms")
  if [ "$n" -eq 0 ]; then
    log "  no $PREFIX* alarms exist yet (normal on a first dry-run): skipping the dashboard"
    return 0
  fi
  body=$(jq -c --arg region "$REGION" --arg prefix "$PREFIX" '
    {widgets: (
      [ {type: "alarm", x: 0, y: 0, width: 24, height: 6,
         properties: {title: "Alarmas Nexus", alarms: [.[].arn], sortBy: "stateUpdatedTimestamp"}} ]
      + [ to_entries[]
          | {type: "metric", x: ((.key % 3) * 8), y: (6 + ((.key / 3) | floor) * 6), width: 8, height: 6,
             properties: {title: (.value.name | ltrimstr($prefix)), annotations: {alarms: [.value.arn]},
                          view: "timeSeries", stacked: false, region: $region}} ]
    )}' <<<"$alarms")
  mutate "dashboard $DASHBOARD: $n alarms (status + 1 graph each)" \
    cloudwatch put-dashboard --region "$REGION" --dashboard-name "$DASHBOARD" --dashboard-body "$body"
}

# ---------------------------------------------------------------- delete

delete_all() {
  local names lg n
  log "Deleting alarms named $PREFIX*"
  names=$(aws_cli cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "$PREFIX" \
            --query 'MetricAlarms[].AlarmName' --output text | tr -d '\r')
  for n in $names; do [ "$n" = None ] || mutate "delete alarm $n" cloudwatch delete-alarms --region "$REGION" --alarm-names "$n"; done
  mutate "delete anomaly model of GatewayRequests" cloudwatch delete-anomaly-detector --region "$REGION" \
    --single-metric-anomaly-detector "Namespace=Nexus/Gateway,MetricName=GatewayRequests,Stat=Sum" || true
  mutate "delete dashboard $DASHBOARD" cloudwatch delete-dashboards --region "$REGION" --dashboard-names "$DASHBOARD" || true

  log "Deleting metric filters named $PREFIX*"
  for lg in "${API_GROUPS[@]}" "${ADAPTER_GROUPS[@]}" "${MNGR_GROUPS[@]}"; do
    names=$(aws_cli logs describe-metric-filters --region "$REGION" --log-group-name "$lg" \
              --filter-name-prefix "$PREFIX" --query 'metricFilters[].filterName' --output text | tr -d '\r')
    for n in $names; do [ "$n" = None ] || mutate "delete filter $n on $lg" logs delete-metric-filter --region "$REGION" --log-group-name "$lg" --filter-name "$n"; done
  done
}

# ---------------------------------------------------------------- main

command -v aws > /dev/null || die "aws cli not found"
command -v jq  > /dev/null || die "jq not found"
[ "$DRY_RUN" = 1 ] && log "DRY-RUN: patterns are tested and the plan printed, nothing is created or deleted (DRY_RUN=0 to apply)"
log "Region $REGION, account from the AWS credentials in the environment"

case "${1:-}" in
  create|filters|delete) ;;
  dashboard) create_dashboard; exit 0 ;;
  *) die "usage: $0 create|filters|dashboard|delete   (DRY_RUN=0 to apply)" ;;
esac
log "Checking which log groups exist in this account"
load_existing_groups
keep_existing API_GROUPS
keep_existing ADAPTER_GROUPS
keep_existing MNGR_GROUPS
log "  using ${#API_GROUPS[@]} gateway, ${#ADAPTER_GROUPS[@]} adapter and ${#MNGR_GROUPS[@]} mngr log groups"

case "$1" in
  create) create_all ;;
  filters) create_filters; log "Done. Only metric filters were touched." ;;
  delete) delete_all ;;
  *) die "usage: $0 create|filters|dashboard|delete   (DRY_RUN=0 to apply)" ;;
esac
