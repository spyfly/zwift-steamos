#!/usr/bin/env bash
# zwift-steamos — uninstaller
#   ./uninstall.sh            sign out of Zwift, remove the Steam shortcuts, compat tool, CLI, udev rules
#                             and the Zluggish helper
#   ./uninstall.sh --purge    also delete the wine prefix and the game files (rides/profile live in the
#                             Zwift account and are not affected)
#   ./uninstall.sh --purge --yes   do not ask
set -u
DATA="${ZWIFT_STEAMOS_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/zwift-steamos}"
PURGE=0 ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --purge) PURGE=1 ;;
        --yes) ASSUME_YES=1 ;;
        *) echo "usage: $0 [--purge] [--yes]" >&2; exit 1 ;;
    esac
done
GE=""; COMPAT_TOOL=""; APPID=""
# shellcheck source=/dev/null
[ -f "$DATA/zwift.conf" ] && . "$DATA/zwift.conf"
STEAM_ROOT="$HOME/.local/share/Steam"
[ -d "$STEAM_ROOT" ] || STEAM_ROOT="$HOME/.steam/root"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if pgrep -f 'Zwift(App|Launcher)\.exe' >/dev/null 2>&1; then
    echo "Zwift is running - run: zwift kill"
    exit 1
fi

echo "Removing Steam shortcut + compat-tool mapping"
if [ -f "$HERE/share/steam-integration.py" ]; then
    python3 "$HERE/share/steam-integration.py" \
        --exe "$DATA/game/LinuxZwiftLauncher.exe" --app-name "Zwift" --remove 2>/dev/null || true
    python3 "$HERE/share/steam-integration.py" \
        --exe "$DATA/game/LinuxZwiftLauncher.exe" --app-name "Zwift (Zluggish)" --remove 2>/dev/null || true
fi

[ -L "$HOME/.local/bin/zwift" ] && grep -qs 'zwift-steamos' "$(readlink -f "$HOME/.local/bin/zwift")" 2>/dev/null && {
    rm -f "$HOME/.local/bin/zwift"; echo "removed ~/.local/bin/zwift"
}

[ -f "$DATA/zwift-auth.py" ] && python3 "$DATA/zwift-auth.py" logout >/dev/null 2>&1
if [ -d "$DATA" ]; then
    [ "$PURGE" = 1 ] || echo "removing $DATA (scripts, logs; game files stay with --purge)" 
    if [ "$PURGE" = 0 ]; then
        # keep game files for a reinstall unless purging
        find "$DATA" -maxdepth 1 -mindepth 1 ! -name game -exec rm -rf {} +
    else
        rm -rf "$DATA"
    fi
    echo "removed $DATA"
fi

if [ -n "${COMPAT_TOOL:-}" ] && [ -d "$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL" ]; then
    rm -rf "$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL" && echo "removed compat tool $COMPAT_TOOL"
fi

if [ -n "${APPID:-}" ] && [ -d "$STEAM_ROOT/steamapps/compatdata/$APPID" ]; then
    if [ "$PURGE" = 1 ]; then
        if [ "$ASSUME_YES" = 1 ]; then a=y; else read -r -p "Delete the wine prefix + shader cache ($STEAM_ROOT/steamapps/compatdata/$APPID)? [y/N] " a </dev/tty || a=n; fi
        case "$a" in y|Y|yes) rm -rf "$STEAM_ROOT/steamapps/compatdata/$APPID" && echo "removed compatdata/$APPID" ;; *) echo "kept compatdata/$APPID" ;; esac
    else
        echo "kept compatdata/$APPID (use --purge to delete)"
    fi
fi

for f in /etc/udev/rules.d/51-zwift-ant-usb.rules /etc/udev/rules.d/52-zwift-bluetooth-awake.rules; do
    if [ -f "$f" ] && [ "$(id -u)" = 0 ]; then
        rm -f "$f"; udevadm control --reload-rules 2>/dev/null; echo "removed $f"
    elif [ -f "$f" ]; then
        echo "sudo rm $f   # re-run as root to remove this"
    fi
done

if [ -d /etc/zwift-steamos ]; then
    if [ "$(id -u)" = 0 ]; then
        rm -rf /etc/zwift-steamos /etc/sudoers.d/zwift-steamos-zluggish
        rm -f /etc/ca-certificates/trust-source/anchors/zwift-steamos-zluggish.crt
        rm -f /etc/atomic-update.conf.d/zwift-steamos.conf
        command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract
        echo "removed Zluggish helper, sudoers rule and trust anchor"
    else
        echo "sudo rm -rf /etc/zwift-steamos /etc/sudoers.d/zwift-steamos-zluggish /etc/ca-certificates/trust-source/anchors/zwift-steamos-zluggish.crt /etc/atomic-update.conf.d/zwift-steamos.conf"
    fi
fi

# /etc/hosts managed block (Zluggish offline)
if [ "$(id -u)" = 0 ]; then
    awk -v b="# BEGIN zwift-steamos zluggish (managed)" -v e="# END zwift-steamos zluggish (managed)" \
        'index($0, b) == 1 { skip = 1; next } index($0, e) == 1 { skip = 0; next } !skip' /etc/hosts > /etc/hosts.tmp \
        && mv /etc/hosts.tmp /etc/hosts
fi

echo "Done. Steam needs a restart to drop the shortcut from the library."
