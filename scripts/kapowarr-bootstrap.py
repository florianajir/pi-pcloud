#!/usr/bin/env python3
"""Configure Kapowarr: root folders, post-processing settings and the qBittorrent
download client (idempotent).

Runs *inside* the Kapowarr container, fed to its bundled python3 on stdin by
kapowarr-bootstrap.sh - not on the host. Kapowarr shares gluetun's network
namespace, so its API only answers on localhost:5656 there, and the image ships
no curl and no jq. Credentials arrive through the environment, never on the
command line.

Being a file rather than a heredoc is what puts it under ruff in `make lint`;
as an inlined block none of its 127 lines were checked by anything.
"""

import json
import os
import time
import urllib.parse
import urllib.request

BASE = "http://localhost:5656/api"
USER = os.environ.get("KAP_USER") or None
PASS = os.environ.get("KAP_PASS") or None


def call(method, path, params=None, body=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.loads(r.read() or b"{}")


def log(msg):
    print(f"[kapowarr-bootstrap] {msg}", flush=True)


def wait_for_api_key():
    """Wait for the API and obtain the api_key. Fresh installs have no auth
    password, so /auth returns the key regardless of the credentials we send."""
    for _ in range(60):
        try:
            _, res = call("POST", "/auth", body={"username": USER, "password": PASS})
            key = (res.get("result") or {}).get("api_key")
            if key:
                return key
        except Exception:
            pass
        time.sleep(5)
    return None


# Root folders, one per Kavita library type: /comics is served by a ComicVine-type
# library, /manga by a Manga-type one (right-to-left, manga reading defaults).
# Move a volume between them from Kapowarr's UI; nothing here reassigns volumes.
ROOT_FOLDERS = ["/comics", "/manga"]

# download_folder MUST be /downloads (only path mounted identically in both Kapowarr and
# qBittorrent) so torrents qBittorrent saves are found and imported into /comics.
# flaresolverr_base_url lets Kapowarr solve Cloudflare on GetComics (same solver Prowlarr uses).
DESIRED_SETTINGS = {
    "download_folder": "/downloads",
    "flaresolverr_base_url": "http://flaresolverr:8191",
    # GetComics often ships a .zip *wrapping* the real .cbz/.cbr. Without these two
    # Kapowarr imports the wrapper as the issue and Kavita opens an archive of
    # archives: 0 pages, no cover. `convert` gates post-processing, and
    # `extract_issue_ranges` is what unpacks it.
    "convert": True,
    "extract_issue_ranges": True,
    # Flat, one level, year in the folder name. Kavita's ComicVine library type reads
    # the series from the folder, never the filename, and GetFoldersTillRoot stops
    # below the scan root - so ANY volume subfolder makes it fall back to that
    # subfolder's name and every series becomes "Volume 01", "Volume 02", ...
    # Does not move existing folders; that needs a mass_rename per volume.
    "volume_folder_naming": "{series_name} ({year})",
    # Must stay empty: every converter that leaves ZIP territory shells out to the
    # bundled rar binary, which is x86-64 only and cannot exec on this aarch64 host.
    "format_preference": [],
}

# localhost:8080 returns 403 from inside the shared namespace; qBittorrent has to
# be addressed by the name that owns the namespace.
QB_BASE_URL = "http://gluetun:8080"


def configure_root_folders(key):
    _, res = call("GET", "/rootfolder", params={"api_key": key})
    # Kapowarr stores paths with a trailing slash (/comics/), so normalise before comparing.
    folders = [(rf.get("folder") or "").rstrip("/") for rf in (res.get("result") or [])]
    for folder in ROOT_FOLDERS:
        if folder not in folders:
            call("POST", "/rootfolder", params={"api_key": key}, body={"folder": folder})
            log(f"Added root folder {folder}")
        else:
            log(f"Root folder {folder} already present")


def settings_match(current, desired):
    # Kapowarr stores folders with a trailing slash (/downloads/), so normalise.
    if isinstance(desired, str):
        return (current or "").rstrip("/") == desired.rstrip("/")
    return current == desired


def configure_settings(key):
    _, res = call("GET", "/settings", params={"api_key": key})
    cur = res.get("result", {})
    changed = {k: v for k, v in DESIRED_SETTINGS.items() if not settings_match(cur.get(k), v)}
    if changed:
        call("PUT", "/settings", params={"api_key": key}, body=changed)
        log("Updated settings: " + ", ".join(sorted(changed)))
    else:
        log("Settings already correct (" + ", ".join(sorted(DESIRED_SETTINGS)) + ")")


def configure_qbittorrent(key):
    _, res = call("GET", "/externalclients", params={"api_key": key})
    clients = res.get("result") or []
    existing = next((c for c in clients if c.get("title") == "qBittorrent"), None)
    body = {
        "title": "qBittorrent",
        "base_url": QB_BASE_URL,
        "username": USER,
        "password": PASS,
        "api_token": None,
    }
    if existing is None:
        call("POST", "/externalclients", params={"api_key": key}, body={"client_type": "qBittorrent", **body})
        log("Added qBittorrent external client")
    elif existing.get("base_url") != QB_BASE_URL:
        # Migrate a stale base_url (e.g. http://localhost:8080 -> gluetun).
        call("PUT", f"/externalclients/{existing['id']}", params={"api_key": key}, body=body)
        log(f"Updated qBittorrent external client base_url to {QB_BASE_URL}")
    else:
        log("qBittorrent external client already present")


def main():
    key = wait_for_api_key()
    if not key:
        log("WARNING: could not obtain API key; skipping")
        return 0

    # Each step is guarded on its own: a Kapowarr version that renamed one
    # endpoint should not cost the stack the other two.
    for label, step in (
        ("root folder", configure_root_folders),
        ("settings", configure_settings),
    ):
        try:
            step(key)
        except Exception as e:
            log(f"WARNING: {label} step failed: {e}")

    if USER and PASS:
        try:
            configure_qbittorrent(key)
        except Exception as e:
            log(f"WARNING: external client step failed: {e}")
    else:
        log("ADMIN_USER/PASSWORD not set; skipping qBittorrent client")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
