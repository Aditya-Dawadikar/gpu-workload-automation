#!/usr/bin/env python3
"""Send a prompt to the deployed model's OpenAI-compatible API (standard library only).

    python chat.py --url http://<head>:8000 [--grafana http://<head>:3000] [--stream] [--max-tokens N] [--system TEXT] "prompt"
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def trace_link(grafana, trace_id):
    """Grafana Explore URL that opens one request trace from the Tempo datasource."""
    pane = {"datasource": "tempo", "range": {"from": "now-1h", "to": "now"},
            "queries": [{"refId": "A", "datasource": {"type": "tempo", "uid": "tempo"},
                         "queryType": "traceql", "query": trace_id}]}
    return "%s/explore?schemaVersion=1&orgId=1&panes=%s" % (
        grafana.rstrip("/"), urllib.parse.quote(json.dumps({"trace": pane}, separators=(",", ":"))))


def print_trace(resp, grafana):
    trace_id = resp.headers.get("X-Trace-Id")
    if trace_id:
        print("trace %s%s" % (trace_id, "  " + trace_link(grafana, trace_id) if grafana else ""), file=sys.stderr)


def call(url, payload=None, timeout=300):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("prompt")
    p.add_argument("--url", required=True, help="API base URL, e.g. http://<head>:8000")
    p.add_argument("--grafana", help="Grafana URL, e.g. http://<head>:3000, to print a link to the request's trace")
    p.add_argument("--model", help="model name (default: the one the API serves)")
    p.add_argument("--system", help="system message")
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--stream", action="store_true", help="print tokens as they arrive")
    a = p.parse_args()
    base = a.url.rstrip("/")
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass

    try:
        model = a.model or json.load(call(base + "/v1/models", timeout=15))["data"][0]["id"]
        messages = ([{"role": "system", "content": a.system}] if a.system else [])
        messages.append({"role": "user", "content": a.prompt})
        payload = {"model": model, "messages": messages, "max_tokens": a.max_tokens,
                   "temperature": a.temperature, "stream": a.stream}
        start = time.time()
        resp = call(base + "/v1/chat/completions", payload)

        if a.stream:
            first_token = None
            for raw in resp:
                line = raw.decode("utf-8").strip()
                if not line.startswith("data: "):
                    continue
                data = line[len("data: "):]
                if data == "[DONE]":
                    break
                event = json.loads(data)
                if "error" in event:
                    sys.exit("\nERROR: " + event["error"]["message"])
                text = event["choices"][0]["delta"].get("content") or ""
                if text and first_token is None:
                    first_token = time.time() - start
                print(text, end="", flush=True)
            print()
            print("\n[%s] first token %.2fs, total %.1fs" % (model, first_token or 0, time.time() - start),
                  file=sys.stderr)
            print_trace(resp, a.grafana)
        else:
            body = json.load(resp)
            elapsed = time.time() - start
            print(body["choices"][0]["message"]["content"])
            u = body["usage"]
            print("\n[%s] %d prompt + %d completion tokens in %.1fs (%.1f tokens/s)"
                  % (model, u["prompt_tokens"], u["completion_tokens"], elapsed,
                     u["completion_tokens"] / elapsed if elapsed else 0), file=sys.stderr)
            print_trace(resp, a.grafana)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            pass
        sys.exit("ERROR: HTTP %d: %s" % (e.code, detail))
    except urllib.error.URLError as e:
        sys.exit("ERROR: cannot reach %s: %s" % (base, e.reason))


if __name__ == "__main__":
    main()
