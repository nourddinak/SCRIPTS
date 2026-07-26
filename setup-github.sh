#!/usr/bin/env bash
# ==============================================================================
#  setup-github.sh — GitHub Actions -> VPS deploy bootstrapper
#
#  QUICK RUN (recommended, keeps stdin usable):
#      bash <(curl -fsSL https://github.com/nourddinak/SCRIPTS/setup-github.sh)
#
#  PIPE STYLE (works too, args go after -s --):
#      curl -fsSL https://github.com/nourddinak/SCRIPTS/setup-github.sh | bash -s -- --port 2222
#
#  CLASSIC:
#      curl -fsSL -o setup-github.sh https://your.domain/setup-github.sh
#      chmod +x setup-github.sh && ./setup-github.sh
#
#  Flags:
#      -e, --env             write a ready-to-paste .env file (mode 600)
#          --env-file PATH   where to write it (default: ~/github-deploy.env)
#      -r, --repo OWNER/NAME target repository, enables the gh commands
#          --push            upload deploy key + all secrets with the gh CLI
#      -n, --key-name NAME   key file name inside ~/.ssh   (default: deploy_key)
#      -H, --host IP         override the detected host/IP
#      -p, --port PORT       override the detected SSH port
#      -u, --user NAME       override the reported username
#      -f, --force           regenerate the key even if one exists
#          --no-private      never print the private key on screen
#          --save            write a summary file to ~/github-deploy-info.txt
#      -q, --quiet           less noise
#      -h, --help            this help
# ==============================================================================

set -Eeuo pipefail

# --- config / defaults --------------------------------------------------------
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

SSH_DIR="$HOME/.ssh"
MARK_BEGIN="# >>> setup-github.sh managed block >>>"
MARK_END="# <<< setup-github.sh managed block <<<"

# --- colors (auto-disabled when output is piped / not a terminal) -------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; D=$'\033[2m';    N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; D=""; N=""
fi

say()   { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
step()  { [ "$QUIET" -eq 1 ] || printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule()  { [ "$QUIET" -eq 1 ] || printf '%s%s%s\n' "$B" "──────────────────────────────────────────────────────────" "$N"; }
head2() { [ "$QUIET" -eq 1 ] || { printf '\n'; rule; printf '%s %s%s\n' "$B" "$*" "$N"; rule; }; }

trap 'die "failed at line $LINENO"' ERR

# --- arg parsing --------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--key-name)  KEY_NAME="${2:?missing value}"; shift 2 ;;
        -H|--host)      OVERRIDE_HOST="${2:?missing value}"; shift 2 ;;
        -p|--port)      OVERRIDE_PORT="${2:?missing value}"; shift 2 ;;
        -u|--user)      OVERRIDE_USER="${2:?missing value}"; shift 2 ;;
        -f|--force)     FORCE=1; shift ;;
        --no-private)   PRINT_PRIVATE=0; shift ;;
        -e|--env)       WRITE_ENV=1; shift ;;
        --env-file)     WRITE_ENV=1; ENV_FILE="${2:?missing value}"; shift 2 ;;
        -r|--repo)      REPO="${2:?missing value}"; shift 2 ;;
        --push)         PUSH=1; WRITE_ENV=1; shift ;;
        --save)         SAVE_SUMMARY=1; shift ;;
        -q|--quiet)     QUIET=1; shift ;;
        -h|--help)      sed -n '2,29p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "unknown option: $1  (try --help)" ;;
    esac
done

KEY_PATH="$SSH_DIR/$KEY_NAME"
ENV_FILE="${ENV_FILE:-$HOME/github-deploy.env}"

if [ "$PUSH" -eq 1 ] && [ -z "$REPO" ]; then
    die "--push needs --repo OWNER/NAME"
fi
if [ -n "$REPO" ] && [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    die "--repo must look like OWNER/NAME (got: $REPO)"
fi

# If we were piped into bash, stdin is the script itself. Reattach a real
# terminal so nothing downstream can swallow the rest of the script.
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
fi

head2 "GitHub VPS Deployment Setup"

# --- helpers ------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif have sudo;  then sudo "$@"
    else die "need root privileges for: $* (install sudo or run as root)"
    fi
}

install_pkg() {
    local pkg="$1"
    if   have apt-get; then
             # a broken third-party repo must not abort the whole run
             as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt update had errors, continuing"
             as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" \
                 || die "could not install '$pkg' — install it manually and re-run"
    elif have dnf;     then as_root dnf install -y -q "$pkg"
    elif have yum;     then as_root yum install -y -q "$pkg"
    elif have apk;     then as_root apk add --no-cache "$pkg"
    elif have pacman;  then as_root pacman -Sy --noconfirm "$pkg"
    elif have zypper;  then as_root zypper --non-interactive install "$pkg"
    else die "no supported package manager found; install '$pkg' manually"
    fi
}

is_ipv4() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<<"$ip"
    for n in "${o[@]}"; do [ "$n" -le 255 ] || return 1; done
    return 0
}

