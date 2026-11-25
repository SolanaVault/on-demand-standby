#!/usr/bin/env bash
# Install fd-standby from this checkout. Idempotent; never overwrites your config.
#   sudo ./install.sh            code -> /opt/fd-standby (symlink to this checkout), units, config skeleton
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null && python3 -c 'import tomllib' || { echo "need python3 >= 3.11"; exit 1; }
for b in curl ssh ssh-keygen tar sha256sum; do command -v $b >/dev/null || { echo "missing $b"; exit 1; }; done
[ "$SRC" = /opt/fd-standby ] || ln -sfn "$SRC" /opt/fd-standby
install -d -m 700 /etc/fd-standby /var/lib/fd-standby
[ -e /etc/fd-standby/fd-standby.conf ] || { install -m 600 "$SRC/config/fd-standby.conf.example" /etc/fd-standby/fd-standby.conf; echo "created /etc/fd-standby/fd-standby.conf - EDIT IT"; }
[ -e /etc/fd-standby/candidates.conf ] || { install -m 600 "$SRC/config/candidates.conf" /etc/fd-standby/candidates.conf; echo "created /etc/fd-standby/candidates.conf"; }
[ -e /etc/fd-standby/candidates-agave.conf ] || { install -m 600 "$SRC/config/candidates-agave.conf" /etc/fd-standby/candidates-agave.conf; echo "created /etc/fd-standby/candidates-agave.conf"; }
# shellcheck disable=SC1091
. /etc/fd-standby/fd-standby.conf
K=${SSH_KEY:-/root/.ssh/id_ed25519_fd_standby}
[ -e "$K" ] || { ssh-keygen -q -t ed25519 -N '' -C "fd-standby@$(hostname)" -f "$K"; echo "created SSH key $K"; }
ln -sfn /opt/fd-standby/bin/fd-standby /usr/local/sbin/fd-standby
ln -sfn /opt/fd-standby/bin/fd-standby-swap /usr/local/sbin/fd-standby-swap
install -m 644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q --now fd-standby-watchdog.timer
echo "installed. Next: edit /etc/fd-standby/fd-standby.conf, put your Cherry API token in the token file, then run: fd-standby doctor"
echo "optional: systemctl enable --now fd-standby-qualify.timer   (qualifies one new server type per day when in stock)"
