import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Category

func categoryFor(host: String, org: String, port: Int) -> String {
    let h = host.lowercased()
    if h.contains("doubleclick") || h.contains("googlesyndication") || h.contains("adservice")
        || h.contains("scorecardresearch") || h.contains("analytics") || h.contains("adnxs") { return "Ad / tracker" }
    if h.contains("youtube") || h.contains("googlevideo") || h.contains("nflx") || h.contains("netflix")
        || h.contains("ttvnw") || h.contains("twitch") || h.contains("hulu") || h.contains("video") { return "Streaming" }
    if h.contains("spotify") || h.contains("scdn") || h.contains("music") { return "Music" }
    if h.contains("facebook") || h.contains("instagram") || h.contains("fbcdn") || org == "Meta"
        || h.contains("twitter") || h.contains("tiktok") { return "Social" }
    if port == 53 || h.contains("dns") { return "DNS / system" }
    if org.contains("Apple") { return "Apple / system" }
    if org.contains("Amazon") || org.contains("Azure") || org.contains("Google Cloud")
        || org.contains("Cloudflare") || org.contains("Akamai") || org.contains("Fastly") { return "Cloud / CDN" }
    if h.contains("tuya") || h.contains("iot") || h.contains("xmpush") { return "IoT telemetry" }
    return "Web"
}

// MARK: - Threat detection

final class ThreatDB {
    static let shared = ThreatDB()
    private var badIPs: Set<String> = []
    private var badDomains: Set<String> = []
    private var sources: [String: String] = [:]
    private let lock = NSLock()
    init() { load() }
    func load() {
        var ips = Set<String>(); var doms = Set<String>(); var src: [String: String] = [:]
        let path = NetPaths.dir + "/threat-indicators.txt"
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            for raw in content.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let ind = parts.first, !ind.isEmpty else { continue }
                let source = parts.count > 1 ? parts[1] : "blocklist"
                if ipv4ToUInt32(ind) != nil { ips.insert(ind) } else { doms.insert(ind.lowercased()) }
                src[ind.lowercased()] = source
            }
        }
        lock.lock(); badIPs = ips; badDomains = doms; sources = src; lock.unlock()
    }
    // Merge auto-downloaded reputation feeds (abuse.ch etc.).
    func merge(ips: [String], domains: [String], source: String) {
        lock.lock()
        for ip in ips { badIPs.insert(ip); sources[ip.lowercased()] = source }
        for d in domains { let dl = d.lowercased(); badDomains.insert(dl); sources[dl] = source }
        lock.unlock()
    }
    var counts: (ips: Int, domains: Int) { lock.lock(); defer { lock.unlock() }; return (badIPs.count, badDomains.count) }
    func confirmed(ip: String, host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if badIPs.contains(ip) { return sources[ip.lowercased()] ?? "known-bad IP" }
        var h = host.lowercased()
        while h.contains(".") {                       // check host, then parent domains — O(labels), not O(feed)
            if badDomains.contains(h) { return sources[h] ?? "known-bad domain" }
            guard let dot = h.firstIndex(of: ".") else { break }
            h = String(h[h.index(after: dot)...])
        }
        return nil
    }
    func classify(remote: String, host: String, org: String, port: Int, isPrivate: Bool) -> String {
        if isPrivate { return "" }
        if let c = confirmed(ip: remote, host: host) { return "confirmed:" + c }
        if let s = suspiciousReason(host: host, org: org, port: port, isPrivate: isPrivate) { return "suspicious:" + s }
        return ""
    }
}

/// Ports that are unremarkable in normal home traffic. Without these, ordinary
/// Cloudflare Tunnel / Tailscale / QUIC / push traffic flagged constantly and the
/// alert badge sat in the dozens — which trains the user to ignore it.
let BENIGN_PORTS: Set<Int> = [
    443, 53, 80, 123, 853,          // web, DNS, NTP, DoT
    7844,                           // Cloudflare Tunnel
    3478, 3479, 5349, 5350, 41641,  // STUN/TURN, Tailscale
    5228, 5229, 5230,               // Google push
    5223, 2197,                     // Apple push
    1900, 5353, 5355,               // SSDP, mDNS, LLMNR
    8080, 8443, 32400,              // alt-HTTP, Plex
]

