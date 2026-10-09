#!/usr/bin/env bash
# setup-github.sh — GitHub Actions -> VPS deploy bootstrapper

set -Eeuo pipefail

KEY_NAME="deploy_key"
FORCE=0
PRINT_PRIVATE=1
SAVE_SUMMARY=0
WRITE_ENV=0
ENV_FILE=""
REPO=""
PUSH=0
QUIET=0
OVERRIDE_HOST=""
OVERRIDE_PORT=""
OVERRIDE_USER=""
SETUP_VPS=0
DEPLOY_USER="deploy"

SSH_DIR="$HOME/.ssh"
MARK_BEGIN="# >>> setup-github.sh managed block >>>"
MARK_END="# <<< setup-github.sh managed block <<<"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; D=""; N=""
fi

say()   { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
step()  { [ "$QUIET" -eq 1 ] || printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

trap 'die "failed at line $LINENO"' ERR

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--key-name)       KEY_NAME="${2:?missing value}"; shift 2 ;;
        -H|--host)           OVERRIDE_HOST="${2:?missing value}"; shift 2 ;;
        -p|--port)           OVERRIDE_PORT="${2:?missing value}"; shift 2 ;;
        -u|--user)           OVERRIDE_USER="${2:?missing value}"; shift 2 ;;
        -f|--force)          FORCE=1; shift ;;
        --no-private)        PRINT_PRIVATE=0; shift ;;
        -e|--env)            WRITE_ENV=1; shift ;;
        --env-file)          WRITE_ENV=1; ENV_FILE="${2:?missing value}"; shift 2 ;;
        -r|--repo)           REPO="${2:?missing value}"; shift 2 ;;
        --push)              PUSH=1; WRITE_ENV=1; shift ;;
        --save)              SAVE_SUMMARY=1; shift ;;
        --setup-vps)         SETUP_VPS=1; shift ;;
        --deploy-user)       DEPLOY_USER="${2:?missing value}"; shift 2 ;;
        -q|--quiet)          QUIET=1; shift ;;
        -h|--help)           echo "Usage: $0 [--setup-vps] [--push] [-r owner/repo] [-e] [--env-file PATH] [-H HOST] [-p PORT] [-u USER] [-f] [--deploy-user NAME] [--save] [-q]"; exit 0 ;;
        *)                   die "unknown option: $1" ;;
    esac
done

KEY_PATH="$SSH_DIR/$KEY_NAME"
ENV_FILE="${ENV_FILE:-$HOME/github-deploy.env}"

if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
fi

say "${G}GitHub VPS Deployment Setup${N}"
say ""

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif have sudo; then sudo "$@"
    else die "need sudo or root privileges"
    fi
}

install_pkg() {
    local pkg="$1"
    if have apt-get; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" || die "install failed"
    elif have dnf; then as_root dnf install -y -q "$pkg"
    elif have yum; then as_root yum install -y -q "$pkg"
    elif have apk; then as_root apk add --no-cache "$pkg"
    fi
}

is_ipv4() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
}

is_private_ip() {
    case "${1:-}" in
        10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        *) return 1 ;;
    esac
}

setup_vps_authorized_keys() {
    local vps_host="$1"
    local vps_port="$2"
    local vps_user="$3"
    local public_key_file="$KEY_PATH.pub"

    step "Setting up authorized_keys on VPS"

    if [ ! -f "$public_key_file" ]; then
        die "Public key not found: $public_key_file"
    fi

    local pub_key; pub_key="$(cat "$public_key_file")"
    local setup_script; setup_script="$(mktemp)"

    cat >"$setup_script" <<'EOF'
#!/bin/bash
DEPLOY_USER="$1"
PUBLIC_KEY="$2"
SSH_DIR="/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR"
[ -f "$AUTH_KEYS" ] && cp "$AUTH_KEYS" "$AUTH_KEYS.backup.$(date +%s)" && chmod 600 "$AUTH_KEYS.backup".*
grep -qF "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null || echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR" "$AUTH_KEYS"
echo "OK"
EOF

    local result; result="$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$vps_port" "$vps_user@$vps_host" "bash -s '$DEPLOY_USER' '$pub_key'" <"$setup_script" 2>&1 || echo "FAILED")"
    rm -f "$setup_script"

    if [ "$result" = "OK" ]; then
        say "  ${G}✓ authorized_keys configured${N}"
        return 0
    else
        warn "VPS setup failed. Manual setup:"
        say "sudo mkdir -p /home/$DEPLOY_USER/.ssh && sudo chmod 700 /home/$DEPLOY_USER/.ssh"
        say "echo '$pub_key' | sudo tee -a /home/$DEPLOY_USER/.ssh/authorized_keys >/dev/null"
        say "sudo chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys"
        say "sudo chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh"
        return 1
    fi
}

step "Checking dependencies"
for bin in git curl ssh-keygen; do
    if ! have "$bin"; then
        say "  installing $bin"
        install_pkg "$bin" || install_pkg openssh-client
    fi
done

step "Creating SSH directory"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

step "Generating deploy key"
if [ -f "$KEY_PATH" ] && [ "$FORCE" -eq 0 ]; then
    say "  using existing key at $KEY_PATH"
else
    [ -f "$KEY_PATH" ] && cp -a "$KEY_PATH" "$KEY_PATH.bak.$(date +%s)"
    rm -f "$KEY_PATH" "$KEY_PATH.pub"
    ssh-keygen -q -t ed25519 -a 100 -C "github-actions@$(hostname -s 2>/dev/null || echo vps)" -f "$KEY_PATH" -N "" </dev/null
    say "  ${G}created${N} at $KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

