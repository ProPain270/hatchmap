#!/usr/bin/env python3
"""hatch-actions — HatchMap's remote-control endpoint for the homelab server.

Tailnet-only by construction: binds 127.0.0.1 and is published with `tailscale serve`, which
terminates TLS with the node's Tailscale certificate and only accepts tailnet peers. Every
request must carry the bearer token from /etc/hatch-actions/token. Every action is appended to
/var/log/hatch-actions.log. No shell interpolation of client input anywhere: container names are
validated against `docker ps -a`, scripts against the allow-list in config.json.

Endpoints
  GET  /ping                          reachability (no auth)
  GET  /health                        service + notifier status
  GET  /containers                    docker ps -a
  POST /containers/<name>/<op>        op ∈ start|stop|restart
  GET  /scripts                       allow-listed systemd units with last-run info
  POST /scripts/<id>                  systemctl start <unit>
  POST /topology/refresh              run hatch-topology-gen.service now, return meta.updated
  GET  /log?n=100                     recent action log
  GET  /notify/config                 push rules (topic, enabled, per-event flags)
  PUT  /notify/config                 update push rules (JSON body, only known keys)
  POST /notify/test                   send a low-priority test push to the topic
"""
import hmac, json, os, re, subprocess, sys, time, threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VERSION = "1.0"
CONF_DIR = "/etc/hatch-actions"
CONF = os.path.join(CONF_DIR, "config.json")
TOKEN_FILE = os.path.join(CONF_DIR, "token")
LOG = "/var/log/hatch-actions.log"
NOTIFY_STATE = "/var/lib/hatch-notify/state.json"
TOPOLOGY = "/opt/hatch-map/topology.json"
START = time.time()
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
LOCK = threading.Lock()


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_config():
    try:
        with open(CONF) as f:
            return json.load(f)
    except Exception:
        return {"bind": "127.0.0.1", "port": 8771, "scripts": []}


def load_token():
    try:
        return open(TOKEN_FILE).read().strip()
    except Exception:
        return ""


