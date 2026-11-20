#!/usr/bin/env bash
set -euo pipefail

# Put the cluster into a known state for one benchmark cell, and refuse if it
# cannot.
#
# Usage: ./scripts/reset-cell.sh <throughput|latency> <scenario-arm> [--accept-postgres-restart]
# Example: ./scripts/reset-cell.sh throughput a-direct
#
# Run this between every repetition. PLAN-CH7.md §5.7 requires a fresh gateway
# pod per repetition so the reported spread includes deployment-to-deployment
# variance, and Hyperfoil needs restarting too: reused across back-to-back
# 10-minute runs it hits its own GC/jitter watchdog and the run dies partway.

NS="skacelik-ns"
BASELINE="benchmarks/results/.postgres-baseline"
MODE="${1:?Usage: $0 <throughput|latency> <scenario-arm> [--accept-postgres-restart]}"
ARM="${2:?Usage: $0 <throughput|latency> <scenario-arm> [--accept-postgres-restart]}"
ACCEPT_PG_RESTART="${3:-}"

die() { echo "REFUSING: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok   %s\n' "$*"; }

case "${MODE}" in
  throughput|latency) ;;
  *) die "unknown mode '${MODE}'. Expected 'throughput' or 'latency'." ;;
esac

# ---------------------------------------------------------------------------
# Which deployments this arm needs up, and which must be down.
# ---------------------------------------------------------------------------

ALL_GATEWAYS="edgy-gateway scg-gateway edgy-gateway-native"

case "${ARM}" in
  *-direct)       GATEWAY="" ;;
  *-edgy)         GATEWAY="edgy-gateway" ;;
  *-edgy-native)  GATEWAY="edgy-gateway-native" ;;
  *-scg)          GATEWAY="scg-gateway" ;;
  *) die "unknown arm '${ARM}'. Expected <scenario>-direct|edgy|edgy-native|scg." ;;
esac

# Scenario C is the only one that needs discovery. For A and B, Consul's core is
# the slack that keeps the namespace inside its 20-CPU quota with the generator
# at 6 — RUN-PLAN.md §4.
case "${ARM}" in
  c-*) CONSUL_REPLICAS=1 ;;
  *)   CONSUL_REPLICAS=0 ;;
esac

BENCH_FILE="benchmarks/${MODE}/${ARM}.hf.yaml"
[ -f "${BENCH_FILE}" ] || die "no benchmark file ${BENCH_FILE}"

echo "Arm ${ARM} [${MODE}] -> gateway '${GATEWAY:-none (direct)}', consul replicas ${CONSUL_REPLICAS}"

# ---------------------------------------------------------------------------
# 1. Postgres must not have restarted.
# ---------------------------------------------------------------------------
step "Postgres continuity"
PG_START="$(kubectl get pod -n "${NS}" -l app=postgres \
  -o jsonpath='{.items[0].status.startTime}' 2>/dev/null || true)"
[ -n "${PG_START}" ] || die "no Postgres pod found"

mkdir -p "$(dirname "${BASELINE}")"
if [ ! -f "${BASELINE}" ]; then
  echo "${PG_START}" > "${BASELINE}"
  ok "baseline recorded: ${PG_START}"
  echo "   (first run — every later cell is checked against this)"
elif [ "$(cat "${BASELINE}")" != "${PG_START}" ]; then
  if [ "${ACCEPT_PG_RESTART}" = "--accept-postgres-restart" ]; then
    echo "${PG_START}" > "${BASELINE}"
    echo "   ACCEPTED a Postgres restart: $(cat "${BASELINE}") -> ${PG_START}"
    echo "   Every cell measured before now is void. Re-run them, and warm the"
    echo "   buffer cache with a throwaway run before the next reported cell."
  else
    echo "   baseline: $(cat "${BASELINE}")" >&2
    echo "   now:      ${PG_START}" >&2
    die "Postgres restarted. Every cell measured before this point is void
    (RUN-PLAN.md §1, STATUS.md §4). If this was deliberate, re-run with
    --accept-postgres-restart, warm the cache with a throwaway run, and
    re-measure everything already captured."
  fi
else
  ok "unchanged since ${PG_START}"
fi

# ---------------------------------------------------------------------------
# 2. Consul to the replica count this scenario wants.
# ---------------------------------------------------------------------------
step "Consul replicas"
CURRENT_CONSUL="$(kubectl get deploy consul -n "${NS}" -o jsonpath='{.spec.replicas}')"
if [ "${CURRENT_CONSUL}" != "${CONSUL_REPLICAS}" ]; then
  kubectl scale deploy/consul --replicas="${CONSUL_REPLICAS}" -n "${NS}" >/dev/null
  echo "   scaled consul ${CURRENT_CONSUL} -> ${CONSUL_REPLICAS}"
  [ "${CONSUL_REPLICAS}" = "1" ] && kubectl rollout status deploy/consul -n "${NS}" --timeout=3m
else
  ok "already at ${CONSUL_REPLICAS}"
fi

# ---------------------------------------------------------------------------
# 3. One gateway up, fresh, and the others at zero.
# ---------------------------------------------------------------------------
step "Gateways"
for g in ${ALL_GATEWAYS}; do
  if [ "${g}" != "${GATEWAY}" ]; then
    if [ "$(kubectl get deploy "${g}" -n "${NS}" -o jsonpath='{.spec.replicas}')" != "0" ]; then
      kubectl scale deploy/"${g}" --replicas=0 -n "${NS}" >/dev/null
      echo "   scaled ${g} down"
    fi
  fi
done

