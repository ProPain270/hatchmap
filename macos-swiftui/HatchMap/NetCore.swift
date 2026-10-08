import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Shell helper

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// Like shell() but merges stderr into stdout (codesign writes to stderr).
func shellOut(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - IP helpers

func isPrivateIP(_ ip: String) -> Bool {
    if ip.contains(":") {
        let low = ip.lowercased()
        if low == "::1" { return true }
        if low.hasPrefix("fe80") || low.hasPrefix("fc") || low.hasPrefix("fd") || low.hasPrefix("ff") { return true }
        return false
    }
    let p = ip.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4 else { return false }
    let a = p[0], b = p[1]
    if a == 10 { return true }
    if a == 172 && (16...31).contains(b) { return true }
    if a == 192 && b == 168 { return true }
    if a == 127 || (a == 169 && b == 254) || (224...239).contains(a) || a == 0 { return true }
    return false
}

func isDeviceIP(_ ip: String) -> Bool {
    if ip.contains(":") {
        let low = ip.lowercased()
        if low.hasPrefix("ff") { return false }
        return low.hasPrefix("fe80") || low.hasPrefix("fc") || low.hasPrefix("fd")
    }
    let p = ip.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4 else { return false }
    if (224...239).contains(p[0]) || p[3] == 255 || p[3] == 0 { return false }
    return isPrivateIP(ip)
}

func ipv4ToUInt32(_ ip: String) -> UInt32? {
    let p = ip.split(separator: ".").compactMap { UInt32($0) }
    guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
    return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]
}

func reverseDNS(_ ip: String) -> String? {
    guard !ip.contains(":") else { return nil }
    var sa = sockaddr_in()
    sa.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafePointer(to: &sa) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            getnameinfo(sap, len, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        }
    }
    guard rc == 0 else { return nil }
    let name = String(cString: host)
    return name.isEmpty ? nil : name
}

// MARK: - Self identity (my IPs + subnet)

final class NetID {
    static let shared = NetID()
    private(set) var myIPs: Set<String> = []
    private(set) var subnetPrefix = "192.168.1."
    private(set) var gatewayIP = ""
    init() { refresh() }
    func refresh() {
        var ips: Set<String> = []
        let out = shell("/sbin/ifconfig", ["-a"])
        for raw in out.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("inet ") {
                let parts = t.split(separator: " ")
                if parts.count >= 2 { ips.insert(String(parts[1])) }
            } else if t.hasPrefix("inet6 ") {
                let parts = t.split(separator: " ")
                if parts.count >= 2 {
                    let a = String(parts[1]).split(separator: "%").first.map(String.init) ?? String(parts[1])
                    ips.insert(a)
                }
            }
        }
        myIPs = ips
        for line in shell("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") where line.contains("gateway:") {
            gatewayIP = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        if let lan = ips.first(where: { isPrivateIP($0) && !$0.hasPrefix("127") && !$0.contains(":") }) {
            let c = lan.split(separator: ".")
            if c.count == 4 { subnetPrefix = "\(c[0]).\(c[1]).\(c[2])." }
        }
    }
    func isMe(_ ip: String) -> Bool { myIPs.contains(ip) }
    var lanIP: String { myIPs.first(where: { isPrivateIP($0) && !$0.hasPrefix("127") && !$0.contains(":") }) ?? "<mac-ip>" }
}

// MARK: - Org / netblock database (bundled starter set)

struct OrgHit { let org: String; let country: String }

