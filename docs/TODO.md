# TODO — the ordered task list

For whoever or whatever picks this up next. Written 2026-11-19.

This is the operational companion. It says *what to do and in what order*, with
the mechanics attached. It does not repeat the reasoning — that is in
`docs/RUN-PLAN.md` (execution plan), `docs/STATUS.md` (current numbers and what
not to undo) and `~/dev/swe/diploma/PLAN-CH7.md` (the methodology the chapter
has to satisfy).

## Read this first, cold start

1. `docs/STATUS.md` — where the numbers are, what was changed and why.
2. `docs/RUN-PLAN.md` §2 — the fixes that make a run reportable at all.
3. `python3 -I scripts/verdict.py --all` — the actual scoring. **Do not form a
   view of the results from filenames, from `top.txt`, or from the HTML
   reports.** Three cells were misread that way in one evening.
4. `python3 -I scripts/verdict.py --aggregate 8100` — the T3 table as it stands.

The single most important fact: **scenario A is not finished.** Phase 1
(throughput) has no passing cell for any arm, and phase 2 (latency) has one
repetition of three. Scenario B has not started and must not start first.

---

## The rules that cost a run when broken

Each of these has already destroyed at least one cell.

| Never | Instead | Why |
|---|---|---|
| `kubectl apply -f k8s/...` or `kubectl set resources` | `kubectl apply -k .` | Bypasses `kustomization.yaml`. This is how `backend-a` lost its image tag and a 25000 run became a 53-byte `run.json`. |
| Restart Postgres | Nothing — just don't | `emptyDir` storage. A restart re-seeds a million rows and dumps the buffer cache, voiding every cell measured after it. `a-edgy/18000-r1` died of this. |
| `kubectl rollout restart deploy/backend-a` | `kubectl delete pod -n skacelik-ns -l app=backend-a` | Guaranteed QoS pinned to `kub-a17`. A rolling restart wants both pods up at once, the node has no room, it hangs forever. |
| Reuse a Hyperfoil pod across two 10-minute runs | `./scripts/reset-cell.sh <arm>` | Its GC/jitter watchdog trips and kills the run partway. |
| Change `sharedConnections`, `threads`, `maxSessions`, resources or `nodeSelector` mid-campaign | Finish the campaign first | Every cell measured before the change becomes void. This has already happened twice. |
| Relax the 10 ms p99 bound | Nothing — it only gates throughput cells | It was declared in advance and §7.4 has to justify it. See `RUN-PLAN.md` §2.2. |
| Run two gateways at once | One up, the rest at 0 | Quota is 20 CPU; the idle one also takes CPU on the node under test. |
| Set the rate in only the `steady` phase | All three: `rampup` `initialUsersPerSec` (= 0.1·R) and `targetUsersPerSec`, `hold` `usersPerSec`, `steady` `usersPerSec` | The warm-up is specified relative to each run's own rate. Getting this wrong invalidates the bisection and leaves no trace in the report. |
| Target an Ingress or Route | The ClusterIP Service | Puts HAProxy in the measurement path. |
| Rebuild native with G1 to improve the tail | Report the Serial GC default | Tuning is an explicit non-goal (`PLAN-CH7.md` §3) and it is a second variable. |

---

## The loop for one cell

```sh
# 1. Reset. Refuses if Postgres restarted, a pod is off its pinned node,
#    two gateways are up, or anything is not Running.
./scripts/reset-cell.sh a-scg

# 2. Re-open the tunnel — it died with the old Hyperfoil pod. Second terminal.
kubectl port-forward -n skacelik-ns svc/hyperfoil 8090:8090

# 3. Set the rate in THREE places in benchmarks/a-scg.hf.yaml, and set
#    steady duration: 3m for a bisection step, 10m for a latency run.

# 4. Run it. Third terminal.
docker run --rm -it --network host -v "$PWD/benchmarks:/b" \
  quay.io/hyperfoil/hyperfoil:latest cli
#   connect localhost:8090
#   upload /b/a-scg.hf.yaml      <- also validates the YAML; a parse error shows here
#   run a-scg
#   status                        <- watch for the steady phase starting

# 5. AT THE START OF THE STEADY PHASE, fourth terminal.
#    40 samples for a 10m latency run, 12 for a 3m bisection step.
./scripts/capture-cell.sh a-scg 9000 1 12

# 6. Back in the CLI, export into the cell directory.
#   export <runid> -f json -d /b/results/a-scg/9000-r1
#   report <runid>          -d /b/results/a-scg/9000-r1

# 7. Rename to the names verdict.py expects, then score.
cd benchmarks/results/a-scg/9000-r1 && mv *.json run.json && mv *.html run.html && cd -
python3 -I scripts/verdict.py a-scg 9000 1
```

`capture-cell.sh` refuses if the rate in the directory name disagrees with the
`steady` rate in the benchmark file. That is deliberate — it is the easiest way
to mislabel a cell.

