import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Model

struct TrafficEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let src, dst: String
    let sport, dport: Int
    let proto: String
    let servicePort: Int
    let direction: String      // out / in / local / observed
    let originSummary: String
    let device: String
    let app: String
    let host: String
    let remoteIP: String
    let org: String
    let country: String
    let category: String
    let deviceIP: String
    let threat: String
    let isPrivate: Bool
    let bytes: Int
    let flowKey: String
}

let WELL_KNOWN: [Int: String] = [22:"SSH",53:"DNS",80:"HTTP",123:"NTP",143:"IMAP",443:"HTTPS",
    465:"SMTPS",587:"SMTP",993:"IMAPS",995:"POP3S",3389:"RDP",3478:"STUN",5353:"mDNS"]

func servicePort(_ s: Int, _ d: Int) -> Int {
    if WELL_KNOWN[d] != nil || d <= s { return d }
    if WELL_KNOWN[s] != nil { return s }
    return d
}

func splitEndpoint(_ ep: String) -> (String, Int)? {
    guard let dot = ep.lastIndex(of: ".") else { return nil }
    guard let port = Int(ep[ep.index(after: dot)...]) else { return nil }
    return (String(ep[ep.startIndex..<dot]), port)
}

func parseLine(_ line: String) -> (src: String, dst: String, sport: Int, dport: Int, proto: String, len: Int)? {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("IP6 ") { s = String(s.dropFirst(4)) }
    else if s.hasPrefix("IP ") { s = String(s.dropFirst(3)) }
    else { return nil }
    guard let gt = s.range(of: " > ") else { return nil }
    let srcTok = String(s[s.startIndex..<gt.lowerBound])
    let rest = String(s[gt.upperBound...])
    guard let delim = rest.range(of: ": ") else { return nil }
    let dstTok = String(rest[rest.startIndex..<delim.lowerBound])
    let proto = rest[delim.upperBound...].lowercased()
    guard let (sa, sp) = splitEndpoint(srcTok), let (da, dp) = splitEndpoint(dstTok) else { return nil }
    let pn = proto.contains("udp") ? "UDP" : (proto.contains("tcp") ? "TCP" : "OTHER")
    var len = 0
    if let r = proto.range(of: "length ") {
        len = Int(proto[r.upperBound...].prefix(while: { $0.isNumber })) ?? 0
    } else {
        // tcpdump -q prints "tcp 1428" — the trailing number is the payload length.
        if let last = proto.split(separator: " ").last, let n = Int(last) { len = n }
    }
    return (sa, da, sp, dp, pn, len)
}

// MARK: - Party labelling

func partyLabel(_ ip: String) -> String {
    if NetID.shared.isMe(ip) { return "Me" }
    if isPrivateIP(ip) { return DeviceDB.shared.label(ip) ?? "Local device" }
    let org = OrgDB.shared.lookup(ip)?.org
    return org ?? NameCache.shared.name(ip) ?? ip
}

// MARK: - Device rows

struct DeviceRow: Identifiable {
    var id: String { ip }
    let ip: String
    let name: String
    let type: String
    let icon: String
    let vendor: String
    let flows: Int
    let dests: Int
    let isMe: Bool
    let klass: String
    let os: String
    let classIcon: String
}

func deviceLabel(_ ip: String) -> String {
    if NetID.shared.isMe(ip) { return "This Mac" }
    if let l = DeviceDB.shared.label(ip) { return l }
    if let n = NameCache.shared.name(ip) { return n }
    return ip
}

// MARK: - Remote capture listener (whole-network vantage from a router/Proxmox collector)

/// Accepts capture streams from a collector running at a better vantage point (the gateway,
/// or a switch mirror port). Two things make this safe enough to leave running:
/// a shared token, and the fact that a stream can only ever *add* observed traffic.
///
/// Wire protocol, first line then raw tcpdump output:
///     NETSIGHT1 <token> <channel>        channel = F (flows, tcpdump -q) | D (DNS, port 53)
final class RemoteListener {
    static let shared = RemoteListener()
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    var onLine: ((String, String) -> Void)?          // (channel, line)
    var onStats: ((Int) -> Void)?                    // peer count changed

    private(set) var token = ""
    private var tokenPath: String { NetPaths.dir + "/collector-token.txt" }

