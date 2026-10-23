#!/usr/bin/env bash
# Deploy a Hugging Face model to the Ray GPU cluster from ../gpu-workers and
# serve it as an OpenAI-compatible API (Ray Serve + vLLM) on the head, port 8000.
#   ./scripts/deploy.sh [--model <hf-id>] [options]    (--help lists them)
# Re-running with other options updates the deployment in place.
source "$(dirname "$0")/common.sh"

MODEL="${LLM_MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
SERVED_NAME=""
REVISION=""
REPLICAS=""
TP=1
MAX_MODEL_LEN=4096
DTYPE=auto
GPU_MEM=0.90
MAX_ONGOING=64
TRUST_REMOTE_CODE=false
VLLM_VERSION="${VLLM_VERSION:-0.6.6.post1}"
HF_TOKEN_FILE=""
SKIP_DOWNLOAD=0
TIMEOUT_MIN=40
TRACING=1
TEMPO_IMAGE="${TEMPO_IMAGE:-grafana/tempo:2.6.1}"
ENGINE_ARGS=()

usage() {
  cat <<EOF
Usage: ./scripts/deploy.sh [options]

Model
  --model ID                  Hugging Face model ID (default: $MODEL)
  --revision REV              Branch, tag or commit of the model repo
  --name NAME                 Model name clients put in requests (default: the model ID)
  --trust-remote-code         Allow custom model code from the repo
  --hf-token-file PATH        File with a Hugging Face token, for gated models (default: \$HF_TOKEN)

Placement
  --replicas N                Copies of the model (default: as many as the cluster's GPUs fit)
  --tp N                      GPUs per copy, all on one node (tensor parallelism; default 1)

Engine
  --max-model-len N           Context length in tokens (default 4096; 0 = the model's full context)
  --dtype TYPE                auto|half|float16|bfloat16|float32 (default auto = half on pre-Ampere GPUs like the T4)
  --gpu-memory-utilization F  Share of each GPU's memory vLLM may use (default 0.90)
  --max-ongoing-requests N    Concurrent requests per copy (default 64)
  --engine-arg KEY=VALUE      Any other vLLM engine argument, e.g. quantization=awq (repeatable)
  --vllm-version V            vLLM version installed on the workers (default $VLLM_VERSION)

Other
  --skip-download             Let the replicas download the model themselves
  --no-tracing                Don't trace requests (default: every request is traced to Tempo on the head)
  --timeout MIN               How long to wait for the model to come up (default 40)
EOF
}

need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --model)                  need "$@"; MODEL=$2; shift 2 ;;
    --revision)               need "$@"; REVISION=$2; shift 2 ;;
    --name)                   need "$@"; SERVED_NAME=$2; shift 2 ;;
    --trust-remote-code)      TRUST_REMOTE_CODE=true; shift ;;
    --hf-token-file)          need "$@"; HF_TOKEN_FILE=$2; shift 2 ;;
    --replicas)               need "$@"; REPLICAS=$2; shift 2 ;;
    --tp)                     need "$@"; TP=$2; shift 2 ;;
    --max-model-len)          need "$@"; MAX_MODEL_LEN=$2; shift 2 ;;
    --dtype)                  need "$@"; DTYPE=$2; shift 2 ;;
    --gpu-memory-utilization) need "$@"; GPU_MEM=$2; shift 2 ;;
    --max-ongoing-requests)   need "$@"; MAX_ONGOING=$2; shift 2 ;;
    --engine-arg)             need "$@"; ENGINE_ARGS+=("$2"); shift 2 ;;
    --vllm-version)           need "$@"; VLLM_VERSION=$2; shift 2 ;;
    --skip-download)          SKIP_DOWNLOAD=1; shift ;;
    --no-tracing)             TRACING=0; shift ;;
    --timeout)                need "$@"; TIMEOUT_MIN=$2; shift 2 ;;
    -h|--help)                usage; exit 0 ;;
    *)                        die "Unknown option: $1 (see --help)" ;;
  esac
done

