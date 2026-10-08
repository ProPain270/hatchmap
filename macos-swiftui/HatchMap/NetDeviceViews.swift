import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - App / service usage aggregation (which app, doing what, to where)

struct EndpointUse: Identifiable {
    let id = UUID()
    let label: String
    let purpose: String
    let category: String
    let bytes: Int
    let country: String
}

struct AppUse: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let subtitle: String
    let kind: String        // "app" (confirmed on Mac) | "service" (inferred) | "host"
    let flows: Int
    let bytes: Int
    let trackers: Int
    let endpoints: [EndpointUse]
    let conf: String
    let plaintext: Bool
    let countries: [String]
}

func appUsages(_ events: [TrafficEvent]) -> [AppUse] {
    struct Agg { var flows = 0; var bytes = 0; var trackers = 0; var icon = "globe"; var subtitle = ""; var kind = "host"; var conf = ""; var plain = false; var eps: [String: EndpointUse] = [:]; var countries: Set<String> = [] }
    var groups: [String: Agg] = [:]
    for e in events where !e.isPrivate {
        var key = ""; var icon = "globe"; var subtitle = ""; var kind = "host"; var conf = "likely"
        if let ai = appInfoOf(e) {
            key = ai.display; icon = ai.icon
            subtitle = ai.signature.isEmpty ? ai.role.capitalized : ai.signature
            kind = "app"; conf = "confirmed"
        } else if !e.app.isEmpty {
            key = e.app; icon = "app.dashed"; subtitle = "Process"; kind = "app"; conf = "confirmed"
        } else if let s = serviceOf(e) {
            key = s.name; icon = s.icon
            subtitle = s.vendor.isEmpty ? "Inferred service" : s.vendor
            kind = "service"; conf = s.confidence
        } else {
            let bh = bestHost(e); key = e.org.isEmpty ? (bh.isEmpty ? e.dst : bh) : e.org
            icon = "globe"; subtitle = "Endpoint"; kind = "host"; conf = "likely"
        }
        var g = groups[key] ?? Agg()
        let vol = volumeOf(e).total
        g.flows += 1; g.bytes += vol; g.icon = icon; g.subtitle = subtitle; g.kind = kind
        if g.conf.isEmpty { g.conf = conf }
        if e.category == "Ad / tracker" { g.trackers += 1 }
        if e.servicePort == 80 || e.servicePort == 23 || e.servicePort == 21 { g.plain = true }
        if !e.country.isEmpty { g.countries.insert(e.country) }
        let epLabel: String
        if let s = serviceOf(e) { epLabel = s.name } else { let bh = bestHost(e); epLabel = bh.isEmpty ? e.dst : bh }
        if let ep = g.eps[epLabel] {
            g.eps[epLabel] = EndpointUse(label: ep.label, purpose: ep.purpose, category: ep.category, bytes: ep.bytes + vol, country: ep.country)
        } else {
            g.eps[epLabel] = EndpointUse(label: epLabel, purpose: activityOf(e).headline, category: e.category, bytes: vol, country: e.country)
        }
        groups[key] = g
    }
    return groups.map { (name, g) in
        AppUse(name: name, icon: g.icon, subtitle: g.subtitle, kind: g.kind, flows: g.flows, bytes: g.bytes,
               trackers: g.trackers, endpoints: g.eps.values.sorted { $0.bytes > $1.bytes },
               conf: g.conf, plaintext: g.plain, countries: g.countries.sorted())
    }.sorted { $0.bytes == $1.bytes ? $0.flows > $1.flows : $0.bytes > $1.bytes }
}

