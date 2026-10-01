import Foundation

/// A configured host, as written by `clipbridge add` to ~/.config/clipbridge/hosts/<alias>.json.
/// Same file as HostEntry; this view carries what the menu needs (matched names, the box's IPs).
public struct HostInfo: Decodable, Sendable {
    public let host: String
    public let port: Int
    public let also: [String]?
    public let ips: [String]?
    public let added: Double?
    public let names_added: [String: Double]?

    /// Names the ssh config block matches: alias, HostName, --also names.
    public var matched: [String] {
        var out = [host]
        for n in (names_added ?? [:]).keys.sorted() + (also ?? []) where !out.contains(n) { out.append(n) }
        return out
    }

    public static func loadAll(from dir: URL) -> [HostInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(HostInfo.self, from: data)
        }
    }
}

/// Aliases from ~/.ssh/config that could be added (no wildcards, not inside clipbridge blocks).
public enum SSHConfig {
    public static func aliases(in text: String) -> [String] {
        var out: [String] = []
        var inBlock = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# clipbridge begin") { inBlock = true; continue }
            if line.hasPrefix("# clipbridge end") { inBlock = false; continue }
            if inBlock { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for name in parts.dropFirst() where !name.contains(where: { "*?!".contains($0) }) && !out.contains(name) {
                out.append(name)
            }
        }
        return out
    }
}

/// A running interactive `ssh` process and where it connects to.
public struct SSHSession: Sendable {
    public let pid: Int
    public let started: Date
    public let destination: String

    public init(pid: Int, started: Date, destination: String) {
        self.pid = pid
        self.started = started
        self.destination = destination
    }

    /// ssh options that take an argument (from ssh(1)).
    static let optionsWithArg = Set("BbcDEeFIiJLlmOoPpQRSWw")

    public static func running(now: Date = Date()) -> [SSHSession] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,etime=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { parse(String($0), now: now) }
    }

    public static func parse(_ line: String, now: Date) -> SSHSession? {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 3, let pid = Int(cols[0]), let elapsed = parseElapsed(cols[1]) else { return nil }
        let args = Array(cols[2...])
        guard (args[0] as NSString).lastPathComponent == "ssh" else { return nil }
        var i = 1
        var dest: String?
        while i < args.count {
            let a = args[i]
            if a == "--" { dest = i + 1 < args.count ? args[i + 1] : nil; break }
            if a.hasPrefix("-") && a.count > 1 {
                let flags = Array(a.dropFirst())
                // -G/-O/-V/-Q are queries; -T/-N/-W/-f are tunnels or background jobs with no
                // terminal, so nothing there pastes.
                if flags.contains(where: { "GOVQTNWf".contains($0) }) { return nil }
                if let idx = flags.firstIndex(where: { optionsWithArg.contains($0) }), idx == flags.count - 1 { i += 1 }
                i += 1
                continue
            }
            dest = a
            break
        }
        guard var d = dest else { return nil }
        if d.hasPrefix("ssh://") { d = String(d.dropFirst(6)) }
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        if let colon = d.firstIndex(of: ":"), !d.contains("::") { d = String(d[..<colon]) }
        return SSHSession(pid: pid, started: now.addingTimeInterval(-elapsed), destination: d)
    }

    /// ps etime: [[dd-]hh:]mm:ss
    public static func parseElapsed(_ s: String) -> TimeInterval? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }
        return days * 86400 + secs
    }
}

/// Something in the menu that needs the user's attention.
public struct HostWarning: Sendable {
    public enum Kind: Sendable {
        /// The session reached a set-up box by an address the ssh block doesn't match: no clipboard.
        case unmatchedAddress
        /// The session started before clipbridge matched that name: it has no forward until reconnected.
        case openedBeforeSetup
    }

    public let kind: Kind
    public let host: String
    public let destination: String
    public let pids: [Int]

    public static func compute(hosts: [HostInfo], sessions: [SSHSession]) -> [HostWarning] {
        var grouped: [String: (Kind, String, String, [Int])] = [:]
        for s in sessions {
            for h in hosts {
                let key: String
                let kind: Kind
                if h.matched.contains(s.destination) {
                    let since = h.names_added?[s.destination] ?? h.added ?? 0
                    guard s.started.timeIntervalSince1970 < since - 2 else { continue }
                    kind = .openedBeforeSetup
                    key = "pre|\(h.host)|\(s.destination)"
                } else if (h.ips ?? []).contains(s.destination) {
                    kind = .unmatchedAddress
                    key = "ip|\(h.host)|\(s.destination)"
                } else {
                    continue
                }
                var entry = grouped[key] ?? (kind, h.host, s.destination, [])
                entry.3.append(s.pid)
                grouped[key] = entry
            }
        }
        return grouped.values
            .map { HostWarning(kind: $0.0, host: $0.1, destination: $0.2, pids: $0.3.sorted()) }
            .sorted { ($0.kind == .unmatchedAddress ? 0 : 1, $0.host, $0.destination) < ($1.kind == .unmatchedAddress ? 0 : 1, $1.host, $1.destination) }
    }

    public var title: String {
        let n = pids.count == 1 ? "1 ssh session" : "\(pids.count) ssh sessions"
        switch kind {
        case .unmatchedAddress:
            return "⚠︎ \(n) to \(host) via \(destination) can't see the clipboard. Fix…"
        case .openedBeforeSetup:
            return "⚠︎ \(n) to \(host) (\(destination)) opened before setup. Reconnect \(pids.count == 1 ? "it" : "them")"
        }
    }
}

