# HTTPS (cert-manager)

<https://argocd.localhost> and <https://podinfo.localhost> show a padlock, with real certificates signed by a certificate authority (CA) that only this Mac trusts.

## The pieces

```
~/.homelab-ca/ca.key + ca.crt     ← made once on the Mac, NEVER in Git
        │  ca.crt trusted in the macOS System keychain
        ▼
Secret homelab-ca  (ns cert-manager)   ← loaded by bootstrap.sh
        ▼
ClusterIssuer homelab-ca               ← Git: apps/cluster-issuers/
        ▼
Ingress with annotation + tls: block   ← Git
        ▼  cert-manager notices, creates a Certificate, signs it
Secret argocd-server-tls / podinfo-tls
        ▼
Traefik serves it on :443  →  🔒
```

| Piece | What it is | Where it's defined |
|---|---|---|
| **cert-manager** v1.21.3 | Controller that issues and renews certificates | [`argocd/apps/cert-manager.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/apps/cert-manager.yaml) (Helm chart, `crds.enabled: true`) |
| **ClusterIssuer** `homelab-ca` | "Sign certificates with the CA in Secret `homelab-ca`" | [`apps/cluster-issuers/`](https://github.com/antonypolitakis/k8s-homelab/tree/main/apps/cluster-issuers) |
| **Secret** `homelab-ca` | The CA's certificate and private key | Hand-loaded by `bootstrap.sh` from `~/.homelab-ca/` |
| **Certificate** (one per Ingress) | A request: "this host, into this Secret" | Created automatically by cert-manager from the Ingress annotation |

## Why a CA made on the Mac?

There are three ways to get trusted certificates for `*.localhost`:

| Option | Problem |
|---|---|
| Let's Encrypt | Can only issue for public domains it can verify. `localhost` isn't one. |
| cert-manager generates the CA in-cluster | A **new** CA on every rebuild → re-trust it on the Mac every time. |
| **CA made once on the Mac** ✅ | Trusted once, lasts 10 years, survives rebuilds. The key just has to stay out of Git. |

### Name constraint

The CA can **only** sign certificates for `localhost` and its subdomains:

```
X509v3 Name Constraints: critical
    Permitted:
      DNS:localhost
```

Your Mac trusts this CA, so a leaked key could otherwise be used to fake *any* website to you. With the constraint, the worst it can fake is `*.localhost`. (Tested: a certificate it signs for `evil.example.com` fails verification.)

## One-time setup on the Mac

**1. Create the CA**

```bash
mkdir -p ~/.homelab-ca
cd ~/.homelab-ca
openssl req -x509 -newkey rsa:4096 -noenc -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=k8s-homelab local CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;DNS:localhost"
chmod 600 ca.key
cd -
```

**2. Trust it** (asks for your password)

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/.homelab-ca/ca.crt
```

Safari and Chrome use the keychain straight away; Firefox may need a restart.

**3. Load it into the cluster** — `bootstrap.sh` does this on every rebuild:

```bash
kubectl create namespace cert-manager
kubectl create secret tls homelab-ca -n cert-manager \
  --cert=$HOME/.homelab-ca/ca.crt --key=$HOME/.homelab-ca/ca.key
```

!!! danger "Never commit `ca.key`"
    It lives in `~/.homelab-ca/`, outside the repo, readable only by you. This Secret is the one deliberate exception to "everything in Git". Tools like SOPS or Sealed Secrets can put secrets in Git safely — a later topic.

**To remove the CA** from the Mac:

```bash
sudo security delete-certificate -c "k8s-homelab local CA" /Library/Keychains/System.keychain
```

## The chicken and the egg

On a fresh cluster, the `cluster-issuers` app syncs at the same time as `cert-manager` — before the `ClusterIssuer` kind exists. Two settings handle that:

```yaml
syncOptions:
  - SkipDryRunOnMissingResource=true   # don't fail the dry run for an unknown kind
retry:
  limit: 10
  backoff:
    duration: 10s                      # try again until cert-manager's CRDs exist
```

A failed first sync on that app is normal; it goes green on its own.

## Giving an app HTTPS

Two additions to its Ingress — an annotation and a `tls:` block:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca
spec:
  tls:
    - hosts:
        - podinfo.localhost
      secretName: podinfo-tls     # cert-manager creates this Secret
  rules:
    ...
```

For Argo CD the chart writes the Ingress, so it's set through [`argocd/values.yaml`](https://github.com/antonypolitakis/k8s-homelab/blob/main/argocd/values.yaml) — and Argo CD applies the change to itself:

```yaml
server:
  ingress:
    tls: true                     # → tls: block for argocd.localhost, Secret argocd-server-tls
    annotations:
      cert-manager.io/cluster-issuer: homelab-ca
```

Argo CD still runs with `server.insecure: true`: **Traefik** terminates TLS, then talks plain HTTP to argocd-server inside the cluster.

## Checking it

```bash
kubectl get clusterissuer                 # homelab-ca   READY True
kubectl get certificate -A                # one per Ingress, READY True
curl -sI --cacert ~/.homelab-ca/ca.crt https://argocd.localhost | head -1

# What Traefik is actually serving
echo | openssl s_client -connect localhost:443 -servername argocd.localhost 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName -dates
```

Expected: issuer `CN=k8s-homelab local CA`, SAN `DNS:argocd.localhost`, valid 90 days. cert-manager renews automatically about 30 days before expiry.

The certificate's *subject* is empty — that's normal. Browsers only look at the SAN (Subject Alternative Name).

## Not done (yet)

- **HTTP → HTTPS redirect.** `http://` still works. Traefik can redirect with `ports.web.redirections` in its values.
- **Secrets in Git** with SOPS or Sealed Secrets, replacing the hand-loaded CA Secret.
