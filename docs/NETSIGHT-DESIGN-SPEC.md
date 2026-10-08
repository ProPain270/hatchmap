# NetSight — Design & Handoff Spec

Version 3.0 · 2026-07-29 · source of truth: `native/NetSight.swift` (single file)
Stack: SwiftUI + AppKit, macOS 13+, `swiftc -swift-version 5 -O -parse-as-library`, built by `native/build.sh`.

This spec is descriptive, not aspirational — every token and measurement below is what the code actually does today. If you change one, change it here too.

---

## Overview

NetSight is a passive network-visibility app for one Mac. It answers three questions, in this order of importance:

1. **What is talking on my network right now?** (Feed)
2. **What sites were visited, and from which device?** (Sites, Ask)
3. **Is any of it dangerous?** (Alerts, Policies)

The design has one job: make machine data legible to a human without dumbing it down. Three rules follow from that, and most decisions below trace back to them.

- **Aggregate before you list.** A packet capture produces hundreds of near-identical rows per minute. Every primary view therefore shows *rolled-up* entities — destinations in the Feed, brands in Sites, merged machines in Devices — with the raw rows one click underneath. The v2.8 build listed raw flows by default and read as a log file; that was the single biggest reason it failed review.

- **Machine values look like machine values.** Domains, IPs, byte counts, timestamps, and counts are always monospace. Prose is always proportional. A reader should be able to tell "data" from "explanation" without reading either.
- **Certainty is always visible.** This Mac's traffic is ground truth (the owning process is known via `lsof`); every other device is inference from network fingerprints. The UI never lets those two look the same — see the confidence badges.

---

## Layout

```
┌──────────┬────────────────────────────────────────────────┐
│ sidebar  │ viewHeader        (title + subtitle + controls) │
│ 184pt    ├────────────────────────────────────────────────┤
│ fixed    │ [captureBanner — only on capture failure]       │
│          ├────────────────────────────────────────────────┤
│ nav      │ content                                         │
│ sections │   Feed = dest list │ NowPanel / Inspector (340) │
│          │   others = single pane                          │
│ ┌──────┐ │                                                 │
│ │capture│ │                                                │
│ │ card │ │                                                 │
│ └──────┘ │                                                 │
└──────────┴────────────────────────────────────────────────┘
```

| Region | Size | Behavior |
|---|---|---|
| Window | default 1280×780, min 1100×640 | frame persisted by SwiftUI per scene |
| Sidebar | 184pt fixed | never collapses; nav is the app's primary orientation |
| Divider | 1pt `Pal.stroke` | between sidebar and content |
| View header | ~54pt tall, 16pt horizontal gutter | title + subtitle left, controls right |
| Right pane | 340pt fixed, Feed only | `NowPanel` at rest, `DetailInspector` when a flow is selected — never empty |
| Content gutter | 12pt (lists), 14pt (Sites/Ask/History) | |

**Why the sidebar is fixed:** the previous 8-tab strip gave every destination equal weight and left no room for per-view controls. Grouping into Monitor / Intelligence / Control makes the app's model legible at a glance, and frees the header row for scope and search controls that used to fight with navigation.

---

## Design Tokens

