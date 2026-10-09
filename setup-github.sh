#!/usr/bin/env bash
# setup-github.sh — Bootstrap GitHub Actions SSH deployment to a VPS.
# Run this ON the VPS to authorize the generated key locally, or run it on
# your workstation with --remote-setup to install the public key over SSH.

set -Eeuo pipefail
umask 077

KEY_NAME="deploy_key"
FORCE=0
PRINT_PRIVATE=0
WRITE_ENV=0
ENV_FILE="$HOME/github-deploy.env"
REPO=""
PUSH=0
SAVE_SUMMARY=0
REMOTE_SETUP=0
HOST=""
PORT=""
LOGIN_USER=""
DEPLOY_USER=""
QUIET=0

SSH_DIR="$HOME/.ssh"
MARK_BEGIN="# >>> setup-github.sh managed block >>>"
MARK_END="# <<< setup-github.sh managed block <<<"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
step() { [[ "$QUIET" -eq 1 ]] || printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./setup-github.sh [options]

Options:
  -n, --key-name NAME     SSH key name (default: deploy_key)
  -H, --host HOST         Public IP or hostname of the VPS
  -p, --port PORT         VPS SSH port (default: detected/22)
  -u, --user USER         SSH login username (default: current user)
      --deploy-user USER  Account on the VPS whose authorized_keys is updated
      --remote-setup      Install the public key on the VPS over SSH.
                          Requires existing SSH access to the VPS.
  -r, --repo OWNER/REPO   GitHub repository (for example: owner/my-app)
      --push              Set GitHub repository secrets using the gh CLI
  -e, --env               Write secrets to ~/github-deploy.env (private file)
      --env-file PATH     Write the environment file to PATH
      --print-private     Print the private key (unsafe; avoid if possible)
      --save              Save non-secret connection details to a summary file
  -f, --force             Back up and replace an existing key
  -q, --quiet             Reduce normal output
  -h, --help              Show this help

Typical use ON the VPS:
  chmod +x setup-github.sh
  ./setup-github.sh --repo OWNER/REPO --push

Typical use from your workstation:
  ./setup-github.sh -H VPS_PUBLIC_IP -u ubuntu --remote-setup --repo OWNER/REPO --push

GitHub CLI must already be authenticated (`gh auth login`) for --push.
The script never opens cloud firewall/security-list ports. Allow TCP/22 (or your
custom SSH port) in the VPS firewall and Oracle Cloud security list/NSG.
EOF
}
while (($#)); do
  case "$1" in
    -n|--key-name) KEY_NAME="${2:?missing value}"; shift 2 ;;
    -H|--host) HOST="${2:?missing value}"; shift 2 ;;
    -p|--port) PORT="${2:?missing value}"; shift 2 ;;
    -u|--user) LOGIN_USER="${2:?missing value}"; shift 2 ;;
    --deploy-user) DEPLOY_USER="${2:?missing value}"; shift 2 ;;
    --remote-setup) REMOTE_SETUP=1; shift ;;
    -r|--repo) REPO="${2:?missing value}"; shift 2 ;;
    --push) PUSH=1; shift ;;
    -e|--env) WRITE_ENV=1; shift ;;
    --env-file) ENV_FILE="${2:?missing value}"; WRITE_ENV=1; shift 2 ;;
    --print-private) PRINT_PRIVATE=1; shift ;;
    --save) SAVE_SUMMARY=1; shift ;;
    -f|--force) FORCE=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid key name"
KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_PATH="$KEY_PATH.pub"
[[ -n "$DEPLOY_USER" ]] || DEPLOY_USER="${LOGIN_USER:-$(id -un)}"

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"
  elif have sudo; then sudo "$@"
  else die "root/sudo is required to update another user's authorized_keys"
  fi
}

detect_port() {
  local p=""
  if [[ -r /etc/ssh/sshd_config ]]; then
    p="$(awk 'tolower($1)=="port" && $1 !~ /^#/ {print $2; exit}' /etc/ssh/sshd_config)"
  fi
  printf '%s' "${p:-22}"
}
detect_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

