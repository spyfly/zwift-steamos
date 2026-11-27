#!/usr/bin/env bash
# zwift doctor — environment checks for zwift-steamos (Steam-native install).
set -u

ZWIFT_DATA="${ZWIFT_STEAMOS_DATA:-$HOME/.local/share/zwift-steamos}"
[ -f "$ZWIFT_DATA/zwift.conf" ] && . "$ZWIFT_DATA/zwift.conf"
GAME_DIR="${GAME_DIR:-$ZWIFT_DATA/game}"
COMPAT_TOOL="${COMPAT_TOOL:-}"
STEAM_ROOT="$HOME/.local/share/Steam"
[ -d "$STEAM_ROOT" ] || STEAM_ROOT="$HOME/.steam/root"

G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' O=$'\033[0m'
pass() { printf '  %sOK%s    %s\n' "$G" "$O" "$*"; }
note() { printf '  %sNOTE%s  %s\n' "$Y" "$O" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$R" "$O" "$*"; }

failures=0
chk() { # chk DESC cmd...
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; failures=$((failures+1)); fi
}

echo "zwift-steamos - $( (. /etc/os-release; echo "${PRETTY_NAME:-Linux}") 2>/dev/null), kernel $(uname -r)"

echo "Runtime"
chk "python3" command -v python3
chk "curl" command -v curl
chk "bluetoothctl" command -v bluetoothctl
[ -f "$ZWIFT_DATA/zwift-auth.py" ] && pass "scripts installed ($ZWIFT_DATA)" || fail "scripts missing (re-run install.sh)"
[ -f "$GAME_DIR/ZwiftApp.exe" ] && pass "game installed" || fail "game not installed (run: zwift update)"
[ -x "$GAME_DIR/LinuxZwiftLauncher.exe" ] && pass "launcher helper present" || fail "LinuxZwiftLauncher.exe missing"
[ -f "$ZWIFT_DATA/zwift-auth.py" ] && python3 "$ZWIFT_DATA/zwift-auth.py" status 2>&1 | sed 's/^/          /'

echo "Bluetooth LE"
if [ "${DO_BLE:-1}" != 1 ]; then note "disabled at install (--no-ble)"
else
    if command -v bluetoothctl >/dev/null 2>&1; then
        show="$(timeout 5 bluetoothctl show 2>/dev/null)"
        if [ -z "$show" ]; then
            fail "no Bluetooth adapter found (or bluetooth.service not running)"
        else
            echo "$show" | grep -q 'Powered: yes' \
                && pass "adapter $(echo "$show" | awk '/^Controller/{print $2; exit}') is powered on" \
                || fail "adapter is off: bluetoothctl power on"
            if ! pgrep -f 'ZwiftApp\.exe' >/dev/null; then
                if timeout 10 bluetoothctl --timeout 3 scan on 2>&1 | grep -qE 'InProgress|Failed to start discovery'; then
                    fail "the adapter refuses to scan — the pre-launch wrapper resets it at start, or run: bluetoothctl power off; bluetoothctl power on"
                else
                    pass "Bluetooth scanning works"
                fi
            fi
        fi
        # USB autosuspend on the adapter can drop BLE links (supervision timeout) mid-ride
        bt="$(readlink -f /sys/class/bluetooth/hci0/device/.. 2>/dev/null)"
        if [ -n "$bt" ] && [ -f "$bt/power/control" ]; then
            [ "$(cat "$bt/power/control")" = auto ] \
                && note "USB power saving is ON for the Bluetooth adapter; sensors may drop mid-ride — re-run install.sh" \
                || pass "USB power saving is off for the Bluetooth adapter"
        fi
        if [ -n "${APPID:-}" ]; then
            pfx="$STEAM_ROOT/steamapps/compatdata/$APPID/pfx"
            for mac in $(grep -oiE '_ORG_BLUEZ_HCI[0-9]+&[0-9A-F]{12}' "$pfx/system.reg" 2>/dev/null | grep -oiE '[0-9A-F]{12}$' | tr 'a-f' 'A-F' | sort -u | sed 's/../&:/g; s/:$//'); do
                timeout 5 bluetoothctl info "$mac" 2>/dev/null | grep -q 'Connected: yes' \
                    && note "$mac is still connected with Zwift closed — the pre-launch wrapper releases it at start"
            done
        fi
    else
        fail "bluetoothctl not found - install BlueZ"
    fi
fi

echo "ANT+ USB"
if [ "${DO_ANT:-1}" != 1 ]; then note "disabled at install (--no-ant)"
else
    if [ -n "$COMPAT_TOOL" ] && [ -f "$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL/files/lib/wine/x86_64-unix/libusb0.so" ]; then
        pass "libusb0 bridge installed in the compat tool"
    else
        fail "libusb0 bridge missing from the compat tool - re-run install.sh"
    fi
    stick=""
    for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = 0fcf ] || continue
        stick="$d"; pid="$(cat "$d/idProduct")"
        node="$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")"
        pass "found $(cat "$d/product" 2>/dev/null || echo ANT stick) (0fcf:$pid)"
        case "$pid" in 1008|1009) ;; *) note "0fcf:$pid is not an ANT USB-2/USB-m stick; Zwift may not use it" ;; esac
        [ -w "$node" ] && pass "$node is writable" || fail "$node not writable - re-run install.sh (udev rule) and replug the stick"
    done
    [ -n "$stick" ] || note "no ANT+ USB stick plugged in (Bluetooth trainers connect without one)"
