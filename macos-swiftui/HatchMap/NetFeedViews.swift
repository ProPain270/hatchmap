import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Destination aggregation (the feed's default shape)
// 400 raw packets-per-second rows are noise. People think in "who am I talking to",
// so the live view groups flows by destination and only falls back to raw on request.

struct DestGroup: Identifiable {
    var id: String { key }
    let key: String
    let title: String          // service name, registrable domain, org, or the activity itself
    let subtitle: String
    let icon: String
    let category: String
    let isDomain: Bool         // render the title in mono when it's a real hostname
    let unnamed: Bool          // no DNS/SNI name resolved — rank it visually below named services
    let deviceIPs: [String]
    let flows: Int
    let bytes: Int
    let last: Date
    let threat: String         // "confirmed…" > "suspicious…" > ""
    let plaintext: Bool
    let events: [TrafficEvent]
}

/// google.com from www.google.com, fbcdn.net from static.xx.fbcdn.net.
func registrableDomain(_ host: String) -> String {
    let parts = host.split(separator: ".").map(String.init)
    guard parts.count > 2 else { return host }
    let twoLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]
    if parts.count >= 3, twoLevel.contains(parts[parts.count - 2]), parts[parts.count - 1].count == 2 {
        return parts.suffix(3).joined(separator: ".")
    }
    return parts.suffix(2).joined(separator: ".")
}

func destGroups(_ events: [TrafficEvent]) -> [DestGroup] {
    struct Agg {
        var title = ""; var subtitle = ""; var icon = "globe"; var category = "Web"
        var isDomain = false; var unnamed = false
        var devices: [String] = []; var deviceSet: Set<String> = []
        var hosts: Set<String> = []; var ports: Set<Int> = []
        var flows = 0; var bytes = 0; var last = Date.distantPast
        var threat = ""; var plaintext = false; var evs: [TrafficEvent] = []
    }
    var groups: [String: Agg] = [:]
    for e in events {
        var key = ""; var title = ""; var subtitle = ""; var icon = "globe"
        var isDomain = false; var unnamed = false
        let host = bestHost(e)
        let hostIsName = host.contains(".") && host.contains(where: { $0.isLetter })
        if e.isPrivate {
            key = "local"; title = "Local network"; subtitle = "Devices talking to each other"; icon = "house"
        } else if let s = serviceOf(e), s.confidence != "generic" {
            key = "svc:" + s.name; title = s.name; subtitle = s.purpose; icon = s.icon
        } else if hostIsName {
            let d = registrableDomain(host)
            key = "dom:" + d; title = d; subtitle = e.org.isEmpty ? "Web / app traffic" : e.org; icon = "globe"; isDomain = true
        } else if !e.org.isEmpty {
            key = "org:" + e.org; title = e.org; icon = "cloud"; unnamed = true
        } else {
            // No DNS name, no SNI, no org — group by what it's doing, and say how many hosts.
            let a = activityOf(e)
            key = "act:" + a.headline; title = a.headline; icon = a.icon; unnamed = true
        }
        var g = groups[key] ?? Agg()
        g.title = title; g.icon = icon; g.isDomain = isDomain; g.unnamed = unnamed
        if g.subtitle.isEmpty { g.subtitle = subtitle }
        g.category = e.category
        if unnamed { g.hosts.insert(e.remoteIP.isEmpty ? e.dst : e.remoteIP); g.ports.insert(e.servicePort) }
        g.flows += 1
        g.bytes += volumeOf(e).total
        if e.time > g.last { g.last = e.time }
        if !e.deviceIP.isEmpty && !g.deviceSet.contains(e.deviceIP) { g.deviceSet.insert(e.deviceIP); g.devices.append(e.deviceIP) }
        if e.threat.hasPrefix("confirmed") { g.threat = e.threat }
        else if e.threat.hasPrefix("suspicious") && g.threat.isEmpty { g.threat = e.threat }
        if e.servicePort == 80 || e.servicePort == 23 || e.servicePort == 21 { g.plaintext = true }
        if g.evs.count < 40 { g.evs.append(e) }
        groups[key] = g
    }
    var out: [DestGroup] = []
    for (key, g) in groups {
        var sub = g.subtitle
        if g.unnamed {
            // "12 unidentified hosts · HTTPS" beats a repeated "Unnamed endpoints".
            let n = g.hosts.count
            var bits = ["\(n) unidentified host\(n == 1 ? "" : "s")"]
            if g.ports.count == 1, let p = g.ports.first { bits.append(serviceName(p)) }
            sub = bits.joined(separator: " · ")
        }
        if g.devices.count > 1 { sub += " · \(g.devices.count) devices" }
        out.append(DestGroup(key: key, title: g.title, subtitle: sub, icon: g.icon,
                             category: g.category, isDomain: g.isDomain, unnamed: g.unnamed,
                             deviceIPs: g.devices, flows: g.flows, bytes: g.bytes, last: g.last,
                             threat: g.threat, plaintext: g.plaintext, events: g.evs))
    }
    // Named services rank above anonymous buckets even when the bucket moved more bytes —
    // a row that says "Netflix" is worth more to a reader than one that says "unidentified".
    out.sort { a, b in
        if a.unnamed != b.unnamed { return !a.unnamed }
        return a.bytes == b.bytes ? a.last > b.last : a.bytes > b.bytes
    }
    return out
}