func confBadge(_ kind: String, _ conf: String) -> some View {
    let txt: String; let col: Color
    if kind == "app" { txt = "on this Mac"; col = Color(red: 0.24, green: 0.52, blue: 0.42) }
    else if conf == "generic" { txt = "shared host?"; col = Pal.ink3 }
    else if conf == "confirmed" { txt = "inferred"; col = Color(red: 0.32, green: 0.44, blue: 0.72) }
    else { txt = "likely"; col = Color(red: 0.42, green: 0.40, blue: 0.60) }
    return Text(txt).font(.system(size: 8.5, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
        .background(col).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
}

struct EndpointRow: View {
    let ep: EndpointUse
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(categoryColor(ep.category)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(ep.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.ink).lineLimit(1)
                Text(ep.purpose + (ep.country.isEmpty ? "" : " · \(ep.country)") + " · " + ep.category)
                    .font(.system(size: 10)).foregroundStyle(Pal.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            if ep.bytes > 0 { Text(fmtBytes(ep.bytes)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.ink3) }
        }.padding(.vertical, 4)
    }
}

struct AppUseCard: View {
    let a: AppUse
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { open.toggle() }) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)).frame(width: 36, height: 36)
                        Image(systemName: a.icon).font(.system(size: 16)).foregroundStyle(Pal.info)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Pal.ink).lineLimit(1)
                            confBadge(a.kind, a.conf)
                            if a.trackers > 0 {
                                Text("\(a.trackers) tracker\(a.trackers == 1 ? "" : "s")").font(.system(size: 8.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color(red: 0.55, green: 0.28, blue: 0.28)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            if a.plaintext {
                                Text("plaintext").font(.system(size: 8.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color(red: 0.6, green: 0.45, blue: 0.15)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        Text(subtitleLine).font(.system(size: 10.5)).foregroundStyle(Pal.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        if a.bytes > 0 { Text(fmtBytes(a.bytes)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.ink) }
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                    }
                }.padding(11).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                Divider().background(Color.primary.opacity(0.06)).padding(.horizontal, 11)
                VStack(spacing: 0) { ForEach(a.endpoints) { ep in EndpointRow(ep: ep) } }
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 9)
            }
        }.background(Pal.panel).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var subtitleLine: String {
        var s = [a.subtitle]
        s.append("\(a.flows) flows · \(a.endpoints.count) endpoint\(a.endpoints.count == 1 ? "" : "s")")
        if !a.countries.isEmpty { s.append(a.countries.joined(separator: ", ")) }
        return s.joined(separator: " · ")
    }
}

struct DeviceDetailView: View {
    @ObservedObject var engine: CaptureEngine
    let ip: String
    private var typeLine: String {
        let meta = resolveDevice(ip)
        guard meta.type == "Unknown device" || meta.type.isEmpty else { return meta.type }
        if let p = ProfileDB.shared.profile(ip: ip) {
            if !p.model.isEmpty { return "model \(p.model)" }
            if !p.vendor.isEmpty { return "\(p.vendor) hardware" }
        }
        return "unidentified"
    }
    var body: some View {
        let meta = resolveDevice(ip)
        let dc = deviceClass(ip)
        let evs = engine.events.filter { $0.src == ip || $0.dst == ip }
        let apps = appUsages(evs)
        let localCount = evs.filter { $0.isPrivate }.count
        let totalBytes = evs.reduce(0) { $0 + volumeOf($1).total }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: { engine.deviceDetailIP = "" }) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.ink2)
                        .padding(8).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel("Back to all devices")
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(deviceColor(ip).opacity(0.18)).frame(width: 44, height: 44)
                    Image(systemName: meta.icon).font(.system(size: 20)).foregroundStyle(deviceColor(ip))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(meta.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.ink)
                        if meta.isMe {
                            Text("you").font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Pal.live.opacity(0.2)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if dc.klass != "Unknown" { classChip(dc.klass) }
                    }
                    Text("\(dc.klass)\((dc.os == "—" || dc.os.isEmpty) ? "" : " · \(dc.os)")  ·  \(typeLine)\(meta.vendor.isEmpty ? "" : " · \(meta.vendor)") · \(ip)").font(.system(size: 11.5)).foregroundStyle(Pal.ink3)
                    Text("\(apps.count) apps/services · \(fmtBytes(totalBytes)) · \(localCount) local flows").font(.system(size: 10.5)).foregroundStyle(Pal.ink3)
                }
                Spacer()
                if !meta.isMe {
                    Button(action: {
                        PolicyStore.shared.add(Policy(name: "Block \(meta.name)", targetIP: ip, matchCategory: "", matchHost: "", action: "block", afterHour: -1, enabled: true))
                        engine.deviceDetailIP = ""; engine.selectedView = "Policies"
                    }) {
                        Text("Block device").font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Pal.bad.opacity(0.28)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Button(action: { engine.selectedDeviceIP = ip; engine.deviceDetailIP = ""; engine.selectedView = "Feed" }) {
                    Text("View flows").font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Pal.info.opacity(0.25)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }.padding(14)
            Divider().background(Color.primary.opacity(0.08))
            HStack(spacing: 6) {
                Image(systemName: meta.isMe ? "checkmark.seal.fill" : "info.circle").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                Text(meta.isMe
                     ? "Ground truth: apps below are the real processes on this Mac that own each connection."
                     : "This device doesn't expose its app list — apps below are inferred from the domains it contacts.")
                    .font(.system(size: 10.5)).foregroundStyle(Pal.ink3).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 8)
            if let p = ProfileDB.shared.profile(ip: ip) { profileCard(p).padding(.horizontal, 12).padding(.bottom, 4) }
            if apps.isEmpty {
                VStack { Spacer()
                    Text("No external app traffic captured for this device yet.\nGive it a moment, or use it (open an app on it).")
                        .multilineTextAlignment(.center).foregroundStyle(Pal.ink3).font(.system(size: 12.5)).lineSpacing(3)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 8) { ForEach(apps) { a in AppUseCard(a: a) } }.padding(12) }
            }
        }
    }

    /// Everything known about the hardware without touching it — no probe was sent to build this.
    private func profileCard(_ p: DeviceProfile) -> some View {
        var facts: [(String, String)] = []
        facts.append(("Hardware", p.mac.isEmpty ? "MAC not visible from this Mac" : p.mac))
        if !p.vendor.isEmpty { facts.append(("Vendor (OUI)", p.vendor)) }
        if !p.model.isEmpty { facts.append(("Model", p.model)) }
        if !p.os.isEmpty { facts.append(("OS hint", p.os)) }
        if p.names.count > 1 { facts.append(("Names seen", p.names.sorted().joined(separator: ", "))) }
        if p.ips.count > 1 { facts.append(("Addresses", p.ips.sorted().joined(separator: ", "))) }
        if !p.services.isEmpty { facts.append(("Announces", p.services.sorted().joined(separator: ", "))) }
        facts.append(("First seen", "\(relativeDay(p.firstSeen)) at \(clockTime(p.firstSeen))"))
        facts.append(("Last seen", "\(relativeDay(p.lastSeen)) at \(clockTime(p.lastSeen))"))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                sectionLabel("Profile")
                if p.isNew {
                    Text("NEW").font(dataFont(8.5, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Pal.warn).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text("passive — nothing was sent to this device").font(.system(size: 9.5)).foregroundStyle(Pal.ink3)
            }
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                    HStack(alignment: .top, spacing: 10) {
                        Text(f.0).font(.system(size: 10.5)).foregroundStyle(Pal.ink3).frame(width: 96, alignment: .leading)
                        Text(f.1).font(f.0 == "Hardware" || f.0 == "Addresses" ? dataFont(10.5) : .system(size: 11))
                            .foregroundStyle(Pal.ink2).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.padding(.vertical, 4)
                    if i < facts.count - 1 { Divider() }
                }
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

func displayDeviceTitle(_ d: DeviceRow) -> String {
    if d.name != d.ip { return d.name }
    // The profile may hold a name announced on one of the device's other addresses.
    if let p = ProfileDB.shared.profile(ip: d.ip) {
        let n = p.bestName
        if n != d.ip && !n.hasPrefix("Unknown") { return n }
    }
    if !d.vendor.isEmpty { return "\(d.vendor) device" }
    if d.klass != "Unknown" { return d.klass }
    // Never render a column of identical "Unknown device" rows — the address at least distinguishes them.
    return shortIP(d.ip)
}
/// "Unknown device" next to a known hardware model reads as a contradiction.
/// Say what was actually announced instead — without inventing a product name for a code.
func deviceTypeLine(_ d: DeviceRow) -> String {
    guard d.type == "Unknown device" || d.type.isEmpty else { return d.type }
    if let p = ProfileDB.shared.profile(ip: d.ip) {
        if !p.model.isEmpty { return "model \(p.model)" }
        if !p.vendor.isEmpty { return "\(p.vendor) hardware" }
        if !p.services.isEmpty {
            let pretty = p.services.sorted().prefix(2)
                .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }.joined(separator: ", ")
            return "announces \(pretty)"
        }
        if p.mac.isEmpty { return "no hardware address visible" }
    }
    return "unidentified"
}

func shortIP(_ ip: String) -> String {
    if ip.contains(":") && ip.count > 18 { return String(ip.prefix(9)) + "…" + String(ip.suffix(4)) }
    return ip
}

struct DevicesView: View {
    @ObservedObject var engine: CaptureEngine
    @EnvironmentObject private var options: Options
    var body: some View {
        var inv = engine.deviceInventory
        if options.devHideUnidentified { inv = inv.filter { $0.isMe || $0.name != $0.ip || ProfileDB.shared.profile(ip: $0.ip)?.bestName.hasPrefix("Unknown") == false } }
        if options.devNewOnly { inv = inv.filter { $0.isMe || (ProfileDB.shared.profile(ip: $0.ip)?.isNew ?? false) } }
        switch options.devSort {
        case "name": inv.sort { displayDeviceTitle($0).localizedCaseInsensitiveCompare(displayDeviceTitle($1)) == .orderedAscending }
        case "firstSeen": inv.sort { (ProfileDB.shared.profile(ip: $0.ip)?.firstSeen ?? .distantPast) > (ProfileDB.shared.profile(ip: $1.ip)?.firstSeen ?? .distantPast) }
        default: break
        }
        let mine = inv.filter { $0.isMe }
        let named = inv.filter { !$0.isMe && $0.name != $0.ip }
        let unnamed = inv.filter { !$0.isMe && $0.name == $0.ip }
        return ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
            if AnomalyStore.shared.isLearning {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Pal.info)
                    Text("Learning what's normal — taking a census of your network before unknown-hardware alerts start.")
                        .font(.system(size: 11)).foregroundStyle(Pal.ink2)
                    Spacer()
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).card()
            }
            if !mine.isEmpty { sectionLabel("This Mac").padding(.horizontal, 2) }
            ForEach(mine) { d in deviceCard(d) }
            if !named.isEmpty { sectionLabel("Identified · \(named.count)").padding(.horizontal, 2).padding(.top, 8) }
            ForEach(named) { d in deviceCard(d) }
            if !unnamed.isEmpty { sectionLabel("Unidentified · \(unnamed.count) — run a Scan to fingerprint").padding(.horizontal, 2).padding(.top, 8) }
            ForEach(unnamed) { d in deviceCard(d) }
        }.padding(12) }
    }
    private func deviceCard(_ d: DeviceRow) -> some View {
        Button(action: { engine.deviceDetailIP = d.ip }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(deviceColor(d.ip).opacity(0.16)).frame(width: 38, height: 38)
                    Image(systemName: d.icon).foregroundStyle(deviceColor(d.ip)).font(.system(size: 17))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(displayDeviceTitle(d)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Pal.ink).lineLimit(1)
                        if d.isMe {
                            Text("you").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Pal.live.opacity(0.2)).foregroundStyle(Pal.live).clipShape(RoundedRectangle(cornerRadius: 3))
                        } else if let p = ProfileDB.shared.profile(ip: d.ip), p.isNew {
                            Text("NEW").font(dataFont(8.5, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Pal.warn).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if d.klass != "Unknown" { classChip(d.klass) }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: d.classIcon).font(.system(size: 10)).foregroundStyle(deviceColor(d.ip))
                        Text(deviceTypeLine(d)).font(.system(size: 11, weight: .medium)).foregroundStyle(deviceColor(d.ip))
                        if d.os != "—" && !d.os.isEmpty { Text("· \(d.os)").font(.system(size: 11)).foregroundStyle(Pal.ink2) }
                        Text(shortIP(d.ip)).font(dataFont(10.5)).foregroundStyle(Pal.ink3)
                    }
                    HStack(spacing: 6) {
                        if let p = ProfileDB.shared.profile(ip: d.ip) {
                            if !p.mac.isEmpty {
                                Text(p.mac).font(dataFont(9.5)).foregroundStyle(Pal.ink3)
                            } else {
                                Text("MAC not visible").font(.system(size: 9.5)).foregroundStyle(Pal.ink3)
                            }
                            Text("· first seen \(relativeDay(p.firstSeen)) \(clockTime(p.firstSeen))")
                                .font(dataFont(9.5)).foregroundStyle(Pal.ink3)
                        }
                        Text("· \(d.flows) flows").font(dataFont(9.5)).foregroundStyle(Pal.ink3)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Pal.ink3).font(.system(size: 11))
            }.padding(11).frame(maxWidth: .infinity)
             .card()
        }.buttonStyle(.plain)
    }
}

