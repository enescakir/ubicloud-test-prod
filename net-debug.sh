#!/usr/bin/env bash
# Diagnose actions/checkout git-fetch stalls and slow GitHub throughput from Ubicloud runners.
#
# Usage: ./net-debug.sh [iterations] [target-repo]
#   iterations    default 5
#   target-repo   default https://github.com/ubicloud/ubicloud (public; private repos need GH_TOKEN)
#
# What it does per iteration:
#   1. curl timing probes to github.com and codeload.github.com (handshake latency)
#   2. bandwidth probes: download fixed-size objects from GitHub (data plane) and from
#      Cloudflare + Hetzner (controls). Tells you whether throughput is GitHub-specific.
#   3. depth=1 git fetch with per-line timestamps; detects stalls (gaps in output).
#
# Live view:  tail -F netdebug-*/run-NN.log   (in a second shell)
#
# Output dir: ./netdebug-<host>-<UTC-ts>/
#   env.txt, run-NN.log, run-NN.tcpdump (if tcpdump+sudo), fetch.tsv, bw.tsv, summary.md

set -u
ITER="${1:-5}"
REPO="${2:-https://github.com/ubicloud/ubicloud}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-180}"
BW_TIMEOUT="${BW_TIMEOUT:-30}"
STALL_THRESHOLD="${STALL_THRESHOLD:-30}"
HOST_SHORT="$(hostname -s)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$(pwd)/netdebug-output"
mkdir -p "$OUT"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

have() { command -v "$1" >/dev/null 2>&1; }
sudo_ok() { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; }
to_ms() { awk -v v="$1" 'BEGIN{ printf "%.0f", v*1000 }'; }
to_mbps() { awk -v v="$1" 'BEGIN{ printf "%.2f", v*8/1000/1000 }'; }    # bytes/s → Mbit/s
to_kbps() { awk -v v="$1" 'BEGIN{ printf "%.1f", v*8/1000 }'; }         # bytes/s → kbit/s

ts_filter() {
  if have ts; then ts '[%H:%M:%S]'
  else awk '{ "date -u +%H:%M:%S" | getline t; close("date -u +%H:%M:%S"); print "["t"] "$0; fflush() }'
  fi
}

# Convert a TSV file (with header) to a GitHub-flavoured markdown table.
tsv_to_md() {
  awk -F'\t' '
    NR==1 {
      printf "|"; for (i=1;i<=NF;i++) printf " %s |", $i; print ""
      printf "|"; for (i=1;i<=NF;i++) printf "------|"; print ""
      next
    }
    { printf "|"; for (i=1;i<=NF;i++) printf " %s |", $i; print "" }
  ' "$1"
}

# Bandwidth endpoints to probe. Picked so the throughput numbers are comparable.
# label|url
BW_TARGETS=(
  "github_codeload|https://codeload.github.com/git/git/tar.gz/refs/tags/v2.45.0"
  "github_release|https://github.com/cli/cli/releases/download/v2.40.0/gh_2.40.0_linux_amd64.tar.gz"
  "cloudflare_10MB|https://speed.cloudflare.com/__down?bytes=10485760"
  "hetzner_100MB|https://speed.hetzner.de/100MB.bin"
)

echo "Output dir: $OUT"
echo "Live view:  tail -F $OUT/run-NN.log    (in another terminal)"
echo

###############################################################################
# Environment snapshot (one-shot)
###############################################################################
{
  echo "===== uname / date ====="; uname -a; date -u; echo
  echo "===== resolv.conf ====="; cat /etc/resolv.conf 2>/dev/null; echo
  echo "===== routes ====="
  echo "github.com:";     getent ahosts github.com;            ip route get 140.82.121.4 2>/dev/null
  echo "codeload:";       getent ahosts codeload.github.com
  echo "speed.hetzner:";  getent ahosts speed.hetzner.de
  echo
  echo "===== interface MTUs ====="; ip -br link 2>/dev/null; echo
  echo "===== sysctl tcp ====="
  sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_retries2 net.ipv4.tcp_keepalive_time 2>/dev/null
  echo
  echo "===== git / curl versions ====="; git --version; curl --version | head -1; echo
  if have mtr && sudo_ok; then
    echo "===== mtr to github.com:443 (60 packets, TCP) ====="
    sudo mtr -rwbzc 60 -P 443 -T github.com 2>&1
    echo
    echo "===== mtr to 1.1.1.1 (control) ====="
    sudo mtr -rwbzc 60 1.1.1.1 2>&1
  elif have traceroute; then
    echo "===== TCP traceroute to github.com:443 ====="
    if sudo_ok; then sudo traceroute -T -p 443 -w 2 -q 1 -m 20 github.com 2>&1
    else traceroute -p 443 -w 2 -q 1 -m 20 github.com 2>&1
    fi
  fi
} >"$OUT/env.txt" 2>&1

