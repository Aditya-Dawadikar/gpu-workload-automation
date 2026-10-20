#!/usr/bin/env bash
# Inspect logs on cluster nodes.
#   ./scripts/logs.sh                         list nodes and their bootstrap progress
#   ./scripts/logs.sh <node> [what] [-f]      show one log (-f to follow)
#   ./scripts/logs.sh all                     download every node's logs to logs/collected-<time>/
#
#   <node>: head, worker-0, worker-1, ...
#   [what]: bootstrap  full bootstrap trace (default)
#           steps      bootstrap step summary
#           ray        Ray service (ray-head / ray-worker)
#           metrics    exporters (head: prometheus/grafana/node-exporter, worker: dcgm/node-exporter)
#           cloud-init cloud-init output (useful if bootstrap never started)
source "$(dirname "$0")/common.sh"

remote_cmd() {  # remote_cmd <node> <what> <follow:true|false>
  local node=$1 what=$2 follow=$3 f n
  if $follow; then f="-f"; n="-n 200"; else f=""; n="-n 200"; fi
  case "$what" in
    bootstrap)  echo "sudo tail $n $f /var/log/ray-bootstrap.log" ;;
    steps)      echo "cat /var/log/ray-bootstrap.status 2>/dev/null || echo 'no steps recorded yet'" ;;
    cloud-init) echo "sudo tail $n $f /var/log/cloud-init-output.log" ;;
    ray)        echo "sudo journalctl -u ray-head -u ray-worker --no-pager $n $f" ;;
    metrics)
      if [ "$node" = head ]; then
        echo "cd /opt/observability && sudo docker compose logs --no-color --tail 100 $f"
      else
        echo "sudo docker logs --tail 100 dcgm-exporter 2>&1; echo '--- node-exporter ---'; sudo docker logs --tail 50 $f node-exporter 2>&1"
      fi ;;
    *) die "Unknown log '$what' (bootstrap|steps|ray|metrics|cloud-init)" ;;
  esac
}

# --- No args: overview -------------------------------------------------------
if [ $# -eq 0 ]; then
  printf '%-9s %-16s %-20s %s\n' NODE PUBLIC-IP INSTANCE-ID "BOOTSTRAP"
  while read -r name ip iid; do
    last="$(node_ssh "$ip" 'tail -n 1 /var/log/ray-bootstrap.status 2>/dev/null' 2>/dev/null || echo "ssh-unreachable")"
    IFS='|' read -r _ state step detail <<<"$last"
    case "$state" in
      DONE) s=$'\033[32mdone\033[0m' ;;
      FAIL) s=$'\033[31mFAILED: '"$step"$'\033[0m' ;;
      RUN)  s="running: $step" ;;
      OK)   s="ok: $step" ;;
      *)    s="${last:-not started}" ;;
    esac
    printf '%-9s %-16s %-20s %s\n' "$name" "$ip" "$iid" "$s"
  done < <(cluster_nodes)
  echo
  echo "Details: ./scripts/logs.sh <node> [bootstrap|steps|ray|metrics|cloud-init] [-f]"
  exit 0
fi

# --- all: download everything -------------------------------------------------
if [ "$1" = all ]; then
  out="$ROOT_DIR/logs/collected-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$out"
  while read -r name ip _; do
    log "Collecting $name ($ip)"
    for what in bootstrap steps ray metrics cloud-init; do
      node_ssh "$ip" "$(remote_cmd "$name" "$what" false | sed 's/-n 200/-n 100000/; s/--tail 100/--tail 5000/g')" \
        > "$out/$name-$what.log" 2>&1 || warn "  $what: failed (see $out/$name-$what.log)"
    done
  done < <(cluster_nodes)
  log "Saved to $out"
  exit 0
fi

# --- one node ----------------------------------------------------------------
node="$1"; what="${2:-bootstrap}"; follow=false
for a in "$@"; do [ "$a" = -f ] && follow=true; done
[ "$what" = -f ] && what=bootstrap

read -r ip iid <<<"$(node_lookup "$node")"
log "$node ($ip) - $what"
if [ "$what" = steps ]; then
  node_ssh "$ip" "$(remote_cmd "$node" steps false)" | while IFS='|' read -r ts state step detail; do
    [[ "$ts" =~ ^[0-9]+$ ]] && print_event "$node" "$ts" "$state" "$step" "$detail" || echo "$ts"
  done
else
  node_ssh "$ip" "$(remote_cmd "$node" "$what" "$follow")" || {
    warn "SSH to $node failed. EC2 console output instead:"
    aws ec2 get-console-output --instance-id "$iid" --latest --query Output --output text | tail -n 60
  }
fi