step "Checking dependencies"
for bin in ssh-keygen ssh; do
  have "$bin" || die "$bin is required; install the OpenSSH client package and retry"
done
if [[ "$PUSH" -eq 1 ]]; then
  have gh || die "GitHub CLI (gh) is required for --push: https://cli.github.com"
  [[ -n "$REPO" && "$REPO" == */* ]] || die "--push requires -r OWNER/REPO"
fi

step "Creating SSH directory and deploy key"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
if [[ -f "$KEY_PATH" && -f "$PUB_PATH" && "$FORCE" -eq 0 ]]; then
  say "  Reusing existing key: $KEY_PATH"
else
  if [[ -e "$KEY_PATH" || -e "$PUB_PATH" ]]; then
    cp -a "$KEY_PATH" "$KEY_PATH.bak.$(date +%s)" 2>/dev/null || true
    cp -a "$PUB_PATH" "$PUB_PATH.bak.$(date +%s)" 2>/dev/null || true
    rm -f "$KEY_PATH" "$PUB_PATH"
  fi
  ssh-keygen -q -t ed25519 -a 100 \
    -C "github-actions-deploy@$(hostname -s 2>/dev/null || echo vps)" \
    -f "$KEY_PATH" -N "" </dev/null
  say "  Created $KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$PUB_PATH"

# Determine the endpoint values to store in GitHub.
if [[ -z "$HOST" ]]; then
  HOST="$(detect_public_ip || true)"
fi
[[ -n "$HOST" ]] || {
  if [[ "$REMOTE_SETUP" -eq 0 ]]; then
    HOST="REPLACE_WITH_VPS_PUBLIC_IP"
    warn "Could not detect a public IP. Set VPS_HOST manually in GitHub or rerun with -H."
  else
    die "provide the VPS public IP/hostname with -H when using --remote-setup"
  fi
}
PORT="${PORT:-$(detect_port)}"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "invalid SSH port"
LOGIN_USER="${LOGIN_USER:-$(id -un)}"

step "Authorizing the public key for GitHub Actions"
if [[ "$REMOTE_SETUP" -eq 1 ]]; then
  [[ "$HOST" != "REPLACE_WITH_VPS_PUBLIC_IP" ]] || die "provide the VPS host with -H"
  # Install the public key over SSH; existing authorized_keys entries are preserved.
  cat "$PUB_PATH" | ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$LOGIN_USER@$HOST" "sudo bash -c 'u=\"$DEPLOY_USER\"; id \"\$u\" >/dev/null || exit 2; h=\$(getent passwd \"\$u\" | cut -d: -f6); test -n \"\$h\" || exit 3; install -d -m 700 -o \"\$u\" -g \"\$u\" \"\$h/.ssh\"; touch \"\$h/.ssh/authorized_keys\"; chown \"\$u:\$u\" \"\$h/.ssh/authorized_keys\"; chmod 600 \"\$h/.ssh/authorized_keys\"; k=\$(cat); grep -qxF -- \"\$k\" \"\$h/.ssh/authorized_keys\" || printf \"%s\\n\" \"\$k\" >> \"\$h/.ssh/authorized_keys\"; chown \"\$u:\$u\" \"\$h/.ssh/authorized_keys\"; chmod 600 \"\$h/.ssh/authorized_keys\"; echo OK'"
  say "  Public key installed on $HOST for user $DEPLOY_USER"
else
  # Local mode is intended when this script is being run on the target VPS.
  getent passwd "$DEPLOY_USER" >/dev/null 2>&1 || die "VPS user '$DEPLOY_USER' does not exist locally. Use --remote-setup from your workstation."
  TARGET_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "could not find home directory for $DEPLOY_USER"
  as_root install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$TARGET_HOME/.ssh"
  AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
  as_root touch "$AUTH_KEYS"
  as_root chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
  as_root chmod 600 "$AUTH_KEYS"
  PUB_KEY="$(cat "$PUB_PATH")"
  if ! as_root grep -qxF -- "$PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
    printf '%s\n' "$PUB_KEY" | as_root tee -a "$AUTH_KEYS" >/dev/null
  fi
  as_root chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
  as_root chmod 600 "$AUTH_KEYS"
  say "  Public key added to $AUTH_KEYS (existing keys preserved)"
fi

# SSH client configuration for GitHub itself. This key is also added as a repo
# deploy key only when --push is requested; this enables git clone/pull access.
CFG="$SSH_DIR/config"
touch "$CFG"
chmod 600 "$CFG"
if ! grep -qF "$MARK_BEGIN" "$CFG"; then
  [[ ! -s "$CFG" ]] || cp -a "$CFG" "$CFG.bak.$(date +%s)"
  {
    printf '%s\n' "$MARK_BEGIN"
    printf 'Host github.com\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking accept-new\n' "$KEY_PATH"
    printf '%s\n' "$MARK_END"
  } >> "$CFG"
else
  warn "A setup-github.sh SSH config block already exists; left it unchanged."
fi

ENV_FILE="$(realpath -m "$ENV_FILE" 2>/dev/null || printf '%s' "$ENV_FILE")"
if [[ "$WRITE_ENV" -eq 1 ]]; then
  {
    printf '# GitHub Actions -> VPS deployment secrets\n'
    printf 'VPS_HOST=%s\n' "$HOST"
    printf 'VPS_PORT=%s\n' "$PORT"
    printf 'VPS_USERNAME=%s\n' "$DEPLOY_USER"
    printf 'VPS_SSH_KEY='
    cat "$KEY_PATH"
    printf '\n'
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "  Saved secrets to $ENV_FILE (keep this file private)"
fi

if [[ "$PUSH" -eq 1 ]]; then
  step "Setting GitHub repository secrets for $REPO"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run gh auth login first"
  gh secret set VPS_HOST --repo "$REPO" --body "$HOST"
  gh secret set VPS_PORT --repo "$REPO" --body "$PORT"
  gh secret set VPS_USERNAME --repo "$REPO" --body "$DEPLOY_USER"
  gh secret set VPS_SSH_KEY --repo "$REPO" < "$KEY_PATH"
  say "  Repository secrets configured"
  # Add key as a read-only repo deploy key for git pulls from the VPS.
  if gh repo deploy-key add "$PUB_PATH" --repo "$REPO" --title "vps-deploy-$(hostname -s 2>/dev/null || echo setup)" 2>/dev/null; then
    say "  Added public key as a repository deploy key (for VPS git access)"
  else
    warn "Could not add repository deploy key automatically. It may already exist or gh lacks permission."
  fi
fi

if [[ "$SAVE_SUMMARY" -eq 1 ]]; then
  SUM="$HOME/github-deploy-info.txt"
  {
    printf 'Generated: %s\nVPS_HOST=%s\nVPS_PORT=%s\nVPS_USERNAME=%s\n\nPublic key:\n' "$(date -Is)" "$HOST" "$PORT" "$DEPLOY_USER"
    cat "$PUB_PATH"
  } > "$SUM"
  chmod 600 "$SUM"
  say "  Summary saved to $SUM"
fi

say ""
say "${G}Done.${N}"
say "GitHub secrets expected by your workflow: VPS_HOST, VPS_PORT, VPS_USERNAME, VPS_SSH_KEY"
say "Public key:"
cat "$PUB_PATH"
if [[ "$PRINT_PRIVATE" -eq 1 ]]; then
  warn "The private key below is sensitive. Only paste it into the VPS_SSH_KEY GitHub secret."
  cat "$KEY_PATH"
else
  say "Private key was not printed. It is stored at: $KEY_PATH"
fi
if [[ "$WRITE_ENV" -eq 1 ]]; then
  warn "Delete the environment file after using it: rm -f '$ENV_FILE'"
fi