# These values end up in remote shell commands, so keep them to safe characters.
SAFE='^[A-Za-z0-9._/:-]+$'
SERVED_NAME="${SERVED_NAME:-$MODEL}"
[[ $MODEL =~ $SAFE ]]       || die "Invalid model ID: $MODEL"
[[ $SERVED_NAME =~ $SAFE ]] || die "Invalid --name: $SERVED_NAME"
[ -z "$REVISION" ] || [[ $REVISION =~ $SAFE ]] || die "Invalid --revision: $REVISION"
[[ $VLLM_VERSION =~ $SAFE ]] || die "Invalid --vllm-version: $VLLM_VERSION"
[[ $TP =~ ^[1-9][0-9]*$ ]]  || die "--tp must be a positive integer"
[ -z "$REPLICAS" ] || [[ $REPLICAS =~ ^[1-9][0-9]*$ ]] || die "--replicas must be a positive integer"
[[ $MAX_MODEL_LEN =~ ^[0-9]+$ ]] || die "--max-model-len must be an integer"
[[ $MAX_ONGOING =~ ^[1-9][0-9]*$ ]] || die "--max-ongoing-requests must be a positive integer"
[[ $TIMEOUT_MIN =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
[[ $GPU_MEM =~ ^0?\.[0-9]+$|^1(\.0+)?$ ]] || die "--gpu-memory-utilization must be between 0 and 1"
case "$DTYPE" in auto|half|float16|bfloat16|float32) ;; *) die "Invalid --dtype: $DTYPE" ;; esac

HF_TOKEN_VALUE="${HF_TOKEN:-}"
if [ -n "$HF_TOKEN_FILE" ]; then
  [ -f "$HF_TOKEN_FILE" ] || die "Token file not found: $HF_TOKEN_FILE"
  HF_TOKEN_VALUE="$(tr -d '[:space:]' <"$HF_TOKEN_FILE")"
fi

RUN_DIR="$LLM_DIR/logs/deploy-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR.log") 2>&1
DEPLOY_START=$(date +%s)

phase() { printf '\n\033[1;36m━━━ [%s/5] %s ━━━\033[0m\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
phase 1 "Preflight"
[ -n "$PYTHON" ] || die "Python 3 is required"
for tool in ssh scp curl terraform; do
  command -v "$tool" >/dev/null || die "$tool not found (run $GPU_WORKERS_DIR/scripts/setup.sh)"
done
require_cluster
NODES="$(cluster_nodes)"
WORKERS="$(grep -v '^head ' <<<"$NODES")"
RAY_VERSION="$(hssh "$REMOTE_VENV/bin/python -c 'import ray; print(ray.__version__)'")"
log "Cluster head $HEAD, Ray $RAY_VERSION, $(grep -c . <<<"$WORKERS") GPU worker(s)"

ALL_GPUS=""
CAPACITY=0   # model copies the cluster fits: floor(GPUs / tp) per node
while read -r name ip _; do
  gpus="$(node_ssh "$ip" nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader)" \
    || die "Could not query the GPUs on $name ($ip)"
  count=$(grep -c . <<<"$gpus")
  printf '  %-9s %d x %s\n' "$name" "$count" "$(head -n 1 <<<"$gpus")"
  CAPACITY=$((CAPACITY + count / TP))
  ALL_GPUS+="$gpus"$'\n'
done <<<"$WORKERS"

[ "$CAPACITY" -ge 1 ] || die "No worker has $TP GPUs for --tp $TP. Use a bigger worker_instance_type or a smaller --tp."
REPLICAS="${REPLICAS:-$CAPACITY}"
if [ "$REPLICAS" -gt "$CAPACITY" ]; then
  warn "$REPLICAS replicas requested but the cluster fits $CAPACITY; the rest will wait for free GPUs"
fi

MIN_CC="$(awk -F', *' 'NF >= 3 { print $3 }' <<<"$ALL_GPUS" | sort -n | head -n 1)"
if [ "$DTYPE" = auto ] && awk -v c="$MIN_CC" 'BEGIN { exit !(c < 8.0) }'; then
  DTYPE=half
  log "GPUs with compute capability $MIN_CC can't run bfloat16; using --dtype half"
fi

log "Plan: $MODEL as '$SERVED_NAME', $REPLICAS replica(s) x $TP GPU, dtype $DTYPE, context $([ "$MAX_MODEL_LEN" = 0 ] && echo "model default" || echo "$MAX_MODEL_LEN"), vLLM $VLLM_VERSION"
[ -n "$HF_TOKEN_VALUE" ] && log "Using a Hugging Face token" || true

# ---------------------------------------------------------------------------
phase 2 "Install Ray Serve + vLLM on the nodes (first run: ~5 min)"
prepare_node() {
  local name=$1 ip=$2 role=worker
  [ "$name" != head ] || role=head
  ssh_opts
  node_ssh "$ip" "mkdir -p ~/$REMOTE_DIR/app ~/$REMOTE_DIR/bin"
  scp -q "${SSH_OPTS[@]}" "$LLM_DIR/app/llm_serve.py" "ubuntu@$ip:$REMOTE_DIR/app/"
  scp -q "${SSH_OPTS[@]}" "$LLM_DIR/remote/prepare-node.sh" "$LLM_DIR/remote/predownload.py" "ubuntu@$ip:$REMOTE_DIR/bin/"
  if [ -n "$HF_TOKEN_VALUE" ]; then
    # Over stdin, so the token never shows up in a process list.
    printf '%s' "$HF_TOKEN_VALUE" | ssh "${SSH_OPTS[@]}" "ubuntu@$ip" \
      'umask 077; mkdir -p ~/.cache/huggingface && cat > ~/.cache/huggingface/token'
  fi
  node_ssh "$ip" "bash ~/$REMOTE_DIR/bin/prepare-node.sh $role $RAY_VERSION $VLLM_VERSION"
}
run_parallel prepare prepare_node "$NODES" || die "Installing on the nodes failed. Logs: $RUN_DIR"

# The dashboard serves Ray Serve's REST API only if Serve was installed when
# it started, so the first install needs one restart of the Ray head.
serve_api_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$HEAD:$DASHBOARD_PORT/api/serve/applications/" || true
}
if [ "$(serve_api_code)" != 200 ]; then
  warn "Restarting the Ray head once so its dashboard loads Ray Serve (workers rejoin on their own)"
  hssh 'sudo systemctl restart ray-head'
  want=$(grep -c . <<<"$NODES")
  deadline=$(( $(date +%s) + 600 ))
  while :; do
    alive="$(hssh "$REMOTE_VENV/bin/python -c \"import ray; ray.init(address='auto', logging_level='ERROR'); print(sum(n['Alive'] for n in ray.nodes()))\"" 2>/dev/null | tail -n 1 || true)"
    if [ "$alive" = "$want" ] && [ "$(serve_api_code)" = 200 ]; then break; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "Ray did not come back with all $want nodes after the restart (alive: ${alive:-?}). Check $GPU_WORKERS_DIR/scripts/status.sh"
    printf '  %s  \033[2mwaiting for Ray: %s/%s nodes alive\033[0m\n' "$(fmt_time "$(date +%s)")" "${alive:-0}" "$want"
    sleep 15
  done
  log "Ray is back with $want nodes"
