import SwiftUI

struct TrafficMeasure: Decodable, Hashable {
    let up: Int64, down: Int64
    let interval_s: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        up = try c.decode(Int64.self, forKey: .up); down = try c.decode(Int64.self, forKey: .down)
        interval_s = try c.decode(Int.self, forKey: .interval_s)
        guard up >= 0, down >= 0, interval_s > 0 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid counters")) }
    }
    enum Keys: String, CodingKey { case up, down, interval_s }
}

struct PersonalDevice: Decodable {
    let name: String, kind: String, what: String, state: String, via: String, lastSeen: String
    let bluetooth: String?, dest: String?
    enum Keys: String, CodingKey { case name, kind, what, state, via, last_seen, bluetooth, dest }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        guard !name.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing device name")) }
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "other"
        what = (try? c.decode(String.self, forKey: .what)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "unknown"
        via = (try? c.decode(String.self, forKey: .via)) ?? "manual"
        lastSeen = (try? c.decode(String.self, forKey: .last_seen)) ?? "Unknown"
        bluetooth = try? c.decode(String.self, forKey: .bluetooth)
        dest = try? c.decode(String.self, forKey: .dest)
    }
}
struct LossyPersonalDevice: Decodable {
    let value: PersonalDevice?
    init(from decoder: Decoder) throws { value = try? PersonalDevice(from: decoder) }
}
struct TrafficBucket: Decodable, Identifiable {
    let t: Double, up: Int64, down: Int64
    var id: Double { t }
}
struct LossyTrafficBucket: Decodable {
    let value: TrafficBucket?
    init(from decoder: Decoder) throws {
        let decoded = try? TrafficBucket(from: decoder)
        value = decoded.flatMap { $0.up >= 0 && $0.down >= 0 && $0.t > 0 ? $0 : nil }
    }
}
struct TrafficHistory: Decodable {
    var updated = ""
    var coverageStart: String?
    var nodes: [String: [TrafficBucket]] = [:]
    enum Keys: String, CodingKey { case meta, nodes }
    struct NodeKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    enum MetaKeys: String, CodingKey { case updated, coverage_start }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let meta = try c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        updated = (try? meta.decode(String.self, forKey: .updated)) ?? ""
        coverageStart = try? meta.decode(String.self, forKey: .coverage_start)
        let values = try c.nestedContainer(keyedBy: NodeKey.self, forKey: .nodes)
        for key in values.allKeys {
            let buckets = (try? values.decode([LossyTrafficBucket].self, forKey: key)) ?? []
            nodes[key.stringValue] = buckets.compactMap(\.value).sorted { $0.t < $1.t }
        }
    }
}

