#!/bin/bash
# steam-prelaunch.sh — native pre-launch wrapper for the Steam UI shortcut. Part of zwift-steamos.
# shellcheck shell=bash
#
# Steam runs this before Proton (launch options: `ZWIFT_STEAMOS_DATA=... <this> %command%`).
# It does the natively-run parts of the old umu flow and then execs Proton:
#
#   1. toggles Zluggish offline mode when ZWIFT_OFFLINE_HOST is set (or unset, to go back online)
#   2. resets stale Bluetooth state and checks that BLE scanning works (sensors appear in Zwift)
#   3. checks the installed game against Zwift's servers and updates it in place when outdated
#   4. refreshes the sign-in token (zwift-auth.py) and copies it where LinuxZwiftLauncher.exe reads it
#   5. writes VIDEO_CAPTURE and resolution into the game's prefs.xml
#   6. spawns a watcher that releases paired Bluetooth sensors once the game exits
#
# Everything Wine/Proton-related (PROTON_ENABLE_WINEBTH, WINEDLLOVERRIDES, GAMEID, ...) is exported
# here, so launch options stay a simple, unquoted one-liner.

set -u

ZWIFT_DATA="${ZWIFT_STEAMOS_DATA:-$HOME/.local/share/zwift-steamos}"
CONF="$ZWIFT_DATA/zwift.conf"
GAME_DIR="$ZWIFT_DATA/game"
RESOLUTION="auto"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"    # GAME_DIR, RESOLUTION, ZWIFT_OFFLINE_DEFAULT, DO_BLE, ... (installer-written)
fi
GAME_DIR="${GAME_DIR:-$ZWIFT_DATA/game}"

LOG="$ZWIFT_DATA/prelaunch.log"
log() {
    # Write to the log file directly and echo to stderr best-effort. Do NOT pipe through
    # `tee` here: Steam's stderr capture pipe can be O_NONBLOCK, which makes tee spin in a
    # poll loop forever - the script then blocks in wait4 on the tee and never launches.
    local line
    line="$(printf '[zwift-steamos %s] %s' "$(date +%H:%M:%S)" "$*")"
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
    printf '%s\n' "$line" >&2 2>/dev/null || true
}
mkdir -p "$ZWIFT_DATA"

log "prelaunch: data=$ZWIFT_DATA game=$GAME_DIR"

# ---------------------------------------------------------------- Steam/Proton env
# Steam provides STEAM_COMPAT_DATA_PATH (our prefix lives in $STEAM_COMPAT_DATA_PATH/pfx).
export PROTON_ENABLE_WINEBTH="${PROTON_ENABLE_WINEBTH:-1}"        # winebth.sys: BLE sensors (GE-Proton >= 11-8)
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-libusb0=b;vccorlib140=n,b;winemenubuilder.exe=d}"
export PROTON_USE_XALIA="${PROTON_USE_XALIA:-0}"
export GAMEID="${GAMEID:-umu-zwift}"                               # protonfixes: .NET/fonts/webview2 for the prefix
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---disable-features=RendererCodeIntegrity}"

if [ -z "${STEAM_COMPAT_DATA_PATH:-}" ]; then
    log "ERROR: STEAM_COMPAT_DATA_PATH is not set - launch Zwift from the Steam UI, not directly."
    exit 101
fi
PFX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$PFX/drive_c"

# ---------------------------------------------------------------- helpers (lifted from zwift-linux)
# Wine remembers which Bluetooth MACs the game paired with (system.reg _ORG_BLUEZ_HCI...).
ble_known() {
    grep -oiE '_ORG_BLUEZ_HCI[0-9]+&[0-9A-F]{12}' "$PFX/system.reg" 2>/dev/null | grep -oiE '[0-9A-F]{12}$' \
        | tr 'a-f' 'A-F' | sort -u | sed 's/../&:/g; s/:$//'
}

# Release sensors the game paired with in a previous (crashed) session. Touches only those MACs,
# so audio devices and other apps' connections are left alone.
ble_release() {
    [ "${DO_BLE:-1}" = 1 ] && command -v bluetoothctl >/dev/null || return 0
    local mac
    for mac in $(ble_known); do
        if timeout 5 bluetoothctl info "$mac" 2>/dev/null | grep -q 'Connected: yes'; then
            timeout 5 bluetoothctl disconnect "$mac" >/dev/null 2>&1 && log "Released Bluetooth device $mac"
        fi
    done
}

