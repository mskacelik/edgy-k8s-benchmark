# Differences between Edgy and Spring Cloud Gateway in this benchmark

Everything that is not the subject of the comparison has to be equal, and a
difference nobody noticed cannot be corrected once the runs are done. This file
is the full list: what was unequal and got fixed, and what cannot be made equal
and is therefore declared.

Feeds the environment table of §7.2 and the threats to validity of §7.7.

## Part 1 — found unequal, now matched

| # | What | How it was found | Fix |
|---|---|---|---|
| 1 | **Netty I/O transport.** Spring Boot bundles `netty-transport-native-epoll` for `linux-x86_64`; Quarkus ships none and defaults `prefer-native-transport=false`. On the cluster, Reactor Netty would have used epoll while Vert.x used Java NIO. | Reading the built artefacts. Invisible locally: an arm64 workstation has no epoll jar for either side. | `-Dreactor.netty.native=false` in the SCG image. Both on NIO. |
| 2 | **Downstream HTTP version.** Quarkus enables h2c by default, Spring Boot does not. Edgy answered HTTP/2 prior-knowledge requests with 200; SCG reset the connection. | `curl --http2-prior-knowledge` against both. | `quarkus.http.http2=false`. `smoke.sh` asserts both now refuse. |
| 3 | **Observation instrumentation.** `spring.cloud.gateway.server.webflux.observability.enabled` defaults to **true** and instruments every request. `metrics.enabled` was already false, so checking only metrics would have missed it. | Reading SCG's `spring-configuration-metadata.json`. | Set false. Edgy's logging, metrics and tracing are all off and it has no Micrometer or OTel dependency. |
| 4 | **Service-discovery polling.** Stork refreshes every 5 minutes by default; Spring's Consul catalog watch runs every second. Background work in the gateway process, on one side far more than the other. | Reading Stork's `CachingServiceDiscovery` default against Spring's. | Both driven from one value, `DISCOVERY_REFRESH`, default 300s. Spring's LoadBalancer cache TTL matched too. |
| 5 | **Heap sizing had drifted out of the shared base image** for SCG, because compose overrode `JAVA_OPTS_APPEND` to add `reactor.netty.ioWorkerCount`. | Review of the compose file against the base image. | `ioWorkerCount` is set in `ScgApplication.main` from the same `EVENT_LOOPS` variable Edgy uses. The base image is the only place heap is written. |

Verified equal at runtime, not just in configuration: both gateways run the same
JVM flag set with G1 and `MaxRAMPercentage=75.0`, and each has four event-loop
threads (`vert.x-eventloop` ×4, `reactor-http-nio` ×4).

## Part 2 — cannot be matched, declared

### 2.1 Behaviour at pool exhaustion

Reactor Netty's fixed pool admits `2 × max-connections` pending acquisitions and
then fails requests outright. Vert.x queues without bound. No Spring property
exposes that limit.

So at the ceiling the two gateways fail differently: Spring Cloud Gateway turns
queueing into non-2xx responses, which the §5.1 criterion counts as a failed
run, while Edgy's latency simply grows until the p99 bound is breached. §5.1
already requires recording which failure mode ended each arm. **The chapter must
not present the two ceilings as like-for-like without saying this.**

### 2.2 Connection-pool scope

Edgy creates one pool per origin identifier; Reactor Netty creates one per
remote address. Routes A and B name different origins but the same host, so
driving them together gives Edgy two pools of 64 and Spring one.

The scenarios run separately, so this never fires. But the socket count used to
confirm pool parity must be taken **per scenario**, or it reads 128 against 64
and looks like a misconfiguration.

### 2.3 Error-path response bodies on route B

Statuses agree everywhere, and the three success paths are byte-identical. The
error bodies are not:

| Input | Edgy | Spring Cloud Gateway |
|---|---|---|
| unknown id | 404, body `{"gateway-timestamp":"…"}` | 404, empty body |
| missing id | 400, body `{"gateway-timestamp":"…"}` | 400, empty body |
| undecodable request body | **502** | **400** |

Edgy's JSON modifier treats an empty upstream error body as `{}` and so emits a
timestamp object; Spring's passes the blank through. The 502 is Edgy mapping a
decode failure to a gateway error rather than passing it on.

The benchmark never sends any of these shapes. `scripts/smoke.sh` pins all of
them per gateway so that a change to either is noticed. Changing Edgy's
behaviour is extension work and out of scope for the benchmark.

### 2.4 Native mode

The native Edgy arm uses a different collector and a different heap knob from
the JVM arms, and is built on a Mandrel JDK 25 builder while the JVM images are
JDK 21. None of this can be matched — it is a different runtime, which is the
point of the arm. Reported in the environment table as native-only rows.

### 2.5 Inherited JVM flags

`run-java.sh` injects more than the design records: `-XX:MinHeapFreeRatio=10`,
`-XX:MaxHeapFreeRatio=20`, `-XX:GCTimeRatio=4`, `-XX:AdaptiveSizePolicyWeight=90`
and `-XX:+ExitOnOutOfMemoryError`. Parity holds — both gateways get exactly the
same set, verified on the running command lines — but these make G1 return
memory aggressively and materially shape its behaviour at these heap sizes. They
were inherited rather than chosen, so they belong in the environment table
verbatim rather than being summarised as "G1".

### 2.6 Netty version

4.1.135 on Spring Cloud Gateway, 4.1.138 on Edgy. Both come from their
framework BOMs and pinning either to the other's would mean overriding a
supported combination.

## Part 3 — divergences outside the measured path

Known, harmless, listed so nobody rediscovers them as bugs.

- Multi-segment wildcards: `GET /api/items/1/extra` gives an empty 404 from
  Edgy, which percent-encodes the separator so the upstream sees
  `/items/1%2Fextra`, against the backend's HTML 404 through Spring.
- Bare `GET /api/items`: matches Spring's `/api/items/**` and is forwarded
  unrewritten; does not match Edgy's `/api/items/*` at all. Same status, from
  different sources.
- Wrong method on `/api/lookup`: Vert.x HTML from Edgy, Spring JSON from SCG.
- Edgy sends a `date` response header and Spring does not — about 37 bytes per
  response on one side.
- Request buffer limits are unmatched (Quarkus 10 MB, Spring 256 KB) and set on
  neither side. Cannot fire at a 300-byte body.