step "Configuring SSH"
CFG="$SSH_DIR/config"
touch "$CFG"
if ! grep -qF "$MARK_BEGIN" "$CFG"; then
    [ -s "$CFG" ] && cp -a "$CFG" "$CFG.bak.$(date +%s)"
    {
        printf '%s\n' "$MARK_BEGIN"
        printf 'Host github.com\n'
        printf '    HostName github.com\n'
        printf '    User git\n'
        printf '    IdentityFile %s\n' "$KEY_PATH"
        printf '    IdentitiesOnly yes\n'
        printf '    StrictHostKeyChecking accept-new\n'
        printf '%s\n' "$MARK_END"
    } >>"$CFG"
    chmod 600 "$CFG"
else
    say "  already configured"
fi

step "Adding GitHub host keys"
KH="$SSH_DIR/known_hosts"
touch "$KH"; chmod 600 "$KH"
if ! ssh-keygen -F github.com -f "$KH" >/dev/null 2>&1; then
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >>"$KH" || true
fi

step "Testing GitHub auth"
AUTH_OUT="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com </dev/null 2>&1 || true)"
if printf '%s' "$AUTH_OUT" | grep -qi "successfully authenticated"; then
    say "  ${G}✓ authenticated${N}"
else
    say "  ${Y}not authorized yet${N} (normal on first run)"
fi

step "Detecting connection details"

detect_public_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip="$(curl -fsS4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || ip=""
        is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

detect_local_ip() {
    local ip=""
    have ip && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "$ip"
}

detect_port() {
    local p
    p="$(grep -rhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)" || true
    [ -n "$p" ] || p=22
    printf '%s' "$p"
}

LOCAL_IP="$(detect_local_ip)"
PUBLIC_IP="$(detect_public_ip || true)"

if [ -n "$OVERRIDE_HOST" ]; then
    VPS_HOST="$OVERRIDE_HOST"
elif [ -n "$PUBLIC_IP" ]; then
    VPS_HOST="$PUBLIC_IP"
elif [ -n "$LOCAL_IP" ] && ! is_private_ip "$LOCAL_IP"; then
    VPS_HOST="$LOCAL_IP"
else
    VPS_HOST="${LOCAL_IP:-UNKNOWN}"
    warn "Private IP detected - won't work with GitHub Actions. Use: -H YOUR.PUBLIC.IP"
fi

VPS_PORT="${OVERRIDE_PORT:-$(detect_port)}"
VPS_USER="${OVERRIDE_USER:-$(id -un)}"

say "  VPS_HOST=$VPS_HOST"
say "  VPS_PORT=$VPS_PORT"
say "  VPS_USERNAME=$VPS_USER"

if [ "$SETUP_VPS" -eq 1 ]; then
    setup_vps_authorized_keys "$VPS_HOST" "$VPS_PORT" "$VPS_USER"
fi

ENV_CONTENT="$(
    printf '# GitHub Actions -> VPS  ·  %s\n' "$(date -Is)"
    printf 'VPS_HOST=%s\n' "$VPS_HOST"
    printf 'VPS_PORT=%s\n' "$VPS_PORT"
    printf 'VPS_USERNAME=%s\n' "$VPS_USER"
    printf 'VPS_SSH_KEY='
    cat "$KEY_PATH"
    printf ''
)"

say ""
say "${G}Deploy Public Key:${N}"
cat "$KEY_PATH.pub"

if [ "$PRINT_PRIVATE" -eq 1 ]; then
    say ""
    say "${G}Environment Variables:${N}"
    printf '%s\n' "$ENV_CONTENT"
fi

if [ "$WRITE_ENV" -eq 1 ]; then
    umask 077
    printf '%s\n' "$ENV_CONTENT" >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
    say "  ${G}saved${N} to $ENV_FILE"
fi

if [ "$PUSH" -eq 1 ]; then
    if [ -z "$REPO" ]; then
        die "--push needs --repo OWNER/NAME"
    fi
    if ! have gh; then
        die "gh CLI not installed: https://cli.github.com"
    fi
    
    say ""
    step "Pushing to GitHub ($REPO)"
    
    gh secret set VPS_HOST --repo "$REPO" --body "$VPS_HOST" && say "  set VPS_HOST"
    gh secret set VPS_PORT --repo "$REPO" --body "$VPS_PORT" && say "  set VPS_PORT"
    gh secret set VPS_USERNAME --repo "$REPO" --body "$VPS_USER" && say "  set VPS_USERNAME"
    gh secret set VPS_SSH_KEY --repo "$REPO" <"$KEY_PATH" && say "  set VPS_SSH_KEY"
    gh repo deploy-key add "$KEY_PATH.pub" --repo "$REPO" --title "vps-$(hostname -s 2>/dev/null || echo deploy)" && say "  added deploy key"
fi

if [ "$SAVE_SUMMARY" -eq 1 ]; then
    SUM="$HOME/github-deploy-info.txt"
    umask 077
    {
        echo "Generated: $(date -Is)"
        echo "VPS_HOST=$VPS_HOST"
        echo "VPS_PORT=$VPS_PORT"
        echo "VPS_USERNAME=$VPS_USER"
        echo ""
        echo "Public key:"
        cat "$KEY_PATH.pub"
    } >"$SUM"
    chmod 600 "$SUM"
    say "Summary saved to $SUM"
fi

say ""
say "${G}✓ Done!${N}"
say "Verify GitHub auth: ssh -T git@github.com"
[ "$WRITE_ENV" -eq 1 ] && say "Delete env file when done: rm $ENV_FILE"
