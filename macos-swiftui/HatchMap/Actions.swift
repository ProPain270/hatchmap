import AppKit
import Foundation
import SwiftUI

// MARK: - Remote control
//
// Every action is tailnet-only and token-gated: containers and stack scripts go through the
// hatch-actions service on the server (deployed from backend/install.sh), guest power goes
// straight to the Proxmox API with a least-privilege token, and "Open SSH" hands the host to
// Terminal with the keys that already exist on this Mac. Destructive operations confirm first.

struct ActionHealth: Decodable {
    struct Notify: Decodable {
        var ntfy: String?
        var topic: String?
        var last_push: String?
        var last_check: String?
        var enabled: Bool?
    }
    var ok: Bool
    var version: String?
    var host: String?
    var time: String?
    var docker_ok: Bool?
    var uptime_s: Double?
    var notify: Notify?
}

struct ContainerInfo: Decodable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var state: String      // running | exited | restarting | paused | created
    var status: String     // "Up 3 days (healthy)"
    var image: String
    var isRunning: Bool { state == "running" }
}

struct ScriptInfo: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var description: String
    var unit: String
    var match: [String]?
    var last_run: String?
    var last_result: String?
    var running: Bool?
}

struct ActionResult: Decodable {
    var ok: Bool
    var output: String?
    var error: String?
    var updated: String?
}

struct PushConfig: Decodable {
    var ntfy: String
    var topic: String
    var enabled: Bool
    var events: [String: Bool]
}

struct ActionLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let target: String
    let op: String
    let ok: Bool
    let message: String
}

/// A confirmed-before-run request. `destructive` drives the dialog's button style and wording.
struct PendingAction: Identifiable {
    enum Kind { case container(String, String), script(ScriptInfo), pve(PVEGuest, String), topologyRefresh }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let destructive: Bool
}

final class ActionService: ObservableObject {
    // Placeholder — set the real action-service URL in Settings › Control; this host never resolves.
    static let defaultEndpoint = "https://your-node.your-tailnet.example:8771"

    @Published var health: ActionHealth?
    @Published var lastOK: Date?
    @Published var error = ""
    @Published var containers: [ContainerInfo] = []
    @Published var scripts: [ScriptInfo] = []
    @Published var log: [ActionLogEntry] = []
    @Published var busy: Set<String> = []
    @Published private(set) var tokenFromFile = false
    @Published var pushConfig: PushConfig?
    @Published var pushError = ""
    @Published var pushTestResult = ""

    let pve = ProxmoxClient()
    private var pollTask: Task<Void, Never>?
    private let tokenPath = NetPaths.appDir + "/actions-token"
    private let logPath = NetPaths.appDir + "/actions-log.tsv"
    private let iso = ISO8601DateFormatter()

