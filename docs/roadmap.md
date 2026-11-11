# Roadmap

## The seven projects

- [x] **1. Minecraft server** — Deployments, Services, PersistentVolumes
- [x] **2. Break things on purpose** — pod kills, node drain, memory starvation, probes, HPA + load test
- [x] **3. Hostnames and HTTPS**
    - [x] Traefik ingress with `*.localhost`
    - [x] cert-manager with a local certificate authority, trusted by the Mac
- [x] **4. Monitoring** — `kube-prometheus-stack` (Prometheus + Grafana), app metrics, a custom dashboard; watch the HPA from project 2
- [x] **5. GitOps with Argo CD** — app of apps, auto-sync, prune, self-heal, Argo CD manages itself
- [ ] **6. Write a Kubernetes extension** — a custom resource and controller with kubebuilder
- [ ] **7. Graduate to the cloud** — Terraform a small managed cluster (e.g. EKS), deploy the same manifests, destroy it afterwards

## Next up

1. **Local LLMs** — llama.cpp on the Mac (GPU), called from the cluster, its `/metrics` scraped into Grafana.
2. **A full rebuild** to prove everything comes back from Git.

Done: ~~Argo CD manages itself~~ ([GitOps](gitops.md#argo-cd-manages-itself)) · ~~cert-manager~~ ([HTTPS](https.md)) · ~~monitoring~~ ([Monitoring](monitoring.md)).

## Later

- **Test harness / scripts** — automate the experiments (record state → break something → verify → report).
- **Local LLMs** — run models natively on macOS for GPU acceleration (they'd be CPU-only inside the kind VM) and have cluster apps call out to them.

## Ideas parked along the way

- Minecraft as a **StatefulSet** instead of a Deployment.
- Pin `itzg/minecraft-server` to a specific version.
- Argo CD `resources-finalizer` so removing an app also removes its resources.
- Gateway API instead of the Ingress API.
- Delete the `argocd-initial-admin-secret` after first login, as Argo CD recommends.
- Redirect HTTP → HTTPS in Traefik (`ports.web.redirections`).
- Scrape Argo CD and cert-manager (their charts have `serviceMonitor.enabled` switches) and import community dashboards.
- **Security hardening:** a `homelab` AppProject with a repo/destination allowlist (then test it by pointing an app at a disallowed repo); Pod Security Admission labels on app namespaces; Trivy image scanning; image digests instead of tags. See [Helm → How charts are secured](helm.md#how-charts-are-secured).
- Alertmanager notifications (e.g. to a Slack or email receiver).
- Re-enable etcd / scheduler / controller-manager metrics with kind `kubeadmConfigPatches` (bind to `0.0.0.0`).
- Secrets in Git, safely: SOPS or Sealed Secrets (would replace the hand-loaded CA Secret).
