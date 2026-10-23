#!/usr/bin/env bash
# Show the deployed model: Serve application state, replicas per node, API check.
#   ./scripts/status.sh
source "$(dirname "$0")/common.sh"

require_cluster
NODE_MAP="$(node_map)"
export NODE_MAP

log "Ray Serve on $HEAD"
details="$(serve_details)" || die "Could not read Serve state from http://$HEAD:$DASHBOARD_PORT"
"$PYTHON" -c '
import json, os, sys
names = dict(p.split("=", 1) for p in os.environ.get("NODE_MAP", "").split())
apps = json.load(sys.stdin).get("applications") or {}
if not apps:
    print("  No applications deployed. Run ./scripts/deploy.sh")
for name, app in apps.items():
    args = (app.get("deployed_app_config") or {}).get("args") or {}
    engine = args.get("engine_args") or {}
    print("  app %-8s %s" % (name, app.get("status")))
    print("  model        %s (served as %s)" % (args.get("model", "?"), args.get("served_model_name") or args.get("model", "?")))
    print("  engine       %s" % ", ".join("%s=%s" % kv for kv in sorted(engine.items())))
    if app.get("message"):
        print("  message      " + app["message"].strip().replace("\n", "\n               "))
    for dname, dep in (app.get("deployments") or {}).items():
        print("  deployment   %s: %s" % (dname, dep.get("status")))
        for r in dep.get("replicas") or []:
            ip = r.get("node_ip")
            print("    %-10s %-9s pid %-7s %s" % (r.get("state"), names.get(ip, ip or "unscheduled"),
                                                r.get("pid") or "-", r.get("replica_id")))
        if dep.get("message"):
            print("    " + dep["message"].strip().replace("\n", "\n    "))
' <<<"$details"

API="$(api_url)"
log "API $API/v1"
if models="$(curl -sf --max-time 10 "$API/v1/models")"; then
  "$PYTHON" -c 'import json, sys; print("  serving: " + ", ".join(m["id"] for m in json.load(sys.stdin)["data"]))' <<<"$models"
elif hssh "curl -sf --max-time 10 http://127.0.0.1:$SERVE_PORT/v1/models" >/dev/null 2>&1; then
  warn "The API answers on the head but not from here: port $SERVE_PORT isn't open to your IP.
  Apply the rule with: terraform -chdir=$GPU_WORKERS_DIR/terraform apply (or use an SSH tunnel + LLM_API_URL)"
else
  warn "The API is not answering (no model deployed, or replicas still starting)"
fi