    var endpoint: URL {
        let s = UserDefaults.standard.string(forKey: "actionsURL") ?? ""
        return URL(string: s.isEmpty ? Self.defaultEndpoint : s) ?? URL(string: Self.defaultEndpoint)!
    }
    var token: String {
        let s = (UserDefaults.standard.string(forKey: "actionsToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    var configured: Bool { !token.isEmpty }
    var isStale: Bool { guard let d = lastOK else { return true }; return Date().timeIntervalSince(d) > max(Options.shared.staleAfter, Options.shared.actionsPoll * 2) }
    var statusText: String {
        if !configured { return "No action token — see Settings › Control" }
        if health == nil { return error.isEmpty ? "Connecting…" : "Unreachable — \(error)" }
        guard let d = lastOK else { return "Unreachable" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 120 { return "Live · \(health?.host ?? "action service")" }
        return "Stale · last reply \(s / 60)m ago"
    }

    func start() {
        guard pollTask == nil else { return }
        try? FileManager.default.createDirectory(atPath: NetPaths.appDir, withIntermediateDirectories: true)
        tokenFromFile = FileManager.default.fileExists(atPath: tokenPath)
        loadLog()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshNow()
                try? await Task.sleep(for: .seconds(max(15, Options.shared.actionsPoll)))
            }
        }
    }
    deinit { pollTask?.cancel() }

    // MARK: push rules (server-side hatch-notify config)

    func loadPushConfig() {
        guard configured else { return }
        Task { @MainActor in
            do {
                let r: [String: PushConfig] = try await get("/notify/config")
                pushConfig = r["notify"]; pushError = ""
            } catch { pushError = "Couldn't load push rules: \(error.localizedDescription)" }
        }
    }
    func updatePush(_ patch: [String: Any]) {
        Task { @MainActor in
            do {
                var req = request("/notify/config", method: "PUT")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: patch)
                let (d, r) = try await URLSession.shared.data(for: req)
                try Self.check(r, d)
                struct PushResponse: Decodable { var ok: Bool; var notify: PushConfig? }
                let res = try JSONDecoder().decode(PushResponse.self, from: d)
                if let n = res.notify { pushConfig = n }
                pushError = ""
            } catch { pushError = "Couldn't save push rules: \(error.localizedDescription)" }
        }
    }
    func testPush() {
        pushTestResult = "Sending…"
        Task { @MainActor in
            do { let r = try await post("/notify/test", timeout: 20); pushTestResult = r.ok ? "Sent — check your phone." : (r.error ?? "failed") }
            catch { pushTestResult = error.localizedDescription }
        }
    }

    func refreshNow() {
        tokenFromFile = FileManager.default.fileExists(atPath: tokenPath)
        Task { await refresh() }
        if pve.configured { Task { await pve.refresh() } }
    }

    @MainActor
    private func refresh() async {
        guard configured else { return }
        do {
            let h: ActionHealth = try await get("/health")
            let c: [String: [ContainerInfo]] = try await get("/containers")
            let s: [String: [ScriptInfo]] = try await get("/scripts")
            health = h; containers = (c["containers"] ?? []).sorted { $0.name < $1.name }
            scripts = s["scripts"] ?? []
            lastOK = Date(); error = ""
        } catch {
            self.error = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            if lastOK == nil || Date().timeIntervalSince(lastOK!) > 600 { health = nil }
        }
    }

    // MARK: HTTP

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 15) -> URLRequest {
        var req = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (d, r) = try await URLSession.shared.data(for: request(path))
        try Self.check(r, d)
        return try JSONDecoder().decode(T.self, from: d)
    }
    private func post(_ path: String, timeout: TimeInterval = 90) async throws -> ActionResult {
        let (d, r) = try await URLSession.shared.data(for: request(path, method: "POST", timeout: timeout))
        try Self.check(r, d)
        return try JSONDecoder().decode(ActionResult.self, from: d)
    }
    private static func check(_ r: URLResponse, _ d: Data) throws {
        guard let http = r as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw NSError(domain: "hatch", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "token rejected (HTTP \(http.statusCode))"]) }
        if http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode(ActionResult.self, from: d))?.error ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "hatch", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: actions

    @MainActor
    func perform(_ p: PendingAction) async {
        let key = p.title
        busy.insert(key); defer { busy.remove(key) }
        switch p.kind {
        case .container(let name, let op):
            await run(target: name, op: op) { try await self.post("/containers/\(name)/\(op)") }
        case .script(let s):
            await run(target: s.title, op: "run") { try await self.post("/scripts/\(s.id)") }
        case .topologyRefresh:
            await run(target: "topology", op: "refresh") { try await self.post("/topology/refresh", timeout: 40) }
        case .pve(let g, let op):
            let r = await pve.power(g, op)
            record(target: "\(g.type == "lxc" ? "CT" : "VM")\(g.vmid) \(g.name)", op: op, ok: r.ok, message: r.message)
            await pve.refresh()
        }
        await refresh()
    }

    @MainActor
    private func run(target: String, op: String, _ body: () async throws -> ActionResult) async {
        do {
            let r = try await body()
            record(target: target, op: op, ok: r.ok, message: r.error ?? r.output ?? (r.ok ? "done" : "failed"))
        } catch {
            record(target: target, op: op, ok: false, message: error.localizedDescription)
        }
    }

    private func record(target: String, op: String, ok: Bool, message: String) {
        let e = ActionLogEntry(time: Date(), target: target, op: op, ok: ok, message: message)
        log.insert(e, at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
        let line = "\(iso.string(from: e.time))\t\(target)\t\(op)\t\(ok)\t\(message.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))\n"
        if !FileManager.default.fileExists(atPath: logPath) { try? "# time\ttarget\top\tok\tmessage\n".write(toFile: logPath, atomically: true, encoding: .utf8) }
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8) ?? Data()); try? h.close() }
        Notifier.shared.post(title: ok ? "\(op.capitalized) \(target)" : "\(op.capitalized) \(target) failed", body: String(message.prefix(140)), id: "act-\(target)-\(op)-\(ok)", kind: .action)
    }

    private func loadLog() {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        var out: [ActionLogEntry] = []
        for line in text.split(separator: "\n").suffix(300) where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 5, let t = iso.date(from: c[0]) else { continue }
            out.append(ActionLogEntry(time: t, target: c[1], op: c[2], ok: c[3] == "true", message: c[4]))
        }
        log = out.reversed()
    }

    // MARK: matching topology nodes to controllable things

    static func norm(_ s: String) -> String {
        let base = s.split(separator: "×").first.map(String.init) ?? s
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    func containers(for node: HNode) -> [ContainerInfo] {
        guard node.t == "docker" else { return [] }
        let n = Self.norm(node.name)
        guard !n.isEmpty else { return [] }
        if let exact = containers.first(where: { Self.norm($0.name) == n }) { return [exact] }
        let pref = containers.filter { Self.norm($0.name).hasPrefix(n) }
        if !pref.isEmpty { return pref }
        return containers.filter { Self.norm($0.name).contains(n) || n.contains(Self.norm($0.name)) && Self.norm($0.name).count >= 5 }
    }
    func script(for node: HNode) -> ScriptInfo? {
        let n = Self.norm(node.name)
        return scripts.first { s in (s.match ?? []).contains { Self.norm($0) == n } || Self.norm(s.id) == n }
    }
}

