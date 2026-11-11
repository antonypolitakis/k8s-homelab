# podinfo

[podinfo](https://github.com/stefanprodan/podinfo) is a tiny Go web app built for demos: it shows which pod served each request, exposes health endpoints, and is very fast. Here it's the target for breaking things and autoscaling.

- **URL:** <https://podinfo.localhost>
- **Image:** `ghcr.io/stefanprodan/podinfo:6.17.0` (pinned — `latest` would hide which version is running)
- **Namespace:** `podinfo` (created by Argo CD via `CreateNamespace=true`)

## Files — `apps/podinfo/`

| File | What |
|---|---|
| `deployment.yaml` | No `replicas` (the HPA owns it). CPU request 50m, memory 32Mi request / 128Mi limit. Readiness `/readyz`, liveness `/healthz`. |
| `service.yaml` | ClusterIP on port 9898, named `http`, labelled `app: podinfo` (so the ServiceMonitor can find it) |
| `ingress.yaml` | `podinfo.localhost` → Service `podinfo:9898` |
| `hpa.yaml` | 2–8 replicas at 50% CPU; 60s scale-down window |
| `servicemonitor.yaml` | Tells Prometheus to scrape every pod's `/metrics` every 15s |
| `kustomization.yaml` | Lists the above; sets namespace `podinfo` |

## Useful commands

```bash
curl -s http://podinfo.localhost | grep hostname       # which pod answered
kubectl get pods,hpa -n podinfo
kubectl top pods -n podinfo
kubectl rollout history deploy/podinfo -n podinfo      # previous versions (old ReplicaSets)
```

## Metrics

podinfo serves Prometheus metrics at `/metrics`:

| Metric | Labels | Use |
|---|---|---|
| `http_requests_total` | `status` | Total requests |
| `http_request_duration_seconds` (histogram) | `method`, `path`, `status` | Request rate (`_count`), latency percentiles (`_bucket`) |

`path` includes `healthz` and `readyz` — the probes, twice a minute per pod — so filter them out (`path!~"healthz|readyz|metrics"`) to see real traffic. Graphed on the **podinfo autoscaling** dashboard; see [Monitoring](../monitoring.md).

See [Health probes](../probes.md) and [Autoscaling](../autoscaling.md) for what's been learned with it.
