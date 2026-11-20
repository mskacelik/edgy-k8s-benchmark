# Status, 2026-11-19

Short companion to `docs/RUN-PLAN.md`. Three parts: what the numbers actually
are, what was changed in the repository and must not be changed back, and what to
do next.

If you are an agent picking this up cold: read this file, then `RUN-PLAN.md`,
then run `python3 -I scripts/verdict.py --all`. Do not form a view of the results
from filenames or from `top.txt`. `docs/TODO.md` is the ordered task list.

---

## 1. Where the numbers stand

Scenario A (pass-through `GET`) only. Nothing of scenario B or C has been run.

### Throughput — phase 1 is NOT finished

**No throughput cell passes, for any arm.** `verdict.py --all` scores every
bisection cell `FAIL` or `INVALID`, so table T2 has nothing behind it yet:

| Arm | Best cell under the pinned topology | Verdict |
|---|---|---|
| scg | 9000-r1 (steady clean, p99 4.75 ms) | **INVALID** — `hold` failed |
| scg | 9000-r2 | **INVALID** — 53-byte `run.json` |
| scg | 9250-r1 (p99 23.46 ms) | FAIL |
| scg | 9500-r1 (session limit, achieved 8781/s) | FAIL |
| edgy | 18000-r1 (p99 18.22 ms) / 18000-r2 (p99 482 ms) | FAIL |
| edgy | 22000-r1 (steady clean, p99 8.52 ms) | **INVALID** — `hold` failed |
| direct | 24000-r1 | **INVALID** — no steady phase, 404 path |

SCG's ceiling is bracketed between 9000 (clean steady, invalid warm-up) and
9250 (clean fail). Edgy's is bracketed between 18000 (fail) and 22000 (clean
steady, invalid warm-up) — note this is **not** monotone, which is itself a
reason to distrust single cells here.

**The highest-value run available is one clean SCG repetition at 9000.** It is
seven minutes and it is what the whole campaign's nominal rate rests on.

### The nominal rate: 8550 → **8100 req/s**

Revised 2026-11-19. §5.3 takes the lowest maximum across the three JVM arms,
call it *M*, and measures everything at 0.9·*M*.

- The old 8550 was 0.9 × 9500, from a 9500 cell that scored clean **before** the
  topology was pinned.
- Under the pinned topology 9500 fails outright (`Exceeded session limit`,
  achieved 8781/s against 9500 requested) and 9250 fails on p99. The pass side
  moved down to 9000, so *M* = 9000 and **0.9 × 9000 = 8100**.

All four phase-2 cells were run at 8100 and it is the rate to keep. But be
honest about what backs it: **9000 has no `PASS` cell**, only an `INVALID` one
whose steady phase was clean. Until that repetition exists, 8100 is derived from
a cell the criterion says tells us nothing. This is the first thing to fix.

### Latency — phase 2 is one repetition of three

Four cells at 8100, 10-minute steady, all with a clean achieved rate and zero
connection errors, timeouts or internal errors:

| Arm | p50 | p90 | p99 | p99.9 | max | gateway CPU | gateway RSS |
|---|---|---|---|---|---|---|---|
| direct | 0.54 ms | 0.96 ms | 4.85 ms | 36.96 ms | 221 ms | — | — |
| edgy | 0.77 ms | 1.33 ms | 5.54 ms | 8.85 ms | 213 ms | ~1140m = 57 % | 160–175 MiB |
| scg | 1.29 ms | 7.83 ms | 19.79 ms | 30.41 ms | 228 ms | ~1620m = 81 % | 245–278 MiB |
| edgy-native | 0.90 ms | 1.39 ms | 68.68 ms | 130.55 ms | 329 ms | ~1300m = 65 % | 64–103 MiB |

§5.7 requires **three** repetitions per arm, each on a fresh pod, reported as a
median with the spread. One run is not evidence, and `verdict.py --aggregate
8100` says so on every row. Eight runs remain.

### Three findings that survive

- **SCG's limit is not CPU.** 81 % of two cores at 9500 where it collapsed;
  Edgy was at 94 % when it reached its own knee. The two gateways run out of
  different things, and §5.1 asks for the mode that ended each arm.
- **Native trades tail latency for footprint.** RSS 64–103 MiB against the JVM's
  160–175, for ~14 % more CPU, with p50 and p90 close to the JVM but p99 at
  68.68 ms and p99.9 at 130.55 ms, and a sawtooth RSS pattern. That shape is
  GraalVM CE's default Serial GC. §3 makes tuning a non-goal, so the default
  collector **is** the finding — name it in T1 and do not rebuild with G1 to
  make the number nicer.
