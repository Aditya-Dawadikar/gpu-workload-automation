#!/usr/bin/env bash
# Runs on a cluster node as ubuntu (copied there by scripts/deploy.sh).
# Installs Ray Serve - plus vLLM on GPU workers - into Ray's venv, then installs
# the Serve app module. Skips pip when the right versions are already there.
#   prepare-node.sh <head|worker> <ray_version> <vllm_version>
set -euo pipefail

ROLE=$1 RAY_VERSION=$2 VLLM_VERSION=$3
VENV=/opt/ray/venv
PY=$VENV/bin/python
HERE="$(cd "$(dirname "$0")" && pwd)"

# Ray 2.40's @serve.ingress pickles the FastAPI app; recent FastAPI (0.161) holds a
# thread lock (native telemetry) that can't be pickled, so pin the web stack to
# the versions Ray 2.40 / vLLM 0.6.6 were released against.
WEB_PINS=(fastapi==0.115.6 starlette==0.41.3 uvicorn==0.34.0)
# Same story for vLLM 0.6.6: transformers 5.x dropped tokenizer attributes it uses
# (all_special_tokens_extended), so keep transformers on the 4.x line it shipped with.
VLLM_PINS=("vllm==$VLLM_VERSION" transformers==4.47.1)
# OpenTelemetry for request tracing: vLLM 0.6.6 only enables otlp_traces_endpoint
# with these importable, and was built against the 1.26 SDK.
VLLM_PINS+=(opentelemetry-api==1.26.0 opentelemetry-sdk==1.26.0 opentelemetry-exporter-otlp==1.26.0
            opentelemetry-semantic-conventions-ai==0.4.1)
required=("ray==$RAY_VERSION" "${WEB_PINS[@]}")
if [ "$ROLE" = worker ]; then
  required+=("${VLLM_PINS[@]}")
fi

# Prints the required distributions that are missing or at the wrong version.
check() {
  "$PY" - "$@" <<'EOF'
import sys
from importlib.metadata import PackageNotFoundError, version

missing = []
for spec in sys.argv[1:]:
    name, _, want = spec.partition("==")
    try:
        have = version(name)
    except PackageNotFoundError:
        missing.append(name)
        continue
    if want and have != want:
        missing.append(f"{name} {have} (want {want})")
print(", ".join(missing))
EOF
}

missing="$(check "${required[@]}")"
if [ -z "$missing" ]; then
  echo "Already installed: ${required[*]}"
else
  echo "Installing; missing: $missing"
  # Pin Ray in the same resolve so vLLM's dependencies can't move it.
  pkgs=("ray[default,serve]==$RAY_VERSION" "${WEB_PINS[@]}" "click<8.2")
  if [ "$ROLE" = worker ]; then
    pkgs+=("${VLLM_PINS[@]}")
  fi
  "$VENV/bin/pip" install --progress-bar off "${pkgs[@]}"
  missing="$(check "${required[@]}")"
  [ -z "$missing" ] || { echo "Still missing after install: $missing" >&2; exit 1; }
fi

if [ "$ROLE" = worker ]; then
  "$PY" -c '
import torch, vllm
from vllm.tracing import is_otel_available
assert torch.cuda.is_available(), "torch cannot see a GPU"
assert is_otel_available(), "vLLM cannot load OpenTelemetry; request tracing would fail"
print("vllm", vllm.__version__, "| torch", torch.__version__, "CUDA", torch.version.cuda,
      "|", torch.cuda.device_count(), "x", torch.cuda.get_device_name(0))'
fi

SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
install -m 644 "$HERE/../app/llm_serve.py" "$SITE/llm_serve.py"
"$PY" -c 'import llm_serve'
echo "Ray $RAY_VERSION + Serve ready; app module at $SITE/llm_serve.py"
