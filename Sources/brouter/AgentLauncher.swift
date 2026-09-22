import AppKit

// MARK: - Config agents

/// An agent ("Smart Config") that can be asked to edit the config — either a
/// CLI run in a terminal, or a desktop app opened via its URL scheme.
struct ConfigAgent {
    enum Runner {
        /// A CLI run in a terminal. `command` is the resolved absolute path.
        case cli(command: String, preArgs: [String])
        /// A desktop app opened via a URL scheme with a prefilled prompt.
        case appScheme(AppScheme)
    }

    let name: String
    let runner: Runner
    /// App bundle path, used for the menu icon (app agents only).
    let iconPath: String?

    var needsTerminal: Bool { if case .cli = runner { return true }; return false }
}

/// Desktop apps that accept a prompt via their URL scheme.
enum AppScheme {
    case claudeCode   // claude://code/new?q=<prompt>&folder=<dir>
    case codex        // codex://threads/new?prompt=<prompt>&path=<dir>

    var bundleId: String {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .codex:      return "com.openai.codex"
        }
    }

    func url(configURL: URL) -> URL? {
        let dir = configURL.deletingLastPathComponent().path
        let prompt = AgentCatalog.prompt(for: configURL)
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let str: String
        switch self {
        case .claudeCode:
            str = "claude://code/new?q=\(enc(prompt))&folder=\(enc(dir))"
        case .codex:
            str = "codex://threads/new?prompt=\(enc(prompt))&path=\(enc(dir))"
        }
        return URL(string: str)
    }
}

enum AgentCatalog {
    private static let cliSpecs: [(name: String, tool: String, preArgs: [String])] = [
        ("Devin CLI",         "devin",  ["--model", "swe-1.6-fast", "--"]),
        ("Claude Code (CLI)", "claude", []),
        ("Codex (CLI)",       "codex",  []),
    ]

    static func prompt(for configURL: URL) -> String {
        "Can you help me edit this configuration? First read and understand it: \(configURL.path)"
    }

    /// Detect available agents. Desktop apps (no terminal needed) are listed
    /// first, then installed CLIs.
    static func detect() -> [ConfigAgent] {
        var out: [ConfigAgent] = []
        let ws = NSWorkspace.shared

        for (scheme, name) in [(AppScheme.claudeCode, "Claude Code (app)"), (AppScheme.codex, "Codex (app)")] {
            if let url = ws.urlForApplication(withBundleIdentifier: scheme.bundleId) {
                out.append(ConfigAgent(name: name, runner: .appScheme(scheme), iconPath: url.path))
            }
        }
        for spec in cliSpecs {
            if let path = Shell.toolPath(spec.tool) {
                out.append(ConfigAgent(name: spec.name, runner: .cli(command: path, preArgs: spec.preArgs), iconPath: nil))
            }
        }
        return out
    }
}

// MARK: - Terminals

struct TerminalApp {
    enum Kind { case kitty, ghostty, wezterm, alacritty, iterm, terminal }
    let name: String
    let appPath: String
    let kind: Kind

    var icon: NSImage { NSWorkspace.shared.icon(forFile: appPath) }
}

enum TerminalCatalog {
    private static let known: [(name: String, bundleId: String, kind: TerminalApp.Kind)] = [
        ("kitty",       "net.kovidgoyal.kitty",   .kitty),
        ("Ghostty",     "com.mitchellh.ghostty",  .ghostty),
        ("WezTerm",     "com.github.wez.wezterm",  .wezterm),
        ("iTerm",       "com.googlecode.iterm2",   .iterm),
        ("Alacritty",   "io.alacritty",            .alacritty),
        ("Terminal",    "com.apple.Terminal",      .terminal),
    ]

    static func detect() -> [TerminalApp] {
        let ws = NSWorkspace.shared
        return known.compactMap { t in
            guard let url = ws.urlForApplication(withBundleIdentifier: t.bundleId) else { return nil }
            return TerminalApp(name: t.name, appPath: url.path, kind: t.kind)
        }
    }
}

// MARK: - Launching