is_private_ip() {
    case "${1:-}" in
        10.*|127.*|169.254.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;  # CGNAT
        *) return 1 ;;
    esac
}

# --- 1. dependencies ----------------------------------------------------------
step "Checking dependencies"
for bin in git curl; do
    if have "$bin"; then
        say "  ${D}$bin ok${N}"
    else
        say "  installing $bin ..."
        install_pkg "$bin"
    fi
done
have ssh-keygen || install_pkg openssh-client

# --- 2. ~/.ssh ----------------------------------------------------------------
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# --- 3. deploy key ------------------------------------------------------------
step "Deploy key"
if [ -f "$KEY_PATH" ] && [ "$FORCE" -eq 0 ]; then
    say "  ${Y}exists, keeping it${N} -> $KEY_PATH  (use --force to regenerate)"
else
    if [ -f "$KEY_PATH" ]; then
        cp -a "$KEY_PATH" "$KEY_PATH.bak.$(date +%s)"
        say "  old key backed up"
    fi
    rm -f "$KEY_PATH" "$KEY_PATH.pub"
    ssh-keygen -q -t ed25519 -a 100 \
        -C "github-actions-deploy@$(hostname -s 2>/dev/null || echo vps)" \
        -f "$KEY_PATH" -N "" </dev/null
    say "  ${G}created${N} -> $KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

# --- 4. ssh config (managed block, never clobbers the whole file) -------------
step "SSH client config"
CFG="$SSH_DIR/config"
touch "$CFG"
if grep -qF "$MARK_BEGIN" "$CFG"; then
    # strip the old managed block, keep everything the user wrote themselves
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        index($0,b){skip=1} !skip{print} index($0,e){skip=0}' "$CFG" >"$tmp"
    mv "$tmp" "$CFG"
else
    [ -s "$CFG" ] && cp -a "$CFG" "$CFG.bak.$(date +%s)"
fi
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
say "  ${D}managed block written to $CFG (your other hosts untouched)${N}"

# --- 5. known_hosts (no duplicate entries on re-runs) -------------------------
step "GitHub host keys"
KH="$SSH_DIR/known_hosts"
touch "$KH"; chmod 600 "$KH"
if ssh-keygen -F github.com -f "$KH" >/dev/null 2>&1; then
    say "  ${D}already pinned${N}"
else
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >>"$KH" || warn "ssh-keyscan failed"
    say "  added"
fi

# --- 6. auth test -------------------------------------------------------------
step "Testing GitHub authentication"
AUTH_OUT="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com </dev/null 2>&1 || true)"
if printf '%s' "$AUTH_OUT" | grep -qi "successfully authenticated"; then
    say "  ${G}key is already authorised on GitHub${N}"
else
    say "  ${Y}not authorised yet${N} — normal on first run, add the key below first"
fi

# --- 7. connection facts ------------------------------------------------------
step "Detecting connection details"

detect_public_ip() {
    local u ip
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com; do
        ip="$(curl -fsS4 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')" || ip=""
        is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done
    if have dig; then
        ip="$(dig -4 +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null | tr -d '[:space:]')" || ip=""
        is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    fi
    return 1
}

detect_local_ip() {
    local ip=""
    have ip && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "$ip"
}

detect_port() {
    local p=""
    p="$(grep -rhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
         | awk '{print $2}' | head -n1)" || true
    [ -n "$p" ] || p=22
    printf '%s' "$p"
}

LOCAL_IP="$(detect_local_ip)"
PUBLIC_IP="$(detect_public_ip || true)"

if [ -n "$OVERRIDE_HOST" ]; then
    VPS_HOST="$OVERRIDE_HOST"; IP_SRC="manual override"
elif [ -n "$PUBLIC_IP" ]; then
    VPS_HOST="$PUBLIC_IP";     IP_SRC="public lookup"
elif [ -n "$LOCAL_IP" ] && ! is_private_ip "$LOCAL_IP"; then
    VPS_HOST="$LOCAL_IP";      IP_SRC="local interface"
else
    VPS_HOST="${LOCAL_IP:-UNKNOWN}"; IP_SRC="local interface (private!)"
    warn "Could not reach any public-IP service. '$VPS_HOST' is a private/NAT address"
    warn "and GitHub Actions cannot connect to it. Re-run with:  --host YOUR.PUBLIC.IP"
fi

if [ -n "$PUBLIC_IP" ] && [ -n "$LOCAL_IP" ] && [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
    say "  ${D}public: $PUBLIC_IP   |   private/NIC: $LOCAL_IP (NAT — use the public one)${N}"
fi

VPS_PORT="${OVERRIDE_PORT:-$(detect_port)}"
VPS_USER="${OVERRIDE_USER:-$(id -un)}"

# --- 8. build the .env payload -------------------------------------------------
# command substitution strips trailing newlines, so the closing quote is
# printed on its own line to preserve the newline OpenSSH keys require.
ENV_CONTENT="$(
    printf '# GitHub Actions -> VPS  ·  generated %s\n' "$(date -Is)"
    printf 'VPS_HOST=%s\n'     "$VPS_HOST"
    printf 'VPS_PORT=%s\n'     "$VPS_PORT"
    printf 'VPS_USERNAME=%s\n' "$VPS_USER"
    printf 'VPS_SSH_KEY='
    cat "$KEY_PATH"
    printf ''
)"

