# The cluster

## Layers

```
Your Mac
└── OrbStack (a Linux VM running Docker)
    ├── container: homelab-control-plane   ← runs Kubernetes itself
    ├── container: homelab-worker          ← runs app pods
    └── container: homelab-worker2         ← runs app pods
            └── your pods run *inside* these node containers
```

Each node container runs the same Kubernetes software (kubelet, container runtime) as a real server would. `docker ps` shows the three nodes; `kubectl get nodes` shows the same three from Kubernetes' point of view.

Kubernetes version: **v1.37.0** (the default for kind v0.33.0). Kubernetes ships a minor release roughly every four months, and kind clusters pick up new versions when kind is upgraded and the cluster rebuilt.

## Nodes

| Node | Role |
|---|---|
| `homelab-control-plane` | API server, scheduler, controllers, etcd. **Tainted** so ordinary pods aren't scheduled here. Carries the port mappings. |
| `homelab-worker` | App pods |
| `homelab-worker2` | App pods |

## Port mappings

A pod inside a node container inside a VM isn't reachable from the Mac by default. [`cluster/kind-config.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/cluster/kind-config.yaml) forwards Mac ports to fixed **NodePorts**:

| Mac port | NodePort | Goes to |
|---|---|---|
| 80 | 30080 | Traefik `web` entrypoint (HTTP) |
| 443 | 30443 | Traefik `websecure` entrypoint (HTTPS) |
| 25565 | 30565 | Minecraft (raw TCP — bypasses the ingress) |

A NodePort is open on **every** node, and kube-proxy forwards it to wherever the pods actually run — so mapping only the control-plane node is enough.

!!! warning
    Port mappings are fixed when the cluster is created. Changing `kind-config.yaml` requires a rebuild.

## Built-in extras from kind

- **kindnet** — the pod network (CNI).
- **local-path-provisioner** — the default `standard` StorageClass. See [Storage](storage.md).

kind does **not** include metrics-server or an ingress controller; both are installed by Argo CD.
