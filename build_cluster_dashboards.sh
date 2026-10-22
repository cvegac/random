#!/usr/bin/env bash
# Generates one Dynatrace dashboard per Nexus cluster from a template dashboard JSON.
#
#   ./build_cluster_dashboards.sh                      # dynatrace/Nexus.json -> results/dynatrace_clusters/
#   ./build_cluster_dashboards.sh -t export.json       # another template (e.g. a fresh export from the tenant)
#   ./build_cluster_dashboards.sh -o out_dir           # another output folder
#
# The template is the all-clusters Nexus dashboard: it must have the multi-select `Cluster` variable, whose
# values (minus "*") are the clusters to build. Default: dynatrace/Nexus.json next to this script.
# For each cluster it writes <out_dir>/Nexus-<cluster>.json:
#   - the Cluster variable is removed and every `$Cluster` filter is fixed to that cluster
#     (also inside the Servicio/Canal query variables, so their lists only show that cluster)
#   - the header becomes "## Nexus · <cluster>" without the Cluster hint
#   - "ERRORES ADAPTADOR POR CLUSTER" becomes "ERRORES ADAPTADOR POR SERVICIO" (one cluster = one line)
# Optional env var: CLUSTERS="accountsws productsws" builds only those.
# Needs: jq.

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }
usage() { echo "usage: $0 [-t template.json] [-o out_dir]" >&2; exit 1; }

DEFAULT_TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dynatrace/Nexus.json"

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

main() {
  local template="$DEFAULT_TEMPLATE" out_dir="results/dynatrace_clusters" opt
  while getopts "t:o:h" opt; do
    case "$opt" in
      t) template="$OPTARG" ;;
      o) out_dir="$OPTARG" ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))
  [ $# -eq 0 ] || usage
  command -v jq >/dev/null || die "jq is required"

  [ -f "$template" ] || die "template not found: $template (use -t)"
  local tpl
  tpl=$(mktemp)
  trap "rm -f '$tpl'" EXIT   # expanded now: $tpl is local and gone when the EXIT trap runs
  cat "$template" > "$tpl"   # jq reads it from stdin: Git Bash may hand absolute paths to jq.exe unconverted

  # Fed through stdin: Git Bash may hand absolute paths to jq.exe unconverted.
  jq -e '.variables[]? | select(.key == "Cluster")' < "$tpl" >/dev/null \
    || die "the template has no Cluster variable"

  local clusters="${CLUSTERS:-}"
  if [ -z "$clusters" ]; then
    clusters=$(jq -r '.variables[] | select(.key == "Cluster") | .input | split(",") | map(select(. != "*")) | join(" ")' \
                 < "$tpl" | tr -d '\r')
  fi
  [ -n "$clusters" ] || die "no clusters found in the Cluster variable"

  mkdir -p "$out_dir"
  local n=0 cluster out
  for cluster in $clusters; do
    out="$out_dir/Nexus-$cluster.json"
    # the log group parse yields the cluster without its "ws" suffix (accountsws -> accounts)
    jq --arg cluster "$cluster" --arg prefix "${cluster%ws}" "$FILTER" < "$tpl" > "$out"
    if grep -q '\$Cluster' "$out"; then
      die "$out still references \$Cluster: the template filters the cluster in a way this script doesn't know"
    fi
    if grep -q 'ERRORES ADAPTADOR POR CLUSTER' "$out"; then
      echo "Warning: $out kept the per-cluster errors tile (its query no longer matches the expected shape)" >&2
    fi
    n=$((n + 1))
  done
  echo "$n dashboards in $out_dir (template: $template)"
}

main "$@"
