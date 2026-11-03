"""Render the vLLM alert rules from their template and thresholds.

    python render_alerts.py [--defaults-only] > vllm-alerts.yml

Values come from observability/vllm/alert-thresholds.env; an environment
variable of the same name overrides one (unless --defaults-only, which the
rule unit tests use). Exits non-zero on a missing, malformed or unreachable
threshold.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VLLM_DIR = os.path.join(HERE, "..", "observability", "vllm")
DURATION = re.compile(r"^([0-9]+(ms|s|m|h|d|w|y))+$")
NUMBER = re.compile(r"^[0-9]+(\.[0-9]+)?$")
# Highest finite bucket of each vLLM 0.6.6 latency histogram: a p95 above it
# comes out of histogram_quantile as exactly this value, so a threshold at or
# above it could never fire.
TOP_BUCKET = {
    "VLLM_ALERT_TTFT_P95_SECONDS": 10.0,   # vllm:time_to_first_token_seconds
    "VLLM_ALERT_ITL_P95_SECONDS": 2.5,     # vllm:time_per_output_token_seconds
    "VLLM_ALERT_E2E_P95_SECONDS": 60.0,    # vllm:e2e_request_latency_seconds
}


def thresholds(defaults_only: bool) -> dict:
    values = {}
    with open(os.path.join(VLLM_DIR, "alert-thresholds.env")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    if not defaults_only:
        values.update({k: os.environ[k] for k in values if os.environ.get(k)})
    errors = []
    for key, value in values.items():
        kind = DURATION if key.endswith("_FOR") else NUMBER
        if not kind.match(value):
            errors.append("%s=%r is not a %s" % (key, value, "duration" if kind is DURATION else "number"))
        elif key in TOP_BUCKET and float(value) >= TOP_BUCKET[key]:
            errors.append("%s=%s can never fire: the histogram's highest finite bucket is %ss"
                          % (key, value, TOP_BUCKET[key]))
    if errors:
        sys.exit("render_alerts.py: " + "; ".join(errors))
    return values


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--defaults-only", action="store_true", help="ignore environment overrides")
    args = p.parse_args()
    values = thresholds(args.defaults_only)
    with open(os.path.join(VLLM_DIR, "vllm-alerts.yml.tmpl")) as f:
        text = f.read()
    text = re.sub(r"@@(\w+)@@", lambda m: values[m.group(1)] if m.group(1) in values else m.group(0), text)
    left = sorted(set(re.findall(r"@@(\w+)@@", text)))
    if left:
        sys.exit("render_alerts.py: no value for " + ", ".join(left))
    text = text.replace("# Prometheus alert rules", "# Rendered by scripts/render_alerts.py. Prometheus alert rules", 1)
    sys.stdout.buffer.write(text.encode())   # LF endings on Windows too: the file goes to Linux


if __name__ == "__main__":
    main()
