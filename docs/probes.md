# Health probes

Probes are how Kubernetes knows whether a container is actually *working*, not just *running*.

| Probe | Question | On failure |
|---|---|---|
| **readinessProbe** | Can this pod take traffic right now? | Removed from Service endpoints (gets no traffic). Not counted as Ready by rolling updates. |
| **livenessProbe** | Is this pod still alive? | Container is restarted. |
| **startupProbe** | Has a slow app finished starting? | Holds off the other probes until it passes. |

## podinfo's probes

podinfo exposes `/readyz` and `/healthz` for exactly this:

```yaml
readinessProbe:
  httpGet:
    path: /readyz
    port: 9898
  initialDelaySeconds: 2
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /healthz
    port: 9898
  initialDelaySeconds: 5
  periodSeconds: 10
```

## Minecraft's probe

```yaml
readinessProbe:
  exec:
    command: ["mc-health"]   # ships with the itzg image; pings the server
  initialDelaySeconds: 30
  periodSeconds: 10
```

That's why a fresh Minecraft pod shows `0/1 Running` for ~40 seconds before `1/1`: the JVM is up, but the world isn't loaded yet, so it gets no traffic.

## Why readiness probes make rolling updates safe

A Deployment rollout replaces old pods only as new ones become **Ready**. Without a readiness probe, "Ready" just means *the process started*.

This was tested directly by starving podinfo of memory (limit 8Mi — it needs ~15–20Mi):

| | Without readiness probe | With readiness probe |
|---|---|---|
| New pod counted Ready | The instant the container started | Only after `/readyz` passed (never) |
| Old pods | All replaced | Kept running |
| Users (`curl` loop) | **503** — outage | **200** — no impact |
| Deployment's view | "Rollout succeeded" | Rollout stuck → `ProgressDeadlineExceeded` after 10 min |
| Argo CD | Synced / Progressing | Synced / Progressing → Degraded |

!!! tip "Lesson"
    A rolling update is only as safe as your readiness probe. Without one, Kubernetes can't tell a working pod from one that's about to crash.

## Reading an OOM kill

```bash
kubectl describe pod -n podinfo <pod> | grep -A5 "Last State"
```

`Reason: OOMKilled`, `Exit Code: 137` — 137 is 128 + 9 (SIGKILL): the kernel killed the process for exceeding its memory limit. Repeated failures lead to `CrashLoopBackOff`, with restart delays doubling (10s, 20s, 40s… up to 5 min).
