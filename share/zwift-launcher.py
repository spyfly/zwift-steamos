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
            return urllib.parse.urlsplit(ws).port, ws
    raise RuntimeError("no DevTools endpoint from chromium (timeout)")


def _page_target(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
        targets = json.load(r)
    pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    if not pages:
        raise RuntimeError("no page target in chromium")
    return pages[0]["webSocketDebuggerUrl"]


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
            "DBUS_SESSION_BUS_ADDRESS", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "TMPDIR")
    env = {k: os.environ[k] for k in keep if os.environ.get(k)}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/local/bin")
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


def ask_code_chromium(url, timeout=None):
    """Open the sign-in page in a Chromium app window; return the ?code= of the
    http://zwift/ redirect, or None if the user cancelled/it timed out."""
    cmd = _chromium_cmd()
    profile = _profile_dir()
    _seed_chromium_prefs()
    os.makedirs(profile, exist_ok=True)
    timeout = timeout or float(os.environ.get("ZWIFT_AUTH_TIMEOUT", "600"))
    args = cmd + ["--app=" + url, "--user-data-dir=" + profile,
                  "--remote-debugging-port=0", "--no-first-run",
                  "--no-default-browser-check", "--window-size=%d,%d" % WINDOW,
                  "--ozone-platform-hint=auto",
                  "--disable-features=Translate,RendererCodeIntegrity",
                  "--disable-breakpad"]
    code = None
    error = None

    def _kill_tree():
        # chromium runs under the flatpak's bwrap: killing the wrapper alone orphans
        # the browser. Signal the whole process group instead.
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
        target = _page_target(port)
        sock = _ws_connect(target)
        global WS
        WS = sock
        _ws_send(sock, {"id": 1, "method": "Fetch.enable", "params": {"patterns": [
            {"urlPattern": "http://zwift/*"}, {"urlPattern": "http://zwift?*"}]}})
        mid = 1
        deadline = time.time() + timeout
        while time.time() < deadline:
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


def main(argv):
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
