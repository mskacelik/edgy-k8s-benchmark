#!/usr/bin/env python3
"""Score benchmark cells against the PLAN-CH7.md pass criteria.

Usage:
    python3 -I scripts/verdict.py <arm> <rate> <rep>      score one cell
    python3 -I scripts/verdict.py --all                   score every cell
    python3 -I scripts/verdict.py --aggregate <rate> [arm ...]
                                                          median + spread, T3 shape

Options:
    --phase latency|throughput   override the phase inferred from steady duration
    --quiet                      verdict lines only, no per-pod detail

This exists because the criterion was being applied by eye, and three cells were
misread on 2026-11-18: a run whose steady phase never happened was read as a
pass, a run that failed at p99 662 ms was read as the ceiling, and a run against
a 404 path was read as a valid direct arm. The rules are mechanical, so a script
should apply them.


THE TWO PHASES HAVE DIFFERENT CRITERIA
--------------------------------------

This is the 2026-11-19 revision and it is the point of the file. The p99 bound
belongs to the throughput bisection (PLAN-CH7.md §5.1) and *not* to the latency
measurement (§5.4).

  - A **throughput** cell asks "is this rate sustainable?". p99 is a gate: the
    bound of 10 ms, declared in docs/RUN-PLAN.md §2.2 before any run, decides
    whether the rate passes. It does not move. Relaxing it after seeing results
    would make it not a criterion.

  - A **latency** cell runs at the nominal rate, where the rate is already known
    to be sustainable. Here p99 *is the result*. Gating on it would mean
    discarding the measurement for having the value it has. PLAN-CH7.md §7 lists
    the gates for this cell explicitly: error rate and achieved-versus-requested
    rate. p99 sits in the latency-table row, not in a gate row.

So SCG at p99 19.79 ms and native at p99 68.68 ms, both at the nominal rate, are
findings for T3. They are not failures. What they do show is that the 3-minute
bisection under-detects the tail — §5.4 says the 10-minute phase exists to catch
exactly the periodic events a shorter phase misses — and that belongs in §7.4.

The phase is inferred from the measured duration of the steady phase: 5 minutes
or more is a latency cell, less is a bisection step. `--phase` overrides it.


THE VERDICTS
------------

  FAIL    The cell is a valid measurement and it did not pass.
            - any failure recorded against the steady phase;
            - any failed request in steady: connection errors, internal errors,
              timeouts, or responses that failed validation (non-2xx);
            - responses not matching requests;
            - blockedTime above zero in steady — the generator could not keep to
              its schedule, so the open model degenerated and the number is a
              lower bound, not a measurement;
            - achieved rate more than 1 % off the requested rate;
            - throughput cells only: steady p99 above the 10 ms bound.

  INVALID The cell says nothing about the rate and is simply repeated. It does
          NOT push a ceiling down.
            - run.json missing, truncated or unparseable;
            - no steady phase in the report;
            - a warm-up phase (rampup or hold) failed.
          SCG failed `hold` at 9000 and passed cleanly at 9500. Read as a fail,
          that would have moved the ceiling 500 req/s on the strength of noise.

  PASS    Everything else.

Generator CPU warnings never decide a verdict. They are per-core spikes and say
nothing on their own: in the four 8100 cells the generator *pod* sat at 0.76-1.26
of its 6 cores while individual cores touched 100 %. The pod-level figures from
top.txt are printed alongside, and those are what §5.2 attribution and §7.7
co-location both actually rest on.
"""

import json
import os
import re
import statistics
import sys

# docs/RUN-PLAN.md §2.2. Declared before any run, applied to throughput
# bisection only. Do not change this to accommodate a result.
P99_BOUND_MS = 10.0

RATE_TOLERANCE = 0.01

# Was a flat 10, calibrated on 3-minute runs, which made a 10-minute run look
# 3.3x worse for behaving identically. Normalised per minute of steady phase.
CPU_WARNINGS_PER_MINUTE = 3.4

# At or above this many seconds of steady phase, the cell is a §5.4 latency
# measurement rather than a §5.1 bisection step.
LATENCY_PHASE_SECONDS = 300

RESULTS_ROOT = "benchmarks/results"

# Longest first: edgy-gateway-native must not match as edgy-gateway.
POD_GROUPS = [
    "edgy-gateway-native",
    "edgy-gateway",
    "scg-gateway",
    "backend-a",
    "backend-b",
    "hyperfoil",
    "postgres",
    "consul",
]

