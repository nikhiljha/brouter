import AppKit

enum CLI {
    static let version = "0.1.0"

    /// Handle CLI subcommands. Returns an exit code if handled,
    /// or nil to continue launching as the agent.
    static func run(_ args: [String]) -> Int32? {
        guard let first = args.first else { return nil }
        let rest = Array(args.dropFirst())

        switch first {
        case "--help", "-h", "help":
            printHelp(); return 0
        case "--version", "version":
            print("brouter \(version)"); return 0
        case "--config-path", "config-path":
            print(Config.resolveURL().path); return 0
        case "--validate", "validate":
            return validate()
        case "--list-browsers", "browsers":
            return listBrowsers()
        case "--detect", "detect", "list-detected":
            return detect()
        case "--agents", "agents":
            return listAgents()
        case "--init", "init":
            return initConfig(force: rest.contains("--force") || rest.contains("-f"))
        case "--edit", "edit":
            let url = Config.ensureExists()
            NSWorkspace.shared.open(url)
            print("opening \(url.path)")
            return 0
        case "--route", "route":
            guard let url = rest.first else { errln("usage: brouter route <url>"); return 2 }
            return dryRun(url: url)
        case "--open", "open":
            guard let url = rest.first else { errln("usage: brouter open <url>"); return 2 }
            return openURL(url)
        case "--set-default", "set-default":
            return setDefault(pathArg: rest.first)
        default:
            // Anything that looks like a URL: treat as `open`.
            if first.contains("://") { return openURL(first) }
            return nil
        }
    }

    // MARK: - Commands

    private static func validate() -> Int32 {
        let router = Router(configURL: Config.resolveURL())
        let ok = router.load()
        if ok {
            print("config OK: \(router.configURL.path)")
            let browsers = router.allBrowsers()
            print("browsers: \(browsers.count)")
            for b in browsers { print("  - \(describe(b))") }
            return 0
        } else {
            errln("config INVALID: \(router.lastError ?? "unknown error")")
            return 1
        }
    }

    private static func listBrowsers() -> Int32 {
        let router = Router(configURL: Config.resolveURL())
        guard router.load() else { errln(router.lastError ?? "config error"); return 1 }
        for b in router.allBrowsers() { print(describe(b)) }
        return 0
    }

    private static func detect() -> Int32 {
        let browsers = BrowserDetector.detect()
        if browsers.isEmpty { print("No browsers detected."); return 0 }
        for b in browsers {
            print("\(b.shortName)  (\(b.bundleId))")
            for t in b.targets {
                var bits: [String] = ["key=\(t.key)", "app=\(t.app)"]
                if let p = t.profileDir { bits.append("profile=\(p)") }
                if !t.args.isEmpty { bits.append("args=\(t.args.joined(separator: " "))") }
                var label = t.profileLabel ?? "(default)"
                if let d = t.detail { label += " · \(d)" }
                print("  - \(label)  [\(bits.joined(separator: ", "))]")
            }
        }
        return 0
    }

    private static func listAgents() -> Int32 {
        let agents = AgentCatalog.detect()
        print("config agents:")
        if agents.isEmpty {
            print("  (none detected)")
        } else {
            for a in agents {
                switch a.runner {
                case .cli(let command, let preArgs):
                    let extra = preArgs.isEmpty ? "" : "  args=\(preArgs.joined(separator: " "))"
                    print("  - \(a.name)  [cli: \(command)]\(extra)")
                case .appScheme(let scheme):
                    print("  - \(a.name)  [app: \(scheme.bundleId)]")
                }
            }
        }
        print("terminals:")
        let terms = TerminalCatalog.detect()
        if terms.isEmpty {
            print("  (none detected)")
        } else {
            for t in terms { print("  - \(t.name)  [\(t.appPath)]") }
        }
        return 0
    }

