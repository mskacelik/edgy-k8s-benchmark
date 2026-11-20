# Chapter 7 run plan — what to do next

Companion to `~/dev/swe/diploma/PLAN-CH7.md` (the methodology) and `docs/RUNBOOK.md`
(the mechanics). This file is the execution order: what is done, what is wrong with
what is done, and what remains, in the order it has to happen.

Written 2026-11-18, after the scenario A throughput runs. **Revised the same
evening** after a second batch of cells — §1 and §2 below are the revised
version. `docs/STATUS.md` is the shorter companion: what was fixed, and what not
to undo.

Scope chosen: **A and B at full protocol, native on A, squeeze on A, C reduced.**
See §9 for the budget this assumes.

---

## 1. State of play

Everything measured so far is **scenario A** of `PLAN-CH7.md` — pass-through
`GET /api/items/{id}`. The three benchmark files are the three *arms* of it, which
the file names (`scenario-a-direct`, `scenario-b-edgy`, `scenario-c-scg`) make
confusing, because `PLAN-CH7.md` uses A/B/C for scenarios. **Rename them**
(§2.5). Nothing of the plan's scenario B (transforming POST) or C (TLS +
discovery) has been run.

Run `python3 -I scripts/verdict.py --all` for the current scoring of every cell;
it applies §2.2 mechanically and rewrites each `meta.txt`. As of the revision:

**Revised again 2026-11-19, after the first latency batch.** The table below is
the pre-pinning picture and is kept only to show how the brackets were arrived
at. Under the pinned topology, **no throughput cell passes for any arm** — see
`docs/STATUS.md` §1 for the current scoring. T2 has nothing behind it yet and
phase 1 is not finished.

| Arm | Status | Best passing cell | p50 / p99 | Gateway CPU (limit 2) |
|---|---|---|---|---|
| direct | **ceiling unknown** | 10000 (old layout) | 0.42 / 0.92 ms | backend 1.55 of 3 |
| edgy | **ceiling just above 22000** | 22000, steady clean, 3.96 M requests | 1.00 / 8.52 ms | 1.88 = **94 %** |
| scg | **converged: 9500** | 9500, zero failures anywhere | 1.05 / 4.92 ms | 1.61 = 81 % |

#### The nominal rate: 8550 → 8100

The 9500 that gave 8550 was measured **before** the topology was pinned. Re-run
under the pinning of §2.5 it fails outright — `Exceeded session limit`, achieved
8781/s against 9500 requested — and 9250 fails on p99 at 23.46 ms. The pass side
moved down to 9000, so *M* = 9000 and the nominal rate is **0.9 × 9000 = 8100**.
All four latency cells were run there.

Be honest about what backs it, because this is the campaign's load-bearing
number: **9000 has no `PASS` cell.** `9000-r1` has a clean steady phase at
p99 4.75 ms but failed its warm-up, so §2.2 scores it `INVALID`; `9000-r2` is a
53-byte `run.json`. Until a clean repetition exists, 8100 is derived from a cell
the criterion says tells us nothing. **One seven-minute SCG run at 9000 is the
highest-value thing on the list.** If it fails, *M* moves down, 8100 moves with
it, and all four latency cells are re-run at the new rate — §5's most expensive
failure mode, and the reason to do it before anything else.

Edgy's bracket is also not monotone under the pinning — 18000 fails on p99
while 22000 has a clean steady phase — which is reason enough to distrust any
single cell here. Its exact ceiling changes the T2 throughput column but not
the rate anything is measured at.

**SCG's limit is not CPU.** It sat at 81 % of two cores at 9500 and 83 % at 9750,
where it collapsed. Whatever ends that arm — event loop, connection pool,
allocation rate — it is not running out of processor. Edgy by contrast was at
94 % when it reached its own knee. That contrast is a finding and belongs in §7.5
of the chapter, not just in the attribution evidence.

### Cells that look like results and are not

Four of the seven exported cells are void. They are kept on disk, scored
`INVALID`, because the chapter has to be able to say why a rate was or was not
tested.

- **`a-direct/24000-r1`** — three faults at once. The report has no steady phase
  at all; `info.errors` holds **104 generator CPU warnings peaking at 100 %**;
  and the benchmark requested `/api/items/${id}` against the backend directly,
  which has no `/api` prefix, so every request was a 404. A 404 never touches the
  database, so the arm was fast for the wrong reason and the generator could push
  harder than the real workload allows. Path fixed in `a-direct.hf.yaml`.
