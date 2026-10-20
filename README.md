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

Tooling for setting up GPU clusters on the cloud, running workloads on them, and watching them while they run.

## Projects

| Directory | What it does |
|---|---|
| [`gpu-workers/`](gpu-workers/README.md) | One command sets up a **Ray** GPU cluster on AWS (CPU head + N GPU workers) with a **Prometheus + Grafana** dashboard for per-node and per-GPU utilization. |

## Quick start

```bash
git clone https://github.com/Aditya-Dawadikar/gpu-workload-automation.git
cd gpu-workload-automation/gpu-workers
./scripts/setup.sh         # install Terraform / AWS CLI if missing, sign in to AWS, create tfvars
./scripts/deploy.sh        # provision and wait until every worker has joined Ray
./scripts/run-gpu-test.sh  # load every GPU; watch it in Grafana
./scripts/destroy.sh       # tear everything down (stops billing)
```

You need a bash shell (Git Bash on Windows), an AWS account with GPU instance quota, and Python 3.
See [`gpu-workers/README.md`](gpu-workers/README.md) for prerequisites, configuration, dashboards and troubleshooting.

> **Cost warning:** GPU instances are billed by the hour. Run `./scripts/destroy.sh` when you're done.

## Contributing

Contributions are welcome. To contribute:

1. Fork the repository and create a branch (`git checkout -b feature/my-change`).
2. Make your change. Keep shell scripts POSIX/bash with LF line endings, and run `terraform fmt` on Terraform files.
3. Open a pull request that describes what changed and how you tested it.

To report a bug or request a feature, [open an issue](https://github.com/Aditya-Dawadikar/gpu-workload-automation/issues).

## License

Released under the [MIT License](LICENSE).
