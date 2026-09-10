#!/usr/bin/env bash
# PrepperPi non-destructive application updater — safe to re-run on an existing install.
# Backs up configs before touching anything. Skips network/AP setup.
# Usage: sudo bash scripts/update-app.sh
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[-]${NC} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash scripts/update-app.sh"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/opt/prepperpi/backup/pre-update-${TIMESTAMP}"

info "Repository root: $REPO_DIR"
info "Backup destination: $BACKUP_DIR"

# ── Source network config (read-only — we don't modify it here) ───────────────
[[ -f "$REPO_DIR/config/network.conf" ]] \
    || die "config/network.conf not found. Run fresh-install.sh for a new setup."

# shellcheck source=/dev/null
source "$REPO_DIR/config/network.conf"

# ── Back up live configs before touching anything ─────────────────────────────
info "Backing up existing configs to $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"

# Capture whatever is currently deployed
[[ -f /etc/hostapd/hostapd.conf ]]            && cp /etc/hostapd/hostapd.conf         "$BACKUP_DIR/"
[[ -f /etc/dnsmasq.d/prepperpi.conf ]]        && cp /etc/dnsmasq.d/prepperpi.conf     "$BACKUP_DIR/"
[[ -f /etc/nginx/sites-available/prepperpi ]] && cp /etc/nginx/sites-available/prepperpi "$BACKUP_DIR/"
[[ -d /opt/prepperpi/webapp ]]                && cp -r /opt/prepperpi/webapp           "$BACKUP_DIR/webapp"
for unit in prepperpi-web.service kiwix-serve.service; do
    [[ -f /etc/systemd/system/$unit ]] && cp /etc/systemd/system/$unit "$BACKUP_DIR/"
done

info "Backup complete."

# ── Python venv — update packages ─────────────────────────────────────────────
info "Updating Python packages..."
if [[ ! -d /opt/prepperpi/venv ]]; then
    warn "Virtualenv not found — creating a fresh one."
    python3 -m venv /opt/prepperpi/venv
fi
/opt/prepperpi/venv/bin/pip install --upgrade pip --quiet
/opt/prepperpi/venv/bin/pip install -r "$REPO_DIR/requirements.txt" --quiet
info "Packages: $(/opt/prepperpi/venv/bin/pip freeze | paste -sd, -)"

# ── Application files ─────────────────────────────────────────────────────────
info "Syncing webapp files..."
install -d -m 755 /opt/prepperpi/webapp
find "$REPO_DIR/scripts" -name "*.sh" -exec dos2unix -q {} \;

rsync -a --delete "$REPO_DIR/webapp/" /opt/prepperpi/webapp/ 2>/dev/null \
    || cp -r "$REPO_DIR/webapp/." /opt/prepperpi/webapp/

info "Syncing scripts..."
install -d -m 755 /opt/prepperpi/scripts
cp "$REPO_DIR/scripts/"*.sh  /opt/prepperpi/scripts/
cp "$REPO_DIR/scripts/"*.py  /opt/prepperpi/scripts/ 2>/dev/null || true
chmod +x /opt/prepperpi/scripts/*.sh

# ── nginx config (non-destructive: only update if the site block changed) ─────
info "Updating nginx site config..."
cp "$REPO_DIR/configs/nginx/prepperpi.conf" /etc/nginx/sites-available/prepperpi
ln -sf /etc/nginx/sites-available/prepperpi /etc/nginx/sites-enabled/prepperpi
nginx -t || die "nginx config test failed — check configs/nginx/prepperpi.conf"

# ── systemd units — update app units only, leave network units alone ──────────
info "Updating app-layer systemd units..."
for unit in \
    prepperpi-web.service \
    kiwix-serve.service \
    prepperpi-update.service \
    prepperpi-update.timer \
    prepperpi-backup.service \
    prepperpi-backup.timer \
    prepperpi-monitor.service \
    os-update-weekly.service \
    os-update-weekly.timer
do
    # Prefer configs/systemd/ over systemd/ when both exist
    src=""
    [[ -f "$REPO_DIR/systemd/$unit" ]]         && src="$REPO_DIR/systemd/$unit"
    [[ -f "$REPO_DIR/configs/systemd/$unit" ]] && src="$REPO_DIR/configs/systemd/$unit"
    if [[ -n "$src" ]]; then
        cp "$src" /etc/systemd/system/$unit
        info "  updated $unit"
    fi
done

# kiwix-serve hardening drop-in
mkdir -p /etc/systemd/system/kiwix-serve.service.d
cp "$REPO_DIR/systemd/kiwix-serve.service.d/override.conf" \
   /etc/systemd/system/kiwix-serve.service.d/override.conf

# ── Reload and restart app services ───────────────────────────────────────────
info "Reloading systemd and restarting app services..."
systemctl daemon-reload
systemctl reload-or-restart nginx
systemctl restart prepperpi-web.service || warn "prepperpi-web failed to restart — check: journalctl -u prepperpi-web"
systemctl restart kiwix-serve.service   || warn "kiwix-serve failed to restart — check: journalctl -u kiwix-serve"

# Intentionally NOT restarting: hostapd, dnsmasq, nat-iptables
# Those are network-layer services that affect connected clients.
# Run fresh-install.sh if you need to change network config.

# ── Permissions ───────────────────────────────────────────────────────────────
info "Fixing permissions..."
chown -R prepperpi:prepperpi /opt/prepperpi
chown -R prepperpi:prepperpi /var/log/prepperpi 2>/dev/null || true
chmod 750 /opt/prepperpi/scripts/*.sh
chmod 640 /opt/prepperpi/webapp/*.py 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "Update complete."
info "  Web UI : http://${PI_IP}/"
info "  Backup : $BACKUP_DIR"
warn "No reboot required — services restarted in place."
