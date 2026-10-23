#!/usr/bin/env bash
# Remove the model from the cluster and free its GPUs, CPUs, memory and disk.
# The cluster keeps running (tear it down with ../gpu-workers/scripts/destroy.sh).
# Waits until every node is drained - no Serve actors, Ray's CPU/GPU/memory
# fully free, no processes on the GPUs - then deletes the model weights and
# compile/download caches, and prints what each node has left. The installed
# packages stay, so the next deploy skips the install.
#   ./scripts/undeploy.sh [--keep-model-cache] [--timeout SEC]
source "$(dirname "$0")/common.sh"

KEEP_MODEL=0
TIMEOUT_SEC=180
usage="Usage: ./scripts/undeploy.sh [--keep-model-cache] [--timeout SEC]"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-model-cache) KEEP_MODEL=1; shift ;;
    --delete-model-cache) shift ;;   # the default now; kept so old commands still work
    --timeout) [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--timeout needs a number of seconds"; TIMEOUT_SEC=$2; shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) die "$usage" ;;
  esac
done

RUN_DIR="$LLM_DIR/logs/undeploy-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LLM_DIR/logs"
exec > >(tee -a "$RUN_DIR.log") 2>&1
START=$(date +%s)

require_cluster
NODES="$(cluster_nodes)"
NODE_MAP="$(node_map)"
export NODE_MAP
ssh_opts
hssh "mkdir -p ~/$REMOTE_DIR/bin"
scp -q "${SSH_OPTS[@]}" "$LLM_DIR/remote/ray_resources.py" "ubuntu@$HEAD:$REMOTE_DIR/bin/"
NODE_USAGE="$(cat "$LLM_DIR/remote/node-usage.sh")"

# Fills RAY_OUT, NODE_OUT[<name>] and BUSY (one "<where>: <reasons>" per line;
# empty once everything is released).
declare -A NODE_OUT
snapshot() {
  local name ip _ status
  BUSY=""
  RAY_OUT="$(hssh "$REMOTE_VENV/bin/python ~/$REMOTE_DIR/bin/ray_resources.py $NODE_MAP" 2>&1)" \
    || RAY_OUT+=$'\nRAY_STATUS BUSY could not query Ray'
  status="$(grep '^RAY_STATUS ' <<<"$RAY_OUT" | tail -n 1)"
  [ "$status" = "RAY_STATUS DRAINED" ] || BUSY+="ray: ${status#RAY_STATUS BUSY }"$'\n'
  while read -r name ip _; do
    NODE_OUT[$name]="$(node_ssh "$ip" "$NODE_USAGE" 2>&1)" \
      || NODE_OUT[$name]+=$'\nNODE_STATUS BUSY unreachable over SSH'
    status="$(grep '^NODE_STATUS ' <<<"${NODE_OUT[$name]}" | tail -n 1)"
    [ "$status" = "NODE_STATUS CLEAN" ] || BUSY+="$name: ${status#NODE_STATUS BUSY }"$'\n'
  done <<<"$NODES"
}

report() {
  local name _
  printf '  \033[1mRay resources\033[0m\n'
  grep -v '^RAY_STATUS ' <<<"$RAY_OUT" | sed 's/^/  /'
  while read -r name _; do
    printf '  \033[1m%s\033[0m\n' "$name"
    grep -v '^NODE_STATUS ' <<<"${NODE_OUT[$name]}" | sed 's/^/    /'
  done <<<"$NODES"
}

log "Before: Ray Serve on $HEAD"
if details="$(serve_details)"; then
  "$PYTHON" -c '
import json, os, sys
names = dict(p.split("=", 1) for p in os.environ.get("NODE_MAP", "").split())
apps = json.load(sys.stdin).get("applications") or {}
if not apps:
    print("  No applications deployed")
for name, app in apps.items():
    print("  app %s: %s" % (name, app.get("status")))
    for dname, dep in (app.get("deployments") or {}).items():
        for r in dep.get("replicas") or []:
            ip = r.get("node_ip")
            print("    %-10s %-9s pid %s" % (r.get("state"), names.get(ip, ip or "unscheduled"), r.get("pid") or "-"))
' <<<"$details"
else
  warn "Could not read Serve state; shutting down anyway"
fi
snapshot
report

log "Shutting down Ray Serve on $HEAD"
hssh "$REMOTE_VENV/bin/serve shutdown -y --address http://127.0.0.1:$DASHBOARD_PORT"

log "Waiting for the nodes to drain (up to ${TIMEOUT_SEC}s)"
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
last=""
while :; do
  snapshot
  [ -n "$BUSY" ] || break
  if [ "$BUSY" != "$last" ]; then
    printf '  %s  \033[2mstill busy (%s):\033[0m\n' "$(fmt_time "$(date +%s)")" "$(elapsed "$START")"
    sed '/^$/d; s/^/      /' <<<"$BUSY"
    last=$BUSY
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "After: resources still held"
    report
    die "Not drained after ${TIMEOUT_SEC}s:
$(sed '/^$/d; s/^/  /' <<<"$BUSY")
Leftover processes are listed above; stop them with: ssh ubuntu@<node> kill <pid>
Log: $RUN_DIR.log"
  fi
  sleep 5
done
printf '  %s  \033[32m✔\033[0m all nodes drained \033[2m(%s)\033[0m\n' "$(fmt_time "$(date +%s)")" "$(elapsed "$START")"

log "Freeing disk: $([ "$KEEP_MODEL" = 1 ] && echo "compile and download caches (keeping the model)" || echo "model weights, compile and download caches")"
CLEAN_DISK="KEEP_MODEL=$KEEP_MODEL; $(cat "$LLM_DIR/remote/clean-disk.sh")"
DISK_OK=1
while read -r name ip _; do
  printf '  \033[1m%s\033[0m\n' "$name"
  node_ssh "$ip" "$CLEAN_DISK" 2>&1 | sed 's/^/    /' \
    || { DISK_OK=0; warn "Could not free the disk on $name"; }
done <<<"$NODES"

log "After: resources released"
snapshot
report
[ "$DISK_OK" = 1 ] || die "Drained, but freeing the disk failed on some node (see above). Log: $RUN_DIR.log"
log "Done in $(elapsed "$START"). GPUs, CPUs, memory and disk are free; the cluster is still running. Log: $RUN_DIR.log"