---

## Phase 0 — desk work

- [x] `verdict.py` split by phase, real error gating, p90/max, aggregate mode
- [x] `reset-cell.sh` with placement, Postgres and QoS assertions
- [x] 2xx status validators in all four `a-*.hf.yaml`
- [x] Hyperfoil image pinned by digest
- [x] Pre-pinning results archived to `superseded-pre-pinning/`
- [x] `8100-r1` provenance recorded in each `meta.txt`
- [ ] **Commit the working tree.** `capture-cell.sh` stamps cells `DIRTY WORKING
      TREE` otherwise, and all four existing cells carry that stamp.
- [ ] **Confirm the status validator parses** — one `upload /b/a-scg.hf.yaml` in
      the CLI. It is the only change never exercised against a live controller.
      If `handler: status: range: 2xx` is rejected, check the Hyperfoil version's
      docs for the equivalent key rather than dropping the validator.
- [ ] Fill the gaps in `benchmarks/results/environment-t1.txt`: Quarkus version,
      Spring Cloud Gateway version, Hyperfoil version, gateway containers' JDK
      build. Needed for T1, cheap now, annoying later.

---

## Phase 1 — scenario A throughput. **Blocks everything.**

3-minute steady phase, 2-minute warm-up. ~6.5 min per step.

- [ ] **`a-scg` at 9000, one clean repetition.** Do this first. The nominal rate
      of 8100 is 0.9 × 9000 and 9000 currently has no `PASS` cell — only an
      `INVALID` one whose steady phase was clean. If this fails, *M* drops, 8100
      drops with it, and the four latency cells already captured must be re-run.
      Precision 250 req/s.
- [ ] `a-edgy` at 22000 (clean steady, invalid warm-up — repeat it), then 23000,
      24000 until one fails. Precision 1000 req/s. Note the bracket is not
      monotone: 18000 failed on p99 while 22000 was clean. Distrust single cells.
- [ ] `a-direct` at 24000, with the corrected `/items/${id}` path. Precision
      1000 req/s. Report `≥ X req/s, generator-limited` **only** if the
      generator's *pod-level* CPU shows it. The per-core warnings `verdict.py`
      prints do not: at 8100 the pod sat at 13–21 % of its 6 cores while
      individual cores touched 100 %.
- [ ] Record the failure mode that ends each arm. SCG dies of connection
      starvation at ~81 % CPU, Edgy was at 94 % at its knee. `PLAN-CH7.md` §5.1
      asks for this and the contrast belongs in §7.5, not a footnote.

**Exit criterion:** three maxima, each scored `PASS`, each with CPU captures
showing the gateway at or near its limit while backend and Postgres stay clearly
below theirs. That last part is §5.2 attribution — `verdict.py` prints it under
every cell.

---

## Phase 2 — scenario A latency. 8 runs remaining.

10-minute steady at **8100 req/s**, fresh pod per repetition, ~14 min each.

- [ ] `a-direct` r2, r3
- [ ] `a-edgy` r2, r3
- [ ] `a-scg` r2, r3
- [ ] `a-edgy-native` r2, r3
- [ ] `python3 -I scripts/verdict.py --aggregate 8100` → the T3 row

r1 of each already exists and passes. **Do not gate these on the 10 ms p99
bound** — at the nominal rate p99 is the result, not a criterion
(`RUN-PLAN.md` §2.2). SCG at 19.79 ms and native at 68.68 ms are findings.

Once three reps exist, draw the **latency CDF on a log axis for the appendix**.
Native's distribution is bimodal (p90 1.39 ms → p99 68.68 ms) and
`PLAN-CH7.md` §9.1 pre-commits to a CDF in that case.

---

## Phase 3 — native. Scenario A only.

- [ ] Native's own throughput bisection. Start from the JVM arm's bracket and
      work down; expect it lower. Its latency is already measured at the
      JVM-derived nominal rate, which is correct — §5.5 says the rate stays
      derived from the three JVM arms.
- [ ] RSS under load — already captured (64–103 MiB, mean 78) but needs the
      three repetitions.
- [ ] **Startup time.** Still not measurable. Both gateways have
      `readinessProbe` with `initialDelaySeconds: 3, periodSeconds: 3`, which
      quantises "time to first served request" to three seconds and would report
      JVM (~1 s) and native (tens of ms) as identical. For the footprint runs
      only, measure `.status.containerStatuses[].state.running.startedAt` to the
      application's own `started in Xs` log line, and quote the log line
      verbatim. **Do not report a number taken off the current probe.**

      ```sh
      kubectl get pod -n skacelik-ns -l app=edgy-gateway-native \
        -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}'
      kubectl logs -n skacelik-ns deploy/edgy-gateway-native | grep "started in"
      ```

---

