import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Passive discovery (mDNS / Bonjour) — names, models & services other devices broadcast
// Multicast is visible to the Mac even on a switched network, so this is how we identify
// phones / TVs / IoT that never send unicast traffic through us.

final class DiscoveryDB {
    static let shared = DiscoveryDB()
    struct Info { var name = ""; var model = ""; var services: Set<String> = [] }
    private var byIP: [String: Info] = [:]
    private let lock = NSLock()
    private let known = ["_airplay","_raop","_companion-link","_googlecast","_nvstream","_spotify-connect",
                         "_sonos","_hap","_homekit","_ipp","_printer","_pdl-datastream","_amzn","_matter",
                         "_meshcop","_device-info","_smb","_afpovertcp","_ssh","_rdlink","_appletv","_sleep-proxy"]

    func info(_ ip: String) -> Info? { lock.lock(); defer { lock.unlock() }; return byIP[ip] }
    func services(_ ip: String) -> Set<String> { info(ip)?.services ?? [] }

    private var dhcp: [String: (name: String, os: String)] = [:]   // keyed by MAC
    func dhcpInfo(mac: String) -> (name: String, os: String)? { lock.lock(); defer { lock.unlock() }; return dhcp[mac.lowercased()] }
    func ingestDHCP(_ text: String) {
        func quoted(after key: String) -> String? {
            guard let r = text.range(of: key) else { return nil }
            let tail = text[r.upperBound...]
            guard let q1 = tail.range(of: "\"") else { return nil }
            let afterQ = tail[q1.upperBound...]
            guard let q2 = afterQ.range(of: "\"") else { return nil }
            return String(afterQ[afterQ.startIndex..<q2.lowerBound])
        }
        var mac = ""
        if let r = text.range(of: "from ") { mac = String(text[r.upperBound...].prefix(while: { $0 != "," && $0 != " " })).lowercased() }
        if mac.split(separator: ":").count != 6, let r = text.range(of: "Client-Ethernet-Address ") {
            mac = String(text[r.upperBound...].prefix(while: { $0 != " " && $0 != "\n" && $0 != "(" })).lowercased()
        }
        guard mac.split(separator: ":").count == 6 else { return }
        let host = quoted(after: "Hostname Option 12") ?? ""
        let v = (quoted(after: "Vendor-Class Option 60") ?? "").lowercased()
        var os = ""
        if v.contains("android") { os = "Android" }
        else if v.contains("msft") { os = "Windows" }
        else if v.contains("dhcpcd") || v.contains("udhcp") { os = "Linux/embedded" }
        if host.isEmpty && os.isEmpty { return }
        lock.lock(); dhcp[mac] = (host, os); if dhcp.count > 2000 { dhcp.removeAll() }; lock.unlock()
    }

    func ingest(_ line: String) {
        guard let gt = line.range(of: " > ") else { return }
        let head = String(line[line.startIndex..<gt.lowerBound])           // "IP 192.0.2.62.5353"
        guard let r = head.range(of: ".5353", options: .backwards) else { return }
        let srcIP = head[head.startIndex..<r.lowerBound].split(separator: " ").last.map(String.init) ?? ""
        guard ipv4ToUInt32(srcIP) != nil, isPrivateIP(srcIP) else { return }
        var svcs: Set<String> = []
        for k in known where line.contains(k) { svcs.insert(k) }
        var model = ""
        if let mr = line.range(of: "model=") { model = String(line[mr.upperBound...].prefix(while: { $0 != "\"" && $0 != " " && $0 != "," })) }
        if model.isEmpty, let mr = line.range(of: "am=") { model = String(line[mr.upperBound...].prefix(while: { $0 != "\"" && $0 != " " && $0 != "," })) }
        var name = ""
        if let ar = line.range(of: " A " + srcIP) {
            let before = line[line.startIndex..<ar.lowerBound]
            if let lr = before.range(of: ".local.", options: .backwards) {
                let seg = before[before.startIndex..<lr.lowerBound]
                name = String(seg.split(whereSeparator: { $0 == " " || $0 == "," }).last ?? "")
            }
        }
        if svcs.isEmpty && model.isEmpty && name.isEmpty { return }
        lock.lock()
        var e = byIP[srcIP] ?? Info()
        if !name.isEmpty { e.name = name.replacingOccurrences(of: "-", with: " ") }
        if !model.isEmpty { e.model = model }
        e.services.formUnion(svcs)
        byIP[srcIP] = e
        if byIP.count > 2000 { byIP.removeAll() }
        lock.unlock()
    }
}

// MARK: - Device database (arp + OUI vendor + hostnames)

func normalizeMAC(_ raw: String) -> String? {
    let parts = raw.lowercased().split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return nil }
    var out: [String] = []
    for p in parts {
        guard p.count <= 2, !p.isEmpty, p.allSatisfy({ $0.isHexDigit }) else { return nil }
        out.append(p.count == 1 ? "0" + p : String(p))
    }
    return out.joined(separator: ":")
}

