"""Checks for the vLLM metrics integration; used by check-metrics.sh.

    check_metrics.py dashboard-rules DASHBOARD.json      every panel/variable query as a recording rule (for promtool)
    check_metrics.py exposition METRICS.txt DASHBOARD.json RULES.yml
                                                         compare a replica's real /metrics with what vLLM 0.6.6
                                                         defines and with what the dashboard and rules use
    check_metrics.py live PROM_URL DASHBOARD.json RULES.yml
                                                         targets, metric presence and every query on live Prometheus
    check_metrics.py snapshot PROM_URL                   JSON of the counters the load check compares
    check_metrics.py compare BEFORE.json AFTER.json      which of them went up
"""
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# vLLM 0.6.6.post1, vllm/engine/metrics.py (class Metrics) and PrometheusStatLogger.info():
# name -> type, as prometheus_client writes them on # TYPE lines.
VLLM_066 = {
    "vllm:num_requests_running": "gauge", "vllm:num_requests_waiting": "gauge",
    "vllm:num_requests_swapped": "gauge", "vllm:lora_requests_info": "gauge",
    "vllm:gpu_cache_usage_perc": "gauge", "vllm:cpu_cache_usage_perc": "gauge",
    "vllm:gpu_prefix_cache_hit_rate": "gauge", "vllm:cpu_prefix_cache_hit_rate": "gauge",
    "vllm:cache_config_info": "gauge",
    "vllm:avg_prompt_throughput_toks_per_s": "gauge", "vllm:avg_generation_throughput_toks_per_s": "gauge",
    "vllm:spec_decode_draft_acceptance_rate": "gauge", "vllm:spec_decode_efficiency": "gauge",
    "vllm:num_preemptions_total": "counter", "vllm:prompt_tokens_total": "counter",
    "vllm:generation_tokens_total": "counter", "vllm:tokens_total": "counter",
    "vllm:request_success_total": "counter",
    "vllm:spec_decode_num_accepted_tokens_total": "counter", "vllm:spec_decode_num_draft_tokens_total": "counter",
    "vllm:spec_decode_num_emitted_tokens_total": "counter",
    "vllm:iteration_tokens_total": "histogram", "vllm:time_to_first_token_seconds": "histogram",
    "vllm:time_per_output_token_seconds": "histogram", "vllm:e2e_request_latency_seconds": "histogram",
    "vllm:request_queue_time_seconds": "histogram", "vllm:request_inference_time_seconds": "histogram",
    "vllm:request_prefill_time_seconds": "histogram", "vllm:request_decode_time_seconds": "histogram",
    "vllm:time_in_queue_requests": "histogram", "vllm:model_forward_time_milliseconds": "histogram",
    "vllm:model_execute_time_milliseconds": "histogram", "vllm:request_prompt_tokens": "histogram",
    "vllm:request_generation_tokens": "histogram", "vllm:request_max_num_generation_tokens": "histogram",
    "vllm:request_params_n": "histogram", "vllm:request_params_max_tokens": "histogram",
}
# Defined by app/llm_serve.py (ReplicaMetrics).
LLM_SERVE = {
    "llm_serve_replica_info": "gauge", "llm_serve_max_ongoing_requests": "gauge",
    "llm_serve_max_num_seqs": "gauge", "llm_serve_max_num_batched_tokens": "gauge",
    "llm_serve_kv_cache_capacity_tokens": "gauge",
    "llm_serve_requests_received_total": "counter", "llm_serve_responses_total": "counter",
}
# Counters the load check expects to rise when requests are served.
LOAD_COUNTERS = {
    "arrivals": 'sum(llm_serve_requests_received_total{job="vllm"})',
    "completions": 'sum(vllm:request_success_total{job="vllm"})',
    "prompt tokens": 'sum(vllm:prompt_tokens_total{job="vllm"})',
    "generated tokens": 'sum(vllm:generation_tokens_total{job="vllm"})',
    "TTFT observations": 'sum(vllm:time_to_first_token_seconds_count{job="vllm"})',
    "engine iterations": 'sum(vllm:iteration_tokens_total_count{job="vllm"})',
}
# Grafana variables -> values that keep each query valid PromQL and match everything.
GRAFANA_VARS = {"$__rate_interval": "1m", "$__interval": "15s", "$__range": "30m",
                "$application": ".*", "$deployment": ".*", "$model": ".*", "$instance": ".*"}
METRIC_RE = re.compile(r"\b(vllm:[a-z0-9_:]+|llm_serve_[a-z0-9_]+|llm_sd_[a-z0-9_]+|ray_serve_[a-z0-9_]+)")


def dashboard_queries(path):
    d = json.load(open(path))
    out = []
    for p in d["panels"]:
        for t in p.get("targets", []):
            out.append(("panel %r %s" % (p["title"], t["refId"]), t["expr"]))
    for v in d["templating"]["list"]:
        m = re.match(r"label_values\((.*),\s*\w+\)$", v["query"]["query"])
        out.append(("variable $%s" % v["name"], m.group(1) if m else v["query"]["query"]))
    return [(where, substitute(expr)) for where, expr in out]


def substitute(expr):
    for var, value in GRAFANA_VARS.items():
        expr = expr.replace(var, value)
    return expr


def rule_queries(path):
    text = open(path).read()
    exprs = re.findall(r"expr: \|\n((?:\s{10}.*\n)+)|expr: (.+)", text)
    return [("rule", (block or line).strip()) for block, line in exprs]


