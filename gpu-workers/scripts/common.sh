#!/usr/bin/env bash
# Shared helpers for the deployment scripts. Source, don't execute.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"

# Tools installed by setup.sh, and the AWS profile it signed in with.
TOOLS_DIR="$ROOT_DIR/.tools"
TOOLS_BIN="$TOOLS_DIR/bin"
TOOLS_ENV="$TOOLS_DIR/env"
export PATH="$TOOLS_BIN:$PATH"
if [ -z "${AWS_PROFILE:-}" ] && [ -f "$TOOLS_ENV" ]; then
  source "$TOOLS_ENV"
fi
# First interpreter that really runs Python 3 (on Windows, `python3` may be a
# Microsoft Store stub that only prints an install hint).
PYTHON=""
for _py in python3 python py; do
  if command -v "$_py" >/dev/null && "$_py" -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null; then
    PYTHON="$(command -v "$_py")"
    break
  fi
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

tf()        { terraform -chdir="$TF_DIR" "$@"; }
tf_out()    { tf output -raw "$1"; }

head_ip()   { tf_out head_public_ip; }

# Private key: $SSH_KEY if set, otherwise whatever Terraform used (either the
# key you supplied or the one it generated under terraform/.keys/).
ssh_key() {
  if [ -n "${SSH_KEY:-}" ]; then echo "$SSH_KEY"; return; fi
  local src; src="$(tf_out ssh_private_key_path 2>/dev/null || true)"
  # State written from another environment (Windows vs WSL) may hold a path
  # this shell can't open; generated keys always live in terraform/.keys/.
  [ -f "$src" ] || src="$TF_DIR/.keys/$(basename "${src//\\//}")"
  case "$src" in
    "$TF_DIR"/.keys/*)
      # ssh refuses keys readable by others, and files on Windows drives
      # mounted in WSL can't be chmod'ed - so use a private copy in $HOME.
      if [ -f "$src" ]; then
        local copy="$HOME/.cache/gpu-workers/$(basename "$src")"
        mkdir -p "$(dirname "$copy")" && chmod 700 "$(dirname "$copy")"
        cmp -s "$src" "$copy" 2>/dev/null || cp -f "$src" "$copy"
        chmod 600 "$copy"
        src="$copy"
      fi ;;
  esac
  echo "$src"
}

# Cluster nodes get new host keys every time they're rebuilt, so trust them on
# first use with a cluster-specific known_hosts that deploy.sh resets.
KNOWN_HOSTS="$TOOLS_DIR/known_hosts"

ssh_opts() {
  mkdir -p "$TOOLS_DIR"
  SSH_OPTS=(-i "$(ssh_key)" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
            -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=10 -o LogLevel=ERROR)
}

# -n: never read stdin, so node_ssh is safe inside `while read` loops.
node_ssh()  { local ip=$1; shift; ssh_opts; ssh -n "${SSH_OPTS[@]}" "ubuntu@$ip" "$@"; }
head_ssh()  { node_ssh "$(head_ip)" "$@"; }

# Prints one line per node: "<name> <public-ip> <instance-id>" (head first).
cluster_nodes() {
  tf output -json | "$PYTHON" -c '
import json, sys
o = json.load(sys.stdin)
print("head", o["head_public_ip"]["value"], o["head_instance_id"]["value"])
for i, (ip, iid) in enumerate(zip(o["worker_public_ips"]["value"], o["worker_instance_ids"]["value"])):
    print(f"worker-{i}", ip, iid)
'
}

# Looks up "<public-ip> <instance-id>" for a node name (head, worker-0, ...).
node_lookup() {
  cluster_nodes | awk -v n="$1" '$1 == n { print $2, $3; found=1 } END { exit !found }' \
    || die "Unknown node '$1'. Nodes: $(cluster_nodes | awk '{print $1}' | tr '\n' ' ')"
}

fmt_time() { date -d "@$1" +%H:%M:%S 2>/dev/null || date -r "$1" +%H:%M:%S; }

# Pretty-prints one bootstrap status record: node epoch state step detail
print_event() {
  local node=$1 state=$3 step=$4 detail=${5:-} t
  t="$(fmt_time "$2")"
  case "$state" in
    RUN)  printf '  %s  %-9s \033[36m▶\033[0m %s\n' "$t" "$node" "$step" ;;
    OK)   printf '  %s  %-9s \033[32m✔\033[0m %s \033[2m(%s)\033[0m\n' "$t" "$node" "$step" "$detail" ;;
    FAIL) printf '  %s  %-9s \033[1;31m✘ FAILED: %s\033[0m\n  %8s  %-9s   \033[31m%s\033[0m\n' "$t" "$node" "$step" "" "" "$detail" ;;
    DONE) printf '  %s  %-9s \033[1;32m★ %s\033[0m \033[2m(total %s)\033[0m\n' "$t" "$node" "$step" "$detail" ;;
    *)    printf '  %s  %-9s   %s %s\n' "$t" "$node" "$step" "$detail" ;;
  esac
}

# Instant Prometheus query -> scalar value (empty if no result).
prom_scalar() {
  local query="$1"
  curl -sf --max-time 5 "http://$(head_ip):9090/api/v1/query" --data-urlencode "query=$query" \
    | "$PYTHON" -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")' \
    2>/dev/null || true
}