final class OrgDB {
    static let shared = OrgDB()
    private struct Block { let base: UInt32; let mask: UInt32; let prefix: Int; let org: String; let country: String }
    private var blocks: [Block] = []
    init() {
        let raw: [(String, String, String)] = [
            ("8.8.8.0/24","Google","US"),("8.8.4.0/24","Google","US"),
            ("142.250.0.0/15","Google","US"),("172.217.0.0/16","Google","US"),
            ("216.58.192.0/19","Google","US"),("74.125.0.0/16","Google","US"),
            ("64.233.160.0/19","Google","US"),("34.64.0.0/10","Google Cloud","US"),
            ("35.190.0.0/17","Google Cloud","US"),("108.177.0.0/17","Google","US"),
            ("1.1.1.0/24","Cloudflare","US"),("1.0.0.0/24","Cloudflare","US"),
            ("104.16.0.0/12","Cloudflare","US"),("172.64.0.0/13","Cloudflare","US"),
            ("162.158.0.0/15","Cloudflare","US"),("198.41.128.0/17","Cloudflare","US"),
            ("141.101.64.0/18","Cloudflare","US"),("108.162.192.0/18","Cloudflare","US"),
            ("190.93.240.0/20","Cloudflare","US"),("188.114.96.0/20","Cloudflare","US"),
            ("173.245.48.0/20","Cloudflare","US"),("103.21.244.0/22","Cloudflare","US"),
            ("103.22.200.0/22","Cloudflare","US"),("103.31.4.0/22","Cloudflare","US"),
            ("131.0.72.0/22","Cloudflare","US"),("197.234.240.0/22","Cloudflare","US"),
            ("13.32.0.0/15","Amazon CloudFront","US"),
            ("52.0.0.0/8","Amazon AWS","US"),("54.0.0.0/8","Amazon AWS","US"),
            ("3.0.0.0/9","Amazon AWS","US"),("18.64.0.0/10","Amazon AWS","US"),
            ("17.0.0.0/8","Apple","US"),("23.32.0.0/11","Akamai","US"),
            ("23.192.0.0/11","Akamai","US"),("104.64.0.0/10","Akamai","US"),
            ("184.24.0.0/13","Akamai","US"),("157.240.0.0/16","Meta","US"),
            ("31.13.24.0/21","Meta","US"),("31.13.64.0/18","Meta","US"),
            ("129.134.0.0/16","Meta","US"),("20.0.0.0/8","Microsoft Azure","US"),
            ("13.64.0.0/11","Microsoft","US"),("40.74.0.0/15","Microsoft","US"),
            ("151.101.0.0/16","Fastly","US"),("199.232.0.0/16","Fastly","US"),
            ("45.57.0.0/16","Netflix","US"),("108.175.32.0/20","Netflix","US"),
            ("208.67.222.0/24","OpenDNS / Cisco","US"),("9.9.9.0/24","Quad9","CH"),
            ("35.186.0.0/16","Google Cloud","US"),("140.82.112.0/20","GitHub","US"),
            ("192.30.252.0/22","GitHub","US"),("99.86.0.0/16","Amazon CloudFront","US"),
        ]
        for (cidr, org, cc) in raw {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let base = ipv4ToUInt32(String(parts[0])), let pfx = Int(parts[1]) else { continue }
            let mask: UInt32 = pfx == 0 ? 0 : (~UInt32(0) << (32 - pfx))
            blocks.append(Block(base: base & mask, mask: mask, prefix: pfx, org: org, country: cc))
        }
        blocks.sort { $0.prefix > $1.prefix }
    }
    func lookup(_ ip: String) -> OrgHit? {
        guard let v = ipv4ToUInt32(ip) else { return nil }
        for b in blocks where (v & b.mask) == b.base { return OrgHit(org: b.org, country: b.country) }
        return nil
    }
}

// MARK: - Reverse-DNS name cache (async warmed)

final class NameCache {
    static let shared = NameCache()
    private var cache: [String: String] = [:]
    private var pending: Set<String> = []
    private let q = DispatchQueue(label: "hatchmap.net.dns", qos: .utility)
    private let lock = NSLock()
    func name(_ ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let n = cache[ip] { return n.isEmpty ? nil : n }
        if !pending.contains(ip) {
            pending.insert(ip)
            q.async { [weak self] in
                let n = reverseDNS(ip) ?? ""
                self?.lock.lock(); self?.cache[ip] = n; self?.lock.unlock()
            }
        }
        return nil
    }
}

// MARK: - Passive DNS (real domain / subdomain per IP)

final class DNSMap {
    static let shared = DNSMap()
    private var ipToDomain: [String: String] = [:]
    private var pending: [String: (String, Date)] = [:]
    private let lock = NSLock()

    func domain(_ ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ipToDomain[ip]
    }

    // Inject a domain learned another way (e.g. TLS SNI) when we never saw a plaintext DNS query.
    func set(_ ip: String, domain: String) {
        lock.lock()
        if ipToDomain[ip] == nil { ipToDomain[ip] = domain }
        if ipToDomain.count > 10000 { ipToDomain.removeAll() }
        lock.unlock()
    }

