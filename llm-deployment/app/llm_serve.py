"""Ray Serve application: an OpenAI-compatible LLM endpoint backed by vLLM.

scripts/deploy.sh installs this module into Ray's venv on every node and deploys
it with a Serve config whose import_path is ``llm_serve:build_app``. vLLM is
imported only inside the replicas (on GPU workers), so the CPU-only head can
build the application without it.

Endpoints:
  GET  /v1/models
  POST /v1/chat/completions    (supports "stream": true)
  POST /v1/completions         (supports "stream": true)
  GET  /health

Metrics: each replica records vLLM's engine stats as Ray metrics, which Ray
exports on every node's metrics port (:8080) as ray_llm_* series. Prometheus
on the head already scrapes that port; the "LLM Serving" Grafana dashboard
reads them.

Tracing: with an otlp_endpoint (deploy.sh points it at Tempo on the head),
every request becomes a trace - the server span (child of the caller's W3C
traceparent header, if sent), prompt preparation, generation, and vLLM's own
llm_request span with queue time and time to first token. Responses carry the
trace ID in an X-Trace-Id header; look it up in Grafana > Explore > Tempo.
"""
import json
import logging
import os
import socket
import time
import urllib.parse
import uuid
from typing import Any, AsyncIterator, Dict, List, Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from ray import serve

logger = logging.getLogger("ray.serve")

TRACE_SERVICE = "llm-serve"   # service.name of the spans in Tempo

api = FastAPI(title="Ray Serve LLM")

# OpenAI request fields passed straight through to vLLM's SamplingParams.
SAMPLING_FIELDS = (
    "n", "temperature", "top_p", "top_k", "min_tokens", "stop", "seed",
    "presence_penalty", "frequency_penalty", "repetition_penalty",
)


class RayStatLogger:
    """vLLM stat logger that records engine stats as Ray metrics.

    vLLM calls log() after every engine step with that step's Stats; fields are
    read with getattr so small differences between vLLM versions don't break it.
    """

    TTFT_BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 40]
    TPOT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1]
    REQUEST_BUCKETS = [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 40, 60, 120, 300]

    def __init__(self, model: str, replica: str):
        from ray.util import metrics

        tags = {"model": model, "replica": replica}

        def gauge(name, doc):
            m = metrics.Gauge(name, doc, tag_keys=tuple(tags))
            m.set_default_tags(tags)
            return m

        def counter(name, doc, extra=()):
            m = metrics.Counter(name, doc, tag_keys=tuple(tags) + tuple(extra))
            m.set_default_tags(tags)
            return m

        def histogram(name, doc, buckets):
            m = metrics.Histogram(name, doc, boundaries=buckets, tag_keys=tuple(tags))
            m.set_default_tags(tags)
            return m

        self.running = gauge("llm_num_requests_running", "Requests being generated")
        self.waiting = gauge("llm_num_requests_waiting", "Requests queued in the engine")
        self.kv_cache = gauge("llm_gpu_cache_usage", "Share of GPU KV-cache blocks in use (0-1)")
        self.prompt_tokens = counter("llm_prompt_tokens", "Prompt tokens processed")
        self.generation_tokens = counter("llm_generation_tokens", "Tokens generated")
        self.preemptions = counter("llm_num_preemptions", "Requests preempted for lack of KV cache")
        self.finished = counter("llm_request_finished", "Finished requests", extra=("finished_reason",))
        self.ttft = histogram("llm_time_to_first_token_seconds", "Time to first token", self.TTFT_BUCKETS)
        self.tpot = histogram("llm_time_per_output_token_seconds", "Time per output token", self.TPOT_BUCKETS)
        self.e2e = histogram("llm_e2e_request_latency_seconds", "End-to-end request latency", self.REQUEST_BUCKETS)
        self.queue = histogram("llm_request_queue_time_seconds", "Time requests wait in the queue", self.REQUEST_BUCKETS)

    def log(self, stats) -> None:
        def get(name, default=0):
            value = getattr(stats, name, None)
            return default if value is None else value

        self.running.set(get("num_running_sys"))
        self.waiting.set(get("num_waiting_sys"))
        self.kv_cache.set(get("gpu_cache_usage_sys"))
        for metric, field in ((self.prompt_tokens, "num_prompt_tokens_iter"),
                              (self.generation_tokens, "num_generation_tokens_iter"),
                              (self.preemptions, "num_preemption_iter")):
            if get(field) > 0:
                metric.inc(get(field))
        for metric, field in ((self.ttft, "time_to_first_tokens_iter"),
                              (self.tpot, "time_per_output_tokens_iter"),
                              (self.e2e, "time_e2e_requests"),
                              (self.queue, "time_in_queue_requests")):
            for value in get(field, []):
                metric.observe(value)
        for reason in get("finished_reason_requests", []):
            self.finished.inc(1, tags={"finished_reason": str(reason)})

    def info(self, type: str, obj: Any) -> None:  # part of vLLM's stat logger interface
        pass


