import AppKit
import ClipBridgeCore
import Foundation
import Network
import UserNotifications

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let config = home.appendingPathComponent(".config/clipbridge")
    static let hosts = config.appendingPathComponent("hosts")
    static let paused = config.appendingPathComponent("paused")
    static let log = home.appendingPathComponent("Library/Logs/clipbridge.log")
}

enum Settings {
    static let defaults = UserDefaults.standard
    static let windows: [(String, TimeInterval)] = [("2 minutes", 120), ("10 minutes", 600), ("Off", 0)]

    /// 0 in defaults means Off (no time limit).
    static var freshness: TimeInterval {
        get { defaults.object(forKey: "freshness") as? TimeInterval ?? 120 }
        set { defaults.set(newValue, forKey: "freshness") }
    }

    static var notify: Bool {
        get { defaults.object(forKey: "notify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify") }
    }

    static var paused: Bool { FileManager.default.fileExists(atPath: Paths.paused.path) }

    static func setPaused(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: Paths.paused.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: Paths.paused)
        }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "clipbridge.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            let url = Paths.log
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(stamped.utf8))
        }
    }
}

final class Server: @unchecked Sendable {
    static let port: UInt16 = 7788
    let handler: Handler
    let onEvent: @Sendable (PullEvent) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "clipbridge.server")

    init(handler: Handler, onEvent: @escaping @Sendable (PullEvent) -> Void) {
        self.handler = handler
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Server.port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.write("listening 127.0.0.1:\(Server.port)")
            case .failed(let error):
                Log.write("listener failed: \(error); exiting")
                // exit(0) so launchd's KeepAlive (SuccessfulExit=false) doesn't restart in a loop.
                exit(0)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        let timeout = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        receive(conn, buffer: Data(), timeout: timeout)
    }

    private func receive(_ conn: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            let parsed: HTTPRequest?
            do {
                parsed = try HTTPRequest.parse(buf)
            } catch {
                timeout.cancel()
                self.send(conn, HTTPResponse(status: 400))
                return
            }
            if let req = parsed {
                timeout.cancel()
                let handler = self.handler
                let onEvent = self.onEvent
                Task {
                    let (resp, event) = await handler.handle(req)
                    onEvent(event)
                    self.send(conn, resp)
                }
            } else if isComplete || error != nil {
                timeout.cancel()
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf, timeout: timeout)
            }
        }
    }

    private func send(_ conn: NWConnection, _ resp: HTTPResponse) {
        conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var server: Server?
    private let freshness = Freshness()
    private var recent: [PullEvent] = []
    private var notifyAllowed = false
    private var lastIcon: String?
    private var warnings: [HostWarning] = []
    private var busy: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Paths.hosts, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        if #available(macOS 15.4, *) {
            Log.write("start accessBehavior=\(NSPasteboard.general.accessBehavior.rawValue)")
        } else {
            Log.write("start")
        }

        freshness.observe(changeCount: NSPasteboard.general.changeCount, now: Date())
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.freshness.observe(changeCount: NSPasteboard.general.changeCount, now: Date())
                self.updateIcon()
            }
        }

        refreshWarnings()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWarnings() }
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            Task { @MainActor in self.notifyAllowed = granted }
            Log.write(granted ? "notify-authorized" : "notify-denied\(error.map { " \($0.localizedDescription)" } ?? "")")
        }

        let handler = Handler(
            freshness: freshness,
            hosts: { HostStore.load(from: Paths.hosts) },
            settings: {
                let w = Settings.freshness
                return HandlerSettings(paused: Settings.paused, freshnessWindow: w == 0 ? nil : w)
            },
            snapshot: { need in await MainActor.run { Snapshot.read(from: .general, need: need) } }
        )
        let server = Server(handler: handler) { [weak self] event in
            Log.write(event.logLine)
            Task { @MainActor in self?.record(event) }
        }
        do {
            try server.start()
        } catch {
            Log.write("listener error: \(error); exiting")
            exit(0)
        }
        self.server = server
    }

    private func record(_ event: PullEvent) {
        guard event.isContentPull else { return }
        recent.insert(event, at: 0)
        recent = Array(recent.prefix(10))
        guard Settings.notify else { return }
        guard notifyAllowed else {
            Log.write("notify-denied")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Clipboard pulled"
        let kind = event.path == "/v1/image" ? "Image" : "Text"
        content.body = "\(kind) · \(event.host ?? "?") · \(ByteCountFormatter.string(fromByteCount: Int64(event.bytes), countStyle: .file))"
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            Log.write(error == nil ? "notified" : "notify-failed \(error!.localizedDescription)")
        }
    }

    private func updateIcon() {
        let paused = Settings.paused
        let name = paused ? "pause.circle" : warnings.contains { $0.kind == .unmatchedAddress } ? "exclamationmark.triangle" : "doc.on.clipboard"
        guard name != lastIcon else { return }
        lastIcon = name
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: paused ? "ClipBridge paused" : "ClipBridge")
        statusItem.button?.image?.isTemplate = true
    }

    private func refreshWarnings() {
        DispatchQueue.global(qos: .utility).async {
            let w = HostWarning.compute(hosts: HostInfo.loadAll(from: Paths.hosts), sessions: SSHSession.running())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.warnings = w
                    self.updateIcon()
                }
            }
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = Settings.paused
        menu.addItem(withTitle: paused ? "ClipBridge: Paused" : "ClipBridge: On", action: nil, keyEquivalent: "")
        menu.addItem(item(paused ? "Resume" : "Pause", #selector(togglePause)))
        menu.addItem(.separator())

        // Warnings are recomputed every 20 s; recompute now too, synchronously (ps is quick).
        warnings = HostWarning.compute(hosts: HostInfo.loadAll(from: Paths.hosts), sessions: SSHSession.running())
        updateIcon()
        for w in warnings {
            let i = item(w.title, #selector(fixWarning(_:)))
            i.representedObject = w
            if w.kind == .openedBeforeSetup { i.toolTip = "These sessions were opened before clipbridge matched this name, so they have no forward. Exit and reconnect them. pids: \(w.pids.map(String.init).joined(separator: " "))" }
            menu.addItem(i)
        }
        if !warnings.isEmpty { menu.addItem(.separator()) }

        let hosts = HostInfo.loadAll(from: Paths.hosts)
        menu.addItem(withTitle: hosts.isEmpty ? "No hosts yet" : "Hosts", action: nil, keyEquivalent: "")
        for h in hosts {
            let hi = NSMenuItem(title: "  \(h.host)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let m = NSMenuItem(title: "Matches: \(h.matched.joined(separator: ", "))", action: nil, keyEquivalent: "")
            m.isEnabled = false
            sub.addItem(m)
            let others = (h.ips ?? []).filter { !h.matched.contains($0) }
            if !others.isEmpty {
                let o = NSMenuItem(title: "Not matched: \(others.joined(separator: ", "))", action: nil, keyEquivalent: "")
                o.isEnabled = false
                sub.addItem(o)
            }
            sub.addItem(.separator())
            for (title, sel) in [("Also match another IP or name…", #selector(addNames(_:))),
                                 ("Run doctor", #selector(runDoctor(_:))),
                                 ("Remove…", #selector(removeHost(_:)))] {
                let i = item(title, sel)
                i.representedObject = h.host
                i.isEnabled = busy == nil
                sub.addItem(i)
            }
            hi.submenu = sub
            menu.addItem(hi)
        }
        if let busy {
            let b = NSMenuItem(title: "  \(busy)…", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
        }
        let add = item("Add host…", #selector(addHost))
        add.isEnabled = busy == nil
        menu.addItem(add)
        menu.addItem(.separator())

        let fresh = NSMenuItem(title: "Serve copies from the last…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in Settings.windows {
            let i = item(title, #selector(setFreshness(_:)))
            i.representedObject = value
            i.state = Settings.freshness == value ? .on : .off
            sub.addItem(i)
        }
        fresh.submenu = sub
        menu.addItem(fresh)

        let notify = item("Notify on pull", #selector(toggleNotify))
        notify.state = Settings.notify ? .on : .off
        menu.addItem(notify)
        menu.addItem(.separator())

        menu.addItem(withTitle: recent.isEmpty ? "No pulls yet" : "Recent pulls", action: nil, keyEquivalent: "")
        let tf = DateFormatter()
        tf.timeStyle = .medium
        for e in recent {
            let kind = e.path == "/v1/image" ? "image" : "text"
            let size = ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file)
            let i = NSMenuItem(title: "  \(e.host ?? "?") · \(kind) · \(tf.string(from: e.date)) · \(size)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("Copy doctor command", #selector(copyDoctor)))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(item("Quit ClipBridge", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: host actions (all through the clipbridge CLI)

    private func runCLI(_ label: String, _ args: [String], then: @escaping @MainActor (CLI.Result) -> Void) {
        busy = label
        CLI.run(args) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = nil
                    self.refreshWarnings()
                    then(result)
                }
            }
        }
    }

    private static func clean(_ output: String) -> String {
        output.split(separator: "\n").filter { !$0.hasPrefix("other-ips:") }
            .map { $0.replacingOccurrences(of: "clipbridge: ", with: "") }.joined(separator: "\n")
    }

    @objc private func addHost() {
        let existing = Set(HostInfo.loadAll(from: Paths.hosts).map(\.host))
        let aliases = SSHConfig.aliases(in: (try? String(contentsOf: Paths.home.appendingPathComponent(".ssh/config"), encoding: .utf8)) ?? "").filter { !existing.contains($0) }
        guard !aliases.isEmpty else {
            Dialog.message("No ssh aliases to add", "Every Host in ~/.ssh/config is already set up, or there are none. Add a Host entry for the box first.")
            return
        }
        guard let (alias, extra) = Dialog.addHost(aliases: aliases) else { return }
        add(alias, extra)
    }

    private func add(_ alias: String, _ extra: [String]) {
        runCLI("Setting up \(alias)", ["add", alias] + extra.flatMap { ["--also", $0] }) { r in
            guard r.status == 0 else {
                Dialog.message("Couldn't set up \(alias)", Self.clean(r.output), monospaced: true)
                return
            }
            let others = r.output.split(separator: "\n").first { $0.hasPrefix("other-ips:") }
                .map { $0.dropFirst("other-ips:".count).split(separator: " ").map(String.init) } ?? []
            if !others.isEmpty,
               Dialog.confirm("\(alias) also answers on other addresses",
                              "\(others.joined(separator: ", "))\n\nIf you ever ssh to it by one of these (LAN vs Tailscale, say), that session won't see the clipboard unless it's matched too. Match them now?",
                              ok: "Match all") {
                self.add(alias, others)
                return
            }
            Dialog.message("\(alias) is ready",
                           "Open a NEW ssh session to it (sessions opened before this have no forward), then press Ctrl+V in Claude Code, or run pbpaste.\n\n\(Self.clean(r.output))")
        }
    }

    @objc private func addNames(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              let h = HostInfo.loadAll(from: Paths.hosts).first(where: { $0.host == host }) else { return }
        let suggestions = (h.ips ?? []).filter { !h.matched.contains($0) }
        guard let names = Dialog.addNames(host: host, suggestions: suggestions) else { return }
        add(host, names)
    }

    @objc private func fixWarning(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? HostWarning else { return }
        switch w.kind {
        case .unmatchedAddress:
            guard Dialog.confirm("Match \(w.host) by \(w.destination)?",
                                 "You're connected to \(w.host) as \(w.destination), which clipbridge doesn't match, so that session has no clipboard. clipbridge will add \(w.destination) to the host's ssh block. Reconnect the session afterwards.",
                                 ok: "Match \(w.destination)") else { return }
            add(w.host, [w.destination])
        case .openedBeforeSetup:
            Dialog.message("Reconnect these sessions",
                           "\(w.pids.count == 1 ? "This ssh session" : "These ssh sessions") to \(w.host) (\(w.destination)) started before clipbridge matched that name, so they have no forward to the Mac. Exit them and ssh in again.\n\npids: \(w.pids.map(String.init).joined(separator: " "))")
        }
    }

    @objc private func runDoctor(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        runCLI("Checking \(host)", ["doctor", host]) { r in
            let verdict = r.status == 0 ? "All checks passed" : r.status == 3 ? "Copy an image or text, then run again" : "Problems found"
            Dialog.message("\(host): \(verdict)", r.output, monospaced: true)
        }
    }

    @objc private func removeHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              Dialog.confirm("Remove \(host)?",
                             "Removes the shims, config and PATH line from \(host), and its block from ~/.ssh/config (a backup is kept).",
                             ok: "Remove", destructive: true) else { return }
        runCLI("Removing \(host)", ["remove", host]) { r in
            Dialog.message(r.status == 0 ? "\(host) removed" : "Couldn't remove \(host)", Self.clean(r.output), monospaced: r.status != 0)
        }
    }

    @objc private func togglePause() {
        Settings.setPaused(!Settings.paused)
        updateIcon()
    }

    @objc private func setFreshness(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TimeInterval { Settings.freshness = v }
    }

    @objc private func toggleNotify() { Settings.notify.toggle() }

    @objc private func copyDoctor() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.hosts.path)) ?? []
        let host = names.first(where: { $0.hasSuffix(".json") }).map { String($0.dropLast(5)) } ?? "<alias>"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("clipbridge doctor \(host)", forType: .string)
    }

    @objc private func openLog() { NSWorkspace.shared.open(Paths.log) }

    @objc private func quit() { exit(0) }

    // MARK: notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

// Debug/diagnostic: print what the menu would warn about, then exit.
if CommandLine.arguments.contains("--print-warnings") {
    let hosts = HostInfo.loadAll(from: Paths.hosts)
    for h in hosts { print("host \(h.host): matches \(h.matched.joined(separator: " ")); box ips \((h.ips ?? []).joined(separator: " "))") }
    let w = HostWarning.compute(hosts: hosts, sessions: SSHSession.running())
    if w.isEmpty { print("no warnings") }
    for x in w { print("\(x.title)  [pids \(x.pids.map(String.init).joined(separator: " "))]") }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
