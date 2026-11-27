#!/usr/bin/env python3
"""Chromium webview sign-in for zwift-steamos - replicates the default Zwift launcher.

Opens Zwift's sign-in page in a chromeless Chromium app window, intercepts the
http://zwift/?code=... redirect via the DevTools protocol (Fetch domain), returns
the authorization code. The caller (zwift-auth.login) exchanges it and stores the
result, exactly like the stock WebKit path.

The browser profile is persistent by default: the Keycloak SSO cookie survives
restarts, so the next sign-in completes silently without typing credentials -
the same behaviour the real launcher has. Set ZWIFT_AUTH_CHROMIUM_EPHEMERAL=1
for a throwaway profile.

Only the standard library is used; the DevTools websocket client (~80 lines)
avoids the websockets dependency. Chromium is located as: native binary in PATH,
then the org.chromium.Chromium flatpak, then google-chrome.
"""

import base64
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

WINDOW = (600, 860)
WS = None  # set once a DevTools socket is attached, for debug tooling

_SSO_COOKIE_HINT = (
    "Tipp: Cookies im Launcher-Profil bleiben erhalten - naechstes Mal ohne Eingabe.\n")


def _chromium_cmd():
    for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        p = shutil.which(name)
        if p:
            return [p]
    fp = shutil.which("flatpak")
    if fp:
        for inst in ("--user", "--system"):
            try:
                r = subprocess.run([fp, "info", inst, "org.chromium.Chromium"],
                                   capture_output=True, timeout=20)
                if r.returncode == 0:
                    return [fp, "run", inst, "org.chromium.Chromium"]
            except (OSError, subprocess.SubprocessError):
                pass
    raise RuntimeError("no chromium found - install it: flatpak install org.chromium.Chromium")


def _profile_dir():
    if os.environ.get("ZWIFT_AUTH_CHROMIUM_EPHEMERAL"):
        return os.path.join(os.environ.get("TMPDIR", "/tmp"), "zwift-launcher-ephemeral")
    fp = shutil.which("flatpak")
    if fp:
        return os.path.expanduser(
            "~/.var/app/org.chromium.Chromium/config/zwift-launcher-profile")
    data = os.environ.get("ZWIFT_STEAMOS_DATA") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "zwift-steamos")
    return os.path.join(data, "launcher-profile")


