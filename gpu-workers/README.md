# GPU Workers: Ray GPU cluster on AWS

One command sets up a GPU cluster on AWS with **Ray** installed and connected on every
node, plus a **Prometheus + Grafana** dashboard that shows per-node and per-GPU utilization.

```
                    ┌──────────────── VPC 10.42.0.0/16 ─────────────────┐
 operator (your IP) │  ┌─────────── head (m5.xlarge, CPU) ──────────┐   │
   :8265 Ray UI ────┼─▶│ Ray head: GCS :6379, dashboard :8265       │   │
   :3000 Grafana ───┼─▶│ Prometheus :9090  ── EC2 discovery ──┐     │   │
   :9090 Prometheus ┼─▶│ Grafana :3000, node_exporter :9100   │     │   │
   :22 SSH          │  └──────────────────────────────────────┼─────┘   │
                    │        ▲ ray start --address=head:6379  │ scrape  │
                    │  ┌─────┴──── gpu worker × N (g4dn/g5/p4…) ▼──────┐ │
                    │  │ Ray worker (metrics :8080)                   │ │
                    │  │ dcgm-exporter :9400 (GPU) node_exporter :9100│ │
                    │  └──────────────────────────────────────────────┘ │
                    └───────────────────────────────────────────────────┘
```

| Layer | What runs | Where |
|---|---|---|
| Infra | VPC, public subnet, security group, IAM roles, key pair, EC2 instances | `terraform/` |
| Cluster | Ray `2.40.0` in `/opt/ray/venv`, managed by systemd (`ray-head` / `ray-worker`) | `terraform/templates/*-init.sh.tftpl` |
| GPU metrics | NVIDIA DCGM exporter on each worker | worker bootstrap |
| Host metrics | node_exporter on every node | worker bootstrap + head compose |
| Ray metrics | Ray's built-in exporter on each node, discovered with Ray's service-discovery file | head |
| Dashboards | Grafana with the **GPU Cluster Overview** dashboard plus the dashboards Ray generates | `observability/` |

Workers use the **AWS Deep Learning Base GPU AMI (Ubuntu 22.04)**, which already has the
NVIDIA driver, CUDA, Docker and the NVIDIA container toolkit. The head uses plain Ubuntu 22.04.
Both use Python 3.10, so their Ray versions match.

## Prerequisites

- A bash shell (Git Bash on Windows), plus `curl`, `ssh` and Python 3
- Terraform and the AWS CLI v2. **`./scripts/setup.sh` installs them if they're missing:**
  - Terraform: checksum-verified download into `gpu-workers/.tools/bin`
  - AWS CLI: per-user install on Linux/macOS; winget or MSI on Windows, which may ask for admin rights
- AWS sign-in. `setup.sh` reuses an existing profile (refreshing SSO or `aws login` sessions
  that have expired) or creates one, using `aws login` (browser sign-in with your console
  account), IAM Identity Center/SSO, or access keys. The chosen profile is saved to
  `.tools/env`, and the other scripts use it automatically.
  When a session expires later, re-run `setup.sh`.
- An SSH key is **optional**. Leave `ssh_public_key_path` unset and Terraform generates an
  ed25519 key pair for the cluster, saving the private key to `terraform/.keys/<cluster_name>.pem`
  (gitignored). To use your own key instead, set `ssh_public_key_path = "~/.ssh/id_ed25519.pub"`.
  The scripts find the matching private key on their own (override with `SSH_KEY=...`).
