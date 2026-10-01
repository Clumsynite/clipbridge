import XCTest

@testable import ClipBridgeCore

final class SessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_850_000)

    func testElapsed() {
        XCTAssertEqual(SSHSession.parseElapsed("05:09"), 309)
        XCTAssertEqual(SSHSession.parseElapsed("01:00:00"), 3600)
        XCTAssertEqual(SSHSession.parseElapsed("2-01:00:00"), 2 * 86400 + 3600)
        XCTAssertNil(SSHSession.parseElapsed("x"))
    }

    func testParsesInteractiveSessions() throws {
        let s = try XCTUnwrap(SSHSession.parse("  6920   10:00 ssh -p 61122 devbox@100.64.0.12", now: now))
        XCTAssertEqual(s.pid, 6920)
        XCTAssertEqual(s.destination, "100.64.0.12")
        XCTAssertEqual(s.started, now.addingTimeInterval(-600))
        XCTAssertEqual(SSHSession.parse("1 00:01 /usr/bin/ssh devbox", now: now)?.destination, "devbox")
        XCTAssertEqual(SSHSession.parse("1 00:01 ssh -l me -i ~/.ssh/k 192.168.1.40", now: now)?.destination, "192.168.1.40")
        XCTAssertEqual(SSHSession.parse("1 00:01 ssh -p61122 -4 me@box", now: now)?.destination, "box")
        XCTAssertEqual(SSHSession.parse("1 00:01 ssh -t box tmux attach", now: now)?.destination, "box")
        XCTAssertEqual(SSHSession.parse("1 00:01 ssh ssh://me@box:2222", now: now)?.destination, "box")
    }

    func testIgnoresTunnelsQueriesAndOtherProgs() {
        XCTAssertNil(SSHSession.parse("10801 03:00:00 ssh -v -T -D 62723 -o ConnectTimeout=15 devbox", now: now))
        XCTAssertNil(SSHSession.parse("1 00:01 ssh -G devbox", now: now))
        XCTAssertNil(SSHSession.parse("1 00:01 ssh -O check devbox", now: now))
        XCTAssertNil(SSHSession.parse("1 00:01 ssh -N -L 8080:localhost:80 box", now: now))
        XCTAssertNil(SSHSession.parse("1 00:01 ssh: /Users/me/.ssh/cm/abc [mux]", now: now))
        XCTAssertNil(SSHSession.parse("1 00:01 sshd: user@pts/0", now: now))
    }

    func host(names: [String: Double], also: [String] = [], ips: [String], rotated: Double? = nil) throws -> HostInfo {
        var json: [String: Any] = ["host": "devbox", "port": 23187, "token_hex": "00", "also": also,
                                   "ips": ips, "added": names.values.min() ?? 0, "names_added": names]
        if let rotated { json["rotated"] = rotated }
        return try JSONDecoder().decode(HostInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testUnmatchedAddressWarning() throws {
        let setup = now.timeIntervalSince1970 - 3600
        let h = try host(names: ["devbox": setup, "100.64.0.12": setup],
                         ips: ["192.168.1.40", "100.64.0.12"])
        let sessions = [
            SSHSession(pid: 1, started: now.addingTimeInterval(-60), destination: "192.168.1.40"),
            SSHSession(pid: 2, started: now.addingTimeInterval(-30), destination: "192.168.1.40"),
            SSHSession(pid: 3, started: now.addingTimeInterval(-60), destination: "100.64.0.12"),
            SSHSession(pid: 4, started: now.addingTimeInterval(-60), destination: "github.com"),
        ]
        let w = HostWarning.compute(hosts: [h], sessions: sessions)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].kind, .unmatchedAddress)
        XCTAssertEqual(w[0].destination, "192.168.1.40")
        XCTAssertEqual(w[0].pids, [1, 2])
    }

    func testOpenedBeforeSetupWarning() throws {
        let aliasTime = now.timeIntervalSince1970 - 3600
        let lanTime = now.timeIntervalSince1970 - 60
        let h = try host(names: ["devbox": aliasTime, "192.168.1.40": lanTime], also: ["192.168.1.40"],
                         ips: ["192.168.1.40"])
        let sessions = [
            // Opened via .46 before .46 was matched: no forward until reconnected.
            SSHSession(pid: 5, started: now.addingTimeInterval(-600), destination: "192.168.1.40"),
            // Opened via the alias after it was set up: fine.
            SSHSession(pid: 6, started: now.addingTimeInterval(-600), destination: "devbox"),
            // Opened via .46 after the fix: fine.
            SSHSession(pid: 7, started: now.addingTimeInterval(-10), destination: "192.168.1.40"),
        ]
        let w = HostWarning.compute(hosts: [h], sessions: sessions)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].kind, .openedBeforeSetup)
        XCTAssertEqual(w[0].pids, [5])
        XCTAssertEqual(h.matched, ["devbox", "192.168.1.40"])
    }

    func testOpenedBeforeKeyChangeWarning() throws {
        let setup = now.timeIntervalSince1970 - 7200
        let rotated = now.timeIntervalSince1970 - 300
        let h = try host(names: ["devbox": setup], ips: [], rotated: rotated)
        let sessions = [
            SSHSession(pid: 8, started: now.addingTimeInterval(-3600), destination: "devbox"),  // old key
            SSHSession(pid: 9, started: now.addingTimeInterval(-60), destination: "devbox"),    // new key
        ]
        let w = HostWarning.compute(hosts: [h], sessions: sessions)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].kind, .openedBeforeKeyChange)
        XCTAssertEqual(w[0].pids, [8])
        XCTAssertTrue(w[0].title.contains("before the key changed"))
    }

    func testAliasesFromSSHConfig() {
        let text = """
            Host github.com *.internal
              HostName github.com
            Host alpha-box beta-box
              User a
            Host !bad
            Host *
            # clipbridge begin devbox
            Host devbox 100.64.0.12
            # clipbridge end devbox
            host  devbox
              Port 61122
            """
        XCTAssertEqual(SSHConfig.aliases(in: text), ["github.com", "alpha-box", "beta-box", "devbox"])
    }
}
