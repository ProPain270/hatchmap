import Combine
import Foundation
import SwiftUI

// MARK: - Daily-use intelligence over the topology feed
//
// Problems-first attention list (topology + network), "what changed since I last looked",
// per-node 24h flap history, and storage runway in days. Everything here is derived from what
// the app has actually observed; nothing is invented when the history is thin.

struct AttentionItem: Identifiable {
    enum Severity: Int, Comparable { case info = 0, warn = 1, crit = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue } }
    enum Target { case node(HNode), net(NetView), none }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let icon: String
    let target: Target
}

struct ChangeItem: Identifiable {
    let id: String
    let time: Date
    let key: String          // "tier/name"
    let name: String
    let from: String
    let to: String
    let kind: String         // state | storage | sitrep
    var text: String {
        switch kind {
        case "storage": return "\(name) \(from) → \(to)"
        case "sitrep": return "\(name): \(from) → \(to)"
        default: return "\(name) \(from) → \(to)"
        }
    }
    var isBad: Bool {
        if kind == "state" { return to != "up" }
        if kind == "sitrep" { return to == "warn" || to == "crit" }
        if kind == "storage", let a = Int(from.filter(\.isNumber)), let b = Int(to.filter(\.isNumber)) { return b > a }
        return false
    }
}

struct RunwayEstimate {
    let days: Double?        // nil = not filling (stable or freeing)
    let spanHours: Double    // how much history the estimate rests on
    let perDay: Int64        // bytes/day (positive = filling)
    var text: String {
        guard let d = days else { return perDay < 0 ? "freeing up" : "stable" }
        if d < 1 { return "under a day left" }
        if d > 365 { return "1y+ runway" }
        return "~\(Int(d.rounded())) day\(Int(d.rounded()) == 1 ? "" : "s") runway"
    }
    var confidence: String {
        if spanHours < 6 { return "based on \(max(1, Int(spanHours * 60)))m of samples" }
        if spanHours < 48 { return "based on \(Int(spanHours))h of samples" }
        return "based on \(Int(spanHours / 24))d of samples"
    }
}

struct NodeSnap: Codable, Equatable {
    var state: String
    var pct: Int?
    var free: String?
}

struct Snapshot: Codable {
    var savedAt: Date
    var nodes: [String: NodeSnap]        // "tier/name"
    var sitrep: [String: String]         // label -> state
    var sitrepValues: [String: String]   // label -> value
}

final class InsightStore: ObservableObject {
    @Published var attention: [AttentionItem] = []
    @Published var delta: [ChangeItem] = []
    @Published var deltaSince: Date?
    @Published var recentChanges: [ChangeItem] = []      // in-session + persisted, newest first (24h)

    private var bag = Set<AnyCancellable>()
    private var lastTopo: Topology?
    private var savedSnapshot: Snapshot?
    private var storageSamples: [(t: Date, key: String, free: Int64, pct: Int)] = []
    private var lastSampleAt: [String: Date] = [:]
    private weak var engine: CaptureEngine?
    private var inactiveSince: Date?

    private let dir = NetPaths.appDir
    private var snapshotPath: String { dir + "/last-seen.json" }
    private var stateLogPath: String { dir + "/state-log.tsv" }
    private var samplesPath: String { dir + "/storage-samples.tsv" }
    private let iso = ISO8601DateFormatter()

