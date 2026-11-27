#!/usr/bin/env bash
# packaging/build-bundle.sh — build the zwift-steamos single-file flatpak bundle.
#
# Pure scripts + data, so no flatpak-builder and no runtime download at build time: assemble the
# app tree (files + metadata), import it with flatpak build-export and pack a bundle with
# flatpak build-bundle. The bundle declares the freedesktop 24.08 runtime, which is pulled
# automatically at install time on the target machine.
#
#   ./packaging/build-bundle.sh [version]     -> dist/zwift-steamos-<version>.flatpak
#   flatpak install --user ./zwift-steamos-<version>.flatpak
#   flatpak run io.github.spyfly.zwift-steamos install
set -euo pipefail
cd "$(dirname "$0")/.."

APP_ID=io.github.spyfly.zwift-steamos
RUNTIME=org.freedesktop.Platform
SDK=org.freedesktop.Sdk
ARCH=x86_64
RUNTIME_VERSION=24.08
VERSION="${1:-1.0.0}"
STAGE="$(mktemp -d)"
REPO_DIR="$(mktemp -d)"
OUT_DIR=dist
trap 'rm -rf "$STAGE" "$REPO_DIR"' EXIT

command -v flatpak >/dev/null || { echo "flatpak not found" >&2; exit 1; }
[ -f share/app-icon.png ] || { echo "share/app-icon.png missing" >&2; exit 1; }

# --- app file tree -----------------------------------------------------------
if [ ! -f share/zwift-dns-shim.so ]; then
    command -v cc >/dev/null 2>&1 || { echo "no cc and no prebuilt share/zwift-dns-shim.so" >&2; exit 1; }
    cc -shared -fPIC -O2 -Wall -o share/zwift-dns-shim.so share/zwift-dns-shim.c -ldl \
        || { echo "failed to compile the DNS shim" >&2; exit 1; }
fi
mkdir -p "$STAGE/files/bin" "$STAGE/files/share/zwift-steamos"
cp -r share zwift-start ant-libusb wine-patches install.sh uninstall.sh "$STAGE/files/share/zwift-steamos/"
install -m 755 packaging/zwift-steamos.sh "$STAGE/files/bin/zwift-steamos"
install -Dm644 packaging/io.github.spyfly.zwift-steamos.metainfo.xml \
    "$STAGE/files/share/metainfo/io.github.spyfly.zwift-steamos.metainfo.xml"
install -Dm644 packaging/io.github.spyfly.zwift-steamos.desktop \
    "$STAGE/files/share/applications/io.github.spyfly.zwift-steamos.desktop"
install -Dm644 share/icons/hicolor/256x256/apps/io.github.spyfly.zwift-steamos.png \
    "$STAGE/files/share/icons/hicolor/256x256/apps/io.github.spyfly.zwift-steamos.png"

cat > "$STAGE/metadata" <<EOF
[Application]
name=$APP_ID
runtime=$RUNTIME/$ARCH/$RUNTIME_VERSION
sdk=$SDK/$ARCH/$RUNTIME_VERSION
command=zwift-steamos

[Context]
shared=network;
filesystems=xdg-data/zwift-steamos:create;xdg-data/Steam:create;
devices=;
sockets=;
EOF

# --- export + bundle ----------------------------------------------------------
mkdir -p "$OUT_DIR"
flatpak build-export --arch="$ARCH" --disable-sandbox "$REPO_DIR" "$STAGE" "$VERSION" >/dev/null
flatpak build-bundle "$REPO_DIR" "$OUT_DIR/zwift-steamos-$VERSION.flatpak" "$APP_ID" "$VERSION"

echo "wrote $OUT_DIR/zwift-steamos-$VERSION.flatpak ($(du -h "$OUT_DIR/zwift-steamos-$VERSION.flatpak" | cut -f1))"
echo "install on the target machine:"
echo "  flatpak install --user ./$OUT_DIR/zwift-steamos-$VERSION.flatpak"
