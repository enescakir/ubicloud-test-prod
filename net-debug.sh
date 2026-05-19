#!/usr/bin/env bash
# Reproduce / diagnose actions/checkout git-fetch stalls against GitHub.
#
# Usage: ./net-debug.sh [iterations] [target-repo]
#   iterations    default 5
#   target-repo   default https://github.com/ubicloud/ubicloud (public)
#
# Live view:  tail -f netdebug-*/run-NN.log   (from a second shell)
#
# Output: ./netdebug-<host>-<UTC-ts>/
#   env.txt, run-NN.log, run-NN.tcpdump (if tcpdump+sudo), summary.tsv

set -u
ITER="${1:-5}"
REPO="${2:-https://github.com/ubicloud/ubicloud}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-180}"
STALL_THRESHOLD="${STALL_THRESHOLD:-30}"
HOST_SHORT="$(hostname -s)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$(pwd)/netdebug-${HOST_SHORT}-${TS}"
mkdir -p "$OUT"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

have() { command -v "$1" >/dev/null 2>&1; }
sudo_ok() { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; }
to_ms() { awk -v v="$1" 'BEGIN{ printf "%.0f", v*1000 }'; }

# Per-line timestamp filter (writes to stdout, used via redirection to a file)
ts_filter() {
  if have ts; then ts '[%H:%M:%S]'
  else awk '{ "date -u +%H:%M:%S" | getline t; close("date -u +%H:%M:%S"); print "["t"] "$0; fflush() }'
  fi
}

echo "Output dir: $OUT"
echo "Live view:  tail -F $OUT/run-NN.log    (in another terminal)"
echo

###############################################################################
# Environment snapshot (one-shot)
###############################################################################
{
  echo "===== uname / date ====="; uname -a; date -u; echo
  echo "===== resolv.conf ====="; cat /etc/resolv.conf 2>/dev/null; echo
  echo "===== route to github.com ====="
  getent ahosts github.com
  ip route get 140.82.121.4 2>/dev/null
  echo
  echo "===== interface MTUs ====="; ip -br link 2>/dev/null; echo
  echo "===== sysctl tcp ====="
  sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_retries2 net.ipv4.tcp_keepalive_time 2>/dev/null
  echo
  echo "===== git / curl versions ====="; git --version; curl --version | head -1; echo
  if have traceroute; then
    echo "===== TCP traceroute to github.com:443 ====="
    if sudo_ok; then sudo traceroute -T -p 443 -w 2 -q 1 -m 20 github.com 2>&1
    else traceroute -p 443 -w 2 -q 1 -m 20 github.com 2>&1
    fi
  fi
} >"$OUT/env.txt" 2>&1

###############################################################################
# Per-iteration probes
###############################################################################
SUMMARY="$OUT/summary.tsv"
printf 'iter\tstatus\tdns_ms\ttcp_ms\ttls_ms\tttfb_ms\tcurl_total_ms\tfetch_s\tstalled\tmax_gap_s\n' >"$SUMMARY"

CURL_FMT='%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code} %{size_download}\n'

