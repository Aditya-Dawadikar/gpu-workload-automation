#!/usr/bin/env bash
# Runs on the Ray head as ubuntu (copied there by scripts/deploy.sh, with its
# files in ~/llm-deployment/vllm-metrics/). Wires the replicas' native vLLM
# metrics into the gpu-workers Prometheus. Changes only what differs:
#   - the llm-metrics-sd service, which writes the replicas' scrape targets;
#   - /opt/observability/prometheus/llm/{rules,targets}, mounted read-only into
#     Prometheus as /etc/prometheus/llm;
#   - the vllm and vllm-sd jobs and rule_files entry in prometheus.yml, and that
#     mount in docker-compose.yml. Both files come from Terraform: they are
#     merged, not replaced (other jobs, services and settings stay as they are),
#     and the Terraform originals are kept as *.orig the first time.
# Every change is checked with the running Prometheus image's promtool before
# it is applied; then Prometheus is reloaded, or recreated if its mounts changed.
#   setup-vllm-metrics.sh <serve_app> <metrics_port_base>
set -euo pipefail

APP=$1 PORT_BASE=$2
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../vllm-metrics"
OBS=/opt/observability
LLM="$OBS/prometheus/llm"
SD_DIR="$OBS/llm"
PY=/opt/ray/venv/bin/python   # has PyYAML (a Ray dependency)
UNIT=/etc/systemd/system/llm-metrics-sd.service

changed() { ! sudo cmp -s "$1" "$2"; }

sudo install -d -m 755 -o ubuntu -g ubuntu "$LLM" "$LLM/rules" "$LLM/targets" "$SD_DIR"

# --- discovery service --------------------------------------------------------
sd_changed=0
if changed "$SRC/vllm_metrics_sd.py" "$SD_DIR/vllm_metrics_sd.py"; then
  sudo install -m 644 "$SRC/vllm_metrics_sd.py" "$SD_DIR/vllm_metrics_sd.py"
  sd_changed=1
fi
cat > "$SRC/llm-metrics-sd.service" <<EOF
[Unit]
Description=Prometheus targets for the vLLM replicas of Ray Serve app $APP
After=ray-head.service docker.service

[Service]
User=ubuntu
ExecStart=$PY $SD_DIR/vllm_metrics_sd.py --app $APP --port-base $PORT_BASE --out $LLM/targets/vllm.json --listen 127.0.0.1:9465
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
if changed "$SRC/llm-metrics-sd.service" "$UNIT"; then
  sudo install -m 644 "$SRC/llm-metrics-sd.service" "$UNIT"
  sudo systemctl daemon-reload
  sd_changed=1
fi
sudo systemctl enable -q llm-metrics-sd
if [ "$sd_changed" = 1 ] || ! systemctl is-active -q llm-metrics-sd; then
  echo "Restarting llm-metrics-sd (replica target discovery)"
  sudo systemctl restart llm-metrics-sd
fi

# --- Prometheus config, compose mount and rules, staged -----------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"   # promtool's container runs as nobody
cp "$OBS/prometheus/prometheus.yml" "$STAGE/prometheus.yml"
cp "$OBS/docker-compose.yml" "$STAGE/docker-compose.yml"
"$PY" - "$SRC/prometheus-scrape.yml" "$STAGE/prometheus.yml" "$STAGE/docker-compose.yml" <<'EOF'
import sys
import yaml

fragment_path, prom_path, compose_path = sys.argv[1:]
MOUNT = "./prometheus/llm:/etc/prometheus/llm:ro"
HEADER = ("# Rendered by gpu-workers Terraform; llm-deployment/remote/setup-vllm-metrics.sh merged in\n"
          "# %s. The Terraform original is next to this file as *.orig.\n")

def load(path):
    with open(path) as f:
        return yaml.safe_load(f)

class Dumper(yaml.SafeDumper):
    def ignore_aliases(self, data):   # write the expanded YAML anchors out in full
        return True

def save(path, data, what):
    with open(path, "w") as f:
        f.write(HEADER % what)
        yaml.dump(data, f, Dumper=Dumper, sort_keys=False, default_flow_style=False)

