#!/bin/bash
# install.sh — zwift-steamos: Zwift as a native Steam shortcut. Part of zwift-steamos.
# shellcheck shell=bash
#
# Zwift runs through GE-Proton as a Steam compatibility tool and is started from the Steam UI
# like any other game: no umu-launcher, no Wine prefix in a private directory, no AppArmor
# profile. Steam owns the prefix (compatdata), GE-Proton lives in compatibilitytools.d, and a
# small native pre-launch wrapper does the sign-in token, game updates, Bluetooth preflight and
# the optional Zluggish offline redirect before Steam starts Proton.
#
# Installs (per user):
#   ~/.local/share/zwift-steamos/            scripts, game files, token, logs
#   ~/.local/share/Steam/compatibilitytools.d/GE-Proton<ver>-zwift
#                                            patched GE-Proton (libusb0 bridge for ANT+)
#   ~/.local/bin/zwift                       CLI (login, update, zluggish, doctor, ...)
#   Steam shortcuts "Zwift" / "Zwift (Zluggish)" bound to the compat tool
#
# Root-only bits (sudo, optional): udev rules for ANT+ sticks and Bluetooth USB power saving,
# the Zluggish hosts helper + sudoers rule, and the Zluggish certificate in the trust store.
#
# Usage:
#   ./install.sh [--user NAME] [--data-dir DIR] [--ge-version GE-Proton11-14]
#                [--zluggish-cert FILE] [--zluggish-host IP] [--no-shortcut]
#                [--no-ble] [--no-ant] [--restart-steam] [--check-only]
#
# Run the sign-in once before the first start:   zwift login
# Then start Zwift from the Steam UI.

set -euo pipefail

VERSION="2026.11.27-1"
DEFAULT_GE="GE-Proton11-14"
GE_RELEASE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------- flags
DATA_DIR="" TARGET_USER="" GE_VERSION="$DEFAULT_GE" RESTART_STEAM=0 CHECK_ONLY=0
DO_BLE=1 DO_ANT=1 MAKE_SHORTCUT=1
ZLUGGISH_CERT="" ZLUGGISH_HOST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="${2:?}"; shift 2 ;;
        --data-dir) DATA_DIR="${2:?}"; shift 2 ;;
        --ge-version) GE_VERSION="${2:?}"; shift 2 ;;
        --zluggish-cert) ZLUGGISH_CERT="${2:?}"; shift 2 ;;
        --zluggish-host) ZLUGGISH_HOST="${2:?}"; shift 2 ;;
        --no-shortcut) MAKE_SHORTCUT=0; shift ;;
        --no-ble) DO_BLE=0; shift ;;
        --no-ant) DO_ANT=0; shift ;;
        --restart-steam) RESTART_STEAM=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
    esac
done

say()  { printf '\033[1;32m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------- target user
if [ "$(id -u)" = 0 ]; then
    TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
    [ -n "$TARGET_USER" ] || die "running as root: pass --user NAME (the Steam user, e.g. deck)"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [ -n "$TARGET_HOME" ] || die "no such user: $TARGET_USER"
    SUDO="sudo -u $TARGET_USER"
    AS_ROOT=1
else
    TARGET_USER="$(id -un)"
    TARGET_HOME="$HOME"
    SUDO=""
    AS_ROOT=0
fi
DATA="${DATA_DIR:-$TARGET_HOME/.local/share/zwift-steamos}"
STEAM_ROOT="$TARGET_HOME/.local/share/Steam"
[ -d "$STEAM_ROOT" ] || STEAM_ROOT="$TARGET_HOME/.steam/root"
[ -d "$STEAM_ROOT" ] || die "Steam client directory not found under $TARGET_HOME - start Steam once first"
GAME_DIR="$DATA/game"
BIN_DIR="$DATA/bin"
COMPAT_DIR="$STEAM_ROOT/compatibilitytools.d"
GE_DIR="$COMPAT_DIR/$GE_VERSION-zwift"
GE_ZWIFT="$GE_VERSION-zwift"

say "zwift-steamos $VERSION -> user $TARGET_USER, data $DATA"
if [ -n "${ZWIFT_FLATPAK:-}" ]; then
    say "running inside the zwift-steamos flatpak (system-level bits go to setup-system.sh)"
fi
for t in curl tar sha256sum sha512sum python3; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ -f "$HERE/zwift-start/LinuxZwiftLauncher.exe" ] || die "repo incomplete: zwift-start/LinuxZwiftLauncher.exe missing"
[ -f "$HERE/ant-libusb/build/x86_64-unix/libusb0.so" ] || die "repo incomplete: ant-libusb/build/* missing (see ant-libusb/README.md)"
[ "$CHECK_ONLY" = 1 ] && { say "check-only: preflight OK (GE-Proton $GE_VERSION, data $DATA)"; exit 0; }

