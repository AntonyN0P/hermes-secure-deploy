#!/usr/bin/env bash
# hermes-secure-deploy — remove the Hermes services installed by install.sh.
# By default the service account and its data are KEPT; pass --purge to delete them.
set -Eeuo pipefail

MARKER="# managed-by: hermes-secure-deploy"
HERMES_USER="${HERMES_USER:-hermes}"
PURGE=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --user) HERMES_USER="${2:?--user needs a value}"; shift 2 ;;
        --purge) PURGE=true; shift ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        -h|--help)
            echo "Usage: sudo bash uninstall.sh [--user NAME] [--purge] [-y]"
            echo "  --purge   also delete the '$HERMES_USER' account and /home/$HERMES_USER (a backup tarball is made first)"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
[ "$HERMES_USER" != root ] || { echo "refusing to touch root" >&2; exit 2; }

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    local ans; printf '%s [y/N] ' "$1"; read -r ans </dev/tty || ans=""
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]
}

echo "==> Stopping Hermes services"
for unit in hermes-gateway.service hermes-dashboard.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -rf "/etc/systemd/system/$unit" "/etc/systemd/system/$unit.d"
    echo "    removed $unit"
done
systemctl daemon-reload

if grep -q "$MARKER" /usr/local/bin/hermes 2>/dev/null; then
    rm -f /usr/local/bin/hermes
    echo "    removed /usr/local/bin/hermes wrapper"
fi

echo "    OS hardening (ufw, fail2ban, unattended-upgrades, SSH config) is left in place."
echo "    To revert SSH hardening: rm /etc/ssh/sshd_config.d/00-hermes-secure-deploy.conf && systemctl reload ssh"
if [ -f /swapfile-hermes ]; then
    echo "    Swap file /swapfile-hermes is left in place. To remove it:"
    echo "      swapoff /swapfile-hermes && rm /swapfile-hermes && sed -i '\\|^/swapfile-hermes |d' /etc/fstab && rm -f /etc/sysctl.d/90-hermes-swap.conf"
fi

if [ "$PURGE" = true ] && id "$HERMES_USER" >/dev/null 2>&1; then
    home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
    if [ "$home" != "/home/$HERMES_USER" ]; then
        echo "    home of $HERMES_USER is '$home', not /home/$HERMES_USER — refusing to delete it automatically" >&2
        exit 1
    fi
    if confirm "Delete user '$HERMES_USER' and $home (agent config, secrets, memories)?"; then
        backup="/root/hermes-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$backup" -C "$(dirname "$home")" --exclude='.hermes/tools' --exclude='.hermes/cache' "$(basename "$home")"
        chmod 600 "$backup"
        echo "    backup (contains secrets!): $backup"
        loginctl disable-linger "$HERMES_USER" >/dev/null 2>&1 || true
        pkill -u "$HERMES_USER" >/dev/null 2>&1 || true
        sleep 1
        userdel -r "$HERMES_USER" 2>/dev/null || userdel "$HERMES_USER"
        rm -rf "$home"
        echo "    deleted $HERMES_USER and $home"
    fi
else
    echo "    kept user '$HERMES_USER' and its data (use --purge to delete)"
fi
echo "Done."