for g in ${ALL_GATEWAYS}; do
  [ "${g}" = "${GATEWAY}" ] && continue
  kubectl wait --for=delete pod -l app="${g}" -n "${NS}" --timeout=2m 2>/dev/null || true
done

if [ -n "${GATEWAY}" ]; then
  kubectl scale deploy/"${GATEWAY}" --replicas=0 -n "${NS}" >/dev/null
  kubectl wait --for=delete pod -l app="${GATEWAY}" -n "${NS}" --timeout=2m 2>/dev/null || true
  kubectl scale deploy/"${GATEWAY}" --replicas=1 -n "${NS}" >/dev/null
  kubectl rollout status deploy/"${GATEWAY}" -n "${NS}" --timeout=5m
  ok "${GATEWAY} is a fresh pod (§5.7)"
else
  ok "direct arm, no gateway in the path"
fi

# ---------------------------------------------------------------------------
# 4. Backends: never `rollout restart`.
# ---------------------------------------------------------------------------
step "Backends"
for b in backend-a backend-b; do
  PHASE="$(kubectl get pod -n "${NS}" -l app="${b}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo missing)"
  READY="$(kubectl get pod -n "${NS}" -l app="${b}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
  [ "${PHASE}" = "Running" ] && [ "${READY}" = "true" ] \
    || die "${b} is ${PHASE}/ready=${READY}.
    Do NOT 'kubectl rollout restart' it — Guaranteed QoS on a pinned node makes
    that hang forever. Delete the pod instead:
        kubectl delete pod -n ${NS} -l app=${b}"
  ok "${b} Running and Ready"
done

# ---------------------------------------------------------------------------
# 5. Restart the generator.
# ---------------------------------------------------------------------------
step "Hyperfoil"
kubectl rollout restart deploy/hyperfoil -n "${NS}" >/dev/null
kubectl rollout status deploy/hyperfoil -n "${NS}" --timeout=5m
ok "generator restarted — no watchdog state carried over from the last run"

# ---------------------------------------------------------------------------
# 6. Everything landed where the manifests say it should.
# ---------------------------------------------------------------------------
step "Pod placement against the pinned topology (§2.5)"
PLACEMENT_BAD=0
while read -r dep; do
  [ -n "${dep}" ] || continue
  REPLICAS="$(kubectl get deploy "${dep}" -n "${NS}" -o jsonpath='{.spec.replicas}')"
  [ "${REPLICAS}" = "0" ] && continue
  WANT="$(kubectl get deploy "${dep}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}')"
  GOT="$(kubectl get pods -n "${NS}" -l app="${dep}" \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
  if [ -z "${WANT}" ]; then
    echo "   WARN ${dep} has no nodeSelector — placement is uncontrolled"
    PLACEMENT_BAD=1
  elif [ "${WANT}" != "${GOT}" ]; then
    echo "   BAD  ${dep} wants ${WANT}, is on ${GOT:-<unscheduled>}" >&2
    PLACEMENT_BAD=1
  else
    ok "${dep} on ${GOT}"
  fi
done < <(kubectl get deploy -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

[ "${PLACEMENT_BAD}" = "0" ] || die "the topology is not the one every other cell
    was measured under. Either the node is full or drained, or a selector moved.
    RUN-PLAN.md §2.5: change all six selectors together and re-run the
    campaign; do not move one pod."

# ---------------------------------------------------------------------------
# 7. Exactly one gateway, and nothing unhealthy anywhere.
# ---------------------------------------------------------------------------
step "Final state"
UP="$(kubectl get pods -n "${NS}" -l role=gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')"
EXPECT=$([ -n "${GATEWAY}" ] && echo 1 || echo 0)
[ "${UP}" = "${EXPECT}" ] || die "${UP} gateway pods are up, expected ${EXPECT}.
    Two gateways running at once means the quota is wrong and the unused one is
    taking CPU on the node under test."
ok "${UP} gateway pod(s), as expected for ${ARM}"

if kubectl get pods -n "${NS}" --no-headers | grep -vE '(Running|Completed)' | grep -q .; then
  kubectl get pods -n "${NS}" --no-headers | grep -vE '(Running|Completed)' >&2
  die "not every pod is Running"
fi
ok "every pod Running"

if ! git diff --quiet 2>/dev/null; then
  echo "   WARN working tree is dirty — capture-cell.sh will stamp the cell"
  echo "        DIRTY WORKING TREE and its provenance will not be reconstructible."
fi

HOST="$(grep -m1 -E '^\s*host:' "${BENCH_FILE}" | sed 's/.*host:[[:space:]]*//')"
RATE="$(awk '/^- steady:/{f=1} f&&/usersPerSec:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "${BENCH_FILE}")"
DURATION="$(awk '/^- steady:/{f=1} f&&/duration:/{print $2; exit}' "${BENCH_FILE}")"

cat << NEXT

------------------------------------------------------------------------
Ready for ${ARM} [${MODE}].  ${BENCH_FILE}: host ${HOST}, steady ${RATE}/s for ${DURATION}

The port-forward died with the old Hyperfoil pod. Re-open it in another
terminal before connecting the CLI:

    kubectl port-forward -n ${NS} svc/hyperfoil 8090:8090

Then:

    docker run --rm -it --network host -v "\$PWD/benchmarks:/b" \\
      quay.io/hyperfoil/hyperfoil:latest cli
    connect localhost:8090
    upload /b/${MODE}/${ARM}.hf.yaml
    run ${ARM}

At the START of the steady phase, in a third terminal (optional for throughput):

    ./scripts/capture-cell.sh ${MODE} ${ARM} ${RATE} <rep>
------------------------------------------------------------------------
NEXT