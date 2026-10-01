import AppKit
import ClipBridgeCore
import Foundation

/// Runs the clipbridge CLI. All host changes go through it so the app and the terminal agree.
enum CLI {
    static var path: String? {
        let candidates = [Paths.home.appendingPathComponent(".local/bin/clipbridge").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ args: [String], completion: @escaping @Sendable (Result) -> Void) {
        guard let path else {
            completion(Result(status: 127, output: "clipbridge CLI not found at ~/.local/bin/clipbridge. Run bin/clipbridge install from the repo."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(Paths.home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOME"] = Paths.home.path
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                completion(Result(status: 126, output: "couldn't run clipbridge: \(error.localizedDescription)"))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            completion(Result(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
        }
    }
}

/// Small modal dialogs. The app is a menu-bar accessory, so it has to come forward first.
@MainActor
enum Dialog {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    static func message(_ title: String, _ text: String, monospaced: Bool = false) {
        activate()
        let a = NSAlert()
        a.messageText = title
        if monospaced {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.string = text
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            a.accessoryView = scroll
        } else {
            a.informativeText = text
        }
        a.runModal()
    }

    static func confirm(_ title: String, _ text: String, ok: String, destructive: Bool = false) -> Bool {
        activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let b = a.addButton(withTitle: ok)
        b.hasDestructiveAction = destructive
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Returns (alias, extra names) or nil if cancelled.
    static func addHost(aliases: [String]) -> (String, [String])? {
        activate()
        let a = NSAlert()
        a.messageText = "Add a host"
        a.informativeText = """
            Pick the ssh alias from ~/.ssh/config. clipbridge adds a forward for it, installs the xclip / xsel / \
            pbpaste shims on the box, and puts ~/.local/bin first on its PATH.

            If you sometimes connect by IP instead of the alias, list those IPs too (space-separated). The box's \
            own addresses are offered after setup.
            """
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: aliases)
        let field = NSTextField(frame: .zero)
        field.placeholderString = "Other IPs or names (optional), e.g. 192.168.1.40"
        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
        popup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        a.accessoryView = stack
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = popup
        guard a.runModal() == .alertFirstButtonReturn, let alias = popup.titleOfSelectedItem else { return nil }
        return (alias, names(field.stringValue))
    }

    /// Asks for extra names/IPs for an existing host.
    static func addNames(host: String, suggestions: [String]) -> [String]? {
        activate()
        let a = NSAlert()
        a.messageText = "Also match \(host) by…"
        a.informativeText = suggestions.isEmpty
            ? "IPs or names you ssh to for this box (space-separated)."
            : "IPs or names you ssh to for this box (space-separated). This box also answers on: \(suggestions.joined(separator: " "))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = suggestions.joined(separator: " ")
        a.accessoryView = field
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = names(field.stringValue)
        return n.isEmpty ? nil : n
    }

    static func names(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).map(String.init)
    }
}