struct AppsView: View {
    let events: [TrafficEvent]
    @EnvironmentObject private var options: Options
    var body: some View {
        var apps = appUsages(events)
        if options.appsHideSystem { apps = apps.filter { !($0.kind == "app" && ($0.subtitle == "Apple (system)" || $0.subtitle.hasPrefix("System") || $0.subtitle == "Background Service")) } }
        if options.appsTrackersOnly { apps = apps.filter { $0.trackers > 0 } }
        switch options.appsSort {
        case "flows": apps.sort { $0.flows > $1.flows }
        case "name": apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: break
        }
        return Group {
            if apps.isEmpty {
                VStack(spacing: 9) { Spacer()
                    Image(systemName: "square.stack.3d.up").font(.system(size: 24)).foregroundStyle(Pal.ink3)
                    Text("No app traffic yet.\nApps on this Mac show as confirmed; other devices' apps are inferred from their traffic.")
                        .multilineTextAlignment(.center).foregroundStyle(Pal.ink3).font(.system(size: 12.5)).lineSpacing(3)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 8) {
                    Text("Tap any app to see every endpoint it talks to and what each one is for.")
                        .font(.system(size: 10.5)).foregroundStyle(Pal.ink3).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2).padding(.bottom, 2)
                    ForEach(apps) { a in AppUseCard(a: a) }
                }.padding(12) }
            }
        }
    }
}