def sh(args, timeout=60):
    """Run a fixed argv (never a shell string) and return (rc, stdout+stderr)."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ss" % timeout
    except Exception as e:
        return 1, str(e)


def audit(who, action, ok, detail=""):
    line = "%s\t%s\t%s\t%s\t%s\n" % (now(), who, action, "ok" if ok else "FAIL", detail.replace("\n", " ⏎ ")[:500])
    with LOCK:
        try:
            with open(LOG, "a") as f:
                f.write(line)
        except Exception:
            pass


def docker_ok():
    rc, _ = sh(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=10)
    return rc == 0


def containers():
    rc, out = sh(["docker", "ps", "-a", "--format", "{{json .}}"], timeout=20)
    if rc != 0:
        raise RuntimeError(out or "docker ps failed")
    items = []
    for ln in out.splitlines():
        try:
            j = json.loads(ln)
        except Exception:
            continue
        items.append({"name": j.get("Names", ""), "state": j.get("State", ""), "status": j.get("Status", ""),
                      "image": j.get("Image", "")})
    return items


def unit_info(unit):
    rc, out = sh(["systemctl", "show", unit, "-p", "ActiveEnterTimestamp,ExecMainExitTimestamp,Result,ActiveState,SubState"], timeout=10)
    info = {}
    for ln in out.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            info[k] = v
    last = info.get("ExecMainExitTimestamp") or info.get("ActiveEnterTimestamp") or ""
    return {"last_run": last, "last_result": info.get("Result", ""),
            "running": info.get("ActiveState") in ("activating", "active") and info.get("SubState") not in ("dead", "exited")}


def scripts_list(cfg):
    out = []
    for s in cfg.get("scripts", []):
        d = dict(s)
        d.update(unit_info(s["unit"]))
        out.append(d)
    return out


NOTIFY_EVENTS = ["node_down", "node_up", "node_warn", "disk_warn", "disk_crit", "disk_ok", "sitrep", "stale"]


def notify_config(cfg):
    n = dict(cfg.get("notify", {}))
    n.setdefault("ntfy", "http://127.0.0.1:5000"); n.setdefault("topic", "hatchmap-alerts"); n.setdefault("enabled", True)
    ev = dict(n.get("events", {}))
    for k in NOTIFY_EVENTS:
        ev.setdefault(k, True)
    n["events"] = ev
    n.pop("token", None)                      # never hand the ntfy token back out
    return n


def save_config(cfg):
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CONF)


def notify_state():
    try:
        with open(NOTIFY_STATE) as f:
            st = json.load(f)
        return {"ntfy": st.get("ntfy"), "topic": st.get("topic"), "last_push": st.get("last_push"),
                "last_check": st.get("last_check"), "enabled": st.get("enabled", True)}
    except Exception:
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "hatch-actions/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet; the audit log is the record
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        tok = load_token()
        h = self.headers.get("Authorization", "")
        given = h[7:].strip() if h.lower().startswith("bearer ") else self.headers.get("X-Hatch-Token", "").strip()
        return bool(tok) and hmac.compare_digest(given, tok)

    def who(self):
        return self.headers.get("X-Forwarded-For") or self.client_address[0]

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/ping":
            return self.send(200, {"ok": True, "service": "hatch-actions", "version": VERSION})
        if not self.authed():
            return self.send(401, {"ok": False, "error": "unauthorized"})
        cfg = load_config()
        try:
            if path == "/health":
                return self.send(200, {"ok": True, "version": VERSION, "host": os.uname().nodename, "time": now(),
                                       "uptime_s": round(time.time() - START, 1), "docker_ok": docker_ok(),
                                       "notify": notify_state()})
            if path == "/containers":
                return self.send(200, {"containers": containers()})
            if path == "/scripts":
                return self.send(200, {"scripts": scripts_list(cfg)})
            if path == "/notify/config":
                return self.send(200, {"notify": notify_config(cfg)})
            if path == "/log":
                n = int(parse_qs(urlparse(self.path).query).get("n", ["100"])[0])
                try:
                    lines = open(LOG).read().splitlines()[-n:]
                except Exception:
                    lines = []
                ents = []
                for ln in lines:
                    c = ln.split("\t")
                    if len(c) >= 4:
                        ents.append({"time": c[0], "who": c[1], "action": c[2], "ok": c[3] == "ok", "detail": c[4] if len(c) > 4 else ""})
                return self.send(200, {"entries": ents})
        except Exception as e:
            return self.send(500, {"ok": False, "error": str(e)})
        self.send(404, {"ok": False, "error": "not found"})

    def do_PUT(self):
        path = urlparse(self.path).path.rstrip("/")
        if not self.authed():
            return self.send(401, {"ok": False, "error": "unauthorized"})
        if path != "/notify/config":
            return self.send(404, {"ok": False, "error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
            cfg = load_config()
            cur = notify_config(cfg)
            changed = []
            if "enabled" in body:
                cur["enabled"] = bool(body["enabled"]); changed.append("enabled=%s" % cur["enabled"])
            if "topic" in body and re.match(r"^[A-Za-z0-9_-]{1,64}$", str(body["topic"])):
                cur["topic"] = str(body["topic"]); changed.append("topic=" + cur["topic"])
            for k, v in (body.get("events") or {}).items():
                if k in NOTIFY_EVENTS:
                    cur["events"][k] = bool(v); changed.append("%s=%s" % (k, bool(v)))
            keep_token = cfg.get("notify", {}).get("token")
            cfg["notify"] = cur if not keep_token else dict(cur, token=keep_token)
            save_config(cfg)
            audit(self.who(), "notify config", True, ", ".join(changed) or "no change")
            return self.send(200, {"ok": True, "notify": notify_config(cfg)})
        except Exception as e:
            audit(self.who(), "notify config", False, str(e))
            return self.send(500, {"ok": False, "error": str(e)})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        if not self.authed():
            audit(self.who(), "POST " + path, False, "unauthorized")
            return self.send(401, {"ok": False, "error": "unauthorized"})
        cfg = load_config()
        who = self.who()
        try:
            m = re.match(r"^/containers/([^/]+)/(start|stop|restart)$", path)
            if m:
                name, op = m.group(1), m.group(2)
                if not NAME_RE.match(name):
                    return self.send(400, {"ok": False, "error": "bad container name"})
                known = {c["name"] for c in containers()}
                if name not in known:
                    audit(who, "container %s %s" % (op, name), False, "unknown container")
                    return self.send(404, {"ok": False, "error": "no such container"})
                if name in cfg.get("protected_containers", []) and op != "start":
                    audit(who, "container %s %s" % (op, name), False, "protected")
                    return self.send(403, {"ok": False, "error": "%s is protected in config.json" % name})
                rc, out = sh(["docker", op, name], timeout=90)
                audit(who, "container %s %s" % (op, name), rc == 0, out)
                return self.send(200 if rc == 0 else 500, {"ok": rc == 0, "output": out or ("%s %s" % (op, name)),
                                                            "error": None if rc == 0 else (out or "docker exited %d" % rc)})
            m = re.match(r"^/scripts/([A-Za-z0-9_.-]+)$", path)
            if m:
                sid = m.group(1)
                s = next((x for x in cfg.get("scripts", []) if x["id"] == sid), None)
                if not s:
                    audit(who, "script " + sid, False, "not allow-listed")
                    return self.send(404, {"ok": False, "error": "script not allow-listed"})
                rc, out = sh(["systemctl", "start", "--no-block", s["unit"]], timeout=20)
                audit(who, "script " + sid, rc == 0, out or "started " + s["unit"])
                return self.send(200 if rc == 0 else 500, {"ok": rc == 0, "output": out or "started " + s["unit"],
                                                            "error": None if rc == 0 else out})
            if path == "/notify/test":
                n = notify_config(cfg)
                tok = cfg.get("notify", {}).get("token")
                import urllib.request
                req = urllib.request.Request("%s/%s" % (n["ntfy"].rstrip("/"), n["topic"]),
                                             data=b"Test from HatchMap on your Mac. Push rules are working.", method="POST")
                req.add_header("Title", "HatchMap test push"); req.add_header("Priority", "low"); req.add_header("Tags", "white_check_mark")
                if tok:
                    req.add_header("Authorization", "Bearer " + tok)
                with urllib.request.urlopen(req, timeout=10) as r:
                    st = r.status
                audit(who, "notify test", st == 200, "ntfy HTTP %s" % st)
                return self.send(200 if st == 200 else 500, {"ok": st == 200, "output": "ntfy HTTP %s → %s" % (st, n["topic"])})
            if path == "/topology/refresh":
                before = ""
                try:
                    before = json.load(open(TOPOLOGY))["meta"]["updated"]
                except Exception:
                    pass
                rc, out = sh(["systemctl", "start", "hatch-topology-gen.service"], timeout=35)
                after = before
                for _ in range(20):
                    try:
                        after = json.load(open(TOPOLOGY))["meta"]["updated"]
                    except Exception:
                        pass
                    if after != before:
                        break
                    time.sleep(0.5)
                audit(who, "topology refresh", rc == 0, "updated %s" % after)
                return self.send(200 if rc == 0 else 500, {"ok": rc == 0, "updated": after, "output": out or "regenerated",
                                                            "error": None if rc == 0 else out})
        except Exception as e:
            audit(who, "POST " + path, False, str(e))
            return self.send(500, {"ok": False, "error": str(e)})
        self.send(404, {"ok": False, "error": "not found"})


def main():
    cfg = load_config()
    if not load_token():
        print("no token at %s — run install.sh" % TOKEN_FILE, file=sys.stderr)
        sys.exit(2)
    bind, port = cfg.get("bind", "127.0.0.1"), int(cfg.get("port", 8771))
    srv = ThreadingHTTPServer((bind, port), Handler)
    srv.daemon_threads = True
    audit("system", "service start", True, "%s:%d" % (bind, port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
