# LLM Deployment: Hugging Face models on the Ray GPU cluster

One command takes a model from Hugging Face and serves it on the Ray cluster built by
[`../gpu-workers`](../gpu-workers/README.md), as an **OpenAI-compatible API**.
It uses **Ray Serve** for routing and replicas, and **vLLM** for inference.

```
 client (your IP) ──▶ head :8000  Ray Serve HTTP proxy (route /v1/...)
                          │
            ┌─────────────┴──────────────┐
            ▼                            ▼
   worker-0: LLMServer replica   worker-1: LLMServer replica     (one per GPU by default)
             vLLM engine on GPU            vLLM engine on GPU
             model from ~/.cache/huggingface
```

| Endpoint | |
|---|---|
| `GET /v1/models` | The served model |
| `POST /v1/chat/completions` | Chat (uses the model's chat template); `"stream": true` supported |
| `POST /v1/completions` | Plain text completion; `"stream": true` supported |
| `GET /health` | Engine health |

## Prerequisites

- A running cluster: `../gpu-workers/scripts/deploy.sh`. These scripts read its Terraform
  outputs and reuse its SSH key and AWS profile, so there's nothing else to configure.
- **Port 8000 open to your IP.** The gpu-workers Terraform opens it for `allowed_cidrs`. On a
  cluster created before that rule existed, apply it once (this only adds a security-group rule;
  no instances are replaced):
  ```bash
  terraform -chdir=../gpu-workers/terraform apply
  ```
- For **gated models** (Llama, Gemma, Mistral…): accept the license on the model's Hugging Face
  page, then `export HF_TOKEN=hf_...` or pass `--hf-token-file`.

## Quick start

```bash
cd llm-deployment
./scripts/deploy.sh                        # Qwen/Qwen2.5-1.5B-Instruct, one replica per GPU
./scripts/chat.sh "Explain Ray Serve in one sentence"
./scripts/chat.sh --stream "Write a haiku about GPUs"
./scripts/load-test.sh                     # 100 concurrent requests; watch the LLM Serving dashboard
./scripts/status.sh                        # app state, replicas per node, API check
./scripts/logs.sh                          # replica + vLLM logs from every worker
./scripts/undeploy.sh                      # free GPUs/CPU/memory, wait for the nodes to drain, delete the model + caches, report each node (cluster keeps running; --keep-model-cache to skip re-downloading)
```

Other models:

```bash
./scripts/deploy.sh --model microsoft/Phi-3.5-mini-instruct
./scripts/deploy.sh --model Qwen/Qwen2.5-7B-Instruct-AWQ --engine-arg quantization=awq
HF_TOKEN=hf_... ./scripts/deploy.sh --model meta-llama/Llama-3.1-8B-Instruct --name llama-8b --max-model-len 8192
```

Running `deploy.sh` again with different options updates the deployment in place (Serve
replaces the replicas). Only **one model** is served at a time: a new deploy replaces the old one.

### What `deploy.sh` does

1. **Preflight**: finds the cluster, reads the Ray version, lists the GPUs on every worker,
   and works out how many replicas fit and which dtype the GPUs support.
2. **Install** (in parallel on all nodes): Ray Serve on the head, Ray Serve + vLLM in Ray's venv
   (`/opt/ray/venv`) on the workers, with Ray pinned to the cluster's version. It also installs the
   Serve app (`app/llm_serve.py`) and your Hugging Face token. The first run takes about 5 minutes;
   later runs skip anything already installed. On the very first install the Ray head restarts once
   so its dashboard picks up Ray Serve; the workers rejoin automatically.
3. **Download**: every GPU worker fetches the model weights into `~/.cache/huggingface`,
   using the same file selection as vLLM. Problems such as a gated model or a wrong ID show up here with a clear message.
4. **Deploy**: starts Grafana Tempo on the head for request traces, writes a Ray Serve config,
   runs `serve deploy` on the head, installs the **LLM Serving** and **vLLM Engine** Grafana
   dashboards, and sets up Prometheus to scrape every replica's native vLLM metrics
   (see [Native vLLM metrics](#native-vllm-metrics)).
5. **Wait + verify**: follows replica states until the app is `RUNNING`, sends a test request
   through the head, checks that `ray_llm_*` metrics and every replica's `vllm:*` metrics reach
   Prometheus and traces reach Tempo, and checks that the API is reachable from your machine.

All output is saved to `logs/deploy-<time>.log`; per-node install and download logs
and the generated Serve config are in `logs/deploy-<time>/`.

## Options

| Option | Default | Notes |
|---|---|---|
| `--model ID` | `Qwen/Qwen2.5-1.5B-Instruct` | Any Hugging Face model vLLM supports (or set `LLM_MODEL`) |
| `--name NAME` | the model ID | The `model` value clients send |
| `--revision REV` | latest | Branch, tag or commit |
| `--replicas N` | as many as fit | One per `--tp` GPUs on each worker |
| `--tp N` | `1` | GPUs per replica (tensor parallelism), all on one node, e.g. `--tp 4` on `g5.12xlarge` |
| `--max-model-len N` | `4096` | Context length; `0` uses the model's full context. Longer contexts need more GPU memory for the KV cache |
| `--dtype TYPE` | `auto` | `auto` becomes `half` on GPUs without bfloat16 support (T4 / g4dn) |
| `--gpu-memory-utilization F` | `0.90` | Share of GPU memory vLLM reserves for weights + KV cache |
| `--max-ongoing-requests N` | `64` | Concurrent requests per replica (vLLM batches them) |
| `--engine-arg KEY=VALUE` | | Any other [vLLM engine argument](https://docs.vllm.ai/en/v0.6.6/models/engine_args.html), e.g. `quantization=awq`, `enforce_eager=true` |
| `--trust-remote-code` | off | Needed by models that ship custom code |
| `--hf-token-file PATH` | `$HF_TOKEN` | Token for gated or private models |
| `--vllm-version V` | `0.6.6.post1` | Must work with the cluster's Ray (`2.40.0`) and Python 3.10 |
| `--skip-download` | | Let replicas download the model as they start |
| `--no-tracing` | tracing on | Don't start Tempo or trace requests |
| `--timeout MIN` | `40` | How long to wait for replicas to become ready |

### Picking a model for your GPUs

At 16-bit precision the weights take about **2 GB per billion parameters**, and vLLM needs extra GPU memory on top for the KV cache.

| Worker | GPU memory | Fits well (one replica per GPU) |
|---|---|---|
| `g4dn.xlarge` | 1× T4, 16 GB | Up to ~4B in fp16 (Qwen2.5-1.5B/3B, Phi-3.5-mini, Llama-3.2-3B); 7–8B with AWQ |
| `g5.xlarge` | 1× A10G, 24 GB | 7–8B in bf16 (Qwen2.5-7B, Llama-3.1-8B, Mistral-7B) |
| `g5.12xlarge` | 4× A10G, 96 GB | ~30B with `--tp 4`, or four 7–8B replicas |
| `p4d.24xlarge` | 8× A100 40 GB | 70B with `--tp 8` |

## Using the API

```bash
curl http://<head>:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen2.5-1.5B-Instruct",
  "messages": [{"role": "user", "content": "Hello!"}],
  "max_tokens": 128
}'
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://<head>:8000/v1", api_key="unused")
reply = client.chat.completions.create(
    model="Qwen/Qwen2.5-1.5B-Instruct",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(reply.choices[0].message.content)
```

Supported request fields: `messages` / `prompt`, `max_tokens` (or `max_completion_tokens`), `temperature`, `top_p`,
`top_k`, `n`, `stop`, `seed`, `presence_penalty`, `frequency_penalty`, `repetition_penalty`,
`min_tokens` and `stream`. If you leave out `max_tokens`, the reply can use the rest of the context.

## Load test

```bash
./scripts/load-test.sh                                   # 100 requests, 8 concurrent, max_tokens 128
./scripts/load-test.sh --requests 500 --concurrency 32   # push harder: watch requests start waiting
```

It reports successes and failures, requests/s, generated tokens/s, and p50/p95 latency, plus
links to the traces of the three slowest requests. It exits non-zero if any request failed, so it
also works as a liveness check in scripts.

## Metrics and dashboards

Each replica records vLLM's engine stats as Ray metrics. Ray exports them on every node's metrics
port (8080), which the cluster's Prometheus already scrapes, so they need no extra ports or scrape config.
`deploy.sh` installs the **LLM Serving** dashboard at `http://<head>:3000/d/llm-serving` (Grafana folder *llm*):

| Row | Panels |
|---|---|
| Overview | Replicas reporting, requests running / waiting, generated tokens/s, p95 time to first token, max KV-cache usage |
| Traffic | Prompt and generated tokens/s, HTTP requests/s by status code (from Ray Serve), finished requests by reason (`stop` / `length`) |
| Latency | Time to first token, time per output token, end-to-end latency (p50/p95/p99), queue time |
| Engine | Running/waiting requests and KV-cache usage per replica, preemptions |
| GPUs | Utilization, memory and power per GPU (DCGM) |
| Request traces | Recent requests, and slow (> 5 s) or failed ones, from Tempo; click a trace ID to open it |

The metrics are in Prometheus (`http://<head>:9090`) as:

| Metric | Type |
|---|---|
| `ray_llm_num_requests_running`, `ray_llm_num_requests_waiting` | gauge |
| `ray_llm_gpu_cache_usage` | gauge, 0–1 |
| `ray_llm_prompt_tokens_total`, `ray_llm_generation_tokens_total`, `ray_llm_num_preemptions_total` | counter |
| `ray_llm_request_finished_total{finished_reason}` | counter |
| `ray_llm_time_to_first_token_seconds`, `ray_llm_time_per_output_token_seconds`, `ray_llm_e2e_request_latency_seconds`, `ray_llm_request_queue_time_seconds` | histogram |

All of them carry `model` and `replica` labels. Ray Serve's own metrics (`ray_serve_*`) and dashboards
(Grafana folder *ray*) cover the HTTP side, and the Ray dashboard's *Serve* tab (`http://<head>:8265`)
shows replicas and their logs.

## Native vLLM metrics

Besides the `ray_llm_*` copies above, every replica exposes **vLLM's own Prometheus metrics** (`vllm:*`,
exactly as vLLM defines them), and Prometheus scrapes each replica directly. The **vLLM Engine**
dashboard (`http://<head>:3000/d/vllm-engine`, folder *llm*) and a set of alert rules use them.

```
 worker-N  replica on GPU g ──▶ <private IP>:8300+g /metrics   vllm:* + llm_serve_*   (private network only)
                                        ▲
 head      llm-metrics-sd ──────────────┤ every 15s: where does Ray Serve run replicas? which ports answer?
             │ writes targets file      │
             ▼                          │
           Prometheus  job "vllm" ──────┘ scrapes each replica (never the load-balanced :8000)
                       job "vllm-sd"   ◀── llm-metrics-sd's own metrics: Serve replica states
                       rules           ──▶ alerts at :9090/alerts and on the dashboard
```

**How it works**

- **In each replica**, vLLM 0.6.6 already records its metrics in the process's `prometheus_client`
  registry, but only vLLM's own OpenAI server serves them over HTTP, and this app uses Ray Serve
  instead. `app/llm_serve.py` serves that registry on the worker's **private IP** at port
  `8300 + <first GPU index>`, so replicas sharing a node never collide and a GPU always keeps the same
  port. The port isn't in the security group's operator rules, so only cluster nodes can reach it. It
  adds a few `llm_serve_*` series (below). Set `LLM_METRICS_PORT_BASE` to move the range (8 ports).
- **On the head**, the `llm-metrics-sd` systemd service asks Ray Serve's REST API which nodes run
  replicas, probes those nodes' ports for a replica, and writes the targets to
  `/opt/observability/prometheus/llm/targets/vllm.json` (Prometheus `file_sd`). Target labels are stable:
  `instance` (`<ip>:<port>`), `application`, `deployment`, `private_ip`, `gpu_slot`. If a replica stops
  answering, its target stays listed (so `up` goes to 0 and alerts fire) until Serve no longer has a
  replica on that node or the target has been silent for 10 minutes.
- **Prometheus config**: `deploy.sh` runs `remote/setup-vllm-metrics.sh`, which *merges* the `vllm` and
  `vllm-sd` jobs and a `rule_files` entry into the head's Terraform-rendered `prometheus.yml`. It also adds a
  read-only mount of `/opt/observability/prometheus/llm` to the `prometheus` service in
  `docker-compose.yml`. Other jobs, services and settings are kept. The Terraform originals are saved
  once as `*.orig`. The merged config is checked with the running Prometheus image's `promtool` before
  anything is changed. After that, Prometheus is reloaded, or recreated the first time to add the mount;
  its data volume is kept. Rerunning `deploy.sh` changes nothing unless a file differs.
- Nothing in `../gpu-workers` changes. Changing its head templates would make Terraform **replace the head
  node**, so the integration is installed by `deploy.sh`, like Tempo and the dashboards.

**Metrics** (verified against the vLLM `0.6.6.post1` source, `vllm/engine/metrics.py`). All `vllm:*` series
have the label `model_name`, which is the served name (`--name`):

| Metric | Type | Used for |
|---|---|---|
| `vllm:num_requests_running`, `vllm:num_requests_waiting`, `vllm:num_requests_swapped` | gauge | Batch size and queue (sampled at engine steps) |
| `vllm:request_success_total{finished_reason}` | counter | Completions |
| `vllm:time_to_first_token_seconds`, `vllm:time_per_output_token_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:request_queue_time_seconds`, `vllm:request_prefill_time_seconds`, `vllm:request_decode_time_seconds` | histogram (seconds) | Latency |
| `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` | counter | Token throughput |
| `vllm:request_prompt_tokens`, `vllm:request_generation_tokens` | histogram (tokens) | Tokens per request |
| `vllm:iteration_tokens_total` | histogram (tokens) | Tokens per engine iteration |
| `vllm:gpu_cache_usage_perc` | gauge, 0–1 | KV-cache usage |
| `vllm:num_preemptions_total` | counter | Preemptions |
| `vllm:gpu_prefix_cache_hit_rate` | gauge, 0–1 or −1 | Prefix cache (see below) |
| `vllm:cache_config_info` | gauge = 1 | Cache config as labels (`num_gpu_blocks`, `block_size`, …) |
| `llm_serve_requests_received_total{route}` | counter | **Arrivals.** vLLM 0.6.6 has no arrival counter, so the app counts requests as they arrive |
| `llm_serve_responses_total{route,code}` | counter | Responses by HTTP status (499 = client disconnected) |
| `llm_serve_max_num_seqs`, `llm_serve_max_ongoing_requests`, `llm_serve_max_num_batched_tokens`, `llm_serve_kv_cache_capacity_tokens` | gauge | Capacity limits, for headroom panels |
| `llm_serve_replica_info{replica_id,serve_application,serve_deployment,gpu_ids,vllm_version}` | gauge = 1 | Replica identity (read by discovery) |
| `llm_sd_replicas{application,deployment,state}` | gauge | Replicas per state from Ray Serve (**readiness**, separate from scrape health) |

Labels never carry request IDs, users, prompts or other request content. `vllm:lora_requests_info` is
dropped at scrape time (its labels are lists of LoRA adapter names, and this app serves none).

**Dashboard** (`vllm-engine`). Variables: *Serve app*, *Deployment*, *Model*, *Replica (instance)*.

| Row | Panels |
|---|---|
| Fleet overview | Replicas scraped vs Serve RUNNING, arrivals/s, completions/s, running, waiting, p95 TTFT, generated tokens/s, max KV cache |
| Requests | Arrivals vs completions vs errors, completions by finish reason, running and waiting per replica, responses by HTTP status |
| Latency – fleet | TTFT, inter-token latency, end-to-end latency, queue time (p50/p90/p99 + mean), prefill vs decode p95, tokens per request |
| Latency – per replica | p95 TTFT / inter-token / end-to-end for each replica |
| Token throughput | Prompt + generated tokens/s (fleet), generated tokens/s per replica |
| Engine iterations and KV cache | Tokens per iteration, batch occupancy, iterations/s, KV-cache usage, preemptions/s, swapped requests |
| Prefix cache | Why a counter-based hit ratio isn't available in 0.6.6; the lifetime hit-rate gauge per replica |
| Replica health and capacity | Scrape health timeline, Serve replica states, KV-cache headroom (tokens), free batch slots, Ray Serve in-flight vs limit, scrape duration, firing alerts |

How to read it:

- **Fleet percentiles** sum every replica's histogram buckets first and then compute the quantile once
  (`histogram_quantile(q, sum by (le) (rate(..._bucket[...]))`). Replica percentiles are never averaged.
  Per-replica panels compute each replica's own percentile from its own buckets.
- **Units:** latency panels are in seconds. Arrival and completion rates are requests/s. Token rates are
  tokens/s.
- **No traffic** gives an empty panel ("no requests"), not 0. A rate of zero over finished requests has
  no percentile. Gauges such as running/waiting are only updated on engine steps, so after traffic stops
  they keep the value of the last step.
- **Tokens per iteration is not batch size.** `vllm:iteration_tokens_total` counts the *tokens* processed
  in one engine step: all prompt tokens being prefilled plus one per decoding sequence. A single request
  can contribute thousands in one step. Batch size, the number of *requests*, is
  `vllm:num_requests_running` (see the *batch occupancy* panel). The histogram's buckets are vLLM's
  CUDA-graph batch sizes (largest usually 256), so bigger steps fall in `+Inf` and its percentiles are
  capped at that size. The panel shows the mean, rate(sum) / rate(count), for that reason.
- **Prefix cache hit ratio from counters is not supported by vLLM 0.6.6.post1.** It exports no prefix-cache
  hit or query counters; those come with the V1 engine in later vLLM releases. What it has is the gauge
  `vllm:gpu_prefix_cache_hit_rate`:
  - It is the fraction (0–1) of KV-cache **block** lookups that hit, cumulative since the replica
    started.
  - It is `-1` when prefix caching is off, which is the V0 default. Turn it on with
    `--engine-arg enable_prefix_caching=true`.
  - It can't be weighted across replicas, so the dashboard shows it per replica, filtered to `>= 0`,
    and never treats it as a windowed ratio.
- **Arrivals vs completions:** arrivals are counted by the app as requests come in. Completions are
  requests vLLM finished. Rejected requests (400/404) and client disconnects show up in the HTTP status
  panel, not in completions.
- **Queues you can't see here:** requests beyond `--max-ongoing-requests` per replica wait in Ray Serve
  before reaching vLLM. vLLM's TTFT and queue time start when a request enters the engine. The *Ray Serve
  in-flight vs limit* panel and the LLM Serving / Ray Serve dashboards show the HTTP side.
- This is metrics only. CPU/GPU flame charts and profiler traces are a separate feature; Prometheus
  metrics don't provide them.

**Alerts** (`observability/vllm/vllm-alerts.yml.tmpl`, thresholds in `observability/vllm/alert-thresholds.env`).
There is no Alertmanager in the stack: alerts show at `http://<head>:9090/alerts` and in the dashboard's
*Firing vLLM alerts* table. Add an Alertmanager if you want notifications.

| Alert | Fires when | Default | Tune? |
|---|---|---|---|
| `VLLMMetricsTargetDown` | a replica's `/metrics` fails to scrape (`up == 0`) | for 2m | no |
| `VLLMReplicasWithoutMetrics` | Serve has more RUNNING replicas than answering endpoints | for 5m | no |
| `VLLMServeReplicasNotRunning` | Serve reports replicas not RUNNING (failed health checks, restarts, no GPU) | for 15m | keep above your model load time |
| `VLLMMetricsDiscoveryStale` | `llm-metrics-sd` down or failing | for 2m | no |
| `VLLMQueueBuildup` | a replica's vLLM queue (`num_requests_waiting`) > 8 | for 5m | **yes**: workload-specific |
| `VLLMPreemptions` | a replica preempts > 0.01 requests/s | for 10m | **yes** |
| `VLLMHighTimeToFirstToken` | fleet p95 TTFT > 2 s, with > 0.05 req/s | for 10m | **yes**: model, GPU, prompt length |
| `VLLMHighInterTokenLatency` | fleet p95 time per output token > 0.2 s | for 10m | **yes** |
| `VLLMHighEndToEndLatency` | fleet p95 end-to-end > 30 s | for 10m | **yes**: scales with `max_tokens` |

Scrape health is not inference readiness. `up == 1` only means `/metrics` answered: a replica can serve
metrics while its engine fails, or serve requests while a scrape fails. Readiness comes from Ray Serve's
health checks (`VLLMServeReplicasNotRunning`, *Serve replica states* panel) and, end to end, from a
request (`./scripts/chat.sh`, `./scripts/load-test.sh`). Latency alerts stay quiet below the minimum request
rate, because a few requests give a noisy p95 and none give no p95 at all. Each latency threshold must be
below the histogram's highest bucket (TTFT 10 s, inter-token 2.5 s, end-to-end 60 s). Above that, the p95
can't be measured, and `render_alerts.py` refuses such values.

Override any threshold with an environment variable of the same name when deploying:

```bash
VLLM_ALERT_TTFT_P95_SECONDS=1 VLLM_ALERT_QUEUE_WAITING=20 ./scripts/deploy.sh
```

**Validate**:

```bash
./scripts/check-metrics.sh --static     # no cluster: promtool checks of rules (+ unit tests), scrape config, every dashboard query
./scripts/check-metrics.sh              # live: targets, a replica's real /metrics vs vLLM 0.6.6's definitions, every query on Prometheus
./scripts/check-metrics.sh --load 20    # live + 20 requests, then checks that request/token counters rose
```

`promtool` comes from your PATH, or from the `prom/prometheus` image if Docker is running.

## Request tracing

Every request to `/v1/chat/completions` and `/v1/completions` is traced with OpenTelemetry. The replicas
export the spans over OTLP to Grafana Tempo on the head (`:4317`, private network only), which
`deploy.sh` starts next to Prometheus and Grafana and adds to Grafana as the *Tempo* datasource.
Traces are kept for 24 hours. Grafana opens traces in Explore, which it normally limits to editors,
so `deploy.sh` also lets the anonymous viewers use Explore (a `docker-compose.override.yml` next to the
gpu-workers stack); no login is needed. A trace looks like this:

```
POST /v1/chat/completions    replica, model, stream, status, time to first token, tokens in/out
├─ prepare_prompt            chat template + tokenization
└─ generate                  handed to vLLM until the last token (event: first_token)
   └─ llm_request            vLLM's own span: time in queue, time to first token, e2e latency
```

- **Find a request's trace:** every response has an `X-Trace-Id` header. `chat.sh` and `load-test.sh`
  print a Grafana link for it, and so does `deploy.sh` for its test request.
- **Join your own traces:** send a W3C `traceparent` header and the server span becomes a child of your
  span, so your app, the LLM call and vLLM's engine time show up in one trace.
- **Search:** Grafana → Explore → Tempo, e.g. `{resource.service.name="llm-serve" && duration > 5s}`
  or `{span.http.response.status_code >= 400}`. Streams the client dropped have status 499 and are
  marked as errors.

The Ray Serve HTTP proxy on the head has no span of its own. If you send a `traceparent`, the gap between
your client span and the server span is the time spent in the proxy and on the network.

## Troubleshooting

- **`DEPLOY_FAILED` / replicas keep restarting:** `./scripts/logs.sh worker-0` shows the vLLM traceback.
  The usual causes:
  - *"max seq len … is larger than the maximum number of tokens that can be stored in KV cache"*: lower
    `--max-model-len` or use a bigger GPU.
  - *CUDA out of memory*: the model doesn't fit. Use a smaller or quantized model, or `--tp`.
  - *Bfloat16 is only supported on GPUs with compute capability ≥ 8.0*: pass `--dtype half`
    (`auto` already does this on T4).
- **Replicas stay `starting` (unscheduled) and the message mentions resources:** there aren't enough free
  GPUs. Another job may be using them (e.g. `run-gpu-test.sh`), or `--replicas` is more than the GPUs fit.
- **401 / gated error during download:** accept the license on huggingface.co, and check the token can
  read the repo.
- **The API works on the head but not from your machine:** port 8000 isn't open to your IP. Apply the
  gpu-workers Terraform (see Prerequisites), or tunnel:
  `ssh -i <key> -N -L 8000:127.0.0.1:8000 ubuntu@<head>` and `export LLM_API_URL=http://127.0.0.1:8000`.
- **Serve logs on the head** (controller, HTTP proxy): `./scripts/logs.sh head`.
- **LLM dashboard is empty:** panels fill in once requests flow (run `load-test.sh`). If there is still
  nothing, check `count({__name__=~"ray_llm_.+"})` in Prometheus, the `ray` job under *Status → Targets*,
  and `./scripts/logs.sh` for "Could not attach the metrics logger".
- **vLLM Engine dashboard empty / `vllm` targets missing:** run `./scripts/check-metrics.sh`. Then:
  - At `http://<head>:9090/targets`, job `vllm` should list one target per replica.
  - If it lists none, check discovery on the head: `journalctl -u llm-metrics-sd -n 50`, and
    `cat /opt/observability/prometheus/llm/targets/vllm.json`. Discovery needs the Ray dashboard on
    `:8265`.
  - In `./scripts/logs.sh`, a replica logs "Serving vLLM metrics on port …" or "Could not start the
    metrics endpoint" (e.g. the port is still held by a replica that is shutting down).
- **`vllm` targets are up but there are no `vllm:*` series (you see `vllm_num_requests_running` etc.):**
  `prometheus_client` 0.23+ rewrites `vllm:` to `vllm_` for Prometheus 2.x scrapers. `prepare-node.sh` pins
  `prometheus_client==0.22.1`; rerun `deploy.sh` so the workers get it and the replicas restart.
- **A `vllm` target is down (`up == 0`) but the API works:** the replica's metrics thread or port is the
  problem, not inference. A replica restarted on another GPU of the same node gets a new port; the old
  target disappears within 10 minutes.
- **Prometheus didn't pick up the vLLM jobs:** rerun `deploy.sh`; `setup-vllm-metrics.sh` prints what it
  changed and refuses a config `promtool` rejects. To undo the merge on the head, restore
  `/opt/observability/prometheus/prometheus.yml.orig` and `docker-compose.yml.orig`, then run
  `docker compose up -d prometheus` in `/opt/observability`.
- **No traces in Tempo:** `./scripts/logs.sh worker-0` should show "Tracing requests to http://…:4317";
  OpenTelemetry export errors show up there too. On the head, `docker logs llm-tempo` shows Tempo itself.

## Limitations

- One model per cluster at a time, and tensor parallelism only within one node
  (no multi-node pipeline parallelism).
- **No authentication on the API.** Only the `allowed_cidrs` from gpu-workers can reach it, so
  keep that list tight.
- Text only: image inputs, tool calls and logprobs are not implemented.
- The LLM Serving and vLLM Engine dashboards, Tempo, the vLLM scrape jobs, alert rules and
  `llm-metrics-sd` live on the head's disk, so a rebuilt head loses them (and the stored traces) until
  the next `deploy.sh`.
- vLLM metrics are those of vLLM `0.6.6.post1`. It has no prefix-cache hit/query counters and no
  request-arrival counter (the app adds one), and `vllm:iteration_tokens_total` percentiles are capped at
  its largest bucket. A different `--vllm-version` may rename or add metrics: run
  `./scripts/check-metrics.sh`, which compares a replica's real `/metrics` with what the dashboard uses.
- No Alertmanager: alerts are visible in Prometheus and Grafana, but not sent anywhere.
