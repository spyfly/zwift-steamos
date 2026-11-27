# Changelog

## 27 November 2026 — zwift-steamos 1.0.0 (SteamOS-native fork)

- **One Steam library shortcut only** ("Zwift"); Zluggish offline mode switches its launch options
  (`zluggish --host <ip> --cert <pem>` → offline, `zluggish off` → online). Stale "Zwift (Zluggish)"
  entries from earlier installs are removed automatically.
- **Prelaunch skips the sign-in token check in offline mode** — the offline server handles auth,
  and the Python TLS check cannot trust its self-signed certificate.
- **Steam-native runtime, no umu-launcher.** GE-Proton (default: 11-14) installs into Steam's
  `compatibilitytools.d` as `GE-Proton<ver>-zwift` and is bound to the shortcut through Steam's
  `CompatToolMapping`; Steam owns the wine prefix (`compatdata/<appid>/pfx`). `steam-prelaunch`
  runs in the launch options before `%command%` (offline toggle, BLE preflight, update check,
  token refresh, prefs) and hands over to Proton — the game starts from the Steam UI.
- **Flatpak packaging** (`packaging/`): `io.github.spyfly.zwift-steamos` as a single-file bundle.
  The flatpak is the installer/control plane (install, update, login, doctor, uninstall); Wine and
  the game run natively under Steam, not in the sandbox. Grants: `xdg-data/zwift-steamos` and
  `xdg-data/Steam` (create) + network. Flatpak apps cannot escalate to root, so the few root-level
  bits are one optional `sudo bash ~/.local/share/zwift-steamos/bin/setup-system.sh` (udev rules,
  sudoers, trust anchor).
- **Zluggish offline mode built in, root-free:** launch env `ZWIFT_OFFLINE_HOST=<ip>` (per launch
  or via the separate "Zwift (Zluggish)" library entry) redirects the four client domains through
  an `LD_PRELOAD` getaddrinfo shim that runs inside the game's wine process — no `/etc/hosts`, no
  sudoers rule, no system trust store. The server certificate is appended to the game's own
  `data/cacert.pem` (libcurl uses the bundled store) and re-appended after game updates. A
  sudoers-whitelisted hosts helper (`setup-system.sh`) remains as fallback; in flatpak installs it
  is also the one-time sudo step for the ANT+ udev rules.
- **SteamOS persistence:** `setup-system.sh` whitelists its files in `/etc/atomic-update.conf.d`
  so they survive SteamOS updates (3.6+ keeps only whitelisted `/etc` changes).
- Everything else carries over from upstream zwift-linux (BLE fixes, ANT+ bridge, launcher-free
  sign-in).

## 10 November 2026

- **Bluetooth heart-rate sensors that connect but show "no signal" are fixed.** With a Garmin
  fenix 7, Zwift logged `[BLEWinLib] Set notify failed` and never received a pulse. Wine's
  request to BlueZ to switch on heart-rate notifications (`StartNotify`) failed with
  `ATT error: 0x0e` around connection setup, and Zwift doesn't repeat it. On the same
  connection the watch sent heart rate normally (120 readings a minute) as soon as the request
  was made again, so the sensor, BlueZ and the kernel were fine.
  - `zwift` now starts `tools/ble-hr-hold.py`, which holds its own heart-rate subscription for
    any connected heart-rate sensor while Zwift runs (`ble-hr-hold.log` in the data folder).
  - `wine-patches/` adds a retry for `StartNotify` to Wine's Bluetooth driver (up to 6 tries,
    400 ms apart). `install.sh` installs the prebuilt `winebth.so` only over the unmodified
    GE-Proton 11-8 file and keeps that as `winebth.so.orig`.
  - Tested on the "workout" PC: a 68-minute ride with heart rate throughout, and Zwift
    reconnected the fenix by itself after three short early drops. The retry didn't run in that
    session, because the first request succeeded.
  - `tools/ble-watch.py` logs what BlueZ sees for one sensor during a ride (connects, BlueZ's
    disconnect reason, notification gaps), without root.
- **Zwift's window keeps its size and position.** Zwift saves neither. `tools/zwift-window.py`
  runs alongside the game and, with Wine's X11 driver, restores the last size and position. If
  that spot is no longer on any monitor, it restores only the size, shrunk to fit if needed. With
  every driver, including Wayland, the last size Zwift logged is written to `prefs.xml` after the
  game closes, so the next start opens at that size.
- **`zwift doctor` no longer reports a working ANT+ stick as failed.** umu/Proton doesn't pass a
  Windows program's console output back, so the live stick test always looked empty. The test now
  writes its output to a file.

## 2 November 2026