enum DeviceCategory: String, CaseIterable, Hashable {
    case all = "All devices", personal = "Personal", servers = "Servers", services = "Services"
}
struct TrackedDevice: Identifiable {
    let id: String, name: String, what: String, state: String, category: DeviceCategory
    let dest: String?, bluetooth: String?, traffic: TrafficMeasure?
    let presence: String
}
extension Topology {
    var trackedDevices: [TrackedDevice] {
        let personal = devices.enumerated().map { index, d in
            TrackedDevice(id: "personal:\(index):\(d.name)", name: d.name, what: d.what, state: d.state, category: .personal,
                          dest: d.dest, bluetooth: d.bluetooth, traffic: nil,
                          presence: d.via == "tailscale" ? "Tailscale · \(d.lastSeen)" : "Presence unavailable")
        }
        return personal + groups.flatMap(\.nodes).map { n in
            TrackedDevice(id: n.uid, name: n.name, what: n.plain, state: n.state,
                          category: ["host", "lxc", "vm"].contains(n.t) ? .servers : .services,
                          dest: n.dest, bluetooth: nil, traffic: n.traffic, presence: "Homelab probe")
        }
    }
}
func trafficBytes(_ value: Int64?) -> String {
    guard let value else { return "—" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

struct TrackedDevicesView: View {
    @ObservedObject var svc: TopologyService
    let category: DeviceCategory
    let query: String

    var rows: [TrackedDevice] {
        (svc.topo?.trackedDevices ?? []).filter { d in
            (category == .all || category == d.category) &&
            (query.isEmpty || (d.name + " " + d.what).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header bar
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.title2.bold())
                    Text("\(rows.count) device\(rows.count == 1 ? "" : "s") monitored")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if !svc.error.isEmpty {
                SchemaBanner(text: svc.error).padding(.horizontal, 18)
            }
            if !svc.historyError.isEmpty {
                Text(svc.historyError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
            }

            List(rows, selection: $svc.selectedTrackedDeviceID) { d in
                TrackedDeviceRow(device: d)
                    .tag(d.id)
            }
            .listStyle(.sidebar)
        }
    }
}

struct TrackedDeviceRow: View {
    let device: TrackedDevice

    var body: some View {
        HStack(spacing: 12) {
            // Device type icon badge
            Image(systemName: iconForDevice(device))
                .font(.title3)
                .foregroundStyle(iconColor(device))
                .frame(width: 36, height: 36)
                .background(iconColor(device).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    DeviceStatusPill(state: device.state)
                }
                Text(device.what)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let t = device.traffic {
                    HStack(spacing: 4) {
                        Text("↑ \(trafficBytes(t.up))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.purple)
                        Text("↓ \(trafficBytes(t.down))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                } else {
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(device.category.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func iconForDevice(_ d: TrackedDevice) -> String {
        let n = d.name.lowercased()
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("fold") || n.contains("phone") { return "iphone" }
        if n.contains("band") || n.contains("watch") { return "applewatch" }
        if d.category == .servers { return "server.rack" }
        if d.category == .services { return "cube.box" }
        return "desktopcomputer"
    }

    private func iconColor(_ d: TrackedDevice) -> Color {
        switch d.category {
        case .personal: return .indigo
        case .servers: return .teal
        case .services: return .orange
        case .all: return .blue
        }
    }
}

struct DeviceStatusPill: View {
    let state: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(state.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch state.lowercased() {
        case "online", "up": return .green
        case "offline", "down": return .secondary
        default: return .orange
        }
    }
}

struct TrackedDeviceDetail: View {
    @ObservedObject var svc: TopologyService
    let veteran: Bool

    var device: TrackedDevice? {
        svc.topo?.trackedDevices.first { $0.id == svc.selectedTrackedDeviceID }
    }

    var body: some View {
        if let d = device {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Top Hero Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Image(systemName: iconForDevice(d))
                                .font(.system(size: 28))
                                .foregroundStyle(iconColor(d))
                                .frame(width: 56, height: 56)
                                .background(iconColor(d).opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 14))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(d.name)
                                        .font(.title2.bold())
                                    DeviceStatusPill(state: d.state)
                                }
                                Text(d.what)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Label(d.presence, systemImage: "antenna.radiowaves.left.and.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(d.category.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(16)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))

                    // Destination / Routing Card
                    DetailSection(title: "Talks to") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.circle.fill")
                                    .foregroundStyle(.blue)
                                Text(d.dest ?? "—")
                                    .font(.body.weight(.medium))
                            }
                            Text("Configured traffic destination. Specific remote addresses are not captured by host counters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Bluetooth Capability Card
                    DetailSection(title: "Bluetooth Capability") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "wave.3.right.circle.fill")
                                    .foregroundStyle(.purple)
                                Text(d.bluetooth ?? "—")
                                    .font(.body)
                            }
                            Text("Declared hardware capability, presented as specification rather than live connection state.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 24h Traffic History Chart
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Traffic log · last 24 hours", systemImage: "chart.bar.xaxis")
                                .font(.headline)
                            Spacer()
                            if let traffic = d.traffic {
                                Text(veteran ? "\(traffic.up) TX / \(traffic.down) RX (\(traffic.interval_s)s)" : "2 min interval")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        TrafficHistoryChart(buckets: svc.history?.nodes[d.name] ?? [])

                        if let traffic = d.traffic {
                            HStack {
                                Text("Latest interval metrics:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Sent \(trafficBytes(traffic.up))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.purple)
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Received \(trafficBytes(traffic.down))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.cyan)
                            }
                        }

                        if let start = svc.history?.coverageStart {
                            Text("History coverage begins \(start). Missing periods are unmeasured; totals exclude those gaps.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if !svc.historyError.isEmpty {
                            Text(svc.historyError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Select a device", systemImage: "laptopcomputer.and.iphone",
                                   description: Text("Choose a device from the list to view detailed metrics and capabilities."))
        }
    }

    private func iconForDevice(_ d: TrackedDevice) -> String {
        let n = d.name.lowercased()
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("fold") || n.contains("phone") { return "iphone" }
        if n.contains("band") || n.contains("watch") { return "applewatch" }
        if d.category == .servers { return "server.rack" }
        if d.category == .services { return "cube.box" }
        return "desktopcomputer"
    }

    private func iconColor(_ d: TrackedDevice) -> Color {
        switch d.category {
        case .personal: return .indigo
        case .servers: return .teal
        case .services: return .orange
        case .all: return .blue
        }
    }
}

struct TrafficHistoryChart: View {
    let buckets: [TrafficBucket]

    var recent: [TrafficBucket] {
        buckets.filter { $0.t >= Date().timeIntervalSince1970 - 86400 && $0.t <= Date().timeIntervalSince1970 }
    }

    var body: some View {
        if recent.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("— No measured traffic history yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
                Spacer()
            }
        } else {
            let sent = recent.reduce(Int64(0)) { $0 + $1.up }
            let received = recent.reduce(Int64(0)) { $0 + $1.down }

            VStack(alignment: .leading, spacing: 10) {
                // Dual-color Canvas bar chart
                Canvas { context, size in
                    let end = Date().timeIntervalSince1970
                    let maxVal = max(1, recent.map { Double($0.up) + Double($0.down) }.max() ?? 1)
                    let barWidth = max(2, size.width / 288)

                    // Baseline gridlines
                    for ratio in [0.25, 0.5, 0.75] {
                        let y = size.height * (1.0 - ratio)
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(p, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)
                    }

                    for b in recent {
                        let x = max(0, (b.t - end + 86400) / 86400 * (size.width - barWidth))
                        let upH = (Double(b.up) / maxVal) * size.height
                        let downH = (Double(b.down) / maxVal) * size.height

                        // Download bar (cyan)
                        if downH > 0 {
                            let downRect = CGRect(x: x, y: size.height - downH, width: barWidth, height: downH)
                            context.fill(Path(roundedRect: downRect, cornerRadius: 1), with: .color(Color.cyan.opacity(0.85)))
                        }

                        // Upload bar stacked or overlay (purple)
                        if upH > 0 {
                            let upRect = CGRect(x: x, y: max(0, size.height - downH - upH), width: barWidth, height: upH)
                            context.fill(Path(roundedRect: upRect, cornerRadius: 1), with: .color(Color.purple.opacity(0.85)))
                        }
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Timeline Axis
                HStack {
                    Text("24h ago").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("12h ago").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Now").font(.caption2).foregroundStyle(.tertiary)
                }

                // Summary Totals Badge
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple).frame(width: 8, height: 8)
                        Text("Sent:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(trafficBytes(sent))
                            .font(.caption.bold().monospacedDigit())
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.cyan).frame(width: 8, height: 8)
                        Text("Received:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(trafficBytes(received))
                            .font(.caption.bold().monospacedDigit())
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