    /// Stable across launches so a deployed collector keeps working after a restart.
    func loadOrCreateToken() {
        if let t = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 16 { token = trimmed; return }
        }
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        try? token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
    }

    var peerCount: Int { lock.lock(); defer { lock.unlock() }; return conns.count }

    func start(port: UInt16) {
        stop()
        loadOrCreateToken()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: nwPort) else { return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.receive(conn, buffer: "", channel: "", authed: false)
        }
        l.start(queue: .global())
        listener = l
    }

    private func drop(_ conn: NWConnection) {
        lock.lock(); conns.removeValue(forKey: ObjectIdentifier(conn)); let n = conns.count; lock.unlock()
        conn.cancel()
        onStats?(n)
    }

    private func receive(_ conn: NWConnection, buffer: String, channel: String, authed: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }
            var buf = buffer
            var ch = channel
            var ok = authed
            if let data = data, !data.isEmpty {
                buf += String(decoding: data, as: UTF8.self)
                while let nl = buf.firstIndex(of: "\n") {
                    let line = String(buf[buf.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
                    buf = String(buf[buf.index(after: nl)...])
                    if !ok {
                        // Handshake or nothing — an unauthenticated peer never reaches ingest.
                        let parts = line.split(separator: " ").map(String.init)
                        guard parts.count >= 3, parts[0] == "NETSIGHT1", parts[1] == self.token,
                              parts[2] == "F" || parts[2] == "D" else { self.drop(conn); return }
                        ok = true; ch = parts[2]
                        self.lock.lock(); self.conns[ObjectIdentifier(conn)] = conn; let n = self.conns.count; self.lock.unlock()
                        self.onStats?(n)
                        continue
                    }
                    if !line.isEmpty { self.onLine?(ch, line) }
                }
                if buf.count > 300_000 { buf = "" }      // a peer sending garbage can't grow memory
            }
            if isComplete { self.drop(conn); return }
            self.receive(conn, buffer: buf, channel: ch, authed: ok)
        }
    }

    func stop() {
        lock.lock(); let cs = Array(conns.values); conns.removeAll(); lock.unlock()
        cs.forEach { $0.cancel() }
        listener?.cancel(); listener = nil
        onStats?(0)
    }
}

// MARK: - SSH collector (the reliable path to a better vantage point)
//
// Pushing a stream *to* the Mac runs into macOS's application firewall: an ad-hoc-signed
// binary gets a fresh identity on every rebuild, so inbound connections are silently
// dropped. Dialling *out* over SSH avoids that entirely, and is better anyway — nothing
// listens, the transport is encrypted, and it authenticates with keys that already exist.

struct CollectorHost: Identifiable, Equatable {
    var id: String { user + "@" + host }
    var user = "root"
    var host = ""
    var iface = "auto"
    var mode = "dns"          // dns | both
    var status = "idle"
    var dnsLines = 0
    var flowLines = 0
    var error = ""
}

final class SSHCollector {
    static let shared = SSHCollector()
    private var procs: [String: [Process]] = [:]        // host id -> its channel processes
    private let lock = NSLock()

    var onLine: ((String, String) -> Void)?             // (channel, line)
    var onStatus: ((String, String, String) -> Void)?   // (hostID, status, error)

    var activeHosts: [String] { lock.lock(); defer { lock.unlock() }; return Array(procs.keys) }
    func isRunning(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return procs[id] != nil }