- **The p90→p99 jump makes native's distribution bimodal** (1.39 ms → 68.68 ms).
  `PLAN-CH7.md` §9.1 pre-commits to what happens then: "If the numbers turn out
  to have that shape, a latency CDF on a logarithmic axis goes in the appendix
  and the body refers to it." That clause has now fired.

### One thing that is not a problem

`verdict.py` flags 122 generator CPU warnings on the SCG cell and 53 on direct.
They are **per-core** spikes and mean nothing on their own. Pod-level from
`top.txt`: direct 1257m mean / 1723m peak, SCG 1049m/1193m, Edgy 761m/801m,
native 769m/850m — against a 6000m limit, so 13–21 % of allocation. The
generator was nowhere near the limit. This is the evidence §6.2 demands for the
single-generator fallback and it belongs in §7.7.

---

## 2. What was changed, and why not to change it back

Each of these exists because something went wrong. The reasoning is also in a
comment at the relevant line, so an agent editing the file sees it there.

### Pinned pod placement — `k8s/*.yaml`

Every pod now has `nodeSelector: kubernetes.io/hostname: <node>`. The generator
alone had moved across four nodes between runs, and in one cell landed on the
database's node. The `preferredDuringScheduling` anti-affinity never bound.

Nodes are the ones the clean cells ran on: generator `kub-b4`, both gateways
`kub-a14`, backend-a `kub-a17`, backend-b `kub-a15`, postgres `kub-c4`, consul
`kub-a13`.

**Do not** replace this with anti-affinity rules, and **do not** move one pod's
node without moving the others and re-running the campaign. Both gateways share
a node on purpose — identical network path for both arms.

### Backend resources back to 3 CPU Guaranteed — `k8s/backends.yaml`

They had drifted to `requests: cpu 4 / limits: cpu 6`, which is Burstable QoS and
therefore subject to CFS throttling — the thing `PLAN-CH7.md` §6.1 requires
Guaranteed QoS to avoid. Every pod in the measurement path now has
`requests == limits`.

3 CPU is sufficient and deliberate: at Edgy's 22000 req/s the backend drew 62 %
of it while the gateway was at 94 %, so the gateway is the limiter, which is the
point. **Do not** raise it to make a run "safer" — it breaks QoS matching and the
quota, and it invalidates every cell measured before the change.

### Generator raised to 6 CPU, `threads: 6` — `k8s/hyperfoil.yaml`, `benchmarks/a-*.hf.yaml`

Hyperfoil's own `info.errors` logged cores above its 80 % threshold in every
cell, and 104 times at 100 % in the direct arm. `PLAN-CH7.md` §5.1 sanctions
scaling the generator precisely so it does not become the limit.

Keep `threads:` in the benchmark files equal to the pod's CPU count. Quota is now
18 of 20 CPU with one gateway up, so **scale Consul to 0 during scenarios A and
B**.

### Generator settings matched across arms — `benchmarks/a-*.hf.yaml`

`sharedConnections` was 512 / 1024 / 2048 across the three arms — a second
variable, which §4.4 forbids. Now `8192` / `maxSessions: 50000` / `threads: 6`
everywhere. **These three values must stay identical in every `a-*.hf.yaml`,
`b-*` and `c-*` file.** They are matched variables, not per-arm tuning.

### Direct arm path corrected — `benchmarks/a-direct.hf.yaml`

`/api/items/${id}` → `/items/${id}`. The `/api` prefix is what the *gateways*
strip; the backend never had it.

### Hyperfoil standalone mode — `k8s/hyperfoil.yaml`

The comments explaining why this is standalone rather than the operator or the
controller were deleted at some point. Restored. **Do not "fix" this back to the
controller:** the namespace has no CRD rights, and the controller writes its own
agent pod specs with no securityContext, which the restricted Pod Security
Standard rejects. This is `PLAN-CH7.md` §6.2 fallback one and the chapter reports
it as a limitation.

### `scg-gateway` replicas back to 0 — `k8s/gateways.yaml`

It had been committed as 1. Both gateways live at 0 in git; scale up only the arm
under test.

### Postgres warning — `k8s/postgres.yaml`

Storage is an `emptyDir`. A restart re-seeds a million rows and discards the
buffer cache. **Never restart it mid-campaign.** If it does restart, every cell
measured afterwards has to be re-run.

### `scripts/capture-cell.sh` rewritten

