# Monitoring (Prometheus + Grafana)

| URL | What |
|---|---|
| <https://grafana.localhost> | Dashboards — user `admin`, password below |
| <https://prometheus.localhost> | Raw metrics, PromQL queries, scrape targets (**Status → Targets**) |
| <https://alertmanager.localhost> | Firing alerts |

```bash
# Grafana password (new on every rebuild)
kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

## What's installed

One Argo CD Application, [`argocd/apps/monitoring.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/monitoring.yaml): the community Helm chart **kube-prometheus-stack 93.2.0** into namespace `monitoring`.

| Component | Job |
|---|---|
| **Prometheus** | Visits every target every 30s, stores the numbers (3 days here) |
| **Grafana** | Draws graphs by sending PromQL queries to Prometheus. Stores nothing itself. ~25 dashboards come built in. |
| **Alertmanager** | Receives alerts from Prometheus' rules, groups them, would send notifications |
| **Prometheus Operator** | A controller that runs Prometheus/Alertmanager and turns `ServiceMonitor` resources into scrape config |
| **kube-state-metrics** | Reads Kubernetes objects (Deployments, HPAs, pods…) and publishes them as numbers |
| **node-exporter** | One pod per node (DaemonSet): the machine's CPU, memory, disk, network |

## Why each setting is there

| Setting | Why |
|---|---|
| `kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy.enabled: false` | kind binds these to `127.0.0.1` inside the node, so they can't be scraped. Left on, their "Down" alerts fire forever. |
| `prometheusOperator.admissionWebhooks.certManager.enabled: true` | The operator's webhook needs a TLS cert. The default makes it with Helm hook Jobs, which sit badly with Argo CD; cert-manager does it instead. |
| `prometheus-node-exporter.hostRootFsMount.enabled: false` | Avoids a mount-propagation crash on Docker-based nodes like kind's. |
| `prometheus.prometheusSpec.*SelectorNilUsesHelmValues: false` | By default Prometheus only watches this chart's own ServiceMonitors. Off = it watches every ServiceMonitor in the cluster (needed for podinfo and Traefik). |
| `prometheus.prometheusSpec.retention: 3d` | Keep 3 days of history. |
| `grafana.admin.existingSecret: grafana-admin` | Password from a Secret made by `bootstrap.sh`. See [the random-password trap](#the-random-password-trap). |
| `grafana.testFramework.enabled: false` | Drops a Helm *test* pod Argo CD has no use for. |
| `*.ingress` with the `homelab-ca` annotation | HTTPS at `*.localhost`, like every other app. The chart writes the Ingresses — no extra files. |
| `ServerSideApply=true` | The Prometheus CRDs are too big for a client-side apply. |

## How the numbers get to a graph

Prometheus **scrapes**: every 30s (15s for podinfo) it makes an HTTP request to each target's `/metrics` page, which is just lines of `name{labels} value`. Each dot on a graph is one scrape.

```
                 ┌─────────────────────────────────────────┐
 containers ───► │ kubelet on every node (built-in cAdvisor) │  CPU/memory per container
                 └─────────────────────────────────────────┘
                 ┌─────────────────────────────────────────┐
 the machine ──► │ node-exporter on every node              │  node CPU, memory, disk
                 └─────────────────────────────────────────┘
                 ┌─────────────────────────────────────────┐        ┌────────────┐  PromQL  ┌─────────┐
 k8s objects ──► │ kube-state-metrics (one pod)             │ ◄──────│ Prometheus │ ◄─────── │ Grafana │
                 └─────────────────────────────────────────┘ scrape └────────────┘          └─────────┘
                 ┌─────────────────────────────────────────┐
 apps ─────────► │ podinfo /metrics, Traefik :9100, …       │  requests, status codes, latency
                 └─────────────────────────────────────────┘
```

### Nodes or pods?

Both — Prometheus calls every target **directly**:

| Target | Address | Where |
|---|---|---|
| kubelet (`/metrics`, `/metrics/cadvisor`, `/metrics/probes`) | `192.168.97.x:10250` | every **node** |
| node-exporter | `192.168.97.x:9100` | every **node** |
| apiserver | `192.168.97.2:6443` | the **control plane** |
| kube-state-metrics, podinfo, Traefik, Grafana, … | `10.244.x.x` | **pods**, wherever they run |

The control plane tells Prometheus *who* to scrape (it watches the API for pods and nodes behind each ServiceMonitor), but the data never passes through it. When the HPA adds podinfo pods, they appear as targets on their own.

`/metrics/probes` on each kubelet reports readiness/liveness probe results — where [probes](probes.md) and monitoring meet.

### Two pipelines

| | metrics-server | Prometheus |
|---|---|---|
| Used by | the HPA, `kubectl top` | Grafana, alerts |
| Keeps | the latest value only | history (3 days) |
| Speed | seconds | 15–60s behind (scrape interval + `rate()` window) |

*metrics-server decides now; Prometheus explains afterwards.* That's why Grafana trails `kubectl get hpa -w` by up to a minute.

## Adding a scrape target: ServiceMonitor

A ServiceMonitor says "scrape the pods behind Services with this label, on this named port". podinfo's — [`apps/podinfo/servicemonitor.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/apps/podinfo/servicemonitor.yaml):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: podinfo
spec:
  selector:
    matchLabels:
      app: podinfo        # the Service must carry this label…
  endpoints:
    - port: http          # …and name its port
      path: /metrics
      interval: 15s       # finer than the 30s default
```

For that to match, [`service.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/apps/podinfo/service.yaml) got `labels: {app: podinfo}` and `name: http` on its port.

