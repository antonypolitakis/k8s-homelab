# k8s-homelab

A local Kubernetes learning lab on an Apple Silicon Mac, run the GitOps way:
**this repo is the source of truth, and Argo CD keeps the cluster in sync with it.**
Nothing is deployed with `kubectl apply` except the one-time bootstrap.

```
 git push ──► GitHub (this repo) ◄── polls ── Argo CD ──► kind cluster "homelab"
```

## What's installed

### On the Mac

| Tool | Version | Purpose |
|---|---|---|
| [OrbStack](https://orbstack.dev) | Docker 29.8 | Container runtime — a lightweight Linux VM that runs the kind nodes |
| [kind](https://kind.sigs.k8s.io) | v0.33.0 | Builds Kubernetes clusters out of Docker containers |
| kubectl | current (brew) | Kubernetes CLI |
| helm | current (brew) | Installs Argo CD |
| [k9s](https://k9scli.io) | current (brew) | Terminal UI for watching the cluster |
| [gh](https://cli.github.com) | current (brew) | GitHub CLI |
| [hey](https://github.com/rakyll/hey) | 0.1.5 | HTTP load generator |

Install with: `brew install --cask orbstack && brew install kind kubectl helm k9s gh hey`

### In the cluster

| Component | Version | Namespace | Managed by |
|---|---|---|---|
| Kubernetes | v1.37.0 | — | kind ([`cluster/kind-config.yaml`](cluster/kind-config.yaml)) |
| local-path-provisioner | kind default | `local-path-storage` | kind |
| Argo CD | v3.6.1 (Helm chart `argo/argo-cd` 10.14.0) | `argocd` | Helm, via [`bootstrap.sh`](bootstrap.sh) |
| Minecraft server | `itzg/minecraft-server:stable` | `minecraft` | Argo CD |
| podinfo | `ghcr.io/stefanprodan/podinfo:6.17.0` | `podinfo` | Argo CD |

## Cluster layout

Three nodes, each a Docker container inside OrbStack:

| Node | Role |
|---|---|
| `homelab-control-plane` | Runs Kubernetes itself. Tainted so app pods don't land here. Also forwards Mac port `25565` → NodePort `30565` (Minecraft). |
| `homelab-worker` | Runs app pods |
| `homelab-worker2` | Runs app pods |

## Repo layout

```
k8s-homelab/
├── bootstrap.sh              # rebuild everything from scratch
├── cluster/
│   └── kind-config.yaml      # 3-node cluster + port mapping
├── argocd/
│   ├── root.yaml             # the "app of apps" — applied once by bootstrap.sh
│   └── apps/                 # one Argo CD Application per app; root watches this folder
│       ├── minecraft.yaml
│       └── podinfo.yaml
└── apps/                     # the actual Kubernetes manifests, one folder per app
    ├── minecraft/            # Namespace, PVC, Deployment, Service (kustomize)
    └── podinfo/              # Deployment, Service (kustomize)
```

## How the GitOps setup works

Argo CD uses the **app of apps** pattern:

```
root (argocd/root.yaml)
  └─ watches argocd/apps/*.yaml
       ├─ minecraft  ──► syncs apps/minecraft/  ──► namespace "minecraft"
       └─ podinfo    ──► syncs apps/podinfo/    ──► namespace "podinfo"
```

Every Application uses the same sync policy:

```yaml
syncPolicy:
  automated:
    prune: true      # resources removed from Git are deleted from the cluster
    selfHeal: true   # manual changes in the cluster are reverted to match Git
```

- **Git → cluster:** Argo CD polls the repo roughly every 3 minutes (or hit **Refresh** in the UI).
- **Cluster drift:** detected and reverted within seconds (e.g. `kubectl scale --replicas=0` gets undone).
- **Rollback:** `git revert <commit> && git push`.

> ⚠️ Because `prune: true` is on, deleting `apps/minecraft/pvc.yaml` from Git will delete the Minecraft world.

### Adding a new app

1. Put its manifests in `apps/<name>/` with a `kustomization.yaml` listing them.
2. Add `argocd/apps/<name>.yaml` (copy `podinfo.yaml`, change `name`, `path` and `namespace`).
3. `git push`. That's it — no `kubectl apply`.

`podinfo` shows the shortcut of letting Argo CD create the namespace (`syncOptions: [CreateNamespace=true]`) instead of shipping a `namespace.yaml`.

## Build / rebuild the cluster

```bash
./bootstrap.sh                                         # create from scratch
kind delete cluster --name homelab && ./bootstrap.sh   # full teardown + rebuild (~2–3 min)
```

`bootstrap.sh` creates the kind cluster, installs Argo CD with Helm (pinned chart version), waits for it, applies `argocd/root.yaml`, and prints the Argo CD admin password. Argo CD then deploys everything else from Git.

**What survives a rebuild:** everything defined in Git.
**What doesn't:** data (the Minecraft world) and the Argo CD admin password.

## Accessing things

There's no ingress yet, so use port-forwards (each in its own terminal tab):

| What | Command | URL |
|---|---|---|
| Argo CD UI | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | https://localhost:8080 (user `admin`) |
| podinfo | `kubectl port-forward -n podinfo svc/podinfo 9898:9898` | http://localhost:9898 |
| Minecraft | none needed — kind maps it | `localhost:25565` (Java Edition) |

Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Talk to the Minecraft server without the game client:

```bash
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed
```

## Storage

Minecraft's world lives on a PersistentVolume from kind's default `standard` StorageClass (`rancher.io/local-path`):

```
Pod /data  ──mount──►  PVC minecraft-data  ──►  PV pvc-<uid>  ──►  folder on ONE node:
                                                                   /var/local-path-provisioner/pvc-<uid>_minecraft_minecraft-data
```

- Survives **pod deletion** ✅
- Gets stuck `Pending` if its **node is drained** — the PV has node affinity to the node it was created on ⚠️
- Lost on **cluster deletion** ❌ (the folder is inside the node's Docker container)
- The 5Gi size is not enforced by local-path.

Peek at it directly: `docker exec homelab-worker ls /var/local-path-provisioner/`

## Experiments done so far

| Experiment | Result |
|---|---|
| Delete the Minecraft pod | New pod, same world seed |
| Push a change to Git (MOTD) | Argo CD rolled it out with no `kubectl` |
| `kubectl scale` by hand | Argo CD reverted it in under a second |
| Delete a podinfo pod under load (`hey`) | App stayed up; the port-forward to that pod broke |
| Drain a node | podinfo moved in ~7s; Minecraft stuck `Pending` until `uncordon` |
| Delete and rebuild the whole cluster | Everything back from Git; new Minecraft world |

## Gotchas

- zsh doesn't treat `# comments` as comments when you type them interactively — drop them, or `setopt interactive_comments`.
- `<placeholders>` in commands must be replaced, angle brackets included (zsh treats `<` `>` as redirects).
- A port-forward is pinned to one pod; if that pod dies, the forward dies. Ingress (below) fixes this.
- `itzg/minecraft-server:stable` follows the latest Minecraft release; pin it if you need a fixed client version.

## Roadmap

- [x] 1. Minecraft server — Deployments, Services, PersistentVolumes
- [ ] 2. Break things on purpose — pod kills ✅, node drain ✅, memory starvation, HPA + load test
- [ ] 3. Ingress (`*.localhost`) + cert-manager with a local CA
- [ ] 4. Monitoring with `kube-prometheus-stack`
- [x] 5. GitOps with Argo CD (app of apps)
- [ ] 6. A custom controller with kubebuilder
- [ ] 7. Managed cluster in the cloud with Terraform
- [ ] Let Argo CD manage its own Helm install
- [ ] Test harness / scripts
- [ ] Local LLMs (run natively on macOS for GPU access; call from the cluster)
