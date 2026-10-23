"""Ray's view of the cluster for scripts/undeploy.sh: what each node has free.

Runs on the head (copied there by undeploy.sh):
    ray_resources.py [<private-ip>=<node-name> ...]
Prints CPU, GPU and memory free/total per node as Ray accounts them, plus the
Ray Serve actors still alive. The last line is "RAY_STATUS DRAINED" or
"RAY_STATUS BUSY <reasons>".
"""
import sys
from collections import Counter

import ray
from ray.util.state import list_actors

GIB = 1024 ** 3
SERVE_ACTORS = ("ServeReplica", "ServeController", "ProxyActor")


def amount(resource, free, total):
    if not total.get(resource):
        return "-"
    if resource == "memory":
        return "%.1f/%.1f GiB" % (free.get(resource, 0) / GIB, total[resource] / GIB)
    return "%g/%g" % (free.get(resource, 0), total[resource])


def main() -> int:
    names = dict(arg.split("=", 1) for arg in sys.argv[1:])
    ray.init(address="auto", logging_level="ERROR", log_to_driver=False)

    nodes = [n for n in ray.nodes() if n["Alive"]]
    try:
        from ray._private.state import available_resources_per_node
        free_by_node = available_resources_per_node()
    except Exception:   # internal API; fall back to cluster-wide totals
        free_by_node = None

    actors = list_actors(filters=[("state", "=", "ALIVE")], limit=10000, raise_on_missing_output=False)
    serve = [a for a in actors if (a.class_name or "").startswith(SERVE_ACTORS)]
    serve_by_node = Counter(a.node_id for a in serve)

    rows = []
    if free_by_node is not None:
        for n in sorted(nodes, key=lambda n: names.get(n["NodeManagerAddress"], "~" + n["NodeManagerAddress"])):
            rows.append((names.get(n["NodeManagerAddress"], n["NodeManagerAddress"]),
                         free_by_node.get(n["NodeID"], {}), n["Resources"], serve_by_node[n["NodeID"]]))
    else:
        rows.append(("cluster", ray.available_resources(), ray.cluster_resources(), len(serve)))

    print("  %-10s %-11s %-11s %-17s %s" % ("node", "CPU free", "GPU free", "memory free", "Serve actors"))
    busy = set()
    for name, free, total, n_serve in rows:
        print("  %-10s %-11s %-11s %-17s %d" % (name, amount("CPU", free, total), amount("GPU", free, total),
                                               amount("memory", free, total), n_serve))
        for resource in ("CPU", "GPU", "memory"):
            if free.get(resource, 0) < total.get(resource, 0):
                busy.add(resource + " in use")
    for a in serve:
        print("    alive: %s pid %s" % (a.class_name, a.pid))
    if serve:
        busy.add("%d Serve actor(s) alive" % len(serve))

    print("RAY_STATUS " + ("BUSY " + ", ".join(sorted(busy)) if busy else "DRAINED"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
