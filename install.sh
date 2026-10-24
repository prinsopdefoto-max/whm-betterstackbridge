#!/bin/bash
# Installs or upgrades StatusBridge for WHM. Run as root from the repository directory.
set -euo pipefail

if [ "$(id -u)" != "0" ]; then echo "Please run this script as root." >&2; exit 1; fi
if [ ! -x /usr/local/cpanel/bin/register_appconfig ]; then echo "cPanel/WHM not found." >&2; exit 1; fi

umask 022
SRC="$(cd "$(dirname "$0")" && pwd)"

# Everything below is installed as root and executed as root. Refuse a source
# tree that someone other than root could have modified.
if [ -n "$(find "$SRC" -path "$SRC/.git" -prune -o \( ! -user root -o -perm -0002 -o -perm -0020 \) -print -quit)" ]; then
    echo "Refusing: $SRC contains files not owned by root or writable by others." >&2
    exit 1
fi
PREFIX=/opt/betterstack-whm
DOCROOT=/usr/local/cpanel/whostmgr/docroot
PERL=/usr/local/cpanel/3rdparty/bin/perl

echo "Installing files to $PREFIX ..."
install -d -m 0755 "$PREFIX/lib/BetterStack/WHM" "$PREFIX/bin"
install -m 0644 "$SRC"/lib/BetterStack/WHM/*.pm "$PREFIX/lib/BetterStack/WHM/"
install -m 0755 "$SRC/bin/bswhm" "$PREFIX/bin/bswhm"
ln -sf "$PREFIX/bin/bswhm" /usr/local/sbin/bswhm

echo "Registering the WHM plugin ..."
install -d -m 0755 "$DOCROOT/cgi/betterstack" "$DOCROOT/addon_plugins"
install -m 0755 "$SRC/cgi/index.cgi" "$DOCROOT/cgi/betterstack/index.cgi"
install -m 0644 "$SRC/whm/betterstack.png" "$DOCROOT/addon_plugins/betterstack.png"
/usr/local/cpanel/bin/register_appconfig "$SRC/whm/betterstack.conf"

install -d -m 0700 -o root -g root /etc/betterstack-whm /var/lib/betterstack-whm
chown -R root:root /etc/betterstack-whm /var/lib/betterstack-whm "$PREFIX" "$DOCROOT/cgi/betterstack"
chmod 0700 /etc/betterstack-whm /var/lib/betterstack-whm
find /etc/betterstack-whm /var/lib/betterstack-whm -type f -exec chmod 0600 {} +
# Older versions created the log world-readable.
for f in /var/log/betterstack-whm.log /var/log/betterstack-whm.log.1; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then chown root:root "$f"; chmod 0600 "$f"; fi
done

echo "Installing the cron job ..."
install -m 0644 "$SRC/whm/betterstack-whm.cron" /etc/cron.d/betterstack-whm

echo "Checking syntax ..."
for f in "$PREFIX"/lib/BetterStack/WHM/*.pm "$PREFIX/bin/bswhm"; do
    "$PERL" -I"$PREFIX/lib" -c "$f" >/dev/null 2>&1 || { echo "Syntax error in $f" >&2; "$PERL" -I"$PREFIX/lib" -c "$f"; exit 1; }
done

# Remember the clone and commit this install came from, for the update check in WHM.
COMMIT=""
UPSTREAM=""
if [ -d "$SRC/.git" ] && command -v git >/dev/null 2>&1; then
    COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
    UPSTREAM="$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
fi
SRC="$SRC" COMMIT="$COMMIT" UPSTREAM="$UPSTREAM" "$PERL" -I"$PREFIX/lib" -MBetterStack::WHM::Util=write_json \
    -e 'write_json( "/var/lib/betterstack-whm/install.json", { source => $ENV{SRC}, commit => $ENV{COMMIT}, upstream => $ENV{UPSTREAM}, at => time } )'

echo "Synchronising with Better Stack (also removes duplicates) ..."
"$PERL" "$PREFIX/bin/bswhm" sync || true

echo "Running all checks ..."
"$PERL" "$PREFIX/bin/bswhm" run --force || true

echo
echo "Done. Open WHM -> Plugins -> StatusBridge to enter your Better Stack API token and choose a status page."
