#!/usr/bin/env bash
# Send concurrent requests to the deployed model to check it's live under load.
# Watch the "LLM Serving" dashboard in Grafana while it runs.
#   ./scripts/load-test.sh [--requests N] [--concurrency N] [--max-tokens N]
# Set LLM_API_URL to use another endpoint (e.g. an SSH tunnel).
source "$(dirname "$0")/common.sh"

[ -n "$PYTHON" ] || die "Python 3 is required"
[ -n "${LLM_API_URL:-}" ] || HEAD="$(head_ip 2>/dev/null)" \
  || die "No cluster found. Deploy one first: $GPU_WORKERS_DIR/scripts/deploy.sh"
[ -z "${HEAD:-}" ] || log "Dashboard: http://$HEAD:3000/d/llm-serving"
exec "$PYTHON" "$LLM_DIR/scripts/load_test.py" --url "$(api_url)" ${HEAD:+--grafana "http://$HEAD:3000"} "$@"