    func attach(_ svc: TopologyService, engine: CaptureEngine) {
        guard bag.isEmpty else { return }
        self.engine = engine
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        loadPersisted()
        svc.$topo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in if let t { self?.ingest(t) } }
            .store(in: &bag)
        svc.$lastGoodDate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildAttention(svc: svc) }
            .store(in: &bag)
        AnomalyStore.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildAttention(svc: svc) }
            .store(in: &bag)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.rebuildAttention(svc: svc) }
            .store(in: &bag)
        // "Since you last looked" also covers stepping away with the app open.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inactiveSince = Date()
            self?.persistSnapshot()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let since = self.inactiveSince, Date().timeIntervalSince(since) > Double(Options.shared.deltaGapMin) * 60,
                  let snap = self.savedSnapshot, let t = self.lastTopo else { return }
            self.inactiveSince = nil
            self.computeDelta(from: snap, to: t)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.persistSnapshot()
        }
    }

    // MARK: ingest

    private func ingest(_ t: Topology) {
        defer { lastTopo = t }
        let now = Date()
        // First topology of this run: diff against what was on screen when the app last quit.
        if lastTopo == nil, let snap = savedSnapshot { computeDelta(from: snap, to: t) }
        if let prev = lastTopo {
            let a = InsightStore.snapshot(prev), b = InsightStore.snapshot(t)
            var changes: [ChangeItem] = []
            for (key, nb) in b.nodes {
                guard let na = a.nodes[key] else { continue }
                let name = key.split(separator: "/").last.map(String.init) ?? key
                if na.state != nb.state {
                    changes.append(ChangeItem(id: "\(now.timeIntervalSince1970)-s-\(key)", time: now, key: key, name: name, from: na.state, to: nb.state, kind: "state"))
                }
                let w = Options.shared.diskWarn, c = Options.shared.diskCrit
                if let pa = na.pct, let pb = nb.pct, (pa < w && pb >= w) || (pa >= w && pb < w) || (pa < c && pb >= c) {
                    changes.append(ChangeItem(id: "\(now.timeIntervalSince1970)-p-\(key)", time: now, key: key, name: name, from: "\(pa)%", to: "\(pb)%", kind: "storage"))
                }
            }
            for (label, sb) in b.sitrep {
                if let sa = a.sitrep[label], sa != sb {
                    changes.append(ChangeItem(id: "\(now.timeIntervalSince1970)-r-\(label)", time: now, key: "sitrep/\(label)", name: label, from: sa, to: sb, kind: "sitrep"))
                }
            }
            if !changes.isEmpty {
                recentChanges.insert(contentsOf: changes, at: 0)
                appendStateLog(changes)
                for c in changes { Notifier.shared.stateChange(c) }
            }
        }
        // Storage samples — one per node per 10 minutes is plenty for a runway estimate.
        for item in t.storage {
            let key = "\(item.group.tier)/\(item.node.name)"
            guard let pct = item.node.pct, let free = parseBytes(item.node.free ?? "") else { continue }
            if let last = lastSampleAt[key], now.timeIntervalSince(last) < 600 { continue }
            lastSampleAt[key] = now
            storageSamples.append((now, key, free, pct))
            appendSample(now, key, free, pct)
        }
        pruneMemory()
    }

    static func snapshot(_ t: Topology) -> Snapshot {
        var nodes: [String: NodeSnap] = [:]
        for g in t.groups { for n in g.nodes { nodes["\(g.tier)/\(n.name)"] = NodeSnap(state: n.state, pct: n.pct, free: n.free) } }
        var sit: [String: String] = [:], vals: [String: String] = [:]
        for s in t.sitrep { sit[s.l] = s.c; vals[s.l] = s.v }
        return Snapshot(savedAt: Date(), nodes: nodes, sitrep: sit, sitrepValues: vals)
    }

    private func computeDelta(from snap: Snapshot, to t: Topology) {
        let cur = InsightStore.snapshot(t)
        var out: [ChangeItem] = []
        let now = Date()
        for (key, nb) in cur.nodes {
            let name = key.split(separator: "/").last.map(String.init) ?? key
            guard let na = snap.nodes[key] else {
                out.append(ChangeItem(id: "d-new-\(key)", time: now, key: key, name: name, from: "—", to: "new node", kind: "state")); continue
            }
            if na.state != nb.state { out.append(ChangeItem(id: "d-s-\(key)", time: now, key: key, name: name, from: na.state, to: nb.state, kind: "state")) }
            if let pa = na.pct, let pb = nb.pct, abs(pa - pb) >= 2 { out.append(ChangeItem(id: "d-p-\(key)", time: now, key: key, name: name, from: "\(pa)%", to: "\(pb)%", kind: "storage")) }
        }
        for key in snap.nodes.keys where cur.nodes[key] == nil {
            let name = key.split(separator: "/").last.map(String.init) ?? key
            out.append(ChangeItem(id: "d-gone-\(key)", time: now, key: key, name: name, from: "present", to: "gone from map", kind: "state"))
        }
        for (label, sb) in cur.sitrep {
            if let sa = snap.sitrep[label], sa != sb {
                out.append(ChangeItem(id: "d-r-\(label)", time: now, key: "sitrep/\(label)", name: label, from: sa, to: sb, kind: "sitrep"))
            } else if let va = snap.sitrepValues[label], let vb = cur.sitrepValues[label], va != vb, snap.sitrep[label] == sb {
                out.append(ChangeItem(id: "d-v-\(label)", time: now, key: "sitrep/\(label)", name: label, from: va, to: vb, kind: "sitrep"))
            }
        }
        delta = out.sorted { $0.isBad && !$1.isBad }
        deltaSince = snap.savedAt
    }

    func dismissDelta() { delta = []; deltaSince = nil }

    // MARK: attention (cross-source, problems first)

    private func rebuildAttention(svc: TopologyService) {
        var items: [AttentionItem] = []
        let o = Options.shared
        if let t = svc.topo {
            for g in t.groups {
                for n in g.nodes {
                    if n.state == "down" {
                        items.append(AttentionItem(id: "down-\(n.uid)", severity: .crit, title: "\(n.name) is down", detail: g.tier, icon: Palette.icon(n.t), target: .node(n)))
                    } else if n.state != "up" {
                        items.append(AttentionItem(id: "warn-\(n.uid)", severity: .warn, title: "\(n.name) degraded", detail: "\(g.tier) · state \(n.state)", icon: Palette.icon(n.t), target: .node(n)))
                    }
                    if let p = n.pct, p >= o.diskWarn {
                        let rw = runway(for: "\(g.tier)/\(n.name)")
                        let tail = rw.map { " · \($0.text)" } ?? ""
                        items.append(AttentionItem(id: "disk-\(n.uid)", severity: p >= o.diskCrit ? .crit : .warn, title: "\(n.name) at \(p)%", detail: "\(n.free ?? "") free\(tail)", icon: "internaldrive", target: .node(n)))
                    }
                }
            }
            for s in t.sitrep where s.c == "warn" || s.c == "crit" {
                // Skip disks already listed as nodes.
                if t.storage.contains(where: { $0.node.name == s.l }) { continue }
                items.append(AttentionItem(id: "sit-\(s.uid)", severity: s.c == "crit" ? .crit : .warn, title: "\(s.l): \(s.v)", detail: s.s, icon: "exclamationmark.triangle", target: .none))
            }
            if o.attnStale, svc.isStale, let d = svc.lastGoodDate {
                items.append(AttentionItem(id: "stale", severity: .warn, title: "Topology feed is stale", detail: "Last good poll \(Int(Date().timeIntervalSince(d) / 60))m ago — showing last-known state", icon: "wifi.exclamationmark", target: .none))
            }
        } else if svc.lastGoodDate == nil, !svc.error.isEmpty {
            items.append(AttentionItem(id: "offline", severity: .crit, title: "Can't reach the topology feed", detail: svc.error, icon: "wifi.slash", target: .none))
        }
        // Network intelligence: only things that are confirmed or genuinely new.
        for a in AnomalyStore.shared.items.prefix(50) where a.level == "bad" && o.attnNetwork {
            items.append(AttentionItem(id: "net-\(a.id)", severity: .crit, title: a.title, detail: a.detail, icon: "exclamationmark.octagon", target: .net(.alerts)))
        }
        let newHW = AnomalyStore.shared.items.filter { $0.level == "review" && $0.title.contains("joined") && Date().timeIntervalSince($0.time) < 86_400 }
        if !newHW.isEmpty && o.attnNetwork {
            items.append(AttentionItem(id: "net-newhw", severity: .info, title: "\(newHW.count) unrecognised device\(newHW.count == 1 ? "" : "s") joined the LAN", detail: newHW.first?.detail ?? "", icon: "questionmark.circle", target: .net(.devices)))
        }
        if o.attnQuiet, let e = engine, e.running, let t = e.lastPacketAt, Date().timeIntervalSince(t) > 600 {
            items.append(AttentionItem(id: "net-stale", severity: .info, title: "Network capture has gone quiet", detail: "No packets for \(Int(Date().timeIntervalSince(t) / 60))m on \(e.iface)", icon: "antenna.radiowaves.left.and.right.slash", target: .net(.feed)))
        }
        attention = items.sorted { $0.severity > $1.severity }
    }

    // MARK: flap history

    /// State/storage transitions for a node key in the last `hours`, newest first.
    func history(for key: String, hours: Double = 24) -> [ChangeItem] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return recentChanges.filter { $0.key == key && $0.time > cutoff }
    }

    // MARK: storage runway

    func runway(for key: String) -> RunwayEstimate? {
        let cutoff = Date().addingTimeInterval(-Double(max(1, Options.shared.runwayDays)) * 86_400)
        let pts = storageSamples.filter { $0.key == key && $0.t > cutoff }
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 1800 else { return nil }          // need at least 30 minutes of history
        // Least squares: free bytes vs. time (days).
        let t0 = first.t.timeIntervalSince1970
        let xs = pts.map { ($0.t.timeIntervalSince1970 - t0) / 86_400 }
        let ys = pts.map { Double($0.free) }
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<pts.count { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) * (xs[i] - mx) }
        guard den > 0 else { return nil }
        let slope = num / den                          // bytes per day (negative = filling)
        let fill = -slope
        let hours = span / 3600
        if fill <= Double(last.free) * 0.001 {          // less than 0.1% of free per day: call it stable
            return RunwayEstimate(days: nil, spanHours: hours, perDay: Int64(fill))
        }
        return RunwayEstimate(days: Double(last.free) / fill, spanHours: hours, perDay: Int64(fill))
    }

    // MARK: persistence

    private func loadPersisted() {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)),
           let s = try? JSONDecoder().decode(Snapshot.self, from: d) { savedSnapshot = s }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        if let text = try? String(contentsOfFile: stateLogPath, encoding: .utf8) {
            var out: [ChangeItem] = []
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard c.count >= 5, let t = iso.date(from: c[0]), t > cutoff else { continue }
                let name = c[1].split(separator: "/").last.map(String.init) ?? c[1]
                out.append(ChangeItem(id: "log-\(c[0])-\(c[1])", time: t, key: c[1], name: name, from: c[2], to: c[3], kind: c[4]))
            }
            recentChanges = out.sorted { $0.time > $1.time }
        }
        if let text = try? String(contentsOfFile: samplesPath, encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let c = line.split(separator: "\t").map(String.init)
                guard c.count >= 4, let t = iso.date(from: c[0]), t > cutoff, let free = Int64(c[2]), let pct = Int(c[3]) else { continue }
                storageSamples.append((t, c[1], free, pct))
                lastSampleAt[c[1]] = max(lastSampleAt[c[1]] ?? .distantPast, t)
            }
            storageSamples.sort { $0.t < $1.t }
        }
    }

    private func persistSnapshot() {
        guard let t = lastTopo else { return }
        let snap = InsightStore.snapshot(t)
        savedSnapshot = snap
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic) }
    }

    private func appendStateLog(_ changes: [ChangeItem]) {
        let lines = changes.map { "\(iso.string(from: $0.time))\t\($0.key)\t\($0.from)\t\($0.to)\t\($0.kind)\n" }.joined()
        append(lines, to: stateLogPath, header: "# time\tkey\tfrom\tto\tkind\n")
    }
    private func appendSample(_ t: Date, _ key: String, _ free: Int64, _ pct: Int) {
        append("\(iso.string(from: t))\t\(key)\t\(free)\t\(pct)\n", to: samplesPath, header: "# time\tkey\tfreeBytes\tpct\n")
    }
    private func append(_ s: String, to path: String, header: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { try? header.write(toFile: path, atomically: true, encoding: .utf8) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(s.data(using: .utf8) ?? Data()); try? h.close()
        }
    }
    private func pruneMemory() {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        if recentChanges.count > 2000 { recentChanges = Array(recentChanges.prefix(2000)) }
        storageSamples.removeAll { $0.t < cutoff }
    }
}

