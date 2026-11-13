#!/usr/bin/env bash
# ==============================================================================
#  vps-deploy-setup.sh: get a VPS ready for vps-deploy (GitHub Actions deploys),
#  then print the GitHub secrets and everything needed to add it to your list.
#
#  RUN ON THE VPS:
#      bash <(curl -fsSL https://raw.githubusercontent.com/nourddinak/SCRIPTS/main/vps-deploy-setup.sh) --name vps1 --sudo
#
#  It makes ONE key that only GitHub Actions uses to log in (your own login, e.g.
#  your .ppk, is not touched), authorizes it, and shows it so you can paste it into
#  GitHub, plus a one-line PowerShell command that saves it on your PC. Re-running reuses it.
#
#  Flags:
#      -n, --name NAME     what to call this server (vps1 ...): also names the secrets (VPS1_HOST ...)
#          --sudo          let this user use sudo without a password (vps-deploy needs it)
#          --no-sudo       never touch sudo settings
#          --new-key       replace the GitHub key (the old one is backed up and un-authorized)
#          --no-private    don't print the private key (read it later: cat ~/.ssh/vps_deploy_key)
#      -k, --key PUBKEY    also authorize this public key (e.g. from your PC)
#      -H, --host IP       override the detected public IP
#      -p, --port PORT     override the detected SSH port
#      -y, --yes           answer yes to every question
#          --save          also write the summary to ~/vps-deploy-info.txt (mode 600)
#      -h, --help          this help
#
#  Changes it can make:
#      ~/.ssh/vps_deploy_key(.pub)     the GitHub Actions key (created once)
#      ~/.ssh/authorized_keys          adds that key (once, never duplicated)
#      /etc/sudoers.d/90-vps-deploy    passwordless sudo, only with --sudo or a yes (checked with visudo)
#  Everything else is read-only. Nothing is sent anywhere except one request to a
#  public-IP service (api.ipify.org / ifconfig.me) to learn this server's real IP.
# ==============================================================================
set -uo pipefail

NAME=""; PUBKEY=""; NEW_KEY=0; PRINT_PRIVATE=1; SUDO_MODE=ask; HOST_OVERRIDE=""; PORT_OVERRIDE=""; YES=0; SAVE=0

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; C=""; N=""; fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
note() { printf '  %s•%s %s\n' "$C" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
usage() {
  cat <<'EOF'
vps-deploy-setup.sh: make a GitHub Actions key on this VPS, show the GitHub secrets,
and print what's needed to add the server to your list.

  -n, --name NAME     what to call this server (vps1 ...): also names the secrets (VPS1_HOST ...)
      --sudo          let this user use sudo without a password (vps-deploy needs it)
      --no-sudo       never touch sudo settings
      --new-key       replace the GitHub key (the old one is backed up and un-authorized)
      --no-private    don't print the private key (read it later: cat ~/.ssh/vps_deploy_key)
  -k, --key PUBKEY    also authorize this public key (e.g. from your PC)
  -H, --host IP       override the detected public IP
  -p, --port PORT     override the detected SSH port
  -y, --yes           answer yes to every question
      --save          also write the summary to ~/vps-deploy-info.txt (mode 600)
  -h, --help          this help
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name) NAME="${2:-}"; shift 2 ;;
    -k|--key) PUBKEY="${2:-}"; shift 2 ;;
    --new-key) NEW_KEY=1; shift ;;
    --no-private) PRINT_PRIVATE=0; shift ;;
    --make-key) shift ;;   # old flag: making the key is the default now
    --sudo) SUDO_MODE=yes; shift ;;
    --no-sudo) SUDO_MODE=no; shift ;;
    -H|--host) HOST_OVERRIDE="${2:-}"; shift 2 ;;
    -p|--port) PORT_OVERRIDE="${2:-}"; shift 2 ;;
    -y|--yes) YES=1; shift ;;
    --save) SAVE=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

TTY=0; if [ -r /dev/tty ] && [ -w /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then TTY=1; fi
ask() {   # ask "question" → 0 for yes
  if [ "$YES" = 1 ]; then return 0; fi
  if [ "$TTY" = 0 ]; then return 1; fi
  local a; printf '  %s?%s %s [y/N] ' "$Y" "$N" "$1" > /dev/tty; read -r a < /dev/tty
  case "$a" in y|Y|yes|YES) return 0 ;; esac; return 1
}