Charts often do it for you. Traefik needed two switches in [`argocd/apps/traefik.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/traefik.yaml):

```yaml
metrics:
  prometheus:
    service:
      enabled: true       # Service traefik-metrics on :9100
    serviceMonitor:
      enabled: true
```

Because a ServiceMonitor is a CRD that the monitoring app installs, the podinfo Application also has `SkipDryRunOnMissingResource=true` + `retry` — on a fresh cluster podinfo may sync before the CRD exists.

## Dashboards as code

Anything saved in Grafana's UI lives in Grafana's own storage — an `emptyDir` here, so it's gone when the pod restarts. Dashboards that should last go in Git:

```
apps/dashboards/
├── kustomization.yaml        # configMapGenerator + label grafana_dashboard: "1"
└── podinfo-dashboard.json    # the dashboard (Grafana JSON model)
```

The `dashboards` Application deploys the ConfigMap into `monitoring`. A sidecar container in the Grafana pod watches **all namespaces** for ConfigMaps labelled `grafana_dashboard: "1"`, writes them to disk and tells Grafana to reload — within seconds, no restart. The built-in dashboards arrive the same way.

**podinfo autoscaling** has three rows:

| Row | Panels | Source |
|---|---|---|
| podinfo — what users see | Requests/s by status · latency p50/p95/p99 | podinfo's `/metrics` (probe and scrape requests filtered out) |
| Autoscaling — what Kubernetes does | Replicas (current/desired/min/max) · CPU vs the 50% target | kube-state-metrics, kubelet |
| Traefik — every app at the front door | Requests/s by app · p95 latency by app | Traefik's `/metrics` |

To change it: edit in Grafana → **Export → Export as JSON** → replace `podinfo-dashboard.json` → push. (Editing in the UI alone is lost on restart.)

## Useful PromQL

```promql
# CPU used ÷ CPU requested (what the HPA targets)
sum(rate(container_cpu_usage_seconds_total{namespace="podinfo",container="podinfo"}[1m]))
  / sum(kube_pod_container_resource_requests{namespace="podinfo",resource="cpu"})

# What the HPA has vs wants
kube_horizontalpodautoscaler_status_current_replicas{namespace="podinfo"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="podinfo"}

# Real requests per second, by status code
sum by (status) (rate(http_request_duration_seconds_count{namespace="podinfo",path!~"healthz|readyz|metrics"}[1m]))

# 95th-percentile latency
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="podinfo",path="root"}[1m])))

# Requests per second per app, at the ingress
sum by (service) (rate(traefik_service_requests_total[1m]))
```

`rate(x[1m])` turns an ever-growing counter into "per second, averaged over the last minute" — which is why graphs slope down for a minute after load stops.

**Explore** (compass icon) is the scratchpad for queries: Code mode, paste, **Run query**.

## The random-password trap

Without a password set, the Grafana chart **generates a random one** on every render. Plain `helm` looks up the existing Secret and reuses it; Argo CD renders charts without cluster access, so it gets a **new** random password each time. On the next re-render Argo CD saw the Secret as different, and `selfHeal` overwrote it — but Grafana only reads the password when its database is first created, so the Secret no longer matched the real password.

Fix: `grafana.admin.existingSecret: grafana-admin`, created by `bootstrap.sh` with `openssl rand`, outside Git — the same pattern as the CA key.

!!! tip "General rule"
    Any chart value generated at random — passwords, tokens, self-generated certs — will drift under Argo CD. Set it yourself or point the chart at an existing Secret.

## What survives a rebuild

| Survives (in Git) | Lost |
|---|---|
| The whole stack and its settings, ServiceMonitors, the podinfo dashboard | Metrics history (Prometheus uses an `emptyDir`) |
| | Anything saved only in Grafana's UI |
| | The Grafana password (a new one each rebuild) |

Losing history is fine for a lab. A PersistentVolume for Prometheus (`prometheusSpec.storageSpec`) would keep it across pod restarts, but not across a rebuild — kind's volumes die with the cluster.