    /// One tcpdump per channel, wrapped in ssh. The remote side auto-detects its own
    /// default-route interface, so this works on a Proxmox host and a router alike.
    func start(_ h: CollectorHost, macIP: String) {
        stop(h.id)
        var started: [Process] = []
        var channels: [(String, String)] = [("D", dnsCommand(h, macIP: macIP))]
        if h.mode == "both" { channels.append(("F", flowCommand(h, macIP: macIP))) }
        for (ch, remoteCmd) in channels {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                           "-o", "StrictHostKeyChecking=accept-new",
                           "-o", "ServerAliveInterval=20",
                           h.user + "@" + h.host, remoteCmd]
            let out = Pipe(); let err = Pipe()
            // An open stdin is the remote watchdog's lifeline: when this process dies the
            // pipe closes, the remote `read` sees EOF, and it kills its own tcpdump.
            // Without this a capture survives on the server after NetSight quits.
            p.standardInput = Pipe()
            p.standardOutput = out; p.standardError = err
            var buf = ""
            out.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let d = fh.availableData
                if d.isEmpty { return }
                buf += String(decoding: d, as: UTF8.self)
                while let nl = buf.firstIndex(of: "\n") {
                    let line = String(buf[buf.startIndex..<nl])
                    buf = String(buf[buf.index(after: nl)...])
                    if !line.isEmpty { self?.onLine?(ch, line) }
                }
                if buf.count > 300_000 { buf = "" }
            }
            err.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let d = fh.availableData
                guard !d.isEmpty else { return }
                let msg = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                // tcpdump chatters on stderr; only surface things that actually stop us.
                let fatal = ["Permission denied", "Host key verification", "Could not resolve",
                             "Connection refused", "command not found", "Operation timed out", "No route to host"]
                if fatal.contains(where: { msg.contains($0) }) {
                    self?.onStatus?(h.id, "error", msg.split(separator: "\n").first.map(String.init) ?? msg)
                }
            }
            p.terminationHandler = { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock(); let stillWanted = self.procs[h.id] != nil; self.lock.unlock()
                if stillWanted { self.onStatus?(h.id, "disconnected", "") }
            }
            do { try p.run(); started.append(p) } catch {
                onStatus?(h.id, "error", "could not launch ssh")
            }
        }
        guard !started.isEmpty else { return }
        lock.lock(); procs[h.id] = started; lock.unlock()
        onStatus?(h.id, "connected", "")
    }

    /// Excluding our own SSH session matters: without it the capture sees the stream it is
    /// producing and feeds on itself.
    private func remotePrelude(_ h: CollectorHost) -> String {
        h.iface == "auto"
            ? "IF=$(ip route show default 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1); IF=${IF:-any};"
            : "IF=\(h.iface);"
    }
    /// Runs tcpdump in the background and blocks on stdin. SSH closing stdin ends the wait
    /// and takes the capture down with it, so nothing is left running on the remote box.
    private func watchdog(_ capture: String) -> String {
        "\(capture) & TP=$!; trap 'kill $TP 2>/dev/null' EXIT INT TERM; while read -r _; do :; done; kill $TP 2>/dev/null"
    }
    private func dnsCommand(_ h: CollectorHost, macIP: String) -> String {
        remotePrelude(h) + " " + watchdog("tcpdump -i $IF -nn -t -l -s 512 'udp port 53 and not (host \(macIP) and tcp port 22)' 2>/dev/null")
    }
    private func flowCommand(_ h: CollectorHost, macIP: String) -> String {
        remotePrelude(h) + " " + watchdog("tcpdump -i $IF -nn -t -l -q 'not (host \(macIP) and tcp port 22)' 2>/dev/null")
    }

    func stop(_ id: String) {
        lock.lock(); let ps = procs.removeValue(forKey: id); lock.unlock()
        ps?.forEach { p in
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            p.terminate()
        }
        onStatus?(id, "idle", "")
    }
    func stopAll() { activeHosts.forEach { stop($0) } }
}

// MARK: - Capture engine

final class CaptureEngine: ObservableObject {
    @Published var events: [TrafficEvent] = []
    @Published var running = false
    @Published var status = "Idle"
    @Published var selectedView = "Feed"
    @Published var search = ""
    @Published var scopeFilter = "All"     // All / Public / Local / Inbound
    @Published var selectedDeviceIP = ""
    @Published var deviceDetailIP = ""
    @Published var grouped = false
    @Published var remoteActive = false
    @Published var focusSearchToken = 0     // bumped by ⌘F; the view moves focus to its search field
    @Published var rawFeed = false          // false = grouped by destination (the useful default)
    @Published var remotePeers = 0
    @Published var collectors: [CollectorHost] = []
    /// Freshness for the Network views: when the last packet was ingested. Nil until the first one.
    @Published var lastPacketAt: Date? = nil
    /// The flow shown in the detail column's inspector (Feed / Alerts).
    @Published var selectedFlowID: UUID? = nil
    var remoteFlowLines = 0
    var remoteDNSLines = 0
    var lastRemoteLine: Date? = nil
    let remotePort = 9999

    private var process: Process?
    private var dnsProcesses: [Process] = []
    private var buffer = ""
    private var recent: [String: Date] = [:]
    private var refreshTimer: Timer?
    private var lastPacketPublished = Date.distantPast
    private(set) var iface: String

