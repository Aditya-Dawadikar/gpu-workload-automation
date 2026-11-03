#!/usr/bin/env bash
# Validate the vLLM metrics integration.
#   ./scripts/check-metrics.sh --static        no cluster needed: promtool checks of the scrape config,
#                                              alert rules (+ unit tests) and every dashboard query
#   ./scripts/check-metrics.sh                 live: the above, plus scrape targets, a replica's real
#                                              /metrics vs vLLM 0.6.6's definitions, every dashboard and
#                                              rule query on the cluster's Prometheus
#   ./scripts/check-metrics.sh --load [N]      live, plus N requests (default 20) through load-test.sh,
#                                              then checks that the request/token counters went up
# promtool comes from PATH, or else from the prom/prometheus image via Docker.
source "$(dirname "$0")/common.sh"

MODE=live LOAD=0
case "${1:-}" in
  --static) MODE=static ;;
  --load) LOAD="${2:-20}"; [[ $LOAD =~ ^[1-9][0-9]*$ ]] || die "--load needs a number of requests" ;;
  "") ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) die "Usage: ./scripts/check-metrics.sh [--static | --load [N]]" ;;
esac
[ -n "$PYTHON" ] || die "Python 3 is required"

VLLM_DIR="$LLM_DIR/observability/vllm"
DASHBOARD="$LLM_DIR/observability/vllm-engine.json"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.55.1}"   # gpu-workers' prometheus_image
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
# check <command...>: prints ✔/✘ $LABEL, and the command's output only when it fails.
check() {
  if "$@" >"$WORK/check.out" 2>&1; then
    printf '  \033[32m✔\033[0m %s\n' "$LABEL"
  else
    printf '  \033[31m✘\033[0m %s\n' "$LABEL"; sed 's/^/      /' "$WORK/check.out"; FAILED=1
  fi
}

# promtool <args...>, with every file argument under $WORK
if command -v promtool >/dev/null; then
  promtool() { (cd "$WORK" && command promtool "$@"); }
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  promtool() { MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$(cd "$WORK" && pwd -W 2>/dev/null || pwd):/work" -w /work --entrypoint promtool "$PROM_IMAGE" "$@"; }
else
  die "promtool not found and Docker is not running. Install Prometheus' promtool or start Docker."
fi

log "Static checks"
"$PYTHON" "$LLM_DIR/scripts/render_alerts.py" >"$WORK/vllm-alerts.yml"
"$PYTHON" "$LLM_DIR/scripts/render_alerts.py" --defaults-only >"$WORK/vllm-alerts.defaults.yml"
cp "$VLLM_DIR/vllm-alerts.test.yml" "$WORK/"
"$PYTHON" "$LLM_DIR/scripts/check_metrics.py" dashboard-rules "$DASHBOARD" >"$WORK/dashboard-queries.yml"
# A Prometheus config like the head's after setup-vllm-metrics.sh: the scrape jobs and rule_files from
# prometheus-scrape.yml, rules under ./llm/rules, discovery files under ./llm/targets.
mkdir -p "$WORK/llm/rules" "$WORK/llm/targets"
cp "$WORK/vllm-alerts.yml" "$WORK/llm/rules/"
sed -e 's#/etc/prometheus/llm/#llm/#' "$VLLM_DIR/prometheus-scrape.yml" >"$WORK/prometheus.yml"

LABEL="alert rules render and pass promtool check rules";       check promtool check rules vllm-alerts.yml
LABEL="alert rule unit tests (default thresholds)";             check promtool test rules vllm-alerts.test.yml
LABEL="every dashboard query and variable parses as PromQL";    check promtool check rules dashboard-queries.yml
LABEL="scrape jobs + rule_files pass promtool check config";    check promtool check config prometheus.yml
LABEL="dashboard JSON: unique panel ids, Prometheus uid";       check "$PYTHON" -c '
import json, sys
d = json.load(open(sys.argv[1]))
ids = [p["id"] for p in d["panels"]]
assert len(ids) == len(set(ids)), "duplicate panel ids"
assert all(p.get("datasource", {}).get("uid", "prometheus") == "prometheus" for p in d["panels"] if p["type"] != "row")
' "$DASHBOARD"
LABEL="vllm_metrics_sd.py compiles";                            check "$PYTHON" -m py_compile "$LLM_DIR/remote/vllm_metrics_sd.py"
LABEL="llm_serve.py compiles";                                  check "$PYTHON" -m py_compile "$LLM_DIR/app/llm_serve.py"

if [ "$MODE" = static ]; then
  [ "$FAILED" = 0 ] && log "Static checks passed" || die "Static checks failed"
  exit 0
fi

# ---------------------------------------------------------------------------
require_cluster
PROM="http://$HEAD:9090"
log "Live checks against $PROM"
"$PYTHON" "$LLM_DIR/scripts/check_metrics.py" live "$PROM" "$DASHBOARD" "$WORK/vllm-alerts.yml" || FAILED=1

log "A replica's own /metrics (fetched on the head; the endpoints are private)"
target="$(curl -sf --max-time 10 "$PROM/api/v1/query" --data-urlencode 'query=up{job="vllm"} == 1' \
  | "$PYTHON" -c 'import json, sys; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["metric"]["instance"] if r else "")')"
if [ -n "$target" ]; then
  hssh "curl -sf --max-time 10 http://$target/metrics" >"$WORK/replica-metrics.txt" || true
  printf '  %s: %s bytes; vLLM version: %s\n' "$target" "$(wc -c <"$WORK/replica-metrics.txt" | tr -d ' ')" \
    "$(grep -o 'vllm_version="[^"]*"' "$WORK/replica-metrics.txt" | head -n 1)"
  "$PYTHON" "$LLM_DIR/scripts/check_metrics.py" exposition "$WORK/replica-metrics.txt" "$DASHBOARD" "$WORK/vllm-alerts.yml" || FAILED=1
else
  warn "No vllm target is up, so no /metrics response to inspect"; FAILED=1
fi

if [ "$LOAD" -gt 0 ]; then
  log "Load check: $LOAD requests, then the counters must rise"
  "$PYTHON" "$LLM_DIR/scripts/check_metrics.py" snapshot "$PROM" >"$WORK/before.json"
  bash "$LLM_DIR/scripts/load-test.sh" --requests "$LOAD" --concurrency 4 | tail -n 8 || FAILED=1
  sleep 20   # replica -> scrape (5s) -> query
  "$PYTHON" "$LLM_DIR/scripts/check_metrics.py" snapshot "$PROM" >"$WORK/after.json"
  "$PYTHON" "$LLM_DIR/scripts/check_metrics.py" compare "$WORK/before.json" "$WORK/after.json" || FAILED=1
fi

[ "$FAILED" = 0 ] && log "All checks passed" || die "Some checks failed (see above)"