final class DeviceDB {
    static let shared = DeviceDB()
    private var hosts: [String: String] = [:]
    private var macs: [String: String] = [:]
    private let lock = NSLock()
    private let ouis: [String: String] = [
        "a4:83:e7":"Apple","ac:de:48":"Apple","f0:18:98":"Apple","3c:06:30":"Apple","a8:66:7f":"Apple",
        "d0:81:7a":"Apple","f4:f9:51":"Apple","dc:a9:04":"Apple","90:9c:4a":"Apple","f0:99:bf":"Apple",
        "68:fe:f7":"Apple","a0:d7:95":"Apple","7c:d1:c3":"Apple","cc:08:e0":"Apple","e0:ac:cb":"Apple",
        "ac:87:a3":"Apple","f4:0f:24":"Apple","98:b8:e3":"Apple","a4:d1:8c":"Apple",
        "b8:27:eb":"Raspberry Pi","dc:a6:32":"Raspberry Pi","e4:5f:01":"Raspberry Pi","28:cd:c1":"Raspberry Pi",
        "44:65:0d":"Amazon","fc:65:de":"Amazon","68:37:e9":"Amazon","f0:27:2d":"Amazon","74:c2:46":"Amazon","0c:47:c9":"Amazon","ac:63:be":"Amazon",
        "18:b4:30":"Google Nest","6c:ad:f8":"Google","d8:6c:63":"Google","1c:f2:9a":"Google","f4:f5:d8":"Google","f4:f5:e8":"Google","3c:5a:b4":"Google","94:eb:2c":"Google","64:16:66":"Nest","18:74:2e":"Google Nest",
        "fc:ec:da":"Ubiquiti","74:83:c2":"Ubiquiti","78:8a:20":"Ubiquiti","24:5a:4c":"Ubiquiti",
        "b0:7f:b9":"Netgear","a0:63:91":"Netgear","2c:30:33":"Netgear",
        "00:1d:d8":"Sonos","94:9f:3e":"Sonos","5c:aa:fd":"Sonos","48:a6:b8":"Sonos","78:28:ca":"Sonos",
        "ec:1b:bd":"Samsung","8c:79:f5":"Samsung","c8:19:f7":"Samsung","d0:59:e4":"Samsung","5c:49:7d":"Samsung",
        "10:2c:6b":"Roku","cc:6d:a0":"Roku","b8:a1:75":"Roku","dc:3a:5e":"Roku","d8:31:34":"Roku",
        "d4:3a:65":"Ring",
        "f0:a3:b1":"Espressif/IoT","2c:3a:e8":"Espressif/IoT","24:0a:c4":"Espressif/IoT","a4:cf:12":"Espressif/IoT","30:ae:a4":"Espressif/IoT","c4:4f:33":"Espressif/IoT",
        "50:c7:bf":"TP-Link","b0:be:76":"TP-Link","98:da:c4":"TP-Link",
        "1c:3b:f3":"Wyze","2c:aa:8e":"Wyze","00:17:88":"Philips Hue","ec:b5:fa":"Philips Hue",
        "b0:c5:54":"D-Link","00:12:17":"Cisco/Linksys","d8:eb:46":"Ecobee","44:61:32":"Ecobee",
        "00:11:32":"Synology","24:5e:be":"QNAP","00:50:56":"VMware","08:00:27":"VirtualBox",
    ]
    private let ouis2: [String: String] = [
        "dc:2b:2a":"Apple","88:66:5a":"Apple","34:c0:59":"Apple","6c:8d:c1":"Apple","9c:04:eb":"Apple",
        "f0:db:f8":"Apple","04:d3:cf":"Apple","5c:f9:38":"Apple","8c:85:90":"Apple","a8:5c:2c":"Apple",
        "5c:0a:5b":"Samsung","78:1f:db":"Samsung","e8:50:8b":"Samsung","00:1a:8a":"Samsung","34:23:ba":"Samsung","8c:77:12":"Samsung",
        "3c:8d:20":"Google","54:60:09":"Google","a4:77:33":"Google","f8:8f:ca":"Google Nest","20:df:b9":"Google Nest",
        "40:b4:cd":"Amazon","50:dc:e7":"Amazon","6c:56:97":"Amazon","44:00:49":"Amazon","b4:7c:9c":"Amazon",
        "00:50:f2":"Microsoft","7c:1e:52":"Microsoft","98:5f:d3":"Microsoft Xbox","c0:33:5e":"Microsoft",
        "88:de:a9":"Roku","ac:3a:7a":"Roku","08:05:81":"Roku",
        "00:04:1f":"Sony PlayStation","2c:cc:44":"Sony","bc:60:a7":"Sony PlayStation",
        "00:1f:32":"Nintendo","40:f4:07":"Nintendo","98:b6:e9":"Nintendo","e8:4e:ce":"Nintendo",
        "54:af:97":"TP-Link","ac:84:c6":"TP-Link","60:32:b1":"TP-Link",
        "24:6f:28":"Espressif/IoT","3c:71:bf":"Espressif/IoT","84:0d:8e":"Espressif/IoT","7c:9e:bd":"Espressif/IoT",
        "00:e0:91":"LG","10:f1:f2":"LG","c4:36:6c":"LG",
        "28:6c:07":"Xiaomi","64:09:80":"Xiaomi","f8:a4:5f":"Xiaomi",
        "3c:a9:f4":"Intel","34:13:e8":"Intel","a0:88:b4":"Intel","00:1b:21":"Intel",
    ]
    /// `arp -a` prints octets unpadded ("0:17:88:…") while DHCP and mDNS give the padded
    /// form — without this the same card would key two different profiles.
    func refresh() {
        var nh: [String: String] = [:]; var nm: [String: String] = [:]
        for raw in shell("/usr/sbin/arp", ["-a"]).split(separator: "\n") {
            let line = String(raw)
            guard let lp = line.firstIndex(of: "("), let rp = line.firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: lp)..<rp])
            let hostPart = line[line.startIndex..<lp].trimmingCharacters(in: .whitespaces)
            var mac = ""
            if let atR = line.range(of: " at ") { mac = String(line[atR.upperBound...].split(separator: " ").first ?? "").lowercased() }
            if let m = normalizeMAC(mac) { nm[ip] = m }
            if !hostPart.isEmpty && hostPart != "?" {
                nh[ip] = hostPart.replacingOccurrences(of: ".local", with: "").replacingOccurrences(of: ".lan", with: "")
            }
        }
        for raw in shell("/usr/sbin/ndp", ["-an"]).split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { continue }
            let ip = String(cols[0]).split(separator: "%").first.map(String.init) ?? String(cols[0])
            let mac = String(cols[1]).lowercased()
            if let m = normalizeMAC(mac) { nm[ip] = m }
        }
        lock.lock(); hosts = nh; macs = nm; lock.unlock()
    }
    func hostName(_ ip: String) -> String? { lock.lock(); defer { lock.unlock() }; let h = hosts[ip]; return (h?.isEmpty ?? true) ? nil : h }
    func label(_ ip: String) -> String? {
        if let h = hostName(ip) { return h }
        if let v = vendorForIP(ip) { return "\(v) device" }
        return nil
    }
    func vendor(_ mac: String) -> String? {
        let parts = mac.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
        guard parts.count >= 3 else { return nil }
        let key = parts.prefix(3).joined(separator: ":")
        return ouis[key] ?? ouis2[key]
    }
    func vendorForIP(_ ip: String) -> String? {
        lock.lock(); let m = macs[ip]; lock.unlock()
        guard let mac = m else { return nil }
        return vendor(mac)
    }
    func mac(_ ip: String) -> String? { lock.lock(); defer { lock.unlock() }; return macs[ip] }
    func allMACs() -> [String: String] { lock.lock(); defer { lock.unlock() }; return macs }
}

