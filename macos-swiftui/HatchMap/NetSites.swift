import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Site history (VisitLog -> per-domain rows with device attribution)

// A brand people type -> the domain fragments that brand actually uses on the wire.
let BRAND_ALIASES: [String: [String]] = [
    "facebook": ["facebook", "fbcdn", "fbsbx", "fb.com", "fbstatic", "meta.com", "metausercontent"],
    "meta": ["facebook", "fbcdn", "meta.com", "instagram", "whatsapp"],
    "instagram": ["instagram", "cdninstagram", "igcdn", "igsonar"],
    "whatsapp": ["whatsapp"],
    "google": ["google", "gstatic", "googleapis", "googleusercontent", "ggpht", "googlevideo", "youtube", "ytimg"],
    "youtube": ["youtube", "ytimg", "googlevideo", "youtu.be"],
    "netflix": ["netflix", "nflxvideo", "nflximg", "nflxso", "nflxext"],
    "amazon": ["amazon.", "media-amazon", "ssl-images-amazon", "primevideo", "amazontrust"],
    "tiktok": ["tiktok", "tiktokcdn", "byteoversea", "ibytedtos"],
    "apple": ["apple", "icloud", "mzstatic", "cdn-apple", "apple-dns", "aaplimg"],
    "microsoft": ["microsoft", "msft", "live.com", "office", "azure", "msedge", "bing.com", "windows"],
    "twitter": ["twitter", "twimg", "x.com", "t.co"],
    "x": ["twitter", "twimg", "x.com"],
    "reddit": ["reddit", "redd.it", "redditmedia", "redditstatic"],
    "spotify": ["spotify", "scdn.", "spotifycdn", "audio-ak"],
    "snapchat": ["snapchat", "sc-cdn", "snapkit"],
    "twitch": ["twitch", "ttvnw", "jtvnw"],
    "discord": ["discord", "discordapp"],
    "github": ["github", "githubusercontent", "ghcr.io"],
    "jellyfin": ["jellyfin"],
    "plex": ["plex.tv", "plex.direct"],
]

struct SiteDeviceUse: Identifiable {
    var id: String { device }
    let device: String; let name: String
    let hits: Int; let bytes: Int; let first: Date; let last: Date
}
struct SiteRow: Identifiable {
    var id: String { domain }
    let domain: String; let category: String
    let devices: [SiteDeviceUse]
    let hits: Int; let bytes: Int; let first: Date; let last: Date
}

func expandBrandTokens(_ tokens: [String]) -> [String] {
    var pats: [String] = []
    for t in tokens {
        if let al = BRAND_ALIASES[t] { pats.append(contentsOf: al) } else { pats.append(t) }
    }
    return pats
}

// How far back a site question or view reaches.
struct DayScope: Equatable {
    let label: String       // "today", "yesterday", "the last 7 days"
    let days: Int           // rolling window size, 1 = today
    let exactDay: String    // non-empty = one specific calendar day instead of a window

    static let today = DayScope(label: "today", days: 1, exactDay: "")
    // Computed, not stored — a stored "yesterday" would go stale if the app runs past midnight.
    static var yesterday: DayScope { DayScope(label: "yesterday", days: 1, exactDay: VisitLog.dayString(daysAgo: 1)) }
    static let week = DayScope(label: "the last 7 days", days: 7, exactDay: "")
    static let month = DayScope(label: "the last 30 days", days: 30, exactDay: "")

    func visits() -> [(device: String, domain: String, v: VisitLog.Visit)] {
        exactDay.isEmpty ? VisitLog.shared.snapshot(days: days) : VisitLog.shared.snapshot(day: exactDay)
    }
}

