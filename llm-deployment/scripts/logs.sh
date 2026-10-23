#!/usr/bin/env bash
# Show LLM serving logs from the cluster nodes.
#   ./scripts/logs.sh                 last 60 lines of the replica + vLLM logs on every worker
#   ./scripts/logs.sh worker-0 [N]    one worker, last N lines (default 200)
#   ./scripts/logs.sh worker-0 -f     follow one worker's logs
#   ./scripts/logs.sh head [N|-f]     Serve controller and HTTP proxy logs
#   ./scripts/logs.sh all [N]         every worker, last N lines
source "$(dirname "$0")/common.sh"

TARGET="${1:-all}"
ARG="${2:-}"
HEAD="$(head_ip 2>/dev/null)" || die "No cluster found (no Terraform outputs in $TF_DIR)"
SSH_KEY="$(ssh_key)"
export SSH_KEY

# Replica logs come from Serve; vLLM's own output lands in the stderr file of
# the Ray worker process that hosts the replica.
REPLICA_FILES="ls -t serve/replica_${SERVE_APP}_*.log 2>/dev/null; grep -ls -E 'vllm|llm_serve' worker-*.err"
HEAD_FILES="ls -t serve/controller_*.log serve/proxy_*.log 2>/dev/null"

show() {   # show <ip> <file-list-cmd> <N|-f>
  local tail_args="-n $3"
  [ "$3" = -f ] && tail_args="-n 50 -F"
  node_ssh "$1" "cd /tmp/ray/session_latest/logs 2>/dev/null || { echo '  (no Ray logs on this node)'; exit 0; }
files=\$($2)
[ -n \"\$files\" ] || { echo '  (no LLM serving logs on this node yet)'; exit 0; }
tail $tail_args \$files"
}

case "$TARGET" in
  all)
    while read -r name ip _; do
      printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$name"
      show "$ip" "$REPLICA_FILES" "${ARG:-60}" || warn "Could not read logs on $name"
    done < <(cluster_nodes | grep -v '^head ')
    ;;
  head)
    show "$HEAD" "$HEAD_FILES" "${ARG:-200}"
    ;;
  *)
    node="$(node_lookup "$TARGET")"
    show "${node%% *}" "$REPLICA_FILES" "${ARG:-200}"
    ;;
esac
