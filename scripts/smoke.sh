#!/usr/bin/env bash
# Proves the backend and both gateways behave identically. Correctness only.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA="$DIR/tls/ca-cert.pem"

BACKEND_A="${BACKEND_A:-http://localhost:8081}"
BACKEND_A_TLS="${BACKEND_A_TLS:-https://localhost:8444}"
EDGY="${EDGY:-http://localhost:8083}"
SCG="${SCG:-http://localhost:8084}"

SEEDED_ID=1
UNKNOWN_ID=999999999

failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %-58s %s\n' "$label" "$actual"
  else
    printf '  FAIL %-58s expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# No `|| echo 000`: curl already prints 000 on a connection failure, and the
# fallback made every such failure read as "000000".
status() { curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
body() { curl -sS "$@" 2>/dev/null; }

row_count() {
  docker compose -f "$DIR/compose.yaml" exec -T postgres \
    psql -U bench -d bench -tAc 'SELECT count(*) FROM item' 2>/dev/null | tr -d '[:space:]'
}

echo "backend (direct)"
check "GET /items/$SEEDED_ID" 200 "$(status "$BACKEND_A/items/$SEEDED_ID")"
check "GET /items/$UNKNOWN_ID" 404 "$(status "$BACKEND_A/items/$UNKNOWN_ID")"
check "POST /items/lookup" 200 \
  "$(status -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$BACKEND_A/items/lookup")"
check "POST /items/lookup unknown id" 404 \
  "$(status -X POST -H 'Content-Type: application/json' -d "{\"id\":$UNKNOWN_ID}" "$BACKEND_A/items/lookup")"
check "POST /items/lookup no id" 400 \
  "$(status -X POST -H 'Content-Type: application/json' -d '{}' "$BACKEND_A/items/lookup")"
check "GET over TLS" 200 "$(status --cacert "$CA" "$BACKEND_A_TLS/items/$SEEDED_ID")"

before="$(row_count)"
status -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$BACKEND_A/items/lookup" >/dev/null
check "lookup wrote no rows" "$before" "$(row_count)"

strip_timestamp() { python3 -c '
import json, sys
d = json.load(sys.stdin)
d.pop("gateway-timestamp", None)
print(json.dumps(d, sort_keys=True))
' 2>/dev/null; }

gateway_checks() {
  local name="$1" base="$2"
  local EXPECT_BAD_BODY="${EXPECT_BAD_BODY:?set per gateway}"
  echo
  echo "$name"
  check "GET /api/items/$SEEDED_ID" 200 "$(status "$base/api/items/$SEEDED_ID")"
  check "GET /api/items/$SEEDED_ID matches direct" \
    "$(body "$BACKEND_A/items/$SEEDED_ID" | strip_timestamp)" \
    "$(body "$base/api/items/$SEEDED_ID" | strip_timestamp)"
  # A 404 body is not a JSON object; the response transformer must pass it through.
  check "GET /api/items/$UNKNOWN_ID" 404 "$(status "$base/api/items/$UNKNOWN_ID")"
  check "POST /api/lookup" 200 \
    "$(status -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$base/api/lookup")"

  local transformed
  transformed="$(body -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$base/api/lookup")"
  check "POST /api/lookup carries gateway-timestamp" yes \
    "$(grep -q 'gateway-timestamp' <<<"$transformed" && echo yes || echo no)"
  # Proves the POST reached the lookup origin and not the pass-through GET route.
  check "POST /api/lookup reached the lookup origin" "$SEEDED_ID" \
    "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id"))' <<<"$transformed" 2>/dev/null)"
  check "POST /api/lookup unknown id" 404 \
    "$(status -X POST -H 'Content-Type: application/json' -d "{\"id\":$UNKNOWN_ID}" "$base/api/lookup")"
  check "POST /api/lookup no id" 400 \
    "$(status -X POST -H 'Content-Type: application/json' -d '{}' "$base/api/lookup")"
  check "GET /api/lb/items/$SEEDED_ID (TLS, discovered)" 200 \
    "$(status "$base/api/lb/items/$SEEDED_ID")"
  # Round-robin over two instances: every call must land on a reachable one.
  # The responses are identical by design, so this proves reachability of the
  # rotation rather than its distribution.
  local codes=""
  for _ in $(seq 10); do codes="$codes$(status "$base/api/lb/items/$SEEDED_ID") "; done
  check "10 discovered calls all 200" "$(printf '200 %.0s' $(seq 10))" "$codes"

  # Downstream protocol is pinned to HTTP/1.1 on both gateways; h2c on one side
  # only would measure two different protocols as if they were one.
  check "rejects HTTP/2 prior knowledge" 000 \
    "$(status --http2-prior-knowledge "$base/api/items/$SEEDED_ID")"

  # Declared difference, not a bug: on route B's error paths the two gateways
  # agree on status but not on body. Edgy's JSON modifier treats an empty error
  # body as {} and so emits a timestamp object; SCG passes the blank through.
  # Pinned here so a future change to either is noticed.
  check "undecodable request body (declared difference)" "$EXPECT_BAD_BODY" \
    "$(status -X POST -H 'Content-Type: application/json' -d 'not-json' "$base/api/lookup")"
}

EXPECT_BAD_BODY=502 gateway_checks "edgy-gateway" "$EDGY"
EXPECT_BAD_BODY=400 gateway_checks "scg-gateway" "$SCG"

echo
echo "parity"
for path in "/api/items/$SEEDED_ID" "/api/lb/items/$SEEDED_ID"; do
  check "edgy and scg agree on $path" \
    "$(body "$EDGY$path" | strip_timestamp)" "$(body "$SCG$path" | strip_timestamp)"
done
check "edgy and scg agree on /api/lookup (timestamp stripped)" \
  "$(body -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$EDGY/api/lookup" | strip_timestamp)" \
  "$(body -X POST -H 'Content-Type: application/json' -d "{\"id\":$SEEDED_ID}" "$SCG/api/lookup" | strip_timestamp)"

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