def _replica_id() -> str:
    try:
        context = serve.get_replica_context()
        replica_id = getattr(context, "replica_id", None)
        return getattr(replica_id, "unique_id", None) or str(getattr(context, "replica_tag", "replica"))
    except Exception:
        return uuid.uuid4().hex[:8]


def _tracer(endpoint: str):
    """OpenTelemetry tracer that exports to `endpoint`; a no-op one without it.

    Given otlp_traces_endpoint, vLLM installs a global tracer provider for its
    llm_request spans; reuse it so all of a replica's spans share one exporter.
    """
    from opentelemetry import trace

    if not endpoint:
        return trace.NoOpTracer()
    from opentelemetry.sdk.trace import TracerProvider

    provider = trace.get_tracer_provider()
    if not isinstance(provider, TracerProvider):
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        provider = TracerProvider()   # resource from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
        trace.set_tracer_provider(provider)
    return provider.get_tracer("llm_serve")


class RequestTrace:
    """The spans of one API request, each ended exactly once:

        POST /v1/chat/completions   server span; parent = the caller's traceparent, if any
        |- prepare_prompt           chat template, tokenization, sampling params
        `- generate                 submitted to vLLM until the last token (event: first_token)
           `- llm_request           vLLM's span: queue time, time to first token, e2e
    """

    def __init__(self, tracer, route: str, headers, attributes: Dict[str, Any]):
        from opentelemetry import trace
        from opentelemetry.trace import Status, StatusCode
        from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

        self._trace, self._status, self._code = trace, Status, StatusCode
        self._propagator = TraceContextTextMapPropagator()
        self.tracer = tracer
        self.span = tracer.start_span("POST " + route, context=self._propagator.extract(dict(headers)),
                                      kind=trace.SpanKind.SERVER, attributes=attributes)
        self.generate_span = None
        self.start = time.monotonic()
        self.first_token: Optional[float] = None
        self.last = None   # latest RequestOutput from vLLM
        self.ended = False

    @property
    def trace_id(self) -> str:
        ctx = self.span.get_span_context()
        return format(ctx.trace_id, "032x") if ctx.is_valid else ""

    def child(self, name: str):
        """Context manager timing a synchronous step under the server span."""
        return self.tracer.start_as_current_span(name, context=self._trace.set_span_in_context(self.span))

    def start_generate(self, request_id: str, prompt_tokens: int, params) -> Optional[Dict[str, str]]:
        """Starts the generate span; returns the trace headers that parent vLLM's span to it."""
        self.span.set_attribute("gen_ai.response.id", request_id)
        self.generate_span = self.tracer.start_span(
            "generate", context=self._trace.set_span_in_context(self.span),
            attributes={"gen_ai.response.id": request_id, "gen_ai.usage.input_tokens": prompt_tokens,
                        "gen_ai.request.max_tokens": params.max_tokens,
                        "gen_ai.request.temperature": params.temperature,
                        "gen_ai.request.top_p": params.top_p})
        headers: Dict[str, str] = {}
        self._propagator.inject(headers, context=self._trace.set_span_in_context(self.generate_span))
        return headers or None   # empty when tracing is off

    def on_output(self, output) -> None:
        self.last = output
        if self.first_token is None and any(o.token_ids for o in output.outputs):
            self.first_token = time.monotonic() - self.start
            self.span.set_attribute("llm.time_to_first_token_s", round(self.first_token, 4))
            if self.generate_span is not None:
                self.generate_span.add_event("first_token")

    def finish(self, status: int = 200, error: Optional[str] = None) -> None:
        if self.ended:
            return
        self.ended = True
        attributes: Dict[str, Any] = {"http.response.status_code": status}
        if self.last is not None:
            attributes["gen_ai.usage.output_tokens"] = sum(len(o.token_ids) for o in self.last.outputs)
            attributes["gen_ai.response.finish_reasons"] = [str(o.finish_reason) for o in self.last.outputs]
        if error:
            attributes["error.message"] = error
        for span in (self.generate_span, self.span):   # child first
            if span is None:
                continue
            span.set_attributes(attributes)
            if status >= 499:   # 499: the client went away mid-stream
                span.set_status(self._status(self._code.ERROR, error))
            span.end()


