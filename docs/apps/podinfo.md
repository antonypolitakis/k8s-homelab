# podinfo

[podinfo](https://github.com/stefanprodan/podinfo) is a tiny Go web app built for demos: it shows which pod served each request, exposes health endpoints, and is very fast. Here it's the target for breaking things and autoscaling.

- **URL:** <https://podinfo.localhost>
- **Image:** `ghcr.io/stefanprodan/podinfo:6.17.0` (pinned — `latest` would hide which version is running)
- **Namespace:** `podinfo` (created by Argo CD via `CreateNamespace=true`)

## Files — `apps/podinfo/`

| File | What |
|---|---|
| `deployment.yaml` | No `replicas` (the HPA owns it). CPU request 50m, memory 32Mi request / 128Mi limit. Readiness `/readyz`, liveness `/healthz`. |
| `service.yaml` | ClusterIP on port 9898 |
| `ingress.yaml` | `podinfo.localhost` → Service `podinfo:9898` |
| `hpa.yaml` | 2–8 replicas at 50% CPU |
| `kustomization.yaml` | Lists the above; sets namespace `podinfo` |

## Useful commands

```bash
curl -s http://podinfo.localhost | grep hostname       # which pod answered
kubectl get pods,hpa -n podinfo
kubectl top pods -n podinfo
kubectl rollout history deploy/podinfo -n podinfo      # previous versions (old ReplicaSets)
```

See [Health probes](../probes.md) and [Autoscaling](../autoscaling.md) for what's been learned with it.
