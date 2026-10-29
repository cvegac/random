#!/usr/bin/env bash
# Looks up services in the soap-services-proxy-config table and prints, per matching item:
# keys, file references (.xsd/.groovy/s3://), hash-like values and enable/status flags.
# Read-only: a single scan of the table (small config table), everything else is local.
#
# Usage: ./check_proxy_config.sh <service> [service ...]   (a name, or part of serviceId / idProxy)
# Output: stdout report + results/proxy_config_<ts>/ (raw scan, items, one JSON per service)
# Env: AWS_REGION, TABLE, OUT
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

REGION="${AWS_REGION:-us-east-1}"
TABLE="${TABLE:-soap-services-proxy-config}"
OUT="${OUT:-results/proxy_config_$(date +%Y%m%d_%H%M%S)}"

die() { echo "Error: $*" >&2; exit 1; }
[ $# -gt 0 ] || die "usage: $0 <service> [service ...]"
SERVICES=("$@")
command -v aws >/dev/null || die "aws cli not found"
command -v jq  >/dev/null || die "jq not found"
mkdir -p "$OUT"

echo "Scanning $TABLE in $REGION ..." >&2
aws --no-verify-ssl dynamodb scan --region "$REGION" --table-name "$TABLE" --output json \
    > "$OUT/raw_scan.json" 2> "$OUT/aws_stderr.log" \
  || { awk '!/InsecureRequestWarning/ && !/warnings\.warn\(/' "$OUT/aws_stderr.log" >&2; die "scan failed"; }

# DynamoDB JSON -> plain JSON (numbers kept as strings)
jq '
  def un: if type != "object" then .
    elif has("S") then .S elif has("N") then .N elif has("BOOL") then .BOOL elif has("NULL") then null
    elif has("M") then .M | map_values(un) elif has("L") then .L | map(un)
    elif has("SS") then .SS elif has("NS") then .NS elif has("B") then "<binary>"
    else . end;
  [.Items[] | map_values(un)]' < "$OUT/raw_scan.json" > "$OUT/items.json"

total=$(jq length < "$OUT/items.json")
echo "Items in table: $total" >&2
echo

for s in "${SERVICES[@]}"; do
  jq --arg s "$s" '[.[] | select(((.serviceId // "") + " " + (.idProxy // "")) | contains($s))]' \
     < "$OUT/items.json" > "$OUT/$s.json"
  n=$(jq length < "$OUT/$s.json")
  echo "=================================================================="
  echo "$s: $n item(s)"
  [ "$n" -gt 0 ] || { echo "  NOT FOUND in $TABLE (neither serviceId nor idProxy contains it)"; echo; continue; }

  jq -r '
    .[] |
    [paths(type == "string" or type == "boolean" or type == "number") as $p
      | {k: ($p | map(tostring) | join(".")), v: getpath($p)}] as $leaves |
    "--- idProxy=\(.idProxy // "?")  serviceId=\(.serviceId // "?")",
    "  attributes: \(keys | join(", "))",
    ($leaves[] | select((.v | type) == "string" and (.v | test("\\.(xsd|groovy|wsdl)$|^s3://"; "i")))
      | "  file    \(.k) = \(.v)"),
    ($leaves[] | select((.k | test("hash|checksum|md5|sha"; "i"))
                        or ((.v | type) == "string" and (.v | test("^([0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))))
      | "  hash    \(.k) = \(.v)"),
    ($leaves[] | select(.k | test("enabl|activ|status|estado|disabl"; "i"))
      | "  flag    \(.k) = \(.v)"),
    ""' < "$OUT/$s.json"
done

echo "=================================================================="
echo "Version check (is 9.9.9 normal in this table?)"
jq -r '
  [.[] | (.serviceId // "") | capture(":(?<v>[0-9][0-9.]*)$").v // "no-version"]
  | group_by(.) | map({v: .[0], n: length}) | sort_by(-.n)[]
  | "  \(.v): \(.n) item(s)"' < "$OUT/items.json"
echo
echo "Full items saved in $OUT/<service>.json" >&2
