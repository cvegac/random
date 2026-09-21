#!/usr/bin/env bash
# Extrae las transacciones completas (por RQID) que tuvieron ERROR en CloudWatch Logs,
# agrupadas por servicio, en un CSV por servicio.
#
#   Paso 1: en los 11 log groups *-mngr busca @message like 'ERROR' y extrae el RQID + @log.
#   Paso 2: por cada @log, trae TODAS las lineas de esos RQIDs, consultando solo su log group
#           (y su companero *-stratus-adapter, si existe).
#   Paso 3: clasifica cada RQID por servicio y escribe un CSV por servicio.
#
# Uso:    ./extraer_trazas_error.sh "2026-09-21 15:00:00" "2026-09-21 15:30:00"
#         (horas en hora local de Colombia, UTC-5)
# Salida: resultados/<fechaini>_<horaini>__<fechafin>_<horafin>/<servicio>.csv
#
# Requiere: aws cli v2 (con credenciales/perfil activo: AWS_PROFILE), jq, gawk/awk, GNU date.
# Variables opcionales: AWS_REGION, OUT_BASE, BATCH_SIZE, PAD_SECONDS, ERROR_PATTERN,
#                       SERVICE_REGEX, OPERATION_REGEX
set -euo pipefail

# Git Bash en Windows convierte "/aws/ecs/..." en una ruta C:\... ; esto lo evita.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

REGION="${AWS_REGION:-us-east-1}"
OUT_BASE="${OUT_BASE:-resultados}"
BATCH_SIZE="${BATCH_SIZE:-100}"          # RQIDs por query en el paso 2 (limite de query: 10.000 chars)
PAD_SECONDS="${PAD_SECONDS:-300}"        # margen antes/despues de la ventana para el paso 2
ERROR_PATTERN="${ERROR_PATTERN:-ERROR}"
# Como se determina el "servicio" de cada RQID (se prueba en orden sobre TODAS las lineas del RQID):
SERVICE_REGEX="${SERVICE_REGEX:-/ESBService/([A-Za-z0-9_]+)}"
OPERATION_REGEX="${OPERATION_REGEX:-<nombreOperacion>([^<]+)</nombreOperacion>}"
TZ_OFFSET="-05:00"                       # Colombia
TZ_OFFSET_SECONDS=-18000

LOG_GROUPS=(
  /aws/ecs/srv/productsws-mngr
  /aws/ecs/srv/accountsws-mngr
  /aws/ecs/srv/acquiringws-mngr
  /aws/ecs/srv/clientsws-mngr
  /aws/ecs/srv/credit-cardsws-mngr
  /aws/ecs/srv/insurancesws-mngr
  /aws/ecs/srv/investmentsws-mngr
  /aws/ecs/srv/loansws-mngr
  /aws/ecs/srv/paymentsws-mngr
  /aws/ecs/srv/remittancesws-mngr
  /aws/ecs/srv/securityws-mngr
)

# Log group companero de cada *-mngr. AJUSTAR si el nombre real es distinto.
companion_group() { printf '%s-stratus-adapter' "${1%-mngr}"; }

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "uso: $0 \"YYYY-MM-DD HH:MM:SS\" \"YYYY-MM-DD HH:MM:SS\"  (hora Colombia)"
command -v aws >/dev/null || die "falta aws cli"
command -v jq  >/dev/null || die "falta jq"

to_epoch()   { date -d "$1 ${TZ_OFFSET}" +%s 2>/dev/null || die "fecha invalida: '$1'"; }
to_label()   { date -d "$1" +%Y%m%d_%H%M%S; }

START=$(to_epoch "$1")
END=$(to_epoch "$2")
[ "$START" -lt "$END" ] || die "la hora de inicio debe ser menor a la final"

OUT_DIR="${OUT_BASE}/$(to_label "$1")__$(to_label "$2")"
TMP="${OUT_DIR}/_intermedios"
mkdir -p "$TMP"

F_RQIDS="$TMP/1_rqids_con_error.tsv"
F_TRAZAS="$TMP/2_trazas.ndjson"
F_CLASIF="$TMP/3_clasificado.ndjson"

# ---------------------------------------------------------------- helpers

# run_query "<query>" <start_epoch> <end_epoch> <log group>...   -> imprime el JSON de resultados
run_query() {
  local query="$1" start="$2" end="$3"; shift 3
  local qid res status
  qid=$(aws logs start-query --region "$REGION" \
          --start-time "$start" --end-time "$end" \
          --query-string "$query" --log-group-names "$@" \
          --query queryId --output text | tr -d '\r')
  while :; do
    res=$(aws logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) die "la query $qid termino en estado $status" ;;
    esac
    sleep 2
  done
  printf '%s' "$res"
}

group_exists() {
  local found
  found=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$1" \
            --query "logGroups[?logGroupName=='$1'].logGroupName" --output text | tr -d '\r')
  [ -n "$found" ]
}

# Convierte results[] de Logs Insights en objetos {campo: valor}
FLAT='.results[] | (map({(.field): .value}) | add)'

# ---------------------------------------------------------------- paso 1

