# SCRIPTS

Server bootstrap scripts. One command each, no dependencies to install first.

| Script | What it does |
|---|---|
| [`setup-github.sh`](setup-github.sh) | Prepares a VPS for GitHub Actions deployment: generates a deploy key, configures SSH, and prints the exact repository secrets to paste into GitHub. |

---

## setup-github.sh

### Quick start

Run this on the VPS you want to deploy **to**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/setup-github.sh)
```

Prefer to read before you run? (recommended for anything you pipe into a shell)

```bash
curl -fsSL -o setup-github.sh https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/setup-github.sh
less setup-github.sh
chmod +x setup-github.sh && ./setup-github.sh
```

Piping works too — arguments go after `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/setup-github.sh | bash -s -- --port 2222 --save
```

### What it does

1. Installs `git` and `curl` if missing (apt / dnf / yum / apk / pacman / zypper).
2. Creates an `ed25519` deploy key at `~/.ssh/deploy_key` — or keeps the existing one.
3. Adds a **managed block** to `~/.ssh/config` for `github.com`. Your other hosts are left untouched.
4. Pins GitHub's host keys in `~/.ssh/known_hosts`, without duplicating them on re-runs.
5. Tests authentication against GitHub.
6. Detects your **real public IP** by asking an external service, not `hostname -I` — which returns the private `10.x` NAT address on most VPS providers.
7. Reads the real SSH port from `sshd_config`.
8. Prints everything you need to paste into GitHub.

Safe to run more than once. Nothing is duplicated or overwritten.

### Options

| Flag | Description |
|---|---|
| `-n, --key-name NAME` | Key filename inside `~/.ssh` (default: `deploy_key`) |
| `-H, --host IP` | Override the detected host/IP |
| `-p, --port PORT` | Override the detected SSH port |
| `-u, --user NAME` | Override the reported username |
| `-f, --force` | Regenerate the key (the old one is backed up) |
| `--no-private` | Never print the private key on screen |
| `--save` | Write a summary to `~/github-deploy-info.txt` (mode `600`) |
| `-q, --quiet` | Less output |
| `-h, --help` | Show help |

### After running

**1. Add the deploy key** — Repository → *Settings* → *Deploy keys* → *Add deploy key*
Paste the **public** key. Tick *Allow write access* only if your workflow pushes back to the repo.

**2. Add the secrets** — Repository → *Settings* → *Secrets and variables* → *Actions*

| Secret | Value |
|---|---|
| `VPS_HOST` | Public IP printed by the script |
| `VPS_PORT` | SSH port (usually `22`) |
| `VPS_USERNAME` | The user the script ran as |
| `VPS_SSH_KEY` | Full private key, including the `BEGIN`/`END` lines |

**3. Verify** on the VPS:

```bash
ssh -T git@github.com
```

You want: *"You've successfully authenticated, but GitHub does not provide shell access."*

### Example workflow

`.github/workflows/deploy.yml`

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy over SSH
        uses: appleboy/ssh-action@v1
        with:
          host:     ${{ secrets.VPS_HOST }}
          port:     ${{ secrets.VPS_PORT }}
          username: ${{ secrets.VPS_USERNAME }}
          key:      ${{ secrets.VPS_SSH_KEY }}
          script: |
            set -e
            cd /var/www/myapp
            git pull origin main
            # npm ci && npm run build && sudo systemctl restart myapp
```

### Notes

- The script prints the private key so you can copy it into the GitHub secret. Use `--no-private` on a shared screen or a recorded session, then read it with `cat ~/.ssh/deploy_key`.
- The key is generated **on the server** and never leaves it except through your clipboard. Nothing is uploaded anywhere.
- A deploy key belongs to one repository. For several repos, generate one per repo with `--key-name` and give each its own `Host` alias.
- If the script reports a `10.x`, `172.16–31.x`, or `192.168.x` address, it could not reach a public-IP service. Re-run with `--host YOUR.PUBLIC.IP`.

### Requirements

Any Linux VPS with `bash` and outbound HTTPS. Root or `sudo` is only needed if `git` or `curl` are missing.

---

## Troubleshooting

**`Permission denied (publickey)` in Actions** — the private key in `VPS_SSH_KEY` is incomplete. Copy the whole thing, including `-----BEGIN OPENSSH PRIVATE KEY-----` and the trailing newline.

**`Host key verification failed`** — the runner doesn't know your VPS. The workflow example above handles this; if you're using raw `ssh`, add `-o StrictHostKeyChecking=accept-new`.

**Connection times out** — `VPS_HOST` is a private IP, or your firewall blocks the SSH port. Check with `sudo ufw status`.

**The raw URL serves an old version** — GitHub caches raw files for a few minutes. Add `?v=$(date +%s)` while you're iterating.
