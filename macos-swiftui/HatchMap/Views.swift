import SwiftUI

// MARK: - Small components

struct StatusDot: View {
    let state: String
    var body: some View {
        let c: Color = state == "up" ? .green : state == "warn" ? .orange : .red
        Circle()
            .fill(c)
            .frame(width: 9, height: 9)
            .shadow(color: c.opacity(0.8), radius: 4)
    }
}

struct ExposurePill: View {
    let expo: String
    var body: some View {
        Text(Palette.expo(expo))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.expoColor(expo).opacity(0.14))
            .foregroundStyle(Palette.expoColor(expo))
            .clipShape(Capsule())
    }
}

struct FreshnessPill: View {
    @ObservedObject var svc: TopologyService
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(svc.isStale ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(svc.staleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }
}

struct StorageBar: View {
    let pct: Int
    let free: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(pct)% used").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let f = free {
                    Text("\(f) free").font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [Palette.storageColor(pct).opacity(0.65), Palette.storageColor(pct)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                }
            }
            .frame(height: 8)
        }
    }
}

struct SchemaBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Cards

struct SitrepCard: View {
    let s: Sit
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.color(s.c))
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.l.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(s.v)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(s.s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
    }
}

struct NodeCard: View {
    let node: HNode
    let group: HGroup
    let veteran: Bool
    let selected: Bool
    var compact: Bool = false
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            if compact { compactBody } else { fullBody }
        }
        .buttonStyle(.plain)
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            Image(systemName: Palette.icon(node.t))
                .foregroundStyle(Palette.color(node.t))
                .frame(width: 24, height: 24)
                .background(Palette.color(node.t).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(veteran ? node.name : displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(node.pct.map { "\($0)% · \(node.free ?? "")" } ?? node.meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusDot(state: node.state)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selected : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor.opacity(0.5) : Theme.border, lineWidth: 1))
    }

    private var fullBody: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: Palette.icon(node.t))
                        .foregroundStyle(Palette.color(node.t))
                        .font(.title3)
                        .frame(width: 30, height: 30)
                        .background(Palette.color(node.t).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    StatusDot(state: node.state)
                }
                Text(veteran ? node.name : displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(node.meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    if let e = node.expo, !e.isEmpty { ExposurePill(expo: e) }
                    Spacer()
                    Text(group.tier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let p = node.pct {
                    StorageBar(pct: p, free: node.free)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selected : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(selected ? Color.accentColor.opacity(0.5) : Theme.border, lineWidth: 1)
            )
    }

    private var displayName: String {
        node.plain.isEmpty ? node.name : node.plain
    }
}

struct AttentionRow: View {
    let group: HGroup
    let node: HNode
    let veteran: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                StatusDot(state: node.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(veteran ? node.name : (node.plain.isEmpty ? node.name : node.plain))
                        .font(.callout.weight(.medium))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(group.tier).font(.caption2).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var reason: String {
        if node.state == "warn" { return "Degraded" }
        if node.state != "up" { return "Down" }
        if let p = node.pct, p >= 90 { return "Storage at \(p)%" }
        return node.state
    }
}

// MARK: - Detail

struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

struct FactRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct NodeDetail: View {
    let node: HNode
    let groupTier: String
    let veteran: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: Palette.icon(node.t))
                        .font(.system(size: 30))
                        .foregroundStyle(Palette.color(node.t))
                        .frame(width: 62, height: 62)
                        .background(Palette.color(node.t).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(veteran ? node.name : (node.plain.isEmpty ? node.name : node.plain))
                            .font(.title2.bold())
                            .lineLimit(2)
                        Text(node.meta)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    StatusDot(state: node.state)
                    Text(node.state.uppercased())
                        .font(.caption.bold())
                    if let e = node.expo, !e.isEmpty { ExposurePill(expo: e) }
                    Spacer()
                    Text(groupTier).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

                DetailSection(title: "About") {
                    Text(veteran ? node.tech : node.plain)
                        .font(.body)
                        .textSelection(.enabled)
                }

                if let p = node.pct {
                    DetailSection(title: "Storage") {
                        StorageBar(pct: p, free: node.free)
                    }
                }

                NodeActionsSection(node: node)
                NodeHistorySection(node: node, groupTier: groupTier)

                if let u = node.url, let link = safeURL(u) {
                    Link(destination: link) {
                        Label("Open \(node.name)", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                DetailSection(title: "Details") {
                    FactRow(label: "Type", value: node.t)
                    FactRow(label: "Address", value: node.meta)
                    FactRow(label: "State", value: node.state)
                }
            }
            .padding(20)
        }
        .navigationTitle(node.name)
    }

    /// Tolerates spaces and other unencoded characters in URLs from the feed.
    private func safeURL(_ s: String) -> URL? {
        if let u = URL(string: s) { return u }
        guard let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: enc)
    }
}
