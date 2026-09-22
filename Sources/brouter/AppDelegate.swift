import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = Router(configURL: Config.resolveURL())
    private var statusBar: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register to receive URLs as the default http/https handler.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create a starter config (populated with detected browsers) on first run.
        Config.ensureExists()
        router.load()
        if let err = router.lastError {
            FileHandle.standardError.write(Data("[brouter] started with config error: \(err)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[brouter] agent ready (config: \(router.configURL.path))\n".utf8))
        }
        statusBar = StatusBarController(router: router)
    }

    // Files opened with brouter (e.g. an .html file via Open With) arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(urlString: url.absoluteString, source: nil) }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            return
        }
        handle(urlString: urlString, source: sourceApp(from: event))
    }

    // MARK: - Routing

    private func handle(urlString: String, source: SourceApp?) {
        let decision = router.route(url: urlString, sourceApp: source)
        switch decision {
        case .open(let target):
            log("route -> \(target.displayName)")
            BrowserLauncher.launch(target, url: urlString)
        case .copy:
            log("route -> copy")
            RouteActions.copy(urlString)
        case .ask(let req):
            log("route -> ask (\(req.options.count) options)")
            let controller = AskDialogController()
            controller.present(req) { option in
                if let option {
                    self.log("  ask -> \(option.displayName)")
                    RouteActions.perform(option, url: urlString)
                } else {
                    self.log("  ask -> cancelled")
                }
            }
        case .none:
            FileHandle.standardError.write(Data("[brouter] no route; using fallback\n".utf8))
            fallbackOpen(urlString)
        }
    }

    /// If routing fails, don't lose the link — open it somewhere sensible.
    private func fallbackOpen(_ urlString: String) {
        if let first = router.allBrowsers().first {
            BrowserLauncher.launch(first, url: urlString)
        } else {
            BrowserLauncher.launch(BrowserTarget(app: "Safari"), url: urlString)
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("[brouter] \(s)\n".utf8))
    }

    // MARK: - Source app

    private func sourceApp(from event: NSAppleEventDescriptor) -> SourceApp? {
        guard let addr = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)),
              let pidDesc = addr.coerce(toDescriptorType: DescType(typeKernelProcessID)) else {
            return nil
        }
        var pid: pid_t = 0
        let data = pidDesc.data
        guard data.count >= MemoryLayout<pid_t>.size else { return nil }
        _ = withUnsafeMutableBytes(of: &pid) { raw in
            data.copyBytes(to: raw.bindMemory(to: UInt8.self))
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return SourceApp(name: app.localizedName, bundleId: app.bundleIdentifier, path: app.bundleURL?.path)
    }
}