// MARK: - Device profiles (passive only — no probing)
// Everything here comes from traffic the network already produced: the ARP/NDP neighbour
// tables, mDNS/Bonjour announcements, DHCP requests, and the OUI vendor table.
// NetSight never pings or port-scans to build a profile; that stays a manual Scan action.

struct DeviceProfile {
    var mac = ""                       // "" when the hardware address isn't visible from here
    var vendor = ""
    var names: Set<String> = []
    var model = ""
    var klass = ""
    var os = ""
    var services: Set<String> = []
    var ips: Set<String> = []
    var firstSeen = Date()
    var lastSeen = Date()

    var key: String { mac.isEmpty ? "ip:" + (ips.sorted().first ?? "?") : mac }
    var bestName: String {
        if let n = names.sorted(by: { $0.count > $1.count }).first, !n.isEmpty { return n }
        if !model.isEmpty { return model }
        if !vendor.isEmpty { return "\(vendor) device" }
        return ips.sorted().first ?? "Unknown device"
    }
    var isNew: Bool { Date().timeIntervalSince(firstSeen) < 86_400 }
}

final class ProfileDB {
    static let shared = ProfileDB()
    private var profiles: [String: DeviceProfile] = [:]      // keyed by MAC, or "ip:<addr>" when unknown
    private var ipIndex: [String: String] = [:]              // ip -> profile key
    private var dirty = false
    private var loadedEmpty = true
    private let lock = NSLock()
    private var path: String { NetPaths.dir + "/device-profiles.tsv" }

    var wasEmptyAtLaunch: Bool { lock.lock(); defer { lock.unlock() }; return loadedEmpty }

    /// Fold everything passively known about `ip` into its profile.
    /// Returns the profile plus whether this is hardware we've never recorded before.
    @discardableResult
    func observe(ip: String) -> (profile: DeviceProfile, isFirstEver: Bool) {
        let mac = normalizeMAC(DeviceDB.shared.mac(ip) ?? "") ?? ""
        let meta = resolveDevice(ip)
        let dc = deviceClass(ip)
        let disc = DiscoveryDB.shared.info(ip)
        let dhcp = mac.isEmpty ? nil : DiscoveryDB.shared.dhcpInfo(mac: mac)

        lock.lock(); defer { lock.unlock() }
        // Prefer an existing MAC-keyed profile; a device first seen without a MAC gets
        // merged into its MAC profile as soon as the neighbour table catches up.
        var key = mac.isEmpty ? (ipIndex[ip] ?? "ip:" + ip) : mac
        if !mac.isEmpty, let oldKey = ipIndex[ip], oldKey != mac, let old = profiles[oldKey], oldKey.hasPrefix("ip:") {
            var merged = old
            merged.mac = mac
            profiles[mac] = mergeInto(profiles[mac], merged)
            profiles.removeValue(forKey: oldKey)
            key = mac
        }
        let existed = profiles[key] != nil
        var p = profiles[key] ?? DeviceProfile()
        if !existed { p.firstSeen = Date() }
        p.mac = mac.isEmpty ? p.mac : mac
        p.lastSeen = Date()
        p.ips.insert(ip)
        if !meta.vendor.isEmpty { p.vendor = meta.vendor }
        if meta.name != ip && !meta.name.isEmpty { p.names.insert(meta.name) }
        if let d = disc {
            if !d.name.isEmpty { p.names.insert(d.name) }
            if !d.model.isEmpty { p.model = d.model }
            p.services.formUnion(d.services)
        }
        if let d = dhcp {
            if !d.name.isEmpty { p.names.insert(d.name) }
            if !d.os.isEmpty && d.os != "—" { p.os = d.os }
        }
        if dc.klass != "Unknown" { p.klass = dc.klass }
        if p.os.isEmpty && dc.os != "—" && !dc.os.isEmpty { p.os = dc.os }
        profiles[key] = p
        ipIndex[ip] = key
        dirty = true
        return (p, !existed)
    }

    private func mergeInto(_ base: DeviceProfile?, _ add: DeviceProfile) -> DeviceProfile {
        guard var b = base else { return add }
        b.ips.formUnion(add.ips); b.names.formUnion(add.names); b.services.formUnion(add.services)
        if b.vendor.isEmpty { b.vendor = add.vendor }
        if b.model.isEmpty { b.model = add.model }
        if b.klass.isEmpty { b.klass = add.klass }
        if b.os.isEmpty { b.os = add.os }
        if add.firstSeen < b.firstSeen { b.firstSeen = add.firstSeen }
        if add.lastSeen > b.lastSeen { b.lastSeen = add.lastSeen }
        return b
    }