def _read_ws_frame(sock):
    """Minimal RFC6455 frame reader: returns (opcode, payload) of one complete message."""
    hdr = sock.recv(2)
    if len(hdr) < 2:
        raise ConnectionError("websocket closed")
    b1, b2 = hdr
    opcode, masked, length = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", sock.recv(8))[0]
    mask = sock.recv(4) if masked else None
    payload = bytearray()
    while len(payload) < length:
        chunk = sock.recv(min(65536, length - len(payload)))
        if not chunk:
            raise ConnectionError("websocket closed")
        payload += chunk
    if mask:
        payload = bytearray(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, bytes(payload)


def _read_ws_message(sock):
    """Assembles fragmented text messages; replies to pings; skips control frames."""
    buf = b""
    while True:
        opcode, payload = _read_ws_frame(sock)
        if opcode == 0x9:  # ping -> pong
            sock.sendall(_ws_send_bytes(0xA, payload))
            continue
        if opcode == 0x8:  # close
            raise ConnectionError("websocket closed by peer")
        if opcode in (0x1, 0x0):
            buf += payload
            if opcode == 0x1 or not buf:
                pass
        fin = opcode != 0  # frames arrive one at a time here; fragmentation is rare
        if fin and (opcode in (0x1, 0x2)) and buf:
            return buf


def _ws_send_bytes(opcode, payload):
    mask = os.urandom(4)
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def _ws_send(sock, obj):
    sock.sendall(_ws_send_bytes(0x1, json.dumps(obj).encode()))


def _ws_connect(url):
    u = urllib.parse.urlsplit(url)
    sock = socket.create_connection((u.hostname, u.port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    if b" 101 " not in resp.split(b"\r\n", 1)[0]:
        raise ConnectionError(f"websocket upgrade failed: {resp[:120]!r}")
    sock.settimeout(10)
    return sock


def _devtools_port(proc, deadline=20.0):
    """Read chromium stderr until the DevTools ws endpoint appears; return (port, ws_url)."""
    q = queue.Queue()
    threading.Thread(target=lambda: [q.put(line) for line in iter(proc.stderr.readline, "")],
                     daemon=True).start()
    end = time.time() + deadline
    while time.time() < end:
        try:
            line = q.get(timeout=1.0)
        except queue.Empty:
            if proc.poll() is not None:
                raise RuntimeError(f"chromium exited early (rc={proc.returncode})")
            continue
        if "DevTools listening" in line:
            ws = line.split("DevTools listening on ")[1].strip()
            port = urllib.parse.urlsplit(ws).port
            if os.environ.get("ZWIFT_LAUNCHER_DEBUG"):
                sys.stderr.write(f"zwift-launcher: debug port={port} "
                                 f"alive={proc.poll() is None}\n")
            return port, ws
        sys.stderr.write("zwift-launcher: chromium: " + line)
    raise RuntimeError("no DevTools endpoint from chromium (timeout)")


def _page_target(port):
    # the DevTools line can print before the HTTP listener accepts; poll briefly.
    end = time.time() + 15
    while True:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
                targets = json.load(r)
            break
        except OSError as e:
            if time.time() >= end:
                raise RuntimeError(f"DevTools endpoint unreachable: {e}") from e
            time.sleep(1.0)
    pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    if not pages:
        raise RuntimeError("no page target in chromium")
    return pages[0]["webSocketDebuggerUrl"]


def _ws_call(sock, mid, method, params=None):
    """Send one CDP command and wait for its id-matched response (best effort)."""
    _ws_send(sock, {"id": mid, "method": method, "params": params or {}})
    sock.settimeout(5)
    try:
        while True:
            try:
                raw = _read_ws_message(sock)
            except socket.timeout:
                return {}
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if msg.get("id") == mid:
                return msg
    finally:
        sock.settimeout(None)


def _headless_signin(env):
    """True when no compositor can show the window (SteamOS game mode runs
    gamescope without a wayland socket; foreign windows stay invisible there).
    Desktop mode has a wayland socket -> the launcher window is visible and the
    user clicks the rider themselves."""
    wd = env.get("WAYLAND_DISPLAY")
    if not wd:
        return True
    return not os.path.exists(os.path.join(env.get("XDG_RUNTIME_DIR", "/run/user/1000"), wd))


def _import_remember_cookies(sock):
    """Seed Zluggish's remember-me cookie(s) from remember-cookies.json into the
    chromium profile via CDP. The realm renews the cookie on every rider login,
    so this is only the initial bootstrap (e.g. after a lost profile)."""
    path = (os.environ.get("ZWIFT_REMEMBER_COOKIES")
            or os.path.join(os.environ.get("ZWIFT_STEAMOS_DATA", ""),
                            "remember-cookies.json"))
    try:
        with open(path) as f:
            cookies = json.load(f)
    except (OSError, ValueError):
        return 0
    if not isinstance(cookies, list):
        return 0
    _ws_call(sock, 100, "Network.enable", {})
    mid, ok = 101, 0
    for c in cookies:
        if not isinstance(c, dict) or not c.get("name") or not c.get("domain"):
            continue
        params = {"name": c["name"], "value": str(c.get("value", "")),
                  "domain": c["domain"], "path": c.get("path") or "/",
                  "secure": bool(c.get("secure")), "httpOnly": bool(c.get("httpOnly"))}
        exp = c.get("expirationDate")
        if isinstance(exp, (int, float)):
            params["expires"] = float(exp)
        ss = c.get("sameSite")
        if isinstance(ss, str) and ss.lower() in ("strict", "lax", "none"):
            params["sameSite"] = ss.title()
        msg = _ws_call(sock, mid, "Network.setCookie", params)
        mid += 1
        if msg.get("result", {}).get("success"):
            ok += 1
        else:
            sys.stderr.write(f"zwift-launcher: cookie {c.get('name')} not set: {msg}\n")
    sys.stderr.write(f"zwift-launcher: remember cookies imported: {ok}/{len(cookies)}\n")
    return ok


_RIDER_CLICK_JS = ('(() => { const f = document.querySelector(\'form[id^="game-form-rider-"]\');'
                   ' if (!f) return "norider";'
                   ' (f.querySelector("button[type=submit]") || f).click();'
                   ' return "clicked:" + f.id; })()')

_SUCCESS_PAGE = (
    "<html><body style=\"background:#10151d;color:#fc4c02;font-family:sans-serif;"
    "display:grid;place-items:center;height:92vh;text-align:center\">"
    "<div><h2>Anmeldung erfolgreich</h2><p style=\"color:#bbb\">Zwift wird gestartet &hellip;</p>"
    "<script>setTimeout(()=>window.close(),1500)</script></div></body></html>")
_FAILURE_PAGE = (
    "<html><body style=\"background:#10151d;color:#fc4c02;font-family:sans-serif;"
    "display:grid;place-items:center;height:92vh;text-align:center\">"
    "<div><h2>Anmeldung fehlgeschlagen</h2><p style=\"color:#bbb\">Fenster schlie&szlig;t &hellip;</p>"
    "<script>setTimeout(()=>window.close(),4000)</script></div></body></html>")


def _clean_env():
    """Steam's runtime env shadows system libs and breaks host apps; give chromium a
    minimal, session-correct environment instead."""
    keep = ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "DISPLAY", "WAYLAND_DISPLAY",
            "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP", "XAUTHORITY",
            "DBUS_SESSION_BUS_ADDRESS", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "TMPDIR",
            "XDG_DATA_DIRS", "XDG_CONFIG_DIRS")
    env = {k: os.environ[k] for k in keep if k in os.environ}
    # Big Picture runs Steam under gamescope without WAYLAND_DISPLAY; redirect
    # the launcher window into the gamescope session so it is actually visible.
    if "WAYLAND_DISPLAY" not in env and "GAMESCOPE_WAYLAND_DISPLAY" in os.environ:
        env["WAYLAND_DISPLAY"] = os.environ["GAMESCOPE_WAYLAND_DISPLAY"]
    env.setdefault("PATH", "/usr/bin:/bin:/usr/local/bin")
    env.setdefault("XDG_DATA_DIRS", "/usr/share:/usr/local/share")
    env.setdefault("HOME", os.path.expanduser("~"))
    return env


def _seed_chromium_prefs():
    # org.chromium.Chromium's wrapper runs unlink_profiles.py before the browser: it
    # scans $XDG_CONFIG_HOME/chromium/Default and exits 1 when Preferences is missing,
    # which kills chromium on a virgin system. Seed a minimal file so the wrapper passes.
    cfg = os.path.expanduser("~/.var/app/org.chromium.Chromium/config/chromium/Default")
    try:
        os.makedirs(cfg, exist_ok=True)
        p = os.path.join(cfg, "Preferences")
        if not os.path.exists(p):
            with open(p, "w") as f:
                f.write("{}")
    except OSError:
        pass


def _tls_spki_flag():
    # Offline the auth realm is served by Zluggish with its own certificate under a
    # zwift.com hostname; pin-exception by SPKI so only that cert is exempted
    # (online launches export no SSL_CERT_FILE and keep full validation).
    cert = os.environ.get("SSL_CERT_FILE")
    if not cert:
        return []
    try:
        pub = subprocess.run(["openssl", "x509", "-in", cert, "-pubkey", "-noout"],
                             capture_output=True, text=True, timeout=10, check=True)
        der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"],
                             input=pub.stdout.encode(), capture_output=True,
                             timeout=10, check=True)
        sha = subprocess.run(["openssl", "dgst", "-sha256", "-binary"],
                             input=der.stdout, capture_output=True, timeout=10, check=True)
        return ["--ignore-certificate-errors-spki-list="
                + base64.b64encode(sha.stdout).decode()]
    except (OSError, subprocess.SubprocessError):
        return []


def ask_code_chromium(url, timeout=None):
    """Open the sign-in page in a Chromium app window; return the ?code= of the
    http://zwift/ redirect, or None if the user cancelled/it timed out."""
    cmd = _chromium_cmd()
    profile = _profile_dir()
    _seed_chromium_prefs()
    os.makedirs(profile, exist_ok=True)
    timeout = timeout or float(os.environ.get("ZWIFT_AUTH_TIMEOUT", "600"))
    env = _clean_env()
    # Wayland sessions must not let ozone fall back to X11 (XAUTHORITY is absent
    # in the cleaned env); only pure-X11 sessions keep the auto hint.
    ozone = (["--ozone-platform=wayland"] if "WAYLAND_DISPLAY" in env
             else ["--ozone-platform-hint=auto"])
    args = cmd + ["--app=" + url, "--user-data-dir=" + profile,
                  "--remote-debugging-port=0", "--no-first-run",
                  "--no-default-browser-check", "--window-size=%d,%d" % WINDOW] \
        + ozone + \
                  ["--disable-features=Translate,RendererCodeIntegrity",
                  "--disable-breakpad"] + _tls_spki_flag()
    code = None
    error = None
    proc = None
    if os.environ.get("ZWIFT_LAUNCHER_DEBUG"):
        sys.stderr.write(f"zwift-launcher: debug cmd: {args}\n")
        sys.stderr.write(f"zwift-launcher: debug env keys: {sorted(env)}\n")
        sys.stderr.write(f"zwift-launcher: debug spki: {[a for a in args if a.startswith('--ignore-certificate') ] or 'NONE'}\n")

    def _kill_tree():
        # chromium runs under the flatpak's bwrap: killing the wrapper alone orphans
        # the browser. Signal the whole process group instead.
        if proc is None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), 15)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), 9)
            except (ProcessLookupError, PermissionError):
                pass
        # sweep escapees: chrome can leave the process group via the flatpak
        # wrapper; anything still holding this profile would hand off to and
        # poison the next launch.
        subprocess.run(["pkill", "-9", "-f", "user-data-dir=" + profile],
                       timeout=10, check=False)

    try:
        port = None
        for attempt in range(2):  # 2nd try: a leftover instance hands off and exits 0
            proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                    text=True, errors="replace", env=_clean_env(),
                                    start_new_session=True)
            try:
                port, _ws_url = _devtools_port(proc)
                break
            except RuntimeError as e:
                _kill_tree()
                if "rc=0" not in str(e) or attempt:
                    raise
                # a leftover chromium with this profile took the URL and exited -
                # clear the stale instance and start fresh once.
                subprocess.run(["pkill", "-f", "user-data-dir=" + profile],
                               timeout=10, check=False)
                time.sleep(2)
        assert proc is not None and port is not None, "chromium never started"
        target = _page_target(port)
        sock = _ws_connect(target)
        global WS
        WS = sock
        _cookie_count = _import_remember_cookies(sock)
        _ws_send(sock, {"id": 1, "method": "Fetch.enable", "params": {"patterns": [
            {"urlPattern": "http://zwift/*"}, {"urlPattern": "http://zwift?*"}]}})
        mid = 1
        # Auto rider click: with the remember cookie the /login/ page accepts a
        # single button click as sign-in, so the launcher can do it headlessly -
        # needed on Big Picture/gamescope where the window is never visible.
        rider_clicks = 0
        env_now = _clean_env()
        if _cookie_count and _headless_signin(env_now):
            next_click = time.time() + 2.5
            sock.settimeout(2.5)  # wake the read loop for the click timer
        else:
            next_click = time.time() * 2  # window is visible - user clicks
        deadline = time.time() + timeout
        while time.time() < deadline:
            if time.time() >= next_click and rider_clicks < 12:
                _ws_send(sock, {"id": 4000 + rider_clicks, "method": "Runtime.evaluate",
                                "params": {"expression": _RIDER_CLICK_JS,
                                           "returnByValue": True}})
                rider_clicks += 1
                next_click = time.time() + 2.5
            if proc.poll() is not None:
                break
            try:
                raw = _read_ws_message(sock)
            except TimeoutError:
                continue  # quiet page - the sign-in form can sit there for minutes
            except (ConnectionError, OSError):
                break
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if isinstance(msg.get("id"), int) and msg["id"] >= 4000:
                r = (msg.get("result") or {}).get("result") or {}
                sys.stderr.write(f"zwift-launcher: click#{msg['id'] - 4000}: "
                                 f"{r.get('value') if r else msg.get('error')}\n")
            if msg.get("method") != "Fetch.requestPaused":
                continue
            params = msg.get("params", {})
            rid, rurl = params.get("requestId"), params.get("request", {}).get("url", "")
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(rurl).query)
            code = (q.get("code") or [None])[0]
            error = (q.get("error_description") or q.get("error") or [None])[0]
            page = _SUCCESS_PAGE if (code and not error) else _FAILURE_PAGE
            mid += 1
            _ws_send(sock, {"id": mid, "method": "Fetch.fulfillRequest", "params": {
                "requestId": rid, "responseCode": 200, "responsePhrase": "OK",
                "responseHeaders": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}],
                "body": base64.b64encode(page.encode()).decode()}})
            if code and not error:
                time.sleep(1.6)  # let the success page paint
            break
    except Exception as e:  # noqa: BLE001 - best effort launcher, caller falls back
        print(f"zwift-launcher: {e}", file=sys.stderr)
    finally:
        _kill_tree()
    if error:
        sys.exit(f"zwift-auth: sign-in failed: {error}")
    return code


