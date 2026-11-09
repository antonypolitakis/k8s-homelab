# Setup & bootstrap

## Tools on the Mac

| Tool | Version | Why |
|---|---|---|
| [OrbStack](https://orbstack.dev) | Docker 29.8 | Runs a lightweight Linux VM with Docker in it. kind's "nodes" are containers inside it. Lighter and faster than Docker Desktop on Apple Silicon. |
| [kind](https://kind.sigs.k8s.io) | v0.33.0 | **K**ubernetes **in** **D**ocker — builds a real, upstream Kubernetes cluster where each node is a Docker container. |
| kubectl | current | The Kubernetes CLI. Must be within one minor version of the cluster. |
| helm | current | Installs Argo CD once, at bootstrap (after that, Argo CD manages itself). |
| k9s | current | Terminal UI — press `0` for all namespaces, `:q` to quit. |
| gh | current | GitHub CLI — create repos, manage auth. |
| hey | 0.1.5 | HTTP load generator for testing autoscaling. |

```bash
brew install --cask orbstack
brew install kind kubectl helm k9s gh hey
```

!!! note "First run of OrbStack"
    The `docker` command only appears after OrbStack has been opened once (`open -a OrbStack`) and a **new** terminal tab has been started.

!!! note "GitHub CLI"
    `gh auth login` → GitHub.com → HTTPS → *Authenticate Git with your GitHub credentials: Yes* → web browser. After that, `git push` just works.

## Bootstrap

Everything is rebuilt by one script:

```bash
./bootstrap.sh                                         # create from scratch
kind delete cluster --name homelab && ./bootstrap.sh   # full teardown + rebuild (~2–3 min)
```

What `bootstrap.sh` does, in order:

1. **`kind create cluster --config cluster/kind-config.yaml`** — 3 nodes, with Mac ports 80/443/25565 mapped in. See [The cluster](cluster.md).
2. **`helm upgrade --install argocd argo/argo-cd --version 10.14.0 -f argocd/values.yaml`** — installs Argo CD with our settings (ingress at `argocd.localhost`, plain HTTP behind Traefik). Then waits for all its Deployments.
3. **`kubectl apply -f argocd/root.yaml`** — the *only* hand-applied manifest. From here, Argo CD deploys everything in `argocd/apps/` from GitHub — including **Argo CD itself**, which adopts the Helm install. See [GitOps](gitops.md#argo-cd-manages-itself).
4. **Waits for Traefik** to be Healthy, so the URLs work when it finishes.
5. Prints the Argo CD admin password and the URLs.

The script `cd`s to its own directory first, so it can be run from anywhere.

!!! warning "Helm is for bootstrap only"
    On a running cluster, change Argo CD by committing to `argocd/values.yaml` — not by re-running the Helm step. The chart version is in both `bootstrap.sh` and `argocd/apps/argocd.yaml`; keep them the same.

!!! warning "Push before you rebuild"
    Argo CD reads the repo from **GitHub**, not from your laptop. Anything not pushed won't be deployed.

## What survives a rebuild

| Survives | Lost |
|---|---|
| Everything defined in Git — apps, ingress, autoscaling, config | Data in PersistentVolumes (the Minecraft world) |
| | The Argo CD admin password (a new one is generated) |
| | Running port-forwards |

## Logging in to Argo CD

Open <http://argocd.localhost>, user `admin`, password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