# ----------------------------------------------------------------------------- 1/6 files
say "1/6 Installing scripts into $DATA"
mkdir -p "$DATA" "$BIN_DIR" "$GAME_DIR"
install -m 755 "$HERE/share/steam-prelaunch.sh"        "$BIN_DIR/steam-prelaunch"
install -m 755 "$HERE/share/zwift-cli.sh"              "$BIN_DIR/zwift"
install -m 755 "$HERE/share/zwift-doctor.sh"           "$BIN_DIR/zwift-doctor"
install -m 644 "$HERE/share/zwift-auth.py"             "$DATA/zwift-auth.py"
install -m 644 "$HERE/share/zwift-launcher.py"         "$DATA/zwift-launcher.py"
install -m 644 "$HERE/share/zwift-fetch-game.py"       "$DATA/zwift-fetch-game.py"
mkdir -p "$DATA/vdf"
cp -f "$HERE/share/vdf/__init__.py" "$HERE/share/vdf/vdict.py" "$DATA/vdf/"
install -m 644 "$HERE/share/zwift-resolution.sh"       "$DATA/zwift-resolution.sh"
install -m 644 "$HERE/share/zwift-display.sh"          "$DATA/zwift-display.sh"
install -m 755 "$HERE/zwift-start/LinuxZwiftLauncher.exe" "$GAME_DIR/LinuxZwiftLauncher.exe"
mkdir -p "$TARGET_HOME/.local/bin"
if [ -n "${ZWIFT_FLATPAK:-}" ]; then
    warn "flatpak mode: the CLI runs as  flatpak run io.github.spyfly.zwift-steamos  (no ~/.local/bin symlink)"
else
    ln -sfn "$BIN_DIR/zwift" "$TARGET_HOME/.local/bin/zwift"
fi

# A simple icon so the library entry does not look like a broken puzzle piece.
ICON="$DATA/zwift.png"
if [ -f "$HERE/share/app-icon.png" ]; then
    install -m 644 "$HERE/share/app-icon.png" "$DATA/zwift.png"
else
    ZP_OUT="$DATA/zwift.png" python3 - <<'EOF' || true
import struct, zlib, os
W = H = 256
px = bytearray()
for y in range(H):
    for x in range(W):
        r = min(x, y, W-1-x, H-1-y)
        inside = r >= 10
        on_z = (40 < x < 216) and (40 < y < 216) and (
            (y < 78) or (y > 178) or (abs((x - 40) - (y - 40)) < 26 and y < 140) or (abs((x - 216) + (y - 116)) < 26 and y >= 116)
        )
        if not inside: px += bytes((0, 0, 0, 0))
        elif on_z:     px += bytes((255, 255, 255, 255))
        else:          px += bytes((252, 108, 3, 255))
def chunk(tag, data):
    c = tag + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(px)))
       + chunk(b'IEND', b''))
open(os.environ['ZP_OUT'], 'wb').write(png)
EOF
fi

