#!/usr/bin/env bash
# hermes-secure-deploy — install Hermes Agent on a fresh Linux server as an
# unprivileged, sandboxed systemd service.
#
#   curl -fsSL https://raw.githubusercontent.com/AntonyN0P/hermes-secure-deploy/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Run `bash install.sh --help` for options. Safe to re-run.
set -Eeuo pipefail

VERSION="0.1.0"
HERMES_INSTALLER_URL="${HERMES_INSTALLER_URL:-https://hermes-agent.nousresearch.com/install.sh}"
LOG_FILE="/var/log/hermes-secure-deploy.log"
MARKER="# managed-by: hermes-secure-deploy"
LOCK_FILE="/run/hermes-secure-deploy.lock"

# ---------------------------------------------------------------- options ---
HERMES_USER="${HERMES_USER:-hermes}"
CHANNEL="${HERMES_CHANNEL:-stable}"
ASSUME_YES=false
NON_INTERACTIVE=false
DO_BASE_HARDENING=""   # auto-updates + fail2ban   ("" = ask)
DO_FIREWALL=""         # ufw, SSH only
DO_SSH_HARDENING=""    # key-only SSH login
DO_DASHBOARD=""        # loopback-only web dashboard
DO_TELEGRAM=""
SKIP_BROWSER=false
SKIP_MODEL_SETUP=false
MODE="install"         # install | update
EXTRA_ENV=()

usage() {
    cat <<EOF
hermes-secure-deploy $VERSION — secure Hermes Agent deployment

Usage: sudo bash install.sh [options]

Modes:
  (default)               Full install / re-configure. Safe to re-run.
  --update                Update Hermes as its user, regenerate the units, restart.

Options:
  --user NAME             Service account name (default: hermes)
  --channel stable|main   Hermes release channel (default: stable)
  -y, --yes               Accept the default answer for every question
  --non-interactive       Never prompt. Telegram comes from TELEGRAM_BOT_TOKEN /
                          TELEGRAM_ALLOWED_USERS env vars (or use --no-telegram);
                          model setup is skipped unless keys are given via --env.
  --env KEY=VALUE         Write KEY=VALUE into the agent's .env (repeatable),
                          e.g. --env OPENROUTER_API_KEY=sk-or-...
  --[no-]hardening        Unattended security updates + fail2ban (default: ask, yes)
  --[no-]firewall         ufw: deny incoming except SSH (default: ask, yes)
  --[no-]ssh-hardening    Key-only SSH, no root password login (default: ask)
  --[no-]dashboard        Web dashboard on 127.0.0.1:9119 (default: ask, no)
  --no-telegram           Do not configure Telegram
  --skip-browser          Do not install Chromium for the browser tool
  --skip-model-setup      Do not run 'hermes setup model'
  -h, --help              Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --user) HERMES_USER="${2:?--user needs a value}"; shift 2 ;;
        --channel) CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
        --env) EXTRA_ENV+=("${2:?--env needs KEY=VALUE}"); shift 2 ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --update) MODE="update"; shift ;;
        --hardening) DO_BASE_HARDENING=yes; shift ;;
        --no-hardening) DO_BASE_HARDENING=no; shift ;;
        --firewall) DO_FIREWALL=yes; shift ;;
        --no-firewall) DO_FIREWALL=no; shift ;;
        --ssh-hardening) DO_SSH_HARDENING=yes; shift ;;
        --no-ssh-hardening) DO_SSH_HARDENING=no; shift ;;
        --dashboard) DO_DASHBOARD=yes; shift ;;
        --no-dashboard) DO_DASHBOARD=no; shift ;;
        --no-telegram) DO_TELEGRAM=no; shift ;;
        --skip-browser) SKIP_BROWSER=true; shift ;;
        --skip-model-setup) SKIP_MODEL_SETUP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

