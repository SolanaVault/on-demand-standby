#!/usr/bin/env bash
# Install ods from this checkout. Idempotent; never overwrites your config.
#   sudo ./install.sh            code -> /opt/ods (symlink to this checkout), units, config skeleton
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null && python3 -c 'import tomllib' || { echo "need python3 >= 3.11"; exit 1; }
for b in curl ssh ssh-keygen tar sha256sum; do command -v $b >/dev/null || { echo "missing $b"; exit 1; }; done
[ "$SRC" = /opt/ods ] || ln -sfn "$SRC" /opt/ods
install -d -m 700 /etc/ods /var/lib/ods
[ -e /etc/ods/ods.conf ] || { install -m 600 "$SRC/config/ods.conf.example" /etc/ods/ods.conf; echo "created /etc/ods/ods.conf - EDIT IT"; }
[ -e /etc/ods/candidates.conf ] || { install -m 600 "$SRC/config/candidates.conf" /etc/ods/candidates.conf; echo "created /etc/ods/candidates.conf"; }
[ -e /etc/ods/candidates-agave.conf ] || { install -m 600 "$SRC/config/candidates-agave.conf" /etc/ods/candidates-agave.conf; echo "created /etc/ods/candidates-agave.conf"; }
# shellcheck disable=SC1091
. /etc/ods/ods.conf
K=${SSH_KEY:-/root/.ssh/id_ed25519_ods}
[ -e "$K" ] || { ssh-keygen -q -t ed25519 -N '' -C "ods@$(hostname)" -f "$K"; echo "created SSH key $K"; }
ln -sfn /opt/ods/bin/ods /usr/local/sbin/ods
ln -sfn /opt/ods/bin/ods-swap /usr/local/sbin/ods-swap
install -m 644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q --now ods-watchdog.timer
echo "installed. Next: edit /etc/ods/ods.conf, put your Cherry API token in the token file, then run: ods doctor"
echo "optional: systemctl enable --now ods-qualify.timer   (qualifies one new server type per day when in stock)"