// MARK: - Proxmox (guest power via API token)

struct PVEGuest: Identifiable, Hashable {
    var id: String { "\(type)/\(vmid)" }
    let vmid: Int
    let name: String
    let type: String      // lxc | qemu
    let node: String
    let status: String    // running | stopped
}

final class ProxmoxClient: NSObject, ObservableObject, URLSessionDelegate {
    static let defaultHost = "https://192.0.2.10:8006"   // placeholder — set your Proxmox host in Settings › Control
    @Published var guests: [PVEGuest] = []
    @Published var error = ""
    @Published var lastOK: Date?

    var host: URL {
        let s = UserDefaults.standard.string(forKey: "pveHost") ?? ""
        return URL(string: s.isEmpty ? Self.defaultHost : s) ?? URL(string: Self.defaultHost)!
    }
    var tokenID: String { UserDefaults.standard.string(forKey: "pveTokenID") ?? "" }
    var secret: String { UserDefaults.standard.string(forKey: "pveSecret") ?? "" }
    var configured: Bool { !tokenID.isEmpty && !secret.isEmpty }

    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    /// Proxmox ships a self-signed certificate. Trust is pinned to the configured host only —
    /// every other host still gets full verification.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host.host(percentEncoded: false), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private func req(_ path: String, method: String = "GET") -> URLRequest {
        // Built as a string: appendingPathComponent would percent-encode the "?type=vm" query.
        let base = host.absoluteString.hasSuffix("/") ? String(host.absoluteString.dropLast()) : host.absoluteString
        let url = URL(string: base + "/api2/json" + path) ?? host
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        r.setValue("PVEAPIToken=\(tokenID)=\(secret)", forHTTPHeaderField: "Authorization")
        return r
    }

    @MainActor
    func refresh() async {
        guard configured else { return }
        do {
            let (d, r) = try await session.data(for: req("/cluster/resources?type=vm"))
            if let http = r as? HTTPURLResponse, http.statusCode >= 400 { throw NSError(domain: "pve", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from Proxmox"]) }
            let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let data = obj?["data"] as? [[String: Any]] ?? []
            guests = data.compactMap { g in
                guard let vmid = g["vmid"] as? Int, let type = g["type"] as? String else { return nil }
                return PVEGuest(vmid: vmid, name: g["name"] as? String ?? "vm\(vmid)", type: type,
                                node: g["node"] as? String ?? "", status: g["status"] as? String ?? "unknown")
            }.sorted { $0.vmid < $1.vmid }
            lastOK = Date(); error = ""
        } catch { self.error = error.localizedDescription }
    }

    func power(_ g: PVEGuest, _ op: String) async -> (ok: Bool, message: String) {
        do {
            let (d, r) = try await session.data(for: req("/nodes/\(g.node)/\(g.type)/\(g.vmid)/status/\(op)", method: "POST"))
            if let http = r as? HTTPURLResponse, http.statusCode >= 400 {
                return (false, "HTTP \(http.statusCode): \(String(decoding: d, as: UTF8.self).prefix(200))")
            }
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            return (true, "task \(obj?["data"] as? String ?? "queued")")
        } catch { return (false, error.localizedDescription) }
    }

    func guest(forVMID id: Int) -> PVEGuest? { guests.first { $0.vmid == id } }
}

// MARK: - SSH via Terminal (no automation permission needed: a .command file opens in Terminal)

enum TerminalLauncher {
    static func openSSH(user: String = "root", host: String) {
        let dir = NetPaths.appDir + "/ssh"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let safe = host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let path = dir + "/\(user)@\(safe).command"
        let script = "#!/bin/bash\nprintf '\\033]0;%s\\007' 'ssh \(user)@\(host)'\nexec ssh -o ConnectTimeout=8 \(user)@\(host)\n"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Pulls an SSH target out of a node's meta line: "192.0.2.10 · PVE 9.2" → 192.0.2.10,
    /// "CT105 · .240" → <subnet>.240 when another host on the map reveals the /24.
    static func sshHost(for node: HNode, in topo: Topology?) -> String? {
        guard ["host", "lxc", "vm"].contains(node.t) else { return nil }
        if let ip = firstIPv4(node.meta) { return ip }
        if let m = node.meta.range(of: #"(^|\s)\.(\d{1,3})\b"#, options: .regularExpression) {
            let last = node.meta[m].filter { $0.isNumber }
            let prefixes = topo?.groups.flatMap { $0.nodes }.compactMap { firstIPv4($0.meta) }
                .map { $0.split(separator: ".").prefix(3).joined(separator: ".") } ?? []
            if let p = prefixes.first { return "\(p).\(last)" }
        }
        return nil
    }
    static func firstIPv4(_ s: String) -> String? {
        guard let r = s.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) else { return nil }
        let ip = String(s[r])
        return ip.hasPrefix("100.") ? nil : ip     // prefer the LAN address over the tailnet one
    }
    static func vmid(for node: HNode) -> Int? {
        guard let r = node.meta.range(of: #"\b(?:CT|VM)\s?(\d{2,5})\b"#, options: .regularExpression) else { return nil }
        return Int(node.meta[r].filter { $0.isNumber })
    }
}

// MARK: - Views

struct ActionHealthPill: View {
    @ObservedObject var actions: ActionService
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(actions.health == nil ? Color.orange : (actions.isStale ? Color.orange : Color.green)).frame(width: 8, height: 8)
            Text(actions.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }
}

struct ActionsView: View {
    @EnvironmentObject private var actions: ActionService
    @EnvironmentObject private var svc: TopologyService
    @EnvironmentObject private var options: Options
    @State private var pending: PendingAction?
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Actions").font(.largeTitle.bold())
                        Text("Remote control — tailnet-only, token-gated, every step confirmed and logged")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ActionHealthPill(actions: actions)
                }

                if !actions.configured {
                    setupCard
                } else if actions.health == nil {
                    Label(actions.statusText, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if options.actShowHosts { hostsSection }
                if actions.configured {
                    if options.actShowScripts { scriptsSection }
                    if options.actShowContainers { containersSection }
                }
                if options.actShowProxmox { proxmoxSection }
            }
            .padding(20)
        }
        .navigationTitle("Actions")
        .onChange(of: pending?.id) { _, _ in
            // "Confirm safe actions" off → run non-destructive actions straight away.
            if let p = pending, !p.destructive, !options.actConfirmSafe { pending = nil; Task { await actions.perform(p) } }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.destructive ? "Yes, \(p.title.lowercased())" : p.title, role: p.destructive ? .destructive : nil) {
                Task { await actions.perform(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text(p.detail) }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Action service not connected", systemImage: "key").font(.headline)
            Text("Deploy the backend on the server (backend/install.sh in the project) and put its token in Settings › Control, or drop it at ~/Library/Application Support/HatchMap/actions-token. Until then, SSH and Proxmox actions still work from here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Open Settings") }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }

    private var hostsSection: some View {
        let hosts = (svc.topo?.groups.flatMap { $0.nodes } ?? []).compactMap { n -> (HNode, String)? in
            TerminalLauncher.sshHost(for: n, in: svc.topo).map { (n, $0) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Hosts · SSH").font(.headline)
            if hosts.isEmpty {
                Text("No host addresses in the topology yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340))], spacing: 10) {
                    ForEach(hosts, id: \.0.uid) { item in
                        let n = item.0, ip = item.1
                        HStack(spacing: 10) {
                            Image(systemName: Palette.icon(n.t)).foregroundStyle(Palette.color(n.t))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(.callout.weight(.medium))
                                Text("\(options.actSSHUser)@\(ip)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Spacer()
                            Button { TerminalLauncher.openSSH(user: options.actSSHUser, host: ip) } label: { Label("SSH", systemImage: "terminal") }
                                .controlSize(.small)
                        }
                        .padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stack scripts").font(.headline)
                Spacer()
                Button {
                    pending = PendingAction(kind: .topologyRefresh, title: "Refresh topology now", detail: "Runs hatch-topology-gen on the server immediately instead of waiting for the 2-minute timer.", destructive: false)
                } label: { Label("Refresh topology now", systemImage: "arrow.triangle.2.circlepath") }
                .controlSize(.small)
            }
            if actions.scripts.isEmpty {
                Text("The action service reports no scripts. Edit /etc/hatch-actions/config.json on the server to add allow-listed units.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(actions.scripts) { s in
                HStack(spacing: 12) {
                    Image(systemName: "scroll").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.callout.weight(.medium))
                        Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(lastRunText(s)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if actions.busy.contains("Run \(s.title)") || s.running == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Run") {
                            pending = PendingAction(kind: .script(s), title: "Run \(s.title)", detail: "\(s.description)\n\nStarts \(s.unit) on the server.", destructive: false)
                        }.controlSize(.small)
                    }
                }
                .padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            }
        }
    }

    private func lastRunText(_ s: ScriptInfo) -> String {
        var bits: [String] = []
        if let lr = s.last_run, !lr.isEmpty { bits.append("last run \(lr)") }
        if let r = s.last_result, !r.isEmpty { bits.append(r) }
        bits.append(s.unit)
        return bits.joined(separator: " · ")
    }

    private var containersSection: some View {
        let list = actions.containers.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        let down = list.filter { !$0.isRunning }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Containers").font(.headline)
                Text("\(actions.containers.filter(\.isRunning).count) / \(actions.containers.count) running")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            ForEach(down + list.filter(\.isRunning)) { c in containerRow(c) }
        }
    }

    private func containerRow(_ c: ContainerInfo) -> some View {
        HStack(spacing: 12) {
            StatusDot(state: c.isRunning ? "up" : (c.state == "restarting" ? "warn" : "down"))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.callout.weight(.medium))
                Text("\(c.status) · \(c.image)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ContainerButtons(container: c, pending: $pending)
        }
        .padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.isRunning ? Theme.border : Color.red.opacity(0.35), lineWidth: 1))
    }

    private var proxmoxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proxmox guests").font(.headline)
                Spacer()
                if actions.pve.configured {
                    Text(actions.pve.error.isEmpty ? (actions.pve.lastOK == nil ? "Connecting…" : "Live · \(actions.pve.host.host(percentEncoded: false) ?? "")") : actions.pve.error)
                        .font(.caption).foregroundStyle(actions.pve.error.isEmpty ? Color.secondary : Color.orange)
                }
            }
            if !actions.pve.configured {
                Text("Add a Proxmox API token in Settings › Control to start, stop and reboot LXCs and VMs from here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if actions.pve.guests.isEmpty {
                Text("No guests reported yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(actions.pve.guests) { g in
                HStack(spacing: 12) {
                    StatusDot(state: g.status == "running" ? "up" : "down")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(g.type == "lxc" ? "CT" : "VM")\(g.vmid) · \(g.name)").font(.callout.weight(.medium))
                        Text("\(g.node) · \(g.status)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PVEButtons(guest: g, pending: $pending)
                }
                .padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            }
        }
    }
}

struct ContainerButtons: View {
    let container: ContainerInfo
    @Binding var pending: PendingAction?
    @EnvironmentObject private var actions: ActionService
    var body: some View {
        let c = container
        if actions.busy.contains(where: { $0.hasSuffix(" \(c.name)") }) {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 6) {
                if c.isRunning {
                    Button("Restart") { pending = PendingAction(kind: .container(c.name, "restart"), title: "Restart \(c.name)", detail: "docker restart \(c.name) on the server. Brief interruption for anything using it.", destructive: false) }
                    Button("Stop", role: .destructive) { pending = PendingAction(kind: .container(c.name, "stop"), title: "Stop \(c.name)", detail: "docker stop \(c.name). It stays stopped until you start it again (autoheal only restarts unhealthy running containers).", destructive: true) }
                } else {
                    Button("Start") { pending = PendingAction(kind: .container(c.name, "start"), title: "Start \(c.name)", detail: "docker start \(c.name) on the server.", destructive: false) }
                }
            }
            .controlSize(.small)
        }
    }
}

