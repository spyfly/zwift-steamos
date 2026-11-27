#!/bin/bash
# zwift-steamos flatpak command — installer / updater / control plane.
#
# The runtime itself is native: the Steam shortcut, GE-Proton compat tool, wine prefix and the
# game all live in the host's Steam directories (the flatpak has filesystem grants for
# ~/.local/share/zwift-steamos and ~/.local/share/Steam). Wine is NOT run inside this sandbox,
# so there is no umu-launcher and no nested Steam runtime. Only the few root-level bits
# (udev rules, sudoers rule, trust anchor) are applied outside, via setup-system.sh.
# shellcheck shell=bash
set -u
APP_ID=io.github.spyfly.zwift-steamos
DATA="${ZWIFT_STEAMOS_DATA:-$HOME/.local/share/zwift-steamos}"
PAYLOAD=/app/share/zwift-steamos

help() {
    cat <<EOF
zwift-steamos (flatpak) — Zwift from the Steam UI on SteamOS

  install   install Zwift into the host Steam client (shortcuts, GE-Proton compat tool,
            game download; same options as install.sh, e.g. --zluggish-host 192.168.30.240
            --zluggish-cert server.pem)
  login     sign in to Zwift (opens the sign-in page / asks for the redirect URL)
  status    show the sign-in state
  update    update the game files from Zwift's server
  doctor    environment checks
  system-setup  print the one-time sudo command for the root-level bits (udev, sudoers, trust)

The game itself starts from the Steam UI (library entry "Zwift" / "Zwift (Zluggish)").
EOF
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
    install)
        ZWIFT_FLATPAK=1 bash "$PAYLOAD/install.sh" "$@" ;;
    login|logout|status)
        [ -f "$DATA/zwift-auth.py" ] || { echo "not installed yet - run: flatpak run $APP_ID install"; exit 1; }
        exec python3 "$DATA/zwift-auth.py" "$cmd" "$@" ;;
    update)
        [ -f "$DATA/zwift-fetch-game.py" ] || { echo "not installed yet - run: flatpak run $APP_ID install"; exit 1; }
        exec python3 "$DATA/zwift-fetch-game.py" "$DATA/game" "$@" ;;
    doctor)
        [ -x "$DATA/bin/zwift-doctor" ] || { echo "not installed yet - run: flatpak run $APP_ID install"; exit 1; }
        exec bash "$DATA/bin/zwift-doctor" ;;
    system-setup)
        if [ -f "$DATA/bin/setup-system.sh" ]; then
            echo "One-time root-level setup (udev rules, sudoers, trust anchor, SteamOS /etc persistence):"
            echo "    sudo bash $DATA/bin/setup-system.sh"
        else
            echo "Run install first (with --zluggish-* options if you want offline mode);"
            echo "without Zluggish there is no root-level step."
        fi ;;
    uninstall)
        bash "$PAYLOAD/uninstall.sh" "$@" ;;
    help|-h|--help) help ;;
    *)
        echo "unknown command: $cmd" >&2; help; exit 1 ;;
esac