func suspiciousReason(host: String, org: String, port: Int, isPrivate: Bool) -> String? {
    if isPrivate { return nil }
    let o = Options.shared
    if port == 80 { return o.mutePlaintext ? nil : "Plaintext HTTP (unencrypted)" }
    if BENIGN_PORTS.contains(port) || WELL_KNOWN[port] != nil { return nil }
    // A resolved name or a recognised network is enough context to consider it ordinary.
    let named = host.contains(".") && host.contains(where: { $0.isLetter })
    if named || !org.isEmpty { return nil }
    if port > 1024 && !o.muteUnusualPort { return "Unusual port \(port) to an unrecognised host" }
    return nil
}

// MARK: - Reputation feed updater (auto-downloads public threat intel into ThreatDB)

final class FeedUpdater {
    static let shared = FeedUpdater()
    private let dir = NetPaths.dir
    enum Kind { case ip, url }
    private let feeds: [(url: String, kind: Kind, cache: String, source: String)] = [
        ("https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt", .ip, "feodo-ips.txt", "abuse.ch Feodo Tracker"),
        ("https://urlhaus.abuse.ch/downloads/text_online/", .url, "urlhaus.txt", "abuse.ch URLhaus"),
    ]
    func update() {
        for f in feeds {   // load cache first so it works offline, then refresh
            if let s = try? String(contentsOfFile: dir + "/" + f.cache, encoding: .utf8) { parse(s, kind: f.kind, source: f.source + " (cached)") }
            fetch(f)
        }
    }
    private func fetch(_ f: (url: String, kind: Kind, cache: String, source: String)) {
        guard let url = URL(string: f.url) else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let s = String(data: data, encoding: .utf8), s.count > 20 else { return }
            try? s.write(toFile: self.dir + "/" + f.cache, atomically: true, encoding: .utf8)
            self.parse(s, kind: f.kind, source: f.source)
        }.resume()
    }
    private func parse(_ s: String, kind: Kind, source: String) {
        var ips: [String] = []; var domains: [String] = []
        for raw in s.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            switch kind {
            case .ip:
                let ip = String(line.split(separator: ",").first ?? Substring(line)).trimmingCharacters(in: .whitespaces)
                if ipv4ToUInt32(ip) != nil { ips.append(ip) }
            case .url:
                if let host = URL(string: line)?.host, host.contains(".") { domains.append(host) }
            }
            if ips.count + domains.count > 80000 { break }
        }
        if !ips.isEmpty || !domains.isEmpty { ThreatDB.shared.merge(ips: ips, domains: domains, source: source) }
    }
}

// MARK: - Anomaly detection + alert center

struct Anomaly: Identifiable { let id = UUID(); let time = Date(); let level: String; let title: String; let detail: String; let deviceIP: String }

final class AnomalyStore: ObservableObject {
    static let shared = AnomalyStore()
    @Published var items: [Anomaly] = []
    private var seenKeys = Set<String>()
    private var baselineUntil = Date()
    private let lock = NSLock()

    func beginBaseline(seconds: TimeInterval = 25) {
        lock.lock(); baselineUntil = Date().addingTimeInterval(seconds); lock.unlock()
    }
    var learningUntil: Date { lock.lock(); defer { lock.unlock() }; return baselineUntil }
    var isLearning: Bool { Date() < learningUntil }

    /// Hardware whose MAC has never appeared in the profile roster. This is the alert that
    /// matters on a home network — an address can change, a network card generally doesn't.
    func clear() { DispatchQueue.main.async { self.items.removeAll() } }