case "$CHANNEL" in stable|main) ;; *) echo "--channel must be stable or main" >&2; exit 2 ;; esac
[[ "$HERMES_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "invalid --user name: $HERMES_USER" >&2; exit 2; }
[ "$HERMES_USER" != root ] || { echo "refusing to run Hermes as root — that is the point of this script" >&2; exit 2; }

HOME_DIR="/home/$HERMES_USER"
HERMES_DIR="$HOME_DIR/.hermes"
HERMES_BIN="$HOME_DIR/.local/bin/hermes"
ENV_FILE="$HERMES_DIR/.env"
GATEWAY_UNIT="hermes-gateway.service"
DASHBOARD_UNIT="hermes-dashboard.service"

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi
_log_file() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; _log_file "==> $*"; }
info() { printf '    %s\n' "$*"; _log_file "    $*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_file "  ok $*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file "warn $*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; _log_file "FAIL $*"; exit 1; }
trap 'die "failed at line $LINENO (exit $?). Log: $LOG_FILE"' ERR

# ------------------------------------------------------------- prompting ----
HAVE_TTY=false
if [ "$NON_INTERACTIVE" = false ] && { exec 3</dev/tty; } 2>/dev/null; then HAVE_TTY=true; fi

# ask_yn "question" default(yes|no) -> exit status 0 for yes
ask_yn() {
    local q="$1" def="$2" ans hint
    if [ "$ASSUME_YES" = true ] || [ "$HAVE_TTY" = false ]; then [ "$def" = yes ]; return; fi
    [ "$def" = yes ] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf '    %s?%s %s %s ' "$C_BOLD" "$C_RESET" "$q" "$hint"
        read -r -u 3 ans || ans=""
        case "${ans,,}" in
            "") [ "$def" = yes ]; return ;;
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
        esac
    done
}

# ask_value VAR "prompt" [default] [secret]
ask_value() {
    local __var="$1" q="$2" def="${3:-}" secret="${4:-}" ans
    if [ "$HAVE_TTY" = false ]; then printf -v "$__var" '%s' "$def"; return; fi
    if [ -n "$def" ]; then printf '    %s?%s %s [%s]: ' "$C_BOLD" "$C_RESET" "$q" "$def"
    else printf '    %s?%s %s: ' "$C_BOLD" "$C_RESET" "$q"; fi
    if [ -n "$secret" ]; then read -r -s -u 3 ans || ans=""; echo; else read -r -u 3 ans || ans=""; fi
    printf -v "$__var" '%s' "${ans:-$def}"
}

# decide VAR "question" default — resolves "" options by asking
decide() {
    local __var="$1" q="$2" def="$3"
    if [ -z "${!__var}" ]; then
        if ask_yn "$q" "$def"; then printf -v "$__var" yes; else printf -v "$__var" no; fi
    fi
}

# --------------------------------------------------------------- helpers ----
as_hermes() {
    (cd "$HOME_DIR" && sudo -u "$HERMES_USER" -H env \
        HOME="$HOME_DIR" USER="$HERMES_USER" LOGNAME="$HERMES_USER" \
        HERMES_HOME="$HERMES_DIR" \
        PATH="$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@")
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@" >/dev/null
}

# set_env KEY VALUE — upsert into the agent's .env without exposing VALUE in argv
set_env() {
    local key="$1" value="$2" tmp line
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid env key: $key"
    [[ "$value" != *$'\n'* ]] || die "env value for $key contains a newline"
    if [[ "$value" =~ ^[A-Za-z0-9_./:@,+=-]*$ ]]; then line="$key=$value"
    elif [[ "$value" != *"'"* ]]; then line="$key='$value'"
    else die "env value for $key contains a single quote; set it manually in $ENV_FILE"; fi
    touch "$ENV_FILE"
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"
    grep -Ev "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" >"$tmp" || true
    printf '%s\n' "$line" >>"$tmp"
    mv "$tmp" "$ENV_FILE"
    chown "$HERMES_USER:$HERMES_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

get_env() { { grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]$//"; }

fix_ownership() { chown -R "$HERMES_USER:$HERMES_USER" "$HOME_DIR"; chmod 700 "$HOME_DIR"; [ ! -d "$HERMES_DIR" ] || chmod 700 "$HERMES_DIR"; }

# ------------------------------------------------------------- preflight ----
preflight() {
    step "Preflight checks"
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"
    exec 9>"$LOCK_FILE"; flock -n 9 || die "another hermes-secure-deploy run is in progress"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    _log_file "hermes-secure-deploy $VERSION mode=$MODE user=$HERMES_USER"

    [ -r /etc/os-release ] || die "cannot detect the OS (/etc/os-release missing)"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        ubuntu:*|debian:*|*:*debian*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
        *) die "unsupported OS '${PRETTY_NAME:-unknown}'. Supported: Ubuntu 22.04+, Debian 12+" ;;
    esac
    [ -d /run/systemd/system ] || die "systemd is not running (containers without systemd are not supported)"
    case "$(uname -m)" in x86_64|aarch64) ok "arch: $(uname -m)" ;; *) die "unsupported CPU architecture $(uname -m)" ;; esac

    local free_gb mem_mb
    free_gb=$(df -Pk / | awk 'NR==2{print int($4/1024/1024)}')
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if [ "$free_gb" -ge 6 ]; then ok "disk: ${free_gb} GB free"; else warn "only ${free_gb} GB free on / — Hermes needs ~4-5 GB"; fi
    if [ "$mem_mb" -ge 1800 ]; then ok "RAM: ${mem_mb} MB"; else warn "only ${mem_mb} MB RAM — 2 GB+ recommended"; fi

    if [ "$NON_INTERACTIVE" = false ] && [ "$HAVE_TTY" = false ]; then
        die "no terminal for questions. Run from an interactive shell or pass --non-interactive"
    fi
}