###############################################################################
# Per-iteration probes
###############################################################################
FETCH_TSV="$OUT/fetch.tsv"
BW_TSV="$OUT/bw.tsv"
printf 'iter\tstatus\tdns_ms\ttcp_ms\ttls_ms\tttfb_ms\tfetch_s\tstalled\tmax_gap_s\n' >"$FETCH_TSV"
printf 'iter\ttarget\thttp_code\tbytes\tseconds\tMbit/s\tdns_ms\ttcp_ms\ttls_ms\tttfb_ms\n' >"$BW_TSV"

CURL_TIMING='%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code} %{size_download} %{speed_download}\n'

for i in $(seq 1 "$ITER"); do
  TAG=$(printf '%02d' "$i")
  LOG="$OUT/run-$TAG.log"
  PCAP="$OUT/run-$TAG.tcpdump"
  : >"$LOG"

  HEADER="=== iter $i / $ITER — $(date -u +%H:%M:%SZ) host=$HOST_SHORT ==="
  echo "$HEADER"
  echo "$HEADER" >>"$LOG"

  # ---- 1. latency probe to github.com (kept for the fetch row) ----
  echo "--- latency: https://github.com/" >>"$LOG"
  GH_TIMINGS=$(curl -sS -o /dev/null -w "$CURL_TIMING" --max-time 30 "https://github.com/" 2>>"$LOG" \
               || echo "ERR ERR ERR ERR ERR 000 0 0")
  read -r T_DNS T_CONN T_TLS T_TTFB T_TOTAL _CODE _BYTES _SPEED <<<"$GH_TIMINGS"
  echo "  dns connect appconnect ttfb total code bytes speed: $GH_TIMINGS" >>"$LOG"

  # ---- 2. bandwidth probes ----
  for entry in "${BW_TARGETS[@]}"; do
    LABEL="${entry%%|*}"
    URL="${entry#*|}"
    echo "--- bw: $LABEL  $URL" >>"$LOG"
    BWT=$(curl -sS -o /dev/null -w "$CURL_TIMING" --max-time "$BW_TIMEOUT" "$URL" 2>>"$LOG" \
          || echo "ERR ERR ERR ERR ERR 000 0 0")
    read -r BW_DNS BW_CONN BW_TLS BW_TTFB BW_TOT BW_CODE BW_BYTES BW_SPEED <<<"$BWT"
    echo "  $LABEL: code=$BW_CODE bytes=$BW_BYTES speed=$BW_SPEED B/s ($(to_mbps "${BW_SPEED:-0}") Mbit/s) total=${BW_TOT}s" >>"$LOG"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$i" "$LABEL" "$BW_CODE" "$BW_BYTES" "$BW_TOT" \
      "$(to_mbps "${BW_SPEED:-0}")" \
      "$(to_ms "${BW_DNS:-0}")" "$(to_ms "${BW_CONN:-0}")" \
      "$(to_ms "${BW_TLS:-0}")" "$(to_ms "${BW_TTFB:-0}")" \
      >>"$BW_TSV"
  done

  # ---- 3. optional packet capture during the fetch ----
  TCPDUMP_PID=""
  if have tcpdump && sudo_ok; then
    nohup sudo tcpdump -i any -s 96 -w "$PCAP" -U \
      "(host github.com or host codeload.github.com) and tcp port 443" \
      </dev/null >/dev/null 2>>"$LOG" &
    TCPDUMP_PID=$!
    disown "$TCPDUMP_PID" 2>/dev/null || true
    sleep 0.3
  fi

  # ---- 4. the actual git fetch (depth=1) ----
  WORKDIR=$(mktemp -d)
  FETCH_START=$(date +%s)
  (
    cd "$WORKDIR"
    git init -q
    git remote add origin "$REPO"
    git config --local gc.auto 0
    git config --local maintenance.auto false
    [ -n "${GH_TOKEN:-}" ] && git config http.extraHeader "Authorization: Bearer $GH_TOKEN"

    GIT_TRACE=1 GIT_CURL_VERBOSE=1 GIT_PROGRESS_DELAY=0 \
      timeout --foreground "$FETCH_TIMEOUT" \
        git -c protocol.version=2 -c gc.auto=0 -c maintenance.auto=false \
            fetch --no-tags --prune --no-recurse-submodules \
                  --progress --depth=1 origin HEAD 2>&1
    echo "__FETCH_EXIT=$?"
  ) </dev/null 2>&1 | ts_filter >>"$LOG"
  FETCH_END=$(date +%s)
  FETCH_S=$((FETCH_END - FETCH_START))

  if [ -n "$TCPDUMP_PID" ]; then
    sudo kill -INT "$TCPDUMP_PID" 2>/dev/null || true
    sudo pkill -INT -f "tcpdump -i any -s 96 -w $PCAP" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"

  FETCH_RC=$(grep -oE '__FETCH_EXIT=[0-9]+' "$LOG" | tail -1 | cut -d= -f2)
  FETCH_RC=${FETCH_RC:-1}
  MAX_GAP=$(awk '
    match($0, /\[([0-9]+):([0-9]+):([0-9]+)\]/, m) {
      t = m[1]*3600 + m[2]*60 + m[3]
      if (prev != "") { gap = t - prev; if (gap < 0) gap += 86400; if (gap > max) max = gap }
      prev = t
    } END { print max+0 }
  ' "$LOG")
  case "$FETCH_RC" in
    0)   STATUS=ok ;;
    124) STATUS=timeout ;;
    *)   STATUS="fail($FETCH_RC)" ;;
  esac
  STALLED=no
  [ "${MAX_GAP:-0}" -ge "$STALL_THRESHOLD" ] && STALLED=yes
  [ "$STATUS" = "timeout" ] && STALLED=yes

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$STATUS" \
    "$(to_ms "${T_DNS:-0}")" "$(to_ms "${T_CONN:-0}")" "$(to_ms "${T_TLS:-0}")" \
    "$(to_ms "${T_TTFB:-0}")" \
    "$FETCH_S" "$STALLED" "${MAX_GAP:-0}" \
    >>"$FETCH_TSV"

  echo "  -> fetch:  status=$STATUS  ${FETCH_S}s  stalled=$STALLED  max_gap=${MAX_GAP}s"
  awk -F'\t' -v iter="$i" '$1==iter { printf "  -> bw:     %-18s %6s Mbit/s  (code=%s  bytes=%s  in %ss)\n", $2, $6, $3, $4, $5 }' "$BW_TSV"
