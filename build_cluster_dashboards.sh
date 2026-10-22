#!/usr/bin/env bash
# Generates one Dynatrace dashboard per Nexus cluster from a template dashboard JSON.
#
#   ./build_cluster_dashboards.sh <template.json> [out_dir]
#
# The template is the all-clusters Nexus dashboard (e.g. dynatrace/Nexus.json or a fresh export from the
# tenant): it must have the multi-select `Cluster` variable, whose values (minus "*") are the clusters to build.
# For each cluster it writes <out_dir>/Nexus-<cluster>.json (default out_dir: results/dynatrace_clusters):
#   - the Cluster variable is removed and every `$Cluster` filter is fixed to that cluster
#     (also inside the Servicio/Canal query variables, so their lists only show that cluster)
#   - the header becomes "## Nexus · <cluster>" without the Cluster hint
#   - "ERRORES ADAPTADOR POR CLUSTER" becomes "ERRORES ADAPTADOR POR SERVICIO" (one cluster = one line)
# Optional env var: CLUSTERS="accountsws productsws" builds only those.
# Needs: jq.

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <template.json> [out_dir]"
TEMPLATE="$1"
OUT_DIR="${2:-results/dynatrace_clusters}"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
command -v jq >/dev/null || die "jq is required"

# Fed through stdin: Git Bash may hand absolute paths to jq.exe unconverted.
jq -e '.variables[]? | select(.key == "Cluster")' < "$TEMPLATE" >/dev/null \
  || die "the template has no Cluster variable"

if [ -z "${CLUSTERS:-}" ]; then
  CLUSTERS=$(jq -r '.variables[] | select(.key == "Cluster") | .input | split(",") | map(select(. != "*")) | join(" ")' \
               < "$TEMPLATE" | tr -d '\r')
fi
[ -n "$CLUSTERS" ] || die "no clusters found in the Cluster variable"

mkdir -p "$OUT_DIR"

# shellcheck disable=SC2016  # $Cluster is DQL, not shell
FILTER='def repl($a; $b): split($a) | join($b);
  ("in(\"*\", $Cluster) or in(concat(cluster, \"ws\"), $Cluster)") as $old
  | ("cluster == \"" + $prefix + "\"") as $new
  | ("| fieldsAdd cluster = concat(cluster, \"ws\")\n| makeTimeseries errors = count(), by: { cluster }") as $perCluster
  | ("| parse content, \"LD '"'"'X-Referer='"'"' LD:referer '"'"','"'"'\"\n| fieldsAdd service = splitString(referer, \"-\")[3]\n| makeTimeseries errors = count(), by: { service }") as $perService
  | .variables |= map(select(.key != "Cluster") | if .type == "query" then .input |= repl($old; $new) else . end)
  | .tiles |= map_values(
      (if .query then .query |= repl($old; $new) else . end)
      | (if .type == "markdown" and ((.content // "") | startswith("## Nexus\n"))
         then .content |= (sub("^## Nexus\n"; "## Nexus · \($cluster)\n") | repl("Cluster: uno, varios o `*` = todos. "; ""))
         else . end)
      | (if .title == "ERRORES ADAPTADOR POR CLUSTER" and (.query | endswith($perCluster))
         then .query |= (.[0:(length - ($perCluster | length))] + $perService) | .title = "ERRORES ADAPTADOR POR SERVICIO"
         else . end))'

n=0
for cluster in $CLUSTERS; do
  out="$OUT_DIR/Nexus-$cluster.json"
  # the log group parse yields the cluster without its "ws" suffix (accountsws -> accounts)
  jq --arg cluster "$cluster" --arg prefix "${cluster%ws}" "$FILTER" < "$TEMPLATE" > "$out"
  if grep -q '\$Cluster' "$out"; then
    die "$out still references \$Cluster: the template filters the cluster in a way this script doesn't know"
  fi
  grep -q 'ERRORES ADAPTADOR POR CLUSTER' "$out" \
    && echo "Warning: $out kept the per-cluster errors tile (its query no longer matches the expected shape)" >&2
  n=$((n + 1))
done
echo "$n dashboards in $OUT_DIR"
