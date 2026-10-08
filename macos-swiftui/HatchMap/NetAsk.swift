import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Ask: natural-language analyst over live + historical data (offline query engine)

struct QueryAnswer {
    let headline: String; let detail: String; let bullets: [String]; let flows: [TrafficEvent]; let devices: [DeviceRow]
    var sites: [SiteRow] = []
}

func networkSummary(_ engine: CaptureEngine) -> QueryAnswer {
    let events = engine.events
    let devs = engine.deviceInventory.count
    let cats = Dictionary(grouping: events.filter { !$0.isPrivate }, by: { $0.category }).mapValues { $0.count }
    let topCat = cats.sorted { $0.value > $1.value }.first
    let topRemote = HistoryStore.shared.snapshotRemotes().filter { !$0.r.isPrivate }.sorted { $0.r.bytes > $1.r.bytes }.first
    let alerts = AnomalyStore.shared.items.count
    var bl: [String] = []
    if let t = topRemote { let s = serviceForIP(t.ip, org: t.r.org, port: t.r.port); bl.append("Heaviest: \(s?.name ?? bestHostForIP(t.ip)) (\(fmtBytes(t.r.bytes)))") }
    if let c = topCat { bl.append("Most common: \(c.key)") }
    bl.append("\(devs) devices active")
    bl.append(alerts == 0 ? "No alerts" : "\(alerts) alert(s) — see the Alerts tab")
    return QueryAnswer(headline: "Here's what's happening on your network",
                       detail: "Ask me things like \u{201C}what facebook sites were visited today?\u{201D}, \u{201C}who's using the most data\u{201D}, \u{201C}what is the Apple TV doing?\u{201D}, \u{201C}anything suspicious?\u{201D}, or \u{201C}show streaming\u{201D}.",
                       bullets: bl, flows: [], devices: [])
}

