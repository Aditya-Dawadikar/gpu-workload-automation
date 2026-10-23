#!/usr/bin/env python3
"""Send concurrent chat requests to the deployed model and report how it did (standard library only).

Shows the endpoint is live under load and gives the LLM Serving dashboard something to plot.
    python load_test.py --url http://<head>:8000 [--grafana http://<head>:3000] [--requests 100] [--concurrency 8] [--max-tokens 128]
"""
import argparse
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from chat import trace_link

PROMPTS = [
    "Explain what a GPU does in two sentences.",
    "Write a haiku about distributed computing.",
    "List three uses of large language models.",
    "What is the difference between latency and throughput?",
    "Summarize the plot of Romeo and Juliet in one paragraph.",
    "Give me a short Python function that reverses a string.",
    "Why is the sky blue? Answer briefly.",
    "Suggest five names for a coffee shop run by robots.",
    "Explain tensor parallelism to a new engineer.",
    "Translate 'good morning, how are you?' into French and Spanish.",
]


def post(url, payload, timeout):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp), resp.headers.get("X-Trace-Id")


def percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))] if values else 0.0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", required=True, help="API base URL, e.g. http://<head>:8000")
    p.add_argument("--grafana", help="Grafana URL, e.g. http://<head>:3000, to link the slowest requests' traces")
    p.add_argument("--model", help="model name (default: the one the API serves)")
    p.add_argument("--requests", type=int, default=100)
    p.add_argument("--concurrency", type=int, default=8)
    p.add_argument("--max-tokens", type=int, default=128)
    p.add_argument("--timeout", type=float, default=300, help="per-request timeout in seconds")
    a = p.parse_args()
    base = a.url.rstrip("/")

    try:
        with urllib.request.urlopen(base + "/v1/models", timeout=15) as resp:
            model = a.model or json.load(resp)["data"][0]["id"]
    except (urllib.error.URLError, OSError) as e:
        sys.exit("ERROR: the API at %s is not answering: %s" % (base, getattr(e, "reason", e)))

    print("Sending %d requests to %s (%s), %d at a time, max_tokens=%d"
          % (a.requests, base, model, a.concurrency, a.max_tokens))
    latencies, tokens, errors, traced = [], [], {}, []   # traced: (latency, trace ID)
    lock, done = threading.Lock(), [0]

    def one(i):
        payload = {"model": model, "max_tokens": a.max_tokens, "temperature": 0.8,
                   "messages": [{"role": "user", "content": random.choice(PROMPTS)}]}
        start = time.time()
        try:
            body, trace_id = post(base + "/v1/chat/completions", payload, a.timeout)
            return time.time() - start, body["usage"]["completion_tokens"], None, trace_id
        except urllib.error.HTTPError as e:
            return None, 0, "HTTP %d" % e.code, e.headers.get("X-Trace-Id")
        except Exception as e:  # timeouts, connection resets
            return None, 0, type(e).__name__, None

    start = time.time()
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        for future in as_completed([pool.submit(one, i) for i in range(a.requests)]):
            latency, n_tokens, error, trace_id = future.result()
            with lock:
                done[0] += 1
                if error:
                    errors[error] = errors.get(error, 0) + 1
                else:
                    latencies.append(latency)
                    tokens.append(n_tokens)
                    if trace_id:
                        traced.append((latency, trace_id))
                if done[0] % max(1, a.requests // 10) == 0 or done[0] == a.requests:
                    print("  %3d/%d done, %d failed (%.0fs)" % (done[0], a.requests, sum(errors.values()),
                                                                time.time() - start), flush=True)
    wall = time.time() - start

    ok = len(latencies)
    print("\nResults")
    print("  succeeded       %d/%d" % (ok, a.requests))
    if errors:
        print("  failed          " + ", ".join("%s x%d" % kv for kv in sorted(errors.items())))
    if ok:
        print("  requests/s      %.2f" % (ok / wall))
        print("  tokens/s        %.1f generated (%d tokens total)" % (sum(tokens) / wall, sum(tokens)))
        print("  latency         p50 %.2fs   p95 %.2fs   max %.2fs"
              % (percentile(latencies, 0.5), percentile(latencies, 0.95), max(latencies)))
    if traced:
        print("\nSlowest requests (open the trace to see queueing vs. prefill vs. decode)")
        for latency, trace_id in sorted(traced, reverse=True)[:3]:
            print("  %6.2fs  %s" % (latency, trace_link(a.grafana, trace_id) if a.grafana else trace_id))
    sys.exit(0 if ok == a.requests else 1)


if __name__ == "__main__":
    main()
