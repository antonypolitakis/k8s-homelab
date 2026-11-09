# Minecraft

A Minecraft Java Edition server using the community [`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) image. It was project 1: the classic way to learn Deployments, Services and PersistentVolumes, because the world has to survive the pod.

- **Address:** `localhost:25565` (Minecraft **Java** Edition only — Bedrock can't connect)
- **Image:** `itzg/minecraft-server:stable` — follows the latest Minecraft release
- **Namespace:** `minecraft`

## Files — `apps/minecraft/`

| File | What |
|---|---|
| `namespace.yaml` | Namespace `minecraft` |
| `pvc.yaml` | 5Gi `ReadWriteOnce` claim `minecraft-data` → see [Storage](../storage.md) |
| `deployment.yaml` | 1 replica, `strategy: Recreate` (only one pod may use the disk), `EULA=TRUE`, `MEMORY=2G`, `MOTD`, readiness via `mc-health`, 2.5Gi request / 3Gi limit |
| `service.yaml` | NodePort 30565 → kind maps Mac 25565 to it |
| `kustomization.yaml` | Lists the above; sets namespace |

Minecraft speaks raw TCP, not HTTP, so it goes through a NodePort rather than the ingress.

## Without the game client

The image includes `rcon-cli`, which sends console commands to the running server:

```bash
kubectl exec -n minecraft deploy/minecraft -- rcon-cli seed       # the world's seed
kubectl exec -n minecraft deploy/minecraft -- rcon-cli list       # players online
kubectl exec -n minecraft deploy/minecraft -- printenv MOTD
kubectl logs -n minecraft deploy/minecraft -f
```

## Why `Recreate`, and why a StatefulSet would be better

`strategy: Recreate` stops the old pod before starting the new one during a *rollout*, so two servers never write the same world. But it only applies to rollouts: scaling to 0 and straight back to 1 briefly overlapped an old (terminating) pod and a new one. A **StatefulSet** guarantees the old pod is fully gone before its replacement starts — the usual choice for stateful apps.

## Playing

Install the Minecraft Launcher from minecraft.net (it runs under Rosetta; the game itself runs natively on Apple Silicon), then Multiplayer → Add Server → `localhost`.
