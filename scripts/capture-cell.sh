#!/usr/bin/env bash
set -euo pipefail

# Capture the evidence that makes one benchmark cell reportable.
#
# Usage: ./scripts/capture-cell.sh <mode> <scenario-arm> <rate> <rep> [samples]
#   mode: throughput | latency
# Examples:
#   ./scripts/capture-cell.sh throughput a-scg 9500 1      (defaults to 12 samples / 3 min)
#   ./scripts/capture-cell.sh latency    a-scg 8100 1      (defaults to 40 samples / 10 min)
#
# Start this at the beginning of the STEADY phase, not at the start of the run.
#
# Values that describe the run are READ FROM benchmarks/<mode>/<arm>.hf.yaml
# rather than hardcoded here.

MODE="${1:?Usage: $0 <throughput|latency> <scenario-arm> <rate> <rep> [samples]}"
ARM="${2:?Usage: $0 <throughput|latency> <scenario-arm> <rate> <rep> [samples]}"
RATE="${3:?}"
REP="${4:?}"
NS="skacelik-ns"

case "${MODE}" in
  throughput) DEFAULT_SAMPLES=12 ;;
  latency)    DEFAULT_SAMPLES=40 ;;
  *)
    echo "Invalid mode '${MODE}': expected 'throughput' or 'latency'." >&2
    exit 1
    ;;
esac

SAMPLES="${5:-${DEFAULT_SAMPLES}}"
BENCH_FILE="benchmarks/${MODE}/${ARM}.hf.yaml"
[ -f "${BENCH_FILE}" ] || { echo "No such benchmark file: ${BENCH_FILE}" >&2; exit 1; }

field() { grep -m1 -E "^\s*$1:" "${BENCH_FILE}" | awk -F: '{gsub(/ /,"",$2); print $2}'; }
SHARED_CONNECTIONS="$(field sharedConnections)"
MAX_SESSIONS="$(field maxSessions)"
THREADS="$(field threads)"
HOST="$(grep -m1 -E '^\s*host:' "${BENCH_FILE}" | sed 's/.*host:[[:space:]]*//')"
STEADY_RATE="$(awk '/^- steady:/{f=1} f&&/usersPerSec:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "${BENCH_FILE}")"

# The rate in the filename and the rate in the benchmark file disagreeing is the
# single easiest way to mislabel a cell, so refuse rather than record a lie.
if [ -n "${STEADY_RATE}" ] && [ "${STEADY_RATE}" != "${RATE}" ]; then
  echo "REFUSING: ${BENCH_FILE} steady phase is ${STEADY_RATE}/s but you said ${RATE}." >&2
  echo "Fix the rate in all three phases of the benchmark file, or correct the argument." >&2
  exit 1
fi

OUT_DIR="benchmarks/results/${ARM}/${RATE}-r${REP}"
mkdir -p "${OUT_DIR}"

echo "Capturing [${MODE}] into ${OUT_DIR} (${SAMPLES} samples, $((SAMPLES * 15 / 60)) min)..."
kubectl get pods -n "${NS}" -o wide > "${OUT_DIR}/pods.txt"
cp "${BENCH_FILE}" "${OUT_DIR}/benchmark.hf.yaml"

cat << META > "${OUT_DIR}/meta.txt"
timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
mode: ${MODE}
arm: ${ARM}
rate: ${RATE}
rep: ${REP}
git_commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo " (DIRTY WORKING TREE)")
host: ${HOST}
threads: ${THREADS}
sharedConnections: ${SHARED_CONNECTIONS}
maxSessions: ${MAX_SESSIONS}
steady_samples: ${SAMPLES}
nodes: $(kubectl get pods -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}@{.spec.nodeName}{" "}{end}')
images: $(kubectl get pods -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.containers[0].image}{" "}{end}')
limits: $(kubectl get pods -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}(cpu={.spec.containers[0].resources.limits.cpu},mem={.spec.containers[0].resources.limits.memory}){" "}{end}')
postgres_pod_age: $(kubectl get pod -n "${NS}" -l app=postgres -o jsonpath='{.items[0].status.startTime}' 2>/dev/null || echo unknown)
verdict: PENDING
META

# A pod that is not Running or not Ready during the measured phase means the
# cell is void. Catching it here costs nothing; catching it afterwards costs the
# run.
if kubectl get pods -n "${NS}" --no-headers | grep -vE '(Running|Completed)' | grep -q .; then
  echo "WARNING: not every pod is Running:" >&2
  kubectl get pods -n "${NS}" --no-headers | grep -vE '(Running|Completed)' >&2
fi

rm -f "${OUT_DIR}/top.txt"
for i in $(seq 1 "${SAMPLES}"); do
  echo "=== Sample ${i}/${SAMPLES} ($(date +%H:%M:%S)) ===" | tee -a "${OUT_DIR}/top.txt"
  kubectl top pods -n "${NS}" | tee -a "${OUT_DIR}/top.txt"
  if [ "${i}" -lt "${SAMPLES}" ]; then
    sleep 15
  fi
done

cat << NEXT

Done. Now, in the Hyperfoil CLI:
    export <runid> -f json -d /b/results/${ARM}/${RATE}-r${REP}
    report <runid>          -d /b/results/${ARM}/${RATE}-r${REP}
then rename to run.json / run.html, and score the cell:
    python3 -I scripts/verdict.py ${ARM} ${RATE} ${REP}

Before the next repetition:
    ./scripts/reset-cell.sh ${ARM}
NEXT