# Make sure the adapter accepts a scan right now; reset it when a stale scan/connection blocks it.
ble_preflight() {
    [ "${DO_BLE:-1}" = 1 ] && command -v bluetoothctl >/dev/null || return 0
    local out
    out="$(timeout 10 bluetoothctl --timeout 3 scan on 2>&1)" || true
    if printf '%s' "$out" | grep -qE 'InProgress|Failed to start discovery'; then
        log "Bluetooth adapter is busy (stale scan or connection) - resetting it..."
        timeout 10 bluetoothctl power off >/dev/null 2>&1; sleep 2
        timeout 10 bluetoothctl power on  >/dev/null 2>&1; sleep 2
        out="$(timeout 10 bluetoothctl --timeout 3 scan on 2>&1)" || true
        if printf '%s' "$out" | grep -qE 'InProgress|Failed to start discovery'; then
            log "Warning: Bluetooth scanning still fails; Bluetooth devices may not appear in Zwift."
        else
            log "Bluetooth adapter reset - scanning works."
        fi
    fi
}

# Zwift renders at USER_RESOLUTION_PREF in prefs.xml (see zwift-resolution.sh for why it's needed).
apply_prefs() {
    local p
    for p in "$PFX"/drive_c/users/*/AppData/Local/Zwift/prefs.xml "$PFX"/drive_c/users/*/Documents/Zwift/prefs.xml; do
        [ -f "$p" ] || continue
        grep -q '<VIDEO_CAPTURE_ENABLED>' "$p" || sed -i 's#</CONFIG>#    <VIDEO_CAPTURE_ENABLED>0</VIDEO_CAPTURE_ENABLED>\n    </CONFIG>#' "$p"
        if [ "${RESOLUTION:-auto}" != auto ] && [[ "$RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
            if grep -q '<USER_RESOLUTION_PREF>' "$p"; then
                sed -i "s#<USER_RESOLUTION_PREF>[^<]*</USER_RESOLUTION_PREF>#<USER_RESOLUTION_PREF>$RESOLUTION</USER_RESOLUTION_PREF>#" "$p"
            else
                sed -i "s#</CONFIG>#    <USER_RESOLUTION_PREF>$RESOLUTION</USER_RESOLUTION_PREF>\n    </CONFIG>#" "$p"
            fi
        fi
    done
}

# ---------------------------------------------------------------- 1. Zluggish offline toggle
# Two mechanisms, in order of preference:
#   a) LD_PRELOAD DNS shim (root-free): the game's wine process resolves through glibc; the shim
#      rewrites the four zwift.com hostnames to the offline server before DNS is consulted.
#      Lives under $HOME, which the pressure-vessel container shares; LD_PRELOAD is forwarded.
#   b) sudoers-whitelisted /etc/hosts helper (needs the one-time `system-setup` step).
ZLUGGISH_HELPER=/etc/zwift-steamos/zluggish-hosts
ZLUGGISH_DOMAINS="us-or-rly101.zwift.com,secure.zwift.com,cdn.zwift.com,launcher.zwift.com"
DNS_SHIM="$ZWIFT_DATA/bin/zwift-dns-shim.so"
OFFLINE_HOST="${ZWIFT_OFFLINE_HOST:-}"
if [ -z "$OFFLINE_HOST" ] && [ -n "${ZWIFT_OFFLINE_DEFAULT:-}" ]; then
    OFFLINE_HOST="$ZWIFT_OFFLINE_DEFAULT"
fi
if [ -n "$OFFLINE_HOST" ] && [ -f "$DNS_SHIM" ]; then
    export ZWIFT_DNS_SHIM_IP="$OFFLINE_HOST"
    export ZWIFT_DNS_SHIM_HOSTS="$ZLUGGISH_DOMAINS"
    export ZWIFT_DNS_SHIM_LOG="$ZWIFT_DATA/dns-shim.log"
    export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$DNS_SHIM"
    log "Zluggish offline mode (DNS shim): zwift.com traffic -> $OFFLINE_HOST"
elif [ -n "$OFFLINE_HOST" ] && command -v sudo >/dev/null && [ -x "$ZLUGGISH_HELPER" ]; then
    sudo -n "$ZLUGGISH_HELPER" add "$OFFLINE_HOST" >>"$LOG" 2>&1 \
        && log "Zluggish offline mode (hosts helper): zwift.com traffic -> $OFFLINE_HOST" \
        || log "Warning: could not enable Zluggish hosts entries (sudo rule missing?)"
elif [ -z "$OFFLINE_HOST" ] && command -v sudo >/dev/null && [ -x "$ZLUGGISH_HELPER" ]; then
    sudo -n "$ZLUGGISH_HELPER" remove >>"$LOG" 2>&1 || true
elif [ -n "$OFFLINE_HOST" ]; then
    log "Warning: offline mode requested but neither the DNS shim ($DNS_SHIM) nor the hosts helper is available"
fi

# ---------------------------------------------------------------- 2. Bluetooth
ble_release
ble_preflight

# ---------------------------------------------------------------- 3. game update check
if [ -d "$GAME_DIR" ] && [ -f "$ZWIFT_DATA/zwift-fetch-game.py" ]; then
    log "Checking for game updates..."
    ( cd "$ZWIFT_DATA" && timeout 600 python3 zwift-fetch-game.py "$GAME_DIR" --if-outdated >>"$LOG" 2>&1 ) \
        && log "Game is up to date." \
        || log "Update check skipped/failed (offline server or network) - starting installed version."
fi

# 3b. keep the offline server's certificate in the game's own CA bundle (game updates replace it)
if [ -f "$ZWIFT_DATA/zwift-server.pem" ] && [ -f "$GAME_DIR/data/cacert.pem" ]; then
    mark=$(sed -n '2p' "$ZWIFT_DATA/zwift-server.pem")
    if [ -n "$mark" ] && ! grep -qF "$mark" "$GAME_DIR/data/cacert.pem"; then
        cat "$ZWIFT_DATA/zwift-server.pem" >> "$GAME_DIR/data/cacert.pem"
        log "Appended the Zluggish server certificate to the game's data/cacert.pem."
    fi
fi

# ---------------------------------------------------------------- 4. sign-in token
LAUNCHER_VERSION="1.2.0"
if [ -f "$GAME_DIR/ZwiftLauncher_ver_cur.xml" ]; then
    lv="$(grep -oE 'version="[^"]+"' "$GAME_DIR/ZwiftLauncher_ver_cur.xml" 2>/dev/null | head -1 | cut -d'"' -f2)"
    [ -z "$lv" ] || [ "$lv" = 0.0.0 ] || LAUNCHER_VERSION="$lv"
fi

TOKEN_FILE="$PFX/drive_c/zwift-token.json"
if [ -n "$OFFLINE_HOST" ]; then
    # Offline (Zluggish): the auth flow must reach the server by IP (host DNS is not
    # shimmed - the shim only lives inside the wine process) and trust its certificate.
    export ZWIFT_CONNECT_IP="$OFFLINE_HOST"
    export SSL_CERT_FILE="$ZWIFT_DATA/zwift-server.pem"
fi
export ZWIFT_STEAMOS_DATA="$ZWIFT_DATA"
# Interactive sign-in by default: if no token can be refreshed, the chromium launcher
# window opens on the Steam session (persistent profile, so Keycloak's SSO cookie is
# remembered and the next start needs no credentials - like the real launcher).
# ZWIFT_LOGIN_UI=0 restores the old non-interactive gate (exit 102).
if [ "${ZWIFT_LOGIN_UI:-1}" = "0" ]; then
    TOKEN_ARGS="--no-login"
else
    TOKEN_ARGS=""
fi
if ! python3 -u "$ZWIFT_DATA/zwift-auth.py" token "$TOKEN_FILE" $TOKEN_ARGS >>"$LOG" 2>&1; then
    log "ERROR: no Zwift sign-in. Run 'zwift login' once (Desktop Mode), then start Zwift again."
    exit 102
fi
chmod 600 "$TOKEN_FILE" 2>/dev/null || true
TOKEN_WIN='C:\zwift-token.json'
log "Sign-in token ready for launcher version $LAUNCHER_VERSION."

# ---------------------------------------------------------------- 5. prefs
apply_prefs

# ---------------------------------------------------------------- 6. exit watcher
# Release paired sensors ~shortly after ZwiftApp.exe exits (game exit kills the wineserver, so the
# Bluetooth connections would otherwise linger).
(
    # wait for the game to appear (up to 2 min), then wait for it to end
    for _ in $(seq 1 120); do pgrep -f 'ZwiftApp\.exe' >/dev/null && break; sleep 1; done
    while pgrep -f 'ZwiftApp\.exe' >/dev/null; do sleep 5; done
    sleep 3
    ble_release >>"$ZWIFT_DATA/prelaunch.log" 2>&1
) >/dev/null 2>&1 & disown

cd "$GAME_DIR" || exit 103
log "Starting Zwift via Proton..."
exec "$@" "$TOKEN_WIN" "$LAUNCHER_VERSION"
