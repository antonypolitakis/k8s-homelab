# Helm

[Helm](https://helm.sh) is the package manager for Kubernetes. Five of the apps here — Argo CD, Traefik, cert-manager, metrics-server and kube-prometheus-stack — are Helm **charts**. But after bootstrap, it's **Argo CD**, not the `helm` command, that installs and updates them.

## The problem Helm solves

Installing something like Prometheus by hand means writing ~100 Kubernetes manifests: Deployments, Services, RBAC, CRDs, ConfigMaps… and keeping them consistent when you change one setting. A chart packages all of that, written once by the project's maintainers, with the parts you might want to change pulled out as **values**.

## How it works

```
 chart (templates + default values.yaml)
            +                                ┌──────────────┐
 your values (what you want different) ────► │ helm template│ ──► plain Kubernetes YAML ──► the cluster
                                             └──────────────┘
```

A chart is a folder (usually shipped as a `.tgz`):

```
traefik/
├── Chart.yaml        # name, chart version, app version
├── values.yaml       # every setting, with defaults — the chart's "API"
├── templates/        # Kubernetes YAML with Go-template placeholders
│   ├── deployment.yaml
│   ├── service.yaml
│   └── …
└── crds/             # CustomResourceDefinitions, applied first
```

A template is ordinary YAML with gaps:

```yaml
# templates/service.yaml (simplified)
spec:
  type: {{ .Values.service.spec.type }}
  ports:
    - name: web
      nodePort: {{ .Values.ports.web.nodePort }}
```

Rendering fills the gaps from the merged values — the chart's defaults, overridden by yours. The output is plain YAML that Kubernetes understands; **Kubernetes itself knows nothing about Helm.**

### Two version numbers

| | Example | Meaning |
|---|---|---|
| **Chart version** | `traefik` **42.3.1** | Version of the *packaging* (templates, defaults). This is what you pin. |
| **App version** | Traefik **v3.7.17** | Version of the software inside it |

The chart version can change without the app changing (a template fix), and one chart version always installs the same app version.

### Where charts come from

A **chart repository** is just a web server with an index of `.tgz` files (`https://traefik.github.io/charts`). Newer charts are also published to OCI registries, like container images.

## Two ways to use a chart

### 1. The `helm` command

```bash
helm upgrade --install argocd argo/argo-cd --version 10.14.0 -f argocd/values.yaml -n argocd
```

Helm renders the chart, applies it, and records a **release**: a Secret (`sh.helm.release.v1.argocd.v1`) holding what it installed. That record is what makes `helm list`, `helm upgrade` and `helm rollback` work.

### 2. Argo CD rendering it

```yaml
# argocd/apps/traefik.yaml
source:
  repoURL: https://traefik.github.io/charts
  chart: traefik
  targetRevision: 42.3.1        # the chart version
  helm:
    valuesObject:               # your values, inline
      service:
        spec:
          type: NodePort
```

Argo CD downloads the chart and runs the equivalent of `helm template` — **render only**. Then it applies the YAML itself, compares it with the cluster, self-heals and prunes like any other app. No Helm release is recorded.

### What that looks like here

```console
$ helm list -A
NAME    NAMESPACE  REVISION  STATUS    CHART
argocd  argocd     1         deployed  argo-cd-10.14.0
```

- **Only `argocd` appears** — the one install `bootstrap.sh` does with the `helm` command. Traefik, cert-manager, metrics-server and monitoring are invisible to `helm list`, because Argo CD never made releases for them.
- **`argocd` is stuck at revision 1**, although Argo CD has since changed it (2 server replicas, TLS, …). Once Argo CD [took over](gitops.md#argo-cd-manages-itself), the Helm record went stale. Don't use `helm upgrade` or `helm rollback` on it; roll back with Git.

## Values: how settings reach a chart

Every chart's settings are documented in its `values.yaml`. Read them before changing anything:

```bash
helm show values traefik --repo https://traefik.github.io/charts --version 42.3.1 | less
helm show chart  traefik --repo https://traefik.github.io/charts            # latest chart + app version
```

This repo passes values in two ways:

| Style | Used by | Why |
|---|---|---|
| **Inline** `helm.valuesObject:` in the Application | traefik, metrics-server, cert-manager, monitoring | Chart, version and settings in one file |
| **A values file** in the repo, via a second `$values` source | argocd | The same `argocd/values.yaml` is used by `bootstrap.sh` and by Argo CD |

Only override what you need — everything else keeps the chart's default, so upgrades bring improvements for free.

## Seeing what a chart will do

Render it locally and read the output, without touching the cluster:

```bash
helm template traefik traefik --repo https://traefik.github.io/charts --version 42.3.1 \
  -n traefik -f my-values.yaml > rendered.yaml

grep '^kind:' rendered.yaml | sort | uniq -c       # what resources it creates
kubectl diff -f rendered.yaml                      # what would change in the cluster
```

This is how changes in this lab were checked before committing — e.g. confirming the Argo CD takeover would change nothing but annotations, or that the monitoring chart had no Helm hooks left.

## Helm features that behave differently under Argo CD

Argo CD only borrows Helm's *templating*. Features that depend on Helm being the installer either get translated or don't work:

| Helm feature | Under Argo CD | Seen here |
|---|---|---|
| **Releases** (`helm list/rollback`) | None — Git history is the record | `helm list` shows only the bootstrap install |
| **Hooks** (`pre-install`, `post-upgrade` Jobs) | Translated to Argo CD sync hooks; usually fine | Argo CD's `argocd-redis-secret-init` Job |
| **Test hooks** (`helm test`) | Not run | Grafana's test pod — disabled with `testFramework.enabled: false` |
| **`lookup`** (read the live cluster while rendering) | Returns nothing — Argo CD renders without cluster access | Grafana's password re-randomised on every render → [the random-password trap](monitoring.md#the-random-password-trap) |
| **`crds/` folder** | Applied, but very large CRDs need `ServerSideApply=true` | Traefik, kube-prometheus-stack |
| **Capabilities checks** (only render X if API Y exists) | Uses the cluster's API list at sync time | ServiceMonitors appear once the monitoring CRDs exist |

!!! tip "Rule of thumb"
    If a chart value is generated, looked up or random, set it yourself when using Argo CD.

## Helm vs brew

A chart is a lot like a Homebrew formula — but with differences that matter:

| Like brew | Unlike brew |
|---|---|
| Formula ↔ **chart**; tap ↔ **chart repo** | Installs a *description* (YAML), not files: Kubernetes pulls the container images and runs them |
| `brew install/upgrade/uninstall/list` ↔ `helm install/upgrade/uninstall/list` | **Values** customise each install heavily — same chart, different setup per cluster |
| Someone else maintains the recipe | One chart can be installed **many times** (separate releases) |
| | No prerequisite resolution — e.g. cert-manager had to be installed before monitoring could use it |

Here Helm is closer to a **Brewfile**: the list of what you want, and its settings, lives in Git — and Argo CD keeps the cluster matching it continuously.

## How charts are secured

Mostly by **trust in whoever wrote them**. A chart is code that creates whatever it likes, with the permissions of whatever applies it — like running someone's install script.

### What a chart can do here

The installer is Argo CD's application controller, and its ClusterRole allows everything:

```
argocd-application-controller:  apiGroups: *  resources: *  verbs: *
```

All apps use Argo CD's `default` AppProject, which restricts nothing:

```yaml
sourceRepos: ["*"]                                # any chart repo or Git repo
destinations: [{namespace: "*", server: "*"}]     # anywhere
clusterResourceWhitelist: [{group: "*", kind: "*"}]   # any cluster-wide resource
```

So charts can — and these legitimately do:

- create **ClusterRoles** (the monitoring chart makes three so Prometheus can read pods and nodes cluster-wide),
- install **admission webhooks** that see every resource you create (Prometheus operator, cert-manager),
- run **host-level pods** (node-exporter uses `hostNetwork` and `hostPID` to read node stats).

A malicious or compromised chart could use the same power for anything.

### From the internet to the cluster

| Layer | Protection | Status here |
|---|---|---|
| **Download** | HTTPS from the project's own repo | ✅ All five charts come from official project repos |
| **Integrity** | The repo's `index.yaml` lists a SHA-256 digest per version; Helm checks the download against it | ✅ Automatic — catches corruption, but not a compromised repo (it would publish a new digest) |
| **Authenticity** | Optional signatures: PGP `.prov` files (classic repos) or **cosign/Sigstore** (OCI charts) | ❌ Not checked — Traefik publishes no `.prov`; neither Helm nor Argo CD verifies by default |
| **Pinning** | `targetRevision: 42.3.1`, never "latest" | ✅ Every chart pinned. Versions *should* be immutable, but an owner could re-publish one |
| **Container images** | Separate supply chain — the chart only names an image | ⚠️ Pinned by tag, not digest; not scanned |
| **Secrets** | Kept out of values and Git | ✅ CA key and Grafana password made outside Git, used via `existingSecret`. (Values in Git are plain text; a Helm release Secret stores its values too.) |

### Tightening it, in order of usefulness

1. **Read before installing.** `helm template … | grep '^kind:' | sort | uniq -c` — look for ClusterRoles, webhooks, `privileged`, `hostNetwork`, `hostPID`.
2. **A dedicated Argo CD AppProject** with an allowlist of source repos (this repo + the five chart repos) and destinations. A typo'd or malicious URL is then refused.
3. **Pod Security Admission** (built into Kubernetes): label app namespaces like `podinfo` as `restricted` so nothing there can run privileged or as root; exempt the ones that need host access (monitoring).
4. **Scan images** — e.g. Trivy, which can run in-cluster and report known vulnerabilities in everything running.
5. **Verify signatures** with cosign for OCI charts and images — mostly a production concern.

!!! note "Risk in this lab"
    Official sources and pinned versions keep the realistic risk low. But "Argo CD installs anything, anywhere, from any repo" is the default — and the first thing production teams change.

## Helm vs Kustomize

Both appear in this repo, for different jobs:

| | Helm | Kustomize |
|---|---|---|
| Model | Templates with placeholders + values | Plain YAML + patches/overlays |
| Best for | Installing **someone else's** software with many options | **Your own** manifests (podinfo, minecraft, docs, dashboards) |
| Used here for | traefik, cert-manager, metrics-server, monitoring, argocd | everything under `apps/` |

Kustomize is built into `kubectl` (`kubectl kustomize apps/podinfo`) and into Argo CD, which detects a `kustomization.yaml` automatically.

## Charts in this lab

| Chart | Chart version | App version | Repo |
|---|---|---|---|
| argo-cd | 10.14.0 | v3.6.1 | `https://argoproj.github.io/argo-helm` |
| traefik | 42.3.1 | v3.7.17 | `https://traefik.github.io/charts` |
| cert-manager | v1.21.3 | v1.21.3 | `https://charts.jetstack.io` |
| metrics-server | 3.14.0 | v0.9.0 | `https://kubernetes-sigs.github.io/metrics-server/` |
| kube-prometheus-stack | 93.2.0 | operator v0.95.2 | `https://prometheus-community.github.io/helm-charts` |

**Upgrading one:** check the chart's release notes, `helm show values` the new version and compare, change `targetRevision` (for argo-cd, also `--version` in `bootstrap.sh`), render and diff, then push.
