import AppKit
import CryptoKit
import ImageIO
import XCTest

@testable import ClipBridgeCore

final class CoreTests: XCTestCase {
    let tokenHex = Data(0..<32).hexString
    var entry: HostEntry { HostEntry(host: "selftest", port: 20001, token_hex: tokenHex) }
    var key: SymmetricKey { entry.key! }

    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    // MARK: signing vectors shared with remote/test_shim.py

    func testResponseSignatureVector() {
        let msg = Signing.responseMessage(nonce: String(repeating: "a", count: 32), status: 200, body: Data("hello".utf8))
        XCTAssertEqual(Signing.mac(msg, key: key), "ef0c01c56e2368ba3fc299e4b03cd9d5a4d840bd675532285ab65d2b69f10862")
    }

    func testRequestSignatureVector() {
        let msg = Signing.requestMessage(path: "/v1/image", host: "selftest", ts: "1790000000", nonce: String(repeating: "b", count: 32))
        XCTAssertEqual(Signing.mac(msg, key: key), "4a518f4462e169e0e291b9f47f6a78821e871397e1e884193d6cc06f3558ba51")
    }

    // MARK: auth

    func query(_ path: String, ts: Date, nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
               host: String = "selftest", key: SymmetricKey? = nil) -> ([String: String], String) {
        let tsString = String(Int(ts.timeIntervalSince1970))
        let mac = Signing.mac(Signing.requestMessage(path: path, host: host, ts: tsString, nonce: nonce), key: key ?? self.key)
        return (["host": host, "ts": tsString, "nonce": nonce], mac)
    }

    func check(_ q: [String: String], _ mac: String?, nonces: NonceCache = NonceCache(), now: Date) -> AuthResult {
        Authenticator.check(path: "/v1/image", query: q, authHeader: mac, hosts: ["selftest": entry], nonces: nonces, now: now)
    }

    func testValidRequest() {
        let now = Date()
        let (q, mac) = query("/v1/image", ts: now)
        XCTAssertTrue(check(q, mac, now: now).ok)
    }

    func testBadMac() {
        let now = Date()
        let (q, _) = query("/v1/image", ts: now)
        XCTAssertEqual(check(q, String(repeating: "0", count: 64), now: now).failure, .mac)
        XCTAssertEqual(check(q, nil, now: now).failure, .mac)
        let (q2, wrong) = query("/v1/image", ts: now, key: SymmetricKey(data: Data(repeating: 7, count: 32)))
        XCTAssertEqual(check(q2, wrong, now: now).failure, .mac)
    }

    func testUnknownHost() {
        let now = Date()
        let (q, mac) = query("/v1/image", ts: now, host: "nope")
        XCTAssertEqual(check(q, mac, now: now).failure, .unknownHost)
    }

    func testReplay() {
        let now = Date()
        let nonces = NonceCache()
        let (q, mac) = query("/v1/image", ts: now)
        XCTAssertTrue(check(q, mac, nonces: nonces, now: now).ok)
        XCTAssertEqual(check(q, mac, nonces: nonces, now: now).failure, .replay)
    }

    func testSkew() {
        let now = Date()
        let (q, mac) = query("/v1/image", ts: now.addingTimeInterval(-61))
        XCTAssertEqual(check(q, mac, now: now).failure, .skew)
        let (q2, mac2) = query("/v1/image", ts: now.addingTimeInterval(-59))
        XCTAssertTrue(check(q2, mac2, now: now).ok)
    }

    func testBadNonceIsBadRequest() {
        let now = Date()
        let (q, mac) = query("/v1/image", ts: now, nonce: "xyz")
        XCTAssertEqual(check(q, mac, now: now).failure, .badRequest)
    }

    func testNonceStoredOnlyAfterValidMac() {
        let now = Date()
        let nonces = NonceCache()
        let (q, _) = query("/v1/image", ts: now)
        _ = check(q, String(repeating: "0", count: 64), nonces: nonces, now: now)
        XCTAssertEqual(nonces.count, 0)
    }

    func testNonceCacheCapAndExpiry() {
        let now = Date()
        let cache = NonceCache(ttl: 300, cap: 100)
        for i in 0..<250 { cache.insert(String(i), now: now) }
        XCTAssertEqual(cache.count, 100)
        XCTAssertFalse(cache.contains("0", now: now))
        XCTAssertTrue(cache.contains("249", now: now))
        XCTAssertFalse(cache.contains("249", now: now.addingTimeInterval(301)))
    }

    // MARK: freshness

    func testStaleAtStartupUntilChange() {
        let f = Freshness()
        let t0 = Date()
        f.observe(changeCount: 5, now: t0)
        XCTAssertFalse(f.isFresh(now: t0, window: 120))
        XCTAssertFalse(f.isFresh(now: t0, window: nil))
        f.observe(changeCount: 6, now: t0.addingTimeInterval(1))
        XCTAssertTrue(f.isFresh(now: t0.addingTimeInterval(100), window: 120))
        XCTAssertFalse(f.isFresh(now: t0.addingTimeInterval(122), window: 120))
        XCTAssertTrue(f.isFresh(now: t0.addingTimeInterval(10_000), window: nil))
    }

    // MARK: images

    func testSmallPNGPassesThroughUnchanged() throws {
        let png = try fixture("small.png")
        XCTAssertEqual(ImageSelect.normalize(png), png)
    }

    func testBigPNGDownscaled() throws {
        let out = try XCTUnwrap(ImageSelect.normalize(try fixture("big.png")))
        let (w, h) = try size(out)
        XCTAssertEqual(max(w, h), 2000)
        XCTAssertEqual(w, 2000)
        XCTAssertEqual(h, 1000)
    }