    private static func initConfig(force: Bool) -> Int32 {
        let url = URL(fileURLWithPath: Config.canonical)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            errln("config already exists at \(url.path)")
            errln("use `brouter init --force` to overwrite it.")
            return 1
        }
        Config.writeStarter(to: url)
        print("wrote starter config: \(url.path)")
        print("detected \(BrowserDetector.detectTargets().count) browser/profile target(s).")
        return 0
    }

    private static func dryRun(url: String) -> Int32 {
        let router = Router(configURL: Config.resolveURL())
        guard router.load() else { errln(router.lastError ?? "config error"); return 1 }
        let decision = router.route(url: url, sourceApp: nil)
        printDecision(decision, url: url)
        return 0
    }

    private static func openURL(_ url: String) -> Int32 {
        let router = Router(configURL: Config.resolveURL())
        guard router.load() else { errln(router.lastError ?? "config error"); return 1 }
        switch router.route(url: url, sourceApp: nil) {
        case .open(let target):
            print("opening in \(target.displayName)")
            return BrowserLauncher.launch(target, url: url) ? 0 : 1
        case .ask(let req):
            print("route() requested an Ask dialog (run the agent to see it). Options:")
            for (i, o) in req.options.enumerated() { print("  \(i + 1). \(describe(o))") }
            return 0
        case .none:
            errln("no route for \(url)")
            return 1
        }
    }

    private static func setDefault(pathArg: String?) -> Int32 {
        let appURL: URL
        if let pathArg {
            appURL = URL(fileURLWithPath: NSString(string: pathArg).expandingTildeInPath)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            appURL = Bundle.main.bundleURL
        } else {
            let candidates = [
                "/Applications/brouter.app",
                NSString(string: "~/Applications/brouter.app").expandingTildeInPath
            ]
            guard let installed = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                errln("Could not find brouter.app. Install it first (make install), or pass a path: brouter set-default /path/to/brouter.app")
                return 1
            }
            appURL = URL(fileURLWithPath: installed)
        }

        print("Setting \(appURL.lastPathComponent) as default for http/https…")
        // Give the request a real foreground app context so macOS can present
        // its "allow change of default browser?" consent prompt.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let ws = NSWorkspace.shared
        var remaining = 2
        var failure: NSError?
        for scheme in ["http", "https"] {
            ws.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error { failure = error as NSError }
                remaining -= 1
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while remaining > 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if let failure {
            errln("failed: \(failure.localizedDescription) [\(failure.domain) \(failure.code)]")
            errln("Tip: set it manually — System Settings ▸ Desktop & Dock ▸ Default web browser ▸ brouter")
            return 1
        }
        print("Done. brouter is now your default browser.")
        return 0
    }

    // MARK: - Output helpers

    private static func describe(_ t: BrowserTarget) -> String {
        var s = t.displayName
        var bits: [String] = []
        bits.append("app=\(t.app)")
        if let p = t.profile { bits.append("profile=\(p)") }
        if !t.args.isEmpty { bits.append("args=\(t.args.joined(separator: " "))") }
        s += "  [\(bits.joined(separator: ", "))]"
        return s
    }

    private static func printDecision(_ decision: RouteDecision, url: String) {
        switch decision {
        case .open(let t):
            print("route(\(url))")
            print("  -> open in \(describe(t))")
            print("  $ open \(BrowserLauncher.openArguments(for: t, url: url).joined(separator: " "))")
        case .ask(let req):
            print("route(\(url))")
            print("  -> ASK\(req.message.map { " (\($0))" } ?? "")")
            for (i, o) in req.options.enumerated() {
                let star = (req.defaultIndex ?? 0) == i ? "*" : " "
                print("   \(star)\(i + 1). \(describe(o))")
            }
        case .none:
            print("route(\(url))")
            print("  -> no route (agent falls back to first/Safari)")
        }
    }

    private static func errln(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    private static func printHelp() {
        print("""
        brouter \(version) — a JavaScript-configurable browser router for macOS

        USAGE:
          brouter                       run as the agent (default; used by launchd)
          brouter route <url>           show where a URL would go (dry run)
          brouter open <url>            route and open a URL now
          brouter validate              load the config and report errors
          brouter detect                list autodetected browsers + profiles
          brouter agents                list detected coding agents + terminals
          brouter init [--force]        write a starter config (with detected browsers)
          brouter edit                  open the config in your editor
          brouter browsers              list browsers defined in the config
          brouter set-default [app]     set brouter as the default http/https handler
          brouter config-path          print the resolved config file path
          brouter version
          brouter help

        CONFIG:
          Resolved from, in order:
            1. $BROUTER_CONFIG
            2. \(Config.canonical)
            3. \(Config.xdgConfig)
        """)
    }
}
