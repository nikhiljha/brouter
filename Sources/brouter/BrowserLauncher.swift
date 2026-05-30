import AppKit

enum BrowserLauncher {
    /// Build the argument vector passed to `/usr/bin/open` for a target+url.
    static func openArguments(for target: BrowserTarget, url: String) -> [String] {
        var args: [String] = []

        // How to identify the app to `open`.
        let appSpec = appSpecifier(target.app)

        let needsArgs = target.profile != nil || !target.args.isEmpty
        if needsArgs {
            // New instance routing so we can pass --args (Chrome de-dupes itself).
            args += ["-n"]
        }
        args += appSpec

        if needsArgs {
            args += ["--args"]
            if let profile = target.profile, !profile.isEmpty {
                args += ["--profile-directory=\(profile)"]
            }
            args += target.args
            args += [url]
        } else {
            args += [url]
        }
        return args
    }

    /// Returns the `open` flag pair identifying the application.
    /// - "/Applications/Foo.app" or contains "/" or ends ".app" -> -a <path>
    /// - looks like a bundle id (dotted, no spaces) -> -b <id>
    /// - otherwise an app name -> -a <name>
    private static func appSpecifier(_ app: String) -> [String] {
        if app.hasSuffix(".app") || app.contains("/") {
            return ["-a", app]
        }
        if app.contains("."), !app.contains(" ") {
            return ["-b", app]
        }
        return ["-a", app]
    }

    /// Launch the URL in the given target. Returns true on success.
    @discardableResult
    static func launch(_ target: BrowserTarget, url: String) -> Bool {
        let args = openArguments(for: target, url: url)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            let ok = proc.terminationStatus == 0
            if !ok {
                FileHandle.standardError.write(Data("[brouter] open exited \(proc.terminationStatus) for: open \(args.joined(separator: " "))\n".utf8))
            }
            return ok
        } catch {
            FileHandle.standardError.write(Data("[brouter] failed to launch open: \(error)\n".utf8))
            return false
        }
    }

    // MARK: - App resolution (for icons / labels)

    /// Resolve a target's app to a file URL on disk, if possible.
    static func appURL(for app: String) -> URL? {
        let ws = NSWorkspace.shared
        if app.hasSuffix(".app") || app.contains("/") {
            let url = URL(fileURLWithPath: app)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if app.contains("."), !app.contains(" "), let url = ws.urlForApplication(withBundleIdentifier: app) {
            return url
        }
        // Try by display name.
        if let path = ws.fullPath(forApplication: app) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Icon for a target's app, or a generic application icon.
    static func icon(for target: BrowserTarget) -> NSImage {
        if let url = appURL(for: target.app) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
