#!/usr/bin/env python3
"""hatch-notify — pushes topology state changes to ntfy, from the server side.

Runs from a systemd timer right after each hatch-topology-gen run. Diffs the fresh
/opt/hatch-map/topology.json against the last one it saw and posts only transitions:
  • a node going down / coming back / degrading
  • a disk crossing 90 % or 95 % (and recovering below 85 %)
  • a SITREP card turning warn/crit (and back to ok)
  • the generator itself going stale (topology older than 10 min) — once
Because it runs on the server, the phone gets the push whether or not the Mac is awake.
Config lives in /etc/hatch-actions/config.json under "notify".
"""
import json, os, sys, urllib.request
from datetime import datetime, timezone

CONF = "/etc/hatch-actions/config.json"
TOPOLOGY = "/opt/hatch-map/topology.json"
STATE_DIR = "/var/lib/hatch-notify"
LAST = os.path.join(STATE_DIR, "last.json")
STATE = os.path.join(STATE_DIR, "state.json")


def now():
    return datetime.now(timezone.utc)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def snapshot(t):
    nodes, sit = {}, {}
    for g in t.get("groups", []):
        for n in g.get("nodes", []):
            nodes["%s/%s" % (g.get("tier", ""), n.get("name", ""))] = {"state": n.get("state", "up"), "pct": n.get("pct"), "free": n.get("free")}
    for s in t.get("sitrep", []):
        sit[s.get("l", "")] = {"state": s.get("state", s.get("c", "ok")), "v": s.get("v", "")}
    return {"nodes": nodes, "sitrep": sit, "updated": t.get("meta", {}).get("updated", "")}


def diff(a, b):
    """(kind, title, message, priority, tags) tuples for what changed between snapshots a → b."""
    out = []
    for key, nb in b["nodes"].items():
        na = a["nodes"].get(key)
        name = key.split("/")[-1]
        if na is None:
            continue
        if na["state"] != nb["state"]:
            if nb["state"] == "down":
                out.append(("node_down", "%s is DOWN" % name, "%s went %s → down" % (key, na["state"]), "high", "red_circle"))
            elif na["state"] == "down":
                out.append(("node_up", "%s is back up" % name, "%s recovered (down → %s)" % (key, nb["state"]), "default", "white_check_mark"))
            elif nb["state"] == "warn":
                out.append(("node_warn", "%s degraded" % name, "%s state %s → warn" % (key, na["state"]), "default", "warning"))
        pa, pb = na.get("pct"), nb.get("pct")
        if isinstance(pa, int) and isinstance(pb, int):
            if pa < 95 <= pb:
                out.append(("disk_crit", "%s at %d%%" % (name, pb), "%s free — critical fill level" % nb.get("free", "?"), "high", "rotating_light"))
            elif pa < 90 <= pb:
                out.append(("disk_warn", "%s at %d%%" % (name, pb), "%s free — crossed 90%%" % nb.get("free", "?"), "default", "floppy_disk"))
            elif pa >= 90 > 85 >= pb:
                out.append(("disk_ok", "%s back to %d%%" % (name, pb), "%s free — pressure relieved" % nb.get("free", "?"), "low", "white_check_mark"))
    for label, sb in b["sitrep"].items():
        sa = a["sitrep"].get(label)
        if sa is None:
            continue
        if sa["state"] != sb["state"]:
            bad = sb["state"] in ("warn", "crit")
            out.append(("sitrep", "SITREP %s: %s" % (label, sb["state"]), "%s → %s · %s" % (sa["state"], sb["state"], sb["v"]),
                        "high" if sb["state"] == "crit" else ("default" if bad else "low"),
                        "rotating_light" if sb["state"] == "crit" else ("warning" if bad else "white_check_mark")))
    return out


def push(cfg, title, message, priority, tags):
    url = "%s/%s" % (cfg["ntfy"].rstrip("/"), cfg["topic"])
    req = urllib.request.Request(url, data=message.encode(), method="POST")
    req.add_header("Title", title)
    req.add_header("Priority", priority)
    req.add_header("Tags", tags)
    if cfg.get("click"):
        req.add_header("Click", cfg["click"])
    if cfg.get("token"):
        req.add_header("Authorization", "Bearer " + cfg["token"])
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def main():
    cfg = load(CONF, {}).get("notify", {})
    cfg.setdefault("ntfy", "http://127.0.0.1:5000")
    cfg.setdefault("topic", "hatchmap-alerts")
    cfg.setdefault("enabled", True)
    state = load(STATE, {})
    state.update({"ntfy": cfg["ntfy"], "topic": cfg["topic"], "enabled": cfg["enabled"], "last_check": iso(now())})
    t = load(TOPOLOGY, None)
    if t is None:
        save(STATE, state)
        return
    cur = snapshot(t)
    prev = load(LAST, None)
    events = []
    # Generator staleness — the one thing a diff can't see.
    try:
        upd = datetime.strptime(cur["updated"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        stale = (now() - upd).total_seconds() > 600
    except Exception:
        stale = False
    if stale and not state.get("stale_notified"):
        events.append(("stale", "Topology feed stale", "hatch-topology-gen hasn't updated since %s" % cur["updated"], "default", "hourglass"))
        state["stale_notified"] = True
    elif not stale and state.get("stale_notified"):
        events.append(("stale", "Topology feed recovered", "Generator is updating again", "low", "white_check_mark"))
        state["stale_notified"] = False
    if prev is not None:
        events.extend(diff(prev, cur))
    save(LAST, cur)
    sent = 0
    flags = cfg.get("events", {})
    if cfg["enabled"]:
        for kind, title, msg, pri, tags in events[:12]:
            if not flags.get(kind, True):
                continue
            try:
                push(cfg, title, msg, pri, tags)
                sent += 1
            except Exception as e:
                state["last_error"] = "%s: %s" % (iso(now()), e)
    if sent:
        state["last_push"] = iso(now())
        state["last_push_count"] = sent
    save(STATE, state)
    if events:
        print("%d event(s), %d pushed" % (len(events), sent))


if __name__ == "__main__":
    main()