# --- 9. output -----------------------------------------------------------------
head2 "1. Deploy key  →  Repo · Settings · Deploy keys · Add deploy key"
cat "$KEY_PATH.pub"
say "${D}(tick \"Allow write access\" only if the workflow pushes back)${N}"

head2 "2. Detected values"
printf '  %-14s %s   %s(%s)%s\n' "VPS_HOST"     "$VPS_HOST" "$D" "$IP_SRC" "$N"
printf '  %-14s %s   %s(%s)%s\n' "VPS_PORT"     "$VPS_PORT" "$D" "sshd_config" "$N"
printf '  %-14s %s\n'            "VPS_USERNAME" "$VPS_USER"
printf '  %-14s %s\n'            "VPS_SSH_KEY"  "$KEY_PATH"

head2 "3. Ready-to-paste .env"
if [ "$PRINT_PRIVATE" -eq 1 ]; then
    warn "contains a private key — not for a shared screen or a recorded session"
    say ""
    printf '%s\n' "$ENV_CONTENT"
else
    say "  hidden by --no-private"
fi

if [ "$WRITE_ENV" -eq 1 ]; then
    umask 077
    printf '%s\n' "$ENV_CONTENT" >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
    say ""
    say "  ${G}saved${N} -> $ENV_FILE   ${D}(mode 600 — never commit this)${N}"
fi

head2 "4. Load it into GitHub"
if have gh; then
    say "  ${D}gh CLI detected${N}"
else
    say "  ${Y}gh CLI not installed${N} — https://cli.github.com  (or paste manually in the UI)"
fi
say ""
say "  ${D}# all four secrets in one shot, from the .env file${N}"
say "  gh secret set -f ${ENV_FILE}${REPO:+ --repo $REPO}"
say ""
say "  ${D}# or one by one — stdin form is the safest for the multi-line key${N}"
say "  gh secret set VPS_HOST     --body \"$VPS_HOST\"${REPO:+ --repo $REPO}"
say "  gh secret set VPS_PORT     --body \"$VPS_PORT\"${REPO:+ --repo $REPO}"
say "  gh secret set VPS_USERNAME --body \"$VPS_USER\"${REPO:+ --repo $REPO}"
say "  gh secret set VPS_SSH_KEY${REPO:+ --repo $REPO} < $KEY_PATH"
say ""
say "  ${D}# and the deploy key${N}"
say "  gh repo deploy-key add $KEY_PATH.pub --title \"vps-$(hostname -s 2>/dev/null || echo deploy)\"${REPO:+ --repo $REPO}"

# --- 10. optional: do it automatically ------------------------------------------
if [ "$PUSH" -eq 1 ]; then
    head2 "5. Pushing to $REPO"
    have gh || die "--push needs the gh CLI: https://cli.github.com"
    gh auth status >/dev/null 2>&1 </dev/null || die "gh is not logged in — run: gh auth login"

    for pair in "VPS_HOST=$VPS_HOST" "VPS_PORT=$VPS_PORT" "VPS_USERNAME=$VPS_USER"; do
        name="${pair%%=*}"; value="${pair#*=}"
        gh secret set "$name" --repo "$REPO" --body "$value" </dev/null \
            && say "  ${G}set${N} $name" \
            || warn "failed to set $name"
    done
    gh secret set VPS_SSH_KEY --repo "$REPO" <"$KEY_PATH" \
        && say "  ${G}set${N} VPS_SSH_KEY" \
        || warn "failed to set VPS_SSH_KEY"

    if gh repo deploy-key add "$KEY_PATH.pub" --repo "$REPO" \
           --title "vps-$(hostname -s 2>/dev/null || echo deploy)" </dev/null 2>/dev/null; then
        say "  ${G}added${N} deploy key"
    else
        say "  ${Y}deploy key not added${N} — it is probably already there, or the token lacks admin scope"
    fi
fi

if [ "$SAVE_SUMMARY" -eq 1 ]; then
    SUM="$HOME/github-deploy-info.txt"
    umask 077
    {
        echo "generated: $(date -Is)"
        echo "VPS_HOST     = $VPS_HOST"
        echo "VPS_PORT     = $VPS_PORT"
        echo "VPS_USERNAME = $VPS_USER"
        echo "VPS_SSH_KEY  = contents of $KEY_PATH"
        echo
        echo "public key:"
        cat "$KEY_PATH.pub"
    } >"$SUM"
    chmod 600 "$SUM"
    say ""
    say "  summary saved to $SUM"
fi

head2 "Done"
say "Verify on this box with:   ssh -T git@github.com"
[ "$WRITE_ENV" -eq 1 ] && say "Shred the env file when finished:  shred -u $ENV_FILE"
say ""
