# Progress reporting shared by the head and worker bootstrap scripts.
# Inlined into the rendered user_data, so it must stay plain bash.
#
# Every step is appended to $STATUS_FILE as  <epoch>|<RUN|OK|FAIL|DONE>|<step>|<detail>
# scripts/deploy.sh streams this file over SSH to show live progress; the full
# command trace goes to /var/log/ray-bootstrap.log.
STATUS_FILE=/var/log/ray-bootstrap.status
BOOT_START=$(date +%s)
CURRENT_STEP=""
STEP_START=$BOOT_START
touch "$STATUS_FILE" && chmod 644 "$STATUS_FILE"

report() { echo "$(date +%s)|$1|$2|${3:-}" >> "$STATUS_FILE"; }

finish_step() {
  if [ -n "$CURRENT_STEP" ]; then
    report OK "$CURRENT_STEP" "$(( $(date +%s) - STEP_START ))s"
  fi
  CURRENT_STEP=""
}

step() {
  finish_step
  CURRENT_STEP="$1"
  STEP_START=$(date +%s)
  report RUN "$CURRENT_STEP"
  echo "================ STEP: $CURRENT_STEP ================"
}

FAIL_REASON=""

on_error() {
  local rc=$1 line=$2 cmd=$3
  local reason="${FAIL_REASON:-exit $rc at line $line: $cmd}"
  report FAIL "${CURRENT_STEP:-bootstrap}" "$reason"
  echo "!!!!!!!! FAILED: ${CURRENT_STEP:-bootstrap} ($reason)"
  trap - ERR
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

bootstrap_done() {
  finish_step
  report DONE "bootstrap complete" "$(( $(date +%s) - BOOT_START ))s"
}

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
  local timeout=$1 desc=$2 waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      FAIL_REASON="timed out after $timeout seconds waiting for $desc"
      echo "$FAIL_REASON"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