step1_rqids_con_error() {
  log "Paso 1: buscando RQIDs con '${ERROR_PATTERN}' en ${#LOG_GROUPS[@]} log groups"
  local q1
  read -r -d '' q1 <<EOF || true
fields @timestamp, @message, @log
| filter @message like '${ERROR_PATTERN}'
| parse @message /\[(?<rqid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/
| filter ispresent(rqid)
| stats count(*) as ocurrencias by rqid, @log
| limit 10000
EOF
  run_query "$q1" "$START" "$END" "${LOG_GROUPS[@]}" > "$TMP/1_errores.json"

  jq -r "$FLAT | [.rqid, (.[\"@log\"] | sub(\"^[0-9]+:\"; \"\")), .ocurrencias] | @tsv" \
     < "$TMP/1_errores.json" | tr -d '\r' > "$F_RQIDS"

  local n; n=$(awk 'END {print NR}' "$F_RQIDS")
  [ "$n" -lt 10000 ] || log "ATENCION: 10.000 filas, el resultado pudo truncarse. Acota la ventana de tiempo."
  log "  -> $n pares (RQID, log group) con error"
  [ "$n" -gt 0 ] || { log "No hay errores en la ventana. Fin."; exit 0; }
}

# ---------------------------------------------------------------- paso 2

step2_trazas_completas() {
  log "Paso 2: trayendo transacciones completas por log group"
  : > "$F_TRAZAS"
  local groups g comp targets ids i slice regex idsjson q n
  mapfile -t groups < <(cut -f2 "$F_RQIDS" | sort -u)

  for g in "${groups[@]}"; do
    targets=("$g")
    comp=$(companion_group "$g")
    if group_exists "$comp"; then targets+=("$comp"); else log "  (sin companero: $comp, solo se consulta $g)"; fi

    mapfile -t ids < <(awk -F'\t' -v g="$g" '$2 == g {print $1}' "$F_RQIDS")
    log "  $g: ${#ids[@]} RQIDs -> ${targets[*]}"

    for ((i = 0; i < ${#ids[@]}; i += BATCH_SIZE)); do
      slice=("${ids[@]:i:BATCH_SIZE}")
      regex=$(IFS='|'; printf '%s' "${slice[*]}")
      idsjson=$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s -c . | tr -d '\r')
      q="fields @timestamp, @log, @logStream, @message
| filter @message like /${regex}/
| sort @timestamp asc
| limit 10000"

      run_query "$q" "$((START - PAD_SECONDS))" "$((END + PAD_SECONDS))" "${targets[@]}" > "$TMP/2_batch.json"

      # Asigna a cada linea el RQID (de la lista) que contiene su mensaje
      jq -c --argjson ids "$idsjson" "$FLAT"' as $r
            | $r["@message"] as $m
            | ($ids | map(select(. as $id | $m | contains($id))) | first) as $rq
            | select($rq != null)
            | {ts: $r["@timestamp"], rqid: $rq,
               log: ($r["@log"] | sub("^[0-9]+:"; "")),
               stream: $r["@logStream"], message: $m}' \
         < "$TMP/2_batch.json" | tr -d '\r' >> "$F_TRAZAS"

      n=$(jq '.results | length' < "$TMP/2_batch.json" | tr -d '\r')
      [ "$n" -lt 10000 ] || log "  ATENCION: lote con 10.000 filas (truncado). Baja BATCH_SIZE."
    done
  done
  log "  -> $(awk 'END {print NR}' "$F_TRAZAS") lineas de traza recolectadas"
}

# ---------------------------------------------------------------- paso 3

step3_agrupar_por_servicio() {
  log "Paso 3: agrupando por servicio -> $OUT_DIR"
  [ -s "$F_TRAZAS" ] || { log "No se recolectaron trazas. Fin."; exit 0; }

  # Servicio por RQID: SERVICE_REGEX, si no OPERATION_REGEX, si no SIN_SERVICIO
  jq -s -c --arg re1 "$SERVICE_REGEX" --arg re2 "$OPERATION_REGEX" '
    def first_match($re): [ .[] | .message | scan($re) | (if type == "array" then .[0] else . end) ] | first;
    group_by(.rqid)
    | map( (first_match($re1) // first_match($re2) // "SIN_SERVICIO") as $svc
           | map(. + {servicio: $svc}) )
    | add | .[]' < "$F_TRAZAS" | tr -d '\r' > "$F_CLASIF"

  local servicios svc safe out
  mapfile -t servicios < <(jq -s -r '[.[].servicio] | unique | .[]' < "$F_CLASIF" | tr -d '\r')

  for svc in "${servicios[@]}"; do
    safe=$(printf '%s' "$svc" | tr -c 'A-Za-z0-9_.\n-' '_')
    out="$OUT_DIR/${safe}.csv"
    {
      echo 'hora_colombia,timestamp_utc,rqid,log_group,log_stream,mensaje'
      jq -s -r --arg s "$svc" --argjson off "$TZ_OFFSET_SECONDS" '
        def col: (.[0:19] | strptime("%Y-%m-%d %H:%M:%S") | mktime + $off | strftime("%Y-%m-%d %H:%M:%S")) + .[19:];
        [ .[] | select(.servicio == $s) ] | sort_by(.rqid, .ts) | .[]
        | [ (.ts | col), .ts, .rqid, .log, .stream, (.message | gsub("[\r\n]+"; " ")) ] | @csv' < "$F_CLASIF"
    } | tr -d '\r' > "$out"
    log "  $(basename "$out")"
  done

  {
    echo 'servicio,rqids_con_error,lineas'
    jq -s -r 'group_by(.servicio) | .[] | [.[0].servicio, (map(.rqid) | unique | length), length] | @csv' < "$F_CLASIF"
  } | tr -d '\r' > "$OUT_DIR/_resumen.csv"
}

step1_rqids_con_error
step2_trazas_completas
step3_agrupar_por_servicio

log "Listo -> $OUT_DIR (resumen en _resumen.csv)"
