# Runbook

Step by step. Run from the repository root.

```sh
cd ~/dev/ibm/edgy-k8s-benchmark
```

---

## A. One-time setup

### A1. Generate TLS certificates

```sh
./tls/generate.sh
```

Makes `tls/ca-cert.pem`, `tls/server-cert.pem`, `tls/server-key.pem`. The
manifests read them. Not in git.

### A2. Log in to the registry

```sh
echo $GITHUB_TOKEN | docker login ghcr.io -u mskacelik --password-stdin
```

Token needs `write:packages`.

### A3. Check the cluster

```sh
kubectl config use-context kuba-cluster
kubectl get pods -n skacelik-ns
```

Must connect without errors.

---

## B. Build and push images

### B1. Build locally (JVM images only, fast)

```sh
./scripts/build-images.sh
```

Builds 4 `linux/amd64` images, tagged with Edgy's short commit SHA. Refuses to
run if the Edgy checkout is dirty.

### B2. Push them

```sh
./scripts/build-images.sh --push
```

### B3. Build the native image (GitHub Actions, needed for the native arm)

```sh
gh workflow run images.yml -f edgy_ref=main -f native=true -f push=true
gh run watch
```

Builds everything including native on an amd64 runner. Native cannot be built
on your Mac at usable speed.

### B4. Note the tag

```sh
git -C ~/dev/ibm/edgy rev-parse --short HEAD
```

This is the image tag.

---

## C. Deploy

### C1. Set the tag in the manifests

Edit `kustomization.yaml`, change the three `newTag:` lines to the tag from B4.

### C2. Preview what would be applied

```sh
kubectl apply -k . --dry-run=server
```

Changes nothing. Expect one error about `rolebindings ... not found` — that is
a dry-run artefact, because the Role is not really created. Any other error is
real.

### C3. Apply

```sh
kubectl apply -k .
```

Creates Postgres, Consul, both backends, both gateways (at 0 replicas),
Hyperfoil, and the config.

### C4. Wait for the database

```sh
kubectl rollout status deploy/postgres -n skacelik-ns --timeout=15m
```

Seeds 1,000,000 rows on first start. Slow. Ready means the data is in.

### C5. Wait for the rest

```sh
kubectl rollout status deploy/consul deploy/backend-a deploy/backend-b deploy/hyperfoil -n skacelik-ns
```

### C6. Check Consul registered both backends

```sh
kubectl exec -n skacelik-ns deploy/consul -- \
  wget -qO- http://localhost:8500/v1/catalog/service/backend-service
```

Must list `backend-a` and `backend-b`.

---

## D. Pick the arm to measure

Only one gateway runs at a time.

### D1. Edgy

```sh
kubectl scale deploy/scg-gateway --replicas=0 -n skacelik-ns
kubectl scale deploy/edgy-gateway --replicas=1 -n skacelik-ns
kubectl rollout status deploy/edgy-gateway -n skacelik-ns
```

### D2. Spring Cloud Gateway

```sh
kubectl scale deploy/edgy-gateway --replicas=0 -n skacelik-ns
kubectl scale deploy/scg-gateway --replicas=1 -n skacelik-ns
kubectl rollout status deploy/scg-gateway -n skacelik-ns
```

### D3. Direct (no gateway)

```sh
kubectl scale deploy/edgy-gateway deploy/scg-gateway --replicas=0 -n skacelik-ns
```

Point the benchmark at `http://backend-a:8080` instead.

### D4. Check the arm answers

```sh
kubectl run curl --rm -it --restart=Never -n skacelik-ns \
  --image=curlimages/curl --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"args":["-s","-o","/dev/null","-w","%{http_code}\n","http://edgy-gateway:8080/api/items/1"]}]}}'
```

Prints `200`.

---

## E. Run a benchmark

### E1. Open a tunnel to Hyperfoil

```sh
kubectl port-forward -n skacelik-ns svc/hyperfoil 8090:8090
```

Leave running. Open a second terminal for the rest.

### E2. Edit the benchmark

Open `benchmarks/scenario-a.hf.yaml`. Set `host:` to the arm you scaled up.

Then set the rate you are testing in **three** places, not one:

| Phase | Key | Value for target rate *R* |
|---|---|---|
| `rampup` | `initialUsersPerSec` | 0.1·*R* |
| `rampup` | `targetUsersPerSec` | *R* |
| `hold` | `usersPerSec` | *R* |
| `steady` | `usersPerSec` | *R* |

The warm-up is deliberately proportional to *R*. Leaving `rampup` or `hold` at a
previous rate while changing `steady` warms each bisection candidate differently
and quietly invalidates the search — it is the easiest mistake to make in this
file, and it leaves no trace in the report.

