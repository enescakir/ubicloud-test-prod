#!/usr/bin/env bash
set -uo pipefail

AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull"
REGISTRY_URL="https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest"
TOTAL=${1:-500}
CONCURRENCY=${2:-20}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Hammering Docker Hub registry ($TOTAL requests, $CONCURRENCY concurrent)"
echo "Starting at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "---"

run_request() {
  local i=$1
  local token http_code time_total remote_ip rate_source rate_remaining

  # Get auth token
  local auth_response auth_ip
  auth_response=$(curl -s -w "\n%{remote_ip}" --connect-timeout 5 --max-time 10 "$AUTH_URL" 2>&1) || true
  auth_ip=$(echo "$auth_response" | tail -1)
  token=$(echo "$auth_response" | sed '$d' | jq -r .token) || true

  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "[$i] AUTH_FAIL auth_ip=$auth_ip"
    touch "$TMPDIR/fail_$i"
    return
  fi

  # Hit registry with token to get rate limit headers
  local headers_file="$TMPDIR/headers_$i"
  local registry_output registry_ip http_code
  registry_output=$(curl -s -D "$headers_file" -o /dev/null -w "%{http_code} %{remote_ip}" \
    --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $token" \
    "$REGISTRY_URL" 2>&1) || true

  http_code=$(echo "$registry_output" | awk '{print $1}')
  registry_ip=$(echo "$registry_output" | awk '{print $2}')
  rate_source=$(grep -i "docker-ratelimit-source" "$headers_file" 2>/dev/null | awk '{print $2}' | tr -d '\r')
  rate_remaining=$(grep -i "ratelimit-remaining" "$headers_file" 2>/dev/null | awk '{print $2}' | tr -d '\r')

  if [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
    echo "[$i] OK status=$http_code auth_ip=$auth_ip registry_ip=$registry_ip source=$rate_source remaining=$rate_remaining"
    touch "$TMPDIR/ok_$i"
  elif [[ "$http_code" == "429" ]]; then
    echo "[$i] RATE_LIMITED auth_ip=$auth_ip registry_ip=$registry_ip source=$rate_source remaining=$rate_remaining"
    touch "$TMPDIR/ratelimit_$i"
  else
    echo "[$i] HTTP_ERROR status=$http_code auth_ip=$auth_ip registry_ip=$registry_ip source=$rate_source remaining=$rate_remaining"
    touch "$TMPDIR/fail_$i"
  fi
}

for ((i=1; i<=TOTAL; i+=CONCURRENCY)); do
  for ((j=0; j<CONCURRENCY && i+j<=TOTAL; j++)); do
    run_request "$((i+j))" &
  done
  wait
done

echo "---"
echo "Finished at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ok=$(ls "$TMPDIR"/ok_* 2>/dev/null | wc -l)
ratelimit=$(ls "$TMPDIR"/ratelimit_* 2>/dev/null | wc -l)
fail=$(ls "$TMPDIR"/fail_* 2>/dev/null | wc -l)
echo "=== RESULTS ==="
echo "  OK:           $ok"
echo "  Rate limited: $ratelimit"
echo "  Failed:       $fail"
echo "  Total:        $TOTAL"