    func profile(ip: String) -> DeviceProfile? {
        lock.lock(); defer { lock.unlock() }
        guard let k = ipIndex[ip] else { return nil }
        return profiles[k]
    }
    func all() -> [DeviceProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Re-read the neighbour tables (already refreshed elsewhere) and fold in anything new.
    /// Alerts for hardware that has never appeared in the roster before.
    func sweep() {
        for (ip, _) in DeviceDB.shared.allMACs() where isDeviceIP(ip) {
            let r = observe(ip: ip)
            if r.isFirstEver { AnomalyStore.shared.noteNewHardware(r.profile) }
        }
    }

    func load() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let df = ISO8601DateFormatter()
        lock.lock(); defer { lock.unlock() }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 10 else { continue }
            func set(_ s: String) -> Set<String> { s.isEmpty ? [] : Set(s.split(separator: "|").map(String.init)) }
            var p = DeviceProfile()
            p.mac = c[0]; p.vendor = c[1]; p.names = set(c[2]); p.model = c[3]
            p.klass = c[4]; p.os = c[5]; p.services = set(c[6]); p.ips = set(c[7])
            p.firstSeen = df.date(from: c[8]) ?? Date(); p.lastSeen = df.date(from: c[9]) ?? Date()
            profiles[p.key] = p
            for ip in p.ips { ipIndex[ip] = p.key }
        }
        loadedEmpty = profiles.isEmpty
    }

    func persist() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let df = ISO8601DateFormatter()
        let lines = profiles.values.map { p -> String in
            [p.mac, p.vendor, p.names.sorted().joined(separator: "|"), p.model, p.klass, p.os,
             p.services.sorted().joined(separator: "|"), p.ips.sorted().joined(separator: "|"),
             df.string(from: p.firstSeen), df.string(from: p.lastSeen)].joined(separator: "\t")
        }
        dirty = false
        lock.unlock()
        try? ("# mac\tvendor\tnames\tmodel\tclass\tos\tservices\tips\tfirst\tlast\n" + lines.joined(separator: "\n"))
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Device-type inference

final class ScanStore {
    static let shared = ScanStore()
    private var portsByIP: [String: [Int]] = [:]
    private let lock = NSLock()
    func set(_ ip: String, _ ports: [Int]) { lock.lock(); portsByIP[ip] = ports; lock.unlock() }
    func ports(_ ip: String) -> [Int] { lock.lock(); defer { lock.unlock() }; return portsByIP[ip] ?? [] }
}

func vendorType(_ v: String) -> (String, String) {
    switch v {
    case "Sonos": return ("Smart speaker", "hifispeaker")
    case "Roku": return ("Streaming player", "tv")
    case "Ring", "Wyze": return ("Camera / doorbell", "video")
    case "Amazon": return ("Echo / Amazon device", "hifispeaker")
    case "Google", "Google Nest", "Nest": return ("Google / Nest device", "homekit")
    case "Raspberry Pi": return ("Raspberry Pi", "cpu")
    case "Espressif/IoT": return ("IoT device", "sensor")
    case "Netgear", "Ubiquiti", "TP-Link", "D-Link", "Cisco/Linksys": return ("Router / access point", "wifi.router")
    case "Samsung": return ("Samsung device", "tv")
    case "Philips Hue": return ("Smart light", "lightbulb")
    case "Ecobee": return ("Thermostat", "thermometer")
    case "Synology", "QNAP": return ("NAS / storage", "externaldrive")
    case "Apple": return ("Apple device", "apple.logo")
    case "VMware", "VirtualBox": return ("Virtual machine", "macwindow")
    default: return ("", "")
    }
}

func deviceType(name: String, vendor: String, ports: [Int]) -> (String, String) {
    let n = name.lowercased()
    func has(_ s: String) -> Bool { n.contains(s) }
    if has("iphone") { return ("iPhone", "iphone") }
    if has("ipad") { return ("iPad", "ipad") }
    if has("macbook") { return ("MacBook", "laptopcomputer") }
    if has("imac") { return ("iMac", "desktopcomputer") }
    if has("mac-mini") || has("macmini") { return ("Mac mini", "macmini") }
    if has("mac-studio") || has("macstudio") { return ("Mac Studio", "macstudio") }
    if has("apple-tv") || has("appletv") { return ("Apple TV", "appletv") }
    if has("homepod") { return ("HomePod", "homepod") }
    if has("apple-watch") || has("applewatch") { return ("Apple Watch", "applewatch") }
    if has("chromecast") || has("google-tv") || has("googletv") { return ("Chromecast / Google TV", "tv") }
    if has("nest-mini") || has("nest-audio") || has("googlehome") || has("google-home") { return ("Google speaker", "hifispeaker") }
    if has("nest") { return ("Nest device", "sensor") }
    if has("echo") || has("alexa") { return ("Amazon Echo", "hifispeaker") }
    if has("fire-tv") || has("firetv") || has("aftv") { return ("Fire TV", "tv") }
    if has("roku") { return ("Roku", "tv") }
    if has("sonos") { return ("Sonos speaker", "hifispeaker") }
    if has("shield") { return ("NVIDIA Shield", "tv") }
    if has("playstation") || has("ps5") || has("ps4") { return ("PlayStation", "gamecontroller") }
    if has("xbox") { return ("Xbox", "gamecontroller") }
    if has("nintendo") || has("switch") { return ("Nintendo Switch", "gamecontroller") }
    if has("printer") || has("officejet") || has("envy") || has("laserjet") { return ("Printer", "printer") }
    if has("synology") || has("qnap") || has("-nas") || has("truenas") || has("diskstation") { return ("NAS / storage", "externaldrive") }
    if has("raspberrypi") || has("raspberry") { return ("Raspberry Pi", "cpu") }
    if has("router") || has("gateway") || has("unifi") || has("udm") || has("eero") || has("orbi") || has("archer") { return ("Router / access point", "wifi.router") }
    if has("camera") || has("cam-") || has("ring") || has("wyze") || has("doorbell") { return ("Camera", "video") }
    if has("hue") || has("lifx") || has("bulb") { return ("Smart light", "lightbulb") }
    if has("thermostat") || has("ecobee") { return ("Thermostat", "thermometer") }
    if has("bravia") || has("webos") || has("samsung") || has("vizio") || has("-tv") { return ("Smart TV", "tv") }
    if has("android") || has("pixel") { return ("Android phone", "iphone") }
    if has("desktop-") || has("windows") { return ("Windows PC", "pc") }
    if ports.contains(62078) { return ("iPhone / iPad", "iphone") }
    if ports.contains(8009) { return ("Chromecast", "tv") }
    if ports.contains(1400) { return ("Sonos speaker", "hifispeaker") }
    if ports.contains(9100) || ports.contains(631) { return ("Printer", "printer") }
    if ports.contains(32400) { return ("Media server (Plex)", "play.rectangle") }
    if ports.contains(548) { return ("Mac / NAS", "desktopcomputer") }
    if ports.contains(3389) { return ("Windows PC", "pc") }
    if ports.contains(445) || ports.contains(139) { return ("PC / NAS", "pc") }
    if ports.contains(22) { return ("Computer / server", "server.rack") }
    let vt = vendorType(vendor)
    if !vt.0.isEmpty { return vt }
    if !vendor.isEmpty { return ("\(vendor) device", "network") }
    return ("Unknown device", "questionmark.circle")
}

