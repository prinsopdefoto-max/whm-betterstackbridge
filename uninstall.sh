#!/bin/bash
# Removes StatusBridge for WHM. Pass --purge to also delete everything it created in
# Better Stack (heartbeats, sections, status page items) and the local configuration.
set -euo pipefail

if [ "$(id -u)" != "0" ]; then echo "Please run this script as root." >&2; exit 1; fi

SRC="$(cd "$(dirname "$0")" && pwd)"
PERL=/usr/local/cpanel/3rdparty/bin/perl

rm -f /etc/cron.d/betterstack-whm

if [ -f /etc/systemd/system/betterstack-whm-maintenance.service ]; then
    systemctl disable --now betterstack-whm-maintenance.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/betterstack-whm-maintenance.service
    systemctl daemon-reload || true
fi

if [ "${1:-}" = "--purge" ] && [ -x /opt/betterstack-whm/bin/bswhm ]; then
    echo "Removing items from Better Stack ..."
    "$PERL" /opt/betterstack-whm/bin/bswhm cleanup || echo "Clean-up in Better Stack reported errors, please check manually."
fi

/usr/local/cpanel/bin/unregister_appconfig betterstack 2>/dev/null \
    || /usr/local/cpanel/bin/unregister_appconfig "$SRC/whm/betterstack.conf" 2>/dev/null || true
rm -rf /usr/local/cpanel/whostmgr/docroot/cgi/betterstack
rm -f /usr/local/cpanel/whostmgr/docroot/addon_plugins/betterstack.png
rm -f /usr/local/sbin/bswhm
rm -rf /opt/betterstack-whm

if [ "${1:-}" = "--purge" ]; then
    rm -rf /etc/betterstack-whm /var/lib/betterstack-whm /var/log/betterstack-whm.log*
fi

echo "StatusBridge for WHM has been removed."