CONF="$DATA/zwift.conf"
cat > "$CONF" <<EOF
# Written by install.sh. Sourced by the pre-launch wrapper and the zwift CLI.
ZWIFT_STEAMOS_DATA="$DATA"
GAME_DIR="$GAME_DIR"
GE_VERSION="$GE_VERSION"
COMPAT_TOOL="$GE_ZWIFT"
DO_BLE=$DO_BLE
RESOLUTION="auto"
EOF

# ----------------------------------------------------------------------------- 2/6 GE-Proton
say "2/6 Installing GE-Proton compatibility tool ($GE_ZWIFT)"
mkdir -p "$COMPAT_DIR"
if [ ! -f "$GE_DIR/files/lib/wine/x86_64-unix/wine/boot" ] && [ ! -f "$GE_DIR/proton" ]; then
    # extract under $DATA (disk-backed): sandbox /tmp is a small tmpfs, too small for GE
    tmp="$(mktemp -d "$DATA/tmp-ge.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    say "   downloading $GE_VERSION (~560 MB) ..."
    curl -fL --retry 3 -o "$tmp/$GE_VERSION-x86_64.tar.gz" "$GE_RELEASE_URL/$GE_VERSION/$GE_VERSION-x86_64.tar.gz" \
        || die "GE-Proton download failed"
    curl -fsSL --retry 3 -o "$tmp/ge.sha512sum" "$GE_RELEASE_URL/$GE_VERSION/$GE_VERSION-x86_64.sha512sum" \
        || warn "could not download checksum file - skipping verification"
    if [ -s "$tmp/ge.sha512sum" ]; then
        (cd "$tmp" && sha512sum -c --quiet ge.sha512sum) || die "GE-Proton download failed its checksum"
        say "   checksum OK"
    fi
    tar -xzf "$tmp/$GE_VERSION-x86_64.tar.gz" -C "$tmp"
    src="$tmp/$GE_VERSION"
    [ -d "$src" ] || src="$tmp/$GE_VERSION-x86_64"   # newer GE tarballs carry the -x86_64 suffix
    [ -d "$src" ] || die "unexpected tarball layout"
    rm -rf "$GE_DIR"
    mv "$src" "$GE_DIR"
    # Give the tool its own name so this patched copy is listed and used only for Zwift.
    sed -i "s/$GE_VERSION/$GE_ZWIFT/g" "$GE_DIR/compatibilitytool.vdf"
    say "   extracted to $GE_DIR"
else
    say "   already present: $GE_DIR"
fi

# ANT+ support: Zwift talks to ANT+ sticks through libusb0.dll; the bridge maps that to Linux usbfs.
say "   installing ANT+ libusb0 bridge into the compat tool"
(cd "$HERE/ant-libusb" && sha256sum -c --quiet SHA256SUMS) \
    || die "ant-libusb binaries don't match ant-libusb/SHA256SUMS"
install -m 644 "$HERE/ant-libusb/build/x86_64-windows/libusb0.dll" "$GE_DIR/files/lib/wine/x86_64-windows/libusb0.dll"
install -m 755 "$HERE/ant-libusb/build/x86_64-unix/libusb0.so"     "$GE_DIR/files/lib/wine/x86_64-unix/libusb0.so"

# Heart-rate notify retry: built against GE-Proton 11-8, applied only when the winebth build matches.
WINEBTH="$GE_DIR/files/lib/wine/x86_64-unix/winebth.so"
if [ "$DO_BLE" = 1 ] && [ -f "$HERE/wine-patches/winebth.so" ] && [ -f "$WINEBTH" ]; then
    (cd "$HERE/wine-patches" && sha256sum -c --quiet SHA256SUMS) || die "wine-patches/winebth.so doesn't match wine-patches/SHA256SUMS"
    have="$(sha256sum "$WINEBTH" | cut -d' ' -f1)"
    WINEBTH_11_8_SHA="54e85a75a9ed092a548a97204dc2f0a99bb5c7a48ce5a3f9b503887b84c4a3f2"
    if [ "$have" = "$WINEBTH_11_8_SHA" ]; then
        cp -n "$WINEBTH" "$WINEBTH.orig"
        install -m 755 "$HERE/wine-patches/winebth.so" "$WINEBTH"
        say "   winebth heart-rate retry patch applied"
    else
        warn "winebth.so is not the GE-Proton 11-8 build (GE $GE_VERSION) - skipping the HR-retry patch; BLE still works via built-in fixes"
    fi
