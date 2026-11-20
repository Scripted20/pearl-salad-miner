#!/bin/sh
# Pearl miner entrypoint for SaladCloud (20.11.2026, rev 2 after review)
# - checks the wallet and settings, names the worker after the Salad machine
# - starts krig-miner with three Kryptex endpoints (failover)
# - watchdog: miner dead, no pool connection, no mining output, GPU idle
#   -> asks Salad IMDS to reallocate to another node, then exits 3.
#   Every check fails open: if a signal cannot be read, it is ignored, never treated as "bad".
set -u

log() { echo "$(date -u +%H:%M:%S) [entry] $*"; }
die() { log "FATAL: $*"; sleep 30; exit 2; }
num() { case "$2" in ''|*[!0-9]*) die "$1 must be a whole number (got '$2')";; esac; }

WALLET="$(printf '%s' "${WALLET:-}" | tr -d ' \t\r\n')"
POOLS="${POOLS:-prl-eu.kryptex.network prl.kryptex.network prl-us.kryptex.network}"
PORT="${PORT:-8048}"
STARTUP_GRACE="${STARTUP_GRACE:-600}"       # s allowed to reach the pool and print a mining line
NO_POOL_TIMEOUT="${NO_POOL_TIMEOUT:-600}"   # s without a pool connection, later on
LOG_STALE_TIMEOUT="${LOG_STALE_TIMEOUT:-900}" # s without a mining/share line, once one was seen
MIN_GPU_UTIL="${MIN_GPU_UTIL:-30}"          # %, 0 disables the GPU check
GPU_IDLE_TIMEOUT="${GPU_IDLE_TIMEOUT:-900}"
STATUS_EVERY="${STATUS_EVERY:-600}"
LOG_LEVEL="${LOG_LEVEL:-info}"
OK_REGEX="${OK_REGEX:-accept|th/s|hashes/s|hashrate}"  # case-insensitive, marks a healthy mining line

for v in PORT STARTUP_GRACE NO_POOL_TIMEOUT LOG_STALE_TIMEOUT MIN_GPU_UTIL GPU_IDLE_TIMEOUT STATUS_EVERY; do
  eval "num $v \"\$$v\""
done

case "$WALLET" in prl1*) ;; *) die "WALLET must be a Pearl address starting with prl1 (got '${WALLET:-empty}')";; esac
case "$WALLET" in *[!a-z0-9]*) die "WALLET has characters a Pearl address cannot have: '$WALLET'";; esac
[ "${#WALLET}" -ge 30 ] || die "WALLET looks too short: '$WALLET'"

MID="${SALAD_MACHINE_ID:-local}"
WORKER="$(printf '%s' "${WORKER:-s$MID}" | tr -cd 'A-Za-z0-9' | cut -c1-11)"
[ -n "$WORKER" ] || WORKER=salad

smi() { timeout 10 nvidia-smi "$@" 2>/dev/null; }
HAVE_SMI=0
if command -v nvidia-smi >/dev/null 2>&1; then
  INFO="$(smi --query-gpu=name,driver_version,memory.total,power.limit --format=csv,noheader | head -1)"
  if [ -n "$INFO" ]; then HAVE_SMI=1; log "gpu: $INFO"; else log "gpu: nvidia-smi gives no reading, GPU check off"; fi
else
  log "gpu: nvidia-smi not available, GPU check off"
fi
[ "$MIN_GPU_UTIL" -gt 0 ] || HAVE_SMI=0

PROC_OK=0
if cat /proc/net/tcp >/dev/null 2>&1; then PROC_OK=1; else log "warn: /proc/net/tcp not readable, pool check off"; fi

log "wallet=$WALLET worker=$WORKER machine=$MID"
log "pools=$POOLS port=$PORT"

ARGS=""
for h in $POOLS; do ARGS="$ARGS --url stratum+ssl://$h:$PORT"; done

RUN=/tmp/krig-run; mkdir -p "$RUN"; rm -f "$RUN/fifo" "$RUN/ok"
mkfifo "$RUN/fifo"
# miner output -> console, and a timestamp file whenever a healthy mining line appears
awk -v re="$OK_REGEX" -v f="$RUN/ok" '{ print; fflush(); if (tolower($0) ~ re) { print $0 > f; close(f) } }' < "$RUN/fifo" &
cd "$HOME" || cd /tmp
# shellcheck disable=SC2086
/opt/krig/krig-miner --coin pearl $ARGS --user "$WALLET/$WORKER" --no-tui --log-level "$LOG_LEVEL" > "$RUN/fifo" 2>&1 &
PID=$!
log "krig-miner started pid=$PID"

