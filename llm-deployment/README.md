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
   runs `serve deploy` on the head, and installs the **LLM Serving** Grafana dashboard.
5. **Wait + verify**: follows replica states until the app is `RUNNING`, sends a test request
   through the head, checks that `ray_llm_*` metrics reach Prometheus and traces reach Tempo,
   and checks that the API is reachable from your machine.

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
- **No traces in Tempo:** `./scripts/logs.sh worker-0` should show "Tracing requests to http://…:4317";
  OpenTelemetry export errors show up there too. On the head, `docker logs llm-tempo` shows Tempo itself.

## Limitations

- One model per cluster at a time, and tensor parallelism only within one node
  (no multi-node pipeline parallelism).
- **No authentication on the API.** Only the `allowed_cidrs` from gpu-workers can reach it, so
  keep that list tight.
- Text only: image inputs, tool calls and logprobs are not implemented.
- The LLM Serving dashboard and Tempo live on the head's disk, so a rebuilt head loses them (and the
  stored traces) until the next `deploy.sh`.