fi

# ----------------------------------------------------------------------------- 3/6 system bits
say "3/6 System setup"
UDEV_RULE='SUBSYSTEM=="usb", ATTRS{idVendor}=="0fcf", ATTRS{idProduct}=="1008|1009", MODE="0666", TAG+="uaccess"'
if [ "$DO_ANT" = 1 ] && [ "$AS_ROOT" = 1 ]; then
    echo "$UDEV_RULE" > /etc/udev/rules.d/51-zwift-ant-usb.rules
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0fcf || true
    say "   ANT+ udev rule installed"
elif [ "$DO_ANT" = 1 ]; then
    warn "not root: create /etc/udev/rules.d/51-zwift-ant-usb.rules manually if you use an ANT+ stick:"
    warn "  $UDEV_RULE"
fi
BT_RULE='ACTION=="bind", SUBSYSTEM=="usb", DRIVER=="btusb", RUN+="/bin/sh -c '"'"'echo on > /sys%p/../power/control'"'"'"'
if [ "$DO_BLE" = 1 ] && [ "$AS_ROOT" = 1 ]; then
    echo "$BT_RULE" > /etc/udev/rules.d/52-zwift-bluetooth-awake.rules
    for d in /sys/class/bluetooth/hci*/device/..; do
        [ -f "$d/power/control" ] && echo on > "$d/power/control" || true
    done
    say "   Bluetooth USB power saving disabled"
fi

# ----------------------------------------------------------------------------- Zluggish offline support
# Preferred mechanism: LD_PRELOAD DNS shim. It rewrites the four zwift.com hostnames to the offline
# server inside the game's wine process, before DNS is consulted — no host file is touched, and the
# app keeps its hostname string (TLS SNI / HTTP Host header intact, so the server's cert is valid).
# The server certificate is appended to the game's own data/cacert.pem (Zwift uses libcurl with its
# bundled store), so no system trust store change is needed either.
# Fallback: a sudoers-whitelisted /etc/hosts helper (setup-system.sh), for setups where the shim
# does not intercept (older runtimes, non-glibc resolvers).
ZLUGGISH_DIR=/etc/zwift-steamos
append_server_cert() {
    local cacert="$GAME_DIR/data/cacert.pem"
    local mark
    [ -f "$DATA/zwift-server.pem" ] || return 0
    if [ ! -f "$cacert" ]; then
        warn "game's data/cacert.pem not found - the certificate will be appended on first launch"
        return 0
    fi
    mark=$(sed -n '2p' "$DATA/zwift-server.pem")
    if [ -n "$mark" ] && ! grep -qF "$mark" "$cacert"; then
        cat "$DATA/zwift-server.pem" >> "$cacert"
        say "   server certificate appended to the game's data/cacert.pem"
    fi
}
if [ -n "$ZLUGGISH_CERT" ] || [ -n "$ZLUGGISH_HOST" ]; then
    say "   preparing Zluggish offline support (DNS shim - no host changes needed)"
    if [ -f "$HERE/share/zwift-dns-shim.so" ]; then
        install -m 755 "$HERE/share/zwift-dns-shim.so" "$BIN_DIR/zwift-dns-shim.so"
    elif command -v cc >/dev/null 2>&1 && \
        cc -shared -fPIC -O2 -Wall -o "$BIN_DIR/zwift-dns-shim.so" "$HERE/share/zwift-dns-shim.c" -ldl 2>/dev/null; then
        say "   DNS shim compiled for this system"
    else
        warn "no prebuilt shim and no compiler: offline mode will use the hosts helper (needs setup-system.sh)"
    fi
    if [ -n "$ZLUGGISH_CERT" ]; then
        # skip when the cert already lives in DATA (same file -> install/cp refuse)
        if [ "$(realpath -- "$ZLUGGISH_CERT")" != "$(realpath -- "$DATA/zwift-server.pem" 2>/dev/null || echo /nonexistent)" ]; then
            install -m 644 "$ZLUGGISH_CERT" "$DATA/zwift-server.pem"
        fi
        append_server_cert
    else
        warn "no --zluggish-cert given: traffic redirect works, but HTTPS to the server will fail without its certificate"
    fi
    if [ -n "$ZLUGGISH_HOST" ]; then
        grep -q "ZWIFT_OFFLINE_DEFAULT=" "$CONF" || echo "ZWIFT_OFFLINE_DEFAULT=\"$ZLUGGISH_HOST\"" >> "$CONF"
    fi
    # Fallback helper: root installs it system-wide; flatpak stages it for setup-system.sh.
    if [ "$AS_ROOT" = 1 ]; then
        install -d -m 755 "$ZLUGGISH_DIR"
        install -m 755 "$HERE/share/zluggish-hosts.sh" "$ZLUGGISH_DIR/zluggish-hosts"
        if [ -n "$ZLUGGISH_CERT" ]; then
            install -m 644 "$ZLUGGISH_CERT" "$ZLUGGISH_DIR/zwift-server.pem"
            "$ZLUGGISH_DIR/zluggish-hosts" trust "$ZLUGGISH_DIR/zwift-server.pem" 2>/dev/null || true
        fi
        cat > /etc/sudoers.d/zwift-steamos-zluggish <<EOF
