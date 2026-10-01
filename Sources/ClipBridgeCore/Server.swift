import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]  // lowercased names

    public static let maxHeaderBytes = 8192

    /// Parses a request head. Returns nil while incomplete; throws when malformed.
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes { throw ParseError.tooLarge }
            return nil
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw ParseError.malformed }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              let comps = URLComponents(string: String(parts[1])), comps.path.hasPrefix("/")
        else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: comps.path, query: query, headers: headers)
    }

    public enum ParseError: Error { case malformed, tooLarge }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String?
    public var body: Data
    public var signature: String?

    public init(status: Int, contentType: String? = nil, body: Data = Data(), signature: String? = nil) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.signature = signature
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                          404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"]

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "Status")\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let signature { head += "X-CB-Sig: \(signature)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// One line in clipbridge.log and one entry in the menu's recent pulls.
public struct PullEvent: Sendable {
    public let date: Date
    public let host: String?
    public let path: String
    public let status: Int
    public let bytes: Int
    public let reason: String?

    public init(date: Date, host: String?, path: String, status: Int, bytes: Int, reason: String?) {
        self.date = date
        self.host = host
        self.path = path
        self.status = status
        self.bytes = bytes
        self.reason = reason
    }

    public var logLine: String {
        var s = "pull host=\(host ?? "-") path=\(path) status=\(status) bytes=\(bytes)"
        if let reason { s += " reason=\(reason)" }
        return s
    }

    /// A served image or text (not a targets probe): what gets a notification.
    public var isContentPull: Bool { status == 200 && (path == "/v1/image" || path == "/v1/text") }
}

public struct HandlerSettings: Sendable {
    public var paused: Bool
    public var freshnessWindow: TimeInterval?  // nil = Off

    public init(paused: Bool, freshnessWindow: TimeInterval?) {
        self.paused = paused
        self.freshnessWindow = freshnessWindow
    }
}

/// Request handling without any networking, so it can be tested directly.
public final class Handler: @unchecked Sendable {
    public static let maxImageBytes = 25 * 1024 * 1024
    public static let maxTextBytes = 4 * 1024 * 1024
    static let routes: Set<String> = ["/v1/targets", "/v1/image", "/v1/text"]

    public let nonces: NonceCache
    public let freshness: Freshness
    let hosts: () -> [String: HostEntry]
    let settings: () -> HandlerSettings
    let snapshot: @Sendable (Need) async -> Snapshot

    public init(
        nonces: NonceCache = NonceCache(),
        freshness: Freshness,
        hosts: @escaping () -> [String: HostEntry],
        settings: @escaping () -> HandlerSettings,
        snapshot: @escaping @Sendable (Need) async -> Snapshot
    ) {
        self.nonces = nonces
        self.freshness = freshness
        self.hosts = hosts
        self.settings = settings
        self.snapshot = snapshot
    }

    public func handle(_ req: HTTPRequest, now: Date = Date()) async -> (HTTPResponse, PullEvent) {
        func event(_ r: HTTPResponse, _ host: String?, _ reason: String?) -> PullEvent {
            PullEvent(date: now, host: host, path: req.path, status: r.status, bytes: r.body.count, reason: reason)
        }
        guard req.method == "GET" else {
            let r = HTTPResponse(status: 405)
            return (r, event(r, nil, "method"))
        }
        guard Handler.routes.contains(req.path) else {
            let r = HTTPResponse(status: 404)
            return (r, event(r, nil, "route"))
        }
        let auth = Authenticator.check(path: req.path, query: req.query, authHeader: req.headers["x-cb-auth"],
                                       hosts: hosts(), nonces: nonces, now: now)
        func signed(_ status: Int, _ type: String? = nil, _ body: Data = Data()) -> HTTPResponse {
            var r = HTTPResponse(status: status, contentType: type, body: body)
            if let key = auth.entry?.key, let nonce = auth.nonce {
                r.signature = Signing.mac(Signing.responseMessage(nonce: nonce, status: status, body: body), key: key)
            }
            return r
        }
        if let failure = auth.failure {
            let r = signed(failure == .badRequest ? 400 : 401)
            return (r, event(r, auth.host, failure.rawValue))
        }
        let s = settings()
        if s.paused {
            let r = signed(204)
            return (r, event(r, auth.host, "paused"))
        }
        let need: Need = req.path == "/v1/image" ? .image : req.path == "/v1/text" ? .text : .types
        let snap = await snapshot(need)
        freshness.observe(changeCount: snap.changeCount, now: now)
        if snap.isConcealed {
            let r = signed(204)
            return (r, event(r, auth.host, "concealed"))
        }
        if !freshness.isFresh(now: now, window: s.freshnessWindow) {
            let r = signed(204)
            return (r, event(r, auth.host, "stale"))
        }
        switch need {
        case .types:
            var lines: [String] = []
            if snap.hasImage { lines.append("image/png") }
            if snap.hasText { lines += ["text/plain", "UTF8_STRING", "STRING"] }
            let r = lines.isEmpty ? signed(204) : signed(200, "text/plain", Data((lines.joined(separator: "\n") + "\n").utf8))
            return (r, event(r, auth.host, lines.isEmpty ? "empty" : nil))
        case .image:
            guard let png = ImageSelect.pngData(from: snap) else {
                let r = signed(204)
                return (r, event(r, auth.host, "no-image"))
            }
            if png.count > Handler.maxImageBytes {
                let r = signed(413)
                return (r, event(r, auth.host, "too-large"))
            }
            let r = signed(200, "image/png", png)
            return (r, event(r, auth.host, nil))
        case .text:
            guard let text = snap.string, !text.isEmpty else {
                let r = signed(204)
                return (r, event(r, auth.host, "no-text"))
            }
            let body = Data(text.utf8)
            if body.count > Handler.maxTextBytes {
                let r = signed(413)
                return (r, event(r, auth.host, "too-large"))
            }
            let r = signed(200, "text/plain; charset=utf-8", body)
            return (r, event(r, auth.host, nil))
        }
    }
}