fi

# ---------------------------------------------------------------------------
phase 3 "Download $MODEL to the GPU workers"
download_model() {
  node_ssh "$2" "$REMOTE_VENV/bin/python ~/$REMOTE_DIR/bin/predownload.py '$MODEL' '$REVISION'"
}
if [ "$SKIP_DOWNLOAD" = 1 ]; then
  log "Skipped (--skip-download); replicas download the model when they start"
else
  run_parallel download download_model "$WORKERS" || die "Downloading the model failed. Logs: $RUN_DIR"
fi

# ---------------------------------------------------------------------------
phase 4 "Deploy to Ray Serve"
OTLP_ENDPOINT=""
if [ "$TRACING" = 1 ]; then
  # Tempo stores the request traces; replicas export to it over the private network.
  log "Starting Tempo on the head for request tracing"
  ssh_opts
  hssh "mkdir -p ~/$REMOTE_DIR/bin ~/$REMOTE_DIR/tempo"
  scp -q "${SSH_OPTS[@]}" "$LLM_DIR/remote/start-tempo.sh" "ubuntu@$HEAD:$REMOTE_DIR/bin/"
  scp -q "${SSH_OPTS[@]}" "$LLM_DIR/observability/tempo/tempo.yaml" "$LLM_DIR/observability/tempo/datasource.yml" \
    "$LLM_DIR/observability/tempo/grafana-override.yml" "ubuntu@$HEAD:$REMOTE_DIR/tempo/"
  hssh "bash ~/$REMOTE_DIR/bin/start-tempo.sh '$TEMPO_IMAGE'" 2>&1 | sed 's/^/  /' \
    || die "Tempo did not start on the head (rerun with --no-tracing to deploy without it)"
  OTLP_ENDPOINT="http://$(tf_out head_private_ip):4317"
else
  log "Request tracing off (--no-tracing)"
fi
CONFIG="$RUN_DIR/serve-config.yaml"
# A new hash when llm_serve.py or the pinned packages in prepare-node.sh change
# makes Serve redeploy with fresh worker processes, so no replica keeps running
# old code - and a failed app is retried against what was just installed rather
# than left in its stale DEPLOY_FAILED state by an otherwise identical config.
APP_SHA="$(cat "$LLM_DIR/app/llm_serve.py" "$LLM_DIR/remote/prepare-node.sh" \
  | "$PYTHON" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
export MODEL SERVED_NAME REVISION TP DTYPE GPU_MEM MAX_MODEL_LEN TRUST_REMOTE_CODE \
  REPLICAS MAX_ONGOING SERVE_APP SERVE_PORT APP_SHA OTLP_ENDPOINT
