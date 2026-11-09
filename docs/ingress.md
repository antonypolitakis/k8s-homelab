# Ingress (Traefik)

## Why an ingress

Before the ingress, every web app needed its own `kubectl port-forward`. Port-forwards:

- need a terminal tab each,
- die when the cluster is rebuilt,
- are **pinned to a single pod** — if that pod dies, the forward dies, even though the app is fine.

An **ingress controller** is a reverse proxy running in the cluster. It receives all HTTP(S) traffic and routes each request to the right Service by **hostname**, load-balancing across all *ready* pods.

## Why Traefik

The other common choice, community **ingress-nginx**, was retired in March 2026 and no longer receives fixes. [Traefik](https://traefik.io) is actively maintained, supports both the classic Ingress API and the newer Gateway API, and installs cleanly with Helm.

Installed: Traefik **v3.7.17**, Helm chart **42.3.1**, as an Argo CD Application ([`argocd/apps/traefik.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/traefik.yaml)).

## How a request flows

```
http://podinfo.localhost
  │  *.localhost always resolves to 127.0.0.1 — no DNS or /etc/hosts needed
  ▼
Mac :80
  ▼  kind port mapping (cluster/kind-config.yaml)
control-plane node :30080
  ▼  NodePort Service → wherever the Traefik pod runs
Traefik
  │  Host header "podinfo.localhost" matches an Ingress rule
  ▼
Service podinfo :9898  ──►  any ready podinfo pod
```

## Configuration

```yaml
helm:
  valuesObject:
    service:
      spec:
        type: NodePort          # kind has no cloud load balancer
    ports:
      web:
        nodePort: 30080         # Mac :80  → here
      websecure:
        nodePort: 30443         # Mac :443 → here
    ingressClass:
      enabled: true
      isDefaultClass: true      # Ingresses with no class use Traefik
    providers:
      kubernetesIngress:
        publishedService:
          enabled: false
        ingressEndpoint:
          ip: 127.0.0.1
```

### Why `ingressEndpoint.ip: 127.0.0.1`

Argo CD only marks an Ingress **Healthy** once the controller writes an address into its status (the `ADDRESS` column of `kubectl get ingress`). Traefik normally copies that address from its own Service — but a NodePort Service has none, so the field stays empty and every app with an Ingress sits at **Progressing** forever. Publishing `127.0.0.1` (where the ingress really is, from the Mac) fixes it.

### Argo CD behind the ingress

Argo CD gets its Ingress from its own Helm chart (`server.ingress` in `argocd/values.yaml`). It also needs `server.insecure: true`: by default argocd-server serves HTTPS and redirects HTTP to HTTPS, which loops endlessly behind a proxy that talks HTTP to it.

## Exposing a new app

Add `apps/<name>/ingress.yaml`, list it in `kustomization.yaml`, push:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <name>
spec:
  ingressClassName: traefik
  rules:
    - host: <name>.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <service-name>
                port:
                  number: <service-port>
```

## Seeing the load balancing

```bash
for i in 1 2 3 4 5 6; do curl -s http://podinfo.localhost | grep hostname; done
```

The hostname alternates between replicas — something a port-forward never does.

## HTTPS

Traefik terminates TLS on port 443 using certificates issued by cert-manager from a local CA. Adding two things to an Ingress — an annotation and a `tls:` block — is all an app needs. See [HTTPS](https.md).

Plain `http://` still works too (there's no redirect yet).