struct DeviceMeta { let ip: String; let name: String; let vendor: String; let type: String; let icon: String; let isMe: Bool }

func resolveDevice(_ ip: String) -> DeviceMeta {
    if NetID.shared.isMe(ip) {
        return DeviceMeta(ip: ip, name: "This Mac", vendor: "Apple", type: "This Mac", icon: "laptopcomputer", isMe: true)
    }
    if !NetID.shared.gatewayIP.isEmpty && ip == NetID.shared.gatewayIP {
        return DeviceMeta(ip: ip, name: DeviceDB.shared.hostName(ip) ?? "Router", vendor: DeviceDB.shared.vendorForIP(ip) ?? "", type: "Router / gateway", icon: "wifi.router", isMe: false)
    }
    let disc = DiscoveryDB.shared.info(ip)
    let dhcpName = DeviceDB.shared.mac(ip).flatMap { DiscoveryDB.shared.dhcpInfo(mac: $0)?.name }
    let host = DeviceDB.shared.hostName(ip) ?? ((disc?.name.isEmpty == false) ? disc?.name : nil) ?? ((dhcpName?.isEmpty == false) ? dhcpName : nil) ?? NameCache.shared.name(ip)
    let vendor = DeviceDB.shared.vendorForIP(ip) ?? ""
    let ports = ScanStore.shared.ports(ip)
    let detect = ((host ?? "") + " " + (disc?.model ?? "")).replacingOccurrences(of: ".local", with: "")
    let (type, icon) = deviceType(name: detect, vendor: vendor, ports: ports)
    var name = (host ?? "").replacingOccurrences(of: ".local", with: "")
    if name.isEmpty { name = type == "Unknown device" ? ip : type }
    return DeviceMeta(ip: ip, name: name, vendor: vendor, type: type, icon: icon, isMe: false)
}

// MARK: - Device class (phone / computer / TV / IoT) + OS hint

func deviceClass(_ ip: String) -> (klass: String, os: String, icon: String) {
    if ip.isEmpty { return ("Unknown", "—", "questionmark.circle") }
    if NetID.shared.isMe(ip) { return ("Computer", "macOS (this Mac)", "laptopcomputer") }
    if !NetID.shared.gatewayIP.isEmpty && ip == NetID.shared.gatewayIP { return ("Router", "gateway", "wifi.router") }
    let disc = DiscoveryDB.shared.info(ip)
    let dhcp = DeviceDB.shared.mac(ip).flatMap { DiscoveryDB.shared.dhcpInfo(mac: $0) }
    let dos = dhcp?.os ?? ""
    let svcs = disc?.services ?? []
    let model = (disc?.model ?? "").lowercased()
    let nameSrc = (disc?.name.isEmpty == false ? disc?.name : (DeviceDB.shared.hostName(ip) ?? ((dhcp?.name.isEmpty == false) ? dhcp?.name : nil)))
    let name = (nameSrc ?? "").lowercased()
    let vendor = DeviceDB.shared.vendorForIP(ip) ?? ""
    let ports = ScanStore.shared.ports(ip)
    func has(_ s: String) -> Bool { name.contains(s) || model.contains(s) }
    // Explicit Apple form factors
    if has("iphone") { return ("Mobile phone", "iOS", "iphone") }
    if has("ipad") { return ("Tablet", "iPadOS", "ipad") }
    if model.contains("appletv") || has("apple tv") || has("appletv") { return ("TV / streamer", "tvOS", "appletv") }
    if has("homepod") || model.contains("audioaccessory") { return ("Speaker", "audioOS", "homepod") }
    if has("macbook") { return ("Computer", "macOS", "laptopcomputer") }
    if has("imac") || has("macmini") || has("mac-mini") || has("macstudio") || has("mac-studio") { return ("Computer", "macOS", "desktopcomputer") }
    if has("watch") { return ("Watch", "watchOS", "applewatch") }
    // DHCP vendor-class OS hint (reliable when present)
    if dos == "Windows" { return ("Computer", "Windows", "pc") }
    if dos == "Android" { return ("Mobile phone", "Android", "iphone") }
    // Service-based (from mDNS/Bonjour)
    if svcs.contains("_nvstream") { return ("Computer", "Windows (NVIDIA)", "pc") }
    if svcs.contains("_googlecast") { return ("TV / streamer", "Google Cast", "tv") }
    if svcs.contains("_airplay") || svcs.contains("_appletv") { return ("TV / streamer", "AirPlay", "appletv") }
    if svcs.contains("_spotify-connect") || svcs.contains("_sonos") || svcs.contains("_raop") { return ("Speaker", "AirPlay/embedded", "hifispeaker") }
    if svcs.contains("_hap") || svcs.contains("_homekit") || svcs.contains("_matter") || svcs.contains("_meshcop") { return ("Smart-home hub", "embedded", "homekit") }
    if svcs.contains("_ipp") || svcs.contains("_printer") || svcs.contains("_pdl-datastream") { return ("Printer", "embedded", "printer") }
    // Hostname hints
    if name.contains("-pc") || name.contains("desktop-") || name.hasPrefix("do-pc") || name.contains("windows") { return ("Computer", "Windows", "pc") }
    if name.contains("android") || name.contains("pixel") || name.contains("galaxy") || name.contains("oneplus") { return ("Mobile phone", "Android", "iphone") }
    // Open-port hints (from a scan)
    if ports.contains(62078) { return ("Mobile phone", "iOS", "iphone") }
    if ports.contains(3389) { return ("Computer", "Windows", "pc") }
    if ports.contains(32400) || ports.contains(548) || ports.contains(445) { return ("Server / NAS", "—", "server.rack") }
    if ports.contains(9100) || ports.contains(631) { return ("Printer", "embedded", "printer") }
    // Vendor hints
    switch vendor {
    case "Apple": return ("Apple device", "Apple", "apple.logo")
    case "Roku": return ("TV / streamer", "Roku OS", "tv")
    case "Samsung": return ("TV / phone", "Samsung", "tv")
    case "Sonos": return ("Speaker", "embedded", "hifispeaker")
    case "Amazon": return ("Echo / Fire", "Fire OS", "hifispeaker")
    case "Google", "Google Nest", "Nest": return ("Smart-home / streamer", "embedded", "homekit")
    case "Ring", "Wyze": return ("Camera", "embedded", "video")
    case "Espressif/IoT", "Philips Hue", "Tuya", "Ecobee": return ("Smart-home device", "embedded", "sensor")
    case "Netgear", "Ubiquiti", "TP-Link", "D-Link", "Cisco/Linksys": return ("Router / AP", "embedded", "wifi.router")
    case "Raspberry Pi": return ("Computer", "Linux", "cpu")
    case "Synology", "QNAP": return ("Server / NAS", "—", "externaldrive")
    default: break
    }
    return ("Unknown", "—", "questionmark.circle")
}

