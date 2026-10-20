#!/usr/bin/env bash
# Submit examples/gpu_stress.py as a Ray job that loads every GPU in the cluster.
#   ./scripts/run-gpu-test.sh [seconds]   (default 300)
source "$(dirname "$0")/common.sh"

SECONDS_TO_RUN="${1:-300}"
HEAD="$(head_ip)"

log "Uploading job to head"
head_ssh 'mkdir -p ~/jobs/gpu_stress'
ssh_opts
scp "${SSH_OPTS[@]}" "$ROOT_DIR/examples/gpu_stress.py" "ubuntu@$HEAD:jobs/gpu_stress/"

log "Submitting Ray job (installs torch on workers on first run). Watch: http://$HEAD:3000"
head_ssh "/opt/ray/venv/bin/ray job submit --address http://127.0.0.1:8265 \
  --working-dir ~/jobs/gpu_stress \
  --runtime-env-json '{\"pip\": [\"torch\"]}' \
  -- python gpu_stress.py --seconds $SECONDS_TO_RUN"
