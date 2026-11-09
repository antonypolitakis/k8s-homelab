# k8s-homelab

A local Kubernetes learning lab on an Apple Silicon Mac, run the GitOps way:
**this repo is the source of truth, and Argo CD keeps the cluster in sync with it.**
Nothing is deployed with `kubectl apply` except the one-time bootstrap.

```
 git push ──► GitHub (this repo) ◄── polls ── Argo CD ──► kind cluster "homelab"

 browser ──► http://<app>.localhost ──► Traefik (ingress) ──► app Service ──► pods
```

| URL | What |
|---|---|
| http://argocd.localhost | Argo CD UI (user `admin`) |
| http://podinfo.localhost | podinfo demo app |
| `localhost:25565` | Minecraft (Java Edition) |

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
| Argo CD | v3.6.1 (Helm chart `argo/argo-cd` 10.14.0) | `argocd` | Helm, via [`bootstrap.sh`](bootstrap.sh) + [`argocd/values.yaml`](argocd/values.yaml) |
| Traefik (ingress controller) | v3.7.17 (Helm chart `traefik/traefik` 42.3.1) | `traefik` | Argo CD |
| Minecraft server | `itzg/minecraft-server:stable` | `minecraft` | Argo CD |
| podinfo | `ghcr.io/stefanprodan/podinfo:6.17.0` | `podinfo` | Argo CD |

## Cluster layout

Three nodes, each a Docker container inside OrbStack:

| Node | Role |
|---|---|
| `homelab-control-plane` | Runs Kubernetes itself. Tainted so app pods don't land here. Carries the Mac port mappings below. |
| `homelab-worker` | Runs app pods |
| `homelab-worker2` | Runs app pods |

Port mappings ([`cluster/kind-config.yaml`](cluster/kind-config.yaml)) — changing these needs a cluster rebuild:

| Mac port | NodePort | Goes to |
|---|---|---|
| 80 | 30080 | Traefik `web` (HTTP) |
| 443 | 30443 | Traefik `websecure` (HTTPS — no certificates yet) |
| 25565 | 30565 | Minecraft (raw TCP, bypasses the ingress) |

## Repo layout

```
k8s-homelab/
├── bootstrap.sh              # rebuild everything from scratch
├── cluster/
│   └── kind-config.yaml      # 3-node cluster + Mac port mappings
├── argocd/
│   ├── values.yaml           # Helm values for Argo CD itself (ingress, plain HTTP)
│   ├── root.yaml             # the "app of apps" — applied once by bootstrap.sh
│   └── apps/                 # one Argo CD Application per app; root watches this folder
│       ├── minecraft.yaml
│       ├── podinfo.yaml
│       └── traefik.yaml      # Helm chart straight from Traefik's chart repo
└── apps/                     # the actual Kubernetes manifests, one folder per app
    ├── minecraft/            # Namespace, PVC, Deployment, Service (kustomize)
    └── podinfo/              # Deployment, Service, Ingress (kustomize)
```

## How the GitOps setup works

Argo CD uses the **app of apps** pattern:

```
root (argocd/root.yaml)
  └─ watches argocd/apps/*.yaml
       ├─ minecraft  ──► syncs apps/minecraft/                 ──► namespace "minecraft"
       ├─ podinfo    ──► syncs apps/podinfo/                   ──► namespace "podinfo"
       └─ traefik    ──► syncs Helm chart traefik 42.3.1       ──► namespace "traefik"
```

An Application's source can be a folder in this repo (minecraft, podinfo) or a Helm chart from a chart repo with values written inline (traefik).

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

`bootstrap.sh`:

1. creates the kind cluster
2. installs Argo CD with Helm (pinned chart version, settings from `argocd/values.yaml`) and waits for it
3. applies `argocd/root.yaml` — from here Argo CD deploys everything else from Git
4. waits for Traefik to be Healthy, then prints the admin password and URLs

It can be run from any directory. Re-running `helm upgrade --install ...` from it applies changes to `argocd/values.yaml` without a rebuild.

> Push before you rebuild — Argo CD reads from GitHub, not your local checkout.

**What survives a rebuild:** everything defined in Git.
**What doesn't:** data (the Minecraft world) and the Argo CD admin password.

## Ingress

[Traefik](https://traefik.io) is the ingress controller (ingress-nginx was retired in March 2026). Any `*.localhost` name resolves to 127.0.0.1 in browsers and curl, so no DNS or `/etc/hosts` changes are needed.

```
http://podinfo.localhost
  └─► Mac :80 ──► kind node :30080 ──► Traefik ──(Host header matches Ingress rule)──► Service podinfo ──► pods
```

How it's wired:

- **Traefik** runs as a `NodePort` Service on fixed ports 30080/30443, which kind maps to Mac ports 80/443. It's the default `IngressClass`.
- Traefik publishes `127.0.0.1` as every Ingress's address (`providers.kubernetesIngress.ingressEndpoint.ip`). Without it, the address stays empty and Argo CD reports apps with an Ingress as `Progressing` forever.
- **Argo CD** gets its Ingress from its own Helm chart (`server.ingress` in `argocd/values.yaml`) and runs with `server.insecure: true` — it serves plain HTTP inside the cluster, otherwise it would redirect to HTTPS and loop behind the ingress.
- **podinfo** has a plain [`ingress.yaml`](apps/podinfo/ingress.yaml) in its app folder.

To expose a new app: add an `ingress.yaml` with `host: <name>.localhost` to its folder, list it in `kustomization.yaml`, push.

Unlike a port-forward, Traefik load-balances across all healthy pods — `curl -s http://podinfo.localhost | grep hostname` alternates between replicas.

## Accessing things

Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Talk to the Minecraft server without the game client:

```bash
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed
```

Fallback if the ingress is broken: `kubectl port-forward svc/argocd-server -n argocd 8080:80`, then http://localhost:8080.

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
| Add Traefik ingress | `argocd.localhost` / `podinfo.localhost` work with no port-forwards; requests load-balance across pods |
| Change Traefik settings in Git | Argo CD upgraded Traefik in place — no rebuild |

## Gotchas

- zsh doesn't treat `# comments` as comments when you type them interactively — drop them, or `setopt interactive_comments`.
- `<placeholders>` in commands must be replaced, angle brackets included (zsh treats `<` `>` as redirects).
- A port-forward is pinned to one pod; if that pod dies, the forward dies. Use the ingress URLs instead.
- `itzg/minecraft-server:stable` follows the latest Minecraft release; pin it if you need a fixed client version.
- Use `http://` for now — `https://` hits Traefik's self-signed default certificate until cert-manager is set up.
- Long heredocs pasted into the terminal can get truncated. For multi-line files, paste into an editor (`nano`, `code`) instead.

## Roadmap

- [x] 1. Minecraft server — Deployments, Services, PersistentVolumes
- [ ] 2. Break things on purpose — pod kills ✅, node drain ✅, memory starvation, HPA + load test
- [ ] 3. Ingress (`*.localhost`) ✅ Traefik, + cert-manager with a local CA for HTTPS
- [ ] 4. Monitoring with `kube-prometheus-stack`
- [x] 5. GitOps with Argo CD (app of apps)
- [ ] 6. A custom controller with kubebuilder
- [ ] 7. Managed cluster in the cloud with Terraform
- [ ] Let Argo CD manage its own Helm install
- [ ] Test harness / scripts
- [ ] Local LLMs (run natively on macOS for GPU access; call from the cluster)