## Phase 4 — the memory squeeze.

One run per arm at the nominal rate with the gateway's memory limit halved from
2 Gi to 1 Gi. Heap follows automatically: the base image sets
`-XX:MaxRAMPercentage=75.0`, native `-XX:MaximumHeapSizePercent=75`.

- [ ] edgy, scg, and native if it passed A
- [ ] Reported as pass/fail against the §5.1 criterion plus percentiles for
      whichever arms pass. **Not a sweep.**

Change the limit in `k8s/gateways.yaml` and `kubectl apply -k .` — *not*
`kubectl set resources`, which bypasses kustomize. Put it back afterwards.

Expect: Edgy held 140–163 MiB at 18000 req/s and 160–175 at 8100, while SCG
reached 541 MiB and was still climbing. That contrast is the paragraph.

---

## Phase 5 — scenario B, transforming POST. Full protocol.

**No code has to be written.** Both gateways and the backend already implement
it: `POST /api/lookup`, Edgy via `RequestJsonObjectBodyModifier` +
`ResponseJsonObjectBodyModifier`, SCG via `modifyRequestBody` +
`modifyResponseBody`. `scripts/smoke.sh` already asserts they behave
identically. What is missing is only the `b-*.hf.yaml` files.

- [ ] Write `b-direct.hf.yaml`, `b-edgy.hf.yaml`, `b-scg.hf.yaml`. Copy the
      `a-*` files; keep `sharedConnections: 8192`, `maxSessions: 50000`,
      `threads: 6` **identical** — they are matched variables, not per-arm
      tuning. Keep the 2xx validator.
- [ ] The direct arm applies the same JSON transformation inside the Hyperfoil
      scenario, so the backend receives an identical request. Body: the
      `LookupRequest` record `{"id": N}`, plus the `via` field the gateway would
      have added.
- [ ] Throughput bisection, three arms. Use A's maxima as the **upper** bound and
      bisect down — body accumulation is the expensive path, so expect lower.
- [ ] Latency at B's own nominal rate (0.9 × B's weakest arm), 3 reps, 10 min.

**Do not add the §4.2 database-reset protocol.** It assumed a `POST
/api/villains` that inserts rows. The implemented endpoint reads by id and never
writes — the Javadoc says so explicitly, for exactly this reason. No table
grows, no restore is needed, arm order is not a confound. Say in the chapter
that the transforming route is read-backed so the write path is not a confound;
an examiner will otherwise ask.

---

## Phase 6 — scenario C, reduced. TLS + discovery + load balancing.

Appendix material, so: throughput bisection at full precision, but latency at
**one repetition with a 5-minute steady phase**, not three of ten. The appendix
must say the repetition count differs.

- [ ] **Resolve this first, 15 minutes, before committing to C.** Can Hyperfoil
      be made to trust the private CA for the direct arm, which talks TLS
      straight to `backend-lb:8443`? Both gateways already trust
      `tls/ca-cert.pem`; the generator is the open question. Try the benchmark's
      own `http.*` TLS settings, then `-Djavax.net.ssl.trustStore` in the
      Hyperfoil pod's `JAVA_OPTS`. If both fail, drop the C direct arm and make
      C a two-arm gateway-only comparison — still publishable in an appendix,
      but **decide it now, not mid-phase.**
- [ ] Consul back to 1 replica. `reset-cell.sh` does this automatically for any
      arm named `c-*`.
- [ ] Verify both endpoints: `kubectl get endpoints backend-lb -n skacelik-ns`
- [ ] Write `c-*.hf.yaml`, bisect, then one 5-minute latency run per arm.

C changes three things at once and **supports no causal claim** about TLS, load
balancing or discovery individually. The appendix text has to say so.

---

## If the week compresses

Cut in this order, per `RUN-PLAN.md` §9: C's latency runs, then C entirely, then
B's third repetition, then B's steady phase to 5 minutes. **Do not cut phase 1
or the CPU attribution captures** — they are what make everything else
admissible.

---

## Open questions for the supervisor

- Do appendices count against the 70 NS limit? It decides whether C's tables,
  the CDF plots and the full benchmark YAML can go to an appendix or be cut.
  Ask before drafting, not after.
- Is scenario C's reduced repetition count acceptable for appendix material,
  given everything in the body runs at three?

## Known stale bits

- `docs/RUNBOOK.md` §E2 still refers to `benchmarks/scenario-a.hf.yaml`, which
  was split into the four `a-*.hf.yaml` files. §E3 and §F use `:latest` for the
  CLI image — harmless, the CLI is not in the measurement path, but get its
  version into T1.
- `kustomization.yaml` pins all four images to `ee77d00`. `PLAN-CH7.md` §6.4
  wants a **tag** rather than a loose SHA, pinned for the whole campaign and
  quoted in the chapter. If Edgy moves mid-campaign, everything re-runs.
