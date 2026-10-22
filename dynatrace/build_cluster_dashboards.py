"""Generate one Dynatrace dashboard per Nexus cluster from dynatrace/Nexus.json.

    python dynatrace/build_cluster_dashboards.py

Nexus.json is the template: edit it, then rerun this script and commit the regenerated files under
dynatrace/clusters/. Never edit the generated files by hand, they get overwritten.

Each cluster dashboard is the template with the Cluster variable removed and its filter fixed to that cluster;
the "errors per cluster" tile becomes "errors per service". Servicio, Canal and Rquid stay as variables.
"""
import copy
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "Nexus.json"
OUT_DIR = HERE / "clusters"

CLUSTER_FILTER = 'in("*", $Cluster) or in(concat(cluster, "ws"), $Cluster)'
HEADER_CLUSTER_SENTENCE = "Cluster: uno, varios o `*` = todos. "
PER_CLUSTER_TILE = "ERRORES ADAPTADOR POR CLUSTER"
PER_CLUSTER_TAIL = '| fieldsAdd cluster = concat(cluster, "ws")\n| makeTimeseries errors = count(), by: { cluster }'
PER_SERVICE_TAIL = ("| parse content, \"LD 'X-Referer=' LD:referer ','\"\n"
                    '| fieldsAdd service = splitString(referer, "-")[3]\n'
                    "| makeTimeseries errors = count(), by: { service }")


def fix_cluster(text, prefix):
    # the log group parse yields the cluster without its "ws" suffix (accountsws -> accounts)
    return text.replace(CLUSTER_FILTER, f'cluster == "{prefix}"')


def build(template, cluster):
    prefix = cluster.removesuffix("ws")
    dash = copy.deepcopy(template)
    dash["variables"] = [v for v in dash["variables"] if v["key"] != "Cluster"]
    for var in dash["variables"]:
        if var.get("type") == "query":
            var["input"] = fix_cluster(var["input"], prefix)
    for tile in dash["tiles"].values():
        if tile.get("type") == "markdown" and tile["content"].startswith("## Nexus\n"):
            assert HEADER_CLUSTER_SENTENCE in tile["content"]
            tile["content"] = (tile["content"].replace("## Nexus\n", f"## Nexus · {cluster}\n", 1)
                               .replace(HEADER_CLUSTER_SENTENCE, ""))
        if "query" in tile:
            tile["query"] = fix_cluster(tile["query"], prefix)
        if tile.get("title") == PER_CLUSTER_TILE:
            assert tile["query"].endswith(PER_CLUSTER_TAIL)
            tile["query"] = tile["query"].removesuffix(PER_CLUSTER_TAIL) + PER_SERVICE_TAIL
            tile["title"] = "ERRORES ADAPTADOR POR SERVICIO"
    text = json.dumps(dash, ensure_ascii=False, indent=2)
    assert "$Cluster" not in text, f"{cluster}: a $Cluster reference was not replaced"
    return text + "\n"


def main():
    template = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    cluster_var = next(v for v in template["variables"] if v["key"] == "Cluster")
    clusters = [c for c in cluster_var["input"].split(",") if c != "*"]
    OUT_DIR.mkdir(exist_ok=True)
    for cluster in clusters:
        (OUT_DIR / f"Nexus-{cluster}.json").write_text(build(template, cluster), encoding="utf-8", newline="\n")
    print(f"{len(clusters)} dashboards in {OUT_DIR}")


if __name__ == "__main__":
    main()
