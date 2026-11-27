#!/bin/bash
# zluggish-hosts.sh — root helper for zwift-steamos Zluggish offline mode.
#
#   zluggish-hosts.sh add <server-ip>    redirect Zwift's client domains to the server in /etc/hosts
#   zluggish-hosts.sh remove             remove the managed block (back to Zwift online)
#   zluggish-hosts.sh trust <cert.pem>   add the server certificate to the system trust store
#   zluggish-hosts.sh cacert <zwift-dir> append the server certificate to the game's data/cacert.pem
#   zluggish-hosts.sh status             show the managed block (or "inactive")
#
# The Steam prelaunch calls `add`/`remove` per launch through a NOPASSWD sudoers rule installed by
# install.sh; `trust`/`cacert` are one-time setup calls. Domains are Zluggish's official list
# (docs.zluggish.com): the game relay, auth, CDN and launcher-update endpoints.

set -euo pipefail

MARK_BEGIN="# BEGIN zwift-steamos zluggish (managed)"
MARK_END="# END zwift-steamos zluggish (managed)"
DOMAINS="us-or-rly101.zwift.com secure.zwift.com cdn.zwift.com launcher.zwift.com"
HOSTS=/etc/hosts
ANCHOR_DIR=/etc/ca-certificates/trust-source/anchors     # SteamOS (Arch-style p11-kit layout)

strip_block() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
        'index($0, b) == 1 { skip = 1; next } index($0, e) == 1 { skip = 0; next } !skip' \
        "$HOSTS" > "${HOSTS}.tmp" && mv "${HOSTS}.tmp" "$HOSTS"
}

case "${1:-}" in
    add)
        IP="${2:?usage: $0 add <server-ip>}"
        [[ "$IP" =~ ^[0-9a-fA-F:.]+$ ]] || { echo "invalid IP: $IP" >&2; exit 2; }
        strip_block
        { echo "$MARK_BEGIN"; for d in $DOMAINS; do echo "$IP $d"; done; echo "$MARK_END"; } >> "$HOSTS"
        echo "hosts: Zwift domains -> $IP"
        ;;
    remove)
        strip_block
        echo "hosts: managed block removed (Zwift online)"
        ;;
    status)
        if grep -qs "^$MARK_BEGIN\$" "$HOSTS"; then grep -A6 "^$MARK_BEGIN\$" "$HOSTS"; else echo "inactive"; fi
        ;;
    trust)
        CERT="${2:?usage: $0 trust <server-cert.pem>}"
        [ -f "$CERT" ] || { echo "no such file: $CERT" >&2; exit 2; }
        install -m 0644 "$CERT" "$ANCHOR_DIR/zwift-steamos-zluggish.crt"
        if command -v update-ca-trust >/dev/null 2>&1; then
            update-ca-trust extract
        elif command -v update-ca-certificates >/dev/null 2>&1; then
            update-ca-certificates
        else
            echo "no CA trust tool found" >&2; exit 1
        fi
        echo "trust: Zluggish certificate added to the system store"
        ;;
    cacert)
        ZDIR="${2:?usage: $0 cacert <zwift-game-dir>}"
        PEM="/opt/zluggish-cert/zwift-server.pem"
        [ -f "$PEM" ] || PEM="/etc/zwift-steamos/zwift-server.pem"
        [ -f "$PEM" ] || { echo "server certificate not found" >&2; exit 2; }
        BUNDLE="$ZDIR/data/cacert.pem"
        [ -f "$BUNDLE" ] || { echo "no $BUNDLE - is the game installed?" >&2; exit 1; }
        if ! grep -qs 'BEGIN ZLUGGISH SERVER CERTIFICATE' "$BUNDLE"; then
            printf '# BEGIN ZLUGGISH SERVER CERTIFICATE\n' >> "$BUNDLE"
            cat "$PEM" >> "$BUNDLE"
            printf '# END ZLUGGISH SERVER CERTIFICATE\n' >> "$BUNDLE"
            echo "cacert: server certificate appended to $BUNDLE"
        else
            echo "cacert: already present in $BUNDLE"
        fi
        ;;
    *)
        echo "usage: $0 add <ip>|remove|status|trust <cert.pem>|cacert <zwift-dir>" >&2
        exit 2
        ;;
esac