class APIError(Exception):
    def __init__(self, status: int, message: str, kind: str = "invalid_request_error"):
        super().__init__(message)
        self.status, self.message, self.kind = status, message, kind

    def response(self) -> JSONResponse:
        return JSONResponse(
            {"error": {"message": self.message, "type": self.kind, "code": self.status}},
            status_code=self.status,
        )


@serve.deployment(name="LLMServer")
@serve.ingress(api)
class LLMServer:
    def __init__(self, model: str, served_model_name: str, engine_args: Dict[str, Any],
                 otlp_endpoint: str = ""):
        from transformers import AutoTokenizer
        from vllm.engine.arg_utils import AsyncEngineArgs
        from vllm.engine.async_llm_engine import AsyncLLMEngine

        self.model_name = served_model_name
        self.created = int(time.time())
        self.replica = _replica_id()
        if otlp_endpoint:
            # Read by both vLLM's tracer provider and ours.
            os.environ.setdefault("OTEL_SERVICE_NAME", TRACE_SERVICE)
            os.environ["OTEL_RESOURCE_ATTRIBUTES"] = ",".join(
                "%s=%s" % (k, urllib.parse.quote(v, safe="/:.-_"))
                for k, v in (("service.instance.id", self.replica), ("host.name", socket.gethostname()),
                             ("llm.model", served_model_name)))
            engine_args = {**engine_args, "otlp_traces_endpoint": otlp_endpoint}

        logger.info("Starting vLLM for %s with %s", model, engine_args)
        self.engine = AsyncLLMEngine.from_engine_args(AsyncEngineArgs(model=model, **engine_args))
        self.max_model_len = self.engine.engine.model_config.max_model_len
        self.tokenizer = AutoTokenizer.from_pretrained(
            model,
            revision=engine_args.get("revision"),
            trust_remote_code=engine_args.get("trust_remote_code", False),
        )
        try:
            self.engine.engine.add_logger("ray_metrics", RayStatLogger(served_model_name, self.replica))
        except Exception:  # serving matters more than metrics
            logger.exception("Could not attach the metrics logger; ray_llm_* metrics are disabled")
        self.tracer = _tracer(otlp_endpoint)
        if otlp_endpoint:
            logger.info("Tracing requests to %s as service %s", otlp_endpoint, TRACE_SERVICE)
        logger.info("Model %s ready (context %d tokens)", model, self.max_model_len)

    async def check_health(self) -> None:
        # Called by Serve; an exception marks the replica unhealthy and restarts it.
        await self.engine.check_health()

    # ------------------------------------------------------------------ routes
    @api.get("/health")
    async def health(self):
        await self.engine.check_health()
        return {"status": "ok"}

    @api.get("/v1/models")
    async def models(self):
        return {
            "object": "list",
            "data": [{"id": self.model_name, "object": "model",
                      "created": self.created, "owned_by": "ray-serve"}],
        }

    @api.post("/v1/chat/completions")
    async def chat_completions(self, request: Request):
        return await self._handle(request, chat=True)

    @api.post("/v1/completions")
    async def completions(self, request: Request):
        return await self._handle(request, chat=False)

    # ----------------------------------------------------------------- helpers
    async def _handle(self, request: Request, chat: bool):
        route = "/v1/chat/completions" if chat else "/v1/completions"
        rt = RequestTrace(self.tracer, route, request.headers, {
            "http.request.method": "POST", "http.route": route, "gen_ai.system": "vllm",
            "gen_ai.request.model": self.model_name, "llm.replica": self.replica})
        status, error, streaming = 200, None, False
        try:
            body = await self._read_body(request)
            rt.span.set_attribute("llm.stream", bool(body.get("stream")))
            with rt.child("prepare_prompt"):
                if chat:
                    prompt_ids = self._chat_prompt_ids(body.get("messages"))
                else:
                    prompt_ids = self._completion_prompt_ids(body.get("prompt"))
                params = self._sampling_params(body, len(prompt_ids))
            response = await self._respond(body, prompt_ids, params, chat, rt)
            streaming = isinstance(response, StreamingResponse)   # the stream ends the spans
        except APIError as e:
            status, error = e.status, e.message
            response = e.response()
        except Exception as e:
            status, error = 500, "%s: %s" % (type(e).__name__, e)
            rt.span.record_exception(e)
            raise
        finally:
            if not streaming:
                rt.finish(status, error)
        if rt.trace_id:
            response.headers["X-Trace-Id"] = rt.trace_id
        return response

    async def _read_body(self, request: Request) -> Dict[str, Any]:
        try:
            body = await request.json()
        except ValueError:
            raise APIError(400, "Request body must be JSON")
        if not isinstance(body, dict):
            raise APIError(400, "Request body must be a JSON object")
        model = body.get("model")
        if model and model != self.model_name:
            raise APIError(404, f"Model '{model}' not found; this endpoint serves '{self.model_name}'",
                           "model_not_found")
        return body

    def _chat_prompt_ids(self, messages: Any) -> List[int]:
        if not isinstance(messages, list) or not messages:
            raise APIError(400, "'messages' must be a non-empty list")
        if not getattr(self.tokenizer, "chat_template", None):
            raise APIError(400, f"{self.model_name} has no chat template; use /v1/completions")
        conversation = []
        for message in messages:
            if not isinstance(message, dict):
                raise APIError(400, "Each message must be an object with 'role' and 'content'")
            content = message.get("content")
            if isinstance(content, list):  # OpenAI content parts: only text is supported
                content = "".join(p.get("text", "") for p in content
                                  if isinstance(p, dict) and p.get("type") == "text")
            conversation.append({"role": message.get("role", "user"), "content": content or ""})
        try:
            return self.tokenizer.apply_chat_template(conversation, tokenize=True, add_generation_prompt=True)
        except Exception as e:  # template errors, e.g. a role the model doesn't support
            raise APIError(400, f"Could not apply the chat template: {e}")

    def _completion_prompt_ids(self, prompt: Any) -> List[int]:
        if isinstance(prompt, list) and len(prompt) == 1:
            prompt = prompt[0]
        if not isinstance(prompt, str) or not prompt:
            raise APIError(400, "'prompt' must be a non-empty string")
        return self.tokenizer(prompt).input_ids

    def _sampling_params(self, body: Dict[str, Any], prompt_len: int):
        from vllm import SamplingParams

        room = self.max_model_len - prompt_len
        if room <= 0:
            raise APIError(400, f"The prompt is {prompt_len} tokens; the context is {self.max_model_len}")
        kwargs = {k: body[k] for k in SAMPLING_FIELDS if body.get(k) is not None}
        max_tokens = body.get("max_completion_tokens") or body.get("max_tokens")
        kwargs["max_tokens"] = min(int(max_tokens), room) if max_tokens else room
        try:
            return SamplingParams(**kwargs)
        except (TypeError, ValueError) as e:
            raise APIError(400, str(e))

    async def _respond(self, body: Dict[str, Any], prompt_ids: List[int], params, chat: bool,
                       rt: RequestTrace):
        request_id = ("chatcmpl-" if chat else "cmpl-") + uuid.uuid4().hex
        created = int(time.time())
        trace_headers = rt.start_generate(request_id, len(prompt_ids), params)
        results = self.engine.generate({"prompt_token_ids": prompt_ids}, params, request_id,
                                       trace_headers=trace_headers)

        if body.get("stream"):
            return StreamingResponse(self._stream(results, request_id, created, chat, rt),
                                     media_type="text/event-stream")

        final = None
        try:
            async for output in results:
                final = output
                rt.on_output(output)
        except ValueError as e:
            raise APIError(400, str(e))

        choices = []
        for o in final.outputs:
            choice = {"index": o.index, "finish_reason": o.finish_reason}
            if chat:
                choice["message"] = {"role": "assistant", "content": o.text}
            else:
                choice["text"] = o.text
            choices.append(choice)
        completion_tokens = sum(len(o.token_ids) for o in final.outputs)
        return JSONResponse({
            "id": request_id,
            "object": "chat.completion" if chat else "text_completion",
            "created": created,
            "model": self.model_name,
            "choices": choices,
            "usage": {
                "prompt_tokens": len(prompt_ids),
                "completion_tokens": completion_tokens,
                "total_tokens": len(prompt_ids) + completion_tokens,
            },
        })

    async def _stream(self, results, request_id: str, created: int, chat: bool,
                      rt: RequestTrace) -> AsyncIterator[str]:
        """Server-sent events; vLLM yields cumulative text, so send only the new part."""
        kind = "chat.completion.chunk" if chat else "text_completion"
        sent: Dict[int, int] = {}  # choice index -> characters already sent

        def event(payload: Dict[str, Any]) -> str:
            return "data: " + json.dumps(payload) + "\n\n"

        status, error, done = 200, None, False
        try:
            async for output in results:
                rt.on_output(output)
                for o in output.outputs:
                    first = o.index not in sent
                    delta = o.text[sent.get(o.index, 0):]
                    sent[o.index] = len(o.text)
                    if not (delta or first or o.finish_reason):
                        continue
                    if chat:
                        message = {"content": delta}
                        if first:
                            message["role"] = "assistant"
                        choice = {"index": o.index, "delta": message, "finish_reason": o.finish_reason}
                    else:
                        choice = {"index": o.index, "text": delta, "finish_reason": o.finish_reason}
                    yield event({"id": request_id, "object": kind, "created": created,
                                 "model": self.model_name, "choices": [choice]})
            done = True
        except ValueError as e:
            status, error, done = 400, str(e), True
            yield event({"error": {"message": str(e), "type": "invalid_request_error", "code": 400}})
        finally:
            if not done:   # cancelled: the client disconnected
                status, error = 499, "client disconnected"
            rt.finish(status, error)
        yield "data: [DONE]\n\n"


