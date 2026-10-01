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

    static func run(_ args: [String], input: String? = nil, completion: @escaping @Sendable (Result) -> Void) {
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
            let stdin = input.map { _ in Pipe() }
            p.standardInput = stdin ?? FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                completion(Result(status: 126, output: "couldn't run clipbridge: \(error.localizedDescription)"))
                return
            }
            if let stdin, let input {
                stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
                try? stdin.fileHandleForWriting.close()
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

    /// Alerts show the app icon (Resources/AppIcon.icns in the bundle). A bare `swift run` binary has
    /// no bundle icon, so fall back to the menu-bar symbol there instead of a generic folder.
    static func alert() -> NSAlert {
        let a = NSAlert()
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil,
           let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipBridge")?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular)) {
            a.icon = img
        }
        return a
    }

    static func message(_ title: String, _ text: String, monospaced: Bool = false) {
        activate()
        let a = alert()
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
        let a = alert()
        a.messageText = title
        a.informativeText = text
        let b = a.addButton(withTitle: ok)
        b.hasDestructiveAction = destructive
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    enum AddChoice {
        case existing(String, [String])
        case newMachine
    }

    /// Pick an ssh alias (plus extra names), or ask for a machine that isn't in ~/.ssh/config.
    static func addHost(aliases: [String]) -> AddChoice? {
        if aliases.isEmpty { return .newMachine }
        activate()
        let a = alert()
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
        a.addButton(withTitle: "New machine…")
        a.window.initialFirstResponder = popup
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let alias = popup.titleOfSelectedItem else { return nil }
            return .existing(alias, names(field.stringValue))
        case .alertThirdButtonReturn:
            return .newMachine
        default:
            return nil
        }
    }

    struct NewMachine {
        let name: String
        let host: String
        let user: String
        let port: Int
        let password: String
    }

    /// Details for a machine that isn't in ~/.ssh/config yet.
    static func newMachine(prefill: NewMachine? = nil, error: String? = nil) -> NewMachine? {
        activate()
        let a = alert()
        a.messageText = "Add a new machine"
        a.informativeText = (error.map { "⚠︎ \($0)\n\n" } ?? "") + """
            For a box that isn't in ~/.ssh/config. clipbridge makes a dedicated key, installs it with your \
            password (once, through ssh-copy-id), and sets the box up. The password is only used for that \
            and, if the box has no python3, for sudo to install it. It's never saved.

            Leave the password empty if the clipbridge key is already on the box.
            """
        func field(_ placeholder: String, _ value: String?, secure: Bool = false) -> NSTextField {
            let f: NSTextField = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
            f.placeholderString = placeholder
            f.stringValue = value ?? ""
            f.widthAnchor.constraint(equalToConstant: 270).isActive = true
            return f
        }
        let name = field("e.g. devbox (you'll ssh to it as this)", prefill?.name)
        let host = field("e.g. 192.168.1.40", prefill?.host)
        let user = field("e.g. ubuntu", prefill?.user)
        let port = field("22", prefill.map { String($0.port) })
        let password = field("optional", nil, secure: true)
        // Labels beside the fields: placeholders vanish once a field is filled in.
        let rows: [(String, NSTextField)] = [("Name", name), ("Host or IP", host), ("User", user),
                                             ("Port", port), ("Password", password)]
        let grid = NSGridView(views: rows.map { label, f in
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            return [l, f]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 5 * 22 + 4 * 8)
        a.accessoryView = grid
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let p = Int(port.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
        let m = NewMachine(name: name.stringValue.trimmingCharacters(in: .whitespaces),
                           host: host.stringValue.trimmingCharacters(in: .whitespaces),
                           user: user.stringValue.trimmingCharacters(in: .whitespaces),
                           port: p, password: password.stringValue)
        let ok = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "._-:".contains($0) } }
        guard ok(m.name), ok(m.host), ok(m.user), (1...65535).contains(m.port) else {
            return newMachine(prefill: m, error: "Fill in name, host and user (letters, digits, . _ - only).")
        }
        return m
    }

    /// Asks for extra names/IPs for an existing host.
    static func addNames(host: String, suggestions: [String]) -> [String]? {
        activate()
        let a = alert()
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
