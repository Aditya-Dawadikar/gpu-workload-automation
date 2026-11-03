"""Prometheus service discovery for the vLLM replicas' metrics endpoints.

Runs on the Ray head as the llm-metrics-sd systemd service (installed by
remote/setup-vllm-metrics.sh) with Ray's venv Python; standard library only.

Every --interval seconds it:
  1. asks Ray Serve's REST API where the replicas of --app run (node IP, state);
  2. on each of those nodes, probes ports --port-base .. +7 for a replica's
     llm_serve_replica_info series (one port per GPU index; see app/llm_serve.py);
  3. writes the endpoints it found to --out as a Prometheus file_sd file, with
     stable target labels: application, deployment, private_ip, gpu_slot.

A target stays in the file while Serve still has a replica of the app on its
node and it answered within --keep seconds, so a replica that stops
answering shows up as up == 0 (and alerts) instead of silently vanishing.

It also serves its own metrics on --listen (127.0.0.1 only), scraped as job
"vllm-sd". llm_sd_replicas is Serve's view of the replicas, independent of
whether their metrics endpoints can be scraped.

    python vllm_metrics_sd.py --app llm --out /opt/observability/prometheus/llm/targets/vllm.json
"""
import argparse
import json
import logging
import os
import re
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Tuple

PORT_SLOTS = 8   # must match ReplicaMetrics.PORT_SLOTS in app/llm_serve.py
INFO_METRIC = "llm_serve_replica_info"
INFO_RE = re.compile(r"^" + INFO_METRIC + r"\{(?P<labels>.*)\}\s+1(\.0)?\s*$", re.M)
LABEL_RE = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')

log = logging.getLogger("vllm-metrics-sd")


def serve_replicas(dashboard: str, app: str) -> List[Dict[str, str]]:
    """[{deployment, replica_id, state, node_ip}] of `app`; [] when it isn't deployed."""
    with urllib.request.urlopen(dashboard.rstrip("/") + "/api/serve/applications/", timeout=10) as r:
        apps = json.load(r).get("applications") or {}
    out = []
    for name, dep in ((apps.get(app) or {}).get("deployments") or {}).items():
        for rep in dep.get("replicas") or []:
            out.append({"deployment": name, "replica_id": rep.get("replica_id") or "",
                        "state": rep.get("state") or "UNKNOWN", "node_ip": rep.get("node_ip") or ""})
    return out


def probe(ip: str, port: int, timeout: float) -> Dict[str, str]:
    """Labels of the replica info series served at ip:port, or {} if none answers there."""
    url = "http://%s:%d/metrics?name[]=%s" % (ip, port, INFO_METRIC)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            text = r.read(65536).decode("utf-8", "replace")
    except (OSError, urllib.error.URLError):
        return {}
    m = INFO_RE.search(text)
    return dict(LABEL_RE.findall(m.group("labels"))) if m else {}


