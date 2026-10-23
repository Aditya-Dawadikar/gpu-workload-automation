#!/usr/bin/env bash
# Shared helpers for the LLM deployment scripts. Source, don't execute.
# Cluster access (Terraform outputs, SSH, log helpers) comes from gpu-workers.
set -euo pipefail

LLM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_WORKERS_DIR="$(cd "${GPU_WORKERS_DIR:-$LLM_DIR/../gpu-workers}" 2>/dev/null && pwd)" \
  || { echo "ERROR: gpu-workers not found next to llm-deployment (set GPU_WORKERS_DIR)" >&2; exit 1; }
source "$GPU_WORKERS_DIR/scripts/common.sh"

REMOTE_DIR=llm-deployment   # ~/llm-deployment on every node
REMOTE_VENV=/opt/ray/venv   # Ray's venv, created by the gpu-workers bootstrap
SERVE_APP=llm               # Ray Serve application name
SERVE_PORT=8000             # Ray Serve HTTP proxy on the head
DASHBOARD_PORT=8265

elapsed() { local s=$(( $(date +%s) - $1 )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }

# Sets HEAD and SSH_KEY (so later SSH calls skip Terraform), and checks that
# the Ray dashboard answers.
require_cluster() {
  HEAD="$(head_ip 2>/dev/null)" && [ -n "$HEAD" ] \
    || die "No cluster found. Deploy one first: $GPU_WORKERS_DIR/scripts/deploy.sh"
  SSH_KEY="$(ssh_key)"
  export SSH_KEY
  curl -sf --max-time 10 "http://$HEAD:$DASHBOARD_PORT/api/version" >/dev/null \
    || die "Ray dashboard at http://$HEAD:$DASHBOARD_PORT is not answering. Check $GPU_WORKERS_DIR/scripts/status.sh and that your IP is in allowed_cidrs."
}

hssh() { node_ssh "$HEAD" "$@"; }

# OpenAI-compatible base URL. LLM_API_URL overrides it, e.g. for an SSH tunnel.
api_url() { echo "${LLM_API_URL:-http://$HEAD:$SERVE_PORT}"; }

# Grafana link that opens one request trace from Tempo (same as the Python clients print).
trace_url() {
  "$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); from chat import trace_link; print(trace_link(sys.argv[2], sys.argv[3]))' \
    "$LLM_DIR/scripts" "http://$HEAD:3000" "$1"
}

# Ray Serve's view of all applications (JSON), from the dashboard REST API.
serve_details() { curl -sf --max-time 10 "http://$HEAD:$DASHBOARD_PORT/api/serve/applications/"; }

# "<private-ip>=<node-name> ..." so Serve's replica IPs can be shown as worker-N.
node_map() {
  tf output -json | "$PYTHON" -c '
import json, sys
o = json.load(sys.stdin)
pairs = [(o["head_private_ip"]["value"], "head")]
pairs += [(ip, f"worker-{i}") for i, ip in enumerate(o["worker_private_ips"]["value"])]
print(" ".join(f"{ip}={name}" for ip, name in pairs))'
}

# serve_details | python -c "$SERVE_SUMMARY_PY" <app> [summary|message]
#   summary: "<APP_STATUS>|<replica states>|<short message>"
#   message: the full application and deployment messages
SERVE_SUMMARY_PY='
import json, os, sys
app_name = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "summary"
names = dict(p.split("=", 1) for p in os.environ.get("NODE_MAP", "").split())
app = (json.load(sys.stdin).get("applications") or {}).get(app_name)
if not app:
    print("NOT_DEPLOYED|no replicas|")
    sys.exit()
deployments = (app.get("deployments") or {}).values()
messages = [app.get("message") or ""] + [d.get("message") or "" for d in deployments]
if mode == "message":
    print("\n".join(m.strip() for m in messages if m.strip()))
    sys.exit()
states = {}
for d in deployments:
    for r in d.get("replicas") or []:
        ip = r.get("node_ip")
        states.setdefault((r.get("state") or "?").lower(), []).append(names.get(ip, ip or "unscheduled"))
replicas = "; ".join("%s %d (%s)" % (s, len(n), ", ".join(sorted(n))) for s, n in sorted(states.items()))
message = " ".join(" ".join(m.split()) for m in messages if m)
print("|".join([app.get("status", "?"), replicas or "no replicas yet", message[:300]]))
'

# run_parallel <label> <fn> <targets>
# Runs "<fn> <name> <ip>" in the background for every "<name> <ip> ..." line of
# <targets>, logging each to $RUN_DIR/<name>-<label>.log, and reports each node
# as it finishes. Returns non-zero if any node failed.
run_parallel() {
  local label=$1 fn=$2 targets=$3 name ip _ i logf start last_note remaining failed=0
  local -a names=() pids=()
  start=$(date +%s); last_note=$start
  while read -r name ip _; do
    [ -n "$name" ] || continue
    "$fn" "$name" "$ip" >"$RUN_DIR/$name-$label.log" 2>&1 &
    names+=("$name"); pids+=("$!")
  done <<<"$targets"

  remaining=${#pids[@]}
  while [ "$remaining" -gt 0 ]; do
    sleep 2
    for i in "${!pids[@]}"; do
      [ -n "${pids[$i]}" ] || continue
      if kill -0 "${pids[$i]}" 2>/dev/null; then continue; fi
      logf="$RUN_DIR/${names[$i]}-$label.log"
      if wait "${pids[$i]}"; then
        printf '  %s  %-9s \033[32m✔\033[0m %s \033[2m(%s)\033[0m\n' \
          "$(fmt_time "$(date +%s)")" "${names[$i]}" "$(tail -n 1 "$logf" | cut -c1-110)" "$(elapsed "$start")"
      else
        failed=1
        printf '  %s  %-9s \033[1;31m✘ FAILED\033[0m (%s) - last lines of %s:\n' \
          "$(fmt_time "$(date +%s)")" "${names[$i]}" "$(elapsed "$start")" "$logf"
        tail -n 25 "$logf" | sed 's/^/      /'
      fi
      pids[$i]=""
      remaining=$((remaining - 1))
    done
    if [ "$remaining" -gt 0 ] && [ $(( $(date +%s) - last_note )) -ge 60 ]; then
      printf '  %s  \033[2mstill running on %d node(s) (%s)\033[0m\n' \
        "$(fmt_time "$(date +%s)")" "$remaining" "$(elapsed "$start")"
      last_note=$(date +%s)
    fi
  done
  return $failed
}
