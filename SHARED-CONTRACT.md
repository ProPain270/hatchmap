# Hatch Map — Shared Data Contract

The macOS app (SwiftUI) and the mobile app (Flutter) render the same topology because they
read the **same JSON from the same endpoint**. HatchMap 2.0 adds two
more server-side pieces on the same box — the action API and the push notifier — documented
here so every client speaks the same language. Everything is tailnet-only.

## 1. Topology feed (schema v2 — additive)

Generator `/usr/local/sbin/hatch-topology-gen.py` probes the stack every 2 minutes
(`hatch-topology-gen.timer`) and writes `/opt/hatch-map/topology.json`; a static server
(`hatch-topology-api.service`, `127.0.0.1:8770`) serves it, published by `tailscale serve`:

```
https://your-node.your-tailnet.example:8443/topology.json   (Tailscale-issued TLS cert)
http://<tailscale-ip>:8770/topology.json                     (raw, tailnet, for curl)
http://<tailscale-ip>:8770/traffic-history.json              (7-day 5-min buckets)
```

```jsonc
{
  "meta":   { "node": "media-server", "tailnet": "…", "updated": "ISO-8601", "schema": 2 },
  "sitrep": [ { "l": "label", "v": "value", "s": "sub", "state": "ok|warn|crit" } ],
  "devices": [
    {
      "name": "Alex's Laptop",
      "kind": "laptop|phone|wearable|display|other",
      "what": "Plain description",
      "state": "online|offline|unknown",
      "via": "tailscale|manual",
      "last_seen": "Human string",
      "bluetooth": "Declared capability string or null",
      "dest": "Configured destination string or null"
    }
  ],
  "groups": [
    {
      "tier": "section title",
      "kind": "row | anchorRow | anchor | group | storage",
      "icon": "movie|magnet|lock|chart|gear|disk|shield",
      "accent": "guard",                                     // optional
      "nodes": [
        {
          "t":     "host|lxc|vm|docker|net|guard|store",     // type → colour
          "name":  "Jellyfin",
          "meta":  ":8096",                                  // ip/port/path
          "plain": "plain-English description",
          "tech":  "technical description",
          "state": "up|down|warn",
          "expo":  "funnel|tail|vpn",                        // optional
          "url":   "https://…",                              // optional
          "pct":   90,                                       // storage nodes only
          "free":  "196G",                                   // storage nodes only
          "dest":  "plain-language destination",             // schema 2 optional
          "traffic": { "up": 337602363, "down": 583233, "interval_s": 120 } // schema 2 optional
        }
      ]
    }
  ]
}
```

### Rules every client follows
- **Type → colour:** host=teal, lxc=green, vm=purple, docker=amber, guard=cyan, store=gold, net=teal.
- **Veteran toggle:** off → `plain`; on → `tech`. Persisted.
- **State dot:** up=green, warn=amber, down=red. **Exposure badge:** funnel=blue, tail=purple, vpn=red.
- **Poll:** 30 s macOS / 60 s mobile+web, plus manual refresh. `meta.updated` shows freshness.
- **Freshness pill everywhere:** any view that shows live data carries a pill —
  *Live* / *Stale · last good Nm ago* / *Offline*. Stale = last successful poll > 90 s ago.
  The app keeps the last-good payload and says so; it never clears the screen.
- **Lenient decode:** a malformed node is dropped; one bad node never kills the map.
- **Stable IDs:** positional (`g{gi}` / `n{gi}-{ni}`); never synthesised from names.
- **Unknown schema warns but renders.** **Endpoint override** lives in Settings, never code.

## 2. Action API — `hatch-actions` (new in 2.0)

`hatch-actions.service` on the server, `127.0.0.1:8771`, published as
`https://your-node.your-tailnet.example:8771` (tailnet only; Funnel never enabled).
Every request except `/ping` needs `Authorization: Bearer <token>` (token: `/etc/hatch-actions/token`).
Container names are validated against `docker ps -a`; scripts against the allow-list in
`/etc/hatch-actions/config.json`; nothing from a client ever reaches a shell string.
Every call is appended to `/var/log/hatch-actions.log` (`time who action ok detail`).

| Method | Path | Returns |
|--------|------|---------|
| GET | `/ping` | `{ok, service, version}` — no auth |
| GET | `/health` | `{ok, version, host, time, uptime_s, docker_ok, notify:{ntfy, topic, last_push, last_check, enabled}}` |
| GET | `/containers` | `{containers:[{name, state, status, image}]}` |
| POST | `/containers/<name>/start\|stop\|restart` | `{ok, output, error}` (403 for `protected_containers` unless `start`) |
| GET | `/scripts` | `{scripts:[{id, title, description, unit, match:[…], last_run, last_result, running}]}` |
| POST | `/scripts/<id>` | `{ok, output}` — `systemctl start --no-block <unit>` |
| POST | `/topology/refresh` | `{ok, updated}` — runs the generator now, waits for a new `meta.updated` |
| GET | `/log?n=100` | `{entries:[{time, who, action, ok, detail}]}` |
| GET | `/notify/config` | `{notify:{ntfy, topic, enabled, events:{…}}}` — the hatch-notify rules |
| PUT | `/notify/config` | body `{enabled?, topic?, events?:{node_down,node_up,node_warn,disk_warn,disk_crit,disk_ok,sitrep,stale}}` |
| POST | `/notify/test` | low-priority test push |

`match` lists topology node names a script backs (e.g. `backup` ↔ the Backup
node) so the detail panel can offer "Run now" on the right node. Clients treat the service like
the feed: a freshness pill (*Live · media-server* / *Stale · last reply Nm ago* /
*Unreachable*) and a confirmation dialog before every POST.

## 3. Push notifier — `hatch-notify` (new in 2.0)

`hatch-notify.path` runs `hatch-notify.py` whenever `topology.json` is rewritten (a 5-minute
timer catches a stalled generator). It diffs against `/var/lib/hatch-notify/last.json` and posts
only transitions to ntfy (`http://127.0.0.1:5000/<topic>`, default topic `hatchmap-alerts`):

| Event | Priority · tag |
|-------|----------------|
| node `→ down` / `down →` recovery / `→ warn` | high · red_circle / default · white_check_mark / default · warning |
| disk crosses 90 % / 95 % / back under 85 % | default · floppy_disk / high · rotating_light / low · white_check_mark |
| SITREP card `→ warn\|crit` and back to ok | default or high · warning/rotating_light / low |
| generator stale > 10 min (once) and recovery | default · hourglass / low |

Each event kind can be switched off in `config.json › notify.events` — the app edits that map
through `PUT /notify/config` (Settings › Alerts & Push). State for `/health` lives in
`/var/lib/hatch-notify/state.json`. The macOS app mirrors the same transitions to Notification
Center locally with its own per-event rules; the phone push never depends on the Mac.

## 4. What clients derive from `meta` (2.0)

- **SSH target:** first non-`100.x` IPv4 in `meta` (`192.0.2.10 · PVE 9.2` → `192.0.2.10`);
  a bare `.240` is completed with the /24 of another host on the map.
- **Proxmox guest:** `CT105` / `VM120` in `meta` → vmid, matched against the API's
  `cluster/resources` list.
- **Container:** node `name` normalised (lower-case, alphanumerics, text before `×`) against
  `docker ps -a` names — exact, then prefix, then contains. `exportarr ×3` → every `exportarr-*`.

Because the shape is identical and the endpoints are shared, editing the generator or the
action allow-list once updates every client on its next poll — no client changes needed.