func classChip(_ k: String) -> some View {
    Text(k).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.primary.opacity(0.09)).foregroundStyle(Pal.ink).clipShape(RoundedRectangle(cornerRadius: 3))
}

// MARK: - App attribution (lsof + process catalog + code signature)

struct AppInfo { let process: String; let display: String; let bundleID: String; let signature: String; let role: String; let icon: String }

// Turn a raw macOS process name into human meaning + role + icon.
func processMeaning(_ cmd: String) -> (String, String, String) {
    let c = cmd.lowercased()
    func h(_ s: String) -> Bool { c.contains(s) }
    // Apps (helpers roll up to the parent app)
    if h("google chrome") || c == "chrome" || h("chromium") { return ("Google Chrome", "app", "globe") }
    if h("com.apple.webkit") || c == "safari" { return ("Safari / WebKit", "app", "safari") }
    if h("firefox") { return ("Firefox", "app", "globe") }
    if h("brave") { return ("Brave", "app", "globe") }
    if h("microsoft edge") || h("msedge") { return ("Microsoft Edge", "app", "globe") }
    if h("slack") { return ("Slack", "app", "message") }
    if h("spotify") { return ("Spotify", "app", "music.note") }
    if h("discord") { return ("Discord", "app", "message") }
    if h("zoom") { return ("Zoom", "app", "video") }
    if h("code helper") || c == "code" || h("electron") { return ("VS Code / Electron app", "app", "chevron.left.forwardslash.chevron.right") }
    if c == "music" { return ("Apple Music", "app", "music.note") }
    if c == "tv" { return ("Apple TV app", "app", "tv") }
    if c == "mail" { return ("Mail", "app", "envelope") }
    if c == "messages" { return ("Messages", "app", "message") }
    if h("facetime") { return ("FaceTime", "app", "video") }
    if h("photos") || h("photolibraryd") || h("photoanalysisd") { return ("Photos", "system daemon", "photo") }
    if h("tailscale") { return ("Tailscale VPN", "app", "network") }
    if h("hatchmedia") { return ("HatchMediaV2", "app", "play.rectangle") }
    if h("hatchmap") { return ("HatchMap (this app)", "app", "map") }
    // System daemons — what the OS is doing in the background
    if c == "bird" { return ("iCloud (bird)", "system daemon", "icloud") }
    if h("cloudd") { return ("iCloud Drive", "system daemon", "icloud") }
    if h("apsd") { return ("Apple Push Service", "system daemon", "bell.badge") }
    if h("identityservicesd") { return ("iMessage / FaceTime ID", "system daemon", "person.crop.circle") }
    if h("mdnsresponder") { return ("System DNS resolver", "system daemon", "magnifyingglass") }
    if h("trustd") { return ("Certificate validation", "system daemon", "checkmark.shield") }
    if h("nsurlsessiond") { return ("Background downloads", "system daemon", "arrow.down.circle") }
    if h("rapportd") { return ("Continuity / Handoff", "system daemon", "link") }
    if h("sharingd") { return ("AirDrop / Sharing", "system daemon", "square.and.arrow.up") }
    if h("netbiosd") { return ("Windows file sharing", "system daemon", "folder") }
    if h("softwareupdated") || h("suhelperd") { return ("Software Update", "system daemon", "arrow.down.circle") }
    if h("gamed") { return ("Game Center", "system daemon", "gamecontroller") }
    if h("locationd") { return ("Location Services", "system daemon", "location") }
    if h("timed") || h("ntpd") { return ("Clock sync", "system daemon", "clock") }
    if h("syncdefaultsd") { return ("iCloud settings sync", "system daemon", "icloud") }
    if h("akd") || h("accountsd") { return ("Apple ID / accounts", "system daemon", "key") }
    if h("itunescloudd") || h("amsengagementd") || h("appstoreagent") || h("storekitd") || h("storedownloadd") { return ("App Store / media", "system daemon", "bag") }
    if h("assistantd") || h("siri") { return ("Siri", "system daemon", "mic") }
    if h("dataaccessd") { return ("Mail / Contacts / Calendar sync", "system daemon", "tray.and.arrow.down") }
    if h("parsecd") || h("spotlight") || h("suggestd") { return ("Spotlight / Siri suggestions", "system daemon", "magnifyingglass") }
    if h("weatherd") { return ("Weather", "system daemon", "cloud.sun") }
    if h("commcenter") { return ("Cellular / carrier", "system daemon", "antenna.radiowaves.left.and.right") }
    if h("configd") { return ("Network configuration", "system daemon", "gearshape") }
    if h("callservicesd") || h("avconferenced") { return ("FaceTime / calls", "system daemon", "video") }
    if h("apple.geod") || h("geod") { return ("Maps", "system daemon", "map") }
    return (cmd, "background service", "app.dashed")
}

