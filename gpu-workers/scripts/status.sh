#!/usr/bin/env bash
# Show cluster endpoints, scrape-target health and `ray status` from the head.
source "$(dirname "$0")/common.sh"

HEAD="$(head_ip)"
log "Endpoints"
echo "  Ray dashboard : $(tf_out ray_dashboard_url)"
echo "  Grafana       : $(tf_out grafana_url)"
echo "  Prometheus    : $(tf_out prometheus_url)"

log "Node bootstrap progress"
"$ROOT_DIR/scripts/logs.sh" | sed 's/^/  /'

log "Prometheus scrape targets (up/total)"
for job in ray node dcgm; do
  up=$(prom_scalar "count(up{job=\"$job\"} == 1)")
  total=$(prom_scalar "count(up{job=\"$job\"})")
  printf '  %-5s %s/%s\n' "$job" "${up:-0}" "${total:-0}"
done

log "GPU utilization (%)"
curl -sf --max-time 5 "http://$HEAD:9090/api/v1/query" --data-urlencode 'query=DCGM_FI_DEV_GPU_UTIL' \
  | "$PYTHON" -c '
import json, sys
rows = json.load(sys.stdin)["data"]["result"]
for r in sorted(rows, key=lambda r: (r["metric"].get("instance", ""), r["metric"].get("gpu", ""))):
    m = r["metric"]
    inst, gpu, model, val = m.get("instance", "?"), m.get("gpu", "?"), m.get("modelName", ""), r["value"][1]
    print(f"  {inst:<28} gpu{gpu} {model:<24} {val:>5}")
' || warn "Prometheus not reachable yet"

if [ -f "$(ssh_key)" ]; then
  log "ray status (on head)"
  head_ssh '/opt/ray/venv/bin/ray status' || warn "ray status failed - see /var/log/ray-bootstrap.log on the head"
else
  warn "Skipping 'ray status': SSH key $(ssh_key) not found"
fi