    func testTIFFConvertedToPNG() throws {
        let out = try XCTUnwrap(ImageSelect.normalize(try fixture("small.tiff")))
        XCTAssertEqual(Array(out.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let (w, h) = try size(out)
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 48)
    }

    func testImageFileURLPreferred() throws {
        let snap = Snapshot(changeCount: 1, types: ["public.file-url", "public.tiff"], fileURLs: [try fixtureURL("small.png")],
                            tiff: try fixture("small.tiff"))
        XCTAssertEqual(ImageSelect.pngData(from: snap), try fixture("small.png"))
    }

    func testNonImageFileURLMeansNoImage() throws {
        let snap = Snapshot(changeCount: 1, types: ["public.file-url", "public.tiff"], fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
                            tiff: try fixture("small.tiff"))
        XCTAssertNil(ImageSelect.pngData(from: snap))
        XCTAssertFalse(snap.hasImage)
    }

    func size(_ data: Data) throws -> (Int, Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    // MARK: HTTP

    func testParse() throws {
        let req = try XCTUnwrap(HTTPRequest.parse(Data("GET /v1/text?host=a&ts=1&nonce=ff HTTP/1.1\r\nHost: x\r\nX-CB-Auth: abc\r\n\r\n".utf8)))
        XCTAssertEqual(req.path, "/v1/text")
        XCTAssertEqual(req.query["host"], "a")
        XCTAssertEqual(req.headers["x-cb-auth"], "abc")
    }

    func testParseIncomplete() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)))
    }

    func testParseMalformed() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GET /x HTTP/1.1\r\nno-colon\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: 65, count: 9000)))
    }

    // MARK: handler

    func makeHandler(_ snap: Snapshot, paused: Bool = false, window: TimeInterval? = 120, fresh: Bool = true) -> Handler {
        let freshness = Freshness()
        freshness.observe(changeCount: fresh ? snap.changeCount - 1 : snap.changeCount, now: Date())
        let e = entry
        return Handler(freshness: freshness, hosts: { ["selftest": e] },
                       settings: { HandlerSettings(paused: paused, freshnessWindow: window) },
                       snapshot: { _ in snap })
    }

    func request(_ path: String, now: Date = Date()) -> (HTTPRequest, String) {
        let (q, mac) = query(path, ts: now)
        return (HTTPRequest(method: "GET", path: path, query: q, headers: ["x-cb-auth": mac]), q["nonce"]!)
    }

    func verifySig(_ r: HTTPResponse, nonce: String) {
        let msg = Signing.responseMessage(nonce: nonce, status: r.status, body: r.body)
        XCTAssertEqual(r.signature, Signing.mac(msg, key: key))
    }

    func testTextServedExactly() async {
        let h = makeHandler(Snapshot(changeCount: 2, types: ["public.utf8-plain-text"], string: "héllo ✓"))
        let (req, nonce) = request("/v1/text")
        let (r, ev) = await h.handle(req)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body, Data("héllo ✓".utf8))
        verifySig(r, nonce: nonce)
        XCTAssertTrue(ev.isContentPull)
    }

    func testTargets() async {
        let h = makeHandler(Snapshot(changeCount: 2, types: ["public.png", "public.utf8-plain-text"]))
        let (req, _) = request("/v1/targets")
        let (r, ev) = await h.handle(req)
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "image/png\ntext/plain\nUTF8_STRING\nSTRING\n")
        XCTAssertFalse(ev.isContentPull)
    }

    func testImageServed() async throws {
        let png = try fixture("small.png")
        let h = makeHandler(Snapshot(changeCount: 2, types: ["public.png"], png: png))
        let (req, nonce) = request("/v1/image")
        let (r, _) = await h.handle(req)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body, png)
        verifySig(r, nonce: nonce)
    }

    func testConcealedNeverServed() async {
        let snap = Snapshot(changeCount: 2, types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], string: "hunter2")
        for path in ["/v1/text", "/v1/targets", "/v1/image"] {
            let (r, ev) = await makeHandler(snap).handle(request(path).0)
            XCTAssertEqual(r.status, 204, path)
            XCTAssertEqual(ev.reason, "concealed")
        }
    }

    func testStaleAndPaused() async {
        let snap = Snapshot(changeCount: 2, types: ["public.utf8-plain-text"], string: "x")
        let (r1, e1) = await makeHandler(snap, fresh: false).handle(request("/v1/text").0)
        XCTAssertEqual(r1.status, 204)
        XCTAssertEqual(e1.reason, "stale")
        let (r2, e2) = await makeHandler(snap, paused: true).handle(request("/v1/text").0)
        XCTAssertEqual(r2.status, 204)
        XCTAssertEqual(e2.reason, "paused")
    }

    func testUnsignedGets401() async {
        let h = makeHandler(Snapshot(changeCount: 2, types: ["public.utf8-plain-text"], string: "x"))
        var (req, _) = request("/v1/text")
        req = HTTPRequest(method: "GET", path: req.path, query: req.query, headers: [:])
        let (r, ev) = await h.handle(req)
        XCTAssertEqual(r.status, 401)
        XCTAssertEqual(ev.reason, "mac")
        XCTAssertTrue(r.body.isEmpty)
    }

    // MARK: real pasteboard (private, named) for the concealed marker

    @MainActor
    func testConcealedOnNamedPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("clipbridge-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("secret", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let snap = Snapshot.read(from: pb, need: .text)
        XCTAssertTrue(snap.isConcealed)
        XCTAssertNil(snap.string)
    }
}