# ------------------------------------------------------------------------------
# who are we setting up
# ------------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then USER_NAME="$SUDO_USER"; else USER_NAME="$(id -un)"; fi
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"; USER_HOME="${USER_HOME:-$HOME}"
IS_ROOT=0; [ "$USER_NAME" = root ] && IS_ROOT=1
if [ "$(id -u)" -eq 0 ]; then S=""; elif sudo -n true 2>/dev/null; then S="sudo -n"; else S=""; fi   # for read-only checks
as_target() { if [ "$(id -un)" = "$USER_NAME" ]; then "$@"; else sudo -u "$USER_NAME" "$@"; fi; }

printf '%svps-deploy setup%s · %s · user %s\n' "$B" "$N" "$(hostname)" "$USER_NAME"

# ------------------------------------------------------------------------------
# 1. SSH key
# ------------------------------------------------------------------------------
head_ "1. GitHub Actions key"
AUTH="$USER_HOME/.ssh/authorized_keys"
KF="$USER_HOME/.ssh/vps_deploy_key"
authorize() {   # $1 = public key line
  local k="$1" body
  case "$k" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *) ;; *) bad "that doesn't look like a public key (it should start with ssh-ed25519 / ssh-rsa)"; return 1 ;; esac
  body="$(printf '%s' "$k" | awk '{ print $1 " " $2 }')"
  as_target mkdir -p "$USER_HOME/.ssh" && as_target chmod 700 "$USER_HOME/.ssh"
  as_target touch "$AUTH" && as_target chmod 600 "$AUTH"
  if grep -qF "$body" "$AUTH" 2>/dev/null; then ok "key already authorized"; return 0; fi
  printf '%s\n' "$k" | as_target tee -a "$AUTH" >/dev/null && ok "key added to $AUTH"
}
KEY_STATE="not set up"
key_label() { printf '%s' "$1" | awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print ($0 == "" ? "(no comment)" : $0) }'; }
if [ "$NEW_KEY" = 1 ] && [ -f "$KF" ]; then
  OLD_BODY="$(awk '{ print $2 }' "$KF.pub" 2>/dev/null)"
  BK="$KF.bak-$(date +%Y%m%d-%H%M%S)"
  as_target mv "$KF" "$BK"; as_target mv "$KF.pub" "$BK.pub" 2>/dev/null
  if [ -n "$OLD_BODY" ] && [ -f "$AUTH" ]; then
    { grep -vF "$OLD_BODY" "$AUTH" || true; } | as_target tee "$AUTH.tmp" >/dev/null && as_target mv "$AUTH.tmp" "$AUTH" && as_target chmod 600 "$AUTH"
  fi
  ok "old key backed up to $BK and removed from authorized_keys (update the GitHub secret!)"
fi
if [ ! -f "$KF" ]; then
  as_target mkdir -p "$USER_HOME/.ssh" && as_target chmod 700 "$USER_HOME/.ssh"
  as_target ssh-keygen -q -t ed25519 -N "" -C "vps-deploy ${NAME:-$(hostname)} (github actions)" -f "$KF" \
    && ok "created $KF (only for GitHub Actions)" || die "couldn't create $KF"
else
  ok "reusing $KF"
fi
authorize "$(cat "$KF.pub")" && KEY_STATE="github key authorized ($KF)"
if [ -n "$PUBKEY" ]; then authorize "$PUBKEY" && KEY_STATE="$KEY_STATE + $(key_label "$PUBKEY")"; fi

# ------------------------------------------------------------------------------
# 2. sudo
# ------------------------------------------------------------------------------
head_ "2. sudo"
if [ "$IS_ROOT" = 1 ]; then
  SUDO_STATE="root (not needed)"; ok "running as root: no sudo needed"
elif as_target sudo -n true 2>/dev/null; then
  SUDO_STATE="passwordless"; ok "$USER_NAME already has passwordless sudo"
else
  SUDO_STATE="needs a password"
  if [ "$SUDO_MODE" = no ]; then note "left alone (--no-sudo)"
  elif [ "$SUDO_MODE" = yes ] || ask "Let $USER_NAME use sudo without a password? (deploys need it to install packages and manage services)"; then
    RULE="$USER_NAME ALL=(ALL) NOPASSWD:ALL"
    TMP="$(mktemp)"; printf '# added by vps-deploy-setup.sh\n%s\n' "$RULE" > "$TMP"
    if sudo visudo -cf "$TMP" >/dev/null && sudo install -m 440 -o root -g root "$TMP" /etc/sudoers.d/90-vps-deploy; then
      SUDO_STATE="passwordless"; ok "wrote /etc/sudoers.d/90-vps-deploy"
    else bad "couldn't set it up (is $USER_NAME allowed to use sudo at all?)"; fi
    rm -f "$TMP"
    if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then S="sudo -n"; fi
  else
    warn "left as is: deploys will fail until this user has passwordless sudo"
  fi