# Printed in the attribution block, in this order, when present.
ATTRIBUTION_ORDER = [
    "edgy-gateway", "edgy-gateway-native", "scg-gateway",
    "backend-a", "backend-b", "postgres", "hyperfoil",
]


def pod_group(name):
    for group in POD_GROUPS:
        if name.startswith(group):
            return group
    return name.rsplit("-", 2)[0]


def parse_cpu(text):
    """kubectl top CPU column -> millicores."""
    text = text.strip()
    if text.endswith("m"):
        return float(text[:-1])
    if text.endswith("n"):
        return float(text[:-1]) / 1e6
    return float(text) * 1000.0


def parse_mem(text):
    """kubectl top memory column -> MiB."""
    text = text.strip()
    for suffix, factor in (("Gi", 1024.0), ("Mi", 1.0), ("Ki", 1 / 1024.0)):
        if text.endswith(suffix):
            return float(text[: -len(suffix)]) * factor
    return float(re.sub(r"[^0-9.]", "", text) or 0)


def parse_top(cell_dir):
    """Pod-level CPU and RSS through the steady phase, from top.txt.

    This is the §5.2 attribution evidence and the §5.6 RSS figure. Reading it
    here rather than by eye is the whole reason the sampler writes the file.
    """
    path = os.path.join(cell_dir, "top.txt")
    if not os.path.exists(path):
        return {}, 0
    series = {}
    samples = 0
    with open(path) as fh:
        for line in fh:
            if line.startswith("==="):
                samples += 1
                continue
            parts = line.split()
            if len(parts) != 3 or parts[0] == "NAME":
                continue
            name, cpu, mem = parts
            try:
                cpu_m, mem_mi = parse_cpu(cpu), parse_mem(mem)
            except ValueError:
                continue
            series.setdefault(pod_group(name), {"cpu": [], "mem": []})
            series[pod_group(name)]["cpu"].append(cpu_m)
            series[pod_group(name)]["mem"].append(mem_mi)
    out = {}
    for group, vals in series.items():
        if not vals["cpu"]:
            continue
        out[group] = {
            "cpu_mean_m": statistics.mean(vals["cpu"]),
            "cpu_peak_m": max(vals["cpu"]),
            "rss_mean_mi": statistics.mean(vals["mem"]),
            "rss_min_mi": min(vals["mem"]),
            "rss_peak_mi": max(vals["mem"]),
            "samples": len(vals["cpu"]),
        }
    return out, samples


def parse_limits(cell_dir):
    """Container limits out of meta.txt, so CPU can be shown as % of limit."""
    path = os.path.join(cell_dir, "meta.txt")
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        text = fh.read()
    match = re.search(r"^limits:(.*)$", text, flags=re.M)
    if not match:
        return {}
    limits = {}
    for name, cpu, mem in re.findall(r"(\S+?)\(cpu=([^,]*),mem=([^)]*)\)", match.group(1)):
        try:
            limits[pod_group(name)] = (parse_cpu(cpu), parse_mem(mem))
        except ValueError:
            continue
    return limits


def read_run(cell_dir):
    path = os.path.join(cell_dir, "run.json")
    if not os.path.exists(path) or os.path.getsize(path) < 1000:
        return None, "run.json is missing or truncated — the run did not complete"
    try:
        with open(path) as fh:
            return json.load(fh), None
    except json.JSONDecodeError as exc:
        return None, "run.json does not parse: %s" % exc