done

###############################################################################
# Final summary — markdown
###############################################################################
SUMMARY="$OUT/summary.md"
{
  echo "# net-debug summary — \`$HOST_SHORT\`  @  $TS"
  echo
  echo "- Repo: \`$REPO\`"
  echo "- Iterations: $ITER"
  echo "- Fetch timeout: ${FETCH_TIMEOUT}s | bandwidth timeout: ${BW_TIMEOUT}s | stall threshold: ${STALL_THRESHOLD}s"
  echo
  echo "## Fetch results"
  echo
  tsv_to_md "$FETCH_TSV"
  echo
  echo "## Bandwidth results (per iteration)"
  echo
  tsv_to_md "$BW_TSV"
  echo
  echo "## Bandwidth aggregate (median Mbit/s per target)"
  echo
  awk -F'\t' '
    NR==1 { next }
    { vals[$2] = vals[$2] $6 " "; count[$2]++ }
    END {
      print "| target | n | min Mbit/s | median Mbit/s | max Mbit/s |"
      print "|--------|---|------------|---------------|------------|"
      for (t in vals) {
        n = split(vals[t], a, " ")
        # remove trailing empty from split
        m = 0; for (k=1; k<=n; k++) if (a[k] != "") { sorted[++m] = a[k]+0 }
        # simple insertion sort
        for (j=2; j<=m; j++) { v=sorted[j]; k=j-1; while (k>=1 && sorted[k]>v) { sorted[k+1]=sorted[k]; k-- } sorted[k+1]=v }
        if (m == 0) continue
        mid = (m%2==1) ? sorted[(m+1)/2] : (sorted[m/2]+sorted[m/2+1])/2
        printf "| %s | %d | %.2f | %.2f | %.2f |\n", t, m, sorted[1], mid, sorted[m]
        delete sorted
      }
    }
  ' "$BW_TSV"
  echo
  echo "_Logs: \`$OUT\`_"
} >"$SUMMARY"

echo
cat "$SUMMARY"
echo
echo "Saved markdown summary to: $SUMMARY"
