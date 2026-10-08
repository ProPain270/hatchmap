# NetSight v2 — Product Vision & Feature Brainstorm

**The 10x leap in one line:** v1 is a *live packet ticker* that says "something talked to an IP." v2 is a **network intelligence console** that says **who** did it (which device), **what** did it (which app), **where** it went (org, country), **why** it matters (category + risk), and lets you **filter, chart, alert on, and export** all of it — with real menus, saved views, history, and a menu-bar mini-mode.

| | v1 (today) | v2 (this vision) |
|---|---|---|
| Identity | Raw IP + port | Device name, app + icon, domain, org/ASN, country, category |
| Views | One live list | Feed · Devices · Apps · Map · Timeline · Alerts · Inspector |
| Filtering | None | Filter bar, live search, saved smart views, BPF capture filters |
| Menus | One toggle | Full menu bar + submenus + right-click context menus + menu-bar extra |
| Memory | 200 rows in RAM | SQLite history, trends, sessions, export (CSV/JSON/PCAP/PDF) |
| Intelligence | Local vs public | Bandwidth accounting, rules engine, new-device & threat alerts |
| Settings | Hardcoded | Full Preferences: interfaces, capture filters, enrichment, retention, theme, notifications, privacy |

---

## The four pillars of identity

Every flow in v2 is enriched along four axes. This is the heart of the upgrade.

### 1. WHO — Device intelligence
Turn `192.0.2.161` into **"Living Room Apple TV."**

- **Discovery sources:** ARP table (`arp -a`), mDNS/Bonjour (`NWBrowser`), DHCP hostnames, reverse DNS, and passive learning from captured traffic.
- **MAC → vendor:** bundled IEEE OUI database → "Apple", "Amazon (Echo)", "Google Nest", "Samsung", "Ring", "Sonos".
- **Device-type inference:** vendor + hostname + behavior + open ports → phone / laptop / TV / speaker / camera / printer / console / IoT / router.
- **Per-device dashboard:** what each device talks to, its top destinations, bandwidth, first-seen/last-seen, category mix.
- **New-device detection:** notify when an unrecognized MAC joins the network ("New device: unknown Espressif/IoT at 192.0.2.212").
- **Device labels & icons:** you rename them once ("Kids' iPad"), NetSight remembers.

### 2. WHAT — Application attribution
Turn a connection into **"Spotify"** or **"Google Chrome — youtube.com tab."**

- **Local process mapping:** correlate each socket to its owning PID/app via `lsof -i -n -P` (fast, approximate) — resolve to app name + **bundle icon**.
- **The proper way:** a **NetworkExtension content filter** (`NEFilterDataProvider`) gives real-time, per-flow app attribution by bundle ID with **no sudo needed** — the macOS-blessed path. (Bigger lift; needs a signed helper.)
- **Per-app rollups:** "Chrome opened 240 connections to 38 orgs," "Dropbox uploaded 1.2 GB," "this app phones home to 5 trackers."
- **App icons** shown directly on cards and in an **Apps view**.

### 3. WHERE — Destination enrichment
Turn `17.253.144.10` into **"Apple · Cupertino, US · AS714."**

- **Names:** live **DNS capture** (already sniffing UDP 53) builds an IP↔hostname map; **TLS SNI** extraction from the ClientHello names HTTPS destinations even without a matching DNS lookup; reverse DNS (PTR) as fallback.
- **GeoIP + ASN:** bundled offline database (MaxMind GeoLite2 / DB-IP / Team Cymru IP-to-ASN) → country, city, **organization** ("Cloudflare", "Google", "Akamai"). Zero external calls — fully local.
- **Country flags** and org logos/favicons on cards.

### 4. WHY — Intent & risk
Turn a flow into **"Streaming (Netflix)"** or **"⚠ Ad/Tracker"** or **"⛔ Known-bad IP."**

- **Category tagging:** Streaming, Social, Cloud/Sync, Gaming, Email, Ads/Trackers, IoT/Telemetry, Software Update, VPN/Proxy, DNS, Unknown — from domain lists + ASN.
- **Confirmed-bad matching (high-confidence only):** every public IP/domain is checked against curated, trusted threat feeds — abuse.ch (ThreatFox / URLhaus / Feodo C2), Spamhaus DROP, known phishing/botnet lists, Tor exit nodes. A hit is an *exact match on a known indicator*, so it's flagged **Confirmed malicious** with the evidence shown; heuristics stay in a separate **Suspicious — review** tier (full model in the Threat-detection section).
- **Plain-English++:** the v1 translator, now enriched ("Your Apple TV is streaming from Netflix's CDN (Akamai, US) — normal.").

### 5. Direction & origin — who's talking to whom, and which way
Every flow answers "is this me, a local device, or someone else — and is it going out or coming in?"