class Discovery:
    def __init__(self, args):
        self.args = args
        self.known: Dict[str, Tuple[Dict[str, str], float]] = {}   # "ip:port" -> (labels, last seen)
        self.replica_counts: Dict[Tuple[str, str], int] = {}       # (deployment, state) -> replicas
        self.targets = 0
        self.last_success = 0.0
        self.errors = 0
        self.lock = threading.Lock()
        self._load()

    def _load(self) -> None:
        """Starts from the last file written, so a restart keeps down targets listed."""
        try:
            with open(self.args.out) as f:
                groups = json.load(f)
        except (OSError, ValueError):
            return
        now = time.time()
        for group in groups:
            for target in group.get("targets", []):
                self.known[target] = (group.get("labels", {}), now)

    def run_once(self) -> None:
        a = self.args
        replicas = serve_replicas(a.dashboard, a.app)
        nodes = {r["node_ip"] for r in replicas if r["node_ip"]}
        now = time.time()
        for ip in sorted(nodes):
            for port in range(a.port_base, a.port_base + PORT_SLOTS):
                info = probe(ip, port, a.probe_timeout)
                if info.get("serve_application", a.app) != a.app:
                    continue
                if info:
                    self.known["%s:%d" % (ip, port)] = ({
                        "application": a.app,
                        "deployment": info.get("serve_deployment", "unknown"),
                        "private_ip": ip,
                        "gpu_slot": str(port - a.port_base),
                    }, now)
        # Drop endpoints whose node no longer runs the app, or that stayed silent
        # past --keep (e.g. the replica came back on another GPU of the node).
        self.known = {t: (labels, seen) for t, (labels, seen) in self.known.items()
                      if labels["private_ip"] in nodes and now - seen <= a.keep}
        self._write()

        counts: Dict[Tuple[str, str], int] = {}
        for r in replicas:
            key = (r["deployment"], r["state"])
            counts[key] = counts.get(key, 0) + 1
        with self.lock:
            self.replica_counts = counts
            self.targets = len(self.known)
            self.last_success = now

    def _write(self) -> None:
        groups = [{"targets": [t], "labels": labels} for t, (labels, _) in sorted(self.known.items())]
        directory = os.path.dirname(os.path.abspath(self.args.out))
        os.makedirs(directory, exist_ok=True)
        # Prometheus may read the file at any moment: write a temp file, then rename.
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".vllm-sd-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(groups, f, indent=2, sort_keys=True)
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.args.out)
        except BaseException:
            os.unlink(tmp)
            raise

    def exposition(self) -> str:
        app = self.args.app
        with self.lock:
            lines = [
                "# HELP llm_sd_replicas Replicas of the Serve application by state, from Ray Serve's REST API.",
                "# TYPE llm_sd_replicas gauge",
            ]
            lines += ['llm_sd_replicas{application="%s",deployment="%s",state="%s"} %d' % (app, d, s, n)
                      for (d, s), n in sorted(self.replica_counts.items())]
            lines += [
                "# HELP llm_sd_targets Metrics endpoints currently written to the file_sd file.",
                "# TYPE llm_sd_targets gauge",
                'llm_sd_targets{application="%s"} %d' % (app, self.targets),
                "# HELP llm_sd_last_success_timestamp_seconds When discovery last completed.",
                "# TYPE llm_sd_last_success_timestamp_seconds gauge",
                'llm_sd_last_success_timestamp_seconds{application="%s"} %.3f' % (app, self.last_success),
                "# HELP llm_sd_errors_total Discovery rounds that failed.",
                "# TYPE llm_sd_errors_total counter",
                'llm_sd_errors_total{application="%s"} %d' % (app, self.errors),
            ]
        return "\n".join(lines) + "\n"


def serve_metrics(discovery: Discovery, listen: str) -> None:
    host, _, port = listen.rpartition(":")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = discovery.exposition().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer((host, int(port)), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", default="llm", help="Ray Serve application name")
    p.add_argument("--out", required=True, help="file_sd JSON file to write")
    p.add_argument("--dashboard", default="http://127.0.0.1:8265", help="Ray dashboard (Serve REST API)")
    p.add_argument("--port-base", type=int, default=8300, help="first port of the replicas' metrics endpoints")
    p.add_argument("--interval", type=float, default=15, help="seconds between discovery rounds")
    p.add_argument("--keep", type=float, default=600,
                   help="seconds a silent endpoint stays listed while its node still runs the app")
    p.add_argument("--probe-timeout", type=float, default=2)
    p.add_argument("--listen", default="127.0.0.1:9465", help="where to serve this daemon's own metrics")
    p.add_argument("--once", action="store_true", help="run one round, print the targets and exit")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    discovery = Discovery(args)
    if args.once:
        discovery.run_once()
        print(open(args.out).read())
        return
    serve_metrics(discovery, args.listen)
    log.info("Discovering metrics endpoints of Serve app %r every %ss into %s", args.app, args.interval, args.out)
    last_summary = None
    while True:
        try:
            discovery.run_once()
            summary = sorted(discovery.known)
            if summary != last_summary:
                log.info("Targets: %s", ", ".join(summary) or "none")
                last_summary = summary
        except Exception as e:   # keep the last good file; Prometheus keeps scraping it
            discovery.errors += 1
            log.warning("Discovery round failed: %s", e)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