def build_app(args: Dict[str, Any]) -> serve.Application:
    """Application builder referenced by the Serve config.

    args: model, served_model_name, num_replicas, max_ongoing_requests,
    engine_args (keyword arguments for vLLM's AsyncEngineArgs) and otlp_endpoint
    (OTLP/gRPC collector for request traces; empty turns tracing off).
    """
    model = args["model"]
    served_model_name = args.get("served_model_name") or model
    engine_args = {"disable_log_requests": True, **args.get("engine_args", {})}
    tp = int(engine_args.get("tensor_parallel_size", 1))

    if tp == 1:
        placement = {"ray_actor_options": {"num_cpus": 1, "num_gpus": 1}}
    else:
        # The replica drives vLLM's Ray workers, one GPU each, packed on one node.
        engine_args.setdefault("distributed_executor_backend", "ray")
        placement = {
            "placement_group_bundles": [{"CPU": 1}] + [{"CPU": 1, "GPU": 1}] * tp,
            "placement_group_strategy": "STRICT_PACK",
        }

    return LLMServer.options(
        num_replicas=int(args.get("num_replicas", 1)),
        max_ongoing_requests=int(args.get("max_ongoing_requests", 64)),
        **placement,
    ).bind(model, served_model_name, engine_args, args.get("otlp_endpoint") or "")