Also set `steady`'s `duration:` — `3m` for a throughput bisection step, `10m` for
a latency run.

### E3. Start the CLI

```sh
docker run --rm -it --network host \
  -v "$PWD/benchmarks:/b" quay.io/hyperfoil/hyperfoil:latest cli
```

### E4. Connect, upload, run

```
connect localhost:8090
upload /b/scenario-a.hf.yaml
run scenario-a
```

Agent pods appear, the run executes, pods are deleted.

### E5. Watch it

```
status
```

### E6. See the result

```
stats
```

Percentiles for the steady phase.

---

## F. Fetch results

### F1. Export the run as JSON

```
export 0001 -f json -d /b/results
```

Inside the Hyperfoil CLI. `0001` is the run id that `run` printed.

### F2. Export as HTML

```
report 0001 -d /b/results
```

### F3. Files land on your machine

```sh
ls benchmarks/results
```

The `/b` mount from E3 is your `benchmarks/` directory.

---

## G. While a run is going, record the evidence

A throughput number without this is not reportable — it does not say whether
the gateway or the backend was the limit.

### G1. CPU of everything

```sh
kubectl top pods -n skacelik-ns
```

Run it a few times during the steady phase. The gateway should be near its
limit and the backends and Postgres clearly below theirs.

### G2. Memory of the gateway

```sh
kubectl top pod -n skacelik-ns -l role=gateway
```

This is the RSS figure for the footprint table.

### G3. Startup time

```sh
kubectl logs -n skacelik-ns deploy/edgy-gateway | grep "started in"
```

---

## H. Between runs

### H1. Fresh gateway pod for each repetition

```sh
kubectl rollout restart deploy/edgy-gateway -n skacelik-ns
kubectl rollout status deploy/edgy-gateway -n skacelik-ns
```

Each repetition must use a new pod, so the spread includes deployment variance.

### H2. Re-seed the database (only if something wrote to it)

```sh
kubectl rollout restart deploy/postgres -n skacelik-ns
kubectl rollout status deploy/postgres -n skacelik-ns --timeout=15m
```

Nothing in the benchmark writes, so this is rarely needed.

---

## I. The memory squeeze

### I1. Halve the gateway's memory

```sh
kubectl set resources deploy/edgy-gateway -n skacelik-ns \
  --requests=memory=1Gi --limits=memory=1Gi
```

Heap is a percentage of the limit, so it follows automatically.

### I2. Re-run the latency phase, then put it back

```sh
kubectl set resources deploy/edgy-gateway -n skacelik-ns \
  --requests=memory=2Gi --limits=memory=2Gi
```

---

## J. Clean up

### J1. Stop the gateways (keeps data and quota free)

```sh
kubectl scale deploy/edgy-gateway deploy/scg-gateway --replicas=0 -n skacelik-ns
```

### J2. Delete everything this project created

```sh
kubectl delete -k .
```

### J3. Check nothing is left

```sh
kubectl get all -n skacelik-ns
```

### J4. Delete stray agent pods, if a run crashed

```sh
kubectl delete pods -n skacelik-ns -l role=agent
```

### J5. Local cleanup

```sh
docker compose down -v
```

---

## K. Local smoke test (no cluster)

### K1. Start everything locally

```sh
docker compose up -d --build
```

### K2. Check both gateways behave identically

```sh
./scripts/smoke.sh
```

Must print `all checks passed`. Run this after any change, before pushing images.

### K3. Run the backend tests

```sh
./mvnw -pl backend-service test
```

---

## Things that will bite

- **The namespace enforces restricted PodSecurity.** Every pod needs
  `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`
  and `seccompProfile: RuntimeDefault`. The manifests have these. Any pod you
  create by hand needs them too — see D4 for the pattern.
- **Hyperfoil's agent pods may be rejected for the same reason.** The controller
  builds those pod specs itself and this repo cannot add a securityContext to
  them. If `run` fails with a PodSecurity error, fall back to standalone mode:
  one Hyperfoil pod generating load by itself, no `agents:` block. You lose
  scale-out and must then check the generator is not the bottleneck.
- **Quota is 20 CPU and 40 GiB of requests.** The deployed set uses about 14 CPU
  with one gateway up. Each agent pod takes 1 more. Scale the unused gateway to
  zero.
- **`kubectl top` needs metrics-server.** If it errors, read CPU from the
  Rancher UI instead.
- **Never target an Ingress or Route.** Benchmark traffic goes to the ClusterIP
  Service, or an extra proxy ends up in the measurement.
