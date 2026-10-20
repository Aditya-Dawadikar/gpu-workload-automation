#!/usr/bin/env bash
# Provision the GPU cluster and follow it until Ray + observability are healthy.
#   ./scripts/deploy.sh                 # interactive apply
#   ./scripts/deploy.sh -auto-approve   # extra args go to `terraform apply`
#
# Progress is printed per phase and per node step; everything is also saved to
# logs/deploy-<timestamp>.log. On failure the failing node's logs are saved to
# logs/deploy-<timestamp>/ and the relevant lines are printed.
source "$(dirname "$0")/common.sh"

BOOTSTRAP_TIMEOUT_MIN="${BOOTSTRAP_TIMEOUT_MIN:-30}"
HEALTH_TIMEOUT_MIN="${HEALTH_TIMEOUT_MIN:-5}"
POLL_SECONDS="${POLL_SECONDS:-10}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/deploy-$RUN_ID.log"
ARTIFACTS="$LOG_DIR/deploy-$RUN_ID"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

PHASE="startup"
PHASE_START=$(date +%s)
DEPLOY_START=$PHASE_START
TOTAL_PHASES=4

phase() {
  [ "$PHASE" = startup ] || ok "$PHASE done in $(elapsed "$PHASE_START")"
  PHASE_NUM=$(( ${PHASE_NUM:-0} + 1 ))
  PHASE="$1"
  PHASE_START=$(date +%s)
  printf '\n\033[1;35m━━━ [%d/%d] %s ━━━\033[0m\n' "$PHASE_NUM" "$TOTAL_PHASES" "$PHASE"
}
ok()      { printf '  \033[32m✔\033[0m %s\n' "$*"; }
elapsed() { local s=$(( $(date +%s) - $1 )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n\033[1;31m✘ Deploy FAILED during phase "%s" (exit %d) after %s\033[0m\n' "$PHASE" "$rc" "$(elapsed "$DEPLOY_START")"
    echo "  Full log: $LOG_FILE"
    [ -d "$ARTIFACTS" ] && echo "  Node logs: $ARTIFACTS/"
  fi
}
trap on_exit EXIT

# =============================================================================
phase "Preflight checks"
# =============================================================================
command -v terraform >/dev/null || die "terraform not found - run ./scripts/setup.sh"
ok "terraform $(terraform version | head -1 | awk '{print $2}')"
command -v aws >/dev/null || die "aws CLI not found - run ./scripts/setup.sh"
ok "$(aws --version 2>&1 | awk '{print $1}')"
[ -n "$PYTHON" ] || die "python not found (used to parse API responses)"
ok "python $("$PYTHON" -c 'import platform; print(platform.python_version())')"
[ -f "$TF_DIR/terraform.tfvars" ] || die "Missing $TF_DIR/terraform.tfvars - run ./scripts/setup.sh"
ok "terraform.tfvars found"
if grep -q '203\.0\.113\.7' "$TF_DIR/terraform.tfvars"; then
  die "allowed_cidrs still has the placeholder 203.0.113.7 - set it to your IP (run: curl -s https://checkip.amazonaws.com)"
fi

IDENTITY="$(aws sts get-caller-identity --query Arn --output text 2>&1)" \
  || die "Not signed in to AWS (profile: ${AWS_PROFILE:-default}). Run ./scripts/setup.sh. AWS said: $IDENTITY"
ok "AWS identity: $IDENTITY (profile: ${AWS_PROFILE:-default})"

# =============================================================================
phase "Provision AWS infrastructure (terraform)"
# =============================================================================
echo "  terraform init..."
tf init -input=false -upgrade >/dev/null || die "terraform init failed (rerun: terraform -chdir=terraform init)"
ok "terraform initialised"

TF_LOG_START=$(wc -l < "$LOG_FILE")
if ! tf apply "$@"; then
  # Translate the most common AWS errors into next steps.
  tf_errors="$(tail -n +"$TF_LOG_START" "$LOG_FILE")"
  hint() { grep -q "$1" <<<"$tf_errors" && printf '\n  \033[1;33mHint:\033[0m %s\n' "$2"; return 0; }
  hint VcpuLimitExceeded            "Your EC2 GPU vCPU quota is too low. Run ./scripts/setup.sh to see the quota and a link to request more."
  hint InsufficientInstanceCapacity "AWS has no capacity for this instance type in this AZ right now. Set availability_zone to another AZ, try another instance type, or retry later."
  hint "Unsupported"                "This instance type isn't offered in the chosen AZ. Set availability_zone in terraform.tfvars."
  hint "ExpiredToken\|RequestExpired\|InvalidClientTokenId" "Your AWS session expired. Run ./scripts/setup.sh to sign in again."
  hint "UnauthorizedOperation\|AccessDenied" "Your AWS identity lacks permissions (EC2, VPC, IAM, SSM read). Ask your admin or use a different profile."
  hint "MaxSpotInstanceCountExceeded" "Spot quota exceeded. Set worker_use_spot = false or request a Spot quota increase."
  hint "InvalidKeyPair"               "The SSH key pair couldn't be imported. Check ssh_public_key_path, or leave it unset to generate one."
  die "terraform apply failed - see the error above"
fi
ok "Infrastructure ready"

HEAD="$(head_ip)"
WORKERS="$(tf_out worker_count)"
KEY="$(ssh_key)"
[ -f "$KEY" ] || die "SSH private key $KEY not found; set SSH_KEY=/path/to/key"
export SSH_KEY="$KEY"   # resolve once; the polling loop reuses it
ok "SSH key: $KEY"
rm -f "$KNOWN_HOSTS"   # nodes may have been rebuilt with new host keys

mapfile -t NODES < <(cluster_nodes)
echo
printf '  %-9s %-16s %s\n' NODE PUBLIC-IP INSTANCE-ID
for n in "${NODES[@]}"; do printf '  %-9s %-16s %s\n' $n; done

# =============================================================================
phase "Bootstrap nodes (install Docker, NVIDIA exporters, Ray; join cluster)"
# =============================================================================
STATE="$(mktemp -d)"

# Saves a node's logs locally and prints the parts that explain the failure.
collect_failure() {
  local name=$1 ip=$2 iid=$3
  mkdir -p "$ARTIFACTS"
  printf '\n\033[1;31m━━━ %s failed — last 60 lines of /var/log/ray-bootstrap.log ━━━\033[0m\n' "$name"
  node_ssh "$ip" 'sudo tail -n 60 /var/log/ray-bootstrap.log' || true
  node_ssh "$ip" 'sudo cat /var/log/ray-bootstrap.log' > "$ARTIFACTS/$name-bootstrap.log" 2>/dev/null || true
  node_ssh "$ip" 'sudo cat /var/log/cloud-init-output.log' > "$ARTIFACTS/$name-cloud-init.log" 2>/dev/null || true
  node_ssh "$ip" 'sudo journalctl -u ray-head -u ray-worker --no-pager -n 300' > "$ARTIFACTS/$name-ray-service.log" 2>/dev/null || true
  local resource; resource="$([ "$name" = head ] && echo 'aws_instance.head' || echo "aws_instance.worker[${name#worker-}]")"
  cat <<EOF

  Saved logs : $ARTIFACTS/$name-*.log
  Inspect    : ./scripts/logs.sh $name        (or: ssh -i "$KEY" ubuntu@$ip)
  Rebuild it : terraform -chdir=terraform apply -replace='$resource'
EOF
}

# Prints the EC2 serial console for a node we never reached over SSH.
collect_console() {
  local name=$1 iid=$2
  mkdir -p "$ARTIFACTS"
  printf '\n\033[1;33m━━━ %s: SSH never came up — EC2 console output (last 40 lines) ━━━\033[0m\n' "$name"
  aws ec2 get-console-output --instance-id "$iid" --latest --query Output --output text \
    > "$ARTIFACTS/$name-console.log" 2>&1 || true
  tail -n 40 "$ARTIFACTS/$name-console.log"
  echo "  Instance state: $(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)"
}

echo "  Following bootstrap on ${#NODES[@]} node(s); timeout ${BOOTSTRAP_TIMEOUT_MIN}m. Cold start usually takes 8-15m."
echo
deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_MIN * 60 ))
last_heartbeat=$(date +%s)
while :; do
  # Fetch every node's status file in parallel. Wait on these PIDs only: a bare
  # `wait` would also block on the tee process that writes the log file.
  pids=()
  for n in "${NODES[@]}"; do
    read -r name ip _ <<<"$n"
    ( node_ssh "$ip" 'cat /var/log/ray-bootstrap.status 2>/dev/null; echo "#SSH_OK"' > "$STATE/$name.new" 2> "$STATE/$name.err" || true ) &
    pids+=($!)
  done
  wait "${pids[@]}"

  all_done=true
  failed=()
  for n in "${NODES[@]}"; do
    read -r name ip iid <<<"$n"
    new="$STATE/$name.new"

    if ! grep -q '^#SSH_OK' "$new"; then
      if [ ! -f "$STATE/$name.waiting" ]; then
        print_event "$name" "$(date +%s)" WAIT "… instance booting, waiting for SSH"
        date +%s > "$STATE/$name.waiting"
      fi
      # A rejected login never fixes itself, so say so straight away; other
      # errors (timeouts, refused) are normal while booting, so wait a while.
      if [ ! -f "$STATE/$name.err-shown" ]; then
        waited=$(( $(date +%s) - $(cat "$STATE/$name.waiting") ))
        if grep -qiE 'permission denied|unprotected|bad permissions|not accessible|load key|invalid format' "$STATE/$name.err"; then
          warn "$name: SSH login rejected - bootstrap progress can't be read until this is fixed. ssh said:"
          sed 's/^/      /' "$STATE/$name.err"
          echo "      key used: $KEY"
          echo "      Check that this is the key Terraform installed (ssh_public_key_path / terraform/.keys/)."
          touch "$STATE/$name.err-shown"
        elif [ "$waited" -ge 240 ]; then
          warn "$name: no SSH after $((waited / 60))m (normal boot takes 1-2m). Last ssh error:"
          sed 's/^/      /' "$STATE/$name.err"
          echo "      Is your current IP ($(curl -sf --max-time 5 https://checkip.amazonaws.com || echo '?')) in allowed_cidrs?"
          touch "$STATE/$name.err-shown"
        fi
      fi
      all_done=false
      continue
    fi

    seen=$(cat "$STATE/$name.seen" 2>/dev/null || echo 0)
    grep -v '^#' "$new" > "$STATE/$name.records" || true
    tail -n +"$((seen + 1))" "$STATE/$name.records" | while IFS='|' read -r ts state step detail; do
      print_event "$name" "$ts" "$state" "$step" "$detail"
    done
    wc -l < "$STATE/$name.records" | tr -d ' ' > "$STATE/$name.seen"

    if [ ! -s "$STATE/$name.records" ] && [ ! -f "$STATE/$name.sshok" ]; then
      print_event "$name" "$(date +%s)" WAIT "… SSH up, waiting for cloud-init to start bootstrap"
    fi
    touch "$STATE/$name.sshok"

    grep -q '|FAIL|' "$STATE/$name.records" && failed+=("$n")
    grep -q '|DONE|' "$STATE/$name.records" || all_done=false
  done

  if [ ${#failed[@]} -gt 0 ]; then
    for n in "${failed[@]}"; do collect_failure $n; done
    die "Bootstrap failed on: $(printf '%s ' "${failed[@]}" | awk '{for(i=1;i<=NF;i+=3) printf "%s ", $i}')"
  fi
  $all_done && break

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo
    warn "Bootstrap did not finish within ${BOOTSTRAP_TIMEOUT_MIN}m. Where each node got to:"
    for n in "${NODES[@]}"; do
      read -r name ip iid <<<"$n"
      if [ -f "$STATE/$name.sshok" ]; then
        last="$(tail -n 1 "$STATE/$name.records" 2>/dev/null || true)"
        echo "    $name: ${last:-no steps recorded}"
        grep -q '|DONE|' "$STATE/$name.records" || collect_failure "$name" "$ip" "$iid"
      else
        collect_console "$name" "$iid"
      fi
    done
    die "Timed out waiting for bootstrap (raise with BOOTSTRAP_TIMEOUT_MIN=45)"
  fi

  # Reassure that we're alive during long steps (pip installs, image pulls).
  if [ $(( now - last_heartbeat )) -ge 60 ]; then
    printf '  \033[2m%s  … still working (%s elapsed)\033[0m\n' "$(date +%H:%M:%S)" "$(elapsed "$PHASE_START")"
    last_heartbeat=$now
  fi
  sleep "$POLL_SECONDS"
done
ok "All ${#NODES[@]} nodes bootstrapped"

# =============================================================================
phase "Verify cluster health"
# =============================================================================
EXPECTED_RAY_NODES=$((WORKERS + 1))
check() {  # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1: $2/$3"; else printf '  \033[33m…\033[0m %s: %s/%s\n' "$1" "${2:-0}" "$3"; return 1; fi
}

deadline=$(( $(date +%s) + HEALTH_TIMEOUT_MIN * 60 ))
while :; do
  echo "  $(date +%H:%M:%S)"
  healthy=true
  check "Ray dashboard reachable from here" "$(curl -sf --max-time 5 "http://$HEAD:8265" >/dev/null && echo 1 || echo 0)" 1 || healthy=false
  check "Grafana reachable from here"       "$(curl -sf --max-time 5 "http://$HEAD:3000/api/health" >/dev/null && echo 1 || echo 0)" 1 || healthy=false
  check "Ray nodes in cluster"              "$(prom_scalar 'count(up{job="ray"} == 1)')" "$EXPECTED_RAY_NODES" || healthy=false
  check "GPU exporters scraped"             "$(prom_scalar 'count(up{job="dcgm"} == 1)')" "$WORKERS" || healthy=false
  check "Host exporters scraped"            "$(prom_scalar 'count(up{job="node"} == 1)')" "$EXPECTED_RAY_NODES" || healthy=false
  $healthy && break

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    warn "Unhealthy Prometheus targets:"
    curl -sf --max-time 5 "http://$HEAD:9090/api/v1/targets?state=active" | "$PYTHON" -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    if t["health"] != "up":
        job, inst = t["labels"].get("job"), t["labels"].get("instance")
        health, err = t["health"], t.get("lastError", "")
        print(f"    {job}: {inst} -> {health} {err}")
' 2>/dev/null || warn "Prometheus API not reachable at http://$HEAD:9090 (is your IP in allowed_cidrs?)"
    echo "  ray status on head:"
    head_ssh '/opt/ray/venv/bin/ray status' 2>&1 | sed 's/^/    /' || true
    die "Cluster did not become healthy within ${HEALTH_TIMEOUT_MIN}m"
  fi
  sleep 15
done

ok "$PHASE done in $(elapsed "$PHASE_START")"
printf '\n\033[1;32m★ Cluster is ready in %s\033[0m\n' "$(elapsed "$DEPLOY_START")"
cat <<EOF

  Ray dashboard : http://$HEAD:8265
  Grafana       : http://$HEAD:3000   (user: admin, password: terraform -chdir=terraform output -raw grafana_admin_password)
  Prometheus    : http://$HEAD:9090
  SSH (head)    : ssh -i "$KEY" ubuntu@$HEAD
  Deploy log    : $LOG_FILE

  Next: ./scripts/run-gpu-test.sh   # load every GPU and watch the dashboard
EOF