# zwift-steamos: allow the pre-launch wrapper to toggle Zluggish hosts entries (fallback)
$TARGET_USER ALL=(root) NOPASSWD: $ZLUGGISH_DIR/zluggish-hosts add *, $ZLUGGISH_DIR/zluggish-hosts remove, $ZLUGGISH_DIR/zluggish-hosts status
EOF
        chmod 0440 /etc/sudoers.d/zwift-steamos-zluggish
        "$HERE/share/system-setup.sh" whitelist
    elif [ ! -f "$BIN_DIR/zwift-dns-shim.so" ]; then
        install -m 755 "$HERE/share/zluggish-hosts.sh" "$BIN_DIR/zluggish-hosts"
    fi
fi
# Flatpak mode: emit the one-shot sudo script for the root-level bits that cannot be avoided —
# the ANT+ udev rules always; hosts-helper fallback + system trust anchor when Zluggish is set up.
if [ -n "${ZWIFT_FLATPAK:-}" ]; then
    ZLUGGISH_HOST="${ZLUGGISH_HOST:-}" \
    ZLUGGISH_CERT_PATH="$([ -f "$DATA/zwift-server.pem" ] && echo "$DATA/zwift-server.pem" || true)" \
    ZWIFT_TARGET_USER="$TARGET_USER" \
    PAYLOAD_HELPER="$([ -f "$BIN_DIR/zluggish-hosts" ] && echo "$BIN_DIR/zluggish-hosts" || true)" \
        bash "$HERE/share/system-setup.sh" generate "$DATA/bin/setup-system.sh" \
        || warn "could not generate setup-system.sh"
    say "   one-time root step (ANT+ udev rules):  sudo bash $DATA/bin/setup-system.sh"
fi