// tokens: match ANY (empty = all sites). deviceFilter: exact device IP, or "" = all.
func siteRows(matching tokens: [String] = [], device deviceFilter: String = "", scope: DayScope = .today) -> [SiteRow] {
    let pats = expandBrandTokens(tokens.map { $0.lowercased() })
    var byDomain: [String: [(String, VisitLog.Visit)]] = [:]
    for (dev, dom, v) in scope.visits() {
        if !deviceFilter.isEmpty && deviceLabel(dev) != deviceLabel(deviceFilter) { continue }
        if !pats.isEmpty && !pats.contains(where: { dom.contains($0) }) { continue }
        byDomain[dom, default: []].append((dev, v))
    }
    var rows: [SiteRow] = []
    for (dom, uses) in byDomain {
        var byLabel: [String: (dev: String, hits: Int, bytes: Int, first: Date, last: Date)] = [:]
        for (dev, v) in uses {
            let label = deviceLabel(dev)
            var agg = byLabel[label] ?? (dev, 0, 0, v.first, v.last)
            agg.hits += v.hits; agg.bytes += v.bytes
            if v.first < agg.first { agg.first = v.first }
            if v.last > agg.last { agg.last = v.last }
            byLabel[label] = agg
        }
        var merged: [SiteDeviceUse] = []
        for (label, a) in byLabel {
            merged.append(SiteDeviceUse(device: a.dev, name: label, hits: a.hits, bytes: a.bytes, first: a.first, last: a.last))
        }
        merged.sort { $0.bytes == $1.bytes ? $0.hits > $1.hits : $0.bytes > $1.bytes }
        var hits = 0; var bytes = 0
        var first = Date.distantFuture; var last = Date.distantPast
        for m in merged {
            hits += m.hits; bytes += m.bytes
            if m.first < first { first = m.first }
            if m.last > last { last = m.last }
        }
        rows.append(SiteRow(domain: dom, category: categoryFor(host: dom, org: "", port: 443), devices: merged,
                            hits: hits, bytes: bytes, first: first, last: last))
    }
    rows.sort { $0.last > $1.last }
    return rows
}

let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
let clockFmtSec: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
func clockTime(_ d: Date) -> String { clockFmt.string(from: d) }
func visitSpan(_ first: Date, _ last: Date) -> String {
    let a = clockTime(first), b = clockTime(last)
    return a == b ? a : "\(a)–\(b)"
}

let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
/// Multi-day spans need a date, not just a wall-clock time.
func dayStamp(_ first: Date, _ last: Date) -> String {
    let a = dayFmt.string(from: first), b = dayFmt.string(from: last)
    return a == b ? "\(a) \(clockTime(last))" : "\(a) – \(b)"
}
/// "today" / "yesterday" / "3 Jul" for a row inside a multi-day view.
func relativeDay(_ d: Date) -> String {
    let s = VisitLog.dayString(d)
    if s == VisitLog.dayString(Date()) { return "today" }
    if s == VisitLog.dayString(daysAgo: 1) { return "yesterday" }
    return dayFmt.string(from: d)
}

// MARK: - Sites view (today's browsing, per device)

func brandInitial(_ domain: String) -> String {
    let parts = registrableDomain(domain).split(separator: ".")
    let core = parts.count >= 2 ? String(parts[parts.count - 2]) : domain
    return core.prefix(1).uppercased()
}

/// Stable per-brand colour so a column of tiles never reads as one flat block.
func brandColor(_ domain: String) -> Color {
    var h: UInt64 = 5381
    for b in registrableDomain(domain).utf8 { h = ((h << 5) &+ h) &+ UInt64(b) }
    return Color(hue: Double(h % 360) / 360.0, saturation: 0.5, brightness: 0.92)
}

/// Sites rolled up by registrable domain: one row per brand, subdomains inside.
struct SiteBrand: Identifiable {
    var id: String { domain }
    let domain: String
    let subs: [SiteRow]
    let devices: [SiteDeviceUse]
    let hits: Int, bytes: Int
    let first: Date, last: Date
    let category: String
}

