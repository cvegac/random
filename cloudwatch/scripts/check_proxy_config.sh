#!/usr/bin/env bash
# Diagnoses why the ESB (mngr) skips or disables services when it loads its cache:
#   "Servicio ignorado y no cargado en caché: xsd no disponible"   -> XSD missing, wrong name/case, bad imports
#   "Servicio deshabilitado por diferencias en el hash del groovy" -> scriptHash in DynamoDB != groovy in S3
# Read-only:
#   1. scan the soap-services-proxy-config table and pick the items of the given services
#   2. list the bucket and download its .xsd/.groovy files
#   3. per item: XSD at <idProxy>/<xsdFileName> (case-sensitive, like S3) and its schemaLocation imports;
#      which groovy in the bucket has the item's scriptHash (raw file, LF or CRLF line endings)
#   4. the error lines of the last LOOKBACK_HOURS in the mngr log groups of those idProxy
#
# Usage: BUCKET=<xsd bucket> ./check_proxy_config.sh <service> [service ...]   (part of serviceId / idProxy)
# Output: stdout report + $OUT (raw scan, items, bucket copy, hashes.tsv, report.txt)
# Env: BUCKET (required), AWS_REGION, TABLE, OUT, LOOKBACK_HOURS
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

REGION="${AWS_REGION:-us-east-1}"
TABLE="${TABLE:-soap-services-proxy-config}"
BUCKET="${BUCKET:-}"
OUT="${OUT:-results/proxy_config_$(date +%Y%m%d_%H%M%S)}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
ERROR_REGEX='Servicio ignorado|Servicio deshabilitado'

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