def run_settings(url, timeout=7200):
    """Settings mode: open the Zluggish web UI in the launcher webview and wait
    until the user closes the window. No token capture, no intercept."""
    cmd = _chromium_cmd()
    profile = _profile_dir()
    _seed_chromium_prefs()
    os.makedirs(profile, exist_ok=True)
    env = _clean_env()
    ozone = (["--ozone-platform=wayland"] if "WAYLAND_DISPLAY" in env
             else ["--ozone-platform-hint=auto"])
    args = cmd + ["--app=" + url, "--user-data-dir=" + profile,
                  "--no-first-run", "--no-default-browser-check",
                  "--window-size=%d,%d" % WINDOW] + ozone + \
        ["--disable-features=Translate,RendererCodeIntegrity",
         "--disable-breakpad"] + _tls_spki_flag()
    for attempt in range(2):
        proc = subprocess.Popen(args, env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)

        def _kill_tree():
            try:
                os.killpg(os.getpgid(proc.pid), 15)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(proc.pid), 9)
                except (ProcessLookupError, PermissionError):
                    pass
            subprocess.run(["pkill", "-9", "-f", "user-data-dir=" + profile],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def _drain():
            err = proc.stderr
            if err is None:
                return
            for line in err:
                if os.environ.get("ZWIFT_LAUNCHER_DEBUG"):
                    sys.stderr.write("zwift-launcher: chromium: " + line)

        threading.Thread(target=_drain, daemon=True).start()
        try:
            proc.wait(timeout=timeout)
            if proc.returncode == 0 and attempt == 0:
                continue  # handed off to an existing instance: retry once
            return 0
        except subprocess.TimeoutExpired:
            return 0
        finally:
            _kill_tree()
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "settings":
        url = os.environ.get("ZWIFT_SETTINGS_URL") or "https://secure.zwift.com/"
        run_settings(url)
        return 0
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    code = ask_code_chromium(argv[1])
    if code:
        print(code)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