func answerQuery(_ raw: String, engine: CaptureEngine) -> QueryAnswer {
    let q = raw.lowercased()
    let events = engine.events
    func has(_ ss: [String]) -> Bool { ss.contains { q.contains($0) } }

    if has(["suspicious","malicious","threat","dangerous","hacked","attack","bad actor","compromis","anything wrong","should i worry","is it safe","am i safe"]) {
        let anomalies = AnomalyStore.shared.items
        let bad = anomalies.filter { $0.level == "bad" }
        let flagged = engine.alerts
        var bl: [String] = []
        for a in anomalies.prefix(6) { bl.append("\(a.title): \(a.detail)") }
        let c = ThreatDB.shared.counts
        let head = (bad.isEmpty && flagged.isEmpty) ? "Nothing confirmed malicious right now." : "\(bad.count) confirmed · \(anomalies.count) notice(s)"
        let detail = (bad.isEmpty && flagged.isEmpty)
            ? "No connection matched the \(c.ips + c.domains) live threat indicators loaded, and no anomalies fired. Encrypted traffic to recognised services looks normal."
            : "Worth a look — confirmed items exactly matched a threat feed; others are heuristics."
        return QueryAnswer(headline: head, detail: detail, bullets: bl, flows: flagged, devices: [])
    }
    if has(["most data","bandwidth","hog","using the most","top talker","heaviest","most traffic","using data","data usage","eating"]) {
        if has(["who","device","phone","computer","which device"]) {
            let ranked = HistoryStore.shared.snapshotDevices().sorted { $0.d.bytes > $1.d.bytes }.prefix(6)
            let bl = ranked.map { "\(resolveDevice($0.ip).name) — \(fmtBytes($0.d.bytes))" }
            return QueryAnswer(headline: "Top devices by data this session", detail: "Ranked by total bytes seen.", bullets: Array(bl), flows: [], devices: engine.deviceInventory)
        }
        let ranked = HistoryStore.shared.snapshotRemotes().filter { !$0.r.isPrivate }.sorted { $0.r.bytes > $1.r.bytes }.prefix(8)
        let bl = ranked.map { it -> String in let s = serviceForIP(it.ip, org: it.r.org, port: it.r.port); return "\(s?.name ?? bestHostForIP(it.ip)) — \(fmtBytes(it.r.bytes))" }
        return QueryAnswer(headline: "Top destinations by data", detail: "The services pulling the most bytes.", bullets: Array(bl), flows: [], devices: [])
    }
    if has(["tracker","tracking","ads","advertis","spying","privacy","who is watching","data broker"]) {
        let ads = events.filter { $0.category == "Ad / tracker" }
        let byApp = Dictionary(grouping: ads, by: { appDisplayOf($0).isEmpty ? bestHost($0) : appDisplayOf($0) })
        let bl = byApp.sorted { $0.value.count > $1.value.count }.prefix(8).map { "\($0.key) → \(Set($0.value.map { bestHost($0) }).count) tracker domain(s)" }
        return QueryAnswer(headline: ads.isEmpty ? "No trackers seen yet." : "\(ads.count) tracker / ad connection(s)",
                           detail: ads.isEmpty ? "Nothing classified as advertising or tracking in the current window." : "Analytics, ad, and attribution services loaded in the background by apps and sites.",
                           bullets: Array(bl), flows: ads, devices: [])
    }
    // Site history — "what facebook sites were visited today?", "what sites did the iPhone visit?"
    let siteIntent = has(["site", "sites", "visited", "visit", "browsing", "browse", "went to", "domains", "websites", "web pages", "webpages", "url"])
    var scope = DayScope.today
    if has(["yesterday"]) { scope = .yesterday }
    else if has(["last 30", "past 30", "this month", "last month", "30 days"]) { scope = .month }
    else if has(["last 7", "past 7", "this week", "last week", "7 days", "week"]) { scope = .week }
    let qWords = Set(q.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" }).map(String.init))
    let domainTokens = qWords.filter { $0.contains(".") && $0.contains(where: { $0.isLetter }) && !$0.hasSuffix("?") }
    let brandTokens = BRAND_ALIASES.keys.filter { qWords.contains($0) }.sorted { $0.count > $1.count } + domainTokens.sorted()
    if siteIntent || !brandTokens.isEmpty {
        var devFilter = ""; var devName = ""
        if let dev = engine.deviceInventory.first(where: { d in
            let n = d.name.lowercased()
            return (n.count > 2 && q.contains(n)) || q.contains(d.ip)
                || (q.contains("apple tv") && d.type.lowercased().contains("apple tv"))
                || (q.contains("iphone") && d.klass.lowercased().contains("phone"))
                || ((q.contains("this mac") || q.contains("my mac") || q.contains("macbook")) && d.isMe)
        }) { devFilter = dev.ip; devName = dev.name }
        let rows = siteRows(matching: brandTokens, device: devFilter, scope: scope)
        let brand = brandTokens.first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let what = brand.map { "\($0) site" } ?? "site"
        if rows.isEmpty {
            let who = devName.isEmpty ? "any visible device" : devName
            return QueryAnswer(headline: "No \(what)s seen \(scope.label)\(devName.isEmpty ? "" : " from \(devName)")",
                               detail: "No matching domain was looked up by \(who) \(scope.label). HatchMap sees this Mac completely; other devices are visible only when their DNS or TLS handshakes cross this Mac — run the router collector (Scan tab) for full coverage.",
                               bullets: [], flows: [], devices: [])
        }
        let devNames = Set(rows.flatMap { $0.devices.map { $0.name } })
        let hits = rows.reduce(0) { $0 + $1.hits }
        let bytes = rows.reduce(0) { $0 + $1.bytes }
        let first = rows.map { $0.first }.min() ?? Date()
        let last = rows.map { $0.last }.max() ?? Date()
        let matchingFlows = engine.events.filter { ev in
            let pats = expandBrandTokens(brandTokens); let h = bestHost(ev).lowercased()
            return !pats.isEmpty && pats.contains { h.contains($0) }
        }
        let span = scope.days > 1 || !scope.exactDay.isEmpty ? dayStamp(first, last) : visitSpan(first, last)
        return QueryAnswer(headline: "\(rows.count) \(what)\(rows.count == 1 ? "" : "s") visited \(scope.label)\(devName.isEmpty ? "" : " by \(devName)")",
                           detail: "\(hits) visit\(hits == 1 ? "" : "s")\(bytes > 0 ? " · \(fmtBytes(bytes))" : "") · \(devNames.count) device\(devNames.count == 1 ? "" : "s") (\(devNames.sorted().joined(separator: ", "))) · \(span)",
                           bullets: [], flows: Array(matchingFlows.prefix(20)), devices: [], sites: rows)
    }
    for (cat, kw) in [("Streaming", ["streaming","video","watching","netflix","youtube"]), ("Music", ["music","spotify","listening"]), ("Social", ["social","tiktok","instagram","facebook","reddit"]), ("Cloud / CDN", ["cloud","backup","syncing","upload"])] {
        if has(kw) {
            let fl = events.filter { $0.category == cat }
            let names = Set(fl.compactMap { serviceOf($0)?.name ?? (bestHost($0).isEmpty ? nil : bestHost($0)) })
            return QueryAnswer(headline: fl.isEmpty ? "No \(cat.lowercased()) traffic right now." : "\(cat): \(fl.count) flow(s)",
                               detail: names.isEmpty ? "" : "Services: \(names.prefix(6).joined(separator: ", "))", bullets: [], flows: fl, devices: [])
        }
    }
    if has(["country","china","russia","foreign","overseas","abroad","geolocation","located"]) {
        let ext = events.filter { !$0.isPrivate && !$0.country.isEmpty }
        let byC = Dictionary(grouping: ext, by: { $0.country })
        let bl = byC.sorted { $0.value.count > $1.value.count }.map { "\($0.key): \($0.value.count) flow(s)" }
        return QueryAnswer(headline: ext.isEmpty ? "No country data yet." : "Traffic by country",
                           detail: "Where your external connections go (coarse GeoIP — most IPs aren't located yet).", bullets: Array(bl), flows: [], devices: [])
    }
    if has(["how many device","what device","list device","devices on","phones","computers","who is on","inventory"]) {
        let devs = engine.deviceInventory
        let byClass = Dictionary(grouping: devs, by: { $0.klass })
        let bl = byClass.sorted { $0.value.count > $1.value.count }.map { "\($0.value.count) × \($0.key)" }
        return QueryAnswer(headline: "\(devs.count) device(s) seen", detail: "Everything that's communicated this session.", bullets: Array(bl), flows: [], devices: devs)
    }
    if has(["unencrypted","plaintext","not secure","insecure","http "]) {
        let fl = events.filter { $0.servicePort == 80 || $0.servicePort == 23 || $0.servicePort == 21 }
        return QueryAnswer(headline: fl.isEmpty ? "No unencrypted traffic seen." : "\(fl.count) unencrypted connection(s)",
                           detail: fl.isEmpty ? "Everything external is going over TLS/HTTPS." : "These could be readable in transit — avoid anything sensitive on them.", bullets: [], flows: fl, devices: [])
    }
    if let dev = engine.deviceInventory.first(where: { d in
        let n = d.name.lowercased(); let t = d.type.lowercased(); let k = d.klass.lowercased()
        return (n.count > 2 && q.contains(n)) || q.contains(d.ip)
            || (q.contains("apple tv") && t.contains("apple tv")) || (q.contains("iphone") && k.contains("phone"))
            || (q.contains("printer") && t.contains("printer"))
    }) {
        let fl = events.filter { $0.src == dev.ip || $0.dst == dev.ip }
        let apps = appUsages(fl)
        let bl = apps.prefix(6).map { "\($0.name) — \($0.endpoints.count) endpoint(s), \(fmtBytes($0.bytes))" }
        return QueryAnswer(headline: "\(dev.name) · \(dev.klass)", detail: "\(fl.count) flows · \(apps.count) apps/services. What it's been doing:", bullets: Array(bl), flows: fl, devices: [])
    }
    return networkSummary(engine)
}

struct AskView: View {
    @ObservedObject var engine: CaptureEngine
    @State private var query = ""
    @State private var answer: QueryAnswer? = nil
    private let suggestions = ["What Facebook sites were visited today?", "What sites did this Mac visit?", "Who's using the most data?",
                               "Any trackers or ads?", "Anything suspicious?", "What is the Apple TV doing?", "How many devices?", "Any unencrypted traffic?"]

    var body: some View {
        Group { if answer == nil { hero } else { results } }
    }

    private var askField: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").foregroundStyle(Pal.live).font(.system(size: 13))
            TextField("Ask about sites, devices, data, threats…", text: $query).onSubmit(run)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Pal.ink)
            Button(action: run) {
                Text("Ask").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Pal.live.opacity(0.9)).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12).padding(.vertical, 9).card(raised: true)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Pal.live.opacity(0.12)).frame(width: 58, height: 58)
                    Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 24)).foregroundStyle(Pal.live)
                }
                VStack(spacing: 5) {
                    Text("Ask your network anything").font(.system(size: 19, weight: .semibold)).foregroundStyle(Pal.ink)
                    Text("Answers come from live capture + today's visit log — private, on-device, no cloud.")
                        .font(.system(size: 12)).foregroundStyle(Pal.ink2)
                }
                askField.frame(width: 560)
                VStack(spacing: 6) {
                    ForEach([Array(suggestions.prefix(4)), Array(suggestions.dropFirst(4))], id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { s in
                                Button(action: { query = s; run() }) {
                                    Text(s).font(.system(size: 10.5)).padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.05)).foregroundStyle(Pal.ink2).clipShape(RoundedRectangle(cornerRadius: 20))
                                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Pal.stroke, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Spacer()
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var results: some View {
        let a = answer ?? networkSummary(engine)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                askField
                Button(action: { answer = nil; query = "" }) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.ink2)
                        .padding(9).background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(a.headline).font(.system(size: 17, weight: .semibold)).foregroundStyle(Pal.ink).fixedSize(horizontal: false, vertical: true)
                    if !a.detail.isEmpty { Text(a.detail).font(.system(size: 12.5)).foregroundStyle(Pal.ink2).fixedSize(horizontal: false, vertical: true) }
                    if !a.bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(a.bullets, id: \.self) { b in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(Pal.live).frame(width: 5, height: 5).padding(.top, 6)
                                    Text(b).font(.system(size: 12.5)).foregroundStyle(Pal.ink).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    if !a.sites.isEmpty {
                        let multi = Set(a.sites.flatMap { $0.devices.map { $0.name } }).count > 1
                        sectionLabel(multi ? "Sites · who visited what, when" : "Sites · when")
                        LazyVStack(spacing: 5) { ForEach(a.sites.prefix(40)) { s in SiteCard(s: s, manyDevices: multi) } }
                    }
                    if !a.devices.isEmpty {
                        sectionLabel("Devices")
                        ForEach(a.devices.prefix(12)) { d in
                            HStack(spacing: 8) {
                                Image(systemName: d.classIcon).foregroundStyle(deviceColor(d.ip)).font(.system(size: 12))
                                Text(d.name).font(.system(size: 12)).foregroundStyle(Pal.ink).lineLimit(1)
                                Text(d.klass).font(.system(size: 10)).foregroundStyle(Pal.ink3)
                                Spacer(); Text("\(d.flows) flows").font(dataFont(10)).foregroundStyle(Pal.ink3)
                            }.padding(.vertical, 2)
                        }
                    }
                    if !a.flows.isEmpty {
                        sectionLabel("Live flows matching")
                        VStack(spacing: 0) {
                            ForEach(a.flows.prefix(30)) { ev in FlowRow(ev: ev, selected: false); Divider() }
                        }.card()
                    }
                }.padding(14)
            }
        }
    }

    private func run() {
        let t = query.trimmingCharacters(in: .whitespaces)
        answer = t.isEmpty ? nil : answerQuery(t, engine: engine)
    }
}