- **Repository hardening.** Added `SECURITY.md` (report problems privately through GitHub),
  `CODEOWNERS`, Dependabot for GitHub Actions, and a CI workflow (read-only permissions, actions
  pinned to commits) that runs ShellCheck and Python syntax checks, verifies every prebuilt
  binary against its checksum and builds `LinuxZwiftLauncher.exe` from source. The ANT+ bridge
  binaries now have `ant-libusb/SHA256SUMS`, which `install.sh` checks before installing them,
  and `ant-libusb/ant-test.sh` verifies the Wine build it downloads.
- **Resolution no longer stuck at 1080p** ([#3](https://github.com/Gititwhileitshott/zwift-linux/pull/3)).
  Zwift caps the resolution by the graphics profile it picks for your GPU, and under Wine it often
  picks a low one (the medium profile, which stops at 1080p, on an AMD Renoir iGPU). GNOME's
  fractional scaling also shrinks the desktop size XWayland reports. The installer now reads the
  largest connected screen's native resolution from `/sys/class/drm` and writes it to Zwift's
  `prefs.xml` once, at the first start; a resolution you then pick in Zwift's settings sticks.
  - `./install.sh --resolution WxH` picks another resolution, `--resolution auto` leaves it to Zwift.
  - `zwift reset-resolution` removes it again (a backup of `prefs.xml` is kept).
  - `zwift set-resolution [WxH]` sets a resolution, or the native one without WxH.
  - `zwift doctor` and `./install.sh --check` show the resolution.
  - Tested: confirmed working on the AMD Renoir PC (GNOME, XWayland).
- **Installer no longer hangs at step 5 when `kscreen-doctor` is installed outside KDE**
  ([#4](https://github.com/Gititwhileitshott/zwift-linux/pull/4), fixes
  [#2](https://github.com/Gititwhileitshott/zwift-linux/issues/2)). Without a running KScreen
  service, `kscreen-doctor` waits forever. The installer now only runs it in a KDE Plasma session
  (`XDG_CURRENT_DESKTOP` contains `KDE`, or `KDE_FULL_SESSION=true`) and stops it after 5 s, then
  falls back to the Xft.dpi and GNOME checks as before.
  - Not yet tested on a real KDE desktop. KDE reports are welcome; include `zwift doctor` output.

## 1.1.0 (October 2026)

- Runs Zwift without the Windows launcher, which stopped working under Wine with launcher 1.2.0
  ([#1](https://github.com/Gititwhileitshott/zwift-linux/pull/1)). See the README.

### TODO (next release)
- Fresh prefixes need WebView2 Runtime + VC++ 2015-2022 x64 redistributable installed into the
  prefix. GE-Proton's protonfixes finds no global fix for the custom AppId (umu-zwift), so both
  installs must be added to install.sh (proton runinprefix vc_redist.x64.exe /install /quiet;
  Evergreen WebView2 standalone /silent /install). Symptoms otherwise: silent UI crash at boot
  (no WebView2), then 0x80000100 abort in builtin vccorlib140.dll at the BLE device-activation
  callback (missing function Zwift's BleWin10Lib needs).

### Chromium webview launcher (2026-11-27)
- share/zwift-launcher.py: chromium app-window sign-in replicating the stock Zwift
  launcher: login page in-window, http://zwift/?code= redirect intercepted via the
  DevTools Fetch domain, authorization code returned to zwift-auth.login() for the
  token exchange. Persistent profile (~/.var/app/org.chromium.Chromium/config/
  zwift-launcher-profile for the flatpak) remembers Keycloak's SSO cookie - the SSO
  URL omits login=true, so repeat sign-ins complete without credentials.
- zwift-auth.login(): chromium first (ZWIFT_AUTH_CHROMIUM=0 to disable), WebKitGTK
  and browser-paste stay as fallbacks with the old force-login URL.
- prelaunch: interactive token refresh by default (ZWIFT_LOGIN_UI=0 restores the
  non-interactive exit-102 gate) - the launcher window now opens directly on the
  Steam session when signed out, no Desktop-Mode detour.

### Chromium launcher verified (2026-11-27)
- End-to-end intercept test on the Steam Machine PASSED: app window on the gaming
  session (Wayland), data-URL JS-redirect to http://zwift/?code=test123, CDP Fetch
  intercept returned the code, exit 0.
- Flatpak-chromium quirks handled: wrapper's unlink_profiles.py exits 1 without
  $XDG_CONFIG_HOME/chromium/Default/Preferences (launcher seeds it); X11 auth fails
  under flatpak so --ozone-platform-hint=auto runs Wayland; terminate() must signal
  the process group (bwrap orphans chrome otherwise); a leftover instance hands off
  and exits 0 - launcher kills it and retries once; CDP socket idles are tolerated
  (the sign-in form can sit still for minutes).
- deploy note: flatpak install MUST run as the deck user (as root it lands in
  /root/.local/share/flatpak and deck's store keeps serving the old build).
