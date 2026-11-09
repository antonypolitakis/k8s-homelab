# GitOps with Argo CD

## The idea

Without GitOps you change a cluster by running commands (`kubectl apply`, `helm install`). The cluster's state then lives in people's shell history.

With GitOps the **Git repo is the source of truth**. [Argo CD](https://argo-cd.readthedocs.io) runs inside the cluster, compares what's in Git with what's running, and makes them match:

- **Git → cluster:** you push; Argo CD applies. It polls Git about every 3 minutes (or press **Refresh** in the UI).
- **Cluster → Git:** someone changes the cluster by hand; Argo CD notices within seconds and reverts it.
- **History:** every change is a commit — reviewed, attributable, and revertible.

## Installed version

Argo CD **v3.6.1**, from Helm chart `argo/argo-cd` **10.14.0**, installed by `bootstrap.sh` with [`argocd/values.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/values.yaml):

```yaml
global:
  domain: argocd.localhost
configs:
  params:
    server.insecure: true      # serve plain HTTP; Traefik faces the browser
server:
  ingress:
    enabled: true
    ingressClassName: traefik
```

Argo CD itself is the one thing *not* managed by Argo CD (yet — see the [Roadmap](roadmap.md)).

## App of apps

Each app is an Argo CD **Application** — a small resource saying "sync *this* source into *that* namespace". Rather than applying each one by hand, a single **root** Application watches a folder of them:

```
root (argocd/root.yaml)               ← applied once, by bootstrap.sh
  └─ watches argocd/apps/*.yaml
       ├─ traefik         ──► Helm chart traefik 42.3.1         ──► ns traefik
       ├─ metrics-server  ──► Helm chart metrics-server 3.14.0  ──► ns kube-system
       ├─ podinfo         ──► apps/podinfo/  (this repo)        ──► ns podinfo
       └─ minecraft       ──► apps/minecraft/ (this repo)       ──► ns minecraft
```

An Application's source can be:

- **A folder in this repo** containing plain manifests and a `kustomization.yaml` (podinfo, minecraft).
- **A Helm chart from a chart repository**, with values written inline under `helm.valuesObject` (traefik, metrics-server).

## Sync policy

Every Application uses:

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