- **`a-edgy/25000-r1`** — `run.json` is 53 bytes. `pods.txt` shows
  `backend-a-76cd7fcc67` in `ImagePullBackOff`: the image tag was dropped when
  the backend's CPU limit was edited, so it tried to pull `:latest`, which does
  not exist. Nothing ran. **This is the cell that made 25000 look unreachable.**
- **`a-edgy/18000-r1`** — p99 18.22 ms against 3.65 ms for the same rate the day
  before. `pods.txt` explains it: backend-a and Postgres were both on `kub-c6`,
  and Postgres was a fresh pod, so a million rows had just been re-seeded into a
  cold buffer cache. **This is the cell that made 18000 look like the ceiling.**
- **`a-edgy/22000-r1`** and **`a-scg/9000-r1`** — steady phases clean, but a
  warm-up phase failed, so they are repeats rather than fails (§2.2).

### The condition underneath all four

**Pod placement was uncontrolled and the environment drifted mid-campaign.** The
generator alone moved across four nodes between runs — `kub-b4`, `kub-c6`,
`kub-c4`, `kub-b15` — and in the direct cell it landed on Postgres's node. The
anti-affinity was `preferredDuringScheduling`, so it never bound. Over the same
few hours the backend went from 3 CPU Guaranteed to `requests: 4 / limits: 6`
(Burstable, so subject to CFS throttling) and the generator's memory doubled.

Arms measured under different topologies and different allocations are not
comparable, which is §4.4's prohibition exactly. All of this is now pinned —
see `docs/STATUS.md`.

Other detail worth keeping:

- SCG's ending failure mode is connection starvation, consistently, from 9750
  upward. Edgy's will be something else. `PLAN-CH7.md` §5.1 asks for the mode
  that ended each arm, and the difference is reportable.
- Postgres never exceeded 1.3 of its 4 cores and backend-a never exceeded 1.9 of
  3. The attribution evidence for §5.2 is sound — the database was never the
  limit in any cell.
- Hyperfoil logged cores over its own 80 % threshold in **every** cell. Within
  budget except in the direct arm, where it was the limit outright. The generator
  has gone from 4 CPU to 6 in response.

---

## 2. Fix before any further reported run

These are not optional polish. Each one, left alone, makes a run unreportable.

### 2.1 One generator configuration for every arm — done

Was 512 / 1024 / 2048 across the three arms, which is a second variable and what
§4.4 of `PLAN-CH7.md` forbids. Now **`sharedConnections: 8192`,
`maxSessions: 50000`, `threads: 6` in all three files**, matching the generator's
6 CPU.

The argument for the chapter: by Little's law the healthy regime needs
`rate × response time` connections — at 22000 req/s and 1 ms that is 22 — so 8192
is nearly three orders of magnitude of headroom while an arm is behaving.
Starvation therefore cannot occur before the arm's knee; at 9750 req/s it would
take a mean response time above 840 ms to exhaust the pool. That makes
"blocked waiting for a free connection" a *detector* of saturation rather than a
cap the generator imposed, which is what licenses using it as a stopping
condition. One value, stated in T1.

### 2.2 Declare the p99 bound for the §5.1 pass criterion

`PLAN-CH7.md` §11 leaves this to be set from a pilot. The pilots now exist.

**p99 ≤ 10 ms, absolute, identical for all arms and scenarios.**

Justification to put in §7.4 of the chapter: it is roughly 2× the slowest clean
pilot observation (SCG at 9500, 4.92 ms) and 11× the fastest (direct, 0.92 ms), so
it does not single out an arm; and it correctly rejects SCG at 9750 (662 ms) and
the contaminated Edgy 18000 cell (18.2 ms), which is the case the bound exists to
catch. Declared now; it does not move again.

#### Which cells it gates — revised 2026-11-19

This is the part that was wrong, and getting it wrong nearly cost the chapter
its pre-declared criterion.