    init() {
        NetPaths.migrateIfNeeded()
        self.iface = CaptureEngine.defaultInterface()
        // Quitting the app must not leave captures running on someone else's server.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            SSHCollector.shared.stopAll()
        }
    }

    /// "Live · capturing on en0" / "Paused" / "Stale · no packets for 3m" — the same treatment
    /// the topology feed gets, so no Network view can show old data without saying so.
    var isStale: Bool {
        guard running else { return true }
        guard let t = lastPacketAt else { return true }
        return Date().timeIntervalSince(t) > Options.shared.staleAfter
    }
    var staleText: String {
        if !running { return status.hasPrefix("Capture access") ? "Capture unavailable" : "Paused" }
        guard let t = lastPacketAt else { return "Live · waiting for traffic" }
        let s = Int(Date().timeIntervalSince(t))
        if Double(s) < Options.shared.staleAfter { return "Live · \(iface)" }
        if s < 3600 { return "Stale · no packets for \(s / 60)m" }
        return "Stale · no packets for \(s / 3600)h"
    }

    static func defaultInterface() -> String {
        let out = shell("/sbin/route", ["-n", "get", "default"])
        for line in out.split(separator: "\n") where line.contains("interface:") {
            return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "en0"
        }
        return "en0"
    }
    /// Interfaces worth offering in Settings: Ethernet/Wi-Fi, bridges and VPN tunnels.
    static func interfaces() -> [String] {
        shell("/sbin/ifconfig", ["-l"]).split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("en") || $0.hasPrefix("bridge") || $0.hasPrefix("utun") }
    }

    /// `interactive` = the user pressed Start: it's fine to raise the one-time admin prompt that
    /// installs the sudoers rule. An automatic start at launch never prompts — it just reports
    /// "Capture access denied" and the Network views offer an Enable button.
    func start(interactive: Bool = false) {
        guard !running else { return }
        status = "Requesting capture access…"
        let opts = Options.shared
        iface = opts.capInterface == "auto" ? CaptureEngine.defaultInterface() : opts.capInterface
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            NetID.shared.refresh()
            _ = ThreatDB.shared
            VisitLog.shared.prune(days: opts.capRetentionDays)
            VisitLog.shared.load()
            if opts.capFeeds { FeedUpdater.shared.update() }
            ProfileDB.shared.load()
            DispatchQueue.main.async {
                self.loadCollectorHosts()
                // A collector you've already set up should come back by itself after a restart.
                self.wireSSHCollector()
                for c in self.collectors { self.connectCollector(c) }
            }
            // First ever run has no roster, so every device would look like an intruder.
            // Take a longer census before the alert starts firing.
            AnomalyStore.shared.beginBaseline(seconds: ProfileDB.shared.wasEmptyAtLaunch ? 180 : Double(opts.capBaselineSec))
            let ok = self.ensurePrivilege(interactive: interactive)
            DispatchQueue.main.async { ok ? self.launch() : (self.status = "Capture access denied") }
            DispatchQueue.global().async { DeviceDB.shared.refresh(); AppDB.shared.refresh() }
        }
    }

    private func ensurePrivilege(interactive: Bool) -> Bool {
        if sudoOK() { return true }
        guard interactive else { return false }
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/sbin/tcpdump"
        let script = "do shell script \"echo '\(rule)' > /etc/sudoers.d/netsight && chmod 440 /etc/sudoers.d/netsight && chown root:wheel /etc/sudoers.d/netsight\" with administrator privileges"
        _ = shell("/usr/bin/osascript", ["-e", script])
        return sudoOK()
    }
    private func sudoOK() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/sbin/tcpdump", "-D"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func dnsSnifferInterfaces() -> [String] {
        var set = Set<String>([iface])
        for line in shell("/usr/sbin/scutil", ["--dns"]).split(separator: "\n") where line.contains("nameserver[0]") {
            let r = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !r.isEmpty else { continue }
            for l in shell("/sbin/route", ["-n", "get", r]).split(separator: "\n") where l.contains("interface:") {
                if let i = l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !i.isEmpty { set.insert(i) }
            }
        }
        return Array(set)
    }

    private func startDNSSniffer(on ifn: String) {
        let dp = Process()
        dp.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dp.arguments = ["-n", "/usr/sbin/tcpdump", "-i", ifn, "-nn", "-t", "-l", "udp port 53"]
        let dpipe = Pipe()
        dp.standardOutput = dpipe
        dp.standardError = FileHandle.nullDevice
        var buf = ""
        dpipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            buf += String(decoding: d, as: UTF8.self)
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[buf.startIndex..<nl])
                buf = String(buf[buf.index(after: nl)...])
                DNSMap.shared.ingest(line)
            }
        }
        do { try dp.run(); dnsProcesses.append(dp) } catch {}
    }

    private func startMDNSSniffer(on ifn: String) {
        let dp = Process()
        dp.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dp.arguments = ["-n", "/usr/sbin/tcpdump", "-i", ifn, "-nn", "-t", "-l", "udp port 5353"]
        let dpipe = Pipe()
        dp.standardOutput = dpipe
        dp.standardError = FileHandle.nullDevice
        var buf = ""
        dpipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            buf += String(decoding: d, as: UTF8.self)
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[buf.startIndex..<nl])
                buf = String(buf[buf.index(after: nl)...])
                DiscoveryDB.shared.ingest(line)
            }
            if buf.count > 200_000 { buf = "" }
        }
        do { try dp.run(); dnsProcesses.append(dp) } catch {}
    }

    private func startSNISniffer(on ifn: String) {
        let dp = Process()
        dp.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dp.arguments = ["-n", "/usr/sbin/tcpdump", "-i", ifn, "-nn", "-t", "-l", "-s", "0", "-x",
                        "tcp port 443 and (tcp[((tcp[12]&0xf0)>>2)]=22) and (tcp[((tcp[12]&0xf0)>>2)+5]=1)"]
        let dpipe = Pipe()
        dp.standardOutput = dpipe
        dp.standardError = FileHandle.nullDevice
        var buf = ""
        var curDst = ""
        var curSrc = ""
        var hex = ""
        func flush() {
            defer { curDst = ""; curSrc = ""; hex = "" }
            guard !curDst.isEmpty, !hex.isEmpty else { return }
            var bytes: [UInt8] = []; bytes.reserveCapacity(hex.count / 2)
            var idx = hex.startIndex
            while let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex), next <= hex.endIndex {
                if let byte = UInt8(hex[idx..<next], radix: 16) { bytes.append(byte) }
                idx = next
                if idx == hex.endIndex { break }
            }
            if let sni = sniFromIPv4Packet(bytes) {
                DNSMap.shared.set(curDst, domain: sni)
                // The ClientHello's source is the device opening the connection — that's a visit.
                if !curSrc.isEmpty, isPrivateIP(curSrc) || NetID.shared.isMe(curSrc) {
                    VisitLog.shared.record(device: curSrc, domain: sni, bytes: 0, hit: true)
                }
            }
        }
        dpipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            buf += String(decoding: d, as: UTF8.self)
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[buf.startIndex..<nl])
                buf = String(buf[buf.index(after: nl)...])
                if line.hasPrefix("IP ") || line.hasPrefix("IP6 ") {
                    flush()
                    if line.hasPrefix("IP6 ") { curDst = ""; curSrc = ""; hex = "" }   // IPv6 SNI skipped for now
                    else if let gt = line.range(of: " > ") {
                        let rest = line[gt.upperBound...]
                        if let colon = rest.range(of: ".443:") { curDst = String(rest[rest.startIndex..<colon.lowerBound]) }
                        let head = line[line.index(line.startIndex, offsetBy: 3)..<gt.lowerBound]
                        if let (src, _) = splitEndpoint(String(head)) { curSrc = src }
                    }
                } else if let c = line.range(of: "0x"), let colon = line[c.lowerBound...].range(of: ": ") {
                    hex += line[colon.upperBound...].replacingOccurrences(of: " ", with: "")
                }
            }
            if buf.count > 300_000 { buf = "" }
        }
        do { try dp.run(); dnsProcesses.append(dp) } catch {}
    }

    private func startDHCPSniffer(on ifn: String) {
        let dp = Process()
        dp.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dp.arguments = ["-n", "/usr/sbin/tcpdump", "-i", ifn, "-nn", "-t", "-l", "-v", "udp port 67 or udp port 68"]
        let dpipe = Pipe()
        dp.standardOutput = dpipe
        dp.standardError = FileHandle.nullDevice
        var buf = ""; var pkt = ""
        func flush() { if !pkt.isEmpty { DiscoveryDB.shared.ingestDHCP(pkt); pkt = "" } }
        dpipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            buf += String(decoding: d, as: UTF8.self)
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[buf.startIndex..<nl])
                buf = String(buf[buf.index(after: nl)...])
                if line.hasPrefix("IP ") || line.hasPrefix("IP6 ") { flush(); pkt = line }
                else { pkt += "\n" + line }
            }
            if buf.count > 200_000 { buf = "" }
        }
        do { try dp.run(); dnsProcesses.append(dp) } catch {}
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/sbin/tcpdump", "-i", iface, "-nn", "-t", "-q", "-l"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { return }
            guard let self = self else { return }
            self.buffer += String(decoding: d, as: UTF8.self)
            while let nl = self.buffer.firstIndex(of: "\n") {
                let line = String(self.buffer[self.buffer.startIndex..<nl])
                self.buffer = String(self.buffer[self.buffer.index(after: nl)...])
                self.ingest(line)
            }
        }
        do { try p.run() } catch { status = "Failed to start tcpdump"; return }
        process = p
        let opts = Options.shared
        if opts.capDNS { for ifn in dnsSnifferInterfaces() { startDNSSniffer(on: ifn) } }
        if opts.capMDNS { startMDNSSniffer(on: iface) }
        if opts.capSNI { startSNISniffer(on: iface) }
        if opts.capDHCP { startDHCPSniffer(on: iface) }
        running = true
        status = "Capturing on \(iface)"
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            DispatchQueue.global().async {
                DeviceDB.shared.refresh(); AppDB.shared.refresh()
                ProfileDB.shared.sweep()          // passive: folds the refreshed neighbour tables in
                HistoryStore.shared.persist(); VisitLog.shared.persist()
                ProfileDB.shared.persist()
            }
        }
    }

    private func ingest(_ line: String, viaCollector: Bool = false) {
        guard let f = parseLine(line) else { return }
        let privSrc = isPrivateIP(f.src), privDst = isPrivateIP(f.dst)
        let meSrc = NetID.shared.isMe(f.src), meDst = NetID.shared.isMe(f.dst)
        let svc = servicePort(f.sport, f.dport)
        let bothPriv = privSrc && privDst

        let direction: String
        if bothPriv { direction = "local" }
        else if meSrc { direction = "out" }
        else if meDst { direction = "in" }
        else if viaCollector && privSrc { direction = "out" }
        else if viaCollector && privDst { direction = "in" }
        else { direction = "observed" }

        let remote = !privDst ? f.dst : (!privSrc ? f.src : (meSrc ? f.dst : f.src))
        let localParty = privSrc ? f.src : (privDst ? f.dst : "")
        let meIP = meSrc ? f.src : (meDst ? f.dst : "")
        let mePort = meSrc ? f.sport : (meDst ? f.dport : 0)

        let key = [f.src, f.dst].sorted().joined(separator: "|") + "|\(svc)|\(f.proto)"
        let now = Date()
        FlowStats.shared.add(key, bytes: f.len, outbound: meSrc || (viaCollector && privSrc))

        let orgHit = OrgDB.shared.lookup(remote)
        let host = DNSMap.shared.domain(remote) ?? NameCache.shared.name(remote) ?? orgHit?.org ?? remote
        let org = orgHit?.org ?? ""
        let country = orgHit?.country ?? ""
        HistoryStore.shared.add(device: localParty, remote: remote, org: org, bytes: f.len, port: svc, isPrivate: bothPriv)
        if !bothPriv, !localParty.isEmpty, f.len > 0, let dom = DNSMap.shared.domain(remote) {
            VisitLog.shared.record(device: localParty, domain: dom, bytes: f.len, hit: false)
        }
        let category = bothPriv ? "Local" : categoryFor(host: host, org: org, port: svc)
        let threat = ThreatDB.shared.classify(remote: remote, host: host, org: org, port: svc, isPrivate: bothPriv)
        if isDeviceIP(localParty) && !NetID.shared.isMe(localParty) { AnomalyStore.shared.noteDevice(localParty) }
        if threat.hasPrefix("confirmed") {
            AnomalyStore.shared.raise(level: "bad", title: "Confirmed malicious connection",
                detail: "\(deviceLabel(localParty)) → \(host) — \(threat.replacingOccurrences(of: "confirmed:", with: ""))",
                deviceIP: localParty, key: "threat:\(remote)", notify: true)
        }
        if !bothPriv, !Options.shared.muteLargeUpload, let st = FlowStats.shared.get(key), st.outBytes > 50_000_000 {
            let who = deviceLabel(localParty)
            AnomalyStore.shared.raise(level: "review", title: "Large upload from a device",
                detail: "\(who.isEmpty ? "A device" : who) sent \(fmtBytes(st.outBytes)) to \(bestHostForIP(remote))",
                deviceIP: localParty, key: "exfil:\(key)", notify: true)
        }
        let device = localParty.isEmpty ? "" : (NetID.shared.isMe(localParty) ? "This Mac" : (DeviceDB.shared.label(localParty) ?? "Local device"))
        let app = meIP.isEmpty ? "" : (AppDB.shared.app(meIP: meIP, mePort: mePort) ?? "")
        let origin = "\(partyLabel(f.src)) → \(partyLabel(f.dst))"

        DispatchQueue.main.async {
            // Freshness: publish at most once a second so the pill doesn't churn the view tree per packet.
            if now.timeIntervalSince(self.lastPacketPublished) >= 1 { self.lastPacketPublished = now; self.lastPacketAt = now }
            if let last = self.recent[key], now.timeIntervalSince(last) < 5 { return }
            self.recent[key] = now
            let ev = TrafficEvent(src: f.src, dst: f.dst, sport: f.sport, dport: f.dport, proto: f.proto,
                                  servicePort: svc, direction: direction, originSummary: origin,
                                  device: device, app: app, host: host, remoteIP: remote, org: org, country: country,
                                  category: category, deviceIP: localParty, threat: threat, isPrivate: bothPriv, bytes: f.len, flowKey: key)
            self.events.insert(ev, at: 0)
            let cap = max(100, Options.shared.feedLiveCap)
            if self.events.count > cap { self.events.removeLast(self.events.count - cap) }
            if self.recent.count > 6000 { self.recent = self.recent.filter { now.timeIntervalSince($0.value) < 5 } }
        }
    }

    func stop() {
        process?.terminate(); process = nil
        dnsProcesses.forEach { $0.terminate() }; dnsProcesses.removeAll()
        SSHCollector.shared.stopAll()
        refreshTimer?.invalidate(); running = false; status = "Stopped"
    }
    func clear() { events.removeAll() }

    func startRemote() {
        RemoteListener.shared.onLine = { [weak self] channel, line in
            guard let self = self else { return }
            if channel == "D" {
                // A gateway's DNS stream is the whole point: every query carries the *client's*
                // address, so VisitLog attributes sites to the device that asked for them.
                DNSMap.shared.ingest(line)
                self.remoteDNSLines &+= 1
            } else {
                self.ingest(line, viaCollector: true)
                self.remoteFlowLines &+= 1
            }
            self.lastRemoteLine = Date()
        }
        RemoteListener.shared.onStats = { [weak self] n in
            DispatchQueue.main.async { self?.remotePeers = n }
        }
        RemoteListener.shared.start(port: UInt16(remotePort))
        remoteActive = true
    }
    func stopRemote() {
        RemoteListener.shared.stop(); remoteActive = false
        remotePeers = 0; remoteFlowLines = 0; remoteDNSLines = 0
    }
    // ── SSH collectors ─────────────────────────────────────────────────────────

    func loadCollectorHosts() {
        guard let text = try? String(contentsOfFile: collectorsPath, encoding: .utf8) else { return }
        var out: [CollectorHost] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 4 else { continue }
            out.append(CollectorHost(user: c[0], host: c[1], iface: c[2], mode: c[3]))
        }
        collectors = out
    }
    private var collectorsPath: String { NetPaths.dir + "/collectors.tsv" }
    func saveCollectorHosts() {
        let lines = collectors.map { "\($0.user)\t\($0.host)\t\($0.iface)\t\($0.mode)" }
        try? ("# user\thost\tiface\tmode\n" + lines.joined(separator: "\n"))
            .write(toFile: collectorsPath, atomically: true, encoding: .utf8)
    }

    func wireSSHCollector() {
        SSHCollector.shared.onLine = { [weak self] channel, line in
            guard let self = self else { return }
            if channel == "D" {
                DNSMap.shared.ingest(line)          // carries the querying device's own address
                self.remoteDNSLines &+= 1
            } else {
                self.ingest(line, viaCollector: true)
                self.remoteFlowLines &+= 1
            }
            self.lastRemoteLine = Date()
        }
        SSHCollector.shared.onStatus = { [weak self] id, status, err in
            DispatchQueue.main.async {
                guard let self = self, let i = self.collectors.firstIndex(where: { $0.id == id }) else { return }
                self.collectors[i].status = status
                self.collectors[i].error = err
            }
        }
    }

    func connectCollector(_ h: CollectorHost) {
        wireSSHCollector()
        if let i = collectors.firstIndex(where: { $0.id == h.id }) { collectors[i].status = "connecting" }
        SSHCollector.shared.start(h, macIP: NetID.shared.lanIP)
    }
    func disconnectCollector(_ h: CollectorHost) { SSHCollector.shared.stop(h.id) }

    var collectorToken: String {
        if RemoteListener.shared.token.isEmpty { RemoteListener.shared.loadOrCreateToken() }
        return RemoteListener.shared.token
    }

    var filtered: [TrafficEvent] {
        let o = Options.shared
        let hideLocal = o.feedHideLocal, hideDNS = o.feedHideDNS, minBytes = o.feedMinBytes
        return events.filter { ev in
            if hideLocal && ev.isPrivate { return false }
            if hideDNS && (ev.category == "DNS / system" || ev.servicePort == 53 || ev.servicePort == 5353) { return false }
            if minBytes > 0 && volumeOf(ev).total < minBytes { return false }
            if !selectedDeviceIP.isEmpty && ev.src != selectedDeviceIP && ev.dst != selectedDeviceIP { return false }
            switch scopeFilter {
            case "Public": if ev.isPrivate { return false }
            case "Local": if !ev.isPrivate { return false }
            case "Inbound": if ev.direction != "in" { return false }
            default: break
            }
            if search.isEmpty { return true }
            let s = search.lowercased()
            return ev.host.lowercased().contains(s) || ev.org.lowercased().contains(s)
                || ev.app.lowercased().contains(s) || ev.device.lowercased().contains(s)
                || ev.category.lowercased().contains(s) || ev.dst.contains(s) || ev.src.contains(s)
        }
    }

    var deviceInventory: [DeviceRow] {
        var map: [String: (flows: Int, dests: Set<String>)] = [:]
        for e in events {
            if isDeviceIP(e.src) { var v = map[e.src] ?? (0, []); v.flows += 1; v.dests.insert(e.org.isEmpty ? e.host : e.org); map[e.src] = v }
            if isDeviceIP(e.dst) && e.dst != e.src { var v = map[e.dst] ?? (0, []); v.flows += 1; v.dests.insert(e.org.isEmpty ? e.host : e.org); map[e.dst] = v }
        }
        // One machine can show up under several addresses (LAN IPv4, link-local IPv6, tailnet).
        // Merge on hardware address where we have one — that's the identity that doesn't drift.
        var merged: [String: (ip: String, flows: Int, dests: Set<String>)] = [:]
        for (ip, v) in map {
            let m = resolveDevice(ip)
            let mac = normalizeMAC(DeviceDB.shared.mac(ip) ?? "") ?? ""
            let key: String
            if m.isMe { key = "\u{1}me" }
            else if !mac.isEmpty { key = "m:" + mac }
            else if m.name != ip { key = "n:" + m.name }
            else { key = ip }
            var cur = merged[key] ?? (ip, 0, [])
            cur.flows += v.flows; cur.dests.formUnion(v.dests)
            // an IPv4 address is the more useful identity than a link-local IPv6
            if cur.ip.contains(":") && !ip.contains(":") { cur.ip = ip }
            merged[key] = cur
        }
        return merged.values.map { v -> DeviceRow in
            let m = resolveDevice(v.ip)
            let dc = deviceClass(v.ip)
            return DeviceRow(ip: v.ip, name: m.name, type: m.type, icon: m.icon, vendor: m.vendor,
                             flows: v.flows, dests: v.dests.count, isMe: m.isMe, klass: dc.klass, os: dc.os, classIcon: dc.icon)
        }.sorted { $0.flows > $1.flows }
    }

    var alerts: [TrafficEvent] { events.filter { !$0.threat.isEmpty } }
}

// MARK: - Storage location (migrated from NetSight's App Support folder on first launch)

enum NetPaths {
    static let appDir = NSHomeDirectory() + "/Library/Application Support/HatchMap"
    static let dir = appDir + "/network"
    private static let legacy = NSHomeDirectory() + "/Library/Application Support/NetSight"

    /// One identity means one data folder. NetSight's roster, visit logs, threat caches, collector
    /// token and policies are copied across once; the old folder is left untouched.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dir) { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: legacy) else { return }
        for n in names where !n.hasPrefix(".") {
            try? fm.copyItem(atPath: legacy + "/" + n, toPath: dir + "/" + n)
        }
    }
}