def score(cell_dir, phase_override=None):
    """Return (verdict, notes, metrics) for one cell."""
    data, problem = read_run(cell_dir)
    if data is None:
        return "INVALID", [problem], {}

    notes = []
    phases = {s.get("phase"): s for s in data.get("stats", [])}

    cpu_warnings = [
        e["msg"] for e in data.get("info", {}).get("errors", [])
        if "CPU" in e.get("msg", "")
    ]
    peaks = [int(m) for msg in cpu_warnings for m in re.findall(r"for (\d+)%", msg)]
    metrics = {
        "generator_cpu_warnings": len(cpu_warnings),
        "generator_cpu_peak_pct": max(peaks) if peaks else None,
    }

    steady = phases.get("steady")
    if steady is None:
        return "INVALID", ["no steady phase in the report — the run died before it"], metrics

    summary = steady.get("total", steady).get("summary", {})
    percentiles = summary.get("percentileResponseTime", {})

    # Authoritative duration: the report's own clock, not the requested
    # duration in the benchmark file. A run that was cut short then scores
    # against what it actually did.
    start, end = summary.get("startTime"), summary.get("endTime")
    duration_s = (end - start) / 1000.0 if start and end and end > start else None

    cell_phase = phase_override or (
        "latency" if duration_s and duration_s >= LATENCY_PHASE_SECONDS else "throughput"
    )

    requests = summary.get("requestCount", 0)
    metrics.update({
        "phase": cell_phase,
        "duration_s": round(duration_s, 1) if duration_s else None,
        "requests": requests,
        "responses": summary.get("responseCount", 0),
        "p50_ms": round(percentiles.get("50.0", 0) / 1e6, 2),
        "p90_ms": round(percentiles.get("90.0", 0) / 1e6, 2),
        "p99_ms": round(percentiles.get("99.0", 0) / 1e6, 2),
        "p999_ms": round(percentiles.get("99.9", 0) / 1e6, 2),
        "p9999_ms": round(percentiles.get("99.99", 0) / 1e6, 2),
        "max_ms": round(summary.get("maxResponseTime", 0) / 1e6, 2),
    })

    failures = data.get("failures", [])
    steady_failures = [f for f in failures if f.get("phase") == "steady"]
    warmup_failures = [f for f in failures if f.get("phase") in ("rampup", "hold")]

    verdict = "PASS"

    for f in dict.fromkeys(f.get("message") for f in steady_failures):
        verdict = "FAIL"
        notes.append("steady failure: %s" % f)

    # PLAN-CH7.md §5.1, first condition: zero failed requests — connection
    # errors, resets, timeouts, non-2xx. Only `failures[]` was checked before,
    # which is a different thing: it holds SLA breaches, not per-request
    # errors. A cell answering 404 to everything scored PASS on this path,
    # which is how a-direct/24000-r1 got as far as it did.
    error_counters = {
        "connection errors": summary.get("connectionErrors", 0),
        "internal errors": summary.get("internalErrors", 0),
        "request timeouts": summary.get("requestTimeouts", 0),
        "invalid responses": summary.get("invalid", 0),
    }
    bad = {k: v for k, v in error_counters.items() if v}
    if bad:
        verdict = "FAIL"
        notes.append("steady failed requests: %s" % ", ".join(
            "%s %d" % (k, v) for k, v in sorted(bad.items())))

    if metrics["responses"] and metrics["responses"] != requests:
        verdict = "FAIL"
        notes.append("steady responses %d against requests %d — %d never answered"
                     % (metrics["responses"], requests, requests - metrics["responses"]))

    # Non-zero blockedTime means Hyperfoil could not issue on schedule, so the
    # open model degenerated towards a closed one and the percentiles
    # understate the truth. That is coordinated omission, which §5.4 makes the
    # one methodological point the chapter rests on, so it cannot be a note.
    blocked = summary.get("blockedTime", 0)
    if blocked:
        verdict = "FAIL"
        notes.append("steady blockedTime %s ns — the generator could not keep to "
                     "schedule, so this is a lower bound and not a measurement" % blocked)

    if cell_phase == "throughput" and metrics["p99_ms"] > P99_BOUND_MS:
        verdict = "FAIL"
        notes.append("steady p99 %.2f ms exceeds the %.0f ms bound"
                     % (metrics["p99_ms"], P99_BOUND_MS))
    elif cell_phase == "latency" and metrics["p99_ms"] > P99_BOUND_MS:
        notes.append("steady p99 %.2f ms is above the %.0f ms throughput bound — "
                     "reported, not gated: at the nominal rate this is the result "
                     "(§5.4), not a pass criterion"
                     % (metrics["p99_ms"], P99_BOUND_MS))

    if verdict == "PASS" and warmup_failures:
        verdict = "INVALID"
        for f in dict.fromkeys(f.get("message") for f in warmup_failures):
            notes.append("warm-up failure, repeat the run: %s" % f)
    elif warmup_failures:
        notes.append("%d warm-up failure(s) as well" % len(warmup_failures))

    budget = max(1, int(CPU_WARNINGS_PER_MINUTE * (duration_s or 180) / 60.0))
    if len(cpu_warnings) > budget:
        notes.append(
            "%d generator CPU warnings (peak %s%%) against a budget of %d for a "
            "%.0f-minute phase — these are single cores; check the generator's "
            "pod-level CPU below before believing it"
            % (len(cpu_warnings), metrics["generator_cpu_peak_pct"], budget,
               (duration_s or 180) / 60.0))
    elif cpu_warnings:
        notes.append("%d generator CPU warnings (peak %s%%), within the budget of %d"
                     % (len(cpu_warnings), metrics["generator_cpu_peak_pct"], budget))

    return verdict, notes, metrics