    func noteNewHardware(_ p: DeviceProfile) {
        if Date() < learningUntil { return }        // still taking the initial census
        if Options.shared.muteNewDevice { return }
        let ip = p.ips.sorted().first ?? "unknown address"
        var what = p.bestName
        if !p.vendor.isEmpty && !what.contains(p.vendor) { what += " · \(p.vendor)" }
        let idPart = p.mac.isEmpty
            ? "Its hardware address isn't visible from this Mac, so it's identified by address only."
            : "MAC \(p.mac) has never been seen on this network before."
        raise(level: "review",
              title: p.mac.isEmpty ? "Unrecognised device joined" : "Unknown hardware joined",
              detail: "\(what) at \(ip). \(idPart)",
              deviceIP: ip, key: "newhw:" + p.key, notify: true)
    }

    func raise(level: String, title: String, detail: String, deviceIP: String, key: String, notify: Bool = false) {
        lock.lock()
        if seenKeys.contains(key) { lock.unlock(); return }
        seenKeys.insert(key)
        if seenKeys.count > 20000 { seenKeys.removeAll() }
        lock.unlock()
        let a = Anomaly(level: level, title: title, detail: detail, deviceIP: deviceIP)
        DispatchQueue.main.async {
            self.items.insert(a, at: 0)
            if self.items.count > 200 { self.items.removeLast(self.items.count - 200) }
        }
        if notify {
            let kind: Notifier.Kind = key.hasPrefix("threat") ? .threat : (key.hasPrefix("newhw") || key.hasPrefix("exfil") ? .newDevice : .other)
            Notifier.shared.post(title: title, body: detail, kind: kind)
        }
    }

    /// A device started talking. Profiles it from passive signals and alerts only if the
    /// hardware itself is unrecognised — the roster lives in ProfileDB, keyed by MAC.
    func noteDevice(_ ip: String) {
        // A device's link-local IPv6 is the same machine as its IPv4 — treating both as
        // separate arrivals buried the Alerts tab in duplicates.
        if ip.hasPrefix("fe80:") || ip.hasPrefix("ff02:") || ip.hasPrefix("169.254.") { return }
        lock.lock()
        let seenKey = "dev:" + ip
        if seenKeys.contains(seenKey) { lock.unlock(); return }
        seenKeys.insert(seenKey)
        lock.unlock()
        let r = ProfileDB.shared.observe(ip: ip)
        if r.isFirstEver { noteNewHardware(r.profile) }
    }
}

/// Local macOS notification (UserNotifications framework). Push to the phone is handled
/// server-side by hatch-notify on the server, so the Mac doesn't need to be awake for it.
func postNotification(title: String, body: String) {
    Notifier.shared.post(title: title, body: body)
}