/// Consistent device identity everywhere: hash color + device-class glyph.
func deviceAvatar(_ ip: String, size: CGFloat = 26) -> some View {
    let c = deviceColor(ip)
    return ZStack {
        RoundedRectangle(cornerRadius: size * 0.28).fill(c.opacity(0.18))
        RoundedRectangle(cornerRadius: size * 0.28).stroke(c.opacity(0.35), lineWidth: 1)
        Image(systemName: deviceClass(ip).icon).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(c)
    }.frame(width: size, height: size)
}

func relativeAge(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

struct DestGroupRow: View {
    let g: DestGroup
    let maxBytes: Int
    let expanded: Bool
    var body: some View {
        let cat = categoryColor(g.category)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(cat.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: g.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(cat)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(g.title)
                            .font(g.isDomain ? dataFont(13.5, .semibold) : .system(size: 14, weight: .semibold))
                            .foregroundStyle(g.unnamed ? Pal.ink2 : Pal.ink).lineLimit(1)
                        if g.threat.hasPrefix("confirmed") { badge("MALICIOUS", Pal.bad) }
                        else if g.threat.hasPrefix("suspicious") { badge("REVIEW", Pal.warn) }
                        if g.plaintext { badge("PLAINTEXT", Pal.warn.opacity(0.75)) }
                    }
                    Text(g.subtitle).font(.system(size: 11)).foregroundStyle(Pal.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                // Only worth pixels when more than one machine is involved — otherwise every
                // row would show the same "This Mac" tile.
                if g.deviceIPs.count > 1 {
                    HStack(spacing: -5) {
                        ForEach(g.deviceIPs.prefix(3), id: \.self) { ip in
                            deviceAvatar(ip, size: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Pal.bg, lineWidth: 1.5))
                        }
                        if g.deviceIPs.count > 3 {
                            Text("+\(g.deviceIPs.count - 3)").font(dataFont(9, .semibold)).foregroundStyle(Pal.ink2)
                                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                        }
                    }.padding(.trailing, 4)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(g.bytes > 0 ? fmtBytes(g.bytes) : "—").font(dataFont(14, .semibold)).foregroundStyle(Pal.ink)
                    Text("\(g.flows) conn · \(relativeAge(g.last))").font(dataFont(9.5)).foregroundStyle(Pal.ink3)
                }.frame(width: 116, alignment: .trailing)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(Pal.ink3).frame(width: 12)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(expanded ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
    }
    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(dataFont(8, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Flow row + detail inspector

struct FlowRow: View {
    let ev: TrafficEvent
    let selected: Bool
    private var quiet: Bool { ev.isPrivate || ev.category == "DNS / system" }
    var body: some View {
        let di = directionIcon(ev.direction)
        let host = bestHost(ev)
        let domainish = host.contains(".") && host.contains(where: { $0.isLetter }) && !ev.isPrivate
        return HStack(spacing: 10) {
            Rectangle().fill(categoryColor(ev.category).opacity(quiet ? 0.35 : 0.9)).frame(width: 3)
                .padding(.vertical, 5).clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text(clockFmtSec.string(from: ev.time)).font(dataFont(9.5)).foregroundStyle(Pal.ink3).frame(width: 52, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(di.1.opacity(0.13)).frame(width: 26, height: 26)
                Image(systemName: di.0).foregroundStyle(di.1).font(.system(size: 10, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if domainish {
                        Text(host).foregroundStyle(Pal.ink).font(dataFont(12, .medium)).lineLimit(1)
                    } else {
                        Text(flowHeadline(ev)).foregroundStyle(Pal.ink).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                    if ev.threat.hasPrefix("confirmed") {
                        Text("MALICIOUS").font(dataFont(8, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Pal.bad).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 3))
                    } else if ev.threat.hasPrefix("suspicious") {
                        Text("REVIEW").font(dataFont(8, .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Pal.warn).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                HStack(spacing: 6) {
                    if !ev.deviceIP.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(deviceColor(ev.deviceIP)).frame(width: 6, height: 6)
                            Text(deviceLabel(ev.deviceIP)).font(.system(size: 10)).foregroundStyle(Pal.ink2).lineLimit(1)
                        }
                    }
                    Text(rowSub(ev)).foregroundStyle(Pal.ink3).font(.system(size: 10)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                let vol = volumeOf(ev).total
                if vol > 0 { Text(fmtBytes(vol)).font(dataFont(10.5)).foregroundStyle(Pal.ink2) }
                Text(ev.category).font(.system(size: 9.5, weight: .medium)).foregroundStyle(categoryColor(ev.category).opacity(0.9))
            }
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 7)
        .background(selected ? Pal.live.opacity(0.07) : Color.clear)
        .overlay(Rectangle().fill(Pal.live).frame(width: 2).opacity(selected ? 1 : 0), alignment: .leading)
        .contentShape(Rectangle())
        .opacity(quiet && !selected ? 0.6 : 1)
    }
}

/// The right pane's resting state. Was an empty 400pt void with a "select a flow" hint —
/// now it earns its space by showing what's happening right now.
struct NowPanel: View {
    @ObservedObject var engine: CaptureEngine
    var body: some View {
        let groups = destGroups(engine.events)
        let top = Array(groups.filter { $0.key != "local" && $0.bytes > 0 }.prefix(6))
        let maxB = top.first?.bytes ?? 1
        let series = HistoryStore.shared.timelineSeries(minutes: 30)
        let peak = max(series.max() ?? 1, 1)
        let devs = Array(engine.deviceInventory.prefix(6))
        let total = HistoryStore.shared.total
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(engine.running ? Pal.live : Pal.ink3).frame(width: 7, height: 7)
                        sectionLabel(engine.running ? "Live" : "Paused")
                    }
                    Text(fmtBytes(total)).font(dataFont(30, .semibold)).foregroundStyle(Pal.ink)
                    Text("seen this session · \(engine.events.count) active connections")
                        .font(.system(size: 11)).foregroundStyle(Pal.ink2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Last 30 minutes")
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(series.enumerated()), id: \.offset) { _, v in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(v > 0 ? Pal.live.opacity(0.85) : Color.primary.opacity(0.06))
                                .frame(height: max(2, CGFloat(Double(v) / Double(peak)) * 54))
                        }
                    }.frame(height: 56, alignment: .bottom)
                }
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Top destinations")
                        ForEach(top) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Circle().fill(categoryColor(g.category)).frame(width: 6, height: 6)
                                    Text(g.title).font(g.isDomain ? dataFont(11.5, .medium) : .system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Pal.ink).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(fmtBytes(g.bytes)).font(dataFont(10.5)).foregroundStyle(Pal.ink2)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.05)).frame(height: 4)
                                        Capsule().fill(categoryColor(g.category).opacity(0.8))
                                            .frame(width: max(3, geo.size.width * CGFloat(min(1, Double(g.bytes) / Double(max(maxB, 1))))), height: 4)
                                    }
                                }.frame(height: 4)
                            }
                        }
                    }
                }
                if !devs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Active devices")
                        ForEach(devs) { d in
                            HStack(spacing: 9) {
                                deviceAvatar(d.ip, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(displayDeviceTitle(d)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.ink).lineLimit(1)
                                    Text(d.klass != "Unknown" ? d.klass : (d.isMe ? "This Mac" : "unidentified"))
                                        .font(.system(size: 9.5)).foregroundStyle(Pal.ink3).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text("\(d.flows)").font(dataFont(11)).foregroundStyle(Pal.ink2)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Pal.rail)
    }
}

