
# SCRIPTS

Server bootstrap scripts. One command each, no dependencies to install first.

| Script | What it does |
|---|---|
| [`setup-github.sh`](setup-github.sh) | Prepares a VPS for GitHub Actions deployment: generates a deploy key, configures SSH, and prints the exact repository secrets to paste into GitHub. |
| [`install-dev-tools.sh`](install-dev-tools.sh) | Installs and updates development tools: Node.js, npm, PM2, Python, Rust, Go, Docker, Git, and build tools. Auto-detects what's missing and installs latest versions. |

---

## install-dev-tools.sh

Automatically installs and updates all essential development tools. Checks if each tool is already installed and only installs what's missing. Safe to run multiple times.

### Quick start

Run this on any Linux VPS or local machine:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/install-dev-tools.sh)
```

Or with a specific tool (1-10):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/install-dev-tools.sh) 1
```

Prefer to read before you run? (recommended)

```bash
curl -fsSL -o install-dev-tools.sh https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/install-dev-tools.sh
less install-dev-tools.sh
chmod +x install-dev-tools.sh && ./install-dev-tools.sh
```

### What it does

- **Detects your package manager** (apt, dnf, yum, pacman, zypper, apk) automatically
- **Checks if tools are already installed** — skips re-installation
- **Installs latest versions** of all tools
- **Handles dependencies** (e.g., installs npm alongside Node.js)
- **Sets up services** (e.g., Docker daemon startup)
- **Color-coded output** so you can see what succeeded and what failed
- **Safe to run multiple times** — idempotent

### Menu options

```
1. Everything (recommended)        — All tools below
2. Git + curl                       — Git version control & curl
3. Node.js + npm                    — JavaScript runtime & package manager
4. PM2                              — Node.js process manager
5. Python 3                         — Python with pip & venv
6. Rust                             — Systems programming language
7. Go                               — Google's compiled language
8. Docker                           — Container platform
9. Git LFS                          — Large File Storage for Git
10. Build tools                     — gcc, make, build-essential, etc.
0. Exit
```

### Usage examples

**Install everything:**
```bash
./install-dev-tools.sh 1
```

**Install just Node.js & npm:**
```bash
./install-dev-tools.sh 3
```

**Interactive menu:**
```bash
./install-dev-tools.sh
# Then type your choice
```

**Download and run in one command:**
```bash
curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/install-dev-tools.sh | bash -s -- 1
```

### Supported systems

- **Debian/Ubuntu** (apt)
- **RHEL/CentOS/Fedora** (dnf/yum)
- **Arch Linux** (pacman)
- **openSUSE** (zypper)
- **Alpine** (apk)

### What gets installed

| Tool | Installed from | Latest version |
|---|---|---|
| Git | Package manager | Latest |
| curl | Package manager | Latest |
| Node.js | NodeSource (apt) or package manager | LTS |
| npm | With Node.js, then upgraded globally | Latest |
| PM2 | npm global | Latest |
| Python 3 | Package manager | Latest |
| Rust | rustup.rs | Latest |
| Go | Package manager or golang.org | Latest |
| Docker | Docker official repos | Latest |
| Git LFS | GitHub official repos | Latest |
| Build tools | Package manager | Latest |

### After running

Check your installations:

```bash
git --version
node --version
npm --version
pm2 --version
python3 --version
rustc --version
go version
docker --version
```

If you installed PM2, start the startup script (optional but recommended):

```bash
pm2 startup
```

### Notes

- **Sudo required** if you're not root (script handles this)
- **Interactive input** — script may ask for your password
- **Network access** required for downloading (curl, rustup, etc.)
- **Idempotent** — safe to run multiple times, won't duplicate installs
- **Colored output** — [INFO], [✓], [WARN], [✗] make it easy to scan

### Troubleshooting

**"No supported package manager found"**
- Your system isn't one of the supported distributions
- Try installing tools manually

**"npm update failed, continuing..."**
- Minor issue, npm is still functional
- You can manually update later with `sudo npm install -g npm@latest`

**"git-lfs not available via package manager"**
- Git LFS might not be in your distro's repos
- You can install from GitHub: https://git-lfs.github.com

**Sudo password prompt**
- This is normal — the script needs elevated privileges to install system packages
- Run it in an interactive terminal or with `sudo` at the start

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