fi

echo "Steam integration"
[ -d "$STEAM_ROOT" ] && pass "Steam client dir" || fail "Steam client dir missing"
if [ -n "$COMPAT_TOOL" ]; then
    chk "compat tool ($COMPAT_TOOL)" test -f "$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL/proton"
fi
if [ -n "${APPID:-}" ] && [ -d "$STEAM_ROOT/steamapps/compatdata/$APPID/pfx/drive_c" ]; then
    pass "wine prefix exists (game has run at least once)"
else
    note "no prefix yet — start Zwift once from the Steam UI"
fi
found=""
for d in "$STEAM_ROOT/userdata"/*/config/shortcuts.vdf; do
    [ -f "$d" ] && grep -qs "Zwift" "$d" && found="$d" && break
done
[ -n "$found" ] && pass "Zwift shortcut present ($found)" || note "no Zwift shortcut yet (re-run install.sh with Steam stopped)"

echo "Last Zwift session"
L="$(find "$STEAM_ROOT/steamapps/compatdata/${APPID:-none}/pfx/drive_c/users" -name Log.txt -path '*Zwift*' 2>/dev/null | xargs -r ls -t | head -1)"
if [ -n "$L" ]; then
    head -2 "$L" | sed 's/^/          /'
    grep -q 'ANT USB receiver found' "$L" && pass "Zwift found the ANT+ stick" || note "Zwift did not report an ANT+ stick"
    grep -q 'Bluetooth Radio is On' "$L" && pass "Zwift found the Bluetooth radio" || note "Zwift did not report a Bluetooth radio"
    grep -E '^\[[0-9:]+\] +(Power|Cadence|HR|Controllable Trainer|Speed|Steering): ' "$L" | sed 's/^\[[0-9:]*\] *//' | sort -u | sed 's/^/          paired  /'
else
    note "no Zwift log yet - start Zwift once from the Steam UI"
fi

echo "Network / offline mode"
[ -f "$ZWIFT_DATA/bin/zwift-dns-shim.so" ] && echo "  DNS shim: $ZWIFT_DATA/bin/zwift-dns-shim.so (root-free offline redirect)"
[ -f "$ZWIFT_DATA/zwift-server.pem" ] && echo "  server cert: $ZWIFT_DATA/zwift-server.pem"
[ -x /etc/zwift-steamos/zluggish-hosts ] && {
    echo "  offline: $(sudo -n /etc/zwift-steamos/zluggish-hosts status 2>/dev/null | head -1)"
}
getent hosts cdn.zwift.com >/dev/null 2>&1 && pass "cdn.zwift.com resolves" || fail "cdn.zwift.com does not resolve"

printf '\n'
if [ "$failures" = 0 ]; then printf '%sAll checks passed.%s\n' "$G" "$O"; else printf '%s%d check(s) failed.%s\n' "$R" "$failures" "$O"; fi
exit "$failures"
