#!/usr/bin/env python3
"""steam-integration.py — register Zwift as a native Steam shortcut. Part of zwift-steamos.

Writes into the Steam client's own files (Steam must not be running while this runs):
  * userdata/<uid>/config/shortcuts.vdf     the "Zwift" non-Steam shortcut(s) pointing at
                                            LinuxZwiftLauncher.exe, with our launch options
  * userdata/<uid>/config/localconfig.vdf   CompatToolMapping entry binding the shortcut to
                                            our GE-Proton compatibility tool

Usage:
  steam-integration.py --exe PATH --app-name Zwift --startdir DIR [--launch-options OPTS]
                       [--compat-tool NAME] [--icon PATH] [--description TXT]
                       [--remove] [--list]
Exit 0 on success. The shortcut's appid is crc32(exe + appname) | 0x80000000 (Steam's own
algorithm for non-Steam shortcuts), so compatdata/ and the compat-tool mapping stay stable.
"""
import argparse
import binascii
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import vdf  # noqa: E402  (vendored ValvePython/vdf, MIT)


def steam_root():
    for cand in (
        os.environ.get("STEAM_ROOT"),
        os.path.join(os.path.expanduser("~"), ".local/share/Steam"),
        os.path.join(os.path.expanduser("~"), ".steam/root"),
    ):
        if cand and os.path.isdir(cand):
            return os.path.realpath(cand)
    sys.exit("Steam client directory not found (tried $STEAM_ROOT, ~/.local/share/Steam, ~/.steam/root)")


def userdata_dirs(root):
    ud = os.path.join(root, "userdata")
    if not os.path.isdir(ud):
        sys.exit(f"no {ud} - has Steam ever run for this user?")
    dirs = [os.path.join(ud, d) for d in os.listdir(ud) if d.isdigit()]
    # newest first: a Steam install has one userdata dir per Steam account
    dirs.sort(key=lambda d: os.path.getmtime(d), reverse=True)
    if not dirs:
        sys.exit("no account directories under userdata/")
    return dirs


def appid_unsigned(exe, appname):
    crc = binascii.crc32(exe.encode("utf-8") + appname.encode("utf-8")) & 0xFFFFFFFF
    return crc | 0x80000000


def as_int32(u):
    return u - 0x100000000 if u >= 0x80000000 else u


def shortcuts_path(cfg_dir):
    return os.path.join(cfg_dir, "shortcuts.vdf")


def load_shortcuts(path):
    if os.path.exists(path):
        with open(path, "rb") as f:
            data = vdf.binary_loads(f.read())
    else:
        data = {"shortcuts": {}}
    root = data.get("shortcuts") if isinstance(data, dict) else None
    if not isinstance(root, dict):
        data = {"shortcuts": {}}
    return data