fi

# ------------------------------------------------------------------------------
# 3. what's on this server (read-only)
# ------------------------------------------------------------------------------
head_ "3. Looking around"
OS="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )"
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) ARCH="$(uname -m)" ;; esac
APT=no; command -v apt-get >/dev/null 2>&1 && APT=yes
[ "$APT" = no ] && warn "no apt-get: vps-deploy only supports Debian/Ubuntu servers"

HOST="$HOST_OVERRIDE"
if [ -z "$HOST" ]; then
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    HOST="$(curl -4 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]')"
    [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break; HOST=""
  done
  [ -z "$HOST" ] && HOST="$(hostname -I 2>/dev/null | awk '{ print $1 }')" && warn "couldn't reach a public-IP service; $HOST may be a private address (use --host)"
fi
SSH_PORT="$PORT_OVERRIDE"
[ -z "$SSH_PORT" ] && SSH_PORT="$($S sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
[ -z "$SSH_PORT" ] && SSH_PORT="$(grep -hE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{ print $2; exit }')"
SSH_PORT="${SSH_PORT:-22}"
PUBKEY_AUTH="$($S sshd -T 2>/dev/null | awk '$1 == "pubkeyauthentication" { print $2 }')"
[ "$PUBKEY_AUTH" = no ] && bad "sshd has PubkeyAuthentication no: key logins won't work until it's enabled"

CPUS="$(nproc 2>/dev/null)"
RAM="$(free -m | awk 'NR == 2 { printf "%d MB (%d MB free)", $2, $7 }')"
DISK="$(df -h / | awk 'NR == 2 { printf "%s (%s free)", $2, $4 }')"

ver() { command -v "$1" >/dev/null 2>&1 || return 1; "$@" 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | awk 'NR == 1'; }
RUNTIMES=""
addrt() { local v; v="$(ver "${@:2}")" && RUNTIMES="$RUNTIMES $1 $v,"; }
addrt node node --version; addrt python python3 --version; addrt go go version; addrt java java -version
addrt dotnet dotnet --version; addrt php php -v; addrt bun bun --version; addrt deno deno --version
addrt rust rustc --version; addrt docker docker --version
VDRT="$(ls /opt/runtimes 2>/dev/null | tr '\n' ' ')"
[ -n "$VDRT" ] && RUNTIMES="$RUNTIMES vps-deploy runtimes: ${VDRT% },"
RUNTIMES="${RUNTIMES%,}"; RUNTIMES="${RUNTIMES# }"

CADDY="not installed"; CADDY_IMPORTS=""
if command -v caddy >/dev/null 2>&1; then
  CADDY="$(caddy version 2>/dev/null | awk '{ print $1 }') ($(systemctl is-active caddy 2>/dev/null))"
  CADDY_IMPORTS="$(grep -hE '^[[:space:]]*import[[:space:]]' /etc/caddy/Caddyfile 2>/dev/null | awk '{ print $2 }' | tr '\n' ' ')"
fi
for db in postgresql redis-server mariadb mysql mongod; do
  st="$(systemctl is-active "$db" 2>/dev/null)"; [ "$st" = active ] && DBS="${DBS:-}$db "
done

FW="none"
if command -v ufw >/dev/null 2>&1; then
  FWS="$($S ufw status 2>/dev/null)"
  if printf '%s' "$FWS" | grep -q 'Status: active'; then
    FW="ufw active"
    for p in "$SSH_PORT" 80 443; do printf '%s' "$FWS" | grep -qE "^$p(/tcp)?[[:space:]].*ALLOW" || FW="$FW, $p not allowed"; done
  elif [ -n "$FWS" ]; then FW="ufw inactive"; fi
fi

# ports: "port  process"
PORTS="$($S ss -ltnpH 2>/dev/null | awk '{ n = split($4, a, ":"); p = a[n]; proc = "?"; if (match($0, /\("[^"]+"/)) proc = substr($0, RSTART + 2, RLENGTH - 3); addr = substr($4, 1, length($4) - length(p) - 1); pub = (addr ~ /^(127\.|\[::1\]|::1)/) ? "local" : "public"; print p, proc, pub }' | sort -n -u)"