def family(name):
    """Metric family as on a # TYPE line: strips histogram series suffixes."""
    for suffix in ("_bucket", "_sum", "_count"):
        if name.endswith(suffix) and name[: -len(suffix)] in {**VLLM_066, **LLM_SERVE}:
            return name[: -len(suffix)]
    return name


def referenced(dashboard, rules):
    names = set()
    for _, expr in dashboard_queries(dashboard) + rule_queries(rules):
        names.update(family(n) for n in METRIC_RE.findall(expr))
    return names


def cmd_dashboard_rules(dashboard):
    print("groups:\n  - name: dashboard-queries\n    rules:")
    for i, (where, expr) in enumerate(dashboard_queries(dashboard)):
        print("      # %s" % where)
        print("      - record: dashboard:query_%d\n        expr: %s" % (i, json.dumps(expr)))


def cmd_exposition(path, dashboard, rules):
    types = dict(re.findall(r"^# TYPE (\S+) (\S+)$", open(path).read(), re.M))
    problems = 0
    print("Metric families in the response: %d (%d vllm:*)" % (len(types), sum(n.startswith("vllm:") for n in types)))
    for name, want in sorted({**VLLM_066, **LLM_SERVE}.items()):
        have = types.get(name)
        if have is None:
            print("  absent      %-45s %s (labelled series appear after first use)" % (name, want))
        elif have != want:
            problems += 1
            print("  TYPE DIFF   %-45s expected %s, got %s" % (name, want, have))
    escaped = sorted(n for n in types if n.startswith("vllm_"))
    if escaped:
        problems += 1
        print("  NAMES ESCAPED: vllm:* is served as vllm_* (prometheus_client >= 0.23 without UTF-8 "
              "negotiation); pin prometheus_client==0.22.1 on the workers. e.g. " + escaped[0])
    extra = sorted(n for n in types if n.startswith("vllm:") and n not in VLLM_066)
    if extra:
        print("  not in vLLM 0.6.6 definitions (newer vLLM?): " + ", ".join(extra))
    for name in sorted(referenced(dashboard, rules)):
        if name.startswith(("vllm:", "llm_serve_")) and name not in types:
            print("  used by the dashboard/rules but absent from this response: " + name)
    # Label names on vllm:* / llm_serve_* series: nothing request- or caller-specific.
    text = open(path).read()
    labels = set()
    for series_labels in re.findall(r"^(?:vllm:|llm_serve_)\S*?\{([^}]*)\}", text, re.M):
        labels.update(re.findall(r'(\w+)="', series_labels))
    print("  label names: " + ", ".join(sorted(labels)))
    risky = sorted(l for l in labels if re.search(r"request|user|prompt|message|trace|session", l)
                   or (l.endswith("_id") and l != "replica_id"))
    if risky:
        problems += 1
        print("  HIGH-CARDINALITY RISK: " + ", ".join(risky))
    return problems


def query(prom, expr):
    url = prom.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def cmd_live(prom, dashboard, rules):
    problems = 0
    with urllib.request.urlopen(prom.rstrip("/") + "/api/v1/targets?state=active", timeout=15) as r:
        targets = [t for t in json.load(r)["data"]["activeTargets"] if t["labels"].get("job") in ("vllm", "vllm-sd")]
    print("Scrape targets:")
    for t in sorted(targets, key=lambda t: (t["labels"]["job"], t["labels"]["instance"])):
        print("  %-7s %-22s %-5s %s" % (t["labels"]["job"], t["labels"]["instance"], t["health"], t["lastError"]))
        problems += t["health"] != "up"
    if not any(t["labels"]["job"] == "vllm" for t in targets):
        print("  no vllm targets: is the model deployed, and is llm-metrics-sd running on the head?")
        problems += 1
    print("Metrics used by the dashboard and rules:")
    for name in sorted(referenced(dashboard, rules)):
        series = name + "_count" if VLLM_066.get(name) == "histogram" else name
        r = query(prom, "count(%s)" % series)
        n = r["data"]["result"][0]["value"][1] if r.get("status") == "success" and r["data"]["result"] else "0"
        print("  %-45s %s series%s" % (name, n, "" if n != "0" else "   <- none (no traffic yet, feature off, or not exported)"))
    print("Dashboard and rule queries:")
    for where, expr in dashboard_queries(dashboard) + rule_queries(rules):
        r = query(prom, expr)
        if r.get("status") != "success":
            problems += 1
            print("  ERROR %s: %s" % (where, r.get("error")))
    print("  %s" % ("all queries evaluate" if not problems else "see errors above"))
    return problems


def cmd_snapshot(prom):
    out = {}
    for label, expr in LOAD_COUNTERS.items():
        r = query(prom, expr)
        result = r.get("data", {}).get("result") or []
        out[label] = float(result[0]["value"][1]) if result else None
    print(json.dumps(out))


def cmd_compare(before_path, after_path):
    before, after = json.load(open(before_path)), json.load(open(after_path))
    problems = 0
    for label in LOAD_COUNTERS:
        a, b = before.get(label), after.get(label)
        if b is None:
            ok, note = False, "no series"
        else:
            ok, note = b > (a or 0), "%s -> %s" % ("none" if a is None else "%g" % a, "%g" % b)
        problems += not ok
        print("  %-18s %-6s %s" % (label, "rose" if ok else "FLAT", note))
    return problems


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    fn = {"dashboard-rules": cmd_dashboard_rules, "exposition": cmd_exposition, "live": cmd_live,
          "snapshot": cmd_snapshot, "compare": cmd_compare}[cmd]
    sys.exit(1 if fn(*args) else 0)


if __name__ == "__main__":
    main()