- **Direction** (from the first packet / TCP SYN — whoever initiated): `↑ Outbound` (I started it), `↓ Inbound` (they connected to me), `↔ Local` (device-to-device on my LAN), `⇢ Observed` (between two other parties I can see).
- **Each party tagged:** `Me` (one of this Mac's own interface IPs), `Local · <device name>` (another box on my subnet), or `External · <org, country>` (public internet). NetSight knows its own IPs and the local subnet, so it labels both ends.
- **So a card reads:** "↑ Outbound — Me (MacBook Pro) → External (Google, US)" · "↓ Inbound — External (unknown, RU) → Me" · "↔ Local — Apple TV → MacBook Pro."
- Powers the filters that actually matter: "inbound from external only," "anything not started by me."

---

## Filtering & search system

- **Filter bar** across the top: chips for Scope (Local/Public), Protocol (TCP/UDP/QUIC/ICMP), Direction (In/Out), Device, App, Category, Country, Org, Port, Badge.
- **Live search** — type anything (IP, domain, app, device, org) and the feed narrows instantly.
- **Saved smart views:** "Public only", "This device only", "Ads & trackers", "Unusual ports", "New/unknown destinations", "Top bandwidth". One click.
- **Quick toggles:** Hide local chatter (mDNS/ARP/broadcast), Hide known-good, Alerts only, Pause auto-scroll.
- **BPF capture filters:** limit capture *at the source* (by host/port/net) via tcpdump's filter expression — lighter and more private than filtering after the fact.

---

## Menus, submenus & context menus

### Native menu bar
- **NetSight** — About · Check for Enrichment DB Updates · Preferences (⌘,) · Quit
- **File** — New Session · Open Session… · Save Session · Export ▸ (CSV · JSON · PCAP · PDF Report) · Import Blocklist…
- **Capture** — Start (⌘R) · Stop · Pause · Clear (⌘K) · Interface ▸ (en0 Wi-Fi · en1 Ethernet · utun VPN · All) · Capture Filter (BPF)… · Promiscuous Mode
- **View** — Live Feed · Devices · Apps · Map · Timeline · Alerts · DNS Log ‖ Consumer / Veteran ‖ Group by ▸ (Device · App · Domain · Country · Category) ‖ Sort by ▸ (Time · Bytes · Connections) ‖ Density ▸ (Comfortable · Compact) ‖ Theme ▸ (Dark · Light · System)
- **Filters** — Saved Views ▸ (…) · Manage Rules… · Clear All Filters
- **Tools** — WHOIS Lookup… · Ping/Traceroute… · Reverse-DNS Batch · Update OUI/GeoIP DBs
- **Window / Help**

### Right-click context menu (on any flow)
Copy IP · Copy Domain · WHOIS · Reverse-DNS · Open in Browser · **Show all from this Device** · **Show all from this App** · Always Hide this Domain · Add to Allowlist / Blocklist · **Block this IP (pf firewall)** · Explain this Connection

### Menu-bar extra (status item)
A tiny always-on indicator: ↑↓ live bandwidth, top talker, connection count. Click for a **popover mini-feed**, quick Pause, and "Open NetSight." (macOS `MenuBarExtra`.)

---

## Views & visualizations

- **Live Feed** — enriched cards: app icon · device name · domain · org · country flag · bytes · category badge · sparkline. Consumer/Veteran toggle preserved.
- **Devices** — every device as a tile: name, type icon, current activity, bandwidth, alert dot. Drill into a per-device dashboard.
- **Apps** — per-app breakdown with icons: connections, data, destinations, tracker count.
- **Map** — **real** GeoIP arcs on a globe/map (fixing v1's random endpoints) with live animated routes and top-country ranking. (MapKit or a SceneKit globe.)
- **Timeline** — bandwidth over time, connections/sec, stacked-area by category (Swift Charts).
- **Top Talkers** — leaderboards by destination / app / device / country.
- **Connection Inspector** — click a flow for a full detail panel: all four pillars, packet timeline, byte counts, history of this pair, related flows.
- **DNS Log** — every resolved name, who asked, when.
- **Alerts** — a running list of rule hits and security events.

---

## Bandwidth & accounting
- Per-flow byte counts (tcpdump reports packet lengths) rolled up per device / app / domain / category.
- Live up/down rates, session totals, daily/monthly usage, optional **data-cap tracking** with a progress ring.

## Threat detection — confirmed vs. suspicious (no false alarms)
The rule: only ever shout "malicious" when it's *actually confirmed*. Two clearly separated tiers make a real threat unmistakable and keep everything else quiet.

- **Confirmed malicious (red, instant):** the remote IP/domain is an **exact match** to a curated, trusted known-bad feed — abuse.ch ThreatFox/URLhaus/Feodo (C2 + malware), Spamhaus DROP/EDROP, known phishing and botnet lists, Tor exit nodes. Matching runs against local in-memory sets, so it fires the instant the packet is seen. Every alert **shows its evidence and source** ("listed on abuse.ch ThreatFox 2026-07-20 · tag: Cobalt Strike C2") — verifiable, never a black box. Feeds auto-update; you choose which to trust.
- **Suspicious — review (amber, never labelled "confirmed"):** heuristics worth a look but not proof — new/unknown destination, non-standard port, plaintext HTTP carrying credential-shaped data, beaconing (regular tiny call-outs), a device suddenly fanning out to many hosts, traffic to a country you never contact. Kept separate, always called "review."
- **Everything else stays green.** No guessing, no crying wolf.

## Rules & alerts
- **Rules engine** (if → notify / log / highlight / block): any Confirmed-malicious hit · new device joins · inbound from external · traffic to country X · unusual port · data-exfil-looking spike.
- **Native notifications** (`UNUserNotificationCenter`) + an **Alerts** view + optional sound. By default only Confirmed-malicious and new-device events notify, so an alert always means something.

## Active network scan (manual, on-demand)
Passive capture shows what's *talking*; a scan shows what's *there and exposed*. Runs only when you press **Scan network** — scoped to your own subnet.

- **Host discovery:** ARP + ping sweep of your subnet (e.g. 192.0.2.0/24) → every live device, even the quiet ones.
- **Port + service scan:** probe common TCP ports per host → open services (SSH, HTTP, RDP, SMB, UPnP, telnet…), with banners and mDNS/Bonjour service names.
- **Fingerprint:** MAC vendor, hostname, inferred device type and OS hints.
- **Exposure report:** a device inventory flagged for risky exposure ("Camera at .212 has telnet/23 and an unauthenticated web UI"), plus anything new since the last scan.
- **How:** drives `nmap` if installed (deep), else a built-in native scanner (`NWConnection` probes + ARP). On-demand only, your subnet only.

## History, data & export
- **Local SQLite** (GRDB.swift) stores flows → searchable history, trends, and reopenable **sessions**.
- **Export:** CSV / JSON for analysis, **PCAP** for Wireshark, **PDF** "network report."
- **Reports:** auto weekly summary — "Your network this week: 47 devices, 2.1M flows, top app Chrome, 3 new devices, 12k tracker hits blocked-worthy."

## Settings / Preferences (full pane)
- **Capture:** interface(s), BPF filter, ignore broadcast/mDNS/ARP, promiscuous mode, sampling.
- **Enrichment:** toggle DNS / SNI / reverse-DNS / GeoIP / ASN / app-attribution; DB auto-update cadence.
- **Devices:** manage names/labels, known-device list, new-device alerting.
- **Alerts & Rules:** rule editor, notification style, sounds, thresholds.
- **Appearance:** theme (dark/light/system), density, font, card fields to show/hide.
- **Storage:** retention window, max DB size, auto-prune, export defaults.
- **Privacy:** local-only guarantee, redact IPs in exports, **auto-pause during screen share**, panic clear.
- **Performance:** max visible rows, refresh rate, capture buffer size.
- **Blocklists/Allowlists:** import/manage ad, tracker, and threat lists.

---

## Architecture upgrades (to support all of the above)
- **Capture layer:** keep tcpdump/libpcap for breadth, add a **NetworkExtension** path for no-sudo capture + native app attribution.
- **UI:** SwiftUI multi-pane (sidebar + content + inspector) with a toolbar and proper document model.
- **Data:** GRDB/SQLite for persistence and fast queries; an in-memory index for the live feed.
- **Charts:** Swift Charts. **Map:** MapKit or SceneKit globe. **Menu bar:** `MenuBarExtra`.
- **Enrichment services:** background actors for DNS/SNI parsing, GeoIP/ASN lookups, OUI vendor lookups, category/reputation matching — all offline.

---

## Phased roadmap (what to build, in order)

**v2.0 — "Identity" (the core 10x, highest value first)**
1. **Direction + origin** — inbound/outbound and Me / Local / External on every flow (cheap, huge clarity).
2. Live **DNS + TLS SNI** naming → real domains on every card.
2. **GeoIP/ASN/org** enrichment (offline DB) + country flags.
3. **Device discovery + MAC-vendor naming** → "who."
4. **App attribution via lsof** → "what" (with icons).
5. **Filter bar + live search + saved views.**
6. **Full menu bar + context menus + Preferences window.**

**v2.1 — "Views & memory"**
7. Devices view, Apps view, Connection Inspector.
8. SQLite history + sessions + CSV/PCAP export.
9. Bandwidth accounting + Timeline charts.
10. Menu-bar extra mini-mode.

**v2.2 — "Intelligence"**
11. **Confirmed-vs-suspicious threat detection** — trusted known-bad feeds, evidence shown, no false alarms.
12. **Active network scan** (manual) + rules engine + notifications + Alerts view.
13. Real GeoIP Map view.
14. Weekly PDF reports.

**v2.3 — "Pro"**
15. NetworkExtension capture (no sudo) + true per-app attribution.
16. Block-this-IP via pf, allow/blocklists.
17. Command palette (⌘K), theming, onboarding.

---

## My recommendation for the first build
Ship **v2.0 items 1–4** first — DNS/SNI names + GeoIP/org + device names + app attribution. That single pass is what makes NetSight feel 10x: every card goes from `192.0.2.153 → 34.149.66.165:443` to **"MacBook Pro · Chrome → youtube.com · Google, US · Streaming."** Filters and menus (items 5–6) come right after and make it feel like a real Mac app. Say the word and I'll start on that pass.