struct ScanView: View {
    @ObservedObject var scanner: Scanner
    @ObservedObject var engine: CaptureEngine
    @State private var mode = 0          // 0 = dns, 1 = both
    @State private var newUser = "root"
    @State private var newHost = ""
    @State private var newIface = "auto"

    private var connectedCount: Int { engine.collectors.filter { $0.status == "connected" }.count }

    private var collectorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(connectedCount > 0 ? Pal.live : Pal.ink3).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whole-network capture").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.ink)
                    Text(connectedCount > 0
                         ? "\(connectedCount) collector\(connectedCount == 1 ? "" : "s") streaming · \(engine.remoteDNSLines) DNS · \(engine.remoteFlowLines) flow lines"
                         : "HatchMap only sees this Mac's vantage point. Add a collector to see every device.")
                        .font(.system(size: 11)).foregroundStyle(connectedCount > 0 ? Pal.live : Pal.ink2)
                }
                Spacer()
            }
            Text("A collector runs tcpdump on a box with a better view — your gateway sees every device's traffic — and HatchMap reads it over SSH. Nothing listens on this Mac and the stream is encrypted.")
                .font(.system(size: 11)).foregroundStyle(Pal.ink2).fixedSize(horizontal: false, vertical: true)

            ForEach(engine.collectors) { c in collectorRow(c) }

            Divider()
            HStack(spacing: 7) {
                field("user", $newUser, 70)
                Text("@").font(dataFont(11)).foregroundStyle(Pal.ink3)
                field("host or IP", $newHost, 150)
                field("iface", $newIface, 66)
                seg(["Sites", "Sites + volume"], $mode)
                Button(action: addCollector) {
                    Text("Add collector").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(newHost.isEmpty ? Color.primary.opacity(0.06) : Pal.live)
                        .foregroundStyle(newHost.isEmpty ? Pal.ink3 : .black).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(newHost.isEmpty)
                Spacer()
            }
            Text("Needs key-based SSH from this Mac to that box (BatchMode — no password prompt). \"Sites\" streams DNS only: a few lines per second, safe on router hardware. \"Sites + volume\" adds every packet header — heavy on a gateway mid-download.")
                .font(.system(size: 10)).foregroundStyle(Pal.ink3).fixedSize(horizontal: false, vertical: true)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func collectorRow(_ c: CollectorHost) -> some View {
        let live = c.status == "connected"
        return HStack(spacing: 10) {
            Circle().fill(live ? Pal.live : (c.status == "error" ? Pal.bad : Pal.ink3)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.id).font(dataFont(12, .medium)).foregroundStyle(Pal.ink)
                Text(c.error.isEmpty
                     ? "\(c.mode == "dns" ? "sites" : "sites + volume") · \(c.iface == "auto" ? "auto interface" : c.iface) · \(c.status)"
                     : c.error)
                    .font(.system(size: 10)).foregroundStyle(c.error.isEmpty ? Pal.ink3 : Pal.bad).lineLimit(1)
            }
            Spacer()
            Button(action: { live ? engine.disconnectCollector(c) : engine.connectCollector(c) }) {
                Text(live ? "Disconnect" : "Connect").font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(live ? Color.primary.opacity(0.08) : Pal.info.opacity(0.22))
                    .foregroundStyle(live ? Pal.ink2 : Pal.info).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            Button(action: {
                engine.disconnectCollector(c)
                engine.collectors.removeAll { $0.id == c.id }
                engine.saveCollectorHosts()
            }) {
                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Pal.ink3)
            }.buttonStyle(.plain).accessibilityLabel("Remove collector \(c.id)")
        }.padding(9).frame(maxWidth: .infinity).card(raised: true)
    }

    private func field(_ placeholder: String, _ text: Binding<String>, _ w: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(dataFont(11)).foregroundStyle(Pal.ink)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: w)
            .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func addCollector() {
        let h = CollectorHost(user: newUser.isEmpty ? "root" : newUser,
                              host: newHost.trimmingCharacters(in: .whitespaces),
                              iface: newIface.isEmpty ? "auto" : newIface,
                              mode: mode == 0 ? "dns" : "both")
        guard !h.host.isEmpty, !engine.collectors.contains(where: { $0.id == h.id }) else { return }
        engine.collectors.append(h)
        engine.saveCollectorHosts()
        engine.connectCollector(h)
        newHost = ""
    }

    private func seg(_ options: [String], _ sel: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button(action: { sel.wrappedValue = i }) {
                    Text(o).font(.system(size: 10.5, weight: sel.wrappedValue == i ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(sel.wrappedValue == i ? Color.primary.opacity(0.10) : Color.clear)
                        .foregroundStyle(sel.wrappedValue == i ? Pal.ink : Pal.ink3).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        VStack(spacing: 0) {
            collectorPanel.padding(12)
            Divider()
            HStack(spacing: 10) {
                Button(action: { scanner.scan() }) {
                    Text(scanner.scanning ? "Scanning…" : "Scan network").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(scanner.scanning ? Pal.panel2 : Pal.info.opacity(0.25))
                        .foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(scanner.scanning)
                Text(scanner.progress).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.ink3)
                Spacer()
            }.padding(12)
            Divider()
            if scanner.results.isEmpty {
                VStack { Spacer()
                    Text("Press Scan network to discover devices and open ports on your subnet.")
                        .foregroundStyle(Pal.ink3).font(.system(size: 13, design: .monospaced)).multilineTextAlignment(.center).padding()
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 8) {
                    ForEach(scanner.results) { h in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(h.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.ink).lineLimit(1)
                                Text(h.ip).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.ink3)
                                if !h.vendor.isEmpty { Text("· \(h.vendor)").font(.system(size: 11)).foregroundStyle(Pal.ink3) }
                                Spacer()
                            }
                            if h.openPorts.isEmpty {
                                Text("no open ports found").font(.system(size: 11)).foregroundStyle(Pal.ink3)
                            } else {
                                HStack(spacing: 5) {
                                    ForEach(h.openPorts, id: \.self) { p in
                                        Text(scanner.portLabel(p)).font(.system(size: 10, design: .monospaced))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Pal.info.opacity(0.18)).foregroundStyle(Pal.info).clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            ForEach(h.exposures, id: \.self) { e in
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.2)).font(.system(size: 10))
                                    Text(e).font(.system(size: 11)).foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.45))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                         .background(Pal.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(12) }
            }
        }
    }
}

func bestHostForIP(_ ip: String) -> String {
    if let d = DNSMap.shared.domain(ip) { return d }
    if let n = NameCache.shared.name(ip) { return n }
    if let o = OrgDB.shared.lookup(ip)?.org { return o }
    return ip
}
func serviceForIP(_ ip: String, org: String, port: Int) -> ServiceHit? {
    ServiceDB.shared.match(host: bestHostForIP(ip), org: org, port: port)
}
