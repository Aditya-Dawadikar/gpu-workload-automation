#!/usr/bin/env bash
# Runs on the Ray head as ubuntu (copied there by scripts/deploy.sh).
# Starts Grafana Tempo next to the gpu-workers Prometheus/Grafana stack and
# adds it to Grafana as a datasource. Restarts only what changed.
#   start-tempo.sh <tempo_image>
set -euo pipefail

IMAGE=$1
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../tempo"
OBS=/opt/observability
NAME=llm-tempo

changed() { ! sudo cmp -s "$1" "$2"; }

config_changed=0
if changed "$SRC/tempo.yaml" "$OBS/tempo/tempo.yaml"; then
  sudo install -D -m 644 "$SRC/tempo.yaml" "$OBS/tempo/tempo.yaml"
  config_changed=1
fi

running_image="$(sudo docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true)"
if [ "$config_changed" = 1 ] || [ "$running_image" != "$IMAGE" ] \
   || [ "$(sudo docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then
  echo "Starting Tempo ($IMAGE)"
  sudo docker rm -f "$NAME" >/dev/null 2>&1 || true
  # Host network like the rest of the stack: replicas reach :4317 over the
  # cluster's private IPs. Runs as root so it can write the fresh named volume.
  sudo docker run -d --name "$NAME" --restart unless-stopped --network host --user 0:0 \
    -v "$OBS/tempo/tempo.yaml:/etc/tempo.yaml:ro" -v llm-tempo-data:/var/tempo \
    "$IMAGE" -config.file=/etc/tempo.yaml >/dev/null
else
  echo "Tempo already running ($IMAGE)"
fi

grafana_changed=0
DS="$OBS/grafana/provisioning/datasources/tempo.yml"
if changed "$SRC/datasource.yml" "$DS"; then
  sudo install -D -m 644 "$SRC/datasource.yml" "$DS"
  grafana_changed=1
fi
if changed "$SRC/grafana-override.yml" "$OBS/docker-compose.override.yml"; then
  sudo install -m 644 "$SRC/grafana-override.yml" "$OBS/docker-compose.override.yml"
  grafana_changed=1
fi
if [ "$grafana_changed" = 1 ]; then
  # up (not restart) so Grafana is recreated with the override's environment.
  echo "Recreating Grafana with the Tempo datasource and Explore for viewers"
  (cd "$OBS" && sudo docker compose up -d grafana 2>&1 | tail -n 1)
fi

for _ in $(seq 1 45); do
  if curl -sf --max-time 3 -o /dev/null http://127.0.0.1:3200/ready; then   # 503 until the ingester is up
    echo "Tempo ready: OTLP on :4317, queries on :3200"
    exit 0
  fi
  sleep 2
done
echo "Tempo did not become ready; last logs:" >&2
sudo docker logs --tail 40 "$NAME" >&2
exit 1