# ----------------------------------------------------------- the plan -------
gather_choices() {
    step "Configuration"
    decide DO_BASE_HARDENING "Enable unattended security updates and fail2ban (SSH brute-force protection)?" yes
    decide DO_FIREWALL "Enable the ufw firewall (deny all incoming except SSH)?" yes

    local keys=false f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        if [ -s "$f" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f"; then keys=true; fi
    done
    if [ -z "$DO_SSH_HARDENING" ]; then
        if [ "$keys" = true ]; then
            decide DO_SSH_HARDENING "Disable SSH password login (key-only; an authorized_keys file was found)?" yes
        else
            warn "no SSH authorized_keys found — skipping SSH hardening so you don't get locked out"
            DO_SSH_HARDENING=no
        fi
    elif [ "$DO_SSH_HARDENING" = yes ] && [ "$keys" = false ]; then
        die "--ssh-hardening requested but no authorized_keys with a key exists — you would be locked out"
    fi

    decide DO_DASHBOARD "Run the web dashboard (bound to 127.0.0.1 only, reach it through an SSH tunnel)?" no
    if [ -z "$DO_TELEGRAM" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then DO_TELEGRAM=yes; else DO_TELEGRAM=no; fi
        else
            decide DO_TELEGRAM "Connect a Telegram bot?" yes
        fi
    fi
    if [ "$SKIP_BROWSER" = false ] && ! ask_yn "Install Chromium for the agent's browser tool (~600 MB)?" yes; then
        SKIP_BROWSER=true
    fi
}

# ------------------------------------------------------------ packages ------
install_packages() {
    step "System packages"
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
    apt_install ca-certificates curl git sudo xz-utils tar libatomic1 procps util-linux iproute2
    ok "base packages"

    if [ "$SKIP_BROWSER" = false ]; then
        # Runtime libraries the Hermes-managed Chromium links against (it does not pull them itself).
        local p missing=()
        for p in libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 libatspi2.0-0 \
                 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libcairo2 libpango-1.0-0 \
                 libasound2 libdrm2 fonts-liberation; do
            if ! apt_install "$p" 2>/dev/null; then
                # Ubuntu 24.04+/Debian 13 renamed some libs with a t64 suffix
                apt_install "${p}t64" 2>/dev/null || missing+=("$p")
            fi
        done
        if [ ${#missing[@]} -eq 0 ]; then ok "Chromium runtime libraries"
        else warn "could not install: ${missing[*]} (browser tool may not start)"; fi
    fi
}

# ------------------------------------------------------------ hardening -----
base_hardening() {
    [ "$DO_BASE_HARDENING" = yes ] || return 0
    step "Base OS hardening"
    apt_install unattended-upgrades fail2ban python3-systemd
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "unattended security updates"

    cat >/etc/fail2ban/jail.d/hermes-secure-deploy.local <<EOF
$MARKER
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    ok "fail2ban (sshd jail)"
}

firewall() {
    [ "$DO_FIREWALL" = yes ] || return 0
    step "Firewall (ufw)"
    apt_install ufw
    local ports p
    ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u)
    [ -n "$ports" ] || ports=22
    for p in $ports; do ufw allow "$p/tcp" comment 'ssh' >/dev/null; ok "allow SSH on $p/tcp"; done
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    ok "ufw enabled: incoming denied except SSH"
    info "open more ports later with: ufw allow <port>/tcp"
}

ssh_hardening() {
    [ "$DO_SSH_HARDENING" = yes ] || return 0
    step "SSH hardening"
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        warn "/etc/ssh/sshd_config does not include sshd_config.d — skipping (configure manually)"
        return 0
    fi
    local conf=/etc/ssh/sshd_config.d/00-hermes-secure-deploy.conf
    cat >"$conf" <<EOF
$MARKER
# First match wins, so this file (00-) overrides cloud-init's 50-cloud-init.conf.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
MaxAuthTries 4
X11Forwarding no
EOF
    if ! sshd -t 2>/dev/null; then
        rm -f "$conf"
        warn "sshd rejected the config — rolled back"
        return 0
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    ok "password login disabled, root login with keys only"
    warn "keep this session open and test a new SSH login in another terminal"
}

# ---------------------------------------------------------------- user ------
create_user() {
    step "Service account '$HERMES_USER'"
    if id "$HERMES_USER" >/dev/null 2>&1; then
        ok "user exists"
        [ "$(getent passwd "$HERMES_USER" | cut -d: -f6)" = "$HOME_DIR" ] || die "user $HERMES_USER exists but its home is not $HOME_DIR"
    else
        useradd --system --create-home --home-dir "$HOME_DIR" --shell /bin/bash --user-group \
            --comment "Hermes Agent (unprivileged)" "$HERMES_USER"
        ok "created system user $HERMES_USER"
    fi
    passwd -l "$HERMES_USER" >/dev/null 2>&1 || true

    local g bad=()
    for g in $(id -nG "$HERMES_USER"); do
        case "$g" in sudo|wheel|admin|adm|docker|lxd|libvirt|disk|shadow|root|systemd-journal) bad+=("$g") ;; esac
    done
    if [ ${#bad[@]} -gt 0 ]; then
        if ask_yn "$HERMES_USER is in privileged groups (${bad[*]}). Remove it from them?" yes; then
            for g in "${bad[@]}"; do gpasswd -d "$HERMES_USER" "$g" >/dev/null; done
            ok "removed from: ${bad[*]}"
        else
            die "refusing to continue: $HERMES_USER would not be unprivileged"
        fi
    fi
    if [ -n "$(find /etc/sudoers /etc/sudoers.d -type f -exec grep -lE "^[[:space:]]*${HERMES_USER}[[:space:]]" {} + 2>/dev/null)" ]; then
        die "$HERMES_USER has a sudoers entry — remove it first"
    fi
    ok "no sudo, no privileged groups, password locked"

    mkdir -p "$HOME_DIR/.local/bin"
    fix_ownership
    # Hermes' restart-safe cron/kanban workers run under the user's systemd manager.
    loginctl enable-linger "$HERMES_USER" >/dev/null 2>&1 || warn "could not enable linger for $HERMES_USER"
}

# ------------------------------------------------------------- install ------
hermes_version() { as_hermes "$HERMES_BIN" --version 2>/dev/null | head -1 || echo "unknown version"; }

install_hermes() {
    step "Hermes Agent ($CHANNEL channel)"
    if [ -x "$HERMES_BIN" ]; then
        ok "already installed ($(hermes_version)); use --update to upgrade"
        return 0
    fi
    local tmp args
    tmp="$(mktemp -d /tmp/hermes-secure-deploy.XXXXXX)"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$HERMES_INSTALLER_URL" -o "$tmp/install.sh" \
        || die "could not download the Hermes installer from $HERMES_INSTALLER_URL"
    chmod 755 "$tmp"; chmod 644 "$tmp/install.sh"
    info "official installer: $HERMES_INSTALLER_URL"
    info "sha256: $(sha256sum "$tmp/install.sh" | cut -d' ' -f1)"
    info "running it as '$HERMES_USER' (not root); this takes a few minutes…"
    args=(--non-interactive --channel "$CHANNEL")
    [ "$SKIP_BROWSER" = false ] || args+=(--skip-browser)
    if ! as_hermes bash "$tmp/install.sh" "${args[@]}"; then
        rm -rf "$tmp"
        die "the Hermes installer failed — see $HERMES_DIR/logs/install.log"
    fi
    rm -rf "$tmp"
    [ -x "$HERMES_BIN" ] || die "installer finished but $HERMES_BIN is missing"
    fix_ownership
    ok "installed: $(hermes_version)"
}

# ---------------------------------------------------------- configuration ---
telegram_get_me() { # token -> prints bot username; rc 1 = rejected, 2 = unreachable
    local out
    out=$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$1" | curl -sS --max-time 20 -K - 2>/dev/null) || return 2
    [[ "$out" == *'"ok":true'* ]] || return 1
    sed -nE 's/.*"username":"([^"]+)".*/\1/p' <<<"$out"
}

configure_telegram() {
    [ "$DO_TELEGRAM" = yes ] || return 0
    step "Telegram"
    local token="${TELEGRAM_BOT_TOKEN:-}" users="${TELEGRAM_ALLOWED_USERS:-}" home="" bot rc

    if [ -z "$token" ] && [ -n "$(get_env TELEGRAM_BOT_TOKEN)" ]; then
        if ask_yn "A Telegram token is already configured. Keep it?" yes; then
            token="$(get_env TELEGRAM_BOT_TOKEN)"; users="${users:-$(get_env TELEGRAM_ALLOWED_USERS)}"
        fi
    fi
    while true; do
        if [ -z "$token" ]; then
            [ "$HAVE_TTY" = true ] || die "TELEGRAM_BOT_TOKEN is not set (or pass --no-telegram)"
            info "Create a bot with @BotFather in Telegram and paste its token (input is hidden)."
            ask_value token "Bot token" "" secret
        fi
        if [[ ! "$token" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; then
            warn "that does not look like a bot token"
            [ "$HAVE_TTY" = true ] || die "invalid TELEGRAM_BOT_TOKEN"
            token=""; continue
        fi
        rc=0; bot=$(telegram_get_me "$token") || rc=$?
        if [ $rc -eq 0 ]; then ok "token valid: @$bot"; break; fi
        if [ $rc -eq 2 ]; then
            warn "could not reach api.telegram.org to verify the token"
            if ask_yn "Save it without verification?" yes; then break; fi
        else
            warn "Telegram rejected this token"
        fi
        [ "$HAVE_TTY" = true ] || die "invalid TELEGRAM_BOT_TOKEN"
        token=""
    done

    info "Only allow-listed Telegram accounts can talk to the agent."
    info "Get your numeric ID from @userinfobot (or @getmyid_bot)."
    while true; do
        [ -n "$users" ] || ask_value users "Allowed Telegram user IDs (comma-separated)"
        users="${users// /}"
        if [[ "$users" =~ ^[0-9]{3,}(,[0-9]{3,})*$ ]]; then break; fi
        warn "expected numeric IDs like 123456789,987654321"
        [ "$HAVE_TTY" = true ] || die "invalid TELEGRAM_ALLOWED_USERS"
        users=""
    done
    home="${TELEGRAM_HOME_CHANNEL:-${users%%,*}}"

    set_env TELEGRAM_BOT_TOKEN "$token"
    set_env TELEGRAM_ALLOWED_USERS "$users"
    set_env TELEGRAM_HOME_CHANNEL "$home"
    ok "allow-list: $users (cron/notifications go to $home)"
}

configure_extra_env() {
    [ ${#EXTRA_ENV[@]} -gt 0 ] || return 0
    step "Extra environment"
    local kv
    for kv in "${EXTRA_ENV[@]}"; do
        [[ "$kv" == *=* ]] || die "--env expects KEY=VALUE, got: ${kv%%=*}"
        set_env "${kv%%=*}" "${kv#*=}"
        ok "set ${kv%%=*}"
    done
}

configure_model() {
    if [ "$SKIP_MODEL_SETUP" = true ] || [ "$HAVE_TTY" = false ]; then
        info "model setup skipped — run later: hermes setup model"
        return 0
    fi
    step "Model provider"
    info "Starting the official Hermes wizard as '$HERMES_USER' (pick a provider, paste the API key)."
    if ! as_hermes "$HERMES_BIN" setup model <&3; then
        warn "model setup did not finish — run it later: hermes setup model"
    fi
    fix_ownership
}

# --------------------------------------------------------------- systemd ----
write_hardening_dropin() { # unit
    local dir="/etc/systemd/system/$1.d"
    mkdir -p "$dir"
    cat >"$dir/10-hardening.conf" <<EOF
$MARKER
# Sandbox for the Hermes service. Lives in a drop-in, so it survives
# 'hermes gateway install' regenerating the main unit after updates.
[Service]
User=$HERMES_USER
Group=$HERMES_USER
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=$HOME_DIR
ReadWritePaths=$HOME_DIR
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
RestrictRealtime=yes
SystemCallArchitectures=native
UMask=0077
EOF
}

write_fallback_gateway_unit() {
    local node_bin uid
    uid=$(id -u "$HERMES_USER")
    node_bin=$(find "$HERMES_DIR/tools" -maxdepth 2 -type d -path '*/node-*/bin' 2>/dev/null | sort | tail -1)
    cat >"/etc/systemd/system/$GATEWAY_UNIT" <<EOF
$MARKER
[Unit]
Description=Hermes Agent Gateway (user $HERMES_USER)
After=network-online.target user@$uid.service
Wants=network-online.target user@$uid.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$HERMES_USER
Group=$HERMES_USER
WorkingDirectory=$HERMES_DIR
Environment=HOME=$HOME_DIR
Environment=USER=$HERMES_USER
Environment=HERMES_HOME=$HERMES_DIR
Environment=HERMES_SUPERVISED_CHILD=1
Environment="PATH=${node_bin:+$node_bin:}$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$HERMES_BIN gateway run
ExecReload=/bin/kill -USR1 \$MAINPID
ExecStop=-$HERMES_BIN --run-module gateway.systemd_stop_mark
ExecStopPost=-$HERMES_BIN --run-module gateway.cgroup_cleanup
Restart=always
RestartSec=5
RestartForceExitStatus=75
SuccessExitStatus=75
RestartPreventExitStatus=78
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=70

[Install]
WantedBy=multi-user.target
EOF
}

install_units() {
    step "systemd services"
    # Prefer the unit Hermes generates itself (kept current by upstream); fall back to ours.
    if (cd / && env HOME=/root HERMES_HOME="$HERMES_DIR" "$HERMES_BIN" gateway install --system \
            --run-as-user "$HERMES_USER" --force) >>"$LOG_FILE" 2>&1 \
       && [ -f "/etc/systemd/system/$GATEWAY_UNIT" ] \
       && grep -q "^User=$HERMES_USER\$" "/etc/systemd/system/$GATEWAY_UNIT"; then
        ok "gateway unit generated by Hermes"
    else
        write_fallback_gateway_unit
        warn "used the bundled gateway unit (Hermes' own generator failed — see $LOG_FILE)"
    fi
    fix_ownership   # running the CLI as root above may have created root-owned files
    write_hardening_dropin "$GATEWAY_UNIT"
    ok "sandbox drop-in: /etc/systemd/system/$GATEWAY_UNIT.d/10-hardening.conf"

    if [ "$DO_DASHBOARD" = yes ]; then
        cat >"/etc/systemd/system/$DASHBOARD_UNIT" <<EOF
$MARKER
[Unit]
Description=Hermes Agent dashboard (127.0.0.1 only; user $HERMES_USER)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HERMES_USER
Group=$HERMES_USER
WorkingDirectory=$HOME_DIR
Environment=HOME=$HOME_DIR
Environment=HERMES_HOME=$HERMES_DIR
ExecStart=$HERMES_BIN dashboard --host 127.0.0.1 --port 9119 --no-open
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        write_hardening_dropin "$DASHBOARD_UNIT"
        ok "dashboard unit (127.0.0.1:9119)"
    elif [ -f "/etc/systemd/system/$DASHBOARD_UNIT" ] && grep -q "$MARKER" "/etc/systemd/system/$DASHBOARD_UNIT"; then
        systemctl disable --now "$DASHBOARD_UNIT" >/dev/null 2>&1 || true
        rm -rf "/etc/systemd/system/$DASHBOARD_UNIT" "/etc/systemd/system/$DASHBOARD_UNIT.d"
        info "removed the dashboard unit"
    fi

    systemctl daemon-reload
    systemctl enable "$GATEWAY_UNIT" >/dev/null 2>&1
    systemctl restart "$GATEWAY_UNIT"
    if [ "$DO_DASHBOARD" = yes ]; then
        systemctl enable "$DASHBOARD_UNIT" >/dev/null 2>&1
        systemctl restart "$DASHBOARD_UNIT"
    fi
    ok "services enabled and started"
}

install_wrapper() {
    step "CLI wrapper"
    local w=/usr/local/bin/hermes
    if [ -e "$w" ] && ! grep -q "$MARKER" "$w" 2>/dev/null; then
        mv "$w" "$w.bak.$(date +%s)"
        warn "moved the existing $w aside"
    fi
    cat >"$w" <<EOF
#!/bin/sh
$MARKER
# Runs the Hermes CLI as the unprivileged '$HERMES_USER' account — never as root.
if [ "\$(id -un)" = "$HERMES_USER" ]; then exec "$HERMES_BIN" "\$@"; fi
cd "$HOME_DIR" 2>/dev/null || cd /
exec sudo -u "$HERMES_USER" -H HERMES_HOME="$HERMES_DIR" "$HERMES_BIN" "\$@"
EOF
    chmod 755 "$w"
    ok "'hermes' run by root now executes as $HERMES_USER"
}

# ---------------------------------------------------------------- verify ----
verify() {
    step "Verification"
    local pid=0 running=false
    for _ in $(seq 1 60); do
        if systemctl is-active -q "$GATEWAY_UNIT"; then
            pid=$(systemctl show -p MainPID --value "$GATEWAY_UNIT")
            if [ "${pid:-0}" -gt 0 ]; then running=true; break; fi
        fi
        sleep 2
    done
    if [ "$running" = true ]; then
        ok "gateway is running (pid $pid)"
        if [ "$(ps -o user= -p "$pid" | tr -d ' ')" = "$HERMES_USER" ]; then ok "runs as $HERMES_USER"
        else warn "gateway does NOT run as $HERMES_USER"; fi
        if grep -q '^NoNewPrivs:[[:space:]]*1' "/proc/$pid/status"; then ok "NoNewPrivileges active"
        else warn "NoNewPrivileges not active"; fi
    else
        warn "gateway is not running: journalctl -u $GATEWAY_UNIT -n 50"
    fi

    if [ "$DO_TELEGRAM" = yes ] && [ "$running" = true ]; then
        info "waiting for Telegram (first start installs dependencies, up to ~3 min)…"
        local connected=false
        for _ in $(seq 1 90); do
            if journalctl -u "$GATEWAY_UNIT" --since "-10min" --no-pager 2>/dev/null | grep -q 'Connected to Telegram'; then
                connected=true; break
            fi
            sleep 2
        done
        if [ "$connected" = true ]; then ok "connected to Telegram — say hi to your bot"
        else warn "no Telegram connection yet — check: journalctl -u $GATEWAY_UNIT -f"; fi
    fi

    if sudo -l -U "$HERMES_USER" 2>/dev/null | grep -q 'not allowed'; then ok "no sudo rights"
    else warn "$HERMES_USER may have sudo rights!"; fi
    if as_hermes test -r /etc/shadow 2>/dev/null; then warn "$HERMES_USER can read /etc/shadow!"; else ok "cannot read /etc/shadow"; fi
    if as_hermes ls /root >/dev/null 2>&1; then warn "$HERMES_USER can list /root!"; else ok "cannot access /root"; fi
    if [ -S /var/run/docker.sock ]; then
        if as_hermes test -w /var/run/docker.sock; then warn "$HERMES_USER can use Docker (root-equivalent)!"
        else ok "no Docker access"; fi
    fi
    if [ "$DO_DASHBOARD" = yes ]; then
        for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q '127.0.0.1:9119 ' && break; sleep 2; done
        if ss -ltn | grep -q '127.0.0.1:9119 '; then ok "dashboard listening on 127.0.0.1:9119"
        else warn "dashboard not listening yet: journalctl -u $DASHBOARD_UNIT"; fi
    fi
}

summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    cat <<EOF

${C_BOLD}${C_GREEN}Hermes Agent is deployed.${C_RESET}

  Service account   $HERMES_USER (no sudo, no password, sandboxed by systemd)
  Config            $HERMES_DIR/config.yaml
  Secrets (.env)    $ENV_FILE   (mode 600)
  Gateway           systemctl status $GATEWAY_UNIT
  Logs              journalctl -u $GATEWAY_UNIT -f

  CLI as root       hermes <command>        (transparently runs as $HERMES_USER)
  Change model      hermes setup model      then: systemctl restart $GATEWAY_UNIT
  Update Hermes     sudo bash install.sh --update
EOF
    if [ "$DO_DASHBOARD" = yes ]; then
        echo "  Dashboard         ssh -L 9119:127.0.0.1:9119 root@${ip:-<server>}   then open http://127.0.0.1:9119"
    fi
    echo
}

# ------------------------------------------------------------------ update --
do_update() {
    [ -x "$HERMES_BIN" ] || die "Hermes is not installed for $HERMES_USER — run without --update first"
    step "Updating Hermes"
    if [ "$HAVE_TTY" = true ]; then as_hermes "$HERMES_BIN" update <&3; else as_hermes "$HERMES_BIN" update </dev/null; fi
    fix_ownership
    if [ -f "/etc/systemd/system/$DASHBOARD_UNIT" ]; then DO_DASHBOARD=yes; else DO_DASHBOARD=no; fi
    if [ -n "$(get_env TELEGRAM_BOT_TOKEN)" ]; then DO_TELEGRAM=yes; else DO_TELEGRAM=no; fi
    install_units
    verify
}

# -------------------------------------------------------------------- main --
main() {
    printf '%shermes-secure-deploy %s%s — Hermes Agent as an unprivileged, sandboxed service\n' "$C_BOLD" "$VERSION" "$C_RESET"
    preflight
    if [ "$MODE" = update ]; then do_update; summary; return; fi
    gather_choices
    install_packages
    base_hardening
    firewall
    ssh_hardening
    create_user
    install_hermes
    configure_telegram
    configure_extra_env
    configure_model
    install_units
    install_wrapper
    verify
    summary
}

main "$@"
