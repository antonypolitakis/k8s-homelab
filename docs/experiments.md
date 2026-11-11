# Experiments

A lab notebook: what was tried, what happened, and what it taught.

## Project 1 — Minecraft

### Delete the pod

```bash
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed    # note it
kubectl delete pod -n minecraft -l app=minecraft
kubectl get pods -n minecraft -w                                 # wait for 1/1
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed    # compare
```

**Result:** new pod name, same seed (`-469892510018111195` before and after).
**Lesson:** pods are disposable; the PersistentVolume isn't. The Deployment noticed 0 of 1 desired pods and replaced it — nobody "restarted" anything.

## Project 5 — GitOps

### Push a change

Added `MOTD: "Deployed by Argo CD"` to the Minecraft Deployment and pushed. Argo CD rolled it out; `printenv MOTD` showed it. No `kubectl apply`.

### Change the cluster by hand

```bash
kubectl scale deploy minecraft -n minecraft --replicas=0
```

**Result:** a replacement pod was `Pending` within **0 seconds**. Argo CD watches the cluster continuously (only Git is polled), so drift is reverted almost instantly.
**Side lesson:** the old pod was still terminating while the new one started — both had the world mounted for ~1s. `Recreate` only applies to rollouts. See [Minecraft](apps/minecraft.md).

### App of apps

Added a `root` Application watching `argocd/apps/`. Then added podinfo with **only `git push`** — root created the Application, which created the app.

### Rebuild everything

```bash
kind delete cluster --name homelab && ./bootstrap.sh
```

**Result:** all apps back from Git in ~3 minutes; Minecraft had a **new** seed.
**Lesson:** Git holds configuration, not data. Data needs storage outside the cluster, and backups.

## Project 2 — Break things on purpose

### Kill a pod under load

`hey -z 60s -c 5` through a port-forward while deleting a podinfo pod:

```
[200]  498,349 responses        ~18,800 req/s, 0.3 ms median
EOF    5                         the 5 in-flight requests when the pod died
connection refused  632,227      the port-forward exited; failures are instant
```

**Lesson:** the *app* never went down — the other replica kept serving. The *route* (a port-forward pinned to one pod) did. Deleting the *other* pod showed zero errors.

### Drain a node

```bash
kubectl drain homelab-worker --ignore-daemonsets --delete-emptydir-data
```

**Result:**

- podinfo's pod on that node was replaced on `homelab-worker2` in **~7s**.
- Minecraft's replacement stayed **`Pending`**:

```
0/3 nodes are available:
  1 node(s) didn't match PersistentVolume's node affinity,   ← worker2: data isn't here
  1 node(s) had untolerated taint(s),                        ← control-plane
  1 node(s) were unschedulable.                              ← worker: cordoned
```

- Argo CD's own pods were evicted too and moved to worker2.

After `kubectl uncordon homelab-worker`, Minecraft came back on the same node with the same seed.
**Lesson:** a pod can only move if its data can move with it. See [Storage](storage.md).

### Invalid manifest

A typo — `memory: 8i` — was pushed.
**Result:** Argo CD showed **OutOfSync / Healthy** and retried: `unable to parse quantity's suffix`. The API server rejected the change; the running pods were untouched.
**Lesson:** invalid manifests never reach your pods.

### Starve podinfo of memory — without probes

Memory limit 8Mi (needs ~15–20Mi).
**Result:** both pods replaced by crash-looping ones (`OOMKilled`, exit 137). `curl` → **503**. The Deployment reported the rollout as *successful*.

### …and with a readiness probe

Same change, after adding `/readyz` readiness and `/healthz` liveness probes.
**Result:** one new pod crash-looped; the two old pods kept serving; `curl` → **200** throughout.

```
ReplicaSet           DESIRED  READY
podinfo-5b84f7886c      2       2     ← good version, still serving
podinfo-66fb8ddcc7      1       0     ← starved version, stuck
```

**Lesson:** a rolling update is only as safe as its readiness probe. See [Health probes](probes.md).

### Autoscale under load

