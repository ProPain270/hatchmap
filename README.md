# HatchMap

HatchMap is a native macOS (SwiftUI) control plane for a self-hosted homelab, paired with a
Flutter Android client and a small Python backend. It merges a live service-topology map
(Proxmox hosts, LXCs, Docker containers, storage runway forecasts) with an on-device network
intelligence engine that attributes traffic to devices and destinations from tcpdump DNS,
TLS-name, mDNS and DHCP sniffing, identifies hardware by MAC vendor and announced services,
and flags threats against public blocklists. Remote actions go through a token-protected
service reachable only over Tailscale, with allow-listed commands and an audit log. All
clients share one versioned JSON contract with tolerant decoding and explicit freshness
states, so the UI never shows stale data as live.

## Features

**Topology map**
- Tiered card grid of hosts, LXCs, VMs, containers, storage and guards, with a detail panel
  per node (state history, flap warning, storage runway in days from a least-squares fit).
- Problems-first Overview: down/degraded nodes, disks over threshold, SITREP cards, stale
  feed, confirmed threats and unrecognised devices, then a "since you last looked" diff.
- Every live view carries a freshness pill (Live / Stale / Offline / Paused); the last good
  payload is kept and labelled, never cleared.

**NetSight engine** (on-device, no cloud)
- Six `tcpdump` sniffers (flows, DNS x2, mDNS, TLS SNI, DHCP) attribute traffic to the
  device that asked and the site it asked for.
- Device identity from MAC vendor (IEEE OUI), DHCP hostname/OS hints, announced mDNS
  services and open ports; identities merge across LAN IPv4, link-local IPv6 and tailnet
  addresses.
- Threat-feed matching against public blocklists (exact-indicator hits are "confirmed";
  heuristics such as plaintext HTTP, unusual ports, new devices and large uploads stay in a
  separate "review" tier).
- Anomaly flags, per-device site history with retention, subnet scan with port fingerprints,
  SSH collectors so a gateway can feed the capture, and a natural-language "Ask" view.

**Remote actions over Tailscale**
- Container start/stop/restart, allow-listed systemd units, topology refresh, Proxmox guest
  start/shutdown/reboot, one-click SSH into any host on the map.
- Every action is confirmed in the UI, token-authenticated, and logged on both ends.

**Alerts and export**
- ntfy push from the server side (so the phone is notified even when the Mac sleeps) with
  per-event rules editable from the app; macOS notifications mirror the same transitions.
- Export any dataset as JSON, CSV, Markdown, HTML or PDF (Core Graphics, paginated).

## Architecture

```
 server (Proxmox LXC or any Linux box)                     Mac
 +---------------------------------------------+            +---------------------------+
 | topology generator  -> topology.json        |  :8443 TLS |  HatchMap.app (SwiftUI)   |
 | hatch-notify.path    -> diff -> ntfy push   | ---------> |   map · NetSight · actions|
 | hatch-actions.service (127.0.0.1, token)    |  :8771 TLS |   sudo tcpdump sniffers   |
 +---------------------------------------------+ <--------- |   ssh / Proxmox API       |
   published with `tailscale serve` (tailnet only)           +---------------------------+
                                                                      ^
 Proxmox API <-- least-privilege token ------------------------------+
                                                             Android (Flutter) reads the
                                                             same topology.json over Tailscale
```

- **macOS app** — `macos-swiftui/HatchMap/`, 24 Swift files, no Xcode project; built with
  `xcrun swiftc` by `macos-swiftui/build.sh`. macOS 14+.
- **Flutter client** — `flutter-mobile/hatch_map/`, polls the same feed, caches the last good
  payload, widget tests cover malformed-entry isolation and offline relaunch.
- **Python backend** — `backend/`: `hatch-actions.py` (remote-control API) and
  `hatch-notify.py` (state-change push), with their systemd units and install/uninstall
  scripts. Standard library only.
- **Contract** — `SHARED-CONTRACT.md` is the one document every client is written against:
  feed schema, action API, push rules, and what clients may derive from `meta`.

The topology generator that writes `topology.json` is specific to my own stack and is not
included; the contract documents its output so you can produce the same JSON from your own
inventory.

## Repository layout

```
macos-swiftui/            native macOS app (HatchMap/*.swift, Info.plist, AppIcon.icns, build.sh)
flutter-mobile/hatch_map/ Flutter Android client
backend/                  hatch-actions.py, hatch-notify.py, systemd/, install.sh, uninstall.sh,
                          config.example.json
tools/                    netsight-collector.sh — push-mode capture collector for a gateway
docs/                     NETSIGHT-DESIGN-SPEC.md, NetSight-v2-Vision.md
SHARED-CONTRACT.md        the JSON contract shared by every client
```

## Build

**macOS app** (Command Line Tools or Xcode, macOS 14+):

```bash
bash macos-swiftui/build.sh            # compiles with -warnings-as-errors → build/HatchMap.app, launches it
bash macos-swiftui/build.sh --no-open
```

`build.sh` probes for the newest SDK that can still compile a SwiftUI `@State` with the
Command Line Tools (the macOS 27 SDK needs a macro plugin that only ships with Xcode).
Set the topology URL, action-service URL/token and Proxmox token in Settings (⌘,). Capture
needs `sudo tcpdump`.

**Flutter client:**

```bash
cd flutter-mobile/hatch_map
flutter pub get
flutter run --dart-define=HATCH_API=https://<your-node>:8443/topology.json
flutter test
```

`build-apk.sh` builds signed split-ABI APKs and expects your own `android/key.properties`
and keystore (neither is committed).

**Backend** (python3, systemd, docker CLI, tailscale on the server):

```bash
scp -r backend root@<server-ip>:/tmp/hatch-backend
ssh root@<server-ip> 'bash /tmp/hatch-backend/install.sh'   # idempotent; keeps token + config
```

`install.sh` seeds `/etc/hatch-actions/config.json` from `config.example.json`, generates a
token at `/etc/hatch-actions/token`, drops allow-listed scripts whose unit does not exist on
the box, and publishes the port with `tailscale serve`. Copy the token to
`~/Library/Application Support/HatchMap/actions-token` on the Mac or paste it into Settings.

## Security model

- `hatch-actions` binds `127.0.0.1` and is published only by `tailscale serve`, which
  terminates TLS with the node's Tailscale certificate and admits tailnet peers only. Funnel
  is never enabled.
- Every request except `/ping` needs a bearer token (constant-time comparison). Every call is
  appended to `/var/log/hatch-actions.log` and to the app's own `actions-log.tsv`.
- Only allow-listed systemd units from `config.json` can be started; container names are
  validated against `docker ps -a`; `protected_containers` cannot be stopped. All subprocesses
  are fixed argv — no client input ever reaches a shell string.
- Proxmox power actions use a privilege-separated API token (`api@pam!hatchmap`) with a role
  limited to `VM.PowerMgmt VM.Audit Sys.Audit`; the app pins the self-signed certificate
  trust to the configured host only.
- The network engine runs locally and sends nothing anywhere; threat feeds are fetched
  read-only. SSH collectors use the keys already on your Mac.

## Status

Personal project, built and used daily on my own homelab. It is shaped by one stack and one
Mac, so expect rough edges outside that: the macOS app has no automated tests beyond a
warnings-as-errors compile, the Flutter client has no in-app endpoint setting (use
`--dart-define`), and the simulated "chaos" scenarios in the mobile client are UI demos, not
real fault injection.

## License

MIT — see [LICENSE](LICENSE).
