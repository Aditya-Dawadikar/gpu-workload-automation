"""Cluster smoke test: run a matmul burn on every GPU in the Ray cluster.

Proves that all workers joined the cluster and lights up the GPU panels in
Grafana. Submit with:  ./scripts/run-gpu-test.sh [seconds]
"""
import argparse
import socket
import time

import ray


@ray.remote(num_gpus=1)
def burn(seconds: int, size: int = 8192) -> dict:
    import torch

    device = torch.device("cuda")
    a = torch.randn(size, size, device=device, dtype=torch.float16)
    b = torch.randn(size, size, device=device, dtype=torch.float16)

    iters, start = 0, time.time()
    while time.time() - start < seconds:
        torch.matmul(a, b)
        iters += 1
        if iters % 50 == 0:
            torch.cuda.synchronize()
    torch.cuda.synchronize()
    elapsed = time.time() - start

    return {
        "host": socket.gethostname(),
        "node_ip": ray.util.get_node_ip_address(),
        "gpu": torch.cuda.get_device_name(0),
        "gpu_ids": ray.get_gpu_ids(),
        "tflops": round(2 * size**3 * iters / elapsed / 1e12, 1),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=300)
    args = parser.parse_args()

    ray.init()
    nodes = [n for n in ray.nodes() if n["Alive"]]
    total_gpus = int(ray.cluster_resources().get("GPU", 0))
    print(f"Cluster: {len(nodes)} alive nodes, {total_gpus} GPUs")
    if total_gpus == 0:
        raise SystemExit("No GPUs registered with Ray - are the workers up?")

    print(f"Burning {total_gpus} GPU(s) for {args.seconds}s - watch Grafana now")
    results = ray.get([burn.remote(args.seconds) for _ in range(total_gpus)])

    for r in sorted(results, key=lambda r: r["node_ip"]):
        print(f"{r['node_ip']:<15} {r['host']:<20} {r['gpu']:<28} gpu={r['gpu_ids']} {r['tflops']} TFLOPS")
    print(f"OK: {len({r['node_ip'] for r in results})} worker node(s) ran GPU work")


if __name__ == "__main__":
    main()