- **GPU quota.** New AWS accounts often have a quota of 0 vCPUs for GPU instances. Check
  *Service Quotas → EC2 → "Running On-Demand G and VT instances"* (or *"All G and VT Spot
  Instance Requests"* for Spot) and request at least `worker_count × vCPUs per instance`
  (g4dn.xlarge = 4 vCPU).

## Quick start

```bash
cd gpu-workers
./scripts/setup.sh           # first time on a machine: installs tools, AWS sign-in, creates tfvars
./scripts/deploy.sh          # terraform apply, then waits until all workers have joined Ray
./scripts/status.sh          # endpoints, scrape health, per-GPU utilization, `ray status`
./scripts/run-gpu-test.sh    # 5-minute matmul burn on every GPU; watch Grafana
./scripts/destroy.sh         # tear everything down (stops billing)
```

`deploy.sh` finishes only when Prometheus sees **every Ray node** (head + workers) and
**every GPU exporter**. That confirms all nodes have joined and are talking to each other.
A cold start usually takes 8–15 minutes, mostly from the Deep Learning AMI booting and the Ray install.

## Dashboards

| URL | Contents |
|---|---|
| `http://<head>:3000` | Grafana home page = **GPU Cluster Overview**. Login `admin` / `terraform -chdir=terraform output -raw grafana_admin_password`. Anonymous users get read-only access (only from `allowed_cidrs`). |
| `http://<head>:8265` | Ray dashboard: nodes, jobs, actors, logs. Its *Metrics* tab embeds Grafana. |
| `http://<head>:9090` | Prometheus: raw metrics and target health (*Status → Targets*). |
| `http://<head>:8000` | Ray Serve HTTP: the OpenAI-compatible LLM API, once you deploy a model with [`../llm-deployment`](../llm-deployment/README.md). |

The **GPU Cluster Overview** dashboard has a `Node` filter and shows:

- **Overview**: Ray nodes up, GPU workers reporting, GPU count, average GPU utilization, GPU memory %, total power, highest temperature
- **GPU**: utilization, memory used, memory-copy utilization, temperature, power, SM clock and PCIe throughput, for each GPU
- **Host**: CPU, memory, network rx/tx and disk use for each node (head included)
- **Ray**: active nodes, GPUs/CPUs in use, tasks by state

Ray's own dashboards (Default, Data, Serve, …) are in the Grafana folder **ray**.

## Configuration

All settings are in `terraform/variables.tf`. The ones you'll change most:

| Variable | Default | Notes |
|---|---|---|
| `allowed_cidrs` | *required* | Who can reach SSH and the UIs |
| `worker_count` | `2` | Number of GPU nodes |
| `worker_instance_type` | `g4dn.xlarge` | e.g. `g5.xlarge` (A10G), `g5.12xlarge` (4×A10G), `p4d.24xlarge` (8×A100) |
| `worker_use_spot` | `false` | Spot workers are much cheaper but can be interrupted |
| `availability_zone` | first AZ | Change it if you get `InsufficientInstanceCapacity` |
| `use_placement_group` | `false` | Cluster placement group for lower inter-node latency |
| `head_schedulable` | `false` | If false, the head advertises 0 CPUs so tasks run only on workers |
| `ray_version` | `2.40.0` | Must be the same on every node, and on any machine that submits jobs |

**Scaling:** change `worker_count` and run `./scripts/deploy.sh` again. New workers join
Ray on their own, and Prometheus finds them through their `RayCluster` EC2 tag, so no
config edits are needed.

**Submitting your own jobs:** use `run-gpu-test.sh` as a template (copy the code to the
head, then `ray job submit --address http://127.0.0.1:8265 ...`). You can also run
`ray job submit --address http://<head>:8265` from any machine with the same Ray version.

## Deployment progress and logs

`deploy.sh` runs in 4 phases and prints progress as it goes:

```
━━━ [3/4] Bootstrap nodes (install Docker, NVIDIA exporters, Ray; join cluster) ━━━
  19:46:07  head      ✔ Install Docker (30s)
  19:46:17  worker-0  ▶ Install Ray 2.40.0
  19:47:17  worker-1  ✘ FAILED: Start GPU + host metrics exporters
                        timed out after 180 seconds waiting for DCGM exporter reporting GPU metrics on :9400
━━━ worker-1 failed — last 60 lines of /var/log/ray-bootstrap.log ━━━
  ...
  Rebuild it : terraform -chdir=terraform apply -replace='aws_instance.worker[1]'
```

1. **Preflight**: checks tools, `terraform.tfvars` and AWS sign-in.
2. **Provision**: runs Terraform and shows its output as it goes. For common AWS errors (vCPU quota,
   no capacity, expired session, missing permissions) it adds a hint saying what to do.
3. **Bootstrap**: each node records every step (start, success with duration, failure with the
   command, line number and what it was waiting for) to `/var/log/ray-bootstrap.status`.
   `deploy.sh` reads this over SSH every 10s and prints each step for every node.
   - If a step fails, it prints the end of that node's log and saves the node's bootstrap,
     cloud-init and Ray service logs to `logs/deploy-<time>/`.
   - If a node never becomes reachable over SSH, it prints the instance's EC2 console output instead.
4. **Health**: checks from your machine that the Ray dashboard and Grafana respond, and that Prometheus sees every Ray node, GPU exporter and host exporter.

Everything printed is also saved to `logs/deploy-<time>.log`.

To dig into a node at any time:

```bash
./scripts/logs.sh                       # each node's bootstrap state
./scripts/logs.sh worker-0              # full bootstrap trace
./scripts/logs.sh worker-0 steps        # step summary with durations
./scripts/logs.sh head ray -f           # follow the Ray service log
./scripts/logs.sh worker-1 metrics      # DCGM / node_exporter container logs
./scripts/logs.sh all                   # download every node's logs to logs/collected-<time>/
```

## Troubleshooting

- **Bootstrap logs:** `./scripts/logs.sh <node>`, or on the node: `/var/log/ray-bootstrap.log`, `journalctl -u ray-head` / `-u ray-worker`.
- **A worker doesn't show in `ray status`:** SSH in (`ssh ubuntu@<worker_public_ip>`) and check the log.
  The usual causes are `pip` failures or the head not being reachable on 6379.
- **GPU panels are empty:** run `docker logs dcgm-exporter` on the worker; `curl localhost:9400/metrics` should list `DCGM_FI_DEV_GPU_UTIL`.
- **Prometheus `node`/`dcgm` targets are missing:** the head's IAM role must allow `ec2:DescribeInstances`, and instances must carry the `RayCluster=<cluster_name>` tag (both are set by Terraform).
- **user_data limit:** the observability config is sent to the head gzipped in user_data
  (about 10.5 KB of the 16 KB limit). If you add large dashboards, ship them from S3 instead.

## Security notes

- Only the CIDRs in `allowed_cidrs` can reach the head's public ports (22, 3000, 8000, 8265, 9090); nodes can talk to each other on any port.
- A generated SSH private key is also stored in Terraform state, as is the Grafana admin password.
  The password is in the head's user_data too.
  Treat both as secrets, and use a remote encrypted state backend for shared use.
- IMDSv2 is required on all instances, and root volumes are encrypted. SSM Session Manager also works if you'd rather not use SSH.