    func ingest(_ line: String) {
        guard let colon = line.range(of: ": ") else { return }
        let toks = line[colon.upperBound...].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = toks.first else { return }
        let txid = String(first.prefix(while: { $0.isNumber }))
        if txid.isEmpty { return }
        if let qi = toks.firstIndex(where: { $0 == "A?" || $0 == "AAAA?" }), qi + 1 < toks.count {
            var dom = toks[qi + 1]
            if dom.hasSuffix(".") { dom = String(dom.dropLast()) }
            if dom.contains(".") && dom.contains(where: { $0.isLetter }) {
                lock.lock(); pending[txid] = (dom, Date()); if pending.count > 4000 { pending.removeAll() }; lock.unlock()
                // The query's source IP is the device that asked — that's a visit.
                var head = line[line.startIndex..<colon.lowerBound]
                if head.hasPrefix("IP6 ") { head = head.dropFirst(4) } else if head.hasPrefix("IP ") { head = head.dropFirst(3) }
                if let gt = head.range(of: " > "), let (src, _) = splitEndpoint(String(head[head.startIndex..<gt.lowerBound])),
                   isPrivateIP(src) || NetID.shared.isMe(src) {
                    VisitLog.shared.record(device: src, domain: dom, bytes: 0, hit: true)
                }
            }
            return
        }
        lock.lock(); let dom = pending[txid]?.0; lock.unlock()
        guard let domain = dom else { return }
        var ips: [String] = []; var i = 0
        while i < toks.count {
            if (toks[i] == "A" || toks[i] == "AAAA"), i + 1 < toks.count {
                var ip = toks[i + 1]; if ip.hasSuffix(",") { ip = String(ip.dropLast()) }
                if !ip.isEmpty { ips.append(ip) }
                i += 2
            } else { i += 1 }
        }
        if !ips.isEmpty {
            lock.lock()
            for ip in ips { ipToDomain[ip] = domain }
            if ipToDomain.count > 10000 { ipToDomain.removeAll() }
            pending.removeValue(forKey: txid)
            lock.unlock()
        }
    }
}

// MARK: - TLS SNI extraction (names the service even when DNS was encrypted or cached)

// Parse the server name from a raw IPv4 TLS ClientHello packet (full packet bytes, starting at IP header).
func sniFromIPv4Packet(_ b: [UInt8]) -> String? {
    guard b.count > 40, (b[0] >> 4) == 4 else { return nil }
    let ihl = Int(b[0] & 0x0f) * 4
    guard ihl >= 20, b.count > ihl + 20, b[9] == 6 else { return nil }        // IPv4, proto TCP
    let tcpOff = Int((b[ihl + 12] & 0xf0) >> 4) * 4
    let p = ihl + tcpOff
    guard tcpOff >= 20, b.count > p + 6 else { return nil }
    guard b[p] == 0x16, b[p + 5] == 0x01 else { return nil }                  // TLS handshake, ClientHello
    var i = p + 5 + 4                                                          // record hdr(5) + handshake hdr(4)
    i += 2 + 32                                                                // client_version + random
    guard i < b.count else { return nil }
    let sidLen = Int(b[i]); i += 1 + sidLen
    guard i + 2 <= b.count else { return nil }
    let csLen = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2 + csLen
    guard i < b.count else { return nil }
    let compLen = Int(b[i]); i += 1 + compLen
    guard i + 2 <= b.count else { return nil }
    let extTotal = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2
    let extEnd = min(b.count, i + extTotal)
    while i + 4 <= extEnd {
        let etype = (Int(b[i]) << 8) | Int(b[i + 1])
        let elen = (Int(b[i + 2]) << 8) | Int(b[i + 3])
        i += 4
        if etype == 0x0000 {                                                  // server_name
            guard i + 5 <= b.count else { return nil }
            let nameType = b[i + 2]
            let nameLen = (Int(b[i + 3]) << 8) | Int(b[i + 4])
            let start = i + 5
            guard nameType == 0, start + nameLen <= b.count, nameLen > 0 else { return nil }
            let s = String(decoding: Array(b[start..<start + nameLen]), as: UTF8.self)
            return (s.contains(".") && s.contains(where: { $0.isLetter })) ? s : nil
        }
        i += elen
    }
    return nil
}

// MARK: - Flow volume stats (bytes accumulate across the whole flow)

final class FlowStats {
    static let shared = FlowStats()
    struct S { var bytes = 0; var packets = 0; var outBytes = 0; var inBytes = 0; var first = Date(); var last = Date() }
    private var m: [String: S] = [:]
    private let lock = NSLock()
    func add(_ key: String, bytes: Int, outbound: Bool) {
        lock.lock(); defer { lock.unlock() }
        var s = m[key] ?? S()
        s.bytes += max(bytes, 0); s.packets += 1; s.last = Date()
        if outbound { s.outBytes += max(bytes, 0) } else { s.inBytes += max(bytes, 0) }
        m[key] = s
        if m.count > 8000 { m.removeAll() }
    }
    func get(_ key: String) -> S? { lock.lock(); defer { lock.unlock() }; return m[key] }
}