func timeAgo(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

// MARK: - Enforcement policies (block / throttle / allow; simulated live, armed on the gateway)

struct Policy: Identifiable, Codable {
    var id = UUID()
    var name: String
    var targetIP: String        // "" = any device
    var matchCategory: String   // "" = any (e.g. "Ad / tracker", "Streaming", "Social")
    var matchHost: String       // substring, "" = any
    var action: String          // "block" | "throttle" | "allow"
    var afterHour: Int          // -1 = always; else active when local hour >= afterHour
    var enabled: Bool
}

final class PolicyStore: ObservableObject {
    static let shared = PolicyStore()
    @Published var policies: [Policy] = []
    private let path = NetPaths.dir + "/policies.json"
    init() { load() }
    func load() { if let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let p = try? JSONDecoder().decode([Policy].self, from: d) { policies = p } }
    func save() { if let d = try? JSONEncoder().encode(policies) { try? d.write(to: URL(fileURLWithPath: path)) } }
    func add(_ p: Policy) { policies.append(p); save() }
    func remove(_ id: UUID) { policies.removeAll { $0.id == id }; save() }
    func toggle(_ id: UUID) { if let i = policies.firstIndex(where: { $0.id == id }) { policies[i].enabled.toggle(); save() } }

    func wouldBlock(_ e: TrafficEvent, hour: Int) -> Policy? {
        if e.isPrivate { return nil }
        for p in policies where p.enabled && p.action == "block" {
            if !p.targetIP.isEmpty && e.deviceIP != p.targetIP && e.src != p.targetIP && e.dst != p.targetIP { continue }
            if !p.matchCategory.isEmpty && e.category != p.matchCategory { continue }
            if !p.matchHost.isEmpty {
                let h = bestHost(e).lowercased(); let o = e.org.lowercased()
                if !h.contains(p.matchHost.lowercased()) && !o.contains(p.matchHost.lowercased()) { continue }
            }
            if p.afterHour >= 0 && hour < p.afterHour { continue }
            return p
        }
        return nil
    }

    /// Writes the enforcer pack into a folder the user picks (an unsigned app writing straight to
    /// ~/Desktop trips a TCC prompt and can stall the caller — the save panel avoids both).
    @discardableResult
    func generateArtifacts(_ engine: CaptureEngine, into dir: URL) -> String {
        let enabled = policies.filter { $0.enabled && $0.action == "block" }
        let deviceBlocks = enabled.filter { !$0.targetIP.isEmpty }
        var domains = Set<String>()
        for p in enabled where p.targetIP.isEmpty && (!p.matchCategory.isEmpty || !p.matchHost.isEmpty) {
            for e in engine.events where !e.isPrivate {
                let catOK = p.matchCategory.isEmpty ? true : e.category == p.matchCategory
                let hostOK = p.matchHost.isEmpty ? true : (bestHost(e).lowercased().contains(p.matchHost.lowercased()) || e.org.lowercased().contains(p.matchHost.lowercased()))
                guard catOK && hostOK else { continue }
                let h = bestHost(e)
                if h.contains("."), h.contains(where: { $0.isLetter }) { domains.insert(h) }
            }
        }
        var nft = "#!/usr/sbin/nft -f\n# Generated by HatchMap — review before applying on your gateway.\ntable inet netsight {\n  chain forward {\n    type filter hook forward priority 0; policy accept;\n"
        for p in deviceBlocks { nft += "    ip saddr \(p.targetIP) drop   # \(p.name)\n" }
        nft += "  }\n}\n"
        let hosts = domains.sorted().map { "0.0.0.0 \($0)" }.joined(separator: "\n")
        let sh = """
        #!/bin/sh
        # HatchMap gateway enforcer — run as root on your router/Proxmox gateway to ARM these rules.
        # Applies device-level blocks via nftables and domain sinkholing via dnsmasq.
        set -e
        D="$(cd "$(dirname "$0")" && pwd)"
        nft -f "$D/hatchmap-enforcer.nft"
        echo "addn-hosts=$D/hatchmap-blocklist.hosts" > /etc/dnsmasq.d/netsight.conf
        (command -v systemctl >/dev/null && systemctl reload dnsmasq) || (command -v service >/dev/null && service dnsmasq reload) || true
        echo "HatchMap enforcement armed: \(deviceBlocks.count) device block(s), \(domains.count) domain(s) sinkholed."
        """
        do {
            try nft.write(to: dir.appendingPathComponent("hatchmap-enforcer.nft"), atomically: true, encoding: .utf8)
            try (hosts + "\n").write(to: dir.appendingPathComponent("hatchmap-blocklist.hosts"), atomically: true, encoding: .utf8)
            try sh.write(to: dir.appendingPathComponent("hatchmap-enforcer.sh"), atomically: true, encoding: .utf8)
        } catch {
            return "Couldn't write the pack: \(error.localizedDescription)"
        }
        return "Wrote to \(dir.path): hatchmap-enforcer.nft (\(deviceBlocks.count) device block\(deviceBlocks.count == 1 ? "" : "s")), hatchmap-blocklist.hosts (\(domains.count) domains), hatchmap-enforcer.sh. Copy them to your gateway and run the .sh as root to arm."
    }
}