[ $# -gt 0 ] || die "usage: BUCKET=<xsd bucket> $0 <service> [service ...]"
[ -n "$BUCKET" ] || die "set BUCKET (the S3 bucket with the .xsd and .groovy files)"
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
SERVICES=("$@")

# native Windows aws/jq can't open /c/... paths
case "$OUT" in /*) OUT=$(cygpath -m "$OUT" 2>/dev/null || printf '%s' "$OUT") ;; esac
mkdir -p "$OUT"

# aws wrapper: --no-verify-ssl and drop the urllib3 warnings from stderr
aws_cli() {
  local err rc=0
  err=$(mktemp)
  aws --no-verify-ssl "$@" 2> "$err" || rc=$?
  awk '!/InsecureRequestWarning/ && !/warnings\.warn\(/ && NF' "$err" | tr -d '\r' >&2
  rm -f "$err"
  return "$rc"
}

# ---------------------------------------------------------------- data

log "Scanning $TABLE in $REGION ..."
aws_cli dynamodb scan --region "$REGION" --table-name "$TABLE" --output json > "$OUT/raw_scan.json" \
  || die "scan failed"

# DynamoDB JSON -> plain JSON (numbers kept as strings)
jq '
  def un: if type != "object" then .
    elif has("S") then .S elif has("N") then .N elif has("BOOL") then .BOOL elif has("NULL") then null
    elif has("M") then .M | map_values(un) elif has("L") then .L | map(un)
    elif has("SS") then .SS elif has("NS") then .NS elif has("B") then "<binary>"
    else . end;
  [.Items[] | map_values(un)]' < "$OUT/raw_scan.json" > "$OUT/items.json"

services_json=$(printf '%s\n' "${SERVICES[@]}" | jq -R . | jq -s -c . | tr -d '\r')
jq --argjson s "$services_json" '
  [.[] | . as $i | ((.serviceId // "") + " " + (.idProxy // "")) as $k
   | select(any($s[]; . as $n | $k | contains($n)))]' < "$OUT/items.json" > "$OUT/selected.json"

log "Listing s3://$BUCKET ..."
aws_cli s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --query 'Contents[].Key' --output json \
  > "$OUT/keys.json" || die "bucket listing failed"
jq -r '.[]?' < "$OUT/keys.json" | tr -d '\r' > "$OUT/keys.txt"

log "Downloading the .xsd and .groovy files ($(awk 'END {print NR}' "$OUT/keys.txt") objects in the bucket) ..."
aws_cli s3 sync "s3://$BUCKET" "$OUT/bucket" --region "$REGION" --only-show-errors \
  --exclude '*' --include '*.xsd' --include '*.groovy' || die "download failed"

log "Hashing the groovy files ..."
sha() { sha256sum | cut -d' ' -f1; }
while IFS= read -r key; do
  case "$key" in *.groovy) ;; *) continue ;; esac
  f="$OUT/bucket/$key"
  [ -f "$f" ] || continue
  printf '%s\traw\t%s\n'  "$key" "$(sha < "$f")"
  printf '%s\tLF\t%s\n'   "$key" "$(tr -d '\r' < "$f" | sha)"
  printf '%s\tCRLF\t%s\n' "$key" "$(tr -d '\r' < "$f" | awk '{printf "%s\r\n", $0}' | sha)"
done < "$OUT/keys.txt" > "$OUT/hashes.tsv"

# ---------------------------------------------------------------- checks

key_exists() { grep -qxF -- "$1" "$OUT/keys.txt"; }

# keys with the same file name ignoring case and folder
similar() {
  local base found
  base=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')
  found=$(awk -v b="$base" '{n = $0; sub(/.*\//, "", n); if (tolower(n) == b) print}' "$OUT/keys.txt" | paste -sd' ' -)
  [ -z "$found" ] || printf '  -> same name ignoring case/folder: %s' "$found"
}

# resolve ./ and ../ in a key
normalize() {
  awk -v p="$1" 'BEGIN { n = split(p, a, "/"); k = 0
    for (i = 1; i <= n; i++) { if (a[i] == "." || a[i] == "") continue; if (a[i] == "..") { if (k > 0) k--; continue }; o[++k] = a[i] }
    s = o[1]; for (i = 2; i <= k; i++) s = s "/" o[i]; print s }'
}

# xmllint only: powershell.exe from Git Bash can fail or read the loop's stdin and cut the report short
xml_check() {
  local res
  command -v xmllint >/dev/null || return 0
  if res=$(xmllint --noout "$1" 2>&1 < /dev/null); then echo "    well-formed"; else echo "    NOT well-formed: $res"; fi
}

check_xsd() {
  local idp="$1" xsd="$2" key loc imp
  [ -n "$xsd" ] || { echo "  XSD     no .xsd file name in the item"; return 0; }
  key="$idp/$xsd"
  if ! key_exists "$key"; then
    echo "  XSD     MISSING $key$(similar "$key")"
    return 0
  fi
  echo "  XSD     OK      $key"
  xml_check "$OUT/bucket/$key"
  while IFS= read -r loc; do
    case "$loc" in http*|'') continue ;; esac
    imp=$(normalize "${key%/*}/$loc")
    if key_exists "$imp"; then echo "    import OK      $imp"; else echo "    import MISSING $imp$(similar "$imp")"; fi
  done < <(grep -oE 'schemaLocation="[^"]+"' "$OUT/bucket/$key" | cut -d'"' -f2 | tr -d '\r' || true)
}

check_groovy() {
  local hash="$1" name="$2" refs="$3" m r prefix
  if [ -z "$hash" ]; then
    echo "  GROOVY  no scriptHash in the item"
  else
    hash=$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')
    m=$(awk -F'\t' -v h="$hash" '$3 == h {print $1 " (" $2 ")"}' "$OUT/hashes.tsv" | paste -sd';' -)
    if [ -n "$m" ]; then echo "  GROOVY  scriptHash ${hash:0:16}... matches: $m"
    else echo "  GROOVY  scriptHash ${hash:0:16}... matches NO groovy in the bucket"; fi
  fi
  for r in $refs; do
    if key_exists "$r"; then echo "  groovy ref OK      $r"; else echo "  groovy ref MISSING $r$(similar "$r")"; fi
  done
  # groovies whose name starts like the service, to compare by eye
  prefix=$(printf '%s' "${name:0:10}" | tr '[:upper:]' '[:lower:]')
  [ -n "$prefix" ] || return 0
  awk -F'\t' -v p="$prefix" '{n = $1; sub(/.*\//, "", n)} index(tolower(n), p) == 1 && $2 != "CRLF" {printf "    candidate %-50s %-4s %s...\n", $1, $2, substr($3, 1, 16)}' "$OUT/hashes.tsv"
}

check_items() {
  local s item idp sid xsd hash name refs
  echo "Table $TABLE: $(jq length < "$OUT/items.json") items, $(jq length < "$OUT/selected.json") for: ${SERVICES[*]}"
  echo "Bucket $BUCKET: $(awk 'END {print NR}' "$OUT/keys.txt") objects"
  echo "Hash match: (raw) file identical; (LF)/(CRLF) only matches after changing the line endings"
  for s in "${SERVICES[@]}"; do
    jq -e --arg s "$s" 'any(.[]; ((.serviceId // "") + " " + (.idProxy // "")) | contains($s))' \
      < "$OUT/items.json" >/dev/null || echo "NOT IN TABLE: $s"
  done
  echo

  while IFS= read -r item; do
    idp=$(jq -r '.idProxy // ""' <<<"$item" | tr -d '\r')
    sid=$(jq -r '.serviceId // ""' <<<"$item" | tr -d '\r')
    xsd=$(jq -r '[paths(type == "string") as $p | getpath($p) | select(test("\\.xsd$"; "i"))] | first // ""' <<<"$item" | tr -d '\r')
    hash=$(jq -r '[paths(type == "string") as $p | select($p[-1] | tostring | test("hash"; "i")) | getpath($p)] | first // ""' <<<"$item" | tr -d '\r')
    # groovy keys: values ending in .groovy, or scriptFileName (stored without the extension)
    refs=$(jq -r '[paths(type == "string") as $p | {k: ($p[-1] | tostring), v: getpath($p)}
                   | if (.v | test("\\.groovy$"; "i")) then .v elif (.k | test("^scriptFile"; "i")) then .v + ".groovy" else empty end]
                  | unique | join(" ")' <<<"$item" | tr -d '\r')
    name=$(jq -r '(.serviceId // "") | sub(":[^:/]*$"; "") | split("/") | map(select(. != "" and (test("^V[0-9]+$") | not))) | last // ""' <<<"$item" | tr -d '\r')
    echo "=================================================================="
    echo "$sid  (idProxy=$idp)"
    echo "  servicesList: $(jq -c '.servicesList // {}' <<<"$item" | tr -d '\r')"
    check_xsd "$idp" "$xsd"
    check_groovy "$hash" "$name" "$refs"
    echo
  done < <(jq -c '.[]' < "$OUT/selected.json" | tr -d '\r')
}

fetch_errors() {
  local groups=() end start q qid res status
  mapfile -t groups < <(jq -r '[.[].idProxy // empty | sub("_[0-9]+$"; "") | "/aws/ecs/srv/\(.)-mngr"] | unique[]' \
                          < "$OUT/selected.json" | tr -d '\r')
  [ ${#groups[@]} -gt 0 ] || return 0
  echo "=================================================================="
  echo "Error lines, last ${LOOKBACK_HOURS}h (UTC) in: ${groups[*]}"
  end=$(date +%s); start=$((end - LOOKBACK_HOURS * 3600))
  q="filter @message like /${ERROR_REGEX}/
| parse @message /(?<msg>Servicio [di][a-z]+ .*)/
| stats count(*) as hits, min(@timestamp) as first_seen, max(@timestamp) as last_seen by @log, msg
| sort last_seen desc
| limit 200"
  qid=$(aws_cli logs start-query --region "$REGION" --start-time "$start" --end-time "$end" \
          --query-string "$q" --log-group-names "${groups[@]}" --query queryId --output text | tr -d '\r') \
    || { echo "  query failed (see the error above)"; return 0; }
  while :; do
    res=$(aws_cli logs get-query-results --region "$REGION" --query-id "$qid" --output json)
    status=$(jq -r .status <<<"$res" | tr -d '\r')
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) echo "  query ended with status $status"; return 0 ;;
    esac
    sleep 2
  done
  printf '%s' "$res" > "$OUT/error_lines.json"
  if [ "$(jq '.results | length' <<<"$res" | tr -d '\r')" = 0 ]; then
    echo "  none (the cache is loaded at startup: raise LOOKBACK_HOURS to cover the last deploy)"
    return 0
  fi
  jq -r '.results[] | (map({(.field): .value}) | add)
         | "  \(.hits)x  \(.first_seen) .. \(.last_seen)  \(.["@log"] | sub("^[0-9]+:"; ""))\n      \(.msg)"' \
     <<<"$res" | tr -d '\r'
}

{ check_items; fetch_errors; } | tee "$OUT/report.txt"
log "Report and files in $OUT"