"$PYTHON" - ${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"} >"$CONFIG" <<'EOF'
import json, os, sys

e = os.environ
engine = {
    "tensor_parallel_size": int(e["TP"]),
    "dtype": e["DTYPE"],
    "gpu_memory_utilization": float(e["GPU_MEM"]),
    "trust_remote_code": e["TRUST_REMOTE_CODE"] == "true",
}
if int(e["MAX_MODEL_LEN"]):
    engine["max_model_len"] = int(e["MAX_MODEL_LEN"])
if e["REVISION"]:
    engine["revision"] = e["REVISION"]
for item in sys.argv[1:]:
    key, sep, value = item.partition("=")
    if not sep or not key:
        sys.exit(f"--engine-arg expects KEY=VALUE, got {item!r}")
    try:
        engine[key.replace("-", "_")] = json.loads(value)   # numbers, true/false, JSON
    except ValueError:
        engine[key.replace("-", "_")] = value

config = {
    "proxy_location": "HeadOnly",
    "http_options": {"host": "0.0.0.0", "port": int(e["SERVE_PORT"])},
    "applications": [{
        "name": e["SERVE_APP"],
        "route_prefix": "/",
        "import_path": "llm_serve:build_app",
        "runtime_env": {"env_vars": {"LLM_SERVE_APP_SHA": e["APP_SHA"]}},
        "args": {
            "model": e["MODEL"],
            "served_model_name": e["SERVED_NAME"],
            "num_replicas": int(e["REPLICAS"]),
            "max_ongoing_requests": int(e["MAX_ONGOING"]),
            "otlp_endpoint": e["OTLP_ENDPOINT"],
            "engine_args": engine,
        },
    }],
}
print("# Generated by llm-deployment/scripts/deploy.sh (JSON is valid YAML)")
print(json.dumps(config, indent=2))
EOF
ssh_opts
scp -q "${SSH_OPTS[@]}" "$CONFIG" "ubuntu@$HEAD:$REMOTE_DIR/serve-config.yaml"
hssh "$REMOTE_VENV/bin/serve deploy ~/$REMOTE_DIR/serve-config.yaml --address http://127.0.0.1:$DASHBOARD_PORT"
log "Serve config saved to $CONFIG"

# Grafana on the head loads new dashboard files from this directory within 30s.
log "Installing the LLM Serving dashboard in Grafana"
scp -q "${SSH_OPTS[@]}" "$LLM_DIR/observability/llm-serving.json" "ubuntu@$HEAD:$REMOTE_DIR/"
hssh "sudo install -D -m 644 ~/$REMOTE_DIR/llm-serving.json /opt/observability/grafana/dashboards/llm/llm-serving.json"

# ---------------------------------------------------------------------------
phase 5 "Wait for the model to load"
NODE_MAP="$(node_map)"
export NODE_MAP
wait_start=$(date +%s)
deadline=$(( wait_start + TIMEOUT_MIN * 60 ))
last=""; last_print=0
while :; do
  summary="$(serve_details | "$PYTHON" -c "$SERVE_SUMMARY_PY" "$SERVE_APP" 2>/dev/null)" \
    || summary="UNKNOWN|dashboard not answering|"
  status=${summary%%|*}; rest=${summary#*|}; replicas=${rest%%|*}; message=${rest#*|}
  now=$(date +%s)
  if [ "$summary" != "$last" ] || [ $((now - last_print)) -ge 60 ]; then
    printf '  %s  %-13s %s \033[2m(%s)\033[0m\n' "$(fmt_time "$now")" "$status" "$replicas" "$(elapsed "$wait_start")"
    if [ -n "$message" ] && [ "$summary" != "$last" ]; then
      printf '                 \033[2m%s\033[0m\n' "$message"
    fi
    last=$summary; last_print=$now
  fi
  case "$status" in
    RUNNING) break ;;
    DEPLOY_FAILED|UNHEALTHY)
      printf '\n\033[1;31mServe reports %s:\033[0m\n' "$status"
      serve_details | "$PYTHON" -c "$SERVE_SUMMARY_PY" "$SERVE_APP" message | sed 's/^/  /' || true
      printf '\n'
      bash "$LLM_DIR/scripts/logs.sh" all 40 || true
      die "Deployment failed. More: ./scripts/logs.sh <worker-N>, or the Serve tab at http://$HEAD:$DASHBOARD_PORT" ;;
  esac
  [ "$now" -lt "$deadline" ] || die "Model not up after $TIMEOUT_MIN min (status $status). Check ./scripts/status.sh and ./scripts/logs.sh"
  sleep 10
