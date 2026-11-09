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

## Tools

**`kubectl` version skew**
: kubectl must be within one minor version of the cluster. Use the Homebrew kubectl, not an old one in `/usr/local/bin`.

**`docker: command not found` after installing OrbStack**
: Open OrbStack once, then open a new terminal tab.

**`mkdocs: bad interpreter: .../python3.9: no such file or directory`**
: A stale Homebrew mkdocs pointing at a removed Python. Use a virtualenv instead (see the README's Docs section), or `brew reinstall mkdocs`.
