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