# ----------------------------------------------------------------------------- 4/6 Steam integration
say "4/6 Registering Steam shortcuts"
if [ "$MAKE_SHORTCUT" = 1 ]; then
    if [ -z "${ZWIFT_FLATPAK:-}" ] && pgrep -u "$TARGET_USER" -x steam >/dev/null 2>&1; then
        warn "Steam is running - it must be restarted to pick up the shortcut (use --restart-steam)"
    fi
    # ONE library entry; the launch options carry the offline mode (switch via zluggish subcommand)
    LAUNCH="ZWIFT_STEAMOS_DATA=$DATA $BIN_DIR/steam-prelaunch %command%"
    DESC="Zwift cycling app (zwift-steamos)"
    if [ -n "$ZLUGGISH_HOST" ]; then
        LAUNCH="ZWIFT_STEAMOS_DATA=$DATA ZWIFT_OFFLINE_HOST=$ZLUGGISH_HOST $BIN_DIR/steam-prelaunch %command%"
        DESC="Zwift via Zluggish offline server ($ZLUGGISH_HOST)"
    fi
    $SUDO python3 "$HERE/share/steam-integration.py" \
        --exe "$GAME_DIR/LinuxZwiftLauncher.exe" --app-name "Zwift" \
        --startdir "$GAME_DIR" --icon "$ICON" \
        --compat-tool "$GE_ZWIFT" --launch-options "$LAUNCH" --description "$DESC"
    # clean up a stale "Zwift (Zluggish)" entry from older installs
    $SUDO python3 "$HERE/share/steam-integration.py" \
        --exe "$GAME_DIR/LinuxZwiftLauncher.exe" --app-name "Zwift (Zluggish)" --remove >/dev/null 2>&1 || true
else
    warn "--no-shortcut: add the game manually in Steam (Exe: $GAME_DIR/LinuxZwiftLauncher.exe, StartDir: $GAME_DIR)"
fi
APPID_ONLINE="$($SUDO python3 -c "import binascii,sys; exe=sys.argv[1]; print((binascii.crc32(exe.encode()+'Zwift'.encode()) & 0xFFFFFFFF) | 0x80000000)" "$GAME_DIR/LinuxZwiftLauncher.exe")"
grep -q '^APPID=' "$CONF" || echo "APPID=\"$APPID_ONLINE\"" >> "$CONF"

# ----------------------------------------------------------------------------- 5/6 game files
say "5/6 Downloading/verifying the game files (~5 GB) into $GAME_DIR"
( cd "$DATA" && $SUDO python3 zwift-fetch-game.py "$GAME_DIR" ) || die "game download failed - run it again: zwift update"
# launcher version file (LAUNCHER_VERSION fallback in the pre-launch wrapper)
curl -fsSL -o "$GAME_DIR/ZwiftLauncher_ver_cur.xml" "https://cdn.zwift.com/gameassets/Zwift_Updates_Root/ZwiftLauncher_ver_cur.xml" 2>/dev/null \
    || warn "could not fetch ZwiftLauncher_ver_cur.xml (using built-in launcher version)"

# ----------------------------------------------------------------------------- 6/6 ownership + restart
if [ "$AS_ROOT" = 1 ]; then
    say "6/6 Fixing ownership for $TARGET_USER"
    chown -R "$TARGET_USER:$TARGET_USER" "$DATA" "$COMPAT_DIR/$GE_ZWIFT" "$TARGET_HOME/.local/bin/zwift" 2>/dev/null || true
fi
if [ "$RESTART_STEAM" = 1 ]; then
    if [ -n "${ZWIFT_FLATPAK:-}" ]; then
        warn "flatpak mode: restart Steam manually (or just reopen the library) to pick up the shortcut"
    else
        say "Restarting Steam to pick up the shortcut"
        if [ "$AS_ROOT" = 1 ]; then
            pkill -TERM -u "$TARGET_USER" -x steam 2>/dev/null || true
        else
            steam -shutdown 2>/dev/null || pkill -TERM -x steam 2>/dev/null || true
        fi
        say "Steam is restarting (on SteamOS the session brings it back automatically)"
    fi
fi

say "Done."
say "  1. Sign in once:        zwift login        (as $TARGET_USER, Desktop Mode recommended)"
say "  2. Start Zwift:         Steam library -> Zwift"
say "  Offline mode:           zwift zluggish --host <ip> --cert <pem>  (zluggish off switches back)"
say "  Status / diagnostics:   zwift status | zwift doctor"
