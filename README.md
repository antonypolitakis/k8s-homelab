# k8s-homelab

A local Kubernetes learning lab on an Apple Silicon Mac, run the GitOps way:
**this repo is the source of truth, and Argo CD keeps the cluster in sync with it.**
Nothing is deployed with `kubectl apply` except the one-time bootstrap.

```
 git push ──► GitHub (this repo) ◄── polls ── Argo CD ──► kind cluster "homelab"

 browser ──► https://<app>.localhost ──► Traefik (ingress) ──► app Service ──► pods
```

| URL | What |
|---|---|
| https://argocd.localhost | Argo CD UI (user `admin`) |
| https://podinfo.localhost | podinfo demo app (autoscaled) |
| https://docs.localhost | These docs, built from GitHub inside the cluster |
| https://grafana.localhost | Grafana dashboards (user `admin`) |
| https://prometheus.localhost | Prometheus |
| https://alertmanager.localhost | Alertmanager |
| `localhost:25565` | Minecraft (Java Edition) |

📖 **Full documentation lives in [`docs/`](docs/index.md)** and can be served with MkDocs — see [Docs](#docs) below.

## Quick start

```bash
brew install --cask orbstack && brew install kind kubectl helm k9s gh hey
# once: create + trust the local CA (see docs/https.md)
./bootstrap.sh                                         # create from scratch (~2–3 min)
kind delete cluster --name homelab && ./bootstrap.sh   # full teardown + rebuild
```

`bootstrap.sh` creates the kind cluster, loads the local CA from `~/.homelab-ca/` into a Secret, creates a random Grafana password Secret, installs Argo CD with Helm (settings in `argocd/values.yaml`), applies `argocd/root.yaml`, waits for Traefik, then prints the admin password and URLs. Argo CD deploys everything else from Git — and takes over its own install.

> Push before you rebuild — Argo CD reads from GitHub, not your local checkout.

**Survives a rebuild:** everything in Git, and the local CA (it lives on the Mac). **Doesn't:** data (the Minecraft world, metrics history) and the Argo CD / Grafana passwords.

## What's installed

### On the Mac

| Tool | Version | Purpose |
|---|---|---|
| [OrbStack](https://orbstack.dev) | Docker 29.8 | Container runtime — a lightweight Linux VM that runs the kind nodes |
| [kind](https://kind.sigs.k8s.io) | v0.33.0 | Builds Kubernetes clusters out of Docker containers |
| kubectl, helm, k9s, gh | current (brew) | Kubernetes CLI, chart installer, terminal UI, GitHub CLI |
| [hey](https://github.com/rakyll/hey) | 0.1.5 | HTTP load generator |

### In the cluster

| Component | Version | Namespace | Managed by |
|---|---|---|---|
| Kubernetes | v1.37.0 | — | kind ([`cluster/kind-config.yaml`](cluster/kind-config.yaml)) |
| local-path-provisioner | kind default | `local-path-storage` | kind |
| Argo CD | v3.6.1 (chart `argo/argo-cd` 10.14.0) | `argocd` | Argo CD itself (Helm only at bootstrap) — [`argocd/values.yaml`](argocd/values.yaml) |
| Traefik (ingress controller) | v3.7.17 (chart `traefik/traefik` 42.3.1) | `traefik` | Argo CD |
| cert-manager | v1.21.3 (chart `cert-manager` v1.21.3) | `cert-manager` | Argo CD; CA key loaded by `bootstrap.sh` |
| metrics-server | v0.9.0 (chart `metrics-server` 3.14.0) | `kube-system` | Argo CD |
| podinfo | `ghcr.io/stefanprodan/podinfo:6.17.0` | `podinfo` | Argo CD |
| kube-prometheus-stack | chart 93.2.0 (Prometheus Operator v0.95.2) | `monitoring` | Argo CD; Grafana password Secret from `bootstrap.sh` |
| docs site | git-sync v4.8.0 + mkdocs-material 9.8.1 + nginx 1.30 | `docs` | Argo CD |
| Minecraft server | `itzg/minecraft-server:stable` | `minecraft` | Argo CD |

## Repo layout

```
k8s-homelab/
├── bootstrap.sh              # rebuild everything from scratch
├── mkdocs.yml                # docs site config
├── docs/                     # the wiki (MkDocs)
├── cluster/
│   └── kind-config.yaml      # 3-node cluster + Mac port mappings (80, 443, 25565)
├── argocd/
│   ├── values.yaml           # Helm values for Argo CD itself
│   ├── root.yaml             # the "app of apps" — applied once by bootstrap.sh
│   └── apps/                 # one Argo CD Application per app; root watches this folder
│       ├── argocd.yaml           # Argo CD's own chart + values.yaml (self-managed)
│       ├── cert-manager.yaml     # Helm chart, from the chart repo
│       ├── cluster-issuers.yaml  # → apps/cluster-issuers/
│       ├── dashboards.yaml       # → apps/dashboards/
│       ├── docs.yaml
│       ├── metrics-server.yaml   # Helm chart, from the chart repo
│       ├── minecraft.yaml
│       ├── monitoring.yaml       # kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
│       ├── podinfo.yaml
│       └── traefik.yaml          # Helm chart, from the chart repo
└── apps/                     # plain Kubernetes manifests, one folder per app (kustomize)
    ├── cluster-issuers/      # ClusterIssuer "homelab-ca" (signs with the local CA)
    ├── dashboards/           # Grafana dashboards as ConfigMaps (label grafana_dashboard: "1")
    ├── docs/                 # git-sync + mkdocs + nginx pod serving docs/ at docs.localhost
    ├── minecraft/            # Namespace, PVC, Deployment, Service
    └── podinfo/              # Deployment (probes), Service, Ingress, HPA, ServiceMonitor
```

## How it fits together

```
root (argocd/root.yaml)
  └─ watches argocd/apps/*.yaml
       ├─ argocd          ──► Helm chart argo-cd 10.14.0        ──► ns argocd (itself)
       ├─ cert-manager    ──► Helm chart cert-manager v1.21.3   ──► ns cert-manager
       ├─ cluster-issuers ──► apps/cluster-issuers/             ──► ClusterIssuer homelab-ca
       ├─ traefik         ──► Helm chart traefik 42.3.1         ──► ns traefik
       ├─ metrics-server  ──► Helm chart metrics-server 3.14.0  ──► ns kube-system
       ├─ podinfo         ──► apps/podinfo/                     ──► ns podinfo
       ├─ docs            ──► apps/docs/                        ──► ns docs
       ├─ monitoring      ──► Helm chart kube-prometheus-stack  ──► ns monitoring
       ├─ dashboards      ──► apps/dashboards/                  ──► ns monitoring
       └─ minecraft       ──► apps/minecraft/                   ──► ns minecraft
```

Every Application syncs automatically with `prune: true` (removed from Git → deleted) and `selfHeal: true` (manual changes reverted). The exception is `argocd`, which has `prune: false` so it can never delete parts of itself.

**Upgrading Argo CD:** bump the chart version in `argocd/apps/argocd.yaml` *and* `bootstrap.sh`, then push. Don't run `helm upgrade` by hand any more.

**To add an app:** manifests in `apps/<name>/` + an Application in `argocd/apps/<name>.yaml` + an `ingress.yaml` with `host: <name>.localhost` (plus the cert-manager annotation and `tls:` block for HTTPS) if it's a web app → `git push`.

Details: [GitOps](docs/gitops.md) · [Helm](docs/helm.md) · [Ingress](docs/ingress.md) · [HTTPS](docs/https.md) · [Storage](docs/storage.md) · [Autoscaling](docs/autoscaling.md) · [Monitoring](docs/monitoring.md)

## Accessing things

```bash
# Argo CD admin password (changes on every rebuild)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# Talk to Minecraft without the game client
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed

# Grafana admin password (changes on every rebuild)
kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d; echo

# Live resource usage (needs metrics-server)
kubectl top nodes
kubectl top pods -A

# Watch the autoscaler
kubectl get hpa -n podinfo -w
```

Fallback if the ingress is broken: `kubectl port-forward svc/argocd-server -n argocd 8080:80` → http://localhost:8080.

## Experiments done so far

| Experiment | Result | Lesson |
|---|---|---|
| Delete the Minecraft pod | New pod, same world seed | Pods are disposable; PVs aren't |
| Push a change to Git (MOTD) | Rolled out with no `kubectl` | Git is the deploy button |
| `kubectl scale` by hand | Reverted in < 1 s | `selfHeal` |
| Delete a podinfo pod under load | App fine; port-forward broke | Port-forwards pin to one pod |
| Drain a node | podinfo moved in ~7 s; Minecraft `Pending` | Local storage pins pods to a node |
| Rebuild the whole cluster | Everything back from Git; new world | Git holds config, not data |
| Add Traefik ingress | `*.localhost` URLs; load-balanced | Ingress replaces port-forwards |
| Typo in a memory value (`8i`) | API server rejected it; app untouched | Invalid manifests never reach pods |
| Starve podinfo (8Mi) **without** probes | All pods replaced → 503s | No readiness probe = "started" counts as "ready" |
| Starve podinfo **with** readiness probe | Rollout stuck; old pods kept serving | Probes make rolling updates safe |
| HPA + `hey -c 50` | 2 → 4 → 8 in 30 s; back to 2 after 5 min | Fast up, slow down; closed-loop load never satisfies an HPA |
| HPA in Grafana, 300s vs 60s scale-down window | Idle pods kept 4m45s vs 45s | Change one thing, measure again |
| Grafana password changed by itself | Chart re-randomised it on every Argo CD render | Random chart values drift under GitOps |
| HTTPS via cert-manager + local CA | Certs issued in seconds; padlock | Only the CA key stays out of Git |
| Argo CD adopts its own install | 54 OutOfSync (annotations only); synced with no restarts | Check the diff before you sync |

The full write-up is in [docs/experiments.md](docs/experiments.md).

## Roadmap

- [x] 1. Minecraft server — Deployments, Services, PersistentVolumes
- [x] 2. Break things on purpose — pod kills, node drain, memory starvation, probes, HPA + load test
- [x] 3. Ingress (`*.localhost`, Traefik) + HTTPS (cert-manager, local CA)
- [x] 4. Monitoring with `kube-prometheus-stack` (+ app metrics, dashboards in Git)
- [x] 5. GitOps with Argo CD (app of apps, self-managed)
- [ ] 6. A custom controller with kubebuilder
- [ ] 7. Managed cluster in the cloud with Terraform
- [x] Let Argo CD manage its own Helm install
- [ ] Test harness / scripts
- [ ] Local LLMs (run natively on macOS for GPU access; call from the cluster)

## Docs

The `docs/` folder is a [MkDocs](https://www.mkdocs.org) site using the Material theme.

**In the cluster:** <https://docs.localhost> — rebuilt from GitHub within ~70 s of a push (see [docs/apps/docs.md](docs/apps/docs.md)).

**Locally**, while writing:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install mkdocs-material
mkdocs serve          # http://127.0.0.1:8000, live-reloads as you edit
mkdocs gh-deploy      # publish to GitHub Pages (gh-pages branch)
```