def check_rate(cell_dir, verdict, metrics):
    """Requested rate from the directory name, achieved from the report."""
    match = re.search(r"/(\d+)-r\d+/?$", cell_dir.rstrip("/") + "/")
    if not match or not metrics.get("duration_s"):
        return verdict, None
    requested = int(match.group(1))
    achieved = metrics["requests"] / metrics["duration_s"]
    drift = abs(achieved - requested) / requested
    metrics["achieved_rate"] = round(achieved, 1)
    if drift > RATE_TOLERANCE and verdict == "PASS":
        verdict = "FAIL"
    return verdict, "achieved %.0f/s against %d/s requested (%.2f %% off)" % (
        achieved, requested, drift * 100)


def attribution_lines(cell_dir):
    """§5.2 evidence: was the gateway the limiting component, or something else."""
    top, samples = parse_top(cell_dir)
    if not top:
        return ["no top.txt — this cell carries no attribution evidence (§5.2)"]
    limits = parse_limits(cell_dir)
    lines = []
    for group in ATTRIBUTION_ORDER:
        if group not in top:
            continue
        stat = top[group]
        cpu_limit = limits.get(group, (None, None))[0]
        pct = (" = %3.0f %% of limit" % (100.0 * stat["cpu_mean_m"] / cpu_limit)
               if cpu_limit else "")
        lines.append(
            "%-20s CPU mean %6.0fm peak %6.0fm%s   RSS %4.0f-%4.0f MiB (mean %4.0f)"
            % (group, stat["cpu_mean_m"], stat["cpu_peak_m"], pct,
               stat["rss_min_mi"], stat["rss_peak_mi"], stat["rss_mean_mi"]))
    lines.append("%d samples over %.0f min" % (samples, samples * 15 / 60.0))
    return lines


def write_verdict(cell_dir, verdict):
    path = os.path.join(cell_dir, "meta.txt")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        text = fh.read()
    if re.search(r"^verdict:", text, flags=re.M):
        text = re.sub(r"^verdict:.*$", "verdict: " + verdict, text, flags=re.M)
    else:
        text = text.rstrip("\n") + "\nverdict: " + verdict + "\n"
    with open(path, "w") as fh:
        fh.write(text)


def report_cell(cell_dir, phase_override=None, quiet=False):
    verdict, notes, metrics = score(cell_dir, phase_override)
    verdict, rate_note = check_rate(cell_dir, verdict, metrics)
    if rate_note:
        notes.append(rate_note)

    detail = ""
    if "p99_ms" in metrics:
        detail = ("p50 %-7s p90 %-7s p99 %-8s p99.9 %-8s max %-8s req %-9s [%s]"
                  % (metrics["p50_ms"], metrics["p90_ms"], metrics["p99_ms"],
                     metrics["p999_ms"], metrics["max_ms"], metrics["requests"],
                     metrics.get("phase", "?")))
    print("%-7s  %-34s %s" % (verdict, cell_dir.replace(RESULTS_ROOT + "/", ""), detail))
    for note in notes:
        print("         - %s" % note)
    if not quiet and "p99_ms" in metrics:
        for line in attribution_lines(cell_dir):
            print("           %s" % line)
    write_verdict(cell_dir, verdict)
    return verdict, metrics


def all_cells():
    if not os.path.isdir(RESULTS_ROOT):
        return []
    # Only `<arm>/<rate>-r<rep>/` is a cell. Anything else under results/ is
    # notes or the superseded pre-pinning archive, and scoring it produces
    # INVALID lines that look like lost runs.
    return sorted(
        os.path.join(RESULTS_ROOT, arm, cell)
        for arm in os.listdir(RESULTS_ROOT)
        if os.path.isdir(os.path.join(RESULTS_ROOT, arm)) and not arm.startswith(".")
        for cell in os.listdir(os.path.join(RESULTS_ROOT, arm))
        if os.path.isdir(os.path.join(RESULTS_ROOT, arm, cell))
        and re.fullmatch(r"\d+-r\d+", cell)
    )


