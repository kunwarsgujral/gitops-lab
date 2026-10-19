#!/usr/bin/env bash
# Sends a request to the site every 0.1s from your machine and counts failures.
# Run it during a rollout, drain or descheduler run to prove (or disprove) "zero dropped requests".
#   scripts/watch-errors.sh            uses http://localhost:30080/
#   scripts/watch-errors.sh <url>
set -uo pipefail
URL="${1:-http://localhost:30080/}"
ok=0; fail=0
trap 'echo; echo "total: ok=$ok failed=$fail"; exit 0' INT
echo "Hitting $URL (Ctrl-C to stop and see totals)"
while true; do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$URL" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "$(date +%T) HTTP $code"
  fi
  printf '\rok=%d failed=%d ' "$ok" "$fail"
  sleep 0.1
done