It hardcoded `sharedConnections: 2048` and `maxSessions: 20000` into every
`meta.txt`, so all existing metadata is wrong about runs that used 8192 / 50000.
It now reads those from the benchmark file, copies the benchmark alongside the
results, records node assignments and Postgres's pod age, flags a dirty working
tree, warns about pods that are not Running, and **refuses to run** when the rate
in the directory name disagrees with the rate in the benchmark file.

### `scripts/verdict.py` added, then split by phase

Applies the pass criteria mechanically, because applying them by eye produced
three misreadings in one evening. Run `python3 -I scripts/verdict.py --all`; it
writes the verdict back into each `meta.txt`.

It distinguishes **FAIL** (the cell is a valid measurement and did not pass)
from **INVALID** (no steady phase, truncated report, or a warm-up phase failed —
repeat it). That distinction matters: SCG failed `hold` at 9000 and then passed
cleanly at 9500. Read as a fail, that would have moved the ceiling in the wrong
direction on noise.

**Rewritten 2026-11-19.** Five changes, all of which alter what a cell scores:

1. **The p99 bound applies to throughput cells only.** See §2.2 of
   `RUN-PLAN.md` and the module docstring. The phase is inferred from the
   measured steady duration (≥ 5 min is a latency cell); `--phase` overrides it.
2. **Failed requests are actually checked.** It now reads `connectionErrors`,
   `internalErrors`, `requestTimeouts` and `invalid` out of the steady summary,
   and compares `responseCount` to `requestCount`. Previously only `failures[]`
   was checked, which holds SLA breaches rather than per-request errors — a
   cell answering 404 to everything passed on that path.
3. **`blockedTime > 0` in steady is a FAIL.** It means Hyperfoil could not issue
   on schedule, so the open model degenerated towards a closed one and the
   percentiles understate the truth. That is coordinated omission, which §5.4
   makes the chapter's central methodological claim, so it cannot be a note.
4. **p90 and max are reported**, as §5.4 and §7 require. Duration now comes from
   the report's own clock rather than the benchmark file, so a run cut short is
   scored against what it did.
5. **`--aggregate <rate>`** gives median and spread across repetitions, which is
   the shape T3 is drawn from, and refuses to be quiet about n < 3.

The generator CPU warning budget is normalised per minute of steady phase. It
was a flat 10, calibrated on 3-minute runs, which made a 10-minute run look 3.3×
worse for behaving identically. Warnings still never decide a verdict, and
pod-level CPU and RSS from `top.txt` are printed beneath each cell — that is the
§5.2 attribution evidence and the §5.6 RSS figure, in one place.

### `scripts/reset-cell.sh` added

`./scripts/reset-cell.sh <arm>`, run between every repetition. Scales the right
gateway down and back up for a fresh pod (§5.7), restarts Hyperfoil, sets Consul
to 0 for scenarios A and B and 1 for C, and then **refuses** unless: Postgres has
not restarted since a recorded baseline, every running pod is on the node its own
Deployment pins it to, exactly one gateway is up, and nothing is non-`Running`.
It prints the `port-forward` command, because that dies with the old Hyperfoil
pod every time.

It never runs `kubectl rollout restart` on a backend. `backend-a` is Guaranteed
QoS pinned to `kub-a17`; a rolling restart needs the replacement scheduled before
the original goes, the node has no room, and it hangs indefinitely. If a backend
needs replacing, `kubectl delete pod -l app=backend-a` and let the ReplicaSet
recreate it in place.

The Postgres check is the one that pays for the script: `a-edgy/18000-r1` was
lost to exactly that and nothing flagged it at the time.

### 2xx status validator added to every `a-*.hf.yaml`

```yaml
handler:
  status:
    range: 2xx
```

§5.1's first pass condition counts non-2xx responses as failed requests. Without
a validator Hyperfoil never looks at the status, so `invalid` stays 0 and a run
answering 404 to everything scores clean — which is what `a-direct/24000-r1` did,
caught by reading the path rather than by the instrument. **Verify it uploads**
(`upload /b/a-scg.hf.yaml` in the CLI parses and validates) before the first
reported run; the key is the one thing here that was not exercised against a live
controller.

This is a mid-campaign change to the benchmark files. It does not alter the load
and is identical across arms, but the four `8100-r1` cells ran without it, so
their "zero failed requests" rests on connection and timeout counters alone. That
is recorded in each of their `meta.txt` files.

### Pre-pinning results archived, not deleted

