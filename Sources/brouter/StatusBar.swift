import AppKit

/// The menu-bar (status item) controller for the running agent.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let router: Router
    private var agents: [ConfigAgent] = []

    init(router: Router) {
        self.router = router
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "brouter") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "br"
            }
            button.toolTip = "brouter — click for menu, ⌥-click for status"
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Detect coding agents off the main thread (uses a login shell).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = AgentCatalog.detect()
            DispatchQueue.main.async { self?.agents = found }
        }
    }

    private var configURL: URL { router.configURL }

    // MARK: - Menu (rebuilt per click so we can vary on ⌥)

    @objc private func statusButtonClicked() {
        let verbose = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        let menu = buildMenu(verbose: verbose)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // reset so the next click hits the action again
    }

    private func buildMenu(verbose: Bool) -> NSMenu {
        let menu = NSMenu()

        if verbose {
            let title = menu.addItem(withTitle: "brouter \(CLI.version)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            router.reloadIfNeeded()
            if let err = router.lastError {
                let it = menu.addItem(withTitle: "⚠︎ config error", action: #selector(openConfig), keyEquivalent: "")
                it.target = self
                it.toolTip = err
            } else {
                let n = router.allBrowsers().count
                let it = menu.addItem(withTitle: "Config OK · \(n) browser\(n == 1 ? "" : "s")", action: nil, keyEquivalent: "")
                it.isEnabled = false
            }
            menu.addItem(.separator())
        }

        // "Smart Config" — ask a coding agent to edit the config. Always present
        // so "Copy Prompt" is available even when nothing is autodetected.
        let smart = NSMenuItem(title: "Smart Config", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if agents.isEmpty {
            let none = sub.addItem(withTitle: "No agents detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
        } else {
            let hdr = sub.addItem(withTitle: "Ask an agent to edit your config", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            sub.addItem(.separator())
            for a in agents {
                let it = sub.addItem(withTitle: a.name, action: #selector(runAgent(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = a
                if let iconPath = a.iconPath {
                    let icon = NSWorkspace.shared.icon(forFile: iconPath)
                    icon.size = NSSize(width: 16, height: 16)
                    it.image = icon
                } else {
                    it.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                }
            }
        }
        sub.addItem(.separator())
        let copyItem = sub.addItem(withTitle: "Copy Prompt", action: #selector(copyPrompt), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        copyItem.toolTip = "Copy the config-editing prompt so you can paste it into any tool"
        smart.submenu = sub
        menu.addItem(smart)

        // "Manual Config" — edit the file yourself.
        let manual = NSMenuItem(title: "Manual Config", action: nil, keyEquivalent: "")
        let msub = NSMenu()
        add(msub, "Open in Editor", #selector(openConfig))
        add(msub, "Reveal in Finder", #selector(revealConfig))
        add(msub, "Copy Config Path", #selector(copyConfigPath))
        msub.addItem(.separator())
        add(msub, "Reload Config", #selector(reloadConfig))
        manual.submenu = msub
        menu.addItem(manual)

        menu.addItem(.separator())

        let detected = NSMenuItem(title: "Detected Browsers", action: nil, keyEquivalent: "")
        detected.submenu = buildDetectedSubmenu()
        menu.addItem(detected)

        menu.addItem(.separator())
        add(menu, "Quit brouter", #selector(quit), key: "q")
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "") {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        item.target = self
    }

    private func buildDetectedSubmenu() -> NSMenu {
        let sub = NSMenu()
        let browsers = BrowserDetector.detect()
        if browsers.isEmpty {
            let item = sub.addItem(withTitle: "No browsers found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return sub
        }
        for b in browsers {
            let icon = NSWorkspace.shared.icon(forFile: b.appPath)
            icon.size = NSSize(width: 16, height: 16)
            let header = sub.addItem(withTitle: b.shortName, action: nil, keyEquivalent: "")
            header.image = icon
            header.isEnabled = false
            for t in b.targets {
                let label = t.profileLabel.map { "    \($0)" } ?? "    (default)"
                let item = sub.addItem(withTitle: label, action: #selector(copyBrowserKey(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.key
                item.toolTip = t.detail.map { "\($0) — copy config key: \(t.key)" } ?? "Copy config key: \(t.key)"
            }
        }
        sub.addItem(.separator())
        let hint = sub.addItem(withTitle: "Click a profile to copy its config key", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        return sub
    }

    // MARK: - Actions

    @objc private func runAgent(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? ConfigAgent else { return }
        Config.ensureExists()

        // App-scheme agents (Claude/Codex desktop) just open a URL — no terminal.
        if !agent.needsTerminal {
            AgentLauncher.run(agent: agent, configURL: configURL, terminal: nil)
            return
        }

        let terminals = TerminalCatalog.detect()
        guard !terminals.isEmpty else {
            NSSound.beep()
            return
        }
        if terminals.count == 1 {
            AgentLauncher.run(agent: agent, configURL: configURL, terminal: terminals[0])
            return
        }
        // Multiple terminals: ask which one, reusing the native picker.
        let options = terminals.map { PickerOption(title: $0.name, subtitle: nil, icon: $0.icon) }
        let picker = AskDialogController()
        picker.presentPicker(caption: "Open \(agent.name) in…",
                             title: "Choose a terminal",
                             detail: configURL.path,
                             options: options, defaultIndex: 0) { [router] idx in
            guard let i = idx else { return }
            AgentLauncher.run(agent: agent, configURL: router.configURL, terminal: terminals[i])
        }
    }

    @objc private func copyPrompt() {
        Config.ensureExists()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AgentCatalog.prompt(for: configURL), forType: .string)
    }

    @objc private func openConfig() {
        Config.ensureExists()
        NSWorkspace.shared.open(configURL)
    }

    @objc private func revealConfig() {
        Config.ensureExists()
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    @objc private func copyConfigPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(configURL.path, forType: .string)
    }

    @objc private func copyBrowserKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(key, forType: .string)
    }

    @objc private func reloadConfig() {
        router.load()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