metrics-server + an HPA (2–8 pods at 50% CPU), then `hey -z 180s -c 50`.
**Result:** 2 → 4 → 8 pods in 30s; stayed at ~565% CPU at the cap; back to 2 five minutes after the load stopped.
**Lessons:** scale up fast, scale down slowly; a closed-loop load generator raises demand as fast as you add capacity. See [Autoscaling](autoscaling.md).

## Project 3 — Ingress

Traefik via Argo CD; `argocd.localhost` and `podinfo.localhost` with no port-forwards. Requests alternate between podinfo replicas. A Traefik setting change (`ingressEndpoint.ip`) was rolled out by Argo CD in place — no rebuild. See [Ingress](ingress.md).

## Project 5 — Argo CD manages itself

Added `argocd/apps/argocd.yaml` (Argo CD's own chart + `argocd/values.yaml` from this repo), first with manual sync.
**Result:** OutOfSync for 54 resources — only the missing tracking annotation; `kubectl diff` of the rendered chart showed no real changes. Synced with **no pod restarts**. Then enabled auto-sync and pushed `server.replicas: 2`: Argo CD scaled its own server to two pods.
**Lesson:** "OutOfSync" doesn't always mean "different" — check the diff before you sync, especially on something you can't afford to break. See [GitOps](gitops.md#argo-cd-manages-itself).

## Project 3 — HTTPS with cert-manager

Made a name-constrained CA on the Mac with `openssl`, trusted it in the System keychain, loaded it as a Secret, and added cert-manager + a `ClusterIssuer` through Argo CD. Annotated the two Ingresses.
**Result:** both certificates issued within seconds of the sync; `https://argocd.localhost` shows a padlock. Argo CD's TLS was switched on by committing to its own `values.yaml` — self-management in action.
**Lesson:** the private key is the one thing that can't go in Git; everything else (issuer, which hosts get certs) can. See [HTTPS](https.md).

## Docs as an in-cluster app

A pod with git-sync, mkdocs and nginx serving this wiki at `https://docs.localhost`.
**Result:** first try crash-looped — git's "dubious ownership" check (root-owned volume, non-root git-sync). Fixed by giving git-sync a subfolder it owns. After that, a docs-only push went live in about a minute with no new pod and no Argo CD sync; a broken link was rejected and the old site kept serving.
**Lessons:** sidecars share work through volumes; a readiness probe that checks for *content* (not just a listening port) keeps an empty site out of rotation. See [Docs site](apps/docs.md).

## Project 4 — Monitoring

### Watch the HPA in Grafana

kube-prometheus-stack via Argo CD; three Explore queries (current replicas, desired replicas, CPU ÷ request) during `hey -z 5m -c 50`.
**Result:** desired jumped to 8 while current was at 4 — the decision ahead of the pods. CPU plateaued at ~5.5× the request with 8 pods (capped at `maxReplicas`). After the load, CPU took about a minute to read 0 (the `rate(...[1m])` window), then replicas stayed at 8 for nearly 5 minutes.
**Lesson:** graphs with history show *sequences* — cause, reaction, delay — that a live `kubectl -w` hides.

### Shorten the scale-down window (300s → 60s)

One change in Git: `behavior.scaleDown.stabilizationWindowSeconds: 60`. Same test again, measured in Prometheus:

| Window | CPU back under target | desired → 2 |
|---|---|---|
| 300s | 14:08:06 | 14:12:51 (4m 45s) |
| 60s | 14:24:06 | 14:24:51 (45s) |

**Lesson:** change one thing, observe again. The API server filled in the rest of `behavior` with defaults, which Argo CD knows to ignore.

### App metrics and a dashboard in Git

A hand-written ServiceMonitor for podinfo, Traefik's chart-provided one, and a dashboard JSON in a labelled ConfigMap.
**Result:** both podinfo pods appeared as separate targets within ~30s; the dashboard loaded within seconds of the sync, no restart.

### Grafana's password changed by itself

**Result:** about an hour in, the password in the Secret stopped working. Argo CD's events showed an automated sync that changed only `Secret monitoring-grafana`: the chart generates a random password on every render, and Argo CD can't look up the existing one.
**Fix:** `grafana.admin.existingSecret`, created by `bootstrap.sh`.
**Lesson:** random values in charts drift under GitOps. Read the events before guessing.
