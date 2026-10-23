# Physical resource use on one node, for scripts/undeploy.sh, which sends this
# file's text as the SSH command (so no shebang and no $0).
# The last line is "NODE_STATUS CLEAN" or "NODE_STATUS BUSY <reasons>".
busy=""
if command -v nvidia-smi >/dev/null; then
  nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits \
    | awk -F', *' '{ printf "gpu%s      %s / %s MiB used, %s%% busy\n", $1, $2, $3, $4 }'
  apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader)"
  if [ -n "$apps" ]; then
    busy="$busy, GPU processes"
    sed 's/^/gpu proc  /' <<<"$apps"
  fi
fi
free -m | awk '/^Mem:/ { printf "ram       %d / %d MiB used (%d MiB available)\n", $3, $2, $7 }'
df -h --output=used,size,avail / | awk 'NR == 2 { printf "disk      %s / %s used, %s free\n", $1, $2, $3 }'
[ -d ~/.cache/huggingface/hub ] && echo "models    $(du -sh ~/.cache/huggingface/hub | cut -f1) in ~/.cache/huggingface/hub"
# The [x] keeps the pattern from matching this script's own command line.
left="$(pgrep -af '[S]erveReplica|[v]llm' || true)"
if [ -n "$left" ]; then
  busy="$busy, replica processes"
  sed 's/^/process   /' <<<"$left"
fi
if [ -n "$busy" ]; then echo "NODE_STATUS BUSY ${busy#, }"; else echo "NODE_STATUS CLEAN"; fi