`benchmarks/results/scenario-a-direct`, `scenario-b-edgy` and `scenario-c-scg`
were the three **arms** of scenario A under the old confusing naming, from
17–18 November and before the topology was pinned. Moved to
`benchmarks/results/superseded-pre-pinning/{direct,edgy,scg}/` with a README
saying why nothing in them is reportable. Kept because `scg/11000-clean.json` is
the source of the 541 MiB SCG RSS figure that `RUN-PLAN.md` §6 uses to predict
the memory squeeze. `verdict.py --all` skips anything not named
`<rate>-r<rep>`.

### `.gitignore` no longer ignores all of `docs/`

The rule was `docs/`, so `RUNBOOK.md`, `gateway-differences.md` and both planning
documents were outside version control — losable, and invisible to anyone
cloning the repository. Narrowed to `docs/superpowers/`, which is presumably what
was meant. `docs/` now needs committing.

### `backend-lb` Service added — `k8s/backends.yaml`

One Service over both replicas for scenario C's direct arm, selecting on `role`
because that is the only label both backends share. HTTPS only.

---

## 3. What to do next

`docs/TODO.md` is the ordered, tickable version of this with the cluster
mechanics attached. The short form:

**Desk work — done 2026-11-19**, except the last item:

1. `verdict.py` split by phase, with real error gating. Done.
2. `reset-cell.sh`. Done.
3. 2xx validators in the benchmark files. Done — still needs one `upload` to
   confirm the key parses against a live controller.
4. Hyperfoil image pinned by digest in `k8s/hyperfoil.yaml`. Done.
5. Pre-pinning results archived. Done.
6. **Commit the working tree.** Not done. `capture-cell.sh` stamps cells `DIRTY
   WORKING TREE` otherwise, and all four `8100-r1` cells carry that stamp.

**Then phase 1, about an hour of cluster time.** This is the part that is not
finished and that everything else rests on:

7. `a-scg` at **9000**, one clean repetition. This is the single most valuable
   run available: the nominal rate of 8100 is 0.9 × 9000 and 9000 currently has
   no `PASS` cell. If it fails, *M* moves down, 8100 moves with it, and all four
   latency cells have to be re-run at the new rate — so do it before anything
   else, not after.
8. `a-edgy` at **22000** (the clean-steady cell to repeat), then 23000, 24000
   until one fails.
9. `a-direct` at **24000**, with the corrected path. Report
   `≥ X req/s, generator-limited` only if the generator's **pod-level** CPU
   actually shows it — the per-core warnings do not.

**Then phase 2**, eight runs: repetitions 2 and 3 of all four arms at **8100**,
10-minute steady, `reset-cell.sh` between each. `verdict.py --aggregate 8100`
produces the T3 row when they are in.

Then native's own ceiling, startup and the squeeze; then scenario B; then C
reduced. `RUN-PLAN.md` §3 has the ordering and the budget.

---

## 4. What not to do

- **Do not report any number from the cells dated 2026-11-18.** They were
  measured across three different topologies and two different backend
  allocations. The brackets survive; the numbers do not.
- **Do not treat a warm-up failure as the arm's ceiling.** Repeat the run.
- **Do not change resources, `nodeSelector`, `sharedConnections`, `threads` or
  `maxSessions` mid-campaign.** If one has to change, every cell measured before
  it is void. This has already happened twice.
- **Do not restart Postgres.** `reset-cell.sh` now refuses if it has.
- **Do not relax the 10 ms p99 bound.** It was declared in advance (§2.2) and
  §7.4 of the chapter has to justify it. A bound of 150 ms against observations
  of 5–69 ms excludes nothing, which makes it not a criterion, and an examiner
  will say so. The bound does not need relaxing: it applies to the throughput
  bisection, and at the nominal rate p99 is the result rather than a gate.
- **Do not `kubectl rollout restart` a backend.** Guaranteed QoS on a pinned
  node makes it hang forever. `kubectl delete pod -l app=backend-a` instead.
- **Do not reuse a Hyperfoil pod across two 10-minute runs.** Its GC/jitter
  watchdog trips and kills the run partway. `reset-cell.sh` restarts it.
- **Do not use `kubectl apply -f k8s/...` or `kubectl set resources`.** Both
  bypass `kustomization.yaml`, and that is how the backend lost its image tag and
  a run was lost. Always `kubectl apply -k .`.
- **Do not read results off `*.html` or `top.txt`.** Use `verdict.py`.
- **Do not add scenario B's database-reset protocol** from `PLAN-CH7.md` §4.2.
  The transforming endpoint reads by id and never writes, so no table grows and
  arm order is not a confound.