enum AgentLauncher {
    /// Run `agent` to help edit the config at `configURL`. For CLI agents a
    /// `terminal` must be supplied; app-scheme agents ignore it.
    static func run(agent: ConfigAgent, configURL: URL, terminal: TerminalApp?) {
        // Belt-and-suspenders: also put the prompt on the clipboard so it can be
        // pasted if an app's deep-link prefill misses (e.g. on a cold start).
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AgentCatalog.prompt(for: configURL), forType: .string)

        switch agent.runner {
        case .appScheme(let scheme):
            guard let url = scheme.url(configURL: configURL) else { return }
            NSWorkspace.shared.open(url)
        case .cli(let command, let preArgs):
            guard let terminal else { return }
            let shell = Shell.userShell
            guard let script = writeScript(command: command, preArgs: preArgs, configURL: configURL, shell: shell) else { return }
            launch(terminal: terminal, shell: shell, scriptPath: script)
        }
    }

    /// Write a temp shell script that cd's to the config dir, runs the agent,
    /// then drops into an interactive shell so the window stays open.
    private static func writeScript(command: String, preArgs: [String], configURL: URL, shell: String) -> String? {
        let dir = configURL.deletingLastPathComponent().path
        let agentCmd = ([Shell.quote(command)] + preArgs + [Shell.quote(AgentCatalog.prompt(for: configURL))])
            .joined(separator: " ")
        let body = """
        cd \(Shell.quote(dir))
        \(agentCmd)
        exec \(Shell.quote(shell)) -li
        """
        let path = NSTemporaryDirectory() + "brouter-agent-\(UUID().uuidString).sh"
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            FileHandle.standardError.write(Data("[brouter] failed to write agent script: \(error)\n".utf8))
            return nil
        }
    }

    private static func launch(terminal: TerminalApp, shell: String, scriptPath: String) {
        switch terminal.kind {
        case .kitty:
            openApp(terminal.appPath, args: [shell, "-li", scriptPath])
        case .ghostty, .alacritty:
            openApp(terminal.appPath, args: ["-e", shell, "-li", scriptPath])
        case .wezterm:
            openApp(terminal.appPath, args: ["start", "--", shell, "-li", scriptPath])
        case .iterm:
            runOSA("""
            tell application "iTerm"
              activate
              set w to (create window with default profile)
              tell current session of w to write text "\(shell) -li \(scriptPath)"
            end tell
            """)
        case .terminal:
            runOSA("""
            tell application "Terminal"
              activate
              do script "\(shell) -li \(scriptPath)"
            end tell
            """)
        }
    }

    private static func openApp(_ appPath: String, args: [String]) {
        run("/usr/bin/open", ["-na", appPath, "--args"] + args)
    }

    private static func runOSA(_ script: String) {
        run("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        do { try p.run(); return true }
        catch {
            FileHandle.standardError.write(Data("[brouter] launch failed (\(launchPath)): \(error)\n".utf8))
            return false
        }
    }
}

// MARK: - Shell helpers

enum Shell {
    /// The user's login shell (best effort).
    static var userShell: String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }

    /// Single-quote a string for safe inclusion in a shell command.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Resolve an executable's absolute path via the user's login shell
    /// (so PATH and aliases from the shell rc files are honored).
    /// Follows aliases (e.g. `devin` -> `devin-insiders`). Returns nil if not found.
    static func toolPath(_ tool: String) -> String? {
        resolve(tool, depth: 0)
    }

    private static func resolve(_ name: String, depth: Int) -> String? {
        guard depth < 4, let line = runLogin("command -v \(name) 2>/dev/null") else { return nil }
        if line.hasPrefix("/") { return line }
        if line.hasPrefix("alias ") {
            // form: alias name=value  (value may be quoted, may include args)
            guard let eq = line.firstIndex(of: "=") else { return nil }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let target = value.split(separator: " ").first.map(String.init) ?? value
            guard !target.isEmpty, target != name else { return nil }
            return resolve(target, depth: depth + 1)
        }
        return nil
    }

    /// Run a command in a login+interactive shell and return its last stdout line.
    private static func runLogin(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: userShell)
        p.arguments = ["-lic", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last
    }
}
