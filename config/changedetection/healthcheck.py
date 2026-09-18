#!/usr/bin/env python3
"""Container healthcheck for changedetection.io.

/worker-health rather than `GET /`: the watch list renders from memory and
answers 200 with every fetch worker dead, which is this service silently not
watching anything. python3 is the only HTTP client in the image.
"""

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = "http://localhost:5000/worker-health"

try:
    with urllib.request.urlopen(URL, timeout=8) as response:
        landed_on = urllib.parse.urlsplit(response.geturl()).path
        payload = response.read()
except (urllib.error.URLError, OSError) as exc:
    sys.exit(f"{URL} did not answer: {exc}")

# A password set in Settings > General sends every non-API route to the login
# page, this one included, so the JSON is gone while the app is up and watching.
if landed_on == "/login":
    sys.exit(0)

try:
    status = json.loads(payload)["health_check"]["status"]
except (ValueError, KeyError, TypeError) as exc:
    sys.exit(f"unexpected /worker-health payload: {exc}")

# `repaired` means this very request restarted the dead workers, which is the
# endpoint doing its job; only `degraded` is a restart that failed.
if status not in ("healthy", "repaired"):
    sys.exit(f"fetch workers {status}: {payload.decode(errors='replace')}")
