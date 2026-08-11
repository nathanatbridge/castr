#!/usr/bin/python3
"""Launcher inside Castr Analyzer.app.

Serves docs/ over localhost and opens it in the default browser. That is the
whole job: the analyser is client-side, so once the page has loaded this
server exists only to answer the "load example" fetch. Nothing here parses a
recording or computes a metric — StrokeAnalysis.swift and docs/analysis.js
remain the only two implementations, checked against each other by
tools/verify-web-parity.js.

Deliberately stdlib-only and Swift-free, so building the app never touches
Package.swift and never needs a compile.
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

# The app is only reachable while it is being used. Because analysis runs in
# the browser, a dead server costs you nothing except the example button, and
# relaunching re-attaches to a live one. This is the only shutdown mechanism:
# a headless python process gets no Dock tile, so there is no menu to quit
# from.
IDLE_TIMEOUT = 30 * 60
PORT_RANGE = range(8788, 8799)
MARKER = "castr-analyzer"
HEALTH_PATH = "/__castr/health"


def resource_dir():
    """Contents/Resources, derived from this file rather than the cwd.

    LaunchServices starts an app bundle with the cwd set to /, so anything
    relative has to be anchored here.
    """
    return os.path.dirname(os.path.abspath(__file__))


def readable(d):
    """True only if index.html can actually be read out of d.

    os.path.isfile is not enough. The repo lives under ~/Desktop, which macOS
    puts behind TCC: a launched .app is allowed to stat those files but gets
    EPERM on open(), so an isfile() check picks a directory every read then
    404s out of. Open the file for real, or don't trust it.
    """
    try:
        with open(os.path.join(d, "index.html"), "rb") as f:
            f.read(1)
        return True
    except OSError:
        return False


def docs_dir():
    """Prefer the live repo checkout; fall back to the copy inside the bundle.

    CONSOLE-PLAN.md's one architectural rule is to serve docs/ itself and never
    fork the analyser. The bundled copy is a build artefact of that same
    directory, not a second source — tools/make-app.sh refreshes it and
    verify-web-parity.js still checks the one original.

    Live is tried first so that editing docs/ can show up with no rebuild, but
    it only wins when it is genuinely readable; under TCC it usually is not.
    """
    live = os.environ.get("CASTR_DOCS") or LIVE_DOCS
    if live and readable(live):
        return live
    return os.path.join(resource_dir(), "docs")


# Rewritten by tools/make-app.sh at build time.
LIVE_DOCS = "@LIVE_DOCS@"


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        kwargs["directory"] = docs_dir()
        super().__init__(*args, **kwargs)

    def do_GET(self):
        self.server.last_request = time.time()
        # Bound to 127.0.0.1 already, so the only way a remote page reaches us
        # is DNS rebinding, which arrives with a Host we never issued.
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", ""):
            self.send_error(403, "non-local Host")
            return
        if self.path.split("?")[0] == HEALTH_PATH:
            d = docs_dir()
            body = json.dumps({
                "app": MARKER,
                "docs": d,
                "source": "live" if d == (os.environ.get("CASTR_DOCS")
                                          or LIVE_DOCS) else "bundled",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, *args):
        pass  # No terminal is attached; stderr would go to Console.app as noise.


def find_running():
    """Return the port of an instance already serving, if there is one.

    Double-clicking twice should focus the thing you already have, not race a
    second copy onto a second port.
    """
    for port in PORT_RANGE:
        try:
            with urllib.request.urlopen(
                "http://127.0.0.1:%d%s" % (port, HEALTH_PATH), timeout=0.4
            ) as r:
                if json.loads(r.read().decode()).get("app") == MARKER:
                    return port
        except (urllib.error.URLError, OSError, ValueError):
            continue
    return None


def serve():
    for port in PORT_RANGE:
        try:
            httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
            return httpd, port
        except OSError:
            continue
    return None, None


def reap_when_idle(httpd):
    while True:
        time.sleep(30)
        if time.time() - httpd.last_request > IDLE_TIMEOUT:
            threading.Thread(target=httpd.shutdown, daemon=True).start()
            return


def alert(msg):
    subprocess.run([
        "/usr/bin/osascript", "-e",
        'display alert "Castr Analyzer" message "%s" as critical' % msg,
    ])


def run_server():
    """The resident half: holds the port. Never started by a double-click."""
    if not readable(docs_dir()):
        return 1
    httpd, port = serve()
    if httpd is None:
        return 1

    httpd.last_request = time.time()
    threading.Thread(target=reap_when_idle, args=(httpd,), daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: threading.Thread(
            target=httpd.shutdown, daemon=True).start())

    httpd.serve_forever()
    return 0


def main():
    """The clicked half: opens the browser, then exits immediately.

    Exiting is the whole point. macOS will not start a second copy of an app
    that is already running — it just activates the existing one, and an
    LSUIElement bundle has no window to activate, so the click does nothing at
    all. Keeping the server in this process therefore breaks every launch after
    the first. So the bundle's process only ever brokers: it finds or spawns a
    detached server, opens the browser and quits, which leaves the app "not
    running" and the next click live.
    """
    if "--serve" in sys.argv:
        return run_server()

    if not readable(docs_dir()):
        alert("Could not find the analyser page. Rebuild it with "
              "tools/make-app.sh.")
        return 1

    port = find_running()
    if port is None:
        # start_new_session detaches it, so it outlives this process exiting.
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--serve"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.time() + 8
        while port is None and time.time() < deadline:
            time.sleep(0.2)
            port = find_running()

    if port is None:
        alert("The analyser server did not start. No free port in 8788-8798?")
        return 1

    subprocess.run(["/usr/bin/open", "http://127.0.0.1:%d/" % port])
    return 0


if __name__ == "__main__":
    sys.exit(main())
