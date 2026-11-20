# Superseded — pre-pinning runs, 17–18 November 2026

**No number in here is reportable.** Kept because the chapter has to be able to
say why a rate was or was not tested, and because two of these runs are still
cited as evidence in planning documents.

These were called `scenario-a-direct`, `scenario-b-edgy` and `scenario-c-scg`,
which is the naming RUN-PLAN.md §1 flags as confusing: they are the three
**arms** of scenario A, not scenarios A, B and C. Renamed to `direct/`, `edgy/`
and `scg/` so nobody reads `scg/` as scenario C.

## Why they are void

They were measured across three different topologies and two different backend
allocations, before the `nodeSelector` pinning of RUN-PLAN.md §2.5 and before
the generator settings were matched across arms (`sharedConnections` was
512 / 1024 / 2048 here, not 8192). Comparing arms measured under different
topologies and different allocations is what PLAN-CH7.md §4.4 forbids.

They also predate the direct arm's path fix: anything here calling
`/api/items/{id}` straight at a backend was answering 404 to every request,
which never touches the database.

## What survives

Brackets, not numbers — and one figure:

- `scg/11000-clean.json` is the source of "SCG reached 541 MiB RSS and was
  still climbing", quoted in RUN-PLAN.md §6 as the basis for expecting SCG to
  struggle in the memory squeeze. It is an order-of-magnitude expectation, not
  a reported measurement. The reportable RSS figures come from the pinned
  `a-*/8100-r*` cells.
- `direct/bisect-10000.json` is the only direct-arm run that ever passed
  anything, under the old topology.

`verdict.py --all` does not score this directory: the per-cell layout it
expects is `<arm>/<rate>-r<rep>/`, and these are loose files.
