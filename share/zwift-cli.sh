#!/bin/bash
# zwift — command-line control for zwift-steamos. The game itself starts from the Steam UI;
# this covers sign-in, updates, Zluggish offline mode and diagnostics.
# shellcheck shell=bash
#
#   zwift login            sign in once (opens the sign-in page; needed before the first launch)
#   zwift logout           delete the stored sign-in
#   zwift status           who is signed in, which mode is active, is the game installed
#   zwift update           check the game against the server and update it in place
#   zwift launch           start Zwift through Steam (same as clicking it in the library)
#   zwift kill             stop a running game and release its Bluetooth sensors
#   zwift zluggish on <ip> persistently redirect Zwift to a Zluggish server (offline mode)
#   zwift zluggish off     back to Zwift online
#   zwift zluggish status
#   zwift doctor           environment checks
set -u

ZWIFT_DATA="${ZWIFT_STEAMOS_DATA:-$HOME/.local/share/zwift-steamos}"
CONF="$ZWIFT_DATA/zwift.conf"
GAME_DIR="$ZWIFT_DATA/game"
APPID=""            # written by install.sh (online shortcut)
ZLUGGISH_HELPER=/etc/zwift-steamos/zluggish-hosts
[ -f "$CONF" ] && . "$CONF"
GAME_DIR="${GAME_DIR:-$ZWIFT_DATA/game}"

cmd="${1:-}"; shift || true

case "$cmd" in
    login)
        exec python3 "$ZWIFT_DATA/zwift-auth.py" login "$@"
        ;;
    logout)
        exec python3 "$ZWIFT_DATA/zwift-auth.py" logout
        ;;
    status)
        echo "data:        $ZWIFT_DATA"
        echo "game dir:    $GAME_DIR $([ -f "$GAME_DIR/ZwiftApp.exe" ] && echo '(installed)' || echo '(NOT installed)')"
        if [ -n "${APPID:-}" ]; then
            echo "shortcut:    appid $APPID ($( [ -n "${APPID_ZLUGGISH:-}" ] && echo 'online + Zluggish' || echo 'online' ))"
        fi
        [ -x "$ZLUGGISH_HELPER" ] && echo "offline:     $(sudo -n "$ZLUGGISH_HELPER" status 2>/dev/null | head -1)" || true
        python3 "$ZWIFT_DATA/zwift-auth.py" status 2>/dev/null || echo "sign-in:     not signed in (run: zwift login)"
        ;;
    update)
        exec python3 "$ZWIFT_DATA/zwift-fetch-game.py" "$GAME_DIR" "$@"
        ;;
    launch)
        [ -n "${APPID:-}" ] || { echo "no Steam shortcut known - run install.sh first" >&2; exit 1; }
        if command -v steam >/dev/null 2>&1; then
            exec steam steam://rungameid/"$APPID"
        elif command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
            exec flatpak run --command=steam com.valvesoftware.Steam steam://rungameid/"$APPID"
        else
            echo "steam not found" >&2; exit 1
        fi
        ;;
    kill)
        pkill -f 'ZwiftApp\.exe' 2>/dev/null; sleep 1
        pkill -f 'LinuxZwiftLauncher\.exe' 2>/dev/null
        sleep 2
        PFX="${STEAM_COMPAT_DATA_PATH:-$HOME/.local/share/Steam/steamapps/compatdata/${APPID:-0}}/pfx"
        DO_BLE=1 PFX="$PFX" bash -c '
            grep -oiE "_ORG_BLUEZ_HCI[0-9]+&[0-9A-F]{12}" "$PFX/system.reg" 2>/dev/null \
                | grep -oiE "[0-9A-F]{12}$" | tr "a-f" "A-F" | sort -u | sed "s/../&:/g; s/:$//" \
            | while read -r mac; do
                  timeout 5 bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes" \
                      && timeout 5 bluetoothctl disconnect "$mac" >/dev/null 2>&1 && echo "Released $mac"
              done'
        echo "stopped."
        ;;
    zluggish)
        sub="${1:-}"; [ $# -gt 0 ] && shift
        case "$sub" in
            on)
                ip="${1:-}"
                [ -n "$ip" ] || { echo "usage: zwift zluggish on <server-ip>" >&2; exit 1; }
                sudo -n "$ZLUGGISH_HELPER" add "$ip" || exit 1
                echo "Offline mode on: Zwift domains -> $ip (launch options override per launch)"
                ;;
            off)
                sudo -n "$ZLUGGISH_HELPER" remove
                ;;
            status)
                sudo -n "$ZLUGGISH_HELPER" status
                ;;
            *)
                echo "usage: zwift zluggish on <ip>|off|status" >&2; exit 1
                ;;
        esac
        ;;
    doctor)
        exec bash "$ZWIFT_DATA/zwift-doctor.sh" "$@"
        ;;
    -h|--help|help|"" )
        sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "unknown command: $cmd (try: zwift help)" >&2
        exit 1
        ;;
esac
