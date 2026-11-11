# GitOps with Argo CD

## The idea

Without GitOps you change a cluster by running commands (`kubectl apply`, `helm install`). The cluster's state then lives in people's shell history.

With GitOps the **Git repo is the source of truth**. [Argo CD](https://argo-cd.readthedocs.io) runs inside the cluster, compares what's in Git with what's running, and makes them match:

- **Git → cluster:** you push; Argo CD applies. It polls Git about every 3 minutes (or press **Refresh** in the UI).
- **Cluster → Git:** someone changes the cluster by hand; Argo CD notices within seconds and reverts it.
- **History:** every change is a commit — reviewed, attributable, and revertible.

## Installed version

Argo CD **v3.6.1**, from Helm chart `argo/argo-cd` **10.14.0**, with [`argocd/values.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/values.yaml):

```yaml
global:
  domain: argocd.localhost
configs:
  params:
    server.insecure: true      # serve plain HTTP; Traefik faces the browser
server:
  replicas: 2                  # first change made to Argo CD through Git
  ingress:
    enabled: true
    ingressClassName: traefik
```

`bootstrap.sh` installs it once with Helm; after that, [Argo CD manages itself](#argo-cd-manages-itself).

## App of apps

Each app is an Argo CD **Application** — a small resource saying "sync *this* source into *that* namespace". Rather than applying each one by hand, a single **root** Application watches a folder of them:

```
root (argocd/root.yaml)               ← applied once, by bootstrap.sh
  └─ watches argocd/apps/*.yaml
       ├─ argocd          ──► Helm chart argo-cd 10.14.0        ──► ns argocd (itself)
       ├─ traefik         ──► Helm chart traefik 42.3.1         ──► ns traefik
       ├─ metrics-server  ──► Helm chart metrics-server 3.14.0  ──► ns kube-system
       ├─ podinfo         ──► apps/podinfo/  (this repo)        ──► ns podinfo
       └─ minecraft       ──► apps/minecraft/ (this repo)       ──► ns minecraft
```

An Application's source can be:

- **A folder in this repo** containing plain manifests and a `kustomization.yaml` (podinfo, minecraft).
- **A Helm chart from a chart repository**, with values written inline under `helm.valuesObject` (traefik, metrics-server).
- **Several sources at once** — a chart from one place, its values file from this repo (argocd; see below).

## Sync policy

Every Application (except `argocd` — see below) uses:

```yaml
syncPolicy:
  automated:
    prune: true      # resources removed from Git are deleted from the cluster
    selfHeal: true   # manual changes in the cluster are reverted to match Git
  syncOptions:
    - CreateNamespace=true   # (where used) Argo CD creates the target namespace
```

!!! danger "prune cuts both ways"
    Delete `apps/minecraft/pvc.yaml` from Git and Argo CD deletes the volume — and the world on it.

Traefik also uses `ServerSideApply=true`, because its CRDs are too large for a client-side apply.

## Argo CD manages itself

[`argocd/apps/argocd.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/argocd.yaml) points Argo CD at its own Helm chart. It has **two sources**: the chart, and this repo, so the chart can use the same `argocd/values.yaml` that `bootstrap.sh` uses.

```yaml
spec:
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.14.0          # must match bootstrap.sh
      helm:
        releaseName: argocd            # same name as the Helm install → same resources
        valueFiles:
          - $values/argocd/values.yaml # "$values" = the source below
    - repoURL: https://github.com/antonypolitakis/k8s-homelab.git
      targetRevision: main
      ref: values
  syncPolicy:
    automated:
      prune: false                     # never let Argo CD delete parts of itself
      selfHeal: true
    syncOptions:
      - ServerSideApply=true           # Argo CD's CRDs are too big for client-side apply
```

### The chicken and the egg

Argo CD can't install itself into an empty cluster, so the work is split:

1. **`bootstrap.sh`** runs `helm upgrade --install` once, so there's an Argo CD to start with.
2. **root** picks up `argocd/apps/argocd.yaml`, and the Argo CD app *adopts* the resources Helm created.

From then on, Helm isn't used again. Upgrades and setting changes are commits.

### How the takeover was done (safely)

The first version had **no** `automated` policy, so nothing would sync without a click:

1. **Render and compare first.** `helm template` with the same chart, version and values, then `kubectl diff` against the cluster. The only difference was a Helm hook Job (`argocd-redis-secret-init`), which Argo CD runs as a sync hook anyway.
2. **The app showed OutOfSync for 54 resources** — but only because none of them had Argo CD's tracking annotation (`argocd.argoproj.io/tracking-id`) yet. Their actual contents matched.
3. **Manual Sync.** Argo CD added the annotations. No pod restarted.
4. **Turned on `automated`** (commit), then **`server.replicas: 2`** (commit). Argo CD scaled its own Deployment — same ReplicaSet, so the existing pod was left alone.

### Rules from now on

!!! warning "Don't `helm upgrade argocd` by hand"
    Argo CD owns the release now. A manual Helm upgrade fights with Git; `selfHeal` will put it back.

!!! warning "The chart version lives in two places"
    To upgrade Argo CD, bump `targetRevision` in `argocd/apps/argocd.yaml` **and** `--version` in `bootstrap.sh`, in the same commit. Otherwise a rebuild installs one version and Argo CD immediately upgrades it to the other.

!!! danger "Breaking Argo CD through Git"
    A bad commit to `argocd/values.yaml` can take down the thing that would apply the fix. If the UI goes away: fix Git, then rescue with the bootstrap command —
    `helm upgrade --install argocd argo/argo-cd -n argocd --version 10.14.0 -f argocd/values.yaml` — or rebuild.

## Charts that generate random values

Some charts make up a value at render time — a password, a token, a certificate. With plain Helm that's fine: the chart looks up the existing Secret and reuses it. Argo CD renders without cluster access, so **every render produces a new random value**, Argo CD sees drift, and `selfHeal` overwrites the live Secret.

That's what happened to Grafana's admin password. The fix is to set the value yourself, or point the chart at a Secret made outside Git (`grafana.admin.existingSecret`). See [Monitoring](monitoring.md#the-random-password-trap).

## Apps that depend on another app's CRDs

`cluster-issuers` (ClusterIssuer) and `podinfo` (ServiceMonitor) use resource kinds that another app installs. On a fresh cluster they may sync first, so they carry:

```yaml
syncOptions:
  - SkipDryRunOnMissingResource=true
retry:
  limit: 10
  backoff:
    duration: 10s
```

A failed first sync on those apps is normal; the retry fixes it.

## Status meanings

| Sync | Health | Meaning |
|---|---|---|
| Synced | Healthy | Cluster matches Git and everything works |
| OutOfSync | Healthy | Git changed but couldn't be applied (e.g. the API server rejected it) — old version still running |
| Synced | Progressing | Applied, still rolling out (or an Ingress has no address yet) |
| Synced | Degraded | Applied exactly as written, but it doesn't work (e.g. crash-looping pods past the deadline) |

## Everyday workflows

**Add an app**

1. Manifests in `apps/<name>/`, listed in `apps/<name>/kustomization.yaml`.
2. Copy `argocd/apps/podinfo.yaml` to `argocd/apps/<name>.yaml`; change `name`, `path`, `namespace`.
3. For a web app, add an `ingress.yaml` with `host: <name>.localhost` ([Ingress](ingress.md)).
4. `git add . && git commit && git push`. No `kubectl`.

**Change an app:** edit the file, commit, push.

**Roll back:** `git revert <commit> && git push` — or edit the values back if the bad commit also contained unrelated changes.

**Remove an app:** delete `argocd/apps/<name>.yaml` and push. The Application is deleted; its resources stay unless the Application has the `resources-finalizer.argocd.argoproj.io` finalizer.

## When an Application and a controller both want a field

The [HPA](autoscaling.md) changes a Deployment's `replicas`. If Git also set `replicas`, `selfHeal` would keep resetting it and the two would fight. The fix used here is to **remove `replicas` from Git** and let the HPA own it (`minReplicas` is the floor). The alternative is Argo CD's `ignoreDifferences` on that field.