fragment = load(fragment_path)
prom = load(prom_path)
before = yaml.safe_dump(prom, sort_keys=True)
rule_files = prom.setdefault("rule_files", []) or []
prom["rule_files"] = rule_files + [r for r in fragment["rule_files"] if r not in rule_files]
ours = {job["job_name"]: job for job in fragment["scrape_configs"]}
jobs = [ours.pop(job["job_name"], job) for job in prom.get("scrape_configs") or []]
prom["scrape_configs"] = jobs + list(ours.values())
if yaml.safe_dump(prom, sort_keys=True) != before:
    save(prom_path, prom, "the vllm and vllm-sd scrape jobs and the llm rule_files entry")

compose = load(compose_path)
volumes = compose["services"]["prometheus"].setdefault("volumes", [])
if MOUNT not in volumes:
    volumes.append(MOUNT)
    save(compose_path, compose, "the read-only ./prometheus/llm mount of the prometheus service")
EOF

prom_changed=0 compose_changed=0 rules_changed=0
changed "$STAGE/prometheus.yml" "$OBS/prometheus/prometheus.yml" && prom_changed=1
changed "$STAGE/docker-compose.yml" "$OBS/docker-compose.yml" && compose_changed=1
changed "$SRC/vllm-alerts.yml" "$LLM/rules/vllm-alerts.yml" && rules_changed=1

# Validate the complete result with the promtool of the Prometheus image in use.
IMAGE="$(sudo docker inspect -f '{{.Config.Image}}' "$(cd "$OBS" && sudo docker compose ps -q prometheus)" 2>/dev/null || true)"
[ -n "$IMAGE" ] || IMAGE="$("$PY" -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["services"]["prometheus"]["image"])' "$OBS/docker-compose.yml")"
mkdir -p "$STAGE/llm/rules" "$STAGE/llm/targets"
cp "$SRC/vllm-alerts.yml" "$STAGE/llm/rules/"
sudo docker run --rm --network none --entrypoint promtool \
  -v "$STAGE/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$STAGE/llm:/etc/prometheus/llm:ro" \
  "$IMAGE" check config /etc/prometheus/prometheus.yml \
  || { echo "promtool rejected the merged Prometheus config; nothing was changed" >&2; exit 1; }

# --- apply ----------------------------------------------------------------------
for f in prometheus/prometheus.yml docker-compose.yml; do
  [ -e "$OBS/$f.orig" ] || sudo cp -p "$OBS/$f" "$OBS/$f.orig"
done
if [ "$rules_changed" = 1 ]; then
  install -m 644 "$SRC/vllm-alerts.yml" "$LLM/rules/vllm-alerts.yml"
fi
if [ "$prom_changed" = 1 ]; then
  # cp, not install/mv: Prometheus has this one file bind-mounted, which follows
  # the inode, so it has to be rewritten in place.
  sudo cp "$STAGE/prometheus.yml" "$OBS/prometheus/prometheus.yml"
fi
if [ "$compose_changed" = 1 ]; then
  sudo cp "$STAGE/docker-compose.yml" "$OBS/docker-compose.yml"
  echo "Recreating Prometheus with the llm rules/targets mount (its data volume is kept)"
  (cd "$OBS" && sudo docker compose up -d prometheus 2>&1 | tail -n 1)
elif [ "$prom_changed" = 1 ] || [ "$rules_changed" = 1 ]; then
  echo "Reloading Prometheus"
  curl -sf -X POST http://127.0.0.1:9090/-/reload
else
  echo "Prometheus already has the vLLM scrape jobs and alert rules"
fi

for _ in $(seq 1 30); do
  if curl -sf --max-time 3 -o /dev/null http://127.0.0.1:9090/-/ready; then
    echo "Prometheus ready; vLLM targets: $(cat "$LLM/targets/vllm.json" 2>/dev/null | "$PY" -c 'import json, sys; print(", ".join(t for g in json.load(sys.stdin) for t in g["targets"]) or "none yet")' 2>/dev/null || echo "none yet")"
    exit 0
  fi
  sleep 2
done
echo "Prometheus did not become ready; last logs:" >&2
(cd "$OBS" && sudo docker compose logs --no-color --tail 40 prometheus) >&2
exit 1
