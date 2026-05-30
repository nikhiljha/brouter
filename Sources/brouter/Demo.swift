import AppKit

/// `brouter ask-demo` — show the Ask dialog with sample options so the UI can
/// be previewed without being the default browser. Exits after a choice.
enum Demo {
    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = DemoDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    /// Build sample targets, preferring browsers from the user's config,
    /// falling back to whatever browsers are installed.
    static func sampleTargets() -> [BrowserTarget] {
        let router = Router(configURL: Config.resolveURL())
        if router.load() {
            let b = router.allBrowsers()
            if !b.isEmpty { return b }
        }
        var out: [BrowserTarget] = []
        let candidates: [(String, String?)] = [
            ("Google Chrome", "Default"),
            ("Google Chrome", "Profile 1"),
            ("Safari", nil),
            ("Firefox", nil),
            ("Arc", nil)
        ]
        for (app, profile) in candidates where BrowserLauncher.appURL(for: app) != nil {
            let label = profile.map { "\(app) — \($0)" } ?? app
            out.append(BrowserTarget(app: app, profile: profile, label: label))
        }
        if out.isEmpty { out = [BrowserTarget(app: "Safari", label: "Safari")] }
        return out
    }
}

private final class DemoDelegate: NSObject, NSApplicationDelegate {
    let controller = AskDialogController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let req = AskRequest(
            url: "https://github.com/nikhiljha/brouter/pull/42",
            options: Demo.sampleTargets(),
            message: "Open link in…",
            defaultIndex: 0,
            timeout: nil
        )
        controller.present(req) { target in
            if let target {
                print("selected: \(target.displayName)")
            } else {
                print("cancelled")
            }
            NSApp.terminate(nil)
        }
    }
}