for i in $(seq 1 "$ITER"); do
  TAG=$(printf '%02d' "$i")
  LOG="$OUT/run-$TAG.log"
  PCAP="$OUT/run-$TAG.tcpdump"
  : >"$LOG"

  HEADER="=== iter $i / $ITER — $(date -u +%H:%M:%SZ) host=$HOST_SHORT repo=$REPO ==="
  echo "$HEADER"
  echo "$HEADER" >>"$LOG"

  # ---- curl timing to github.com (control) and codeload (data plane) ----
  T_DNS=0 T_CONN=0 T_TLS=0 T_TTFB=0 T_TOTAL=0
  for url in "https://github.com/" "https://codeload.github.com/octocat/Hello-World/tar.gz/refs/heads/master"; do
    echo "--- curl $url" >>"$LOG"
    TIMINGS=$(curl -sS -o /dev/null -w "$CURL_FMT" --max-time 30 "$url" 2>>"$LOG" || echo "ERR ERR ERR ERR ERR 000 0")
    echo "  dns connect appconnect ttfb total code bytes: $TIMINGS" >>"$LOG"
    if [ "$url" = "https://github.com/" ]; then
      read -r T_DNS T_CONN T_TLS T_TTFB T_TOTAL _CODE _BYTES <<<"$TIMINGS"
    fi
  done

  # ---- optional packet capture (background; we kill it cleanly at the end) ----
  TCPDUMP_PID=""
  if have tcpdump && sudo_ok; then
    nohup sudo tcpdump -i any -s 96 -w "$PCAP" -U \
      "(host github.com or host codeload.github.com) and tcp port 443" \
      </dev/null >/dev/null 2>>"$LOG" &
    TCPDUMP_PID=$!
    disown "$TCPDUMP_PID" 2>/dev/null || true
    sleep 0.3
  fi

  # ---- the actual fetch ----
  WORKDIR=$(mktemp -d)
  FETCH_START=$(date +%s)
  (
    cd "$WORKDIR"
    git init -q
    git remote add origin "$REPO"
    git config --local gc.auto 0
    git config --local maintenance.auto false
    [ -n "${GH_TOKEN:-}" ] && git config http.extraHeader "Authorization: Bearer $GH_TOKEN"

    # All output to stdout, timestamped, then redirected by the caller.
    GIT_TRACE=1 GIT_CURL_VERBOSE=1 GIT_PROGRESS_DELAY=0 \
      timeout --foreground "$FETCH_TIMEOUT" \
        git -c protocol.version=2 -c gc.auto=0 -c maintenance.auto=false \
            fetch --no-tags --prune --no-recurse-submodules \
                  --progress --depth=1 origin HEAD 2>&1
    RC=$?
    echo "__FETCH_EXIT=$RC"
  ) </dev/null 2>&1 | ts_filter >>"$LOG"
  FETCH_END=$(date +%s)
  FETCH_S=$((FETCH_END - FETCH_START))

  # Kill tcpdump without waiting on it
  if [ -n "$TCPDUMP_PID" ]; then
    sudo kill -INT "$TCPDUMP_PID" 2>/dev/null || true
    # In case sudo's child outlives the sudo wrapper:
    sudo pkill -INT -f "tcpdump -i any -s 96 -w $PCAP" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"

  # ---- parse log for exit code, stall ----
  FETCH_RC=$(grep -oE '__FETCH_EXIT=[0-9]+' "$LOG" | tail -1 | cut -d= -f2)
  FETCH_RC=${FETCH_RC:-1}

  MAX_GAP=$(awk -v thr="$STALL_THRESHOLD" '
    match($0, /\[([0-9]+):([0-9]+):([0-9]+)\]/, m) {
      t = m[1]*3600 + m[2]*60 + m[3]
      if (prev != "") { gap = t - prev; if (gap < 0) gap += 86400; if (gap > max) max = gap }
      prev = t
    }
    END { print max+0 }
  ' "$LOG")

  case "$FETCH_RC" in
    0) STATUS=ok ;;
    124) STATUS=timeout ;;
    *) STATUS="fail($FETCH_RC)" ;;
  esac
  STALLED=no
  [ "${MAX_GAP:-0}" -ge "$STALL_THRESHOLD" ] && STALLED=yes
  [ "$STATUS" = "timeout" ] && STALLED=yes

  ROW=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$i" "$STATUS" \
    "$(to_ms "${T_DNS:-0}")" "$(to_ms "${T_CONN:-0}")" "$(to_ms "${T_TLS:-0}")" \
    "$(to_ms "${T_TTFB:-0}")" "$(to_ms "${T_TOTAL:-0}")" \
    "$FETCH_S" "$STALLED" "${MAX_GAP:-0}")
  echo "$ROW" >>"$SUMMARY"
  echo "  -> status=$STATUS fetch=${FETCH_S}s stalled=$STALLED max_gap=${MAX_GAP}s (log: $LOG)"
done

###############################################################################
# Final summary
###############################################################################
echo
echo "==================== summary ===================="
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "Logs: $OUT"