func fmtBytes(_ n: Int) -> String {
    if n <= 0 { return "0 B" }
    let u = ["B","KB","MB","GB","TB"]; var v = Double(n); var i = 0
    while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
}

// MARK: - History store (accumulates beyond the live 400-flow cap; timeline + top talkers)

final class HistoryStore {
    static let shared = HistoryStore()
    struct Remote { var bytes = 0; var hits = 0; var org = ""; var port = 0; var isPrivate = false; var last = Date() }
    struct Dev { var bytes = 0; var hits = 0 }
    let start = Date()
    private var remotes: [String: Remote] = [:]
    private var devices: [String: Dev] = [:]
    private var timeline: [Int: Int] = [:]     // minute-epoch -> bytes
    private var totalBytes = 0
    private let lock = NSLock()

    func add(device: String, remote: String, org: String, bytes: Int, port: Int, isPrivate: Bool) {
        let by = max(bytes, 0)
        lock.lock(); defer { lock.unlock() }
        totalBytes += by
        timeline[Int(Date().timeIntervalSince1970 / 60), default: 0] += by
        if timeline.count > 5000 { timeline.removeAll() }
        if !remote.isEmpty {
            var r = remotes[remote] ?? Remote()
            r.bytes += by; r.hits += 1; if !org.isEmpty { r.org = org }; r.port = port; r.isPrivate = isPrivate; r.last = Date()
            remotes[remote] = r
            if remotes.count > 20000 { remotes.removeAll() }
        }
        if !device.isEmpty {
            var d = devices[device] ?? Dev()
            d.bytes += by; d.hits += 1
            devices[device] = d
        }
    }
    func snapshotRemotes() -> [(ip: String, r: Remote)] { lock.lock(); defer { lock.unlock() }; return remotes.map { ($0.key, $0.value) } }
    func snapshotDevices() -> [(ip: String, d: Dev)] { lock.lock(); defer { lock.unlock() }; return devices.map { ($0.key, $0.value) } }
    func timelineSeries(minutes: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let now = Int(Date().timeIntervalSince1970 / 60)
        return (0..<minutes).reversed().map { timeline[now - $0] ?? 0 }
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return totalBytes }