def spread(values):
    """Median and range. PLAN-CH7.md §5.7: report the median, state the spread."""
    if not values:
        return None, None, None
    return statistics.median(values), min(values), max(values)


def aggregate(rate, arms=None):
    """Median and spread across repetitions — the shape T3 is drawn from.

    §5.7 and §12: three runs at the converged rate, each a fresh pod, report the
    median and state the spread. A single run is not evidence, so this refuses
    to produce a median from one repetition without saying so.
    """
    if arms is None:
        arms = sorted(a for a in os.listdir(RESULTS_ROOT)
                      if os.path.isdir(os.path.join(RESULTS_ROOT, a)))

    print("\nNominal rate %s req/s — median across repetitions, spread in brackets" % rate)
    print("PLAN-CH7.md §5.7: three reps per arm, fresh pod each. No means.\n")
    header = ("%-18s %-4s %-16s %-16s %-16s %-16s %-16s %s"
              % ("arm", "n", "p50 ms", "p90 ms", "p99 ms", "p99.9 ms", "max ms", "RSS MiB"))
    print(header)
    print("-" * len(header))

    for arm in arms:
        arm_dir = os.path.join(RESULTS_ROOT, arm)
        if not os.path.isdir(arm_dir):
            continue
        reps = sorted(d for d in os.listdir(arm_dir)
                      if re.fullmatch(r"%s-r\d+" % rate, d))
        usable, skipped = [], []
        for rep in reps:
            cell = os.path.join(arm_dir, rep)
            verdict, _, metrics = score(cell)
            verdict, _ = check_rate(cell, verdict, metrics)
            if verdict == "PASS" and "p50_ms" in metrics:
                top, _ = parse_top(cell)
                gateway = next((top[g] for g in ATTRIBUTION_ORDER
                                if g in top and "gateway" in g), None)
                metrics["rss_mean_mi"] = gateway["rss_mean_mi"] if gateway else None
                usable.append(metrics)
            else:
                skipped.append((rep, verdict))
        if not usable:
            if reps:
                print("%-18s %-4s %s" % (arm, 0, "no passing repetition — " + ", ".join(
                    "%s %s" % (r, v) for r, v in skipped)))
            continue

        def col(key, fmt="%.2f"):
            vals = [m[key] for m in usable if m.get(key) is not None]
            med, lo, hi = spread(vals)
            if med is None:
                return "-"
            if len(vals) == 1:
                return (fmt + " (n=1)") % med
            return (fmt + " [" + fmt + "-" + fmt + "]") % (med, lo, hi)

        print("%-18s %-4d %-16s %-16s %-16s %-16s %-16s %s" % (
            arm, len(usable), col("p50_ms"), col("p90_ms"), col("p99_ms"),
            col("p999_ms"), col("max_ms"), col("rss_mean_mi", "%.0f")))
        if skipped:
            print("%-18s      not counted: %s" % (
                "", ", ".join("%s %s" % (r, v) for r, v in skipped)))
        if len(usable) < 3:
            print("%-18s      %d of 3 repetitions — §5.7 is not satisfied yet"
                  % ("", len(usable)))
    print()


def main():
    args = sys.argv[1:]
    phase_override = None
    quiet = False
    if "--phase" in args:
        i = args.index("--phase")
        phase_override = args[i + 1]
        if phase_override not in ("latency", "throughput"):
            print("--phase takes latency or throughput", file=sys.stderr)
            return 2
        del args[i:i + 2]
    if "--quiet" in args:
        quiet = True
        args.remove("--quiet")

    if args and args[0] == "--aggregate":
        if len(args) < 2:
            print("--aggregate needs a rate", file=sys.stderr)
            return 2
        aggregate(args[1], args[2:] or None)
        return 0

    if args == ["--all"]:
        cells = all_cells()
    elif len(args) == 3:
        cells = ["%s/%s/%s-r%s" % (RESULTS_ROOT, args[0], args[1], args[2])]
    else:
        print(__doc__)
        return 2

    counts = {"PASS": 0, "FAIL": 0, "INVALID": 0}
    for cell in cells:
        verdict, _ = report_cell(cell, phase_override, quiet)
        counts[verdict] += 1
        if not quiet:
            print()
    print("%d PASS, %d FAIL, %d INVALID" % (counts["PASS"], counts["FAIL"], counts["INVALID"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
