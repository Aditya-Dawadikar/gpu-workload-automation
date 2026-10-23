# GPU Workload Automation

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Open Source](https://img.shields.io/badge/Open%20Source-%E2%9D%A4-brightgreen.svg)](https://github.com/Aditya-Dawadikar/gpu-workload-automation)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Aditya-Dawadikar/gpu-workload-automation/pulls)
[![GitHub stars](https://img.shields.io/github/stars/Aditya-Dawadikar/gpu-workload-automation?style=social)](https://github.com/Aditya-Dawadikar/gpu-workload-automation/stargazers)

![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.5-7B42BC?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?logo=amazonwebservices&logoColor=white)
![Ray](https://img.shields.io/badge/Ray-2.40.0-028CF0?logo=ray&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?logo=grafana&logoColor=white)
![NVIDIA](https://img.shields.io/badge/NVIDIA-DCGM-76B900?logo=nvidia&logoColor=white)
![vLLM](https://img.shields.io/badge/vLLM-0.6.6-30A2FF)
![Hugging Face](https://img.shields.io/badge/Hugging%20Face-models-FFD21E?logo=huggingface&logoColor=black)

Tooling for setting up GPU clusters on the cloud, serving LLMs on them, and watching them while they run.

## Projects

| Directory | What it does |
|---|---|
| [`gpu-workers/`](gpu-workers/README.md) | One command sets up a **Ray** GPU cluster on AWS (CPU head + N GPU workers) with a **Prometheus + Grafana** dashboard for per-node and per-GPU utilization. |
| [`llm-deployment/`](llm-deployment/README.md) | One command deploys a **Hugging Face** model to that cluster with **Ray Serve + vLLM**, as an OpenAI-compatible API. |

```
 you ──▶ gpu-workers/      Terraform: VPC, Ray head (CPU) + N GPU workers, Prometheus + Grafana
           │
           ▼
         llm-deployment/   vLLM on every GPU, Ray Serve routing, OpenAI API on head:8000
           │
           ▼
         requests ──▶ LLM ──▶ metrics ──▶ Prometheus ──▶ Grafana dashboards
```

## Walkthrough: from nothing to a live LLM

You need a bash shell (Git Bash on Windows), Python 3, and an AWS account with GPU instance quota
(see [GPU quota](gpu-workers/README.md#prerequisites)). Everything else is installed by `setup.sh`.

> **Cost warning:** GPU instances are billed by the hour. Run step 6 when you're done.

### 1. Deploy the GPU cluster

```bash
git clone https://github.com/Aditya-Dawadikar/gpu-workload-automation.git
cd gpu-workload-automation/gpu-workers
./scripts/setup.sh     # first time: installs Terraform / AWS CLI, signs in to AWS, creates terraform.tfvars
./scripts/deploy.sh    # provisions everything and waits until every worker has joined Ray (8-15 min)
./scripts/status.sh    # optional: endpoints, scrape health, per-GPU utilization
```

`terraform/terraform.tfvars` sets the worker count, instance type, Spot use and the IPs allowed in
(`allowed_cidrs`). The defaults give 2 × `g4dn.xlarge` (one NVIDIA T4 each).
See [`gpu-workers/README.md`](gpu-workers/README.md) for every option.

### 2. Deploy a model from Hugging Face

```bash
cd ../llm-deployment
./scripts/deploy.sh                                          # Qwen/Qwen2.5-1.5B-Instruct, one replica per GPU
# or pick another model:
./scripts/deploy.sh --model microsoft/Phi-3.5-mini-instruct
HF_TOKEN=hf_... ./scripts/deploy.sh --model meta-llama/Llama-3.2-3B-Instruct   # gated models need a token
```

This installs vLLM on the workers, downloads the model, starts it behind Ray Serve, installs the
**LLM Serving** dashboard and sends a test request. The first run takes 10–15 minutes; redeploys are faster.
See [`llm-deployment/README.md`](llm-deployment/README.md) for model sizing and all options.

### 3. Check that the LLM is live

```bash
./scripts/status.sh                                     # app RUNNING, replicas per worker, API answering
./scripts/chat.sh "In one sentence, what is Ray Serve?"
./scripts/chat.sh --stream "Write a haiku about GPUs"   # tokens printed as they're generated
```

The API is OpenAI-compatible, so any OpenAI client works:

```bash
HEAD=$(terraform -chdir=../gpu-workers/terraform output -raw head_public_ip)

curl http://$HEAD:8000/v1/models

curl http://$HEAD:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen2.5-1.5B-Instruct",
  "messages": [{"role": "user", "content": "Give me three facts about GPUs."}],
  "max_tokens": 200
}'
```

```python
from openai import OpenAI

HEAD = "<head public IP>"
client = OpenAI(base_url=f"http://{HEAD}:8000/v1", api_key="unused")
reply = client.chat.completions.create(
    model="Qwen/Qwen2.5-1.5B-Instruct",
    messages=[{"role": "user", "content": "Give me three facts about GPUs."}],
)
print(reply.choices[0].message.content)
```

### 4. Put it under load

```bash
./scripts/load-test.sh                                   # 100 requests, 8 at a time
./scripts/load-test.sh --requests 500 --concurrency 32   # heavier
```

It prints successes, requests/s, tokens/s and p50/p95 latency, and exits non-zero if any request failed.

### 5. Watch the dashboards

| Dashboard | URL | What it shows |
|---|---|---|
| **LLM Serving** | `http://<head>:3000/d/llm-serving` | Tokens/s, requests/s by status, time to first token, time per output token, end-to-end latency, running/waiting requests, KV-cache usage, preemptions, plus GPU utilization and memory |
| **GPU Cluster Overview** | `http://<head>:3000` | Per-GPU utilization, memory, power and temperature; host CPU, memory, network; Ray tasks |
| Ray Serve (folder *ray*) | `http://<head>:3000` | Ray Serve's built-in HTTP request, latency and replica dashboards |
| Ray dashboard | `http://<head>:8265` | *Serve* tab: replicas and their logs; *Cluster* tab: nodes and GPUs |

The Grafana admin password is printed by `terraform -chdir=gpu-workers/terraform output -raw grafana_admin_password`.
Anonymous visitors from `allowed_cidrs` get read-only access.

The LLM metrics come from the vLLM engine inside each replica. They're exported as `ray_llm_*` series
through Ray's metrics agent, which Prometheus already scrapes. While the load test runs you should see
tokens/s and GPU utilization rise, and requests start waiting once the batch or KV cache fills.

### 6. Clean up

```bash
./scripts/undeploy.sh                  # remove the model, keep the cluster (GPUs are still billed)
cd ../gpu-workers && ./scripts/destroy.sh   # delete everything and stop billing
```

## Contributing

Contributions are welcome. To contribute:

1. Fork the repository and create a branch (`git checkout -b feature/my-change`).
2. Make your change. Keep shell scripts POSIX/bash with LF line endings, and run `terraform fmt` on Terraform files.
3. Open a pull request that describes what changed and how you tested it.

To report a bug or request a feature, [open an issue](https://github.com/Aditya-Dawadikar/gpu-workload-automation/issues).

## License

Released under the [MIT License](LICENSE).