struct PVEButtons: View {
    let guest: PVEGuest
    @Binding var pending: PendingAction?
    var body: some View {
        let g = guest
        let label = "\(g.type == "lxc" ? "CT" : "VM")\(g.vmid) \(g.name)"
        HStack(spacing: 6) {
            if g.status == "running" {
                Button("Reboot") { pending = PendingAction(kind: .pve(g, "reboot"), title: "Reboot \(label)", detail: "Graceful reboot via the Proxmox API. Everything inside it (containers, shares) goes away for a minute.", destructive: true) }
                Button("Shutdown", role: .destructive) { pending = PendingAction(kind: .pve(g, "shutdown"), title: "Shut down \(label)", detail: "Graceful shutdown via the Proxmox API. It stays off until you start it.", destructive: true) }
            } else {
                Button("Start") { pending = PendingAction(kind: .pve(g, "start"), title: "Start \(label)", detail: "Start via the Proxmox API.", destructive: false) }
            }
        }
        .controlSize(.small)
    }
}

/// The detail column while Actions is selected: service facts + the audit trail.
struct ActionLogPanel: View {
    @EnvironmentObject private var actions: ActionService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Action service").font(.title2.bold())
                DetailSection(title: "Service") {
                    FactRow(label: "Endpoint", value: actions.endpoint.absoluteString)
                    FactRow(label: "Status", value: actions.statusText)
                    if let h = actions.health {
                        FactRow(label: "Version", value: h.version ?? "—")
                        FactRow(label: "Docker", value: (h.docker_ok ?? false) ? "reachable" : "unreachable")
                        if let u = h.uptime_s { FactRow(label: "Uptime", value: durText(u)) }
                    }
                }
                if let n = actions.health?.notify {
                    DetailSection(title: "Push (ntfy)") {
                        FactRow(label: "Topic", value: n.topic ?? "—")
                        FactRow(label: "Server", value: n.ntfy ?? "—")
                        FactRow(label: "Last push", value: n.last_push ?? "none yet")
                        FactRow(label: "Last check", value: n.last_check ?? "—")
                        Text("hatch-notify diffs topology.json every 2 minutes on the server and pushes state changes to your phone — independent of this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DetailSection(title: "Recent actions") {
                    if actions.log.isEmpty {
                        Text("Nothing run yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(actions.log.prefix(40)) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(e.ok ? .green : .red).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(e.op) \(e.target)").font(.caption.weight(.medium))
                                Text(e.message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            Text(timeAgo(e.time)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(20)
        }
    }
    private func durText(_ s: Double) -> String {
        let i = Int(s)
        if i < 3600 { return "\(i / 60)m" }
        if i < 86_400 { return "\(i / 3600)h \((i % 3600) / 60)m" }
        return "\(i / 86_400)d \((i % 86_400) / 3600)h"
    }
}

/// Actions for one topology node, shown in its detail panel.
struct NodeActionsSection: View {
    let node: HNode
    @EnvironmentObject private var actions: ActionService
    @EnvironmentObject private var svc: TopologyService
    @EnvironmentObject private var options: Options
    @State private var pending: PendingAction?

    var body: some View {
        let ssh = TerminalLauncher.sshHost(for: node, in: svc.topo)
        let cs = actions.containers(for: node)
        let script = actions.script(for: node)
        let guest = TerminalLauncher.vmid(for: node).flatMap { actions.pve.guest(forVMID: $0) }
        if ssh != nil || !cs.isEmpty || script != nil || guest != nil || (node.t == "docker" && actions.configured) {
            DetailSection(title: "Actions") {
                if let ip = ssh {
                    HStack {
                        Label("\(options.actSSHUser)@\(ip)", systemImage: "terminal").font(.callout.monospaced())
                        Spacer()
                        Button("Open SSH") { TerminalLauncher.openSSH(user: options.actSSHUser, host: ip) }.controlSize(.small)
                    }
                }
                if let g = guest {
                    HStack {
                        Label("\(g.type == "lxc" ? "CT" : "VM")\(g.vmid) on \(g.node) · \(g.status)", systemImage: "power").font(.callout)
                        Spacer()
                        PVEButtons(guest: g, pending: $pending)
                    }
                }
                ForEach(cs) { c in
                    HStack {
                        StatusDot(state: c.isRunning ? "up" : "down")
                        Text(c.name).font(.callout.monospaced())
                        Spacer()
                        ContainerButtons(container: c, pending: $pending)
                    }
                }
                if node.t == "docker" && cs.isEmpty && actions.configured {
                    Text(actions.health == nil ? "Action service unreachable — container controls appear when it answers." : "No container matches “\(node.name)”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let s = script {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout)
                            Text(s.unit).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run now") {
                            pending = PendingAction(kind: .script(s), title: "Run \(s.title)", detail: "\(s.description)\n\nStarts \(s.unit) on the server.", destructive: false)
                        }.controlSize(.small)
                    }
                }
            }
            .onChange(of: pending?.id) { _, _ in
                if let p = pending, !p.destructive, !options.actConfirmSafe { pending = nil; Task { await actions.perform(p) } }
            }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { p in
                Button(p.destructive ? "Yes, \(p.title.lowercased())" : p.title, role: p.destructive ? .destructive : nil) {
                    Task { await actions.perform(p) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { p in Text(p.detail) }
        }
    }
}