All in `enum Pal`. Contrast ratios measured against `Pal.panel` (#12151D), the most common text background.

| Token | Value | Hex | Contrast | Usage |
|---|---|---|---|---|
| `Pal.bg` | `Color(red:0.039,green:0.047,blue:0.066)` | `#0A0C11` | — | window base |
| `Pal.rail` | `0.050, 0.060, 0.084` | `#0D0F15` | — | sidebar, feed section headers |
| `Pal.panel` | `0.071, 0.084, 0.114` | `#12151D` | — | cards, panels |
| `Pal.panel2` | `0.094, 0.110, 0.148` | `#181C26` | — | raised cards, inputs |
| `Pal.stroke` | `white @ 7%` | — | — | 1pt card borders, dividers |
| `Pal.ink` | `white 0.93` | `#EDEDED` | **15.6:1** | primary text |
| `Pal.ink2` | `white 0.64` | `#A3A3A3` | **7.2:1** | secondary text, subtitles |
| `Pal.ink3` | `white 0.52` | `#858585` | **5.0:1** | timestamps, meta, section labels |
| `Pal.live` | `0.28, 0.87, 0.56` | `#47DE8F` | **10.5:1** | capture-on signal, selection, primary action |
| `Pal.info` | `0.44, 0.71, 1.00` | `#70B5FF` | **8.5:1** | informational accents |
| `Pal.warn` | `0.96, 0.68, 0.26` | `#F5AD42` | **9.5:1** | REVIEW badge, capture banner |
| `Pal.bad` | `0.97, 0.38, 0.38` | `#F76161` | **5.9:1** | MALICIOUS badge, hot alert count |
| `Pal.radius` | `8` | — | — | all card corners |

> `Pal.ink3` was `white 0.44` and measured **3.69:1** — below WCAG AA (4.5:1) for the 9.5–10.5pt text it is used for. Raised to `0.52` (5.0:1) on 2026-07-29. Do not lower it again; that tier carries timestamps and byte counts, which are exactly the values people squint at.

### Category colors (`categoryColor`)

Semantic, not decorative — the same hue identifies a category in the flow row's edge bar, the History bar chart, the Sites card glyph, and the section header dot.

| Category | Color |
|---|---|
| Ad / tracker | `0.90, 0.35, 0.35` |
| Streaming | `0.93, 0.70, 0.30` |
| Music | `0.66, 0.55, 0.95` |
| Social | `0.40, 0.65, 0.95` |
| IoT telemetry | `0.80, 0.55, 0.30` |
| Local | `0.35, 0.80, 0.62` |
| default (Web/Cloud/Apple/DNS) | `0.55, 0.75, 0.95` |

**Device color** is a hash of the IP (`deviceColor`, DJB2 → HSB hue, sat 0.55, bright 0.9). Stable per device across every view — the same dot color means the same machine in the Feed, Sites, Devices, and History.

### Typography

Two families only: system proportional for prose, **system monospace (`dataFont()`) for every machine value**.

| Role | Size / weight | Family |
|---|---|---|
| Ask hero | 19 semibold | proportional |
| Answer headline | 17 semibold | proportional |
| View title | 16 semibold | proportional |
| App name (sidebar) | 15 bold | proportional |
| Card title (device, app) | 13.5 semibold | proportional |
| Body / narrative | 12.5 | proportional |
| Nav item | 12.5 (semibold when selected) | proportional |
| **Domain / host** | **12 medium** | **mono** |
| Meta line | 11 | proportional |
| Chip, subtitle | 10.5 | proportional |
| **Byte count, hit count** | **10.5** | **mono** |
| **Timestamp** | **9.5–10** | **mono** |
| Section label | 9.5 semibold, kerning 1.2, uppercased | mono |
| Badge | 8–9 bold | mono |

### Spacing

4pt base. Common values: card padding 11, list item gap 6–8, view gutter 12–14, header gutter 16, icon-to-text 9–11.

---

## Components

| Component | Variants | State | Notes |
|---|---|---|---|
| `navItem` | selected / idle; with badge (Alerts) | selected = `Pal.live @10%` fill + `@25%` border + live icon | badge turns `Pal.bad` when a confirmed threat exists |
| `captureCard` | running / stopped | button is filled `Pal.live` when stopped (call to action), muted when running | shows `collector :9999` line only when the remote listener is up |
| `viewHeader` | per view | Feed adds scope segment + Group toggle; Feed/Devices/Apps/Alerts add search | title + subtitle from `headerCopy` |
| `captureBanner` | error only | shown when `status` starts with "Capture access denied" or "Failed" | warn-tinted, 3pt left edge, Retry re-runs `engine.start()` |
| `DestGroupRow` | named / unnamed; expanded | expanded reveals up to 12 raw `FlowRow`s on a darker ground | unnamed titles render in `ink2` and sort below every named service |
| `NowPanel` | — | live/paused dot | session total at 30pt mono, 30-min sparkline, top 6 destinations with bars, active devices |
| `FlowRow` | default / selected / quiet | quiet (`isPrivate` or DNS) renders at 0.6 opacity | selected = `Pal.live @7%` + 2pt live edge |
| `SiteBrandCard` | single / multi-subdomain (expandable) | expanded lists subdomains, then devices | tile = brand initial on `brandColor` (hash of registrable domain) |
| `SiteCard` | single-device / multi-device (expandable) | expanded shows `SiteDeviceLine` per device | used by Ask, where the specific hostnames are the answer |
| `deviceCard` | me / identified / unidentified | — | title falls back to vendor, then class, never a raw IP |
| `AppUseCard` | app (confirmed) / service (inferred) / host | expandable endpoint list | confidence badge is mandatory, see below |
| `anomalyCard` | bad / review / info | — | icon + color both encode level |
| `talkerRow` | destination / device | — | bar colored by category (destinations) or device hash (devices) |
| `chip` / `segmented` | selected / idle | selected = 10% white fill, semibold | used for device filter, day scope, sort |

### Confidence badges (`confBadge`) — do not remove

| Badge | Meaning | Color |
|---|---|---|
| `on this Mac` | ground truth — the owning process is known via `lsof` | green `0.24,0.52,0.42` |
| `inferred` | matched a service fingerprint from the domain | blue `0.32,0.44,0.72` |
| `likely` | weaker fingerprint match | violet `0.42,0.40,0.60` |
| `shared host?` | generic CDN — the specific app **cannot** be determined from the network | gray `white 0.38` |

This ladder is the app's honesty contract. A generic CDN must never be presented as a named app.

---

## Interaction

| Element | Trigger | Behavior |
|---|---|---|
| Nav item | click, or ⌘1–⌘9 | switches view, clears `deviceDetailIP`; numbers follow sidebar order top-to-bottom |
| Search | ⌘F | switches to Feed if the current view has no search field, then focuses it |
| Capture toggle | click, ⌘R (start) | start/stop; menu also has Stop, Clear ⌘K, Export CSV ⌘E |
| Destinations / Raw flows | click | Feed shape. Destinations is the default; Raw is the escape hatch |
| Destination row | click | expands its raw flows and selects the newest, so the inspector fills immediately |
| Flow row | click | selects; inspector renders the explanation |
| Section header (grouped feed) | click | collapse/expand that category |
| Site card | click | expands per-device breakdown — only when >1 device |
| Device card | click | opens `DeviceDetailView` |
| Device detail → View flows | click | sets `selectedDeviceIP`, jumps to Feed with a filter banner |
| Device detail → Block device | click | adds a `Policy`, jumps to Policies. **Simulated only** — nothing is blocked until the generated pack is deployed to the gateway |
| Ask suggestion chip | click | fills the query and runs it |
| Ask close (✕) | click | returns to the hero state |

**Motion:** none currently. Deliberate — the feed inserts rows continuously and animating insertion at that rate reads as instability. If motion is added later, restrict it to view transitions (≤150ms ease-out), never to feed rows.

---

## Content & Edge Cases

| Case | Behavior |
|---|---|
| **Empty — Feed, running** | "Waiting for traffic… / Browse something and it'll appear here." |
| **Empty — Feed, stopped** | "Press play to start capturing." |
| **Empty — Sites, today** | explains visits appear as devices look up domains (DNS + TLS) |
| **Empty — Sites, past scope** | "No sites logged for {scope}." — different copy, because "yet" is wrong for a closed day |
| **Empty — Sites, filtered** | "Nothing matches that filter." |
| **Empty — Alerts** | "No alerts. / No confirmed threats or anomalies detected." |
| **Empty — Ask** | hero state with suggestion chips; never a blank panel |
| **Ask, no site match** | states the scope and the device, then explains the vantage limit and points at the collector |
| **Long domain** | `lineLimit(1)`, truncates tail; full value is selectable in the inspector |
| **Long device name** | `lineLimit(1)` |
| **Unnamed device** | title falls back: hostname → "{vendor} device" → device class → "Unknown device". Raw IPv6 is never a title; `shortIP()` elides the middle |
| **Unidentified devices** | grouped under a header that says what to do: "run a Scan to fingerprint" |
| **Flow cap** | live feed holds 400 events; History and VisitLog accumulate past it |
| **Visit log rollover** | at midnight; `dayString` is recomputed per call, never cached at launch |
| **Missing byte counts** | byte labels are omitted entirely rather than showing "0 B" |
| **Threat feed offline** | `FeedUpdater` falls back to the cached indicator file; counts still render |
| **Unnamed destinations** | grouped by what they're doing, titled with the activity, subtitled "N unidentified hosts · HTTPS", dimmed and ranked below named services |
| **Alert relevance** | "New device" fires only for addresses absent from the persisted `known-devices.txt`, and never for link-local (`fe80:`/`169.254.`) addresses — those are the same machines under a second address |
| **Benign ports** | `BENIGN_PORTS` exempts Cloudflare Tunnel (7844), Tailscale/STUN (3478, 41641), Google/Apple push, mDNS/SSDP, Plex. Before this the badge sat at 76 and REVIEW appeared on Google and Tailscale traffic, which trains people to ignore the alert entirely |

---

## Responsive Behavior

There are no breakpoints — this is a fixed-chrome desktop app. Behavior across window sizes:

| Width | Behavior |
|---|---|
| ≥1100pt (min) | full layout; Feed = list + 400pt inspector |
| Sidebar | never scales |
| Content | absorbs all resize; lists reflow, inspector stays 400pt |

**Known gap:** at the 1100pt minimum, Feed leaves ~515pt for the flow list, which truncates long domains early. If this becomes a complaint, the fix is a collapsible inspector (toggle in the view header), not a narrower sidebar.

---

## Accessibility

| Area | Status |
|---|---|
| **Contrast** | All text tiers pass WCAG AA against `panel` and `bg` — measured, see token table. Lowest is `ink3` at 5.0:1 |
| **Labels** | Icon-only controls have `.accessibilityLabel`: capture toggle (state-aware), device-detail back, clear-search, clear-site-filter |
| **Nav** | Each nav item announces its name; the Alerts item announces its open count; selected item carries `.isSelected` |
| **Site cards** | Announce domain, visit count, volume, and device count in one string, with a hint when expandable |
| **Keyboard** | ⌘1–⌘9 views · ⌘F search · ⌘R start · ⌘K clear · ⌘E export |
| **Color independence** | Threat level is encoded by text (MALICIOUS / REVIEW) as well as color; alert level by icon shape as well as color |

**Gaps, honestly:** custom `.buttonStyle(.plain)` rows do not draw a macOS focus ring, so full keyboard traversal of lists is not supported yet — only the menu shortcuts are. Not tested with VoiceOver. Dynamic Type is not honored (sizes are fixed points).

---

## Device Profiles — passive by design

`ProfileDB` keeps one record per piece of hardware, keyed by MAC address, persisted to
`device-profiles.tsv`. **It is built exclusively from signals the network already produced:**
the ARP/NDP neighbour tables, mDNS/Bonjour announcements, DHCP requests, and the local OUI
vendor table. NetSight never pings, port-scans, or otherwise touches a device to build a
profile — active discovery stays behind the manual Scan button, and the profile card says
"passive — nothing was sent to this device" so the user knows which kind of knowledge they
are looking at.

| Field | Passive source |
|---|---|
| MAC, vendor | ARP/NDP cache + OUI table |
| Names | reverse-DNS, mDNS `<Host>.local`, DHCP option 12 |
| Model | mDNS `model=` / `am=` |
| Class, OS hint | inference over the above + announced services |
| Services | mDNS service types (`_airplay`, `_hap`, `_ipp`, …) |
| Addresses | every IP observed for that MAC |
| First / last seen | roster timestamps |

**MAC normalization is load-bearing.** `arp -a` prints octets unpadded (`0:17:88:…`) while
DHCP and mDNS give the padded form. Without `normalizeMAC()` the same card keys two
profiles, which would both mis-merge devices and fire false "unknown hardware" alerts.

**Identity merging.** `deviceInventory` merges rows on MAC where one is visible — a machine
with a LAN IPv4, a link-local IPv6, and a tailnet address is one row, not three. This is why
the Devices list went from ~25 entries to ~14 real machines on the home network.

**Unknown-hardware alert.** A MAC absent from the roster raises a `review` anomaly naming
whatever is known ("Living Room · Apple at 192.0.2.62. MAC … has never been seen on
this network before"). Suppressed during a learning window — 25s normally, **180s on first
ever run** when the roster is empty and every device would otherwise look like an intruder.
When no MAC is visible the alert says so explicitly rather than implying hardware identity.

**Honesty rules for this surface.** Never print "Unknown device" beside a known model —
`deviceTypeLine()` degrades through model → vendor → announced services → "unidentified".
Never translate a raw model code into a product name unless the mapping is certain; showing
`model J305AP` is better than guessing the wrong Apple TV generation.

## Collectors — seeing past this Mac's NIC

A collector is tcpdump running somewhere with a better view, streamed into the same ingest
path as local capture. Two transports exist; **SSH is the one that works.**

| Transport | How | Status |
|---|---|---|
| **SSH (primary)** | NetSight spawns `ssh <user>@<host> "tcpdump …"` per channel and reads stdout | Works. Nothing listens on the Mac, the stream is encrypted, auth is the user's existing keys |
| TCP push (fallback) | `netsight-collector.sh` on the box dials the Mac's `:9999` listener with a token handshake | Blocked by default on macOS — see below |

**Why push mode fails, and why it isn't a bug in the code.** macOS's application firewall
drops inbound connections to a locally-built, ad-hoc-signed binary; the allow entry is tied
to a code signature that changes on every rebuild, so `socketfilterfw` reports the app as
permitted while SYNs are silently dropped. Verified by contrast: a plain `nc -l` on the same
Mac accepted the same connection from the same host seconds later. The listener is kept for
hosts that can't be reached by key-based SSH, but the UI leads with SSH.

**Channels.** `D` = DNS (`udp port 53`), `F` = flows (`tcpdump -q`). DNS is the default and
is what makes per-device site history real: every query carries the *client's* source
address, so `VisitLog` attributes the domain to the device that asked. Flows add byte volume
and connection counts, but on a gateway mid-download that is tens of thousands of lines per
second — DNS is a few per second and is safe to leave running on router hardware.

**Two details that are load-bearing:**

- *Exclude the transport from its own capture.* The remote filter carries
  `not (host <mac> and tcp port 22)`. Without it the capture sees the stream it is producing
  and feeds on itself.
- *Kill the remote capture when the local end dies.* The remote command backgrounds tcpdump
  and then blocks on `read`; SSH closing stdin ends the wait and kills it. Before this,
  quitting NetSight left a `tcpdump` running on the server indefinitely — observed, not
  theoretical. `NSApplication.willTerminateNotification` stops all collectors too.

Proven end-to-end 2026-07-29 against a Proxmox host (192.0.2.10): DNS lookups issued on
that box appeared in NetSight as visits attributed to `192.0.2.10`, alongside this Mac's
own, with a per-device filter chip in Sites. Remote CPU cost measured at 0.0%.

## Data Contract (what the UI can and cannot claim)

The single most important constraint, and the reason for the confidence ladder:

**NetSight sniffs this Mac's NIC.** It sees, in full: this Mac's own traffic, every device's broadcast/multicast (mDNS, ARP, DHCP, SSDP), and anything routed through this Mac. It does **not** see other devices' unicast internet traffic on a switched LAN — an iPhone streaming Netflix never reaches this Mac's NIC.

Therefore:
- Per-device site history is **complete for this Mac** and **partial for everything else**.
- Any empty per-device result must say so and point at the fix (the collector), which the Ask empty state does.
- Full coverage requires `netsight-collector.sh` running on the router or a Proxmox box, streaming to the app's `:9999` listener (Scan tab). The app side is done; the deploy is owner-gated.

---

## Build & Verify

```bash
bash macos-swiftui/build.sh
```

Compiler note: the Swift type-checker times out on chained `Dictionary(grouping:).map{}.sorted{}` with `reduce`/`min`/`max` inside. Write those as plain `for` loops — this has bitten `siteRows` once already.

Runtime note: an unsigned local build doing a **synchronous** read under `~/Desktop`, `~/Documents`, or `~/Downloads` triggers a TCC prompt that blocks the read — on the capture thread it silently freezes ingest, on the main thread it stops the window appearing. All app data therefore lives in `~/Library/Application Support/NetSight/`.

Testing note: `NSHomeDirectory()` on macOS resolves via `getpwuid`, **not** `$HOME`. Overriding `HOME` does not isolate a test harness — it will write straight into the real `~/Library/Application Support/NetSight/` and pollute the visit history. To test against synthetic data, parameterize the directory explicitly.
