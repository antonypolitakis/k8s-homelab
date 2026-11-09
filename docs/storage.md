# Storage

Pods are disposable. Anything written inside a container disappears with it. Apps that need to keep data — like Minecraft's world — use **persistent volumes**.

## The four objects

```
Pod  ──uses──►  PersistentVolumeClaim  ──bound to──►  PersistentVolume  ──is──►  a real disk / folder
                     ▲                                       ▲
                "I need 5Gi"                    created on demand by the StorageClass
```

| Object | Who writes it | What it says |
|---|---|---|
| **PersistentVolumeClaim (PVC)** | You (`apps/minecraft/pvc.yaml`) | "I need 5Gi, read-write by one node (`ReadWriteOnce`)." Says nothing about *where*. |
| **StorageClass** | kind (`standard`, the default) | *How* to satisfy claims — which provisioner, what to do on delete. |
| **PersistentVolume (PV)** | The provisioner, automatically | The actual volume, including *where* it lives. |
| **Pod** | You (`deployment.yaml`) | Mounts the claim **by name** at a path (`/data`). |

The pod only ever references the claim's name. When it starts, the node's kubelet bind-mounts the PV into the container.

## Where the Minecraft world actually is

kind's default StorageClass:

```
standard (default)   rancher.io/local-path   Delete   WaitForFirstConsumer
```

- **`rancher.io/local-path`** — satisfies a claim by creating a plain **folder on one node's disk**.
- **`WaitForFirstConsumer`** — the folder isn't created until a pod needs it, then it's created on **whichever node the scheduler picked** for that pod. From then on, the data lives there.
- **`Delete`** — deleting the PVC deletes the PV and the folder.

So the world is at:

```
Your Mac's SSD
└── OrbStack VM disk
    └── Docker container "homelab-worker"            (a kind node)
        └── /var/local-path-provisioner/pvc-<uid>_minecraft_minecraft-data/
                ▲
                └── mounted into the Minecraft pod as /data
```

Look at it from both sides:

```bash
docker exec homelab-worker ls /var/local-path-provisioner/
kubectl exec -n minecraft deploy/minecraft -- ls /data
```

The PV carries **node affinity** to that node:

```bash
kubectl get pv -o jsonpath='{.items[0].spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'
```

## What survives what

| Event | World survives? | Why |
|---|---|---|
| Pod deleted | ✅ | PVC, PV and folder are independent of the pod |
| Node drained | ⚠️ pod stuck `Pending` | PV's node affinity points at a cordoned node |
| Node uncordoned | ✅ | Pod schedules back onto that node, same folder |
| Cluster deleted | ❌ | The folder was inside the node container |
| PVC removed from Git | ❌ | Argo CD prunes it; reclaim policy `Delete` removes the data |

## local-path limitations

- **Not really persistent** — tied to one node; gone with the node.
- **Size isn't enforced** — the 5Gi is a label, not a quota.
- **No moving** — a pod can never run anywhere but the node holding its data.

In a cloud cluster the StorageClass provisions a **network disk** (e.g. AWS EBS). That PV has no fixed node: it detaches from one node and attaches to another, so drains don't strand the pod. The manifests stay the same — only the StorageClass behind them changes.

!!! tip "Prove persistence with the world seed"
    Every Minecraft world has a seed fixed at creation. Same seed before and after an event = same world.

    ```bash
    kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed
    ```
