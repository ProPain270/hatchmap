import Foundation

// MARK: - Lenient models
// Every field degrades gracefully: a malformed node is skipped or shown with
// defaults, and never kills the whole map. `uid` is assigned post-decode by
// Topology.assignUIDs() so SwiftUI ForEach always has stable, unique IDs.

struct Meta: Decodable {
    var updated = ""
    var node = ""
    var tailnet = ""
    var schema: Int?

    init() {}

    enum CodingKeys: String, CodingKey { case updated, node, tailnet, schema }
    init(from decoder: Decoder) throws {
        let con = try decoder.container(keyedBy: CodingKeys.self)
        updated = (try? con.decodeIfPresent(String.self, forKey: .updated)) ?? ""
        node    = (try? con.decodeIfPresent(String.self, forKey: .node)) ?? ""
        tailnet = (try? con.decodeIfPresent(String.self, forKey: .tailnet)) ?? ""
        schema  = try? con.decodeIfPresent(Int.self, forKey: .schema)
    }
}

struct Sit: Decodable, Identifiable {
    var l = "", v = "", s = "", c = "ok"
    var uid = ""
    var id: String { uid }

    enum CodingKeys: String, CodingKey { case l, v, s, c, state }
    init(from decoder: Decoder) throws {
        let con = try decoder.container(keyedBy: CodingKeys.self)
        l = (try? con.decodeIfPresent(String.self, forKey: .l)) ?? ""
        v = (try? con.decodeIfPresent(String.self, forKey: .v)) ?? ""
        s = (try? con.decodeIfPresent(String.self, forKey: .s)) ?? ""
        c = (try? con.decodeIfPresent(String.self, forKey: .state))
            ?? (try? con.decodeIfPresent(String.self, forKey: .c)) ?? "ok"
    }
}

/// Decodes one node, swallowing failure so a single bad node can't sink its group.
struct FailableNode: Decodable {
    let node: HNode?
    init(from decoder: Decoder) throws {
        node = try? HNode(from: decoder)
    }
}

struct HGroup: Decodable, Identifiable {
    var tier = "", kind = "", icon = ""
    var nodes: [HNode] = []
    var uid = ""
    var id: String { uid }

    enum CodingKeys: String, CodingKey { case tier, kind, icon, nodes }
    init(from decoder: Decoder) throws {
        let con = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try? con.decodeIfPresent(String.self, forKey: .tier)) ?? ""
        kind = (try? con.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        icon = (try? con.decodeIfPresent(String.self, forKey: .icon)) ?? ""
        let raw = (try? con.decodeIfPresent([FailableNode].self, forKey: .nodes)) ?? []
        nodes = raw.compactMap { $0.node }
    }
}

struct HNode: Decodable, Identifiable, Hashable {
    var t = "", name = "", meta = "", plain = "", tech = ""
    var state = "up"
    var expo: String?
    var url: String?
    var pct: Int?
    var free: String?
    var uid = ""
    var dest: String?
    var traffic: TrafficMeasure?
    var id: String { uid }

    enum CodingKeys: String, CodingKey {
        case dest, traffic, t, name, meta, plain, tech, state, expo, url, pct, free
    }

    init(from decoder: Decoder) throws {
        let con = try decoder.container(keyedBy: CodingKeys.self)
        t     = (try? con.decodeIfPresent(String.self, forKey: .t)) ?? ""
        name  = (try? con.decodeIfPresent(String.self, forKey: .name)) ?? ""
        meta  = (try? con.decodeIfPresent(String.self, forKey: .meta)) ?? ""
        plain = (try? con.decodeIfPresent(String.self, forKey: .plain)) ?? ""
        tech  = (try? con.decodeIfPresent(String.self, forKey: .tech)) ?? ""
        state = (try? con.decodeIfPresent(String.self, forKey: .state)) ?? "up"
        expo  = try? con.decodeIfPresent(String.self, forKey: .expo)
        url   = try? con.decodeIfPresent(String.self, forKey: .url)
        pct   = try? con.decodeIfPresent(Int.self, forKey: .pct)
        free  = try? con.decodeIfPresent(String.self, forKey: .free)
        dest = try? con.decodeIfPresent(String.self, forKey: .dest)
        traffic = try? con.decodeIfPresent(TrafficMeasure.self, forKey: .traffic)
    }
}

struct Topology: Decodable {
    var meta = Meta()
    var sitrep: [Sit] = []
    var groups: [HGroup] = []
    var devices: [PersonalDevice] = []

    enum CodingKeys: String, CodingKey { case meta, sitrep, groups, devices }
    init(from decoder: Decoder) throws {
        let con = try decoder.container(keyedBy: CodingKeys.self)
        devices = ((try? con.decodeIfPresent([LossyPersonalDevice].self, forKey: .devices)) ?? []).compactMap(\.value)
        meta   = (try? con.decodeIfPresent(Meta.self, forKey: .meta)) ?? Meta()
        sitrep = (try? con.decodeIfPresent([Sit].self, forKey: .sitrep)) ?? []
        groups = (try? con.decodeIfPresent([HGroup].self, forKey: .groups)) ?? []
    }

    /// Assigns stable, unique IDs by position. The generator emits groups/nodes
    /// in a deterministic order, so these are stable across polls.
    mutating func assignUIDs() {
        for gi in groups.indices {
            groups[gi].uid = "g\(gi)"
            for ni in groups[gi].nodes.indices {
                groups[gi].nodes[ni].uid = "n\(gi)-\(ni)"
            }
        }
        for si in sitrep.indices {
            sitrep[si].uid = "s\(si)"
        }
    }

    /// Nodes that need attention: down/warn, or storage at/over 90%.
    var attention: [(group: HGroup, node: HNode)] {
        groups.flatMap { g in
            g.nodes
                .filter { $0.state != "up" || ($0.pct ?? 0) >= 90 }
                .map { (g, $0) }
        }
    }

    /// Storage nodes across all tiers.
    var storage: [(group: HGroup, node: HNode)] {
        groups.flatMap { g in
            g.nodes.filter { $0.pct != nil }.map { (g, $0) }
        }
    }

    func search(_ raw: String) -> [(group: HGroup, node: HNode)] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return groups.flatMap { g in
            g.nodes.filter {
                $0.name.lowercased().contains(q)
                || $0.plain.lowercased().contains(q)
                || $0.tech.lowercased().contains(q)
                || $0.meta.lowercased().contains(q)
            }.map { (g, $0) }
        }
    }
}