struct DetailInspector: View {
    let event: TrafficEvent?
    var body: some View {
        Group {
            if let e = event {
                let ex = explain(e)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ex.headline).font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(levelColor(ex.level)).frame(width: 8, height: 8).padding(.top, 4)
                            Text(ex.assessment).font(.system(size: 12)).foregroundStyle(levelColor(ex.level))
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 9)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: ex.activityIcon).font(.system(size: 16)).foregroundStyle(Pal.info).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ex.activity).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Pal.ink)
                                Text(ex.activityDetail).font(.system(size: 11.5)).foregroundStyle(Pal.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                         .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 13)
                        if !ex.attribution.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: attrIcon(ex.attributionLevel)).font(.system(size: 10)).foregroundStyle(attrColor(ex.attributionLevel)).padding(.top, 2)
                                Text(ex.attribution).font(.system(size: 10.5)).foregroundStyle(attrColor(ex.attributionLevel))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 9)
                        }
                        Text(ex.narrative).font(.system(size: 12.5)).foregroundStyle(Pal.ink).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                        Divider().padding(.vertical, 14)
                        Text("DETAILS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
                        VStack(spacing: 0) {
                            ForEach(Array(ex.facts.enumerated()), id: \.offset) { i, fct in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(fct.0).font(.system(size: 11)).foregroundStyle(Pal.ink3).frame(width: 92, alignment: .leading)
                                    Text(fct.1).font(.system(size: 11.5, design: fct.0 == "Flow" ? .monospaced : .default))
                                        .foregroundStyle(Pal.ink).frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }.padding(.vertical, 6)
                                if i < ex.facts.count - 1 { Divider() }
                            }
                        }.padding(.top, 6)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) { Spacer()
                    Image(systemName: "hand.point.up.left").font(.system(size: 26)).foregroundStyle(Pal.ink3)
                    Text("Select a flow to see exactly what it is —\nwho, what, where, and whether it's safe.")
                        .multilineTextAlignment(.center).font(.system(size: 12)).foregroundStyle(Pal.ink3).lineSpacing(3)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
        }.frame(maxHeight: .infinity).background(Pal.rail)
    }
}