At the nominal rate, SCG measured p99 19.79 ms and native 68.68 ms over ten
minutes. Applied flatly, the bound fails both. The tempting response is to
relax it to something the results clear — and that is the one move to refuse.
A bound of 150 ms against observations of 5–69 ms excludes nothing, so it is
not a criterion; and §5.1 fixes the criterion "before any run", which a bound
chosen after seeing the numbers plainly is not. An examiner reads that in one
glance.

The bound does not need relaxing, because it was being applied to the wrong
cells. **It belongs to the throughput bisection (§5.1) and not to the latency
measurement (§5.4):**

- A **throughput** cell asks whether a rate is sustainable. p99 is a gate, and
  10 ms decides it.
- A **latency** cell runs at the nominal rate, which is already known to be
  sustainable. Here p99 **is the result**. Gating on it means discarding a
  measurement for having the value it has. `PLAN-CH7.md` §7 lists this cell's
  gates explicitly — error rate, and achieved versus requested rate. p99 sits
  in the latency-table row, not a gate row.

So SCG's 19.79 ms and native's 68.68 ms are **findings for T3**, not failures.
`verdict.py` prints them with a note and passes the cell.

What they do reveal is worth a sentence in §7.4: SCG measured p99 4.75 ms over
three minutes at 9000 and 19.79 ms over ten minutes at 8100 — a *lower* rate.
The three-minute bisection systematically under-detects the tail, which is
exactly what §5.4 says the ten-minute phase exists to catch ("long enough to
catch periodic events — a full-heap collection, a connection pool being
recycled — that a shorter phase would miss"). It is a vindication of the
protocol, not a defect in it. It also means a ceiling reported from a
three-minute cell carries that caveat, and the chapter should say so.

#### The three verdicts

Implemented in **`scripts/verdict.py`** — run `python3 -I scripts/verdict.py
--all` rather than reading percentiles by eye. The phase is inferred from the
measured steady duration (≥ 5 minutes is a latency cell); `--phase` overrides.

1. **FAIL** — the cell is a valid measurement and did not pass:
   - any failure recorded against the *steady* phase;
   - any failed request in steady — connection errors, internal errors,
     timeouts, or responses failing validation (non-2xx);
   - responses not matching requests;
   - `blockedTime` above zero in steady;
   - achieved rate more than 1 % off the requested one;
   - **throughput cells only**: steady p99 above 10 ms.
2. **INVALID** — the run says nothing about the rate and is simply repeated.
   No steady phase, a truncated report, or a *warm-up* phase failed. It does
   **not** push the ceiling down.
3. **PASS** — everything else.

Separating INVALID from FAIL is not bookkeeping. SCG failed `hold` at 9000 and
then passed cleanly at 9500; read as a fail, that would have moved the ceiling
500 req/s in the wrong direction on the strength of noise.

Two of those FAIL conditions are new on 2026-11-19 and both close real holes.
**Failed requests were not actually being counted** — only Hyperfoil's
`failures[]` was read, which holds SLA breaches rather than per-request errors,
so a cell answering 404 to everything scored clean. And **`blockedTime` above
zero** means the generator could not issue on schedule, so the open model
degenerated towards a closed one and the percentiles understate the truth. That
is coordinated omission, which §5.4 makes the chapter's central methodological
claim, so it cannot be left as a note.

Generator CPU warnings are printed but never decide the verdict. They are
per-core spikes: in the four 8100 cells individual cores touched 100 % while the
generator *pod* sat at 13–21 % of its six. `verdict.py` prints pod-level CPU and
RSS from `top.txt` under every cell, and that is what §5.2 attribution and §7.7
co-location both actually rest on.

### 2.7 Validate the response status — added 2026-11-19

`PLAN-CH7.md` §5.1's first pass condition counts non-2xx responses as failed
requests. The benchmark files had no validator, so Hyperfoil never looked at the
status: `invalid` stayed 0 whatever came back. `a-direct/24000-r1` answered 404
to every request and was caught by someone reading the path, not by the
instrument. Every `a-*.hf.yaml` now carries:

```yaml
handler:
  status:
    range: 2xx
```

Identical across arms, no change to the load. **Confirm it parses** with one
`upload` in the CLI before the first reported run — it is the only change here
never exercised against a live controller.

The four `8100-r1` cells ran without it. Their "zero failed requests" therefore
rests on connection and timeout counters alone, which is recorded in each of
their `meta.txt` files. Repetitions 2 and 3 run with it.

### 2.3 The scenario C direct arm has no Service to call — done

`PLAN-CH7.md` §4.2 wants C's direct arm to be the Kubernetes Service over TLS with
two replicas behind it. `backend-a` and `backend-b` are separate Deployments with
separate Services; nothing fronts both. Both pods already carry `role: backend`,
so one Service is enough, and it is now in `k8s/backends.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-lb
spec:
  selector:
    role: backend
  ports:
    - name: https
      port: 8443
```

Add to `k8s/backends.yaml`. Verify both endpoints appear:
`kubectl get endpoints backend-lb -n skacelik-ns`.

### 2.4 Startup time cannot currently be measured

Both gateways have `readinessProbe` with `initialDelaySeconds: 3, periodSeconds: 3`.
That quantises "time to first served request" to three seconds. JVM Edgy starts in
roughly a second and native in tens of milliseconds, so the probe would report them
as identical and destroy the one number the native paragraph rests on.

For the footprint runs only, measure as `pod .status.containerStatuses[].state.running.startedAt`
to the application's own `started in Xs` log line, and record the log line verbatim.
Alternatively drop the probe to `initialDelaySeconds: 0, periodSeconds: 1` for those
runs and say so. Do not report a number taken off the current probe.

### 2.5 Pin the topology — done

Every pod now carries `nodeSelector: kubernetes.io/hostname`, set to the node it
occupied during the clean SCG 9500 and Edgy 22000 cells:

| Pod | Node |
|---|---|
| hyperfoil (generator) | `kub-b4` |
| edgy-gateway **and** scg-gateway | `kub-a14` |
| backend-a | `kub-a17` |
| backend-b | `kub-a15` |
| postgres | `kub-c4` |
| consul | `kub-a13` |

Both gateways pin to the *same* node deliberately: the two arms are then
generated across an identical network path, so nothing about the node or its link
can be mistaken for a difference between the gateways. Only one is ever up.

`nodeSelector` on the built-in `kubernetes.io/hostname` label needs no
cluster-level rights, unlike labelling nodes yourself, and unlike `nodeName` it
still goes through the scheduler — so a full node leaves the pod `Pending`
visibly rather than failing strangely. If a node is drained, change all six
selectors together and re-run the campaign; do not move one pod.

Record the six node names in T1.

### 2.6 Still outstanding

- ~~**Pin the Hyperfoil image.**~~ Done — `k8s/hyperfoil.yaml` now carries
  `quay.io/hyperfoil/hyperfoil@sha256:492c5cb…`, and `meta.txt` records the
  digest per cell. Note the RUNBOOK's CLI command still says `:latest`; the CLI
  is not in the measurement path, but get its version into T1.
- **Startup time is not yet measurable.** Both gateways have `readinessProbe`
  with `initialDelaySeconds: 3, periodSeconds: 3`, which quantises "time to first
  served request" to three seconds. JVM Edgy starts in about a second and native
  in tens of milliseconds, so the probe would report them as identical and
  destroy the one number the native paragraph rests on. For the footprint runs,
  measure from `.status.containerStatuses[].state.running.startedAt` to the
  application's own `started in Xs` log line, and quote the log line. Do not
  report a number taken off the current probe.
- **Commit the working tree.** The standalone-Hyperfoil switch, the Consul
  `CONSUL_DISABLE_PERM_MGMT` fix and the Postgres `PGDATA` fix are facts the
  chapter reports; they belong in git history before the reported runs. Note that
  `capture-cell.sh` now marks a cell `DIRTY WORKING TREE` if they are not.

---

## 3. Order of work

The order is forced by two dependencies: throughput before latency within a
scenario, because the nominal rate is derived from the throughput maxima (§5.3 of
`PLAN-CH7.md`); and the native image build before the native arm, because if it
does not build the arm is dropped and the budget changes.

| # | Phase | Cluster time | Blocks |
|---|---|---|---|
| 0 | Fixes of §2 — no cluster needed | 1 h desk | everything |
| 0b | **Trigger the native build now**, in the background | 0 (CI) | phase 3 |
| 1 | Scenario A throughput, redone under the common settings | ~1.3 h | phase 2 |
| 2 | Scenario A latency at the nominal rate, 3 reps × 3 arms | ~2.1 h | the main table |
| 3 | Native Edgy on scenario A — throughput, latency, RSS, startup | ~1.3 h | — |
| 4 | Memory squeeze on scenario A | ~0.8 h | — |
| 5 | Scenario B — throughput then latency | ~3.4 h | — |
| 6 | Scenario C — reduced (§7) | ~1.8 h | — |

Phases 3 and 4 can slot into any gap; 5 and 6 are the ones to cut against if the
week goes badly, in that order.

### Phase 0b — build native first, not last

`PLAN-CH7.md` §5.5 says to build native early so a failure is discovered while
there is time to drop the arm. `Dockerfile.native` and the `native=true` workflow
input exist but have never been exercised against this gateway application.

```sh
gh workflow run images.yml -f edgy_ref=main -f native=true -f push=true
gh run watch
```

Do this at the start of phase 0, not at the start of phase 3. If it fails for
anything that is not a quick reflection registration, drop the native arm and say
so in the chapter — fixing native support is extension work, out of scope here.

---

## 4. Phase 1 — finish scenario A throughput

Three searches, all under `sharedConnections: 8192`, `maxSessions: 50000`,
`threads: 6`, 3-minute steady phase, warm-up of 30 s `increasingRate` from 0.1·R
plus 90 s `constantRate` at R. Every candidate rate goes into all three phases —
`rampup` `targetUsersPerSec`, `hold` `usersPerSec`, `steady` `usersPerSec` — see
RUNBOOK E2.

Every cell measured before the pinning of §2.5 is superseded, because the
topology and the allocations have changed. What survives is the *bracket*, not
the numbers.

| Arm | Start at | Why | Precision | Expected runs |
|---|---|---|---|---|
| scg | **9000** | pass side of the bracket; confirmation, not search | 250 req/s | 1–2 |
| edgy | **22000** | steady passed there, ceiling just above | 1000 req/s | 3–4 |
| direct | **24000** | never validly measured | 1000 req/s | 4–5 |

Set the rate in all three phases of the `a-*.hf.yaml` file before each step;
`capture-cell.sh` refuses if the directory name and the `steady` rate disagree.

What matters during the search:

- **SCG is nearly done searching, but has no passing cell.** 9000 had a clean
  steady phase and a failed warm-up (`INVALID`); 9250 fails on p99. One clean
  repetition at 9000 under the pinned topology settles both the ceiling and the
  nominal rate. Do this first — everything downstream is derived from it.
- **Do not re-derive Edgy's ceiling from 18000.** That cell is INVALID; see §1.
  Go 22000, then 23000, then 24000.
- **Distrust the direct arm.** Its previous attempt used a 404 path and saturated
  the generator. Check the generator-warning count `verdict.py` prints on every
  direct cell. If it is still generator-limited at 6 CPU, report
  `≥ X req/s, generator-limited` — `PLAN-CH7.md` §5.1 permits that for this arm
  and no other.
- **Record the failure mode that ends each arm.** SCG dies of connection
  starvation at 81 % CPU, so it is not processor-bound; Edgy reached 94 % and
  will probably die of CPU. The contrast belongs in §7.5, not in a footnote.
- **Scale Consul to 0** during scenarios A and B. With the generator at 6 CPU the
  quota sits at 18 of 20 with one gateway up, and Consul's core is the slack.

**Exit criterion:** three maxima, each scored `PASS` by `verdict.py`, each with
CPU captures showing the gateway at or near its limit while backend and Postgres
stay clearly below theirs.

**The nominal rate is 8100**, from 0.9 × SCG's 9000. It is set by the weakest
arm, so Edgy's and direct's ceilings move only the T2 throughput column, not the
rate anything is measured at. Confirm SCG at 9000 first — if that repetition
fails, the rate moves with it and the four latency cells already captured have
to be re-run.

---

## 5. Phase 2 — scenario A latency

Twelve runs: 4 arms × 3 repetitions, all at **8100 req/s**, 10-minute steady
phase, same warm-up shape. (Native is phase 3's arm but shares this rate and
this shape, so it is run alongside.) Each repetition gets a fresh pod, so the
spread includes deployment-to-deployment variance — use
`./scripts/reset-cell.sh <arm>`, which does that and also restarts Hyperfoil,
checks the pinning and refuses if Postgres has restarted.

**Status: 4 of 12 done** — one repetition of each arm, all `PASS`. Eight remain.
`python3 -I scripts/verdict.py --aggregate 8100` is the T3 row and reports n per
arm; it says so when n < 3.

| Arm | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|
| direct | 0.54 ms | 0.96 ms | 4.85 ms | 36.96 ms | 221 ms |
| edgy | 0.77 ms | 1.33 ms | 5.54 ms | 8.85 ms | 213 ms |
| scg | 1.29 ms | 7.83 ms | 19.79 ms | 30.41 ms | 228 ms |
| edgy-native | 0.90 ms | 1.39 ms | 68.68 ms | 130.55 ms | 329 ms |

Three rules that are easy to get wrong:

- The nominal rate is one number for the whole scenario. Do not re-derive it per arm.
- **Do not gate these cells on the 10 ms p99 bound.** At the nominal rate p99 is
  the result, not a criterion. §2.2 above, and it is the thing most likely to be
  got wrong twice.
- If SCG's repetitions show the rate was above its ceiling after all, the
  converged maximum was too high. Step down one bisection increment, recompute
  the nominal rate, and **redo every run** — the rate has to be common for the
  numbers to compare. This is the most expensive failure mode in the campaign,
  and the reason phase 1 insists on confirming SCG's ceiling first.

Report p50, p90, p99, p99.9 and max, with the request count behind each
distribution. Median across the three reps, and state the spread. No means.

### Native's tail triggers the §9.1 appendix clause

Native's distribution is bimodal: p90 1.39 ms, p99 68.68 ms, with a sawtooth
RSS. `PLAN-CH7.md` §9.1 pre-commits to what happens then — "If the numbers turn
out to have that shape, a latency CDF on a logarithmic axis goes in the appendix
and the body refers to it, rather than taking a float in the chapter." Draw it
from the three repetitions once they exist.

The cause is GraalVM CE's default Serial GC. §3 of `PLAN-CH7.md` makes tuning a
non-goal, so the default collector **is** the finding: name it in T1, write the
paragraph around the trade — 64–103 MiB RSS against the JVM's 160–175, for ~14 %
more CPU and a tail two orders of magnitude worse. Do not rebuild with G1 to
make the number nicer; that is a second variable and it answers a question the
chapter is not asking.

---

## 6. Phases 3 and 4 — native and the squeeze

**Native, scenario A only.** Its own throughput bisection, then latency at the
*JVM-derived* nominal rate rather than one of its own. If native cannot sustain
that rate, report its own ceiling and build the paragraph around it — a native
binary trading peak throughput for footprint is the finding, not an obstacle.
Collect RSS under load and startup time per §2.4. Keep the warm-up shape identical
to the JVM arms even though there is no JIT to warm.

**The squeeze.** Rerun the scenario A latency phase at the nominal rate with the
gateway's memory limit halved from 2 Gi to 1 Gi, for Edgy, SCG, and native if it
passed. Heap follows automatically: the base image sets `-XX:MaxRAMPercentage=75.0`
and native uses `-XX:MaximumHeapSizePercent=75`. One run per arm, reported as
pass/fail against the §2.2 criterion plus percentiles for whichever arms pass. Not
a sweep.

The existing captures suggest how this will go: Edgy held 140–163 MiB RSS at
18000 req/s, while SCG reached 541 MiB and was still climbing during the 11000 run.
That contrast is the paragraph.

---

## 7. Phases 5 and 6 — the other scenarios

Short answer to "is that even necessary": **B yes, C in reduced form.** And both
are cheaper than they look, because **no code has to be written for either.**

### What already exists

Both gateways and the backend already implement all three scenarios:

| Scenario | Route | Edgy | SCG |
|---|---|---|---|
| A pass-through GET | `/api/items/*` | `Origin.of("backend", …)` | `rewritePath` to `/items` |
| B transforming POST | `/api/lookup` | `RequestJsonObjectBodyModifier` + `ResponseJsonObjectBodyModifier` | `modifyRequestBody` + `modifyResponseBody` |
| C TLS + discovery + LB | `/api/lb/items/*` | Stork over Consul, round-robin, TLS to `backend-discovered` | Spring Cloud LoadBalancer over Consul, HTTPS |

`scripts/smoke.sh` already asserts both gateways behave identically on all three.
What is missing is only the `.hf.yaml` files, plus the one Service of §2.3.

### Scenario B — keep it, at full protocol

It is the architecturally interesting case: the gateway has to accumulate the
request body instead of streaming it, which is where Edgy's buffering differs from
plain proxying, and it is the only scenario where the two gateways do materially
different work. Dropping it would leave the chapter resting on pass-through
proxying alone.

**`PLAN-CH7.md` §4.2's database-reset-per-cell and arm-order randomisation do not
apply here and should be struck from the chapter.** That section assumed a
`POST /api/villains` that inserts rows. The implemented endpoint is
`POST /items/lookup`, which reads by id and never writes — the Javadoc says so
explicitly, for exactly this reason. No table grows, no restore is needed, arm
order is not a confound, and the run-time budget loses the restore cost. Say in the
chapter that the transforming route is read-backed so that the write path is not a
confound; an examiner will otherwise ask.

The direct arm for B applies the same JSON transformation inside the Hyperfoil
scenario, so the backend receives an identical request. Body: the `LookupRequest`
record, `{"id": N}`, plus the `via` field the gateway would have added.

Expect lower maxima than A for all three arms — body accumulation is the expensive
path — so the bisection brackets start lower. Use A's results as the upper bound
for each arm and bisect down.

### Scenario C — run it reduced

`PLAN-CH7.md` already makes C the first thing to shrink (§8) and sends its results
to the appendix (§9.1), so it is not carrying chapter-body argument. Under the
chosen scope:

- throughput bisection for all three arms, at full precision;
- latency at the C nominal rate, **one repetition, 5-minute steady phase**, not
  three repetitions of ten minutes.

That is honest as long as the appendix says the repetition count differs, which
`PLAN-CH7.md` §8 already anticipates ("say which, in §7.9").

One unknown to resolve before committing to C, cheaply and early:

> **Can Hyperfoil be made to trust the private CA** for the direct arm, which talks
> TLS straight to `backend-lb:8443`? The gateway arms are fine — both gateways
> already trust `tls/ca-cert.pem`. The generator is the open question. Try the
> benchmark's own `http.*` TLS settings first; if there is nothing, fall back to
> `-Djavax.net.ssl.trustStore` in the Hyperfoil pod's `JAVA_OPTS`, and if that also
> fails, the C direct arm is dropped and C becomes a two-arm gateway-only comparison
> — which is still publishable in an appendix, but decide it now, not mid-phase.

Spend 15 minutes on this during phase 0.

Remember C supports **no causal claim** about TLS, load balancing or discovery
individually — it changes three things at once, deliberately, as a realistic
deployment configuration. The appendix text has to say so.

---

## 8. Record-keeping

The layout is `benchmarks/results/<scenario>-<arm>/<rate>-r<rep>/`, written by
`scripts/capture-cell.sh`, holding:

- `run.json` and `run.html` — the Hyperfoil exports;
- `top.txt` — `kubectl top pods` sampled every 15 s through the steady phase;
- `pods.txt` — `kubectl get pods -o wide`, for the placement check;
- `benchmark.hf.yaml` — a copy of the benchmark as it was actually run;
- `meta.txt` — nodes, images, limits, generator settings, Postgres pod age, and
  the verdict, which `verdict.py` writes back.

Two things the script does that are worth not undoing. It **reads the generator
settings out of the benchmark file** instead of hardcoding them — the hardcoded
version wrote `sharedConnections: 2048` into every `meta.txt` for runs that
actually used 8192 — and it **refuses to run** when the rate in the directory
name disagrees with the rate in the benchmark file, which is the easiest way to
mislabel a cell.

T1's environment capture is in `benchmarks/results/environment-t1.txt`: node CPU
model (AMD EPYC 9454), kernel, Kubernetes version (v1.36.6+rke2r1), PostgreSQL
17.12, the generator's JDK. Still missing from it: Quarkus version, Spring Cloud
Gateway version, Hyperfoil version, and the gateway containers' own JDK build.

Pin the Edgy commit for the whole campaign and quote it in the chapter. Images are
currently tagged `ee77d00`; `PLAN-CH7.md` §6.4 asks for a tag rather than a loose
SHA. If Edgy moves mid-campaign, everything re-runs against the new tag — do not
mix.

---

## 9. Budget

Per-run arithmetic: a throughput step is 30 s ramp + 90 s hold + 3 min steady, plus
redeploy, so about 6.5 minutes. A latency run is 2 min warm-up + 10 min steady plus
redeploy, about 14 minutes.

| Phase | Runs | Time |
|---|---|---|
| 1 — A throughput | ~12 | 1.3 h |
| 2 — A latency | 9 | 2.1 h |
| 3 — native | ~7 | 1.3 h |
| 4 — squeeze | 3 | 0.8 h |
| 5 — B throughput + latency | ~12 + 9 | 3.4 h |
| 6 — C throughput + reduced latency | ~12 + 3 | 1.8 h |
| | | **~10.7 h** |

Retries are certain, so budget 16–20 hours spread over the week. That is consistent
with `PLAN-CH7.md` §8's fourteen-to-sixteen hours, with C's reduction roughly
offsetting the throughput re-runs §2 forces.

If the week compresses, cut in this order: C's latency runs, then C entirely, then
B's third repetition, then B's steady phase to 5 minutes. Do not cut phase 1 or the
CPU attribution captures — they are what make everything else admissible.

---

## 10. What this changes in the chapter text

Things discovered during the runs that `PLAN-CH7.md` does not yet say, and that
have to reach §7.2, §7.4 or §7.7:

1. **Hyperfoil runs standalone, one generator pod, no operator and no agent
   scale-out.** The namespace has no CRD rights, and the controller's
   self-generated agent pods are rejected by the restricted Pod Security Standard,
   which the repository cannot patch. This is `PLAN-CH7.md` §6.2's fallback one,
   and §7.7 must report it: single generator, node co-location only *preferred*,
   and no scale-out if the generator becomes the limit. Give the evidence that it
   did not — generator CPU stayed at 1.1–1.2 of 4 cores at 18000 req/s.
2. **The §4.2 database-reset protocol is unnecessary** because the transforming
   route is read-backed (§7 above). Strike it and say why in one sentence.
3. **The arms ended in different failure modes**, which `PLAN-CH7.md` §5.1 asks to
   be reported as a finding rather than a footnote.
4. **`sharedConnections` is a declared, matched value** with the Little's-law
   justification of §2.1. It belongs in T1 and answers the §11 open question.
5. **The p99 bound is 10 ms**, declared in advance, with the derivation of §2.2
   — and it gates the throughput bisection only. At the nominal rate p99 is the
   reported result, not a pass criterion. One sentence in §7.4, because an
   examiner who sees SCG at 19.79 ms and native at 68.68 ms under a declared
   "p99 ≤ 10 ms" will otherwise read it as a criterion quietly abandoned.
6. **A three-minute steady phase under-detects the tail.** SCG measured p99
   4.75 ms over three minutes at 9000 req/s and 19.79 ms over ten minutes at
   8100 — a lower rate. §5.4 predicted this is why the latency phase is ten
   minutes; the campaign has now demonstrated it. Worth a sentence in §7.4, and
   it qualifies every ceiling in T2, which comes from three-minute cells.
7. **Native's tail is GraalVM CE's Serial GC**, not a property of Edgy. p90
   1.39 ms against p99 68.68 ms is bimodal, which fires §9.1's appendix-CDF
   clause. The paragraph is the trade: less than half the JVM's RSS, ~14 % more
   CPU, a tail two orders of magnitude worse.
8. **Zero failed requests now includes non-2xx**, via a status validator added
   on 2026-11-19 (§2.7). Before it, nothing in the instrument checked response
   codes. The scenario A repetition-1 cells predate it.
9. Three small infrastructure fixes were needed to make the stack run at all —
   Consul's `CONSUL_DISABLE_PERM_MGMT`, Postgres's `PGDATA` subdirectory, and the
   `Recreate` strategy on Hyperfoil. These are reproducibility notes for the
   configuration appendix, not chapter prose.

---

## 11. Open questions for the supervisor

- Whether appendices count against the 70 NS limit. `PLAN-CH7.md` §9.1 flags this
  as unconfirmed, and it decides whether C's tables, the CDF plots and the full
  benchmark YAML can go to an appendix or have to be cut. Ask before drafting, not
  after.
- Whether scenario C's reduced repetition count is acceptable for appendix
  material, given everything in the body runs at three.