func vendorFromAuth(_ auth: String) -> String {
    guard let colon = auth.range(of: ": ") else { return "" }
    var v = String(auth[colon.upperBound...])
    if let paren = v.range(of: " (") { v = String(v[v.startIndex..<paren.lowerBound]) }
    return v
}

final class AppDB {
    static let shared = AppDB()
    private var byLocal: [String: String] = [:]      // localip:port -> command
    private var infoCache: [String: AppInfo] = [:]   // command -> resolved info
    private let lock = NSLock()

    func refresh() {
        var next: [String: String] = [:]
        var cmdPid: [String: String] = [:]
        let out = shell("/usr/sbin/lsof", ["-i", "-n", "-P", "+c", "0"])
        for raw in out.split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }
            let cmd = String(cols[0]).replacingOccurrences(of: "\\x20", with: " ")
            let pid = String(cols[1])
            let nameField = cols[8...].joined(separator: " ")
            guard let arrow = nameField.range(of: "->") else { continue }
            let local = String(nameField[nameField.startIndex..<arrow.lowerBound])
            if let key = normalizeEndpoint(local) { next[key] = cmd }
            if cmdPid[cmd] == nil { cmdPid[cmd] = pid }
        }
        lock.lock(); byLocal = next; lock.unlock()
        for (cmd, pid) in cmdPid {
            lock.lock(); let have = infoCache[cmd] != nil; lock.unlock()
            if have { continue }
            let info = AppDB.buildInfo(cmd: cmd, pid: pid)
            lock.lock(); infoCache[cmd] = info; lock.unlock()
        }
    }

    private static func buildInfo(cmd: String, pid: String) -> AppInfo {
        let (disp0, role, icon) = processMeaning(cmd)
        var bundleID = ""; var signature = ""; var display = disp0
        let path = shell("/bin/ps", ["-p", pid, "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let appR = path.range(of: ".app/") {
            let appPath = String(path[path.startIndex..<appR.upperBound].dropLast())   // ".../X.app"
            let infoBase = appPath + "/Contents/Info"
            let bid = shell("/usr/bin/defaults", ["read", infoBase, "CFBundleIdentifier"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !bid.isEmpty && !bid.contains("does not exist") && !bid.contains("Domain") { bundleID = bid }
            if disp0 == cmd {
                var bn = shell("/usr/bin/defaults", ["read", infoBase, "CFBundleDisplayName"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if bn.isEmpty || bn.contains("does not exist") { bn = shell("/usr/bin/defaults", ["read", infoBase, "CFBundleName"]).trimmingCharacters(in: .whitespacesAndNewlines) }
                if !bn.isEmpty && !bn.contains("does not exist") && !bn.contains("Domain") { display = bn }
            }
        }
        if !path.isEmpty {
            let cs = shellOut("/usr/bin/codesign", ["-dv", "--verbose=2", path])
            if let rr = cs.range(of: "Authority=") {
                let auth = String(cs[rr.upperBound...].prefix(while: { $0 != "\n" }))
                if auth.contains("Software Signing") || auth.contains("Apple Root") || auth.contains("Apple Worldwide") { signature = "Apple (system)" }
                else if auth.contains("Developer ID") { let v = vendorFromAuth(auth); signature = v.isEmpty ? "Developer ID" : "Developer ID · \(v)" }
                else if auth.contains("Mac App Store") || auth.contains("Apple Mac OS") { signature = "Mac App Store" }
                else { signature = auth }
            } else if cs.contains("not signed") { signature = "Unsigned" }
        }
        return AppInfo(process: cmd, display: display, bundleID: bundleID, signature: signature, role: role, icon: icon)
    }

    private func normalizeEndpoint(_ s: String) -> String? {
        let str = s
        if str.hasPrefix("[") {
            guard let rb = str.firstIndex(of: "]") else { return nil }
            let host = String(str[str.index(after: str.startIndex)..<rb])
            let rest = str[str.index(after: rb)...]
            guard rest.hasPrefix(":") else { return nil }
            return "\(host):\(rest.dropFirst())"
        }
        guard let colon = str.lastIndex(of: ":") else { return nil }
        let host = String(str[str.startIndex..<colon])
        let port = String(str[str.index(after: colon)...])
        return "\(host):\(port)"
    }
    func app(meIP: String, mePort: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byLocal["\(meIP):\(mePort)"]
    }
    func info(_ cmd: String) -> AppInfo? {
        lock.lock(); defer { lock.unlock() }
        return infoCache[cmd]
    }
}

// MARK: - Active network scanner

struct ScanHost: Identifiable {
    let id = UUID()
    let ip: String
    let name: String
    let vendor: String
    let openPorts: [Int]
    let exposures: [String]
}

final class Scanner: ObservableObject {
    @Published var results: [ScanHost] = []
    @Published var scanning = false
    @Published var progress = "Not scanned yet"

    private let commonPorts = [21,22,23,80,139,443,445,515,548,631,1400,1900,3389,5000,5900,8009,8080,8123,8443,9100,32400,62078]
    private let extendedPorts = [25,53,110,143,465,587,993,995,2049,3000,3001,3306,5432,5601,6379,8000,8006,8088,8096,8770,8771,9000,9090,9093,9096,3100]
    private var ports: [Int] { Options.shared.scanExtended ? (commonPorts + extendedPorts).sorted() : commonPorts }
    private let portName: [Int: String] = [21:"FTP",22:"SSH",23:"Telnet",25:"SMTP",53:"DNS",80:"HTTP",110:"POP3",139:"SMB",143:"IMAP",443:"HTTPS",445:"SMB",465:"SMTPS",515:"LPD",548:"AFP",587:"SMTP",631:"IPP",993:"IMAPS",995:"POP3S",1400:"Sonos",1900:"UPnP",2049:"NFS",3000:"Grafana",3001:"Kuma",3100:"Loki",3306:"MySQL",3389:"RDP",5000:"UPnP",5432:"Postgres",5601:"Kibana",5900:"VNC",6379:"Redis",8000:"HTTP",8006:"Proxmox",8009:"Cast",8080:"HTTP",8088:"Dozzle",8096:"Jellyfin",8123:"HomeAsst",8443:"HTTPS",8770:"HatchAPI",8771:"HatchAct",9000:"HTTP",9090:"Prom",9093:"AlertMgr",9096:"Jellyfin",9100:"Print",32400:"Plex",62078:"iOS"]

    func portLabel(_ p: Int) -> String { "\(p)" + (portName[p].map { " \($0)" } ?? "") }

    func scan() {
        guard !scanning else { return }
        NetID.shared.refresh()
        scanning = true; results = []
        let subnet = NetID.shared.subnetPrefix
        progress = "Discovering hosts on \(subnet)0/24…"
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let g = DispatchGroup(); let sem = DispatchSemaphore(value: 48)
            for i in 1...254 {
                sem.wait(); g.enter()
                DispatchQueue.global().async {
                    _ = shell("/sbin/ping", ["-c","1","-W","300","-t","1","\(subnet)\(i)"])
                    sem.signal(); g.leave()
                }
            }
            g.wait()
            DispatchQueue.main.async { self.progress = "Scanning ports…" }
            var hosts: [(String, String, String)] = []
            var seen = Set<String>()
            for raw in shell("/usr/sbin/arp", ["-a"]).split(separator: "\n") {
                let line = String(raw)
                guard let lp = line.firstIndex(of: "("), let rp = line.firstIndex(of: ")") else { continue }
                let ip = String(line[line.index(after: lp)..<rp])
                guard ip.hasPrefix(subnet), seen.insert(ip).inserted else { continue }
                let hostPart = line[line.startIndex..<lp].trimmingCharacters(in: .whitespaces)
                var mac = ""
                if let atR = line.range(of: " at ") { mac = String(line[atR.upperBound...].split(separator: " ").first ?? "") }
                if mac.contains("incomplete") { continue }
                hosts.append((ip, mac, hostPart == "?" ? "" : hostPart))
            }
            let total = hosts.count
            var acc: [ScanHost] = []; let accLock = NSLock(); var done = 0
            let hg = DispatchGroup(); let hsem = DispatchSemaphore(value: max(4, Options.shared.scanConcurrency))
            for h in hosts {
                hsem.wait(); hg.enter()
                DispatchQueue.global().async {
                    let open = self.probePorts(h.0)
                    var name = h.2.replacingOccurrences(of: ".local", with: "")
                    if name.isEmpty, let rev = reverseDNS(h.0) { name = rev.replacingOccurrences(of: ".local", with: "") }
                    let vendor = DeviceDB.shared.vendor(h.1) ?? ""
                    if name.isEmpty { name = vendor.isEmpty ? h.0 : "\(vendor) device" }
                    ScanStore.shared.set(h.0, open)
                    let host = ScanHost(ip: h.0, name: name, vendor: vendor, openPorts: open, exposures: self.exposureNotes(open))
                    accLock.lock(); acc.append(host); done += 1
                    let snap = acc.sorted { self.ipKey($0.ip) < self.ipKey($1.ip) }; let d = done
                    accLock.unlock()
                    DispatchQueue.main.async { self.results = snap; self.progress = "Scanning… \(d)/\(total) hosts" }
                    hsem.signal(); hg.leave()
                }
            }
            hg.wait()
            DispatchQueue.main.async {
                self.scanning = false
                self.progress = "Scan complete — \(total) live hosts on \(subnet)0/24"
            }
        }
    }

    private func ipKey(_ ip: String) -> Int { ip.split(separator: ".").last.flatMap { Int($0) } ?? 0 }

    private func exposureNotes(_ open: [Int]) -> [String] {
        var n: [String] = []
        if open.contains(23) { n.append("Telnet (23) open — insecure, plaintext login") }
        if open.contains(21) { n.append("FTP (21) open — often plaintext") }
        if open.contains(445) || open.contains(139) { n.append("SMB file sharing exposed") }
        if open.contains(3389) { n.append("Remote Desktop (3389) exposed") }
        if open.contains(5900) { n.append("VNC (5900) exposed") }
        if open.contains(9100) { n.append("Raw printing (9100) open") }
        if open.contains(80) && !open.contains(443) { n.append("Unencrypted web (80), no HTTPS") }
        return n
    }

    private func probePorts(_ ip: String) -> [Int] {
        let syncQ = DispatchQueue(label: "hatchmap.net.probe")
        var open: [Int] = []
        let g = DispatchGroup()
        let timeout = Double(max(300, Options.shared.scanTimeoutMs)) / 1000
        for port in ports {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { continue }
            g.enter()
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
            var finished = false
            func finish(_ isOpen: Bool) {
                if finished { return }
                finished = true
                if isOpen { open.append(port) }
                conn.cancel(); g.leave()
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: syncQ)
            syncQ.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
        g.wait()
        return open.sorted()
    }
}