func siteBrands(_ rows: [SiteRow]) -> [SiteBrand] {
    var byBrand: [String: [SiteRow]] = [:]
    for r in rows { byBrand[registrableDomain(r.domain), default: []].append(r) }
    var out: [SiteBrand] = []
    for (dom, subs) in byBrand {
        var hits = 0, bytes = 0
        var first = Date.distantFuture, last = Date.distantPast
        var devAgg: [String: SiteDeviceUse] = [:]
        for s in subs {
            hits += s.hits; bytes += s.bytes
            if s.first < first { first = s.first }
            if s.last > last { last = s.last }
            for d in s.devices {
                if let cur = devAgg[d.name] {
                    devAgg[d.name] = SiteDeviceUse(device: cur.device, name: cur.name,
                                                   hits: cur.hits + d.hits, bytes: cur.bytes + d.bytes,
                                                   first: min(cur.first, d.first), last: max(cur.last, d.last))
                } else { devAgg[d.name] = d }
            }
        }
        let devs = devAgg.values.sorted { $0.bytes == $1.bytes ? $0.hits > $1.hits : $0.bytes > $1.bytes }
        let sorted = subs.sorted { $0.bytes == $1.bytes ? $0.last > $1.last : $0.bytes > $1.bytes }
        out.append(SiteBrand(domain: dom, subs: sorted, devices: devs, hits: hits, bytes: bytes,
                             first: first, last: last, category: sorted.first?.category ?? "Web"))
    }
    return out
}

struct SiteBrandCard: View {
    let b: SiteBrand
    let showDay: Bool
    let manyDevices: Bool          // only name the device per row when more than one exists overall
    @State private var open = false
    private var expandable: Bool { b.subs.count > 1 || b.devices.count > 1 }
    var body: some View {
        let col = brandColor(b.domain)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { if expandable { open.toggle() } }) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(col.opacity(0.16)).frame(width: 32, height: 32)
                        Text(brandInitial(b.domain)).font(.system(size: 14, weight: .bold)).foregroundStyle(col)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.domain).font(dataFont(13, .semibold)).foregroundStyle(Pal.ink).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(categoryColor(b.category)).frame(width: 5, height: 5)
                            Text(b.category).font(.system(size: 10)).foregroundStyle(Pal.ink3)
                            if b.subs.count > 1 {
                                Text("· \(b.subs.count) subdomains").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                            }
                            if manyDevices {
                                Text("· \(b.devices.count == 1 ? b.devices[0].name : "\(b.devices.count) devices")")
                                    .font(.system(size: 10)).foregroundStyle(Pal.ink2)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 7) {
                            Text("\(b.hits)×").font(dataFont(10.5)).foregroundStyle(Pal.ink3)
                            if b.bytes > 0 { Text(fmtBytes(b.bytes)).font(dataFont(13, .semibold)).foregroundStyle(Pal.ink) }
                        }
                        Text(showDay ? "\(relativeDay(b.last)) \(clockTime(b.last))" : visitSpan(b.first, b.last))
                            .font(dataFont(9.5)).foregroundStyle(Pal.ink3)
                    }
                    Image(systemName: expandable ? (open ? "chevron.down" : "chevron.right") : "circle.fill")
                        .font(.system(size: expandable ? 9 : 2))
                        .foregroundStyle(expandable ? Pal.ink3 : Color.clear).frame(width: 10)
                }.padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain)
             .accessibilityLabel("\(b.domain), \(b.hits) visits, \(fmtBytes(b.bytes)), \(b.devices.count) device\(b.devices.count == 1 ? "" : "s")")
            if open {
                Divider().padding(.horizontal, 11)
                VStack(spacing: 0) {
                    if b.subs.count > 1 {
                        ForEach(b.subs) { s in
                            HStack(spacing: 8) {
                                Text(s.domain).font(dataFont(11)).foregroundStyle(Pal.ink2).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(s.hits)×").font(dataFont(10)).foregroundStyle(Pal.ink3)
                                if s.bytes > 0 { Text(fmtBytes(s.bytes)).font(dataFont(10)).foregroundStyle(Pal.ink2).frame(width: 62, alignment: .trailing) }
                                Text(visitSpan(s.first, s.last)).font(dataFont(10)).foregroundStyle(Pal.ink3).frame(width: 82, alignment: .trailing)
                            }.padding(.vertical, 3)
                        }
                    }
                    if b.devices.count > 1 {
                        Divider().padding(.vertical, 4)
                        ForEach(b.devices) { d in SiteDeviceLine(d: d) }
                    }
                }.padding(.horizontal, 13).padding(.vertical, 7)
            }
        }.card()
    }
}