done

log "Smoke test"
SMOKE="{\"model\": \"$SERVED_NAME\", \"prompt\": \"The capital of France is\", \"max_tokens\": 16, \"temperature\": 0}"
reply="$(hssh "curl -sS --max-time 180 -H 'Content-Type: application/json' -d '$SMOKE' http://127.0.0.1:$SERVE_PORT/v1/completions")" \
  || die "The API did not answer on the head: $reply"
"$PYTHON" -c '
import json, sys
r = json.load(sys.stdin)
if "error" in r:
    sys.exit("ERROR: " + r["error"]["message"])
print("  The capital of France is" + r["choices"][0]["text"].rstrip())
print("  (%d prompt + %d completion tokens)" % (r["usage"]["prompt_tokens"], r["usage"]["completion_tokens"]))' <<<"$reply" \
  || die "Unexpected reply from the API: $reply"

# The smoke test produced engine stats; wait for them to reach Prometheus
# (Ray exports every ~10s, Prometheus scrapes every 5s).
log "Checking that LLM metrics reach Prometheus"
METRICS=0
for _ in $(seq 1 12); do
  series="$(prom_scalar 'count({__name__=~"ray_llm_.+"})')"
  if [ -n "$series" ] && [ "${series%.*}" -gt 0 ]; then METRICS=1; break; fi
  sleep 10
done
if [ "$METRICS" = 1 ]; then
  log "Prometheus has $series ray_llm_* series"
else
  warn "No ray_llm_* metrics in Prometheus after 2 min. Check ./scripts/logs.sh for 'metrics logger' errors and http://$HEAD:9090/targets (job 'ray')"
fi

TRACE_ID=""
if [ "$TRACING" = 1 ]; then
  # Spans leave the replica in batches every ~5s; Tempo makes them searchable soon after.
  log "Checking that request traces reach Tempo"
  for _ in $(seq 1 12); do
    TRACE_ID="$(hssh "curl -s -G --max-time 10 http://127.0.0.1:3200/api/search \
      --data-urlencode 'q={resource.service.name=\"llm-serve\"}' --data-urlencode limit=1" 2>/dev/null \
      | "$PYTHON" -c 'import json, sys; t = json.load(sys.stdin).get("traces") or []; print(t[0]["traceID"] if t else "")' 2>/dev/null || true)"
    [ -z "$TRACE_ID" ] || break
    sleep 5
  done
  if [ -n "$TRACE_ID" ]; then
    log "Tempo is receiving traces, e.g. $(trace_url "$TRACE_ID")"
  else
    warn "No llm-serve traces in Tempo after 1 min. Check ./scripts/logs.sh for OpenTelemetry export errors and: ssh to the head, docker logs llm-tempo"
  fi
fi

API="$(api_url)"
if curl -sf --max-time 10 "$API/v1/models" >/dev/null; then
  REACHABLE=1
else
  REACHABLE=0
  warn "Port $SERVE_PORT on the head isn't reachable from this machine. Apply the gpu-workers security-group rule for it:
      terraform -chdir=$GPU_WORKERS_DIR/terraform apply
  or tunnel through SSH meanwhile and set LLM_API_URL for the other scripts:
      ssh -i $SSH_KEY -N -L $SERVE_PORT:127.0.0.1:$SERVE_PORT ubuntu@$HEAD
      export LLM_API_URL=http://127.0.0.1:$SERVE_PORT"
fi

printf '\n\033[1;32m★ %s is serving as "%s" (%s total)\033[0m\n' "$MODEL" "$SERVED_NAME" "$(elapsed "$DEPLOY_START")"
cat <<EOF

  OpenAI base URL  $API/v1$([ "$REACHABLE" = 1 ] || echo "   (not reachable from here yet, see above)")
  LLM dashboard    http://$HEAD:3000/d/llm-serving   (throughput, latency, KV cache, GPUs, recent traces)
  Request traces   $([ "$TRACING" = 1 ] && echo "Grafana > Explore > Tempo; every response has an X-Trace-Id header" || echo "off (--no-tracing)")
  Ray dashboard    http://$HEAD:$DASHBOARD_PORT/#/serve

  ./scripts/chat.sh "Explain Ray Serve in one sentence"
  ./scripts/load-test.sh            # 100 requests, 8 at a time; watch the dashboard
  curl $API/v1/chat/completions -H 'Content-Type: application/json' \\
    -d '{"model": "$SERVED_NAME", "messages": [{"role": "user", "content": "Hello!"}]}'

  Python:  OpenAI(base_url="$API/v1", api_key="unused")
  Logs of this run: $RUN_DIR.log
EOF