struct PoliciesView: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var store = PolicyStore.shared
    @State private var genMsg = ""
    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let external = engine.events.filter { !$0.isPrivate }
        let blocked = external.compactMap { e -> (TrafficEvent, Policy)? in store.wouldBlock(e, hour: hour).map { (e, $0) } }
        return ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(Pal.info)
                Text("Policies").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.ink)
                Spacer()
            }
            Text("Create block rules per device, category, host, or time. HatchMap simulates them live below — nothing is actually blocked until you generate the gateway pack and run it on your router/Proxmox.")
                .font(.system(size: 11.5)).foregroundStyle(Pal.ink2).fixedSize(horizontal: false, vertical: true)
            Text("QUICK RULES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
            HStack(spacing: 8) {
                quickBtn("Block ads & trackers") { store.add(Policy(name: "Block ads & trackers", targetIP: "", matchCategory: "Ad / tracker", matchHost: "", action: "block", afterHour: -1, enabled: true)) }
                quickBtn("No streaming after 10pm") { store.add(Policy(name: "No streaming after 10pm", targetIP: "", matchCategory: "Streaming", matchHost: "", action: "block", afterHour: 22, enabled: true)) }
                quickBtn("Block social media") { store.add(Policy(name: "Block social media", targetIP: "", matchCategory: "Social", matchHost: "", action: "block", afterHour: -1, enabled: true)) }
            }
            if store.policies.isEmpty {
                Text("No policies yet — add one above, or use \u{201C}Block this device\u{201D} from a device's detail page.")
                    .font(.system(size: 12)).foregroundStyle(Pal.ink3).padding(.top, 2)
            } else {
                Text("RULES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
                ForEach(store.policies) { p in policyRow(p) }
            }
            Divider().background(Color.primary.opacity(0.08))
            Text("DRY RUN — last \(external.count) external flows").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
            Text(blocked.isEmpty ? "Nothing would be blocked with the current rules." : "\(blocked.count) flow(s) would be blocked right now.")
                .font(.system(size: 12.5)).foregroundStyle(blocked.isEmpty ? Pal.ink2 : Color(red: 0.95, green: 0.6, blue: 0.4))
            ForEach(Array(blocked.prefix(20).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.4)).font(.system(size: 10))
                    Text(bestHost(item.0)).font(.system(size: 11.5)).foregroundStyle(Pal.ink).lineLimit(1)
                    Text("· \(item.1.name)").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                    Spacer()
                }
            }
            Divider().background(Color.primary.opacity(0.08))
            Button(action: {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.prompt = "Write pack here"; panel.message = "Choose a folder for the gateway enforcer pack"
                if panel.runModal() == .OK, let dir = panel.url { genMsg = store.generateArtifacts(engine, into: dir) }
            }) {
                Text("Generate gateway enforcer pack").font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Pal.info.opacity(0.25)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            if !genMsg.isEmpty { Text(genMsg).font(.system(size: 11)).foregroundStyle(Pal.ink2).fixedSize(horizontal: false, vertical: true) }
        }.padding(14) }
    }
    private func quickBtn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(Color.primary.opacity(0.08)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
    }
    private func policyRow(_ p: Policy) -> some View {
        HStack(spacing: 10) {
            Button(action: { store.toggle(p.id) }) {
                Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(p.enabled ? Color(red: 0.3, green: 0.7, blue: 0.5) : Pal.ink3).font(.system(size: 15))
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.ink)
                Text(policyDesc(p)).font(.system(size: 10)).foregroundStyle(Pal.ink3)
            }
            Spacer()
            Text(p.action.uppercased()).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(p.action == "block" ? Color(red: 0.6, green: 0.25, blue: 0.25) : Color(red: 0.25, green: 0.5, blue: 0.35)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
            Button(action: { store.remove(p.id) }) { Image(systemName: "trash").foregroundStyle(Pal.ink3).font(.system(size: 11)) }.buttonStyle(.plain)
        }.padding(10).background(Pal.panel).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func policyDesc(_ p: Policy) -> String {
        var s: [String] = [p.targetIP.isEmpty ? "any device" : resolveDevice(p.targetIP).name]
        if !p.matchCategory.isEmpty { s.append(p.matchCategory) }
        if !p.matchHost.isEmpty { s.append("host~\(p.matchHost)") }
        if p.afterHour >= 0 { s.append("after \(p.afterHour):00") }
        return s.joined(separator: " · ")
    }
}