def save_shortcuts(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(vdf.binary_dumps(data))


def update_shortcuts(path, appid_s, fields):
    """Add or replace the shortcut with appid appid_s (signed). Returns (added, changed)."""
    data = load_shortcuts(path)
    root = data["shortcuts"]
    existing_key = None
    for k, sc in root.items():
        try:
            if int(sc.get("appid", 0)) == int(appid_s):
                existing_key = k
                break
        except (TypeError, ValueError):
            continue
    entry = dict(fields)
    entry["appid"] = as_int32(appid_s)
    if existing_key is not None:
        old = root[existing_key]
        if all(str(old.get(field, "")) == str(val) for field, val in entry.items()):
            return "unchanged"
        root[existing_key] = entry
        return "updated"
    # VDF dicts in shortcuts.vdf use sequential string keys ("0", "1", ...)
    root[str(len(root))] = entry
    return "added"


def remove_shortcut(path, appid_s):
    data = load_shortcuts(path)
    root = data["shortcuts"]
    for k, sc in list(root.items()):
        try:
            if int(sc.get("appid", 0)) == int(appid_s):
                del root[k]
                save_shortcuts(path, data)
                return True
        except (TypeError, ValueError):
            continue
    return False


def update_compat_mapping(path, appid_u, tool_name):
    """Set CompatToolMapping[appid] = tool in localconfig.vdf (text VDF)."""
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write('"InstallConfigStore"\n{\n}\n')
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        cfg = vdf.loads(f.read(), mapper=dict)
    sw = cfg.setdefault("InstallConfigStore", {}).setdefault("Software", {})
    valve = sw.setdefault("Valve", {}) if "Valve" in sw else sw.setdefault("valve", {})
    steam = valve.setdefault("Steam", {})
    mapping = steam.setdefault("CompatToolMapping", {})
    want = {"name": tool_name, "config": "", "Priority": "250"}
    if mapping.get(str(appid_u)) == want:
        return "unchanged"
    mapping[str(appid_u)] = want
    with open(path, "w") as f:
        vdf.dump(cfg, f, pretty=True)
    return "updated"


def remove_compat_mapping(path, appid_u):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        cfg = vdf.loads(f.read(), mapper=dict)
    sw = cfg.get("InstallConfigStore", {}).get("Software", {})
    for valve in (sw.get("Valve"), sw.get("valve")):
        if not isinstance(valve, dict):
            continue
        mapping = valve.get("Steam", {}).get("CompatToolMapping")
        if isinstance(mapping, dict) and str(appid_u) in mapping:
            del mapping[str(appid_u)]
            with open(path, "w") as f:
                vdf.dump(cfg, f, pretty=True)
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", help="shortcut target (Linux path to LinuxZwiftLauncher.exe)")
    ap.add_argument("--app-name", default="Zwift")
    ap.add_argument("--startdir", help="working directory for the shortcut (game dir)")
    ap.add_argument("--launch-options", default="")
    ap.add_argument("--compat-tool", default=None)
    ap.add_argument("--icon", default="")
    ap.add_argument("--description", default="Zwift cycling app (zwift-steamos)")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    root = steam_root()
    for ud in userdata_dirs(root):
        cfg = os.path.join(ud, "config")
        sc_path = shortcuts_path(cfg)
        lc_path = os.path.join(cfg, "localconfig.vdf")

        if args.list:
            data = load_shortcuts(sc_path)
            print(f"== {sc_path}")
            for sc in data["shortcuts"].values():
                print(f"   appid={int(sc.get('appid', 0)) & 0xFFFFFFFF} name={sc.get('AppName')!r} exe={sc.get('Exe')!r}")
            continue

        if args.remove:
            if not args.exe:
                sys.exit("--remove needs --exe (to compute the appid)")
            appid_u = appid_unsigned(args.exe, args.app_name)
            changed = False
            if os.path.exists(sc_path) and remove_shortcut(sc_path, as_int32(appid_u)):
                print(f"removed shortcut from {sc_path}")
                changed = True
            if remove_compat_mapping(lc_path, appid_u):
                print(f"removed compat mapping from {lc_path}")
                changed = True
            if not changed:
                print("nothing to remove")
            continue

        for req, name in ((args.exe, "--exe"), (args.startdir, "--startdir")):
            if not req:
                sys.exit(f"{name} is required")
        appid_u = appid_unsigned(args.exe, args.app_name)
        appid_s = as_int32(appid_u)
        fields = {
            "AppName": args.app_name,
            "Exe": args.exe,
            "StartDir": args.startdir,
            "icon": args.icon,
            "ShortcutPath": "",
            "Description": args.description,
            "LaunchOptions": args.launch_options,
            "IsHidden": 0,
            "AllowDesktopConfig": 1,
            "AllowOverlay": 1,
            "WantOverlayPreview": 0,
        }
        res = update_shortcuts(sc_path, appid_s, fields)
        print(f"{sc_path}: shortcut '{args.app_name}' {res} (appid {appid_u})")
        if args.compat_tool:
            res2 = update_compat_mapping(lc_path, appid_u, args.compat_tool)
            print(f"{lc_path}: CompatToolMapping -> {args.compat_tool} {res2}")


if __name__ == "__main__":
    main()
