# Docs site

This wiki, served from inside the cluster.

- **URL:** <https://docs.localhost>
- **Manifests:** [`apps/docs/`](https://github.com/antonypolitakis/k8s-homelab/tree/main/apps/docs)
- **Updates:** within ~70 seconds of a push to `main` — no new pod, no Argo CD sync.

## How it works

One pod, three containers, two shared scratch volumes:

```
GitHub (main)
   │  pulls every 60s
   ▼
git-sync ──writes──► /git      emptyDir   /git/root/current → .worktrees/<commit>
                       │
                       ▼ reads
mkdocs   ──writes──► /site     emptyDir   /site/<commit>/  +  /site/live → <commit>
                       │
                       ▼ reads
nginx    ── :80 ◄── Service docs ◄── Traefik ◄── https://docs.localhost
```

| Container | Image | Job |
|---|---|---|
| `git-sync` | `registry.k8s.io/git-sync/git-sync:v4.8.0` | Keeps a checkout of the repo up to date. Each new commit goes into its own folder, then the `current` link is switched to it **atomically**. |
| `mkdocs` | `squidfunk/mkdocs-material:9.8.1` | Runs [`build-loop.sh`](https://github.com/antonypolitakis/k8s-homelab/blob/main/apps/docs/build-loop.sh): when `current` points at a new commit, `mkdocs build --strict` into `/site/<commit>`, then repoint `/site/live`. |
| `nginx` | `nginx:1.30-alpine` | Serves `/site/live`. Config: [`nginx.conf`](https://github.com/antonypolitakis/k8s-homelab/blob/main/apps/docs/nginx.conf). |

## Ideas it uses

**Multi-container pod.** Containers in a pod share volumes and a network. Each does one job, and they talk through the filesystem.

**`emptyDir` volumes.** Scratch space that lives exactly as long as the pod. Nothing to back up: a new pod re-clones and rebuilds in under a minute.

**Native sidecar.** git-sync is declared as an `initContainer` with `restartPolicy: Always`. It starts *before* the main containers and then keeps running alongside them (built into Kubernetes since v1.33).

**`configMapGenerator`.** kustomize turns `build-loop.sh` and `nginx.conf` into ConfigMaps whose names include a hash of their content (`docs-build-6mtdgbbkth`). Edit either file and the name changes → the pod template changes → a new pod rolls out. A hand-written ConfigMap wouldn't trigger a restart.

**Readiness that checks content.** nginx returns 404 until the first build lands, so the readiness probe on `/` keeps the pod out of the Service until there's a site to serve.

**Failed builds don't go live.** A commit that fails the strict build (broken link, missing nav page) is logged as `FAILED`; `/site/live` stays on the last good commit.

## Two kinds of change

| You push… | What happens |
|---|---|
| A change under `docs/` or `mkdocs.yml` | git-sync pulls it, mkdocs rebuilds. Same pod. |
| A change under `apps/docs/` | Argo CD syncs the manifests; usually a new pod. |

## Watching it

```bash
kubectl get pods -n docs                          # 3/3 when serving
kubectl logs -n docs deploy/docs -c mkdocs -f     # building / serving / FAILED
kubectl logs -n docs deploy/docs -c git-sync      # JSON logs, one line per sync
```

## Gotcha hit while building it

git-sync crash-looped with `detected dubious ownership in repository at '/git'`. The volume is owned by root, git-sync runs as UID 65533, and git (since 2022) refuses to work in a repo owned by another user. The fix is `--root=/git/root`: git-sync creates that subfolder itself, so it owns it.

## Later

The "production" way is to build an nginx image with the site baked in, in GitHub Actions, push it to a registry, and have Argo CD roll out each new tag — immutable versions and easy rollbacks, at the cost of a CI pipeline.
