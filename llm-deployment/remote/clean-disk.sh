# Frees the disk a model deployment used on one node, for scripts/undeploy.sh,
# which sends this file's text as the SSH command with KEEP_MODEL=0|1 in front.
# Runs only once the node is drained, so nothing has these files open.
# Keeps the packages in /opt/ray/venv: the next deploy reuses them.
used() { df -B1 --output=used / | tail -n 1; }
remove() {   # remove <path> [sudo]
  ${2:+sudo -n} test -e "$1" 2>/dev/null || return 0
  printf 'removed   %-34s %s\n' "${1/#$HOME/\~}" "$(${2:+sudo -n} du -sh "$1" 2>/dev/null | cut -f1)"
  ${2:+sudo -n} rm -rf "$1"
}

before=$(used)
if [ "${KEEP_MODEL:-0}" = 1 ]; then
  [ -d ~/.cache/huggingface/hub ] && printf 'kept      %-34s %s\n' "~/.cache/huggingface/hub" "$(du -sh ~/.cache/huggingface/hub | cut -f1)"
else
  remove ~/.cache/huggingface/hub    # model weights
  remove ~/.cache/huggingface/xet    # hf-xet download chunks
fi
# Compile caches (vLLM, torch, Triton) and pip's download cache.
for p in ~/.cache/vllm ~/.cache/torch ~/.cache/torch_extensions ~/.triton ~/.cache/outlines ~/.cache/pip; do
  remove "$p"
done
remove /root/.cache/pip sudo
# Logs of earlier Ray sessions; the running session's stay.
current="$(readlink -f /tmp/ray/session_latest 2>/dev/null)"
for s in /tmp/ray/session_2*; do
  [ -d "$s" ] && [ "$(readlink -f "$s")" != "$current" ] && remove "$s"
done
[ -d /opt/ray/venv ] && printf 'kept      %-34s %s\n' "/opt/ray/venv (Ray, vLLM)" "$(du -sh /opt/ray/venv | cut -f1)"
freed=$(( before - $(used) ))
df -h --output=used,size,avail / | awk -v f="$(numfmt --to=iec "$(( freed > 0 ? freed : 0 ))")" \
  'NR == 2 { printf "disk      %s / %s used, %s free (freed %s)\n", $1, $2, $3, f }'
