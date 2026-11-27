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
  zluggish  configure the offline server without reinstall:
              zluggish --host 192.168.30.240 --cert <pem>   (cert under $DATA)
              zluggish off
  system-setup  print the one-time sudo command for the root-level bits (udev, sudoers, trust)

The game itself starts from the Steam UI (library entry "Zwift" / "Zwift (Zluggish)").
EOF
}

cmd="${1:-}"
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
    zluggish)
        # Configure the offline (Zluggish) server without reinstalling.
        #   zluggish --host 192.168.30.240 --cert <pem>   enable: cert into the game's CA bundle,
        #                                                 ZWIFT_OFFLINE_DEFAULT into the conf,
        #                                                 the "Zwift" shortcut switches to offline
        #   zluggish off                                  disable offline (shortcut back to online)
        # NOTE: inside the flatpak sandbox only $DATA is writable-shared - pass the cert path
        # under ~/.local/share/zwift-steamos/ (e.g. copy it there first).
        [ -f "$DATA/zwift.conf" ] || { echo "not installed yet - run: flatpak run $APP_ID install"; exit 1; }
        host=""; cert=""; off=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --host) host="$2"; shift 2 ;;
                --cert) cert="$2"; shift 2 ;;
                off) off=1; shift ;;
                *) echo "unknown option: $1 (use --host <ip> --cert <pem> | off)"; exit 1 ;;
            esac
        done
        # shellcheck disable=SC1091
        . "$DATA/zwift.conf"   # GAME_DIR, COMPAT_TOOL, ZWIFT_STEAMOS_DATA
        icon="$DATA/zwift.png"
        if [ "$off" = 1 ]; then
            sed -i '/ZWIFT_OFFLINE_DEFAULT=/d' "$DATA/zwift.conf"
            python3 "$PAYLOAD/share/steam-integration.py" \
                --exe "$GAME_DIR/LinuxZwiftLauncher.exe" --app-name "Zwift" \
                --startdir "$GAME_DIR" --icon "$icon" \
                --compat-tool "${COMPAT_TOOL:-}" \
                --launch-options "ZWIFT_STEAMOS_DATA=$DATA $DATA/bin/steam-prelaunch %command%" \
                --description "Zwift cycling app (zwift-steamos)" \
                && echo "offline mode off ('Zwift' shortcut back to online - restart Steam to pick it up)"
            exit 0
        fi
        [ -n "$host" ] || { echo "usage: flatpak run $APP_ID zluggish --host <ip> --cert <pem>"; exit 1; }
        if [ -n "$cert" ] && [ -f "$cert" ]; then
            install -m 644 "$cert" "$DATA/zwift-server.pem"
            cacert="$GAME_DIR/data/cacert.pem"
            if [ -f "$cacert" ]; then
                mark=$(sed -n '2p' "$DATA/zwift-server.pem")
                grep -qF "$mark" "$cacert" || { cat "$DATA/zwift-server.pem" >> "$cacert"; echo "server certificate appended to $cacert"; }
            else
                echo "game not downloaded yet - the certificate is appended on first launch"
            fi
        elif [ -n "$cert" ]; then
            echo "certificate file not found: $cert (inside the sandbox only $DATA is visible)"; exit 1
        fi
        sed -i '/ZWIFT_OFFLINE_DEFAULT=/d' "$DATA/zwift.conf"
        echo "ZWIFT_OFFLINE_DEFAULT=\"$host\"" >> "$DATA/zwift.conf"
        LAUNCH="ZWIFT_STEAMOS_DATA=$DATA ZWIFT_OFFLINE_HOST=$host $DATA/bin/steam-prelaunch %command%"
        python3 "$PAYLOAD/share/steam-integration.py" \
            --exe "$GAME_DIR/LinuxZwiftLauncher.exe" --app-name "Zwift" \
            --startdir "$GAME_DIR" --icon "$icon" \
            --compat-tool "${COMPAT_TOOL:-}" --launch-options "$LAUNCH" \
            --description "Zwift via Zluggish offline server ($host)" \
            && echo "offline server configured: $host (the 'Zwift' shortcut now starts offline - restart Steam to pick it up; zluggish off switches back)" ;;
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
    setup|run|"")
        # no subcommand = auto-install on first use: clicking the app icon right after
        # `flatpak install <bundle>` runs the full setup; afterwards it just reports status.
        if [ -f "$DATA/zwift.conf" ]; then
            if [ "$cmd" = "" ]; then
                echo "zwift-steamos is installed - launch the game from the Steam UI:"
                echo "  library entry \"Zwift\" (or \"Zwift (Zluggish)\" for offline mode)"
                echo "subcommands: install login status update doctor zluggish system-setup uninstall help"
            else
                echo "usage: flatpak run $APP_ID <command>"; echo; help; exit 1
            fi
        else
            echo "First run - installing Zwift into the host Steam client..."
            echo "(GE-Proton + game download, ~6 GB total; progress below)"
            ZWIFT_FLATPAK=1 bash "$PAYLOAD/install.sh" "$@"
        fi ;;
    *)
        echo "unknown command: $cmd" >&2; help; exit 1 ;;
esac