reallocate() {
  if [ "$MID" != local ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 --noproxy '*' -X POST \
      -H 'Metadata: true' -H 'Content-Type: application/json' \
      -d "{\"reason\":\"pearl miner: $1\"}" http://169.254.169.254/v1/reallocate)
    log "IMDS reallocate -> HTTP $CODE"
  fi
}
stop() { log "stopping ($1)"; kill "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null; exit "$2"; }
bad() { log "unhealthy: $1"; reallocate "$1"; stop "$1" 3; }
trap 'stop signal 0' TERM INT

pool_connected() {
  HEXPORT=$(printf '%04X' "$PORT")
  cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p=":$HEXPORT" '$3 ~ p"$" && $4 == "01" {f=1} END {exit !f}'
}
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

START=$(date +%s); LAST_POOL=0; EVER_POOL=0; LAST_BUSY=0; SMI_BAD=0; LAST_STATUS=$START
while :; do
  sleep 15
  NOW=$(date +%s); UP=$((NOW - START))
  if ! kill -0 "$PID" 2>/dev/null; then wait "$PID"; RC=$?; bad "krig-miner exited rc=$RC"; fi

  # pool connection
  if [ "$PROC_OK" = 1 ]; then
    if pool_connected; then LAST_POOL=$NOW; EVER_POOL=1; fi
    if [ "$EVER_POOL" = 0 ] && [ "$UP" -gt "$STARTUP_GRACE" ]; then bad "no pool connection within ${STARTUP_GRACE}s (DNS/firewall on this node?)"; fi
    if [ "$EVER_POOL" = 1 ] && [ $((NOW - LAST_POOL)) -gt "$NO_POOL_TIMEOUT" ]; then bad "pool connection lost for ${NO_POOL_TIMEOUT}s"; fi
  fi

  # mining output (only enforced once a matching line has been seen at least once)
  OKT=$(mtime "$RUN/ok")
  if [ "$OKT" -gt 0 ] && [ $((NOW - OKT)) -gt "$LOG_STALE_TIMEOUT" ]; then bad "no mining line for ${LOG_STALE_TIMEOUT}s"; fi

  # GPU utilisation: only valid 0-100 readings count; idle timer starts after the first valid busy reading
  UTIL=""
  if [ "$HAVE_SMI" = 1 ]; then
    UTIL=$(smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1 | tr -d ' \r')
    case "$UTIL" in
      ''|*[!0-9]*) UTIL=""; SMI_BAD=$((SMI_BAD + 1))
         if [ "$SMI_BAD" -ge 8 ]; then HAVE_SMI=0; log "warn: nvidia-smi readings unusable, GPU check off"; fi ;;
      *) SMI_BAD=0
         if [ "$UTIL" -le 100 ]; then
           if [ "$UTIL" -ge "$MIN_GPU_UTIL" ]; then LAST_BUSY=$NOW; fi
           if [ "$LAST_BUSY" -gt 0 ] && [ $((NOW - LAST_BUSY)) -gt "$GPU_IDLE_TIMEOUT" ]; then bad "GPU under ${MIN_GPU_UTIL}% for ${GPU_IDLE_TIMEOUT}s"; fi
         fi ;;
    esac
  fi

  if [ $((NOW - LAST_STATUS)) -ge "$STATUS_EVERY" ]; then
    LAST_STATUS=$NOW
    if [ "$EVER_POOL" = 1 ]; then AGO="$((NOW - LAST_POOL))s"; else AGO=never; fi
    if [ "$OKT" -gt 0 ]; then OKAGO="$((NOW - OKT))s"; else OKAGO=never; fi
    EXTRA=""
    [ "$HAVE_SMI" = 1 ] && EXTRA=" gpu=[$(smi --query-gpu=utilization.gpu,power.draw,temperature.gpu,clocks.mem --format=csv,noheader | head -1)]"
    log "STATUS uptime=${UP}s pool_ago=$AGO mining_line_ago=$OKAGO util=${UTIL:-?}${EXTRA}"
    [ -s "$RUN/ok" ] && log "last mining line: $(tail -c 300 "$RUN/ok")"
  fi
done
