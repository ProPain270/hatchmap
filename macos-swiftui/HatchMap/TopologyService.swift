import SwiftUI

final class TopologyService: ObservableObject {
    @Published var topo: Topology?
    @Published var error = ""
    @Published var history: TrafficHistory?
    @Published var historyError = ""
    @Published var selectedTrackedDeviceID: String?
    @Published var lastGoodDate: Date?

    // Placeholder — set the real topology URL in Settings (⌘,); this host never resolves.
    static let defaultEndpoint = "https://your-node.your-tailnet.example:8443/topology.json"

    /// Endpoint override from Settings (⌘,) or `defaults write net.hatch.map apiURL -string …`.
    var endpoint: URL {
        let s = UserDefaults.standard.string(forKey: "apiURL") ?? ""
        return URL(string: s.isEmpty ? Self.defaultEndpoint : s)
            ?? URL(string: Self.defaultEndpoint)!
    }

    private var loading = false
    private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: .seconds(max(10, Options.shared.topologyPoll)))
            }
        }
    }

    deinit { task?.cancel() }

    @MainActor
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var req = URLRequest(url: endpoint, timeoutInterval: 15)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (d, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let raw = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            guard raw?["groups"] is [Any], raw?["meta"] is [String: Any] else { throw URLError(.cannotParseResponse) }
            var t = try JSONDecoder().decode(Topology.self, from: d)
            t.assignUIDs()
            let topology = t
            let schema = topology.meta.schema
            await MainActor.run {
                self.topo = topology
                self.lastGoodDate = Date()
                if let schema, schema > 2 {
                    self.error = "Topology schema v\(schema) — this app speaks v2. Showing known fields; update the app to read the rest."
                } else {
                    self.error = ""
                }
            }
        } catch {
            // Keep showing last-good data; the UI surfaces staleness instead.
            await MainActor.run {
                self.error = "Offline — showing last good topology. \(error.localizedDescription)"
            }
        }
        do {
            let url = endpoint.deletingLastPathComponent().appendingPathComponent("traffic-history.json")
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let history = try JSONDecoder().decode(TrafficHistory.self, from: data)
            self.history = history
            self.historyError = ""
        } catch {
            self.historyError = "Traffic history offline — showing the last received history, if available."
        }
    }

    /// True when we have no data, or the last good poll is older than the configured stale window.
    /// Called from the UI (main thread).
    var isStale: Bool {
        guard let d = lastGoodDate else { return true }
        return Date().timeIntervalSince(d) > Options.shared.staleAfter
    }

    /// "Live" / "Stale · last good 4m ago" / "Offline — no data yet"
    var staleText: String {
        guard let d = lastGoodDate else { return "Offline — no data yet" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return "Live" }
        if mins < 60 { return "Stale · last good \(mins)m ago" }
        return "Stale · last good \(mins / 60)h \(mins % 60)m ago"
    }
}
