# Troubleshooting & gotchas

## Shell

**`zsh: command not found: #`** (or `not found` for each word of a comment)
: zsh doesn't treat `#` as a comment when typing interactively. Drop the comments, or add `setopt interactive_comments` to `~/.zshrc`.

**`zsh: parse error near '\n'`** with `<SOMETHING>` in a command
: `<placeholders>` must be replaced, angle brackets included — zsh reads `<` and `>` as redirects.

**Pasted heredoc produces a broken file**
: Long lines can get truncated when pasted into a terminal. For multi-line files, paste into an editor (`nano`, `code`) instead, then check with `cat -n` or `git diff`.

**Leftover `.swp` files**
: vim's swap files from an editor that didn't exit cleanly. Quit vim (`Esc`, `:q!`), then delete them. They're in `.gitignore`.

## Git

**`git commit -am` included files I didn't mean to commit**
: `-a` stages *every* modified tracked file. Run `git status` first; if more than you expect is listed, `git add <file>` and `git commit -m` without `-a`.

**`git commit -a` didn't include my new file**
: `-a` ignores untracked (new) files. `git add` them first.

## Argo CD

**App is OutOfSync and won't sync**
: Look at the last operation's message:
  ```bash
  kubectl get application <app> -n argocd -o jsonpath='{.status.operationState.message}'
  ```
  A typo like `memory: 8i` gives `unable to parse quantity's suffix` — the API server rejected it.

**App stuck at Progressing, and it has an Ingress**
: The Ingress has no `ADDRESS`. Fixed here by Traefik's `ingressEndpoint.ip: 127.0.0.1`. See [Ingress](ingress.md).

**My change isn't showing up**
: Did you push? Argo CD reads GitHub, not your laptop. Then press **Refresh** — otherwise it polls every ~3 minutes.

**The `argocd` app shows OutOfSync for every resource right after it's created**
: Expected on first adoption: the Helm-installed resources don't have Argo CD's `tracking-id` annotation yet. Compare first (`helm template … | kubectl diff -f -`); if the contents match, one sync adds the annotations without restarting anything.

**Argo CD itself is broken after a commit to `argocd/values.yaml`**
: Revert in Git, then re-run the Helm line from `bootstrap.sh` to get Argo CD back up; it will then sync from the fixed Git.

**Manual `kubectl` changes keep getting undone**
: That's `selfHeal`. Change Git instead.

## Networking

**`localhost:9898` refuses to connect**
: No port-forward is running (or it died with its pod). Use <http://podinfo.localhost> instead.

## HTTPS

**Browser shows a certificate warning, and the certificate is "TRAEFIK DEFAULT CERT"**
: cert-manager hasn't issued the certificate (yet). Check `kubectl get certificate -A` — `READY False` → `kubectl describe certificate -n <ns> <name>`. Right after a rebuild, give it a minute.

**`kubectl get clusterissuer` shows `READY False`**
: The `homelab-ca` Secret is missing from the `cert-manager` namespace — usually a rebuild without `~/.homelab-ca/`. Load it with the two `kubectl create` lines in `bootstrap.sh`.

**Certificate is from `k8s-homelab local CA` but the browser still doesn't trust it**
: The CA isn't in the System keychain (`security find-certificate -c "k8s-homelab local CA" /Library/Keychains/System.keychain`). Re-run the `security add-trusted-cert` step. Firefox may need a restart.

**`curl: (60) SSL certificate problem`**
: Your `curl` doesn't read the macOS keychain. Use `curl --cacert ~/.homelab-ca/ca.crt https://…`.

**`cluster-issuers` app failed its first sync**
: Expected on a fresh cluster: the `ClusterIssuer` kind doesn't exist until cert-manager installs its CRDs. The app's `retry` policy fixes it on its own.

## Pods

**`Pending`**
: `kubectl describe pod <pod>` → Events. Common causes: node affinity from a local volume, cordoned nodes, not enough CPU/memory.

**`OOMKilled` / exit code 137**
: Exceeded its memory limit. Raise `resources.limits.memory`.

**`CrashLoopBackOff`**
: The container keeps exiting. `kubectl logs <pod> --previous` shows the last crash.

## Monitoring

**Grafana rejects the password from the Secret**
: Grafana only reads its admin password when its database is first created. If the Secret changed afterwards, they disagree. Delete the Grafana pod (`kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana`) — its `emptyDir` database is recreated with the current password.

**An app flips to OutOfSync on its own and "fixes" a Secret**
: The chart generates a random value on every render. Set it explicitly or use an existing Secret. See [GitOps](gitops.md#charts-that-generate-random-values).

**New ServiceMonitor, but no target in Prometheus**
: Check that the ServiceMonitor's `selector` matches the **Service's** labels (not the pod's), and that `port:` is the Service port's **name**. Then wait ~30s for the operator to reload Prometheus. **Status → Targets** shows it, or `lastError` if scraping fails.

**Custom dashboard doesn't appear in Grafana**
: The ConfigMap needs the label `grafana_dashboard: "1"`. `kubectl logs -n monitoring deploy/monitoring-grafana -c grafana-sc-dashboard` shows whether the sidecar picked it up.

**A dashboard edited in Grafana disappeared**
: Grafana's storage is an `emptyDir`. Export the JSON into `apps/dashboards/` instead.

**Grafana is slower to react than `kubectl get hpa -w`**
: Expected: 15–30s scrape interval plus a 1-minute `rate()` window. See [Monitoring](monitoring.md#two-pipelines).

## Docs app

**git-sync crash-loops: `detected dubious ownership in repository at '/git'`**
: The `emptyDir` is owned by root; git-sync runs as UID 65533 and git refuses a repo owned by someone else. Point `--root` at a subfolder (`/git/root`) so git-sync creates — and owns — it.

**docs.localhost didn't update after a push**
: `kubectl logs -n docs deploy/docs -c mkdocs`. `FAILED` means the strict build rejected the commit (broken link, bad nav entry) — the previous version is still served. Reproduce locally with `mkdocs build --strict`.

**A broken page was published anyway**
: Don't add `-q` to `mkdocs build`: quiet mode hides warnings, and `--strict` only fails on warnings it sees.

## Tools

**`kubectl` version skew**
: kubectl must be within one minor version of the cluster. Use the Homebrew kubectl, not an old one in `/usr/local/bin`.

**`docker: command not found` after installing OrbStack**
: Open OrbStack once, then open a new terminal tab.

**`mkdocs: bad interpreter: .../python3.9: no such file or directory`**
: A stale Homebrew mkdocs pointing at a removed Python. Use a virtualenv instead (see the README's Docs section), or `brew reinstall mkdocs`.