struct SiteDeviceLine: View {
    let d: SiteDeviceUse
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(deviceColor(d.device)).frame(width: 7, height: 7)
            Text(d.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.ink)
            Text(deviceClass(d.device).klass).font(.system(size: 10)).foregroundStyle(Pal.ink3)
            Spacer(minLength: 6)
            if d.hits > 0 { Text("\(d.hits)×").font(dataFont(10.5)).foregroundStyle(Pal.ink2) }
            if d.bytes > 0 { Text(fmtBytes(d.bytes)).font(dataFont(10.5)).foregroundStyle(Pal.ink2).frame(width: 62, alignment: .trailing) }
            Text(visitSpan(d.first, d.last)).font(dataFont(10.5)).foregroundStyle(Pal.ink3).frame(width: 82, alignment: .trailing)
        }.padding(.vertical, 3)
    }
}

struct SiteCard: View {
    let s: SiteRow
    var showDay = false          // multi-day scopes need a date, not just a clock time
    var manyDevices = true       // naming the device on every row is noise when there's only one
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { if s.devices.count > 1 { open.toggle() } }) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(brandColor(s.domain).opacity(0.16)).frame(width: 32, height: 32)
                        Text(brandInitial(s.domain)).font(.system(size: 14, weight: .bold)).foregroundStyle(brandColor(s.domain))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.domain).font(dataFont(12.5, .medium)).foregroundStyle(Pal.ink).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(categoryColor(s.category)).frame(width: 5, height: 5)
                            Text(s.category).font(.system(size: 10)).foregroundStyle(Pal.ink3)
                            if manyDevices {
                                if s.devices.count == 1 {
                                    Text("· \(s.devices[0].name)").font(.system(size: 10)).foregroundStyle(Pal.ink2)
                                } else {
                                    Text("· \(s.devices.count) devices").font(.system(size: 10)).foregroundStyle(Pal.ink2)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            if s.hits > 0 { Text("\(s.hits)×").font(dataFont(10.5)).foregroundStyle(Pal.ink2) }
                            if s.bytes > 0 { Text(fmtBytes(s.bytes)).font(dataFont(11, .semibold)).foregroundStyle(Pal.ink) }
                        }
                        Text(showDay ? "\(relativeDay(s.last)) \(clockTime(s.last))" : visitSpan(s.first, s.last))
                            .font(dataFont(10)).foregroundStyle(Pal.ink3)
                    }
                    if s.devices.count > 1 {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.ink3)
                    }
                }.padding(.horizontal, 11).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
             .accessibilityLabel("\(s.domain), \(s.hits) visits, \(fmtBytes(s.bytes)), \(s.devices.count) device\(s.devices.count == 1 ? "" : "s")")
             .accessibilityHint(s.devices.count > 1 ? "Expands the per-device breakdown" : "")
            if open {
                Divider().padding(.horizontal, 11)
                VStack(spacing: 0) { ForEach(s.devices) { d in SiteDeviceLine(d: d) } }
                    .padding(.horizontal, 13).padding(.vertical, 6)
            }
        }.card()
    }
}

struct SitesView: View {
    @ObservedObject var engine: CaptureEngine
    @State private var search = ""
    @State private var deviceSel = ""            // device label, "" = all
    @State private var scopeSel: Int             // 0 today · 1 yesterday · 2 last 7 days · 3 last 30 days
    @State private var sortSel = 0               // 0 recent · 1 data · 2 visits

    init(engine: CaptureEngine) {
        self.engine = engine
        _scopeSel = State(initialValue: Options.shared.sitesScope)
    }

    private var scope: DayScope { scopeSel == 1 ? .yesterday : (scopeSel == 2 ? .week : (scopeSel == 3 ? .month : .today)) }

