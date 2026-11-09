# k8s-homelab

Yo yo yo! :)
A local Kubernetes learning lab on an Apple Silicon Mac, run the **GitOps** way: the Git repo is the source of truth, and Argo CD keeps the cluster in sync with it.

```
 git push ──► GitHub (this repo) ◄── polls ── Argo CD ──► kind cluster "homelab"

 browser ──► https://<app>.localhost ──► Traefik (ingress) ──► app Service ──► pods
```

## What's running

| URL | What |
|---|---|
| <https://argocd.localhost> | Argo CD UI (user `admin`) |
| <https://podinfo.localhost> | podinfo — a small demo web app, autoscaled |
| `localhost:25565` | Minecraft server (Java Edition) |

## The big ideas

**Everything is declared in Git.** You never tell the cluster *what to do*; you describe *what should exist* (a Deployment with 2 replicas, a 5 GB volume, a hostname) and Kubernetes works continuously to make it true.

**Argo CD closes the loop.** It watches the repo and the cluster. Push a change and it applies it; change the cluster by hand and it puts it back.

**The cluster is disposable.** It's built from Docker containers by [kind](https://kind.sigs.k8s.io) and can be deleted and rebuilt from Git in about three minutes. Only *data* (like the Minecraft world) is lost — which is itself a lesson.

## Where to go next

- New here? Start with [Setup & bootstrap](setup.md), then [The cluster](cluster.md).
- Want to understand the plumbing? Read [GitOps with Argo CD](gitops.md), [Ingress](ingress.md), [HTTPS](https.md) and [Storage](storage.md).
- Want to see what's been tried and what it taught? See the [Experiments](experiments.md) log.