# apps in /var/www
APPS=""
for d in /var/www/*/; do
  [ -d "$d" ] || continue
  d="${d%/}"; n="$(basename "$d")"
  svc="$(grep -lsE "^(WorkingDirectory|ExecStart)=.*$d(/|[[:space:]]|$)" /etc/systemd/system/*.service 2>/dev/null | awk 'NR == 1' | xargs -r basename | sed 's/\.service$//')"
  envf="$d/.env"; [ -f "$d/shared/.env" ] && envf="$d/shared/.env"
  port="$($S awk -F= '/^[[:space:]]*PORT[[:space:]]*=/ { v = $2 } END { print v }' "$envf" 2>/dev/null | tr -d "\"' \r")"
  cf="no"; [ -e "$d/Caddyfile" ] && cf="yes"
  managed="old layout"; [ -d "$d/releases" ] && managed="vps-deploy"
  st="-"; [ -n "$svc" ] && st="$(systemctl is-active "$svc" 2>/dev/null)"
  APPS="$APPS$n|${svc:--}|$st|${port:--}|$cf|$managed"$'\n'
done
CONTAINERS="$($S docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
  | sed -E 's/^\{.*"Names":"([^"]*)".*"Ports":"([^"]*)".*$/\1 \2/' | sed 's/ *$//' | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

# ------------------------------------------------------------------------------
# summary
# ------------------------------------------------------------------------------
summary() {
  echo "===== vps-deploy server info: paste everything from here to the end line to Claude ====="
  echo "name: ${NAME:-<pick one, e.g. vps1>}"
  echo "secret_prefix: $PREFIX"
  echo "pc_key_file: ~/.ssh/$PCNAME"
  echo "host: $HOST"
  echo "user: $USER_NAME"
  echo "ssh_port: $SSH_PORT"
  echo "arch: $ARCH"
  echo "os: $OS (apt: $APT)"
  echo "hardware: $CPUS CPU · RAM $RAM · disk $DISK"
  echo "ssh_key: $KEY_STATE"
  echo "sudo: $SUDO_STATE"
  echo "caddy: $CADDY"
  [ -n "$CADDY_IMPORTS" ] && echo "caddy_imports: $CADDY_IMPORTS"
  echo "databases: ${DBS:-none}"
  echo "runtimes: ${RUNTIMES:-none}"
  echo "firewall: $FW"
  echo "apps (/var/www): name | service | state | port | own Caddyfile | layout"
  if [ -n "$APPS" ]; then printf '%s' "$APPS" | sed 's/^/  - /'; else echo "  (none)"; fi
  [ -n "$CONTAINERS" ] && echo "docker: $CONTAINERS"
  echo "ports in use: port process scope"
  if [ -n "$PORTS" ]; then printf '%s\n' "$PORTS" | sed 's/^/  - /'; else echo "  (couldn't read: run with sudo for process names)"; fi
  echo "===== end ====="
}
PREFIX="$(printf '%s' "${NAME:-vps}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')"

PCNAME="$(printf '%s' "${NAME:-vps}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '_')_deploy"
head_ "4. The GitHub key"
if [ "$PRINT_PRIVATE" = 1 ]; then
  echo
  printf '  %sSave it on your PC once%s: Claude then puts it into every repo itself (it never reads it).\n' "$B" "$N"
  echo "  Copy the line below, paste it into PowerShell on your PC (your own window, not a chat):"
  echo
  printf '%s\n' "\$k=\"\$env:USERPROFILE\\.ssh\\$PCNAME\"; New-Item -ItemType Directory -Force \"\$env:USERPROFILE\\.ssh\" | Out-Null; [IO.File]::WriteAllBytes(\$k,[Convert]::FromBase64String('$(base64 -w0 < "$KF")')); icacls \$k /inheritance:r /grant:r \"\${env:USERNAME}:F\" | Out-Null; \"saved \$k\""
  echo
  warn "That line contains the private key (encoded). Only paste it into your own PowerShell."
  echo
  echo "  Or add it by hand per repo (Settings → Secrets and variables → Actions):"
  printf '    %-20s %s\n' "${PREFIX}_HOST" "$HOST" "${PREFIX}_USER" "$USER_NAME" "${PREFIX}_PORT" "$SSH_PORT" "${PREFIX}_SSH_KEY" "the private key: cat $KF"
else
  note "not shown (--no-private). Show it with: cat $KF"
fi

head_ "5. Server info: paste this block to Claude (it has no secrets)"
echo
summary
if [ "$SAVE" = 1 ]; then
  ( umask 077; summary > "$USER_HOME/vps-deploy-info.txt" ); chown "$USER_NAME" "$USER_HOME/vps-deploy-info.txt" 2>/dev/null
  echo; ok "saved to $USER_HOME/vps-deploy-info.txt"
fi
echo
[ "$SUDO_STATE" = "needs a password" ] && warn "sudo still needs a password: re-run with --sudo."
exit 0