    func persist() {
        let top = snapshotRemotes().sorted { $0.r.bytes > $1.r.bytes }.prefix(150)
        let df = ISO8601DateFormatter()
        let lines = top.map { "\(df.string(from: $0.r.last))\t\($0.ip)\t\($0.r.org)\t\($0.r.bytes)\t\($0.r.hits)" }
        let path = NetPaths.dir + "/history-top.tsv"
        try? ("# saved \(df.string(from: Date()))  ·  total \(totalBytes) bytes\n" + lines.joined(separator: "\n"))
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Visit log (persistent per-day, per-device, per-domain site history)
// Answers "what facebook sites were visited today, and from which device?"
// Fed by three signals: DNS query source IPs, TLS SNI source IPs, and flow bytes.

/// Tailscale MagicDNS zone; names under it are LAN-internal and never count as site visits.
private let tailscaleMagicDNSSuffix = ".ts" + ".net"

final class VisitLog {
    static let shared = VisitLog()
    struct Visit { var first = Date(); var last = Date(); var hits = 0; var bytes = 0 }
    private var visits: [String: Visit] = [:]        // "deviceIP|domain" — today, live
    private var dayCache: [String: [String: Visit]] = [:]   // past day -> its rows, read once
    private var day = VisitLog.dayString(Date())
    private var dirty = false
    private let lock = NSLock()

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private var path: String { NetPaths.dir + "/visits-\(day).tsv" }

    private func rolloverIfNeeded() {
        let today = VisitLog.dayString(Date())
        if today != day { persistLocked(); visits.removeAll(); day = today }
    }

    func record(device: String, domain: String, bytes: Int, hit: Bool) {
        guard !device.isEmpty, domain.contains("."), domain.contains(where: { $0.isLetter }) else { return }
        let dom = domain.lowercased()
        if dom.hasSuffix(".local") || dom.hasSuffix(".arpa") || dom.hasSuffix(tailscaleMagicDNSSuffix) { return }
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        var v = visits[device + "|" + dom] ?? Visit()
        v.last = Date(); v.bytes += max(bytes, 0); if hit { v.hits += 1 }
        visits[device + "|" + dom] = v
        if visits.count > 30000 { visits.removeAll() }
        dirty = true
    }

    func snapshot() -> [(device: String, domain: String, v: Visit)] {
        lock.lock(); defer { lock.unlock() }
        return visits.compactMap { key, v in
            guard let bar = key.firstIndex(of: "|") else { return nil }
            return (String(key[key.startIndex..<bar]), String(key[key.index(after: bar)...]), v)
        }
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard visits.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for (key, v) in VisitLog.parse(text) { visits[key] = v }
    }

    private static func parse(_ text: String) -> [(String, Visit)] {
        let df = ISO8601DateFormatter()
        var out: [(String, Visit)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 6 else { continue }
            let v = Visit(first: df.date(from: c[2]) ?? Date(), last: df.date(from: c[3]) ?? Date(),
                          hits: Int(c[4]) ?? 0, bytes: Int(c[5]) ?? 0)
            out.append((c[0] + "|" + c[1], v))
        }
        return out
    }

    // ── Past days (read-only, cached) ──────────────────────────────────────────

    static func dayString(daysAgo n: Int) -> String {
        dayString(Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date())
    }
    var today: String { lock.lock(); defer { lock.unlock() }; return day }

    /// Days that actually have a log file, newest first (includes today).
    func availableDays() -> [String] {
        let dir = NetPaths.dir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var days: Set<String> = [VisitLog.dayString(Date())]
        for n in names where n.hasPrefix("visits-") && n.hasSuffix(".tsv") {
            days.insert(String(n.dropFirst(7).dropLast(4)))
        }
        return days.sorted(by: >)
    }

    private func loadDayLocked(_ d: String) -> [String: Visit] {
        if let c = dayCache[d] { return c }
        let p = NetPaths.dir + "/visits-\(d).tsv"
        var m: [String: Visit] = [:]
        if let text = try? String(contentsOfFile: p, encoding: .utf8) {
            for (key, v) in VisitLog.parse(text) { m[key] = v }
        }
        dayCache[d] = m
        if dayCache.count > 20 { dayCache.removeAll() }
        return m
    }

    /// Visits over the last `days` calendar days (1 = today only). Merges duplicates across days.
    func snapshot(days: Int) -> [(device: String, domain: String, v: Visit)] {
        guard days > 1 else { return snapshot() }
        lock.lock(); defer { lock.unlock() }
        var merged = visits                                  // today, live
        for n in 1..<days {
            for (key, v) in loadDayLocked(VisitLog.dayString(daysAgo: n)) {
                if var cur = merged[key] {
                    cur.hits += v.hits; cur.bytes += v.bytes
                    if v.first < cur.first { cur.first = v.first }
                    if v.last > cur.last { cur.last = v.last }
                    merged[key] = cur
                } else { merged[key] = v }
            }
        }
        var out: [(String, String, Visit)] = []
        for (key, v) in merged {
            guard let bar = key.firstIndex(of: "|") else { continue }
            out.append((String(key[key.startIndex..<bar]), String(key[key.index(after: bar)...]), v))
        }
        return out
    }

    /// One specific past day (or today).
    func snapshot(day d: String) -> [(device: String, domain: String, v: Visit)] {
        if d == VisitLog.dayString(Date()) { return snapshot() }
        lock.lock(); defer { lock.unlock() }
        var out: [(String, String, Visit)] = []
        for (key, v) in loadDayLocked(d) {
            guard let bar = key.firstIndex(of: "|") else { continue }
            out.append((String(key[key.startIndex..<bar]), String(key[key.index(after: bar)...]), v))
        }
        return out
    }

    func persist() { lock.lock(); defer { lock.unlock() }; rolloverIfNeeded(); persistLocked() }

    /// Drops visit logs older than the retention window (never today's).
    func prune(days: Int) {
        let dir = NetPaths.dir
        let cutoff = VisitLog.dayString(daysAgo: max(1, days))
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasPrefix("visits-") && n.hasSuffix(".tsv") {
            let day = String(n.dropFirst(7).dropLast(4))
            if day < cutoff { try? FileManager.default.removeItem(atPath: dir + "/" + n) }
        }
    }
    private func persistLocked() {
        guard dirty else { return }
        let df = ISO8601DateFormatter()
        let lines = visits.map { key, v -> String in
            let bar = key.firstIndex(of: "|")!
            return "\(key[key.startIndex..<bar])\t\(key[key.index(after: bar)...])\t\(df.string(from: v.first))\t\(df.string(from: v.last))\t\(v.hits)\t\(v.bytes)"
        }
        try? ("# device\tdomain\tfirst\tlast\thits\tbytes\n" + lines.joined(separator: "\n")).write(toFile: path, atomically: true, encoding: .utf8)
        dirty = false
    }
}
