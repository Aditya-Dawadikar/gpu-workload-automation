#!/usr/bin/env bash
# Chat with the deployed model.
#   ./scripts/chat.sh [--stream] [--max-tokens N] [--system TEXT] "prompt"
# Set LLM_API_URL to use another endpoint (e.g. an SSH tunnel).
source "$(dirname "$0")/common.sh"

[ -n "$PYTHON" ] || die "Python 3 is required"
[ -n "${LLM_API_URL:-}" ] || HEAD="$(head_ip 2>/dev/null)" \
  || die "No cluster found. Deploy one first: $GPU_WORKERS_DIR/scripts/deploy.sh"
exec "$PYTHON" "$LLM_DIR/scripts/chat.py" --url "$(api_url)" ${HEAD:+--grafana "http://$HEAD:3000"} "$@"