    var body: some View {
        let sc = scope
        let hidden = Options.shared.sitesHiddenSet
        let all = siteRows(scope: sc).filter { !hidden.contains($0.category) }
        var ipForLabel: [String: String] = [:]
        for r in all { for d in r.devices where ipForLabel[d.name] == nil { ipForLabel[d.name] = d.device } }
        let labels = ipForLabel.keys.sorted { a, b in
            a == "This Mac" ? true : (b == "This Mac" ? false : a < b)
        }
        var rows: [SiteRow] = []
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pats = needle.isEmpty ? [] : expandBrandTokens([needle])
        for r in all {
            if !pats.isEmpty && !pats.contains(where: { r.domain.contains($0) }) { continue }
            if deviceSel.isEmpty { rows.append(r); continue }
            let ds = r.devices.filter { $0.name == deviceSel }
            if ds.isEmpty { continue }
            var hits = 0; var bytes = 0
            var first = Date.distantFuture; var last = Date.distantPast
            for d in ds {
                hits += d.hits; bytes += d.bytes
                if d.first < first { first = d.first }
                if d.last > last { last = d.last }
            }
            rows.append(SiteRow(domain: r.domain, category: r.category, devices: ds,
                                hits: hits, bytes: bytes, first: first, last: last))
        }
        var brands = siteBrands(rows)
        switch sortSel {
        case 1: brands.sort { $0.bytes == $1.bytes ? $0.hits > $1.hits : $0.bytes > $1.bytes }
        case 2: brands.sort { $0.hits == $1.hits ? $0.bytes > $1.bytes : $0.hits > $1.hits }
        default: brands.sort { $0.last > $1.last }
        }
        let totalBytes = rows.reduce(0) { $0 + $1.bytes }
        let multiDay = sc.days > 1
        let manyDevices = labels.count > 1

        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Pal.ink3).font(.system(size: 11))
                        TextField("Filter sites — try a brand like facebook…", text: $search)
                            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.ink)
                        if !search.isEmpty {
                            Button(action: { search = "" }) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                            }.buttonStyle(.plain).accessibilityLabel("Clear site filter")
                        }
                    }.padding(.horizontal, 9).padding(.vertical, 6).frame(width: 280).card(raised: true)
                    segmented(["Today", "Yesterday", "7 days", "30 days"], $scopeSel)
                    segmented(["Recent", "Data", "Visits"], $sortSel)
                    Spacer()
                    Text("\(brands.count) site\(brands.count == 1 ? "" : "s")\(rows.count > brands.count ? " · \(rows.count) hosts" : "")\(totalBytes > 0 ? " · \(fmtBytes(totalBytes))" : "")")
                        .font(dataFont(10.5)).foregroundStyle(Pal.ink3)
                }
                if !labels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            chip("All devices", deviceSel.isEmpty, Pal.info) { deviceSel = "" }
                            ForEach(labels, id: \.self) { l in
                                chip(l, deviceSel == l, deviceColor(ipForLabel[l] ?? l)) { deviceSel = l }
                            }
                        }.padding(.horizontal, 1)
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 9) { Spacer()
                    Image(systemName: "globe").font(.system(size: 24)).foregroundStyle(Pal.ink3)
                    Text(emptyCopy(all.isEmpty, sc))
                        .multilineTextAlignment(.center).foregroundStyle(Pal.ink2).font(.system(size: 12.5)).lineSpacing(3)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 5) {
                    ForEach(brands) { b in SiteBrandCard(b: b, showDay: multiDay, manyDevices: manyDevices) }
                }.padding(12) }
            }
        }
    }

    private func emptyCopy(_ nothingLogged: Bool, _ sc: DayScope) -> String {
        if !nothingLogged { return "Nothing matches that filter." }
        if sc.days > 1 || !sc.exactDay.isEmpty { return "No sites logged for \(sc.label)." }
        return "No sites logged yet today.\nVisits appear as devices look up domains (DNS + TLS)."
    }

    private func segmented(_ options: [String], _ sel: Binding<Int>) -> some View {
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
    private func chip(_ label: String, _ on: Bool, _ tint: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                if label != "All devices" { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 10.5, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(on ? Pal.info.opacity(0.18) : Color.primary.opacity(0.05))
            .foregroundStyle(on ? Pal.ink : Pal.ink2).clipShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
}
