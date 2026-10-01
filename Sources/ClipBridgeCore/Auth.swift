import CryptoKit
import Foundation

/// One remote host allowed to pull. Same JSON shape as the remote shim's config.json.
public struct HostEntry: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token_hex: String

    public init(host: String, port: Int, token_hex: String) {
        self.host = host
        self.port = port
        self.token_hex = token_hex
    }

    public var key: SymmetricKey? {
        guard let data = Data(hex: token_hex), data.count >= 16 else { return nil }
        return SymmetricKey(data: data)
    }
}

/// Reads ~/.config/clipbridge/hosts/*.json. Called on every request; the folder is tiny.
public enum HostStore {
    public static func load(from dir: URL) -> [String: HostEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: HostEntry] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(HostEntry.self, from: data),
                  entry.key != nil
            else { continue }
            out[entry.host] = entry
        }
        return out
    }
}

public enum Signing {
    public static func requestMessage(path: String, host: String, ts: String, nonce: String) -> String {
        "req|\(path)|\(host)|\(ts)|\(nonce)"
    }

    public static func responseMessage(nonce: String, status: Int, body: Data) -> String {
        "resp|\(nonce)|\(status)|\(SHA256.hash(data: body).hexString)"
    }

    public static func mac(_ message: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).hexString
    }

    /// Constant-time check of a hex MAC.
    public static func verify(_ message: String, macHex: String, key: SymmetricKey) -> Bool {
        guard let given = Data(hex: macHex), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data(message.utf8), using: key)
    }
}

/// Remembers nonces from valid requests for 5 minutes, capped so it can't grow without bound.
public final class NonceCache: @unchecked Sendable {
    private var seen: [String: Date] = [:]
    private var order: [(String, Date)] = []
    private let ttl: TimeInterval
    private let cap: Int
    private let lock = NSLock()

    public init(ttl: TimeInterval = 300, cap: Int = 10_000) {
        self.ttl = ttl
        self.cap = cap
    }

    public var count: Int { lock.withLock { seen.count } }

    public func contains(_ nonce: String, now: Date) -> Bool {
        lock.withLock {
            prune(now)
            return seen[nonce] != nil
        }
    }

    public func insert(_ nonce: String, now: Date) {
        lock.withLock {
            prune(now)
            seen[nonce] = now
            order.append((nonce, now))
            while seen.count > cap, !order.isEmpty {
                let (old, _) = order.removeFirst()
                seen[old] = nil
            }
        }
    }

    private func prune(_ now: Date) {
        while let first = order.first, now.timeIntervalSince(first.1) > ttl {
            order.removeFirst()
            seen[first.0] = nil
        }
    }
}

public enum AuthFailure: String, Sendable {
    case badRequest = "bad-request"
    case unknownHost = "unknown-host"
    case skew
    case mac
    case replay
}

public struct AuthResult: Sendable {
    public let host: String?
    public let entry: HostEntry?
    public let nonce: String?
    public let failure: AuthFailure?

    public var ok: Bool { failure == nil }
}

public enum Authenticator {
    public static let maxSkew: TimeInterval = 60

    public static func check(
        path: String,
        query: [String: String],
        authHeader: String?,
        hosts: [String: HostEntry],
        nonces: NonceCache,
        now: Date
    ) -> AuthResult {
        let host = query["host"]
        let nonce = query["nonce"]
        guard let host, let nonce, let ts = query["ts"], let tsValue = Double(ts),
              nonce.count == 32, nonce.allSatisfy(\.isHexDigit)
        else {
            return AuthResult(host: host, entry: nil, nonce: nil, failure: .badRequest)
        }
        guard let entry = hosts[host], let key = entry.key else {
            return AuthResult(host: host, entry: nil, nonce: nonce, failure: .unknownHost)
        }
        func fail(_ f: AuthFailure) -> AuthResult { AuthResult(host: host, entry: entry, nonce: nonce, failure: f) }
        if abs(now.timeIntervalSince1970 - tsValue) > maxSkew { return fail(.skew) }
        let message = Signing.requestMessage(path: path, host: host, ts: ts, nonce: nonce)
        guard let authHeader, Signing.verify(message, macHex: authHeader, key: key) else { return fail(.mac) }
        if nonces.contains(nonce, now: now) { return fail(.replay) }
        nonces.insert(nonce, now: now)
        return AuthResult(host: host, entry: entry, nonce: nonce, failure: nil)
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let hi = a.hexDigitValue, let lo = b.hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
        }
        self.init(bytes)
    }

    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Digest {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