/// "196G" → bytes (binary units, as `df -h` prints them).
func parseBytes(_ s: String) -> Int64? {
    let t = s.trimmingCharacters(in: .whitespaces).uppercased()
    guard let num = Double(t.filter { $0.isNumber || $0 == "." }), !t.isEmpty else { return nil }
    let unit = t.last(where: { $0.isLetter }) ?? "B"
    let mult: Double
    switch unit {
    case "K": mult = 1024
    case "M": mult = 1024 * 1024
    case "G": mult = 1024 * 1024 * 1024
    case "T": mult = 1024 * 1024 * 1024 * 1024
    case "P": mult = 1024 * 1024 * 1024 * 1024 * 1024
    default: mult = 1
    }
    return Int64(num * mult)
}

// MARK: - Node history section (detail panel)

struct NodeHistorySection: View {
    let node: HNode
    let groupTier: String
    @EnvironmentObject private var insights: InsightStore

    var body: some View {
        let key = "\(groupTier)/\(node.name)"
        let h = insights.history(for: key)
        let rw = node.pct != nil ? insights.runway(for: key) : nil
        DetailSection(title: "Last 24 hours") {
            if let rw {
                HStack {
                    Image(systemName: rw.days == nil ? "checkmark.circle" : "hourglass")
                        .foregroundStyle(rw.days.map { $0 < 14 ? Color.orange : Color.green } ?? Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rw.text).font(.callout.weight(.medium))
                        Text(rw.confidence + (rw.perDay > 0 ? " · filling \(fmtBytes(Int(rw.perDay)))/day" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
            } else if node.pct != nil {
                Text("Runway appears after ~30 minutes of samples.").font(.caption).foregroundStyle(.secondary)
            }
            if h.isEmpty {
                Label("No state changes observed", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(h.count) change\(h.count == 1 ? "" : "s")" + (h.count >= 3 ? " — flapping" : ""))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(h.count >= 3 ? Color.orange : Color.primary)
                ForEach(h.prefix(8)) { c in
                    HStack(spacing: 8) {
                        Circle().fill(c.isBad ? Color.red : Color.green).frame(width: 6, height: 6)
                        Text(c.text).font(.caption)
                        Spacer()
                        Text(timeAgo(c.time)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
