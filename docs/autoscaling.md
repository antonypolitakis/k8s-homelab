# Autoscaling

podinfo scales between 2 and 8 pods based on CPU, automatically.

```
metrics-server ──(CPU per pod, every 15s)──► HorizontalPodAutoscaler
                                                  │ "average CPU above target → add pods"
                                                  ▼
                                             Deployment podinfo  (replicas: 2 … 8)
```

## The pieces

| Piece | What it is | Who provides it |
|---|---|---|
| **HorizontalPodAutoscaler (HPA)** | A built-in Kubernetes resource that adjusts a Deployment's `replicas` | Kubernetes itself |
| **metrics-server** | Scrapes CPU/memory from every node's kubelet and serves it via the `metrics.k8s.io` API | A Kubernetes add-on (kubernetes-sigs) — **not installed by default** in kind |
| **Argo CD** | Delivers both from Git | — it makes no scaling decisions |

metrics-server keeps only the **latest** values, in memory. It has no history, graphs or alerts — that's [Prometheus/Grafana's job](monitoring.md). It also powers `kubectl top`.

## metrics-server

[`argocd/apps/metrics-server.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/metrics-server.yaml) — chart **3.14.0** (v0.9.0), into `kube-system`:

```yaml
helm:
  valuesObject:
    args:
      - --kubelet-insecure-tls
```

kind's kubelets use self-signed certificates; `--kubelet-insecure-tls` tells metrics-server not to verify them. Fine for a local lab, not for production.

```bash
kubectl top nodes
kubectl top pods -n podinfo
```

## The HPA

[`apps/podinfo/hpa.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/apps/podinfo/hpa.yaml):

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60   # default 300
```

**`averageUtilization: 50`** is a percentage of the pod's **CPU request**. podinfo requests `50m` (5% of a core), so the HPA adds pods when the average pod uses more than **25m**. A small request makes the demo easy to trigger.

The HPA's core formula:

```
desired replicas = ceil( current replicas × current utilization / target utilization )
```

…clamped to `[minReplicas, maxReplicas]`, and to at most doubling per step when scaling up.

## Giving the HPA ownership of `replicas`

`replicas` was **removed** from `apps/podinfo/deployment.yaml`. If Git said `replicas: 2` while the HPA wanted 6, Argo CD's self-heal would reset it, the HPA would raise it again, and so on. With the field gone, the HPA owns it.

## Timing

- **Scale up:** fast — evaluated every ~15s, may double each step.
- **Scale down:** slow by default — a **5-minute stabilization window**: the HPA uses the *highest* recommendation from the last 5 minutes, so a brief lull doesn't remove pods that are needed again moments later. Here it's set to **60s**.

The API server fills in the rest of `behavior` with defaults — check with:

```bash
kubectl get hpa podinfo -n podinfo -o jsonpath='{.spec.behavior.scaleDown}'; echo
# {"policies":[{"periodSeconds":15,"type":"Percent","value":100}],"selectPolicy":"Max","stabilizationWindowSeconds":60}
```

`100%` per `15s` means all surplus pods may go in one step (8 → 2). A policy like `type: Pods, value: 1, periodSeconds: 30` would step down one pod at a time instead.

### 300s vs 60s, measured in Prometheus

Same load test (`hey -z 5m -c 50`), before and after the change:

| Window | CPU back under target | desired → 2 | Paying for idle pods |
|---|---|---|---|
| 300s (default) | 14:08:06 | 14:12:51 | **4m 45s** |
| 60s | 14:24:06 | 14:24:51 | **45s** |

Scale-up was identical both times (2 → 8 within ~60s). The trade-off: a shorter window saves idle capacity but reacts to every dip in bursty traffic.

## Watching it in Grafana

The **podinfo autoscaling** dashboard shows requests, latency, replicas and CPU on one screen; see [Monitoring](monitoring.md#dashboards-as-code). What it makes visible that `kubectl -w` can't:

- **desired leads current** — the HPA's decision, then the pods catching up (scheduling, start-up, readiness).
- **Resolution** — each dot is one scrape; anything between dots (e.g. a brief 4-replica step) is invisible.
- **The window** — CPU at 0, replicas still flat at the maximum.

## Load testing

```bash
# Tab 1                                   # Tab 2
kubectl get hpa -n podinfo -w             kubectl get pods -n podinfo -w

# Tab 3 — closed loop: 50 requests always in flight, as fast as possible
hey -z 180s -c 50 https://podinfo.localhost

# or open loop: a fixed ~500 req/s (10 workers × 50 req/s each)
hey -z 180s -c 10 -q 50 https://podinfo.localhost
```

### What the closed-loop test showed

| Time | CPU vs 50% target | Replicas |
|---|---|---|
| idle | 2% | 2 |
| +40s | 549% | 2 |
| +55s | 1499% | **4** |
| +70s | 957% | **8** (max) |
| during | ~565% | 8 |
| test ends | 2% | 8 (waiting) |
| +5 min | 2% | **2** |

Quadrupling the pods **didn't** bring per-pod CPU down. `hey -c 50` sends a new request the moment a reply arrives, so more capacity just means more throughput — demand rises with supply. The HPA wanted ~90 pods and was capped at 8. Real users arrive at a roughly fixed rate; the `-q` test models that, and the HPA settles at a stable count in between.

## Stopping a test

Press **Ctrl+C** on `hey`. The HPA scales back down on its own after the stabilization window. Don't `kubectl scale` or `kubectl delete hpa` — Argo CD will put them back.

To pause autoscaling without removing it, set `maxReplicas` equal to `minReplicas` in Git.